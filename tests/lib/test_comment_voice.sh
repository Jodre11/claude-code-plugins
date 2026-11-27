#!/usr/bin/env bash
# Comment-voice tests: the review-core wording pass (voicePass and its guards) and the
# `<!-- code-review-suite -->` marker on every bundle shape. review-core.js runs end to end
# through tests/lib/_cv_runner.js: specialists return fixture findings, three panelists vote
# them real, the writer returns fixture prose, and the comment-editor returns a fixture edit.

_CV_MARKER='<!-- code-review-suite -->'
_CV_CHANGED='Changed lines:\na.cs: 1-60\nb.py: 1-20\n'

_cv_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Review args. $1 route (full|lightweight), $2 review mode (pr|local).
_cv_args() {
    local route="${1:-full}" mode="${2:-pr}"
    jq -cn --arg route "$route" --arg mode "$mode" --arg cl "$(printf '%b' "$_CV_CHANGED")" \
        '{agentPrompt: "x", flags: {py: true}, route: $route, selfReReview: false, reviewMode: $mode,
          base: "main", headSha: ("a" * 40), emptyTreeMode: false, pathScope: "",
          tempDir: "/tmp/claude-test/x", intentLedger: "", panelSize: 3,
          changedLinesBlock: $cl}'
}

# Three panelists voting every finding id in 0..$1-1 real at Important/Bounded.
_cv_pans() {
    jq -cn --argjson n "$1" \
        '[range(3)] | map({votes: [range($n) | {finding_id: ., is_real: true, severity: "Important",
          tractability: "Bounded", blocks_goal: false, rationale: "r"}], raised: []})'
}

# Runs review-core. $1 args, $2 specialists json, $3 panelists json, $4 editor json (or THROW),
# $5 writer assessment as a JSON string literal.
_cv_run() {
    WF="$(_cv_cr_dir)/workflows/review-core.js" CV_ARGS="$1" CV_SPECIALISTS="$2" CV_PANELISTS="$3" \
        CV_EDITOR="${4:-null}" CV_WRITER="${5:-\"panel prose\"}" node "$REPO_ROOT/tests/lib/_cv_runner.js" 2>&1 || true
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

# One correctness finding at a.cs:10 (LLM, edited) and one ruff finding at b.py:3 (static, never
# sent to the editor).
_cv_specs() {
    jq -cn --arg d "$_CV_DESC" --arg f "$_CV_FIX" \
        '{correctness: [{file: "a.cs", line: 10, severity: "Important", confidence: 90, description: $d,
           suggested_fix: $f}],
          ruff: [{file: "b.py", line: 3, rule_id: "F401", severity: "Important", confidence: 100,
           description: "`os` imported but unused.", suggested_fix: "Remove the import."}]}'
}

# Editor result rewriting finding 0. $1 description, $2 suggested_fix (default: unchanged),
# $3 assessment (default: the writer's).
_cv_edit() {
    jq -cn --arg d "$1" --arg f "${2-$_CV_FIX}" --arg a "${3:-panel prose}" \
        '{edits: [{index: 0, description: $d, suggested_fix: $f}], assessment: $a}'
}

# Asserts the guard verdict for a rewrite of finding 0's description. $1 label, $2 rewrite,
# $3 expected accepted (true|false), $4 pattern the logged rejection reason must match.
_cv_description_case() {
    local out body
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$(_cv_edit "$2")")
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
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$(_cv_edit '')")
    _cv_ok "$out" "emptied field" || return 0
    assert_equals "false" "$(echo "$out" | jq -r '.bundle.log.voice[0].accepted')" "voice guard: emptied field rejected"
    assert_equals 1 "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body' | grep -cF -- "$_CV_DESC")" \
        "voice guard: emptied field keeps the original"
}

test_voice_rejects_dropped_number_in_finding() {
    local specs out
    specs=$(jq -cn '{correctness: [{file: "a.cs", line: 10, severity: "Important", confidence: 90,
        description: "The retry loop runs 5 times with no back-off, so an outage triples the load.", suggested_fix: ""}]}')
    out=$(_cv_run "$(_cv_args)" "$specs" "$(_cv_pans 1)" \
        "$(_cv_edit 'The retry loop has no back-off, so an outage triples the load.' '')")
    _cv_ok "$out" "dropped number" || return 0
    assert_equals "dropped the number 5" "$(echo "$out" | jq -r '.bundle.log.voice[0].reason')" \
        "voice guard: a finding may not drop a number"
}

test_voice_fenced_block_must_be_byte_identical() {
    local out changed prose
    changed=$'Return early:\n\n```cs\nif (order?.Customer is null) return;\n```'
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$(_cv_edit "$_CV_DESC" "$changed")")
    _cv_ok "$out" "fenced block changed" || return 0
    assert_equals "false" "$(echo "$out" | jq -r '.bundle.log.voice[] | select(.field == "suggested_fix") | .accepted')" \
        "voice guard: changed code block rejected"
    prose=$'Exit first:\n\n```cs\nif (order.Customer is null) return;\n```'
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$(_cv_edit "$_CV_DESC" "$prose")")
    _cv_ok "$out" "fenced block kept" || return 0
    assert_equals "true" "$(echo "$out" | jq -r '.bundle.log.voice[] | select(.field == "suggested_fix") | .accepted')" \
        "voice guard: prose change around an identical code block accepted"
}

# Asserts the guard verdict for a rewrite of the assessment. $1 label, $2 rewrite, $3 expected,
# $4 pattern the logged rejection reason must match.
_cv_assessment_case() {
    local out writer='"The null dereference blocks the merge; fix it before release."'
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$(_cv_edit "$_CV_DESC" "$_CV_FIX" "$2")" "$writer")
    _cv_ok "$out" "$1" || return 0
    assert_equals "$3" "$(echo "$out" | jq -r '.bundle.log.voice[] | select(.field == "assessment") | .accepted')" \
        "assessment guard: $1 (accepted=$3)"
    if [[ "$3" == true ]]; then
        assert_equals 1 "$(echo "$out" | jq -r '.bundle.bodyText' | grep -cF -- "$2")" "assessment guard: $1 (rewrite in body)"
    else
        assert_equals 1 "$(echo "$out" | jq -r '.bundle.bodyText' | grep -cF 'fix it before release')" \
            "assessment guard: $1 (original in body)"
        assert_matches "$4" "$(echo "$out" | jq -r '.bundle.log.voice[] | select(.field == "assessment") | .reason')" \
            "assessment guard: $1 (reason)"
    fi
}

test_assessment_accepts_clean_rewrite() {
    _cv_assessment_case "clean rewrite" "The null dereference blocks the merge." true
}

test_assessment_rejects_added_digit() {
    _cv_assessment_case "added digit" "The null dereference blocks the merge in 2 places." false '^added the number 2$'
}

test_assessment_rejects_added_verdict_word() {
    _cv_assessment_case "added verdict word" "REQUEST_CHANGES: the null dereference blocks the merge." false 'request'
}

test_assessment_rejects_added_severity_word() {
    _cv_assessment_case "added severity word" "The Critical null dereference blocks the merge." false 'critical'
}

test_voice_ignores_unknown_index() {
    local out edit
    edit=$(jq -cn '{edits: [{index: 7, description: "x", suggested_fix: "y"}], assessment: "panel prose"}')
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$edit")
    _cv_ok "$out" "unknown index" || return 0
    assert_equals "null" "$(echo "$out" | jq -c '.bundle.log.voice')" "voice: an unknown index changes nothing"
    assert_equals 1 "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body' | grep -cF -- "$_CV_DESC")" \
        "voice: an unknown index keeps the original"
}

test_voice_failed_editor_changes_nothing() {
    local out editor
    for editor in null THROW '{"unexpected": true}'; do
        out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" "$editor")
        _cv_ok "$out" "editor result $editor" || continue
        assert_equals 1 "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "a.cs") | .body' | grep -cF -- "$_CV_DESC")" \
            "voice: editor result $editor keeps the original finding"
        assert_equals 1 "$(echo "$out" | jq -r '.bundle.bodyText' | grep -cF 'panel prose')" \
            "voice: editor result $editor keeps the original assessment"
    done
}

test_voice_dispatch_and_input() {
    local out call
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)")
    _cv_ok "$out" "editor dispatch" || return 0
    call=$(echo "$out" | jq -c '.editorCalls[0].opts | {agentType, model, phase, stallMs}')
    assert_equals '{"agentType":"code-review-suite:comment-editor","model":"sonnet","phase":"voice","stallMs":600000}' \
        "$call" "voice: one comment-editor dispatch on sonnet with stallMs 600000"
    local prompt
    prompt=$(echo "$out" | jq -r '.editorCalls[0].prompt')
    assert_matches 'order\.Customer' "$prompt" "voice: LLM findings are sent to the editor"
    assert_not_matches 'imported but unused' "$prompt" "voice: static-analysis findings are not sent to the editor"
    assert_equals 1 "$(echo "$out" | jq '.editorCalls | length')" "voice: exactly one editor dispatch"
}

test_voice_skipped_when_nothing_to_edit() {
    local out
    out=$(_cv_run "$(_cv_args)" '{}' "$(_cv_pans 0)" null '""')
    _cv_ok "$out" "nothing to edit" || return 0
    assert_equals 0 "$(echo "$out" | jq '.editorCalls | length')" "voice: no dispatch when nothing surfaces and no assessment"
}

test_voice_log_conforms_to_schema() {
    local out schema extra missing
    schema="$(_cv_cr_dir)/includes/finding-schema.json"
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" "$(_cv_pans 2)" \
        "$(_cv_edit '`order.Customer` is null for guests, so a.cs:10 crashes. See https://example.com/issue.' \
            "$_CV_FIX" "Shorter prose.")")
    _cv_ok "$out" "voice log schema" || return 0
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.bundle.log.voice[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.log.properties.voice.items.properties | keys)')
    assert_equals "[]" "$extra" "log.voice records declare only schema keys"
    missing=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '[$s[0]["$defs"].sealedBundle.properties.log.properties.voice.items.required[] as $k
          | $b.bundle.log.voice[] | select(has($k) | not)] | length')
    assert_equals 0 "$missing" "log.voice records carry every required key"
    assert_equals 2 "$(echo "$out" | jq '.bundle.log.voice | length')" "log.voice records the description and the assessment"
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

test_marker_on_panel_pr_bundle() {
    local specs out
    # a.cs:10 and a.cs:11 merge into one comment; a.cs:200 is outside the diff, so it becomes
    # a file-level comment.
    specs=$(jq -cn '{correctness: [
        {file: "a.cs", line: 10, severity: "Important", confidence: 90, description: "one", suggested_fix: ""},
        {file: "a.cs", line: 11, severity: "Important", confidence: 90, description: "two", suggested_fix: ""}],
      security: [{file: "a.cs", line: 200, severity: "Important", confidence: 90, description: "three", suggested_fix: ""}]}')
    out=$(_cv_run "$(_cv_args)" "$specs" "$(_cv_pans 3)")
    _cv_ok "$out" "panel PR marker" || return 0
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.comments[] | select(.line) | .body]')" "line-level comments"
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.comments[] | select(.subjectType == "file") | .body]')" "file-level comments"
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.bodyText]')" "review body"
    assert_equals 0 "$(echo "$out" | jq --arg m "$_CV_MARKER" '[.bundle.comments[].body | [splits($m)] | length - 2 | select(. != 0)] | length')" \
        "marker: a co-located group carries exactly one marker"
}

test_marker_on_degraded_bundle() {
    local out
    out=$(_cv_run "$(_cv_args)" "$(_cv_specs)" '[]')
    _cv_ok "$out" "degraded PR marker" || return 0
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.bodyText]')" "below-quorum review body"
    out=$(_cv_run "$(_cv_args full local)" "$(_cv_specs)" '[]')
    _cv_ok "$out" "degraded local" || return 0
    assert_not_matches 'code-review-suite -->' "$(echo "$out" | jq -r '.bundle.bodyText')" "marker: local degraded body unmarked"
}

test_marker_on_lightweight_bundle() {
    local specs out
    specs=$(jq -cn '{"code-analysis": [{file: "a.cs", line: 10, severity: "Important", confidence: 90,
        description: "lw", suggested_fix: ""}]}')
    out=$(_cv_run "$(_cv_args lightweight pr)" "$specs" '[]')
    _cv_ok "$out" "lightweight PR marker" || return 0
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.comments[].body]')" "lightweight comments"
    _cv_all_marked "$(echo "$out" | jq -c '[.bundle.bodyText]')" "lightweight body"
    assert_equals 1 "$(echo "$out" | jq '.editorCalls | length')" "voice: lightweight findings take the wording pass"
    out=$(_cv_run "$(_cv_args lightweight local)" "$specs" '[]')
    _cv_ok "$out" "lightweight local" || return 0
    assert_not_matches 'code-review-suite -->' "$(echo "$out" | jq -r '.bundle.bodyText')" "marker: lightweight local body unmarked"
}

test_marker_absent_from_local_report() {
    local out
    out=$(_cv_run "$(_cv_args full local)" "$(_cv_specs)" "$(_cv_pans 2)")
    _cv_ok "$out" "local report" || return 0
    assert_not_matches 'code-review-suite -->' "$(echo "$out" | jq -r '.bundle.bodyText')" "marker: local report unmarked"
}

test_comment_editor_agent_contract() {
    local f
    f="$(_cv_cr_dir)/agents/comment-editor.md"
    assert_matches "^model: sonnet$" "$(grep '^model:' "$f")" "comment-editor runs on sonnet"
    assert_matches "^tools: Read$" "$(grep '^tools:' "$f")" "comment-editor has Read only"
}

# Detection prompts stay free of the voice rules: only the editor carries the region.
test_comment_voice_only_in_editor() {
    local cr hits
    cr=$(_cv_cr_dir)
    hits=$(grep -lF 'BEGIN GENERATED from includes/comment-voice.md' "$cr"/agents/*.md "$cr"/includes/*.md "$cr"/commands/*.md \
        "$cr"/skills/*/SKILL.md | sed "s|$cr/||" | tr '\n' ' ')
    assert_equals "agents/comment-editor.md " "$hits" "comment-voice region is carried by comment-editor only"
}
