#!/usr/bin/env bash
# Comment-voice tests: the review-core wording pass (voicePass and its guards) and the
# `<!-- code-review-suite -->` marker on every bundle shape. review-core.js runs end to end
# through tests/lib/_tc_runner.js: native returns a fixture finding, ruff returns a static one,
# and the comment-editor returns a fixture edit.

_CV_MARKER='<!-- code-review-suite -->'
_CV_CHANGED='Changed lines:\na.cs: 1-60\nb.py: 1-20\n'
_CV_REPO='/tmp/fx-repo'
_CV_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

_cv_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Review args. $1 review mode (pr|local).
_cv_args() {
    local mode="${1:-pr}"
    jq -cn --arg mode "$mode" --arg cl "$(printf '%b' "$_CV_CHANGED")" --arg r "$_CV_REPO" --arg h "$_CV_SHA" \
        '{agentPrompt: "x", flags: {py: true}, reviewMode: $mode, base: "main", headSha: $h,
          emptyTreeMode: false, pathScope: "", tempDir: "/tmp/claude-test/x", repoDir: $r,
          changedLinesBlock: $cl, nativeTarget: ($r + " " + ("b" * 40) + "..." + $h), cliVersion: "x"}'
}

# Native's result text (a JSON string literal) for a findings array ($1).
_cv_native_text() {
    jq -cn --arg a "$1" '"Done.\n\n```json\n" + $a + "\n```"'
}

# Runs review-core. $1 args, $2 native findings array json, $3 specialists json, $4 editor json
# (or THROW). A native array of the literal word NOTRUN makes native fail.
_cv_run() {
    local native
    if [[ "$2" == NOTRUN ]]; then native='"SKILL_ERROR: test"'; else native=$(_cv_native_text "$2"); fi
    WF="$(_cv_cr_dir)/workflows/review-core.js" TC_ARGS="$1" TC_NATIVE="$native" TC_SPECIALISTS="${3:-{\}}" \
        TC_EDITOR="${4:-null}" node "$REPO_ROOT/tests/lib/_tc_runner.js" 2>&1 || true
}

_cv_ok() {
    if echo "$1" | jq -e '.bundle.verdict' >/dev/null 2>&1; then
        return 0
    fi
    fail "$2: valid run" "probe: ${1:0:200}"
    return 1
}

_CV_DESC='Null dereference of `order.Customer` in a.cs:10 crashes checkout for guest users. See https://example.com/issue.'
_CV_FIX=$'Return early:\n\n```cs\nif (order.Customer is null) return;\n```'

# One native finding at a.cs:10 (edited) whose summary splits into $_CV_DESC and $_CV_FIX.
_cv_nat() {
    jq -cn --arg s "$_CV_DESC Fix: $_CV_FIX" \
        '[{file: "a.cs", line: 10, summary: $s, failure_scenario: "A guest checks out and the request fails.", severity: "important"}]'
}

# One ruff finding at b.py:3 (static, never sent to the editor).
_cv_specs() {
    jq -cn '{ruff: [{file: "b.py", line: 3, rule_id: "F401", severity: "Important",
        description: "`os` imported but unused.", suggested_fix: "Remove the import."}]}'
}

# Editor result rewriting finding 0. $1 description, $2 suggested_fix (default: unchanged).
_cv_edit() {
    jq -cn --arg d "$1" --arg f "${2-$_CV_FIX}" '{edits: [{index: 0, description: $d, suggested_fix: $f}]}'
}

# Asserts the guard verdict for a rewrite of finding 0's description. $1 label, $2 rewrite,
# $3 expected accepted (true|false), $4 pattern the logged rejection reason must match.
_cv_description_case() {
    local out body
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" "$(_cv_edit "$2")")
    _cv_ok "$out" "$1" || return 0
    body=$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body')
    assert_equals "$3" "$(echo "$out" | jq -r '.bundle.log.voice[0].accepted')" "voice guard: $1 (logged accepted=$3)"
    if [[ "$3" == true ]]; then
        assert_equals 1 "$(grep -cF -- "$2" <<<"$body")" "voice guard: $1 (rewrite posted)"
    else
        assert_equals 1 "$(grep -cF -- "$_CV_DESC" <<<"$body")" "voice guard: $1 (original kept)"
        assert_matches "$4" "$(echo "$out" | jq -r '.bundle.log.voice[0].reason')" "voice guard: $1 (reason)"
    fi
}

test_voice_accepts_clean_rewrite() {
    _cv_description_case "clean rewrite" \
        '`order.Customer` is null for guest users, so a.cs:10 crashes checkout. See https://example.com/issue.' true
}

test_voice_rejects_dropped_backtick_token() {
    _cv_description_case "dropped backtick token" \
        'order.Customer is null for guest users, so a.cs:10 crashes checkout. See https://example.com/issue.' false \
        '^dropped `order\.Customer`$'
}

test_voice_rejects_dropped_path_line() {
    _cv_description_case "dropped path:line" \
        '`order.Customer` is null for guest users, so checkout crashes. See https://example.com/issue.' false \
        '^dropped a\.cs:10$'
}

test_voice_rejects_dropped_url() {
    _cv_description_case "dropped URL" \
        '`order.Customer` is null for guest users, so a.cs:10 crashes checkout.' false \
        '^dropped https://example\.com/issue$'
}

test_voice_rejects_growth_over_ten_percent() {
    _cv_description_case "grew more than 10%" \
        "$_CV_DESC This also affects every other caller of the service in several unrelated places." false \
        '^grew by more than 10%$'
}

test_voice_rejects_number_change_in_finding() {
    _cv_description_case "added number" \
        '`order.Customer` is null for 3 guest users, so a.cs:10 crashes checkout. See https://example.com/issue.' false \
        '^added the number 3$'
}

test_voice_rejects_severity_word_in_finding() {
    _cv_description_case "added severity word" \
        'Critical: `order.Customer` is null for guests, so a.cs:10 crashes checkout. See https://example.com/issue.' false \
        'critical'
}

test_voice_rejects_emptied_field() {
    local out
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" "$(_cv_edit '')")
    _cv_ok "$out" "emptied field" || return 0
    assert_equals "false" "$(echo "$out" | jq -r '.bundle.log.voice[0].accepted')" "voice guard: emptied field rejected"
    assert_equals 1 "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body' | grep -cF -- "$_CV_DESC")" \
        "voice guard: emptied field keeps the original"
}

test_voice_rejects_dropped_number_in_finding() {
    local nat out
    nat=$(jq -cn '[{file: "a.cs", line: 10, severity: "important", failure_scenario: "An outage.",
        summary: "The retry loop runs 5 times with no back-off, so an outage triples the load."}]')
    out=$(_cv_run "$(_cv_args)" "$nat" '{}' "$(_cv_edit 'The retry loop has no back-off, so an outage triples the load.' '')")
    _cv_ok "$out" "dropped number" || return 0
    assert_equals "dropped the number 5" "$(echo "$out" | jq -r '.bundle.log.voice[0].reason')" \
        "voice guard: a finding may not drop a number"
}

test_voice_fenced_block_must_be_byte_identical() {
    local out changed prose
    changed=$'Return early:\n\n```cs\nif (order?.Customer is null) return;\n```'
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" "$(_cv_edit "$_CV_DESC" "$changed")")
    _cv_ok "$out" "fenced block changed" || return 0
    assert_equals "false" "$(echo "$out" | jq -r '.bundle.log.voice[] | select(.field == "suggested_fix") | .accepted')" \
        "voice guard: changed code block rejected"
    prose=$'Exit first:\n\n```cs\nif (order.Customer is null) return;\n```'
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" "$(_cv_edit "$_CV_DESC" "$prose")")
    _cv_ok "$out" "fenced block kept" || return 0
    assert_equals "true" "$(echo "$out" | jq -r '.bundle.log.voice[] | select(.field == "suggested_fix") | .accepted')" \
        "voice guard: prose change around an identical code block accepted"
}

test_voice_ignores_unknown_index() {
    local out edit
    edit=$(jq -cn '{edits: [{index: 7, description: "x", suggested_fix: "y"}]}')
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" "$edit")
    _cv_ok "$out" "unknown index" || return 0
    assert_equals "null" "$(echo "$out" | jq -c '.bundle.log.voice')" "voice: an unknown index changes nothing"
    assert_equals 1 "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body' | grep -cF -- "$_CV_DESC")" \
        "voice: an unknown index keeps the original"
}

test_voice_failed_editor_changes_nothing() {
    local out editor
    for editor in null THROW '{"unexpected": true}'; do
        out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" "$editor")
        _cv_ok "$out" "editor result $editor" || continue
        assert_equals 1 "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body' | grep -cF -- "$_CV_DESC")" \
            "voice: editor result $editor keeps the original finding"
    done
}

test_voice_dispatch_and_input() {
    local out call prompt
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)")
    _cv_ok "$out" "editor dispatch" || return 0
    call=$(echo "$out" | jq -c '.editorCalls[0].opts | {agentType, model, phase, stallMs}')
    assert_equals '{"agentType":"code-review-suite:comment-editor","model":"sonnet","phase":"voice","stallMs":600000}' \
        "$call" "voice: one comment-editor dispatch on sonnet with stallMs 600000"
    prompt=$(echo "$out" | jq -r '.editorCalls[0].prompt')
    assert_matches 'order\.Customer' "$prompt" "voice: native findings are sent to the editor"
    assert_not_matches 'imported but unused' "$prompt" "voice: static-analysis findings are not sent to the editor"
    assert_not_matches 'request fails' "$prompt" "voice: native's failure_scenario is not sent to the editor"
    assert_not_matches '[Aa]ssessment' "$prompt" "voice: no assessment in the editor prompt"
    assert_equals 1 "$(echo "$out" | jq '.editorCalls | length')" "voice: exactly one editor dispatch"
}

test_voice_skipped_when_nothing_to_edit() {
    local out
    out=$(_cv_run "$(_cv_args)" '[]' "$(_cv_specs)")
    _cv_ok "$out" "nothing to edit" || return 0
    assert_equals 0 "$(echo "$out" | jq '.editorCalls | length')" "voice: no dispatch when native surfaces nothing"
}

test_voice_log_conforms_to_schema() {
    local out schema extra missing
    schema="$(_cv_cr_dir)/includes/finding-schema.json"
    out=$(_cv_run "$(_cv_args)" "$(_cv_nat)" "$(_cv_specs)" \
        "$(_cv_edit '`order.Customer` is null for guests, so a.cs:10 crashes. See https://example.com/issue.')")
    _cv_ok "$out" "voice log schema" || return 0
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.bundle.log.voice[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.log.properties.voice.items.properties | keys)')
    assert_equals "[]" "$extra" "log.voice records declare only schema keys"
    missing=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '[$s[0]["$defs"].sealedBundle.properties.log.properties.voice.items.required[] as $k
          | $b.bundle.log.voice[] | select(has($k) | not)] | length')
    assert_equals 0 "$missing" "log.voice records carry every required key"
    assert_equals 1 "$(echo "$out" | jq '.bundle.log.voice | length')" "log.voice records the description"
}

# Ends-with check for every element of a JSON string array. $1 json array, $2 label.
_cv_all_marked() {
    local n bad
    n=$(echo "$1" | jq 'length')
    bad=$(echo "$1" | jq --arg m "$_CV_MARKER" '[.[] | select(endswith("\n\n" + $m) | not)] | length')
    if [[ "$n" -gt 0 && "$bad" -eq 0 ]]; then
        pass "marker: $2 ($n)"
    else
        fail "marker: $2" "$bad of $n bodies lack the trailing marker"
    fi
}

test_marker_on_pr_bundle() {
    local nat out
    # a.cs:10 and a.cs:11 merge into one comment; a.cs:200 is not a changed line, so it becomes
    # a file-level comment.
    nat=$(jq -cn '[
        {file: "a.cs", line: 10, severity: "important", summary: "one", failure_scenario: "f"},
        {file: "a.cs", line: 11, severity: "important", summary: "two", failure_scenario: "f"},
        {file: "a.cs", line: 200, severity: "important", summary: "three", failure_scenario: "f"}]')
    out=$(_cv_run "$(_cv_args)" "$nat")
    _cv_ok "$out" "PR marker" || return 0
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.comments[] | select(.line) | .body]')" "line-level comments"
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.comments[] | select(.subjectType == "file") | .body]')" "file-level comments"
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.bodyText]')" "review body"
    assert_equals 0 "$(echo "$out" | jq --arg m "$_CV_MARKER" '[.bundle.comments[].body | [splits($m)] | length - 2 | select(. != 0)] | length')" \
        "marker: a co-located group carries exactly one marker"
}

test_marker_on_native_not_run_bundle() {
    local out
    out=$(_cv_run "$(_cv_args)" NOTRUN "$(_cv_specs)")
    _cv_ok "$out" "native-not-run PR marker" || return 0
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.bodyText]')" "native-not-run review body"
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.comments[].body]')" "native-not-run static comments"
    out=$(_cv_run "$(_cv_args local)" NOTRUN "$(_cv_specs)")
    _cv_ok "$out" "native-not-run local" || return 0
    assert_not_matches 'code-review-suite -->' "$(echo "$out" | jq -r '.bundle.bodyText')" "marker: local native-not-run body unmarked"
}

test_marker_absent_from_local_report() {
    local out
    out=$(_cv_run "$(_cv_args local)" "$(_cv_nat)" "$(_cv_specs)")
    _cv_ok "$out" "local report" || return 0
    assert_not_matches 'code-review-suite -->' "$(echo "$out" | jq -r '.bundle.bodyText')" "marker: local report unmarked"
}

test_comment_editor_agent_contract() {
    local f
    f="$(_cv_cr_dir)/agents/comment-editor.md"
    assert_matches "^model: sonnet$" "$(grep '^model:' "$f")" "comment-editor runs on sonnet"
    assert_matches "^tools: Read$" "$(grep '^tools:' "$f")" "comment-editor has Read only"
    assert_not_matches '[Aa]ssessment' "$(cat "$f")" "comment-editor no longer edits an assessment"
}

# Detection prompts stay free of the voice rules: only the editor carries the region.
test_comment_voice_only_in_editor() {
    local cr hits
    cr=$(_cv_cr_dir)
    hits=$(grep -lF 'BEGIN GENERATED from includes/comment-voice.md' "$cr"/agents/*.md "$cr"/includes/*.md "$cr"/commands/*.md \
        "$cr"/skills/*/SKILL.md | sed "s|$cr/||" | tr '\n' ' ')
    assert_equals "agents/comment-editor.md " "$hits" "comment-voice region is carried by comment-editor only"
}
