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
