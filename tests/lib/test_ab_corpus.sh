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

test_ab_corpus_smoke_fixture_required_keys_present() {
    local source_yaml="$REPO_ROOT/tests/ab/corpus/ruff-smoke-bad-py/source.yaml"
    if [[ ! -f "$source_yaml" ]]; then
        fail "A/B corpus: smoke source.yaml present" "missing"
        return
    fi

    local key
    for key in id agent captured_at captured_under working_dir_strategy intent_ledger depends_on; do
        if [[ "$(yq "has(\"$key\")" "$source_yaml")" == "true" ]]; then
            pass "A/B corpus: smoke source.yaml has $key"
        else
            fail "A/B corpus: smoke source.yaml has $key" "missing required key"
        fi
    done
}

test_ab_corpus_index_includes_smoke_fixture() {
    local index="$REPO_ROOT/tests/ab/corpus/index.yaml"
    if [[ ! -f "$index" ]]; then
        fail "A/B corpus: index.yaml present" "missing"
        return
    fi

    local ids
    ids=$(yq -r '.fixtures[].id' "$index")
    if echo "$ids" | grep -qE '^ruff-smoke-bad-py$'; then
        pass "A/B corpus: index.yaml lists ruff-smoke-bad-py"
    else
        fail "A/B corpus: index.yaml lists ruff-smoke-bad-py" "ids=$ids"
    fi
}

test_ab_corpus_smoke_depends_on_paths_resolve() {
    local source_yaml="$REPO_ROOT/tests/ab/corpus/ruff-smoke-bad-py/source.yaml"
    if [[ ! -f "$source_yaml" ]]; then
        fail "A/B corpus: smoke source.yaml present" "missing"
        return
    fi

    local path missing=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if [[ ! -e "$REPO_ROOT/$path" ]]; then
            missing+=("$path")
        fi
    done < <(yq -r '.depends_on[]' "$source_yaml")

    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "A/B corpus: smoke depends_on paths all resolve"
    else
        fail "A/B corpus: smoke depends_on paths all resolve" "missing: ${missing[*]}"
    fi
}
