#!/usr/bin/env bash
# Per-cog I/O instrumentation tests. The first group calls buildLogPayload in
# isolation (strip-export + invoke). Later groups run review-core.mjs end-to-end
# with mock globals and assert on bundle.log.

_pe_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Invoke buildLogPayload(envelope, phaseLog) in isolation. $1 = envelope json,
# $2 = phaseLog json (optional, defaults to undefined). Emits the payload JSON.
# Uses the async-wrapper pattern (same as _op_run_core) so top-level await in
# review-core.mjs is valid; a sentinel inserted before resolvedArgs causes the
# async body to return before any agent() call is made.
_pe_build_log_payload() {
    local wf phaseLog runner
    wf="$(_pe_cr_dir)/workflows/review-core.mjs"
    phaseLog=''
    [ "$#" -ge 2 ] && phaseLog="$2"
    runner="$REPO_ROOT/tests/lib/_pe_runner.js"
    WF="$wf" PE_ENV="$1" PE_PHASELOG="$phaseLog" node "$runner" 2>&1
}

test_buildlogpayload_omits_cogs_when_no_phaselog() {
    local env out
    env='{"verdict":"APPROVE","rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":72,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> x\n"}'
    out=$(_pe_build_log_payload "$env")
    # Back-compat: no phaseLog → findings present, cogs/meta omitted.
    assert_equals "1" "$(echo "$out" | jq '.findings | length')" "findings still flattened with no phaseLog"
    assert_equals "null" "$(echo "$out" | jq -r '.cogs // "null"')" "cogs omitted when no phaseLog"
    assert_equals "null" "$(echo "$out" | jq -r '.meta // "null"')" "meta omitted when no phaseLog"
}

test_buildlogpayload_emits_meta_and_cogs() {
    local env pl out
    env='{"verdict":"APPROVE","rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> x\n"}'
    pl='{"meta":{"base":"main","head_sha":"abc123","empty_tree_mode":false,"path_scope":""},"cogs":[{"phase":"round1","domain":"correctness","output":{"findings":[]}}]}'
    out=$(_pe_build_log_payload "$env" "$pl")
    assert_equals "main" "$(echo "$out" | jq -r '.meta.base')" "meta.base passed through"
    assert_equals "abc123" "$(echo "$out" | jq -r '.meta.head_sha')" "meta.head_sha passed through"
    assert_equals "correctness" "$(echo "$out" | jq -r '.cogs[0].domain')" "cog domain passed through"
    assert_equals "round1" "$(echo "$out" | jq -r '.cogs[0].phase')" "cog phase passed through"
}
