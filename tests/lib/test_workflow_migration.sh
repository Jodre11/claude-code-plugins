#!/usr/bin/env bash
# Workflow-migration structural tests (schema validity, agent cross-refs, workflow meta and
# flag wiring, and the native dispatch and housekeeper routing in review-core).

_wm_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Shared JS prelude for tests that drive the REAL review-core module with mock globals.
# Defines run(agent, args) and a thin-shaped baseArgs whose nativeTarget passes the shape check.
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
    agentPrompt: "x", flags: {}, reviewMode: "pr", base: "main", headSha: "a".repeat(40),
    emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x", repoDir: "/tmp/fx-repo",
    changedLinesBlock: "", cliVersion: "x",
    nativeTarget: "/tmp/fx-repo " + "b".repeat(40) + "..." + "a".repeat(40),
};
const nativeText = (arr) => "Done.\n\n```json\n" + JSON.stringify(arr) + "\n```";
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
    # pre-thin-args: an old host's args (route, no nativeTarget) are refused the same way.
    for shape in undefined empty-object empty-string free-text pre-thin-args; do
        result=$(node -e '
            const fs = require("fs");
            const src = fs.readFileSync(process.argv[1], "utf8")
                .replace(/^export\s+const\s+meta/m, "const meta");
            const shapes = { "undefined": undefined, "empty-object": {}, "empty-string": "", "free-text": "123 please",
                "pre-thin-args": { agentPrompt: "x", flags: {}, route: "full", reviewMode: "pr" } };
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
# empty-stdout failure mode) must not crash any dispatch site — native, the static
# specialists or the editor. Mock agent() always returns null; the workflow must still
# return a bundle, and a null native result is "native did not run" (verdict NONE).
test_review_core_survives_null_agent_results() {
    local wf result
    wf="$(_wm_cr_dir)/workflows/review-core.js"
    result=$(node -e "$_WM_JS_PRELUDE"'
        const agent = async () => null;
        (async () => {
            for (const mode of ["local", "pr"]) {
                let b;
                try { b = await run(agent, { ...baseArgs, reviewMode: mode, flags: { py: true, csharp: true } }); }
                catch (e) { console.log("THREW(" + mode + "): " + e.message); return; }
                if (!b || typeof b !== "object") { console.log("NOBUNDLE(" + mode + ")"); return; }
                if (!("verdict" in b) || !("comments" in b)) { console.log("BADSHAPE(" + mode + ")"); return; }
                if (b.verdict !== "NONE" || b.native.ran !== false) { console.log("NOT_NONE(" + mode + "): " + b.verdict); return; }
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

# Production bug regression (2026-06-16): the Workflow tool delivers args as a JSON STRING,
# not an object. The resolvedArgs normaliser must JSON.parse a string arg so the script runs
# unchanged; destructuring a string would leave flags undefined.
test_review_core_accepts_string_args() {
    local wf result
    wf="$(_wm_cr_dir)/workflows/review-core.js"
    result=$(node -e "$_WM_JS_PRELUDE"'
        const seen = [];
        const agent = async (prompt, opts) => { seen.push(opts.label); return opts.label === "native" ? nativeText([]) : null; };
        (async () => {
            let b;
            try { b = await run(agent, JSON.stringify({ ...baseArgs, reviewMode: "local", flags: { csharp: true } })); }
            catch (e) { console.log("THREW: " + e.message); return; }
            if (!b || !("verdict" in b) || !("comments" in b)) { console.log("BADSHAPE"); return; }
            if (!seen.includes("jbinspect") || b.native.ran !== true) { console.log("ARGS_LOST: " + seen.join(",")); return; }
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

# The native wrapper is silent while the bundled skill runs, so its dispatch raises the
# sandbox's 180 s no-progress watchdog to 600 s. It carries no schema: a schema leaks into the
# skill's fork and the result is lost (spec, spike S1).
test_native_dispatch_stall_budget_and_no_schema() {
    local wf result
    wf="$(_wm_cr_dir)/workflows/review-core.js"
    result=$(node -e "$_WM_JS_PRELUDE"'
        let nat = null;
        const agent = async (prompt, opts) => {
            if (opts.label === "native") { nat = opts; return nativeText([]); }
            return { status: "ok", findings: [] };
        };
        (async () => {
            try { await run(agent, baseArgs); } catch (e) { console.log("THREW: " + e.message); return; }
            if (!nat) { console.log("NOT_DISPATCHED"); return; }
            if (nat.stallMs !== 600000) { console.log("STALL: " + nat.stallMs); return; }
            if ("schema" in nat) { console.log("HAS_SCHEMA"); return; }
            if (nat.agentType !== "code-review-suite:native-reviewer") { console.log("TYPE: " + nat.agentType); return; }
            if ("model" in nat) { console.log("PINNED_MODEL: " + nat.model); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "native dispatch: native-reviewer type, stallMs 600000, no schema, no model pin"
    else
        fail "native dispatch: native-reviewer type, stallMs 600000, no schema, no model pin" "$result"
    fi
    if grep -qE '^model:' "$(_wm_cr_dir)/agents/native-reviewer.md"; then
        fail "native-reviewer pins no model" "native's fork inherits the wrapper's model, so the agent must not pin one"
    else
        pass "native-reviewer pins no model"
    fi
}

# Housekeeper findings audit the whole touched project, so their manifest is often outside
# the diff. They bypass the anchor guard (keeping file + line for the table) and route to
# posting 'table': rendered in the Dependency Freshness section, never posted inline and never
# blocking, even labelled Important. A native finding on the same out-of-diff anchor proves the
# guard is still active for everyone else (it moves to the body).
test_housekeeper_findings_bypass_line_guard_and_route_to_table() {
    local wf result
    wf="$(_wm_cr_dir)/workflows/review-core.js"
    result=$(node -e "$_WM_JS_PRELUDE"'
        const HK = [
            { file: ".github/workflows/ci.yml", line: 12, severity: "Important",
              description: "actions/checkout is at v3; latest GA is v4.", suggested_fix: "Bump to v4." },
            { file: "package.json", line: 7, severity: "Suggestion",
              description: "lodash is at 4.17.20; latest GA is 4.17.21. Deprecated upstream.", suggested_fix: "Bump." },
        ];
        const NAT = [{ file: ".github/workflows/ci.yml", line: 12, summary: "Step name is misleading.",
            failure_scenario: "A reader is misled.", severity: "nit" }];
        const agent = async (prompt, opts) => {
            if (opts.label === "native") return nativeText(NAT);
            if (opts.agentType === "code-review-suite:housekeeper-reviewer") return { status: "ok", findings: HK };
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
            const hk = b.log.findings.filter(f => f.source === "housekeeper");
            if (hk.length !== 2) { console.log("HK_COUNT: " + hk.length); return; }
            for (const f of hk) {
                if (f.posting !== "table" || f.blocking !== false || f.verdict_relevant !== false) {
                    console.log("HK_ROUTE: " + JSON.stringify(f)); return;
                }
            }
            const ci = hk.find(f => f.description.startsWith("actions/checkout"));
            if (!ci || ci.file !== ".github/workflows/ci.yml" || ci.line !== 12) { console.log("HK_ANCHOR_LOST: " + JSON.stringify(ci)); return; }
            const nat = b.log.findings.find(f => f.source === "native");
            if (!nat || nat.file !== "" || nat.line !== 0) { console.log("GUARD_INACTIVE: " + JSON.stringify(nat)); return; }
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
