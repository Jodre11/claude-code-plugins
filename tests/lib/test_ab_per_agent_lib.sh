#!/usr/bin/env bash
# Unit tests for the per-agent A/B harness lib helpers
# (agent_dispatch.sh, fixture.sh, agent_capture.sh).
# Test cases are added in Tasks 4-6.

# Smoke test: the three lib files exist and pass the same shape checks as
# the Phase 1 lib files (shebang, strict mode). Without this, an empty test
# file would silently contribute zero assertions to tests/run.sh.

test_ab_per_agent_lib_files_exist() {
    local f
    for f in tests/ab/lib/agent_dispatch.sh tests/ab/lib/fixture.sh tests/ab/lib/agent_capture.sh; do
        if [[ -f "$REPO_ROOT/$f" ]]; then
            pass "A/B per-agent: $f present"
        else
            fail "A/B per-agent: $f present" "missing"
        fi
    done
}

test_ab_per_agent_lib_files_use_strict_mode() {
    local f rel
    for f in "$REPO_ROOT"/tests/ab/lib/agent_dispatch.sh "$REPO_ROOT"/tests/ab/lib/fixture.sh "$REPO_ROOT"/tests/ab/lib/agent_capture.sh; do
        if [[ ! -f "$f" ]]; then
            continue
        fi
        rel="${f#"$REPO_ROOT/"}"
        if head -10 "$f" | grep -qE '^set -euo pipefail$'; then
            pass "A/B per-agent: $rel uses set -euo pipefail"
        else
            fail "A/B per-agent: $rel uses set -euo pipefail" \
                "every per-agent lib file must declare strict mode"
        fi
    done
}
