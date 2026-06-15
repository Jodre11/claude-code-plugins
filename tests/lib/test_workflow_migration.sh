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
    # The four $defs the migration depends on must all be present.
    local def
    for def in finding specialistOutput synthEnvelope sealedBundle; do
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
        if grep -qF "workflow('review-core'" "$path"; then
            pass "host wires workflow flag: $file calls workflow('review-core')"
        else
            fail "host wires workflow flag: $file calls workflow('review-core')" \
                "the Step 3.5 routing gate must call workflow('review-core', ...) in every pipeline copy"
        fi
    done
}

# R2-B: the script inlines the schema (import() is unavailable in the sandbox), so a
# structural test asserts the inlined literals stay a faithful $ref-flattened equivalent
# of includes/finding-schema.json. We slice the script prefix (the schema consts precede
# the `const {...} = args` destructure), eval it to recover SPECIALIST_SCHEMA / SYNTH_SCHEMA,
# flatten the canonical's `#/$defs/finding` $refs the same way, and deep-compare. The eval
# input is the repo's own committed source — same trust level as the syntax gate above.
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
        const cut = wf.indexOf("const {");
        if (cut < 0) { console.log("ERR: args destructure not found"); process.exit(1); }
        const prefix = wf.slice(0, cut).replace(/^export\s+const\s+meta/m, "const meta");
        const extract = new Function(prefix + "\nreturn { SPECIALIST_SCHEMA, SYNTH_SCHEMA };");
        const { SPECIALIST_SCHEMA, SYNTH_SCHEMA } = extract();
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
        const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        const sOk = eq(SPECIALIST_SCHEMA, flatten(canon["$defs"].specialistOutput));
        const yOk = eq(SYNTH_SCHEMA, flatten(canon["$defs"].synthEnvelope));
        if (sOk && yOk) { console.log("OK"); }
        else { console.log("MISMATCH specialist=" + sOk + " synth=" + yOk); }
    ' "$wf" "$schema" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "inlined schema parity: SPECIALIST_SCHEMA + SYNTH_SCHEMA match finding-schema.json"
    else
        fail "inlined schema parity: SPECIALIST_SCHEMA + SYNTH_SCHEMA match finding-schema.json" \
            "the inlined schema literals drifted from the canonical \$ref-flattened defs: $result"
    fi
}
