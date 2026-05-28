#!/usr/bin/env bash
# Schema validation tests for tests/ab/corpus/.
# Test cases are added in Tasks 7 and 9 once corpus/ has fixtures to validate.

test_ab_corpus_index_present_or_absent_consistently() {
    # Until Task 7 lands a fixture, corpus/ contains only .gitkeep. After
    # Task 7, corpus/index.yaml must exist and be valid YAML. Asserting
    # "either both index and at least one fixture, or neither" keeps the
    # placeholder period structurally sound.
    local index="$REPO_ROOT/tests/ab/corpus/index.yaml"
    local fixtures
    fixtures=$(find "$REPO_ROOT/tests/ab/corpus" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')

    if [[ ! -f "$index" && "$fixtures" == "0" ]]; then
        pass "A/B corpus: index absent and no fixtures yet (scaffold state)"
        return
    fi

    if [[ -f "$index" && "$fixtures" -gt 0 ]]; then
        if yq '.' "$index" >/dev/null 2>&1; then
            pass "A/B corpus: index.yaml present and parses"
        else
            fail "A/B corpus: index.yaml present and parses" "yq failed to parse $index"
        fi
        return
    fi

    fail "A/B corpus: index and fixtures consistent" \
        "found index.yaml=$( [[ -f "$index" ]] && echo yes || echo no ) and $fixtures fixture dir(s) — must be both or neither"
}
