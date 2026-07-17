#!/usr/bin/env bash
# Workflow-migration structural tests (schema validity, agent cross-refs,
# and — added in Phase 2 — workflow meta + flag wiring).

_wm_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

test_finding_schema_is_valid_json() {
    local cr
    cr=$(_wm_cr_dir)
    local schema="$cr/includes/finding-schema.json"
    if [[ ! -f "$schema" ]]; then
        fail "finding-schema.json exists" "missing: $schema"
        return
    fi
    if jq empty "$schema" 2>/dev/null; then
        pass "finding-schema.json is well-formed JSON"
    else
        fail "finding-schema.json is well-formed JSON" "jq could not parse $schema"
    fi
    # Every $def the migration depends on must be present.
    local def
    for def in finding specialistOutput synthEnvelope sealedBundle crossOpinionEnvelope; do
        if jq -e --arg d "$def" '.["$defs"][$d]' "$schema" >/dev/null 2>&1; then
            pass "finding-schema.json defines \$defs.$def"
        else
            fail "finding-schema.json defines \$defs.$def" "definition missing"
        fi
    done
}

test_static_agents_reference_finding_schema() {
    local cr
    cr=$(_wm_cr_dir)
    local agent
    for agent in ruff-reviewer eslint-reviewer trivy-reviewer jbinspect-reviewer housekeeper-reviewer; do
        local path="$cr/agents/$agent.md"
        if [[ ! -f "$path" ]]; then
            fail "static agent references schema: $agent" "file not found"
            continue
        fi
        if grep -qF 'includes/finding-schema.json' "$path"; then
            pass "static agent references schema: $agent"
        else
            fail "static agent references schema: $agent" \
                "body must cite includes/finding-schema.json so its §7 fields stay aligned with the schema"
        fi
    done
}

test_synthesiser_documents_structured_envelope() {
    local cr
    cr=$(_wm_cr_dir)
    local synth="$cr/agents/review-synthesiser.md"
    if [[ ! -f "$synth" ]]; then
        fail "synthesiser envelope section" "review-synthesiser.md not found"
        return
    fi
    if grep -qF 'synthEnvelope' "$synth"; then
        pass "synthesiser envelope: references finding-schema synthEnvelope def"
    else
        fail "synthesiser envelope: references finding-schema synthEnvelope def" \
            "synthesiser body must document the synthEnvelope structured output for the review-core consumer"
    fi
    if grep -qF 'bodyText' "$synth"; then
        pass "synthesiser envelope: documents bodyText carries full prose"
    else
        fail "synthesiser envelope: documents bodyText carries full prose" \
            "the envelope's bodyText field (full prose report) must be documented so the schema is not read as flattening the judgement"
    fi
}

# A workflow .mjs cannot pass a raw `node --check`: it is parsed as an ES module, so
# `export const meta` combined with the script's top-level `return` is illegal ESM and
# `node --check` always errors "Illegal return statement". The Workflow runtime strips
# `export` and wraps the body in an async function before running it; a faithful syntax
# check must do the same. This helper mirrors that transform.
_wm_syntax_ok() {
    local file="$1"
    node -e '
        const fs = require("fs");
        const s = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        new Function("agent", "parallel", "pipeline", "phase", "log", "args", "workflow",
            "(async()=>{" + s + "\n})()");
    ' "$file" 2>/dev/null
}

test_review_core_workflow_present_and_well_formed() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core.mjs exists" "missing: $wf"
        return
    fi
    pass "review-core.mjs exists"
    if grep -qE "name: 'review-core'" "$wf"; then
        pass "review-core.mjs meta declares name review-core"
    else
        fail "review-core.mjs meta declares name review-core" "meta.name missing or wrong"
    fi
    if grep -qF 'description:' "$wf"; then
        pass "review-core.mjs meta declares a description"
    else
        fail "review-core.mjs meta declares a description" "meta.description missing"
    fi
    # Syntax validity via the runtime-faithful transform (NOT raw `node --check`).
    if _wm_syntax_ok "$wf"; then
        pass "review-core.mjs is syntactically valid (runtime-faithful check)"
    else
        fail "review-core.mjs is syntactically valid (runtime-faithful check)" \
            "the strip-export + async-wrap transform failed to parse the script"
    fi
}

test_host_wires_workflow_flag() {
    local cr
    cr=$(_wm_cr_dir)
    local file
    for file in includes/review-pipeline.md skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if [[ ! -f "$path" ]]; then
            fail "host wires workflow flag: $file" "file not found"
            continue
        fi
        if grep -qF "workflow({scriptPath: \$REVIEW_CORE_PATH}" "$path"; then
            pass "host wires workflow flag: $file calls workflow({scriptPath})"
        else
            fail "host wires workflow flag: $file calls workflow({scriptPath})" \
                "Step 3.5 must call workflow({scriptPath: \$REVIEW_CORE_PATH}, ...) unconditionally in every pipeline copy — the Workflow is the only orchestration path"
        fi
    done
}

test_no_inline_dispatch_fallback() {
    # The Workflow is the ONLY orchestration path: there is no inline specialist-dispatch
    # fallback gated by $USE_WORKFLOW / --no-workflow. Assert none of the three pipeline
    # copies retain the routing-gate tokens. This is the structural guarantee that the
    # ~40% inline-dispatch bypass cannot recur from the prose.
    local cr
    cr=$(_wm_cr_dir)
    local file
    for file in includes/review-pipeline.md skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if [[ ! -f "$path" ]]; then
            fail "no inline dispatch fallback: $file" "file not found"
            continue
        fi
        if grep -qE 'USE_WORKFLOW|--no-workflow|orchestration\.use_workflow' "$path"; then
            fail "no inline dispatch fallback: $file" \
                "found a routing-gate token (USE_WORKFLOW / --no-workflow / orchestration.use_workflow) in $file — the inline fallback must be fully deleted, not gated. The Workflow is the only path."
        else
            pass "no inline dispatch fallback: $file has no routing-gate tokens"
        fi
    done
}

# R2-B: the script inlines the schema (import() is unavailable in the sandbox), so a
# structural test asserts the inlined literals stay a faithful $ref-flattened equivalent
# of includes/finding-schema.json. We slice the script prefix (the schema consts precede
# the `const resolvedArgs = ...` args normaliser and the `const {...} = resolvedArgs`
# destructure), eval it to recover SPECIALIST_SCHEMA / SYNTH_SCHEMA, flatten the canonical's
# `#/$defs/finding` $refs the same way, and deep-compare. The cut anchors on `const
# resolvedArgs` (not the destructure) because the normaliser reads the unbound `args` global,
# which would throw in the schema-only extract harness. The eval input is the repo's own
# committed source — same trust level as the syntax gate above.
test_inlined_schema_matches_canonical() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    local schema="$cr/includes/finding-schema.json"
    if [[ ! -f "$wf" || ! -f "$schema" ]]; then
        fail "inlined schema parity" "review-core.mjs or finding-schema.json missing"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const wfPath = process.argv[1];
        const schemaPath = process.argv[2];
        const wf = fs.readFileSync(wfPath, "utf8");
        const cut = wf.indexOf("const resolvedArgs");
        if (cut < 0) { console.log("ERR: resolvedArgs normaliser not found"); process.exit(1); }
        const prefix = wf.slice(0, cut).replace(/^export\s+const\s+meta/m, "const meta");
        const extract = new Function(prefix + "\nreturn { SPECIALIST_SCHEMA, SYNTH_SCHEMA, CROSS_SCHEMA };");
        const { SPECIALIST_SCHEMA, SYNTH_SCHEMA, CROSS_SCHEMA } = extract();
        const canon = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
        const finding = canon["$defs"].finding;
        const flatten = (node) => {
            if (Array.isArray(node)) return node.map(flatten);
            if (node && typeof node === "object") {
                if (node["$ref"] === "#/$defs/finding") return JSON.parse(JSON.stringify(finding));
                const out = {};
                for (const [k, v] of Object.entries(node)) out[k] = flatten(v);
                return out;
            }
            return node;
        };
        // Order-insensitive deep-equal: sort object keys recursively before
        // stringifying, so an innocent key reorder in either source does not
        // false-fail while a real value/structure drift still does.
        const canonical = (node) => {
            if (Array.isArray(node)) return node.map(canonical);
            if (node && typeof node === "object") {
                const out = {};
                for (const k of Object.keys(node).sort()) out[k] = canonical(node[k]);
                return out;
            }
            return node;
        };
        const eq = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
        const sOk = eq(SPECIALIST_SCHEMA, flatten(canon["$defs"].specialistOutput));
        const yOk = eq(SYNTH_SCHEMA, flatten(canon["$defs"].synthEnvelope));
        const cOk = eq(CROSS_SCHEMA, flatten(canon["$defs"].crossOpinionEnvelope));
        if (sOk && yOk && cOk) { console.log("OK"); }
        else { console.log("MISMATCH specialist=" + sOk + " synth=" + yOk + " cross=" + cOk); }
    ' "$wf" "$schema" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "inlined schema parity: SPECIALIST_SCHEMA + SYNTH_SCHEMA + CROSS_SCHEMA match finding-schema.json"
    else
        fail "inlined schema parity: SPECIALIST_SCHEMA + SYNTH_SCHEMA + CROSS_SCHEMA match finding-schema.json" \
            "the inlined schema literals drifted from the canonical \$ref-flattened defs: $result"
    fi
}

# Category C resilience: an agent() that resolves successfully with null (the documented
# ~30% empty-stdout failure mode) must not crash any of the three dispatch sites. We eval
# the full script body with mock globals — mock agent() always returns null — and assert
# the workflow returns a bundle (verdict NONE in local mode) rather than throwing. This
# guards review-core.mjs:228-231 (specialist), 265-272 (cross), and 295-309 (synth).
test_review_core_survives_null_agent_results() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core null-agent resilience" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const mkArgs = (mode) => ({
            agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
            reviewMode: mode, base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        });
        const agent = async () => null;                       // Category C: resolves, null value
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (mode) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, mkArgs(mode), workflow);
        };
        (async () => {
            for (const mode of ["local", "pr"]) {
                let bundle;
                try { bundle = await run(mode); }
                catch (e) { console.log("THREW(" + mode + "): " + e.message); return; }
                if (!bundle || typeof bundle !== "object") { console.log("NOBUNDLE(" + mode + ")"); return; }
                if (!("verdict" in bundle) || !("comments" in bundle)) { console.log("BADSHAPE(" + mode + ")"); return; }
            }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "review-core survives null agent() results at all dispatch sites"
    else
        fail "review-core survives null agent() results at all dispatch sites" \
            "a dispatch site crashed or returned no bundle on null agent output: $result"
    fi
}

# Production bug regression (2026-06-16): the host skill runs in the main agent loop, which
# has no workflow() primitive, so its documented workflow({scriptPath}, {...}) call is
# executed as a Workflow-TOOL invocation — and the Workflow tool delivers args as a JSON
# STRING, not an object. Destructuring a string yields flags===undefined, and the first
# flags.csharp read throws. The resolvedArgs normaliser must JSON.parse a string arg so the
# script runs unchanged. We feed the FULL script a stringified args object (flags.csharp set)
# with a null-returning agent and assert it reaches a bundle rather than throwing flags.csharp.
test_review_core_accepts_string_args() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core string-args resilience" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const argsStr = JSON.stringify({
            agentPrompt: "x", flags: { csharp: true }, route: "full", selfReReview: false,
            reviewMode: "local", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        });
        const agent = async () => null;
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        (async () => {
            let bundle;
            try {
                const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                    "return (async()=>{" + src + "\n})()");
                bundle = await fn(agent, parallel, pipeline, phase, log, argsStr, workflow);
            } catch (e) { console.log("THREW: " + e.message); return; }
            if (!bundle || typeof bundle !== "object") { console.log("NOBUNDLE"); return; }
            if (!("verdict" in bundle) || !("comments" in bundle)) { console.log("BADSHAPE"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "review-core accepts a JSON-string args (Workflow-tool shape) without throwing"
    else
        fail "review-core accepts a JSON-string args (Workflow-tool shape) without throwing" \
            "the resolvedArgs normaliser must JSON.parse a string arg; got: $result"
    fi
}

# The intent ledger must be threaded from args into the synth prompt (gate follow-up #1).
# Without it, verdict-rubric row 1 can never fire on the --workflow path.
test_review_core_threads_intent_ledger_to_synth() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core intent-ledger threading" "missing: $wf"
        return
    fi
    # Assert intentLedger appears in the args destructure (the `const { ... } = args` block).
    if grep -qE 'intentLedger,' "$wf" || grep -qE 'intentLedger\s*\}' "$wf"; then
        pass "review-core destructures intentLedger from args"
    else
        fail "review-core destructures intentLedger from args" \
            "the args destructure must include intentLedger so the synth prompt can reference it"
    fi
    # Direct check: the synthPrompt string-concatenation references intentLedger via a
    # defensive ternary (intentLedger ? ... : ...).
    if grep -qE 'intentLedger\s*\?' "$wf"; then
        pass "review-core interpolates intentLedger into synth prompt (defensive ternary)"
    else
        fail "review-core interpolates intentLedger into synth prompt (defensive ternary)" \
            "the synth prompt assembly must include a conditional (intentLedger ? ...) for the ledger block"
    fi
}

# repoDir must be threaded from args into the synth prompt so the synthesiser analyses
# the target repository (not cwd) when the review targets a PR in another checkout.
# Specialists receive repoDir via the host-built agentPrompt's "Repo dir:" line; the
# synthesiser prompt is built inside review-core, so it needs its own injection.
test_review_core_threads_repo_dir_to_synth() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core repoDir threading" "missing: $wf"
        return
    fi
    # Assert repoDir appears in the args destructure.
    if grep -qE 'repoDir,' "$wf" || grep -qE 'repoDir\s*\}' "$wf"; then
        pass "review-core destructures repoDir from args"
    else
        fail "review-core destructures repoDir from args" \
            "the args destructure must include repoDir so the synth prompt can target the right repo"
    fi
    # Direct check: the synthPrompt assembly references repoDir via a defensive ternary
    # so the "Repo dir:" line is emitted only when a target repo was supplied.
    if grep -qE 'repoDir\s*\?' "$wf"; then
        pass "review-core interpolates repoDir into synth prompt (defensive ternary)"
    else
        fail "review-core interpolates repoDir into synth prompt (defensive ternary)" \
            "the synth prompt assembly must include a conditional (repoDir ? ...) for the Repo dir line"
    fi
}

# PR D: the synthesiser's Context Gathering step 1 reads the pinned diff from a
# "Full diff file:" line when present. That line is built inside review-core's
# synthPrompt (the synthesiser prompt is assembled here, not by the host), derived
# from tempDir to match review-pipeline.md Step 2.85's $RESOLVED_TEMP_DIR/review-diff.patch.
# Without this threading the synthesiser never sees the line and always falls back to git.
test_review_core_threads_full_diff_file_to_synth() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core full-diff-file threading" "missing: $wf"
        return
    fi

    # Structural: the synthPrompt assembly must emit a "Full diff file:" line via a
    # defensive ternary so it appears only when the diff path is resolvable.
    if grep -qE 'Full diff file: \$\{fullDiffFile\}' "$wf"; then
        pass "review-core interpolates Full diff file into synth prompt"
    else
        fail "review-core interpolates Full diff file into synth prompt" \
            "synthPrompt must include a 'Full diff file: \${fullDiffFile}' line so the synthesiser reads the pinned diff (PR D)"
    fi

    # Structural: the path must be derived from tempDir + the Step 2.85 filename.
    if grep -qE 'review-diff\.patch' "$wf"; then
        pass "review-core derives the diff path from the Step 2.85 filename"
    else
        fail "review-core derives the diff path from the Step 2.85 filename" \
            "the diff path must reference review-diff.patch (the artifact review-pipeline.md Step 2.85 writes)"
    fi

    # Behavioural: drive the REAL module (as the stall test does) and capture the actual
    # synthPrompt it builds. Force a round-1 synth stall so crossAndSynth returns the
    # synthDeferred bundle carrying synthPrompt, then assert the resolved "Full diff file:"
    # line is present with the correct joined path (tempDir + Step 2.85 filename).
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const STALL = "agent stalled on all 6 attempts (no progress for 180000ms each)";
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        const isSynth = (opts) => opts && opts.agentType === "code-review-suite:review-synthesiser";
        const agentStall = async (prompt, opts) => {
            if (isSynth(opts)) throw new Error(STALL);
            return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
        };
        (async () => {
            // tempDir with a trailing slash — the join must not double up.
            const args = {
                agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
                reviewMode: "pr", base: "main", headSha: "a".repeat(40),
                emptyTreeMode: false, pathScope: "", tempDir: "/tmp/claude-abc/",
            };
            let deferred;
            try { deferred = await run(agentStall, args); }
            catch (e) { console.log("THREW: " + e.message); return; }
            const p = deferred && deferred.synthPrompt;
            if (typeof p !== "string") { console.log("NO_PROMPT"); return; }
            if (!p.includes("Full diff file: /tmp/claude-abc/review-diff.patch")) {
                console.log("MISSING_OR_BAD_LINE: " + (p.match(/Full diff file:.*/)||["<absent>"])[0]);
                return;
            }
            if (p.includes("//review-diff")) { console.log("DOUBLE_SLASH"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)

    if [[ "$result" == "OK" ]]; then
        pass "review-core synthPrompt carries a clean Full diff file line (real module, trailing-slash tempDir)"
    else
        fail "review-core synthPrompt carries a clean Full diff file line (real module, trailing-slash tempDir)" \
            "expected OK, got: $result"
    fi
}

# PR E: cross-reviewers stop re-running git to reconstruct context by being handed the
# pinned diff as data. The cross prompt is assembled inside review-core's crossAndSynth
# (NOT the host agentPrompt, and NOT agent_dispatch.sh — the cross path is review-core-only),
# so the "Full diff file:" line must be threaded there, derived from tempDir + the Step 2.85
# filename exactly as the synth prompt is. Without it the cross-reviewers never see the line
# and fall back to git. Drive the REAL module and capture the actual cross prompt via the
# agent() mock (cross-reviewers are dispatched before the synth turn, so a synth stall still
# lets us observe the cross prompt the module built).
test_review_core_threads_full_diff_file_to_cross() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "review-core full-diff-file threading to cross" "missing: $wf"
        return
    fi

    # Structural: the cross prompt assembly must emit a "Full diff file:" line via a
    # defensive ternary so it appears only when the diff path is resolvable. The grep
    # targets the fullDiffFile-interpolated form used in the cross agent() prompt string.
    if grep -qE 'Full diff file: \$\{fullDiffFile\}' "$wf"; then
        pass "review-core interpolates Full diff file into cross prompt"
    else
        fail "review-core interpolates Full diff file into cross prompt" \
            "the cross-reviewer prompt must include a 'Full diff file: \${fullDiffFile}' line so cross-reviewers read the pinned diff (PR E)"
    fi

    # Behavioural: drive the REAL module and capture the FIRST cross-reviewer prompt. Cross
    # reviewers run under a non-synthesiser agentType; the synth turn throws a stall so the
    # run returns the synthDeferred bundle without needing a full envelope. Assert the
    # captured cross prompt carries the resolved, clean "Full diff file:" line and, as a
    # guard against re-inlining the whole diff, that the prompt still passes peer findings.
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const STALL = "agent stalled on all 6 attempts (no progress for 180000ms each)";
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        const isSynth = (opts) => opts && opts.agentType === "code-review-suite:review-synthesiser";
        let crossPrompt = null;
        const agentMock = async (prompt, opts) => {
            if (isSynth(opts)) throw new Error(STALL);
            // Capture the first cross-review prompt (round-1 specialists get the host
            // agentPrompt "x"; cross prompts are the ones that open with "Mode: cross-review").
            if (crossPrompt === null && typeof prompt === "string" && prompt.startsWith("Mode: cross-review")) {
                crossPrompt = prompt;
            }
            return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
        };
        (async () => {
            const args = {
                agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
                reviewMode: "pr", base: "main", headSha: "a".repeat(40),
                emptyTreeMode: false, pathScope: "", tempDir: "/tmp/claude-abc/",
            };
            try { await run(agentMock, args); }
            catch (e) { console.log("THREW: " + e.message); return; }
            if (typeof crossPrompt !== "string") { console.log("NO_CROSS_PROMPT"); return; }
            if (!crossPrompt.includes("Full diff file: /tmp/claude-abc/review-diff.patch")) {
                console.log("MISSING_OR_BAD_LINE: " + (crossPrompt.match(/Full diff file:.*/)||["<absent>"])[0]);
                return;
            }
            if (crossPrompt.includes("//review-diff")) { console.log("DOUBLE_SLASH"); return; }
            if (!crossPrompt.includes("Peer findings (JSON):")) { console.log("NO_PEER_FINDINGS"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)

    if [[ "$result" == "OK" ]]; then
        pass "review-core cross prompt carries a clean Full diff file line (real module, trailing-slash tempDir)"
    else
        fail "review-core cross prompt carries a clean Full diff file line (real module, trailing-slash tempDir)" \
            "expected OK, got: $result"
    fi
}

# Task 1: the finalize route re-enters review-core with a recovered envelope, runs
# finalizeBundle (Class D filter + render) with ZERO agent() calls, and produces a bundle
# identical (in verdict/comments/bodyText) to the normal path for the same non-gate-firing
# envelope. Uses an APPROVE envelope with no contested tier and no Important consensus, so
# boundaryGateFires() is false and the two paths are directly comparable.
test_finalize_route_parity() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "finalize route parity" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const ENV = {
            verdict: "APPROVE",
            rubricRowApplied: 4,
            rubricReason: "no high-confidence findings",
            tiers: {
                consensus: [{ file: "a.js", line: 10, severity: "Suggestion", confidence: 90, description: "desc one", suggested_fix: "fix one" }],
                synthesiser: [{ file: "b.js", line: 20, severity: "Suggestion", confidence: 50, description: "desc two", suggested_fix: "fix two" }],
                contested: [],
                dismissed: [],
            },
            bodyText: "## Summary\n1 file(s) changed | 1 finding(s) | 0 contested\n\n## Synthesiser Assessment\n> Looks fine.\n",
        };
        const baseArgs = {
            agentPrompt: "x", flags: {}, selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        const pick = (b) => ({ verdict: b.verdict, comments: b.comments, bodyText: b.bodyText });
        (async () => {
            // (a) finalize route: agent() must NEVER be called; envelope passed as arg.
            let called = false;
            const agentNever = async () => { called = true; return null; };
            let finalizeBundle;
            try {
                finalizeBundle = await run(agentNever, { ...baseArgs, route: "finalize", envelope: ENV });
            } catch (e) { console.log("THREW(finalize): " + e.message); return; }
            if (called) { console.log("AGENT_CALLED_ON_FINALIZE"); return; }
            if (finalizeBundle.verdict !== "APPROVE") { console.log("BADVERDICT: " + finalizeBundle.verdict); return; }
            if (!Array.isArray(finalizeBundle.comments) || finalizeBundle.comments.length !== 1) { console.log("BADCOMMENTS: " + JSON.stringify(finalizeBundle.comments)); return; }
            if (finalizeBundle.comments[0].path !== "a.js" || finalizeBundle.comments[0].line !== 10) { console.log("BADANCHOR: " + JSON.stringify(finalizeBundle.comments[0])); return; }
            if (!finalizeBundle.bodyText.includes("**APPROVE**")) { console.log("NOHEADLINE"); return; }
            // (b) normal path with a synth mock returning the SAME envelope, no gate fires.
            const agentSynth = async (prompt, opts) => {
                if (opts && opts.agentType === "code-review-suite:review-synthesiser") return ENV;
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let normal;
            try {
                normal = await run(agentSynth, { ...baseArgs, route: "full" });
            } catch (e) { console.log("THREW(normal): " + e.message); return; }
            if (JSON.stringify(pick(normal)) !== JSON.stringify(pick(finalizeBundle))) {
                console.log("PARITY_MISMATCH\nnormal=" + JSON.stringify(pick(normal)) + "\nfinalize=" + JSON.stringify(pick(finalizeBundle)));
                return;
            }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "finalize route runs finalizeBundle with zero agents and matches normal-path output"
    else
        fail "finalize route runs finalizeBundle with zero agents and matches normal-path output" \
            "$result"
    fi
}

# Task 4 (recovery-path degrade): the finalize route is what seals a recovered envelope, but
# the standalone synth can write a corrupt/absent file — the caller's defensive Read/parse then
# hands finalize a null (or the caller emits the empty bundle directly). finalizeBundle's
# Category-C guard MUST turn a null/missing-tiers envelope into the exact empty bundle
# `{ verdict:'NONE', bodyText:'(synthesiser produced no usable output)', comments:[] }` with ZERO
# agent() calls — that is the "degrade, never hang" promise on the recovery path itself. The
# parity test only drives finalize with a well-formed envelope; this asserts the degrade branch.
test_finalize_route_null_envelope_degrades() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "finalize route null-envelope degrade" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const baseArgs = {
            agentPrompt: "x", flags: {}, selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        (async () => {
            // finalize route with a null envelope (corrupt/absent recovery file) must NOT call
            // agent() and must return the exact empty bundle.
            let called = false;
            const agentNever = async () => { called = true; return null; };
            let bundle;
            try {
                bundle = await run(agentNever, { ...baseArgs, route: "finalize", envelope: null });
            } catch (e) { console.log("THREW(null): " + e.message); return; }
            if (called) { console.log("AGENT_CALLED_ON_NULL_FINALIZE"); return; }
            if (bundle.verdict !== "NONE") { console.log("BADVERDICT: " + bundle.verdict); return; }
            if (!Array.isArray(bundle.comments) || bundle.comments.length !== 0) { console.log("BADCOMMENTS: " + JSON.stringify(bundle.comments)); return; }
            if (bundle.bodyText !== "(synthesiser produced no usable output)") { console.log("BADBODY: " + JSON.stringify(bundle.bodyText)); return; }
            // Also cover a valid-JSON-but-missing-tiers envelope (partial corruption that JSON.parse
            // accepts): same Category-C guard, same empty bundle.
            let bundle2;
            try {
                bundle2 = await run(agentNever, { ...baseArgs, route: "finalize", envelope: { verdict: "APPROVE" } });
            } catch (e) { console.log("THREW(notiers): " + e.message); return; }
            if (bundle2.verdict !== "NONE" || bundle2.bodyText !== "(synthesiser produced no usable output)") {
                console.log("NOTIERS_NOT_DEGRADED: " + JSON.stringify(bundle2)); return;
            }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "finalize route degrades a null/missing-tiers envelope to the empty bundle with zero agents"
    else
        fail "finalize route degrades a null/missing-tiers envelope to the empty bundle with zero agents" \
            "$result"
    fi
}

# Task 2: a synth agent() that throws the runtime stall message must be caught inside
# crossAndSynth; the round-1 site then returns a synthDeferred bundle (NOT a crash, NOT an
# empty Category-C bundle). A non-stall throw must re-propagate. A round-2 stall must be
# absorbed by the existing "retain round-1" degrade (no defer, no crash).
test_synth_stall_defers() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "synth stall recovery" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const STALL = "agent stalled on all 6 attempts (no progress for 180000ms each)";
        const baseArgs = {
            agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        const isSynth = (opts) => opts && opts.agentType === "code-review-suite:review-synthesiser";
        (async () => {
            // (a) round-1 synth stall → synthDeferred bundle carrying the prompt.
            const agentStall = async (prompt, opts) => {
                if (isSynth(opts)) throw new Error(STALL);
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let deferred;
            try { deferred = await run(agentStall, baseArgs); }
            catch (e) { console.log("THREW(stall): " + e.message); return; }
            if (deferred.synthDeferred !== true) { console.log("NO_DEFER: " + JSON.stringify(deferred).slice(0, 120)); return; }
            if (typeof deferred.synthPrompt !== "string" || !deferred.synthPrompt.includes("ultrathink")) { console.log("BAD_PROMPT"); return; }
            // (b) a non-stall throw must re-propagate.
            const agentOtherThrow = async (prompt, opts) => {
                if (isSynth(opts)) throw new Error("some other failure");
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let propagated = false;
            try { await run(agentOtherThrow, baseArgs); }
            catch (e) { propagated = /some other failure/.test(e.message); }
            if (!propagated) { console.log("NONSTALL_NOT_PROPAGATED"); return; }
            // (c) round-2 stall is absorbed: round-1 gate fires (APPROVE + contested), round-2
            // synth stalls, and the run retains the round-1 verdict without deferring/crashing.
            const ENV_GATE = {
                verdict: "APPROVE", rubricRowApplied: 4, rubricReason: "borderline",
                tiers: { consensus: [], synthesiser: [],
                         contested: [{ file: "c.js", line: 5, severity: "Suggestion", confidence: 55, description: "d", suggested_fix: "f" }],
                         dismissed: [] },
                bodyText: "## Synthesiser Assessment\n> hi\n",
            };
            let synthCalls = 0;
            const agentGateThenStall = async (prompt, opts) => {
                if (isSynth(opts)) { synthCalls++; if (synthCalls === 1) return ENV_GATE; throw new Error(STALL); }
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let r2;
            try { r2 = await run(agentGateThenStall, baseArgs); }
            catch (e) { console.log("THREW(round2): " + e.message); return; }
            if (r2.synthDeferred) { console.log("ROUND2_WRONGLY_DEFERRED"); return; }
            if (r2.verdict !== "APPROVE") { console.log("ROUND2_LOST_R1_VERDICT: " + r2.verdict); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "synth stall defers (round 1), re-propagates non-stall, absorbs round-2 stall"
    else
        fail "synth stall defers (round 1), re-propagates non-stall, absorbs round-2 stall" \
            "$result"
    fi
}

# Task 4: all three pipeline copies must document the caller-side stall-recovery branch
# (synthDeferred → standalone dispatch → finalize re-entry). The sync test enforces the three
# are byte-identical; this test asserts the recovery tokens are present in each.
test_caller_wires_stall_recovery() {
    local cr
    cr=$(_wm_cr_dir)
    local file
    for file in includes/review-pipeline.md skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if [[ ! -f "$path" ]]; then
            fail "caller wires stall recovery: $file" "file not found"
            continue
        fi
        if grep -qF 'synthDeferred' "$path" \
            && grep -qF 'synth-standalone-recovery' "$path" \
            && grep -qF "route: 'finalize'" "$path"; then
            pass "caller wires stall recovery: $file has the synthDeferred recovery branch"
        else
            fail "caller wires stall recovery: $file has the synthDeferred recovery branch" \
                "Step 3.5 must handle a synthDeferred bundle: standalone review-synthesiser dispatch (name synth-standalone-recovery) then a workflow re-invoke with route: 'finalize'"
        fi
    done
}

# Task 3: the synthesiser agent must document the standalone recovery mode — when an
# `Envelope output path:` line is present, Write the structured envelope JSON to that path.
# It must ALSO be granted the Write tool, or the standalone dispatch inherits a toolset that
# cannot honour the contract and every recovery silently degrades to the empty bundle.
test_synthesiser_documents_standalone_recovery() {
    local cr
    cr=$(_wm_cr_dir)
    local synth="$cr/agents/review-synthesiser.md"
    if [[ ! -f "$synth" ]]; then
        fail "synthesiser standalone recovery note" "review-synthesiser.md not found"
        return
    fi
    if grep -qF 'Envelope output path:' "$synth"; then
        pass "synthesiser documents the Envelope output path: recovery trigger"
    else
        fail "synthesiser documents the Envelope output path: recovery trigger" \
            "review-synthesiser.md must document the standalone recovery mode keyed on an 'Envelope output path:' prompt line"
    fi
    if grep -qiE 'standalone recovery' "$synth"; then
        pass "synthesiser has a Standalone recovery mode section"
    else
        fail "synthesiser has a Standalone recovery mode section" \
            "add a 'Standalone recovery mode' note instructing the agent to Write the envelope JSON"
    fi
    # The recovery contract is inert without the Write tool: the standalone dispatch inherits
    # this frontmatter, so a missing Write grant means the agent cannot write the envelope file
    # and the caller's defensive read always falls back to the empty bundle. Assert the tools:
    # frontmatter line grants Write.
    if grep -qE '^tools:.*\bWrite\b' "$synth"; then
        pass "synthesiser frontmatter grants the Write tool (recovery envelope file write)"
    else
        fail "synthesiser frontmatter grants the Write tool (recovery envelope file write)" \
            "review-synthesiser.md 'tools:' frontmatter must include Write — without it the standalone recovery dispatch cannot write the envelope JSON and every recovery degrades to the empty bundle"
    fi
}

# The lone in-sandbox synth turn reasons in 2min+ silent windows (opus + ultrathink), which
# trips the Workflow sandbox's default 180s (V$m=180000) no-progress watchdog on EVERY full
# review — 6 stalled attempts + ~30min + ~77k discarded output tokens before the out-of-sandbox
# recovery fires. The watchdog timeout is NOT fixed: the binary binds it from a per-agent()-call
# `stallMs` option (`ie = se?.stallMs != null ? Number(se.stallMs) : V$m`), forwarded on the
# workflow path. Setting stallMs to the async-path budget (600000, 3.3x headroom, proven by the
# standalone recovery run) keeps the synth in-sandbox and lets it complete in one attempt. This
# test drives review-core with a mock agent() that captures the synth call's opts and asserts the
# stallMs value actually reaches the call — a behavioural guard, immune to comments/stray tokens,
# so a future refactor cannot silently drop it and reintroduce the stall tax.
test_synth_call_sets_stall_budget() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "synth stall budget" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const ENV = {
            verdict: "APPROVE",
            rubricRowApplied: 4,
            rubricReason: "no high-confidence findings",
            tiers: { consensus: [], synthesiser: [], contested: [], dismissed: [] },
            bodyText: "## Synthesiser Assessment\n> Looks fine.\n",
        };
        const baseArgs = {
            agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        (async () => {
            let synthOpts = null;
            const agent = async (prompt, opts) => {
                if (opts && opts.agentType === "code-review-suite:review-synthesiser") {
                    synthOpts = opts;
                    return ENV;
                }
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            try { await run(agent, baseArgs); }
            catch (e) { console.log("THREW: " + e.message); return; }
            if (synthOpts === null) { console.log("SYNTH_NOT_CALLED"); return; }
            if (synthOpts.stallMs !== 600000) { console.log("BAD_STALLMS: " + JSON.stringify(synthOpts.stallMs)); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "synth agent() call carries stallMs=600000 (raises sandbox watchdog above 180s)"
    else
        fail "synth agent() call carries stallMs=600000 (raises sandbox watchdog above 180s)" \
            "$result"
    fi
}

# Same root cause as the synth stall, one stage over: the panel path's in-sandbox agents —
# the N opus panelists (panelVote) and the sonnet writer (panelWrite) — inherit the default
# 180s watchdog unless their agent() call carries stallMs. On a complex diff a panelist
# reasons past 180s, trips the watchdog, and is dropped by the `.catch(() => null)`, silently
# shrinking the panel until quorum fails. This test drives review-core in panel mode with a
# mock agent() that captures the panel-vote and panel-write opts and asserts stallMs=600000
# reaches both — a behavioural guard so a refactor cannot silently drop it and reintroduce
# the stall (matching the synth guard above).
test_panel_calls_set_stall_budget() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "panel stall budget" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const baseArgs = {
            agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
            orchestrationMode: "panel", panelSize: 3, panelBrief: "brief",
            changedLinesBlock: "",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        (async () => {
            let voteOpts = [];
            let writeOpts = null;
            const agent = async (prompt, opts) => {
                if (opts && opts.phase === "panel-vote") {
                    voteOpts.push(opts);
                    // Minimal valid panelist: one is_real:false vote, no raises.
                    return { votes: [], raised: [] };
                }
                if (opts && opts.phase === "panel-write") {
                    writeOpts = opts;
                    return { bodyText: "## Synthesiser Assessment\nok\n" };
                }
                // Specialist dispatch.
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            try { await run(agent, baseArgs); }
            catch (e) { console.log("THREW: " + e.message); return; }
            if (voteOpts.length === 0) { console.log("PANEL_VOTE_NOT_CALLED"); return; }
            const badVote = voteOpts.find(o => o.stallMs !== 600000);
            if (badVote) { console.log("BAD_VOTE_STALLMS: " + JSON.stringify(badVote.stallMs)); return; }
            if (writeOpts === null) { console.log("PANEL_WRITE_NOT_CALLED"); return; }
            if (writeOpts.stallMs !== 600000) { console.log("BAD_WRITE_STALLMS: " + JSON.stringify(writeOpts.stallMs)); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "panel-vote and panel-write agent() calls carry stallMs=600000 (raises sandbox watchdog above 180s)"
    else
        fail "panel-vote and panel-write agent() calls carry stallMs=600000 (raises sandbox watchdog above 180s)" \
            "$result"
    fi
}
