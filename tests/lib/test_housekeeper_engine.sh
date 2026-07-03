#!/usr/bin/env bash
# tests/lib/test_housekeeper_engine.sh — runs the Python engine unittest
# suite as one gate inside the bash harness (run.sh auto-discovers this).

test_housekeeper_engine_unittest() {
    local repo="$REPO_ROOT"
    local suite="$repo/tests/python"

    if [[ ! -d "$suite" ]]; then
        skip "housekeeper engine unittest" "tests/python not present"
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        skip "housekeeper engine unittest" "python3 not on PATH"
        return
    fi

    local output
    if output=$(cd "$repo" && python3 -m unittest discover -s tests/python 2>&1); then
        pass "housekeeper engine unittest: all engine unit tests pass"
    else
        fail "housekeeper engine unittest: all engine unit tests pass" "$output"
    fi
}
