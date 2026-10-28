#!/usr/bin/env bash
# Workflow-migration structural tests (schema validity, agent cross-refs,
# workflow meta + flag wiring, and the panel prompt/stall/routing wiring in review-core).

_wm_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Shared JS prelude for tests that drive the REAL review-core module with mock globals.
# Defines run(agent, args), a panel-shaped baseArgs, and capturePanel(args), which records
# every panel-vote prompt and the writer prompt while returning minimal valid outputs.
# Single-quoted so bash leaves it alone; the JS uses double quotes only.
_WM_JS_PRELUDE='
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8")
    .replace(/^export\s+const\s+meta/m, "const meta");
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
const baseArgs = {
    agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
    reviewMode: "pr", base: "main", headSha: "a".repeat(40),
    emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
    panelSize: 3, panelBrief: "brief", changedLinesBlock: "",
};
const capturePanel = async (args) => {
    const votePrompts = [];
    let writerPrompt = null;
    const agentTypes = [];
    const agent = async (prompt, opts) => {
        if (opts && opts.agentType) agentTypes.push(opts.agentType);
        if (opts && opts.phase === "panel-vote") { votePrompts.push(prompt); return { votes: [], raised: [] }; }
        if (opts && opts.phase === "panel-write") { writerPrompt = prompt; return { bodyText: "## Panel Assessment\nok\n" }; }
        return { status: "ok", findings: [] };
    };
    const bundle = await run(agent, args);
    return { votePrompts, writerPrompt, agentTypes, bundle };
};
'

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
    # Every $def the Workflow depends on must be present.
    local def
    for def in finding specialistOutput sealedBundle; do
        if jq -e --arg d "$def" '.["$defs"][$d]' "$schema" >/dev/null 2>&1; then
            pass "finding-schema.json defines \$defs.$def"
        else
            fail "finding-schema.json defines \$defs.$def" "definition missing"
        fi
    done
    # The classic synthesiser and cross-review envelopes were retired with classic orchestration.
    for def in synthEnvelope crossOpinionEnvelope; do
        if jq -e --arg d "$def" '.["$defs"][$d]' "$schema" >/dev/null 2>&1; then
            fail "finding-schema.json no longer defines \$defs.$def" \
                "classic orchestration is retired; nothing produces or consumes $def"
        else
            pass "finding-schema.json no longer defines \$defs.$def"
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

# Classic orchestration (cross-review + review-synthesiser + stall recovery) is retired: the
# panel is the only path. Its agent and include are deleted, review-core carries none of its
# dispatch tokens, and a stale `orchestrationMode: "classic"` arg is ignored — the run still
# votes through the panel and never dispatches a synthesiser or cross-reviewer.
test_classic_orchestration_removed() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    local gone
    for gone in agents/review-synthesiser.md includes/cross-review-mode.md; do
        if [[ -e "$cr/$gone" ]]; then
            fail "classic artefact deleted: $gone" "classic orchestration is retired; delete $gone"
        else
            pass "classic artefact deleted: $gone"
        fi
    done
    if [[ ! -f "$wf" ]]; then
        fail "review-core has no classic dispatch tokens" "missing: $wf"
        return
    fi
    local token
    for token in 'review-synthesiser' 'Mode: cross-review' 'synthDeferred' 'SYNTH_SCHEMA' 'CROSS_SCHEMA' 'orchestrationMode'; do
        if grep -qF "$token" "$wf"; then
            fail "review-core has no classic token: $token" "found '$token' in review-core.js"
        else
            pass "review-core has no classic token: $token"
        fi
    done
    local result
    result=$(node -e "$_WM_JS_PRELUDE"'
        (async () => {
            let cap;
            try { cap = await capturePanel({ ...baseArgs, orchestrationMode: "classic" }); }
            catch (e) { console.log("THREW: " + e.message); return; }
            if (cap.votePrompts.length !== 3) { console.log("PANEL_NOT_RUN: " + cap.votePrompts.length); return; }
            const classic = cap.agentTypes.filter(t => /synthesiser|cross/.test(t));
            if (classic.length) { console.log("CLASSIC_DISPATCH: " + classic.join(",")); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "a stale orchestrationMode=classic arg still runs the panel (no synthesiser/cross dispatch)"
    else
        fail "a stale orchestrationMode=classic arg still runs the panel (no synthesiser/cross dispatch)" \
            "$result"
    fi
}

# A workflow script cannot pass a raw `node --check`: `export const meta` is illegal in a
# CommonJS .js file, and a top-level `return` is illegal in an ES module, so node errors
# either way. The Workflow runtime strips `export` and wraps the body in an async function
# before running it; a faithful syntax check must do the same. This helper mirrors that
# transform.
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
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "review-core.js exists" "missing: $wf"
        return
    fi
    pass "review-core.js exists"
    if grep -qE "name: 'review-core'" "$wf"; then
        pass "review-core.js meta declares name review-core"
    else
        fail "review-core.js meta declares name review-core" "meta.name missing or wrong"
    fi
    if grep -qF 'description:' "$wf"; then
        pass "review-core.js meta declares a description"
    else
        fail "review-core.js meta declares a description" "meta.description missing"
    fi
    # Syntax validity via the runtime-faithful transform (NOT raw `node --check`).
    if _wm_syntax_ok "$wf"; then
        pass "review-core.js is syntactically valid (runtime-faithful check)"
    else
        fail "review-core.js is syntactically valid (runtime-faithful check)" \
            "the strip-export + async-wrap transform failed to parse the script"
    fi
}

# Claude Code registers a plugin's workflows from workflows/*.js only; a .mjs, .cjs or .ts
# file there is skipped without a warning, so it never becomes a named workflow.
test_plugin_workflows_use_registrable_extension() {
    local cr
    cr=$(_wm_cr_dir)
    local stray
    stray=$(find "$cr/workflows" -maxdepth 1 -type f \( -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' \))
    if [[ -z "$stray" ]]; then
        pass "plugin workflows use the .js extension Claude Code registers"
    else
        fail "plugin workflows use the .js extension Claude Code registers" \
            "Claude Code skips these, so they never register as named workflows: $stray"
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
        if grep -qF 'Workflow({ name: "code-review-suite:review-core", args: {' "$path"; then
            pass "host wires workflow flag: $file invokes the named workflow"
        else
            fail "host wires workflow flag: $file invokes the named workflow" \
                "Step 3.5 must call Workflow({ name: \"code-review-suite:review-core\", args: {...} }) in every pipeline copy — the Workflow is the only orchestration path"
        fi
        if grep -qE 'scriptPath:|REVIEW_CORE_PATH' "$path"; then
            fail "host wires workflow flag: $file has no scriptPath invocation" \
                "Claude Code refuses a plugin-cache scriptPath unless a read of it is already allowed; invoke by name instead"
        else
            pass "host wires workflow flag: $file has no scriptPath invocation"
        fi
    done
}

# Both hosts pre-approve the named workflow in frontmatter so the launch does not prompt.
# allowed-tools only pre-approves; it does not restrict the host's other tools.
test_hosts_preapprove_review_core_workflow() {
    local cr
    cr=$(_wm_cr_dir)
    local file
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if [[ ! -f "$path" ]]; then
            fail "host pre-approves review-core: $file" "file not found"
            continue
        fi
        local frontmatter
        frontmatter=$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside' "$path")
        if grep -qE '^allowed-tools:.*Workflow\(code-review-suite:review-core\)' <<< "$frontmatter"; then
            pass "host pre-approves review-core: $file"
        else
            fail "host pre-approves review-core: $file" \
                "frontmatter must carry allowed-tools: Workflow(code-review-suite:review-core) so the Step 3.5 launch is pre-approved"
        fi
    done
}

# Registered as a plugin workflow, review-core is also reachable as a bare slash command,
# which supplies no host-computed args (or a free-text string). It must return an inert
# bundle without dispatching any agent, rather than throwing on the missing fields.
test_review_core_bare_invocation_is_inert() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "review-core bare invocation" "missing: $wf"
        return
    fi
    local shape result
    for shape in undefined empty-object empty-string free-text; do
        result=$(node -e '
            const fs = require("fs");
            const src = fs.readFileSync(process.argv[1], "utf8")
                .replace(/^export\s+const\s+meta/m, "const meta");
            const shapes = { "undefined": undefined, "empty-object": {}, "empty-string": "", "free-text": "123 please" };
            let agentCalls = 0;
            const agent = async () => { agentCalls++; return null; };
            const parallel = (thunks) => Promise.all(thunks.map(t => t()));
            const noop = () => {};
            (async () => {
                let bundle;
                try {
                    const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                        "return (async()=>{" + src + "\n})()");
                    bundle = await fn(agent, parallel, async () => [], noop, noop, shapes[process.argv[2]], async () => null);
                } catch (e) { console.log("THREW: " + e.message); return; }
                if (agentCalls !== 0) { console.log("DISPATCHED " + agentCalls); return; }
                if (!bundle || bundle.verdict !== "NONE" || !Array.isArray(bundle.comments) || !bundle.bodyText) {
                    console.log("BADSHAPE " + JSON.stringify(bundle)); return;
                }
                console.log("OK");
            })();
        ' "$wf" "$shape" 2>&1)
        if [[ "$result" == "OK" ]]; then
            pass "review-core bare invocation ($shape args) returns an inert bundle"
        else
            fail "review-core bare invocation ($shape args) returns an inert bundle" \
                "expected verdict NONE, no agent dispatch and no throw; got: $result"
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
# structural test asserts the inlined SPECIALIST_SCHEMA stays a faithful $ref-flattened
# equivalent of includes/finding-schema.json's specialistOutput. We slice the script prefix
# (the schema consts precede the `const resolvedArgs = ...` args normaliser), eval it to
# recover SPECIALIST_SCHEMA, flatten the canonical's `#/$defs/finding` $refs the same way, and
# deep-compare. The cut anchors on `const resolvedArgs` because the normaliser reads the
# unbound `args` global, which would throw in the schema-only extract harness. PANEL_SCHEMA
# and WRITER_SCHEMA are panel-local and deliberately outside the canonical schema. The eval
# input is the repo's own committed source — same trust level as the syntax gate above.
test_inlined_schema_matches_canonical() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    local schema="$cr/includes/finding-schema.json"
    if [[ ! -f "$wf" || ! -f "$schema" ]]; then
        fail "inlined schema parity" "review-core.js or finding-schema.json missing"
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
        const extract = new Function(prefix + "\nreturn { SPECIALIST_SCHEMA };");
        const { SPECIALIST_SCHEMA } = extract();
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
        if (eq(SPECIALIST_SCHEMA, flatten(canon["$defs"].specialistOutput))) { console.log("OK"); }
        else { console.log("MISMATCH specialist"); }
    ' "$wf" "$schema" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "inlined schema parity: SPECIALIST_SCHEMA matches finding-schema.json specialistOutput"
    else
        fail "inlined schema parity: SPECIALIST_SCHEMA matches finding-schema.json specialistOutput" \
            "the inlined schema literal drifted from the canonical \$ref-flattened def: $result"
    fi
}

# Category C resilience: an agent() that resolves successfully with null (the documented
# ~30% empty-stdout failure mode) must not crash any dispatch site — the specialists, the
# panelists or the writer. We eval the full script body with mock globals — mock agent()
# always returns null — and assert the workflow returns a bundle rather than throwing.
test_review_core_survives_null_agent_results() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
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
    local wf="$cr/workflows/review-core.js"
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

# The intent ledger must be threaded from args into every panel-vote prompt: panelists
# decide `blocks_goal` against it, and without it verdict-rubric row 1 can never fire.
# With no ledger, no ledger text may leak in.
test_review_core_threads_intent_ledger_to_panel() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "review-core intent-ledger threading" "missing: $wf"
        return
    fi
    if grep -qE 'intentLedger,' "$wf" || grep -qE 'intentLedger\s*\}' "$wf"; then
        pass "review-core destructures intentLedger from args"
    else
        fail "review-core destructures intentLedger from args" \
            "the args destructure must include intentLedger so the panel prompt can reference it"
    fi
    local result
    result=$(node -e "$_WM_JS_PRELUDE"'
        (async () => {
            const LEDGER = "## Intent ledger\ngoal: ship the widget exporter";
            let withL, without;
            try {
                withL = await capturePanel({ ...baseArgs, intentLedger: LEDGER });
                without = await capturePanel({ ...baseArgs, intentLedger: "" });
            } catch (e) { console.log("THREW: " + e.message); return; }
            if (withL.votePrompts.length !== 3) { console.log("VOTE_COUNT: " + withL.votePrompts.length); return; }
            if (!withL.votePrompts.every(p => p.includes(LEDGER))) { console.log("LEDGER_MISSING"); return; }
            if (without.votePrompts.some(p => p.includes("goal:"))) { console.log("LEDGER_LEAKED_WHEN_ABSENT"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "every panel-vote prompt carries the intent ledger (and none when it is absent)"
    else
        fail "every panel-vote prompt carries the intent ledger (and none when it is absent)" "$result"
    fi
}

# repoDir must reach every panel-vote prompt so a panelist reads surrounding code in the
# target repository (not cwd) when the review targets a PR in another checkout. Specialists
# receive repoDir via the host-built agentPrompt; the panel prompt is built inside review-core,
# so it needs its own injection. The line is omitted when no target repo was supplied.
test_review_core_threads_repo_dir_to_panel() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "review-core repoDir threading" "missing: $wf"
        return
    fi
    if grep -qE 'repoDir,' "$wf" || grep -qE 'repoDir\s*\}' "$wf"; then
        pass "review-core destructures repoDir from args"
    else
        fail "review-core destructures repoDir from args" \
            "the args destructure must include repoDir so the panel prompt can target the right repo"
    fi
    local result
    result=$(node -e "$_WM_JS_PRELUDE"'
        (async () => {
            let withR, without;
            try {
                withR = await capturePanel({ ...baseArgs, repoDir: "/repos/target" });
                without = await capturePanel({ ...baseArgs });
            } catch (e) { console.log("THREW: " + e.message); return; }
            if (withR.votePrompts.length !== 3) { console.log("VOTE_COUNT: " + withR.votePrompts.length); return; }
            if (!withR.votePrompts.every(p => p.includes("Repo dir: /repos/target\n"))) { console.log("REPO_DIR_MISSING"); return; }
            if (without.votePrompts.some(p => p.includes("Repo dir:"))) { console.log("REPO_DIR_LINE_WHEN_ABSENT"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "every panel-vote prompt carries the Repo dir line (and none when repoDir is absent)"
    else
        fail "every panel-vote prompt carries the Repo dir line (and none when repoDir is absent)" "$result"
    fi
}

# PR D: panelists read the pinned diff from a "Full diff file:" line rather than re-running
# git. The panel prompt is assembled inside review-core, so the line is derived from tempDir
# + the Step 2.85 filename (review-pipeline.md writes $RESOLVED_TEMP_DIR/review-diff.patch).
# Drive the REAL module with a trailing-slash tempDir (the join must not double the slash)
# and with no tempDir (the line must be omitted, not point at a bogus path).
test_review_core_threads_full_diff_file_to_panel() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "review-core full-diff-file threading" "missing: $wf"
        return
    fi
    if grep -qE 'review-diff\.patch' "$wf"; then
        pass "review-core derives the diff path from the Step 2.85 filename"
    else
        fail "review-core derives the diff path from the Step 2.85 filename" \
            "the diff path must reference review-diff.patch (the artifact review-pipeline.md Step 2.85 writes)"
    fi
    local result
    result=$(node -e "$_WM_JS_PRELUDE"'
        (async () => {
            let withT, without;
            try {
                withT = await capturePanel({ ...baseArgs, tempDir: "/tmp/claude-abc/" });
                without = await capturePanel({ ...baseArgs, tempDir: "" });
            } catch (e) { console.log("THREW: " + e.message); return; }
            if (withT.votePrompts.length !== 3) { console.log("VOTE_COUNT: " + withT.votePrompts.length); return; }
            const bad = withT.votePrompts.find(p => !p.includes("Full diff file: /tmp/claude-abc/review-diff.patch"));
            if (bad) { console.log("MISSING_OR_BAD_LINE: " + (bad.match(/Full diff file:.*/) || ["<absent>"])[0]); return; }
            if (withT.votePrompts.some(p => p.includes("//review-diff"))) { console.log("DOUBLE_SLASH"); return; }
            if (without.votePrompts.some(p => p.includes("Full diff file:"))) { console.log("LINE_WITHOUT_TEMPDIR"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "every panel-vote prompt carries a clean Full diff file line (and none without tempDir)"
    else
        fail "every panel-vote prompt carries a clean Full diff file line (and none without tempDir)" "$result"
    fi
}

# The panel's in-sandbox agents — the N opus panelists (panelVote) and the sonnet writer
# (panelWrite) — inherit the sandbox's default 180s no-progress watchdog unless their agent()
# call carries stallMs. On a complex diff a panelist reasons past 180s, trips the watchdog,
# and is dropped by the `.catch(() => null)`, silently shrinking the panel until quorum fails.
# The watchdog binds a per-agent()-call `stallMs` option, so this test drives review-core
# with a mock agent() that captures the panel-vote and panel-write opts and asserts
# stallMs=600000 reaches both — a behavioural guard so a refactor cannot silently drop it.
test_panel_calls_set_stall_budget() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "panel stall budget" "missing: $wf"
        return
    fi
    local result
    result=$(node -e "$_WM_JS_PRELUDE"'
        (async () => {
            const voteOpts = [];
            let writeOpts = null;
            const agent = async (prompt, opts) => {
                if (opts && opts.phase === "panel-vote") { voteOpts.push(opts); return { votes: [], raised: [] }; }
                if (opts && opts.phase === "panel-write") { writeOpts = opts; return { bodyText: "## Panel Assessment\nok\n" }; }
                return { status: "ok", findings: [] };
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

# Housekeeper findings audit the whole touched project, so their manifest is often outside
# the diff. They must bypass the voted-line guard (keeping file + line for the table) and
# route to posting 'table': rendered in the Dependency Freshness section, never posted
# inline, forced to Suggestion, and never verdict-relevant — even when the panel votes one
# Important. A non-housekeeper finding on the same out-of-diff anchor proves the guard is
# still active for everyone else (its file and line are cleared).
test_housekeeper_findings_bypass_line_guard_and_route_to_table() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.js"
    if [[ ! -f "$wf" ]]; then
        fail "housekeeper table routing" "missing: $wf"
        return
    fi
    local result
    result=$(node -e "$_WM_JS_PRELUDE"'
        const HK = [
            { file: ".github/workflows/ci.yml", line: 12, severity: "Suggestion", confidence: 100,
              description: "actions/checkout is at v3; latest GA is v4.", suggested_fix: "Bump to v4." },
            { file: "package.json", line: 7, severity: "Suggestion", confidence: 100,
              description: "lodash is at 4.17.20; latest GA is 4.17.21. Deprecated upstream.", suggested_fix: "Bump." },
        ];
        const CORR = [
            { file: ".github/workflows/ci.yml", line: 12, severity: "Suggestion", confidence: 80,
              description: "Step name is misleading.", suggested_fix: "Rename it." },
        ];
        const agent = async (prompt, opts) => {
            if (opts && opts.phase === "panel-vote") {
                const flat = JSON.parse(prompt.split("by finding_id):\n")[1]);
                return {
                    votes: flat.map(f => ({
                        finding_id: f.finding_id, is_real: true,
                        severity: f.domain === "housekeeper" ? "Important" : "Suggestion",
                        tractability: "Bounded", blocks_goal: false, rationale: "r",
                    })),
                    raised: [],
                };
            }
            if (opts && opts.phase === "panel-write") return { bodyText: "## Panel Assessment\nok\n" };
            if (opts && opts.agentType === "code-review-suite:housekeeper-reviewer") return { status: "ok", findings: HK };
            if (opts && opts.agentType === "code-review-suite:correctness-reviewer") return { status: "ok", findings: CORR };
            return { status: "ok", findings: [] };
        };
        (async () => {
            let b;
            try {
                b = await run(agent, { ...baseArgs, flags: { housekeeping: true },
                    changedLinesBlock: "Changed lines:\nsrc/a.js: 1-5" });
            } catch (e) { console.log("THREW: " + e.message); return; }
            if (b.verdict !== "APPROVE") { console.log("VERDICT: " + b.verdict); return; }
            if (b.comments.length !== 0) { console.log("COMMENTS: " + JSON.stringify(b.comments)); return; }
            const hk = b.log.findings.filter(f => f.domain === "housekeeper");
            if (hk.length !== 2) { console.log("HK_COUNT: " + hk.length); return; }
            for (const f of hk) {
                if (f.tier !== "contested" || f.posting !== "table" || f.severity !== "Suggestion" || f.verdict_relevant !== false) {
                    console.log("HK_ROUTE: " + JSON.stringify(f)); return;
                }
            }
            const ci = hk.find(f => f.description.startsWith("actions/checkout"));
            if (!ci || ci.file !== ".github/workflows/ci.yml" || ci.line !== 12) { console.log("HK_ANCHOR_LOST: " + JSON.stringify(ci)); return; }
            const corr = b.log.findings.find(f => f.domain === "correctness");
            if (!corr || corr.file !== "" || corr.line !== 0) { console.log("GUARD_INACTIVE: " + JSON.stringify(corr)); return; }
            const body = b.bodyText;
            if (!body.includes("### Dependency Freshness")) { console.log("NO_FRESHNESS_SECTION"); return; }
            if (!body.includes("| actions/checkout | v3 | v4 | `.github/workflows/ci.yml:12` |  |")) { console.log("BAD_CI_ROW"); return; }
            if (!body.includes("| lodash | 4.17.20 | 4.17.21 | `package.json:7` | Deprecated upstream. |")) { console.log("BAD_LODASH_ROW"); return; }
            if (/### Findings[\s\S]*actions\/checkout/.test(body.split("### Dependency Freshness")[0])) { console.log("HK_IN_INDEX"); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "housekeeper findings keep their out-of-diff anchor, route to the freshness table and never block"
    else
        fail "housekeeper findings keep their out-of-diff anchor, route to the freshness table and never block" \
            "$result"
    fi
}
