#!/usr/bin/env bash
# Unit tests for the observe-mode reviewer-dispatch hook.
_dh_hook() { echo "$REPO_ROOT/plugins/code-review-suite/hooks/reviewer-dispatch-observe.sh"; }

test_observe_logs_main_session_reviewer_dispatch() {
    local log out
    log="$(mktemp)"
    out=$(printf '{"tool_input":{"subagent_type":"code-review-suite:security-reviewer"}}' \
        | CLAUDE_REVIEW_OBSERVE_LOG="$log" bash "$(_dh_hook)"; echo "exit=$?")
    assert_matches 'exit=0' "$out" "observe hook always exits 0"
    assert_equals "1" "$(wc -l < "$log" | tr -d ' ')" "main-session reviewer dispatch logged once"
    rm -f "$log"
}

test_observe_ignores_subagent_originated_dispatch() {
    local log out
    log="$(mktemp)"
    printf '{"agent_type":"code-review-suite:review-synthesiser","tool_input":{"subagent_type":"code-review-suite:security-reviewer"}}' \
        | CLAUDE_REVIEW_OBSERVE_LOG="$log" bash "$(_dh_hook)" >/dev/null
    assert_equals "0" "$(wc -l < "$log" | tr -d ' ')" "subagent-originated dispatch NOT logged (agent_type present)"
    rm -f "$log"
}

test_observe_ignores_non_reviewer_agent() {
    local log
    log="$(mktemp)"
    printf '{"tool_input":{"subagent_type":"Explore"}}' \
        | CLAUDE_REVIEW_OBSERVE_LOG="$log" bash "$(_dh_hook)" >/dev/null
    assert_equals "0" "$(wc -l < "$log" | tr -d ' ')" "non-reviewer main-session dispatch NOT logged"
    rm -f "$log"
}
