#!/usr/bin/env bash
# Behavioural smoke test for static-analysis specialists.
#
# Gated by CLAUDE_CODE_E2E_TESTS=1 — dispatches real Agent calls, costs tokens, takes
# minutes. Stage 2 of the static-analysis specialists spec executes it; CI runs it on a
# schedule, not on every PR.
#
# The test asserts canonical wording from includes/static-analysis-context.md appears
# verbatim in each specialist's observable output:
#   - "Skipped — <tool> not available on PATH." for the PATH-miss branch
#   - "0 findings — no <lang> files in diff." for the empty-diff branch
#   - "Confidence: 100" literal on every finding
#   - Output begins with "## <Tool name> Findings"
#
# Three iterations per specialist, all-pass required. If ≥ 1 specialist fails
# persistently, the spec's rollback applies: convert ALL FOUR static-analysis
# specialists to inline-with-sync-test.

test_static_analysis_behavioural_smoke() {
    if [[ "${CLAUDE_CODE_E2E_TESTS:-0}" != "1" ]]; then
        skip "static-analysis behavioural smoke" "set CLAUDE_CODE_E2E_TESTS=1 to run"
        return
    fi

    local fixture_root="$REPO_ROOT/tests/fixtures/static-analysis"
    if [[ ! -d "$fixture_root" ]]; then
        fail "static-analysis behavioural smoke" "fixture root missing: $fixture_root"
        return
    fi

    # Each specialist has three sub-checks (PATH-miss, no-files, normal run) × three
    # iterations. The actual Agent({...}) dispatches happen in the body — this scaffold
    # is intentionally a placeholder; Stage 2 implements the dispatch + output capture
    # under live Claude Code.
    pass "static-analysis behavioural smoke: scaffold present (Stage 2 implements live dispatch)"
}
