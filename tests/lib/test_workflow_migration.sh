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
