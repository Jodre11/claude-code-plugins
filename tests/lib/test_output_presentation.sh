#!/usr/bin/env bash
# Output-presentation tests: schema relaxation, log payload, anchor ladder,
# body construction, dependency reformat. review-core.mjs logic is exercised by
# evaluating the whole script with mock globals (see _op_run_core below).

_op_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

test_finding_file_is_optional() {
    local cr
    cr=$(_op_cr_dir)
    local schema="$cr/includes/finding-schema.json"
    # `file` MUST NOT be in finding.required (fileless findings are valid).
    if jq -e '.["$defs"].finding.required | index("file")' "$schema" >/dev/null 2>&1; then
        fail "finding.file is optional" "file still listed in finding.required"
    else
        pass "finding.file is optional (not in required)"
    fi
    # `file` MUST still be a declared property (optional, not removed).
    if jq -e '.["$defs"].finding.properties.file' "$schema" >/dev/null 2>&1; then
        pass "finding.file still a declared property"
    else
        fail "finding.file still a declared property" "file property was removed entirely"
    fi
    # sealedBundle.comments items document the optional subjectType discriminator.
    if jq -e '.["$defs"].sealedBundle.properties.comments.items.properties.subjectType' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.comments[].subjectType documented"
    else
        fail "sealedBundle.comments[].subjectType documented" "missing optional file-level anchor discriminator"
    fi
    # sealedBundle documents the log payload field.
    if jq -e '.["$defs"].sealedBundle.properties.log' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.log documented"
    else
        fail "sealedBundle.log documented" "missing log payload field"
    fi
}
