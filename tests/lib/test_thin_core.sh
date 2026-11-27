#!/usr/bin/env bash
# Thin-core tests: review-core.js's native capture (the bundled /code-review, run by
# agents/native-reviewer.md) and the in-code guards around it. Pure helpers run in the
# call mode of tests/lib/_tc_runner.js; the flow runs end to end through the same runner.

_TC_REPO='/tmp/fx-repo'
_TC_BASE='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
_TC_HEAD='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
_TC_EMPTY='4b825dc642cb6eb9a060e54bf8d69288fbee4904'

_tc_wf() {
    echo "$REPO_ROOT/plugins/code-review-suite/workflows/review-core.js"
}

# Calls a hoisted review-core function. $1 name, $2 the arguments as a JSON array.
# Prints the function's result as JSON.
_tc_call() {
    WF="$(_tc_wf)" TC_CALL="$1" TC_INPUT="$2" node "$REPO_ROOT/tests/lib/_tc_runner.js" 2>&1 \
        | jq -c '.result' 2>/dev/null || echo 'RUNNER_FAILED'
}

# parseNativeText on $1 (raw text). Prints the result as JSON.
_tc_parse() {
    _tc_call parseNativeText "$(jq -cn --arg t "$1" '[$t]')"
}

_tc_fence() {
    printf '```json\n%s\n```' "$1"
}

_TC_GOOD='[{"file":"stats.py","line":17,"summary":"Off by one. Fix: add 1.","failure_scenario":"f([1,2,3],3) returns []","severity":"important"}]'

# --- parseNativeText ---------------------------------------------------------------

test_thin_core_parse_array_with_header() {
    local out
    out=$(_tc_parse "$(printf 'Skill "code-review" completed\n\nI found 1 problem.\n\n%s' "$(_tc_fence "$_TC_GOOD")")")
    assert_equals 'true' "$(echo "$out" | jq -r '.ok')" "parse: header and prose before the array → ok"
    assert_equals '17' "$(echo "$out" | jq -r '.findings[0].line')" "parse: header form keeps the finding"
}

test_thin_core_parse_array_without_header() {
    local out
    out=$(_tc_parse "$(_tc_fence "$_TC_GOOD")")
    assert_equals 'true' "$(echo "$out" | jq -r '.ok')" "parse: bare array, no header → ok"
    out=$(_tc_parse "$(printf 'Summary prose.\n\n%s' "$(_tc_fence "$_TC_GOOD")")")
    assert_equals 'stats.py' "$(echo "$out" | jq -r '.findings[0].file')" "parse: prose before the array, no header → ok"
}

test_thin_core_parse_last_array_wins() {
    local out
    out=$(_tc_parse "$(printf '%s\n\nThen:\n\n%s\n\n%s' "$(_tc_fence '[]')" "$(_tc_fence "$_TC_GOOD")" \
        "$(_tc_fence '{"not":"an array"}')")")
    assert_equals '1' "$(echo "$out" | jq -r '.findings | length')" "parse: the last block that parses to an array is used"
}

test_thin_core_parse_drops_extra_keys() {
    local good out
    good='[{"file":"a.py","line":3,"summary":"s","failure_scenario":"f","severity":"nit","confidence":90}]'
    out=$(_tc_parse "$(_tc_fence "$good")")
    assert_equals '["failure_scenario","file","line","severity","summary"]' \
        "$(echo "$out" | jq -c '.findings[0] | keys')" "parse: extra keys dropped"
}

test_thin_core_parse_skill_error() {
    local out
    out=$(_tc_parse "$(printf 'SKILL_ERROR: skill code-review not found\n%s' "$(_tc_fence "$_TC_GOOD")")")
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: SKILL_ERROR → not ok, even with an array after it"
    assert_equals 'SKILL_ERROR: skill code-review not found' "$(echo "$out" | jq -r '.reason')" "parse: SKILL_ERROR text is the reason"
}

test_thin_core_parse_no_array() {
    local out
    out=$(_tc_parse 'I reviewed the change and found nothing worth raising.')
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: no fenced array → not ok"
    out=$(_tc_parse "$(_tc_fence '[{"file":')")
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: unparseable block → not ok"
    out=$(_tc_call parseNativeText '[null]')
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: null result → not ok"
}

test_thin_core_parse_bad_severity_rejects_whole_array() {
    local arr out
    arr='[{"file":"a.py","line":3,"summary":"s","failure_scenario":"f","severity":"nit"},{"file":"a.py","line":4,"summary":"s","failure_scenario":"f","severity":"critical"}]'
    out=$(_tc_parse "$(_tc_fence "$arr")")
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: one bad severity rejects the whole array"
    assert_matches 'finding 1 .*severity' "$(echo "$out" | jq -r '.reason')" "parse: reason names the bad element"
}

test_thin_core_parse_missing_key_rejects() {
    local out
    out=$(_tc_parse "$(_tc_fence '[{"file":"a.py","line":3,"summary":"s","severity":"nit"}]')")
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: a missing key rejects the array"
    assert_matches 'failure_scenario' "$(echo "$out" | jq -r '.reason')" "parse: reason names the missing key"
    out=$(_tc_parse "$(_tc_fence '[{"file":"a.py","line":0,"summary":"s","failure_scenario":"f","severity":"nit"}]')")
    assert_equals 'false' "$(echo "$out" | jq -r '.ok')" "parse: line 0 rejects the array"
}

test_thin_core_parse_empty_array_is_ok() {
    local out
    out=$(_tc_parse "$(printf 'No problems found.\n\n%s' "$(_tc_fence '[]')")")
    assert_equals 'true' "$(echo "$out" | jq -r '.ok')" "parse: empty array → ok"
    assert_equals '0' "$(echo "$out" | jq -r '.findings | length')" "parse: empty array → no findings"
}

# --- checkNativeTarget -------------------------------------------------------------

# $1 target string. Prints {ok, reason?} for repoDir $_TC_REPO and head $_TC_HEAD.
_tc_target() {
    _tc_call checkNativeTarget "$(jq -cn --arg t "$1" --arg r "$_TC_REPO" --arg h "$_TC_HEAD" '[$t, $r, $h]')"
}

test_thin_core_target_forms() {
    assert_equals 'true' "$(_tc_target "$_TC_REPO $_TC_BASE...$_TC_HEAD" | jq -r '.ok')" "target: <path> <sha>...<sha> accepted"
    assert_equals 'true' "$(_tc_target "$_TC_REPO $_TC_EMPTY $_TC_HEAD" | jq -r '.ok')" "target: <path> <empty tree> <sha> accepted"
    assert_equals 'true' "$(_tc_target "$_TC_REPO $_TC_BASE...$_TC_HEAD -- src/lib/*" | jq -r '.ok')" "target: range with a path scope accepted"
    assert_equals 'true' "$(_tc_target "$_TC_REPO $_TC_EMPTY $_TC_HEAD -- docs" | jq -r '.ok')" "target: empty tree with a path scope accepted"
}

test_thin_core_target_rejects() {
    assert_equals 'false' "$(_tc_target "$_TC_REPO --comment $_TC_BASE...$_TC_HEAD" | jq -r '.ok')" "target: a flag before the range rejected"
    assert_equals 'false' "$(_tc_target "$_TC_REPO $_TC_BASE...$_TC_HEAD --fix" | jq -r '.ok')" "target: a trailing flag rejected"
    assert_equals 'false' "$(_tc_target "$_TC_REPO $_TC_BASE...$_TC_HEAD -- --max-findings" | jq -r '.ok')" "target: a flag as the scope rejected"
    assert_equals 'false' "$(_tc_target "$_TC_REPO $_TC_BASE...$_TC_HEAD -- ../etc" | jq -r '.ok')" "target: a traversal scope rejected"
    assert_equals 'false' "$(_tc_target "/tmp/other $_TC_BASE...$_TC_HEAD" | jq -r '.ok')" "target: a path other than repoDir rejected"
    assert_equals 'false' "$(_tc_target "tmp/fx-repo $_TC_BASE...$_TC_HEAD" | jq -r '.ok')" "target: a relative path rejected"
    assert_equals 'false' "$(_tc_target "$_TC_REPO main...$_TC_HEAD" | jq -r '.ok')" "target: a branch name as base rejected"
    assert_equals 'false' "$(_tc_target "$_TC_REPO $_TC_BASE...$_TC_BASE" | jq -r '.ok')" "target: a head other than headSha rejected"
    assert_equals 'false' "$(_tc_target "$_TC_REPO $_TC_BASE $_TC_HEAD" | jq -r '.ok')" "target: two-dot form with a non-empty-tree base rejected"
    assert_equals 'false' "$(_tc_target '' | jq -r '.ok')" "target: empty string rejected"
}

# --- normaliseNative ---------------------------------------------------------------

# $1 severity, $2 summary. Prints the one normalised finding.
_tc_norm() {
    _tc_call normaliseNative "$(jq -cn --arg s "$1" --arg m "$2" \
        '[[{file: "a.py", line: 5, summary: $m, failure_scenario: "fs", severity: $s}]]')" | jq -c '.[0]'
}

test_thin_core_normalise_severities() {
    local out
    out=$(_tc_norm important 'Bug. Fix: x')
    assert_equals 'Important true null' "$(echo "$out" | jq -r '"\(.severity) \(.blocking) \(.annotation)"')" "normalise: important → Important, blocking"
    out=$(_tc_norm nit 'Style. Fix: x')
    assert_equals 'Suggestion false null' "$(echo "$out" | jq -r '"\(.severity) \(.blocking) \(.annotation)"')" "normalise: nit → Suggestion, not blocking"
    out=$(_tc_norm pre_existing 'Old bug. Fix: x')
    assert_equals 'Suggestion false pre-existing' "$(echo "$out" | jq -r '"\(.severity) \(.blocking) \(.annotation)"')" "normalise: pre_existing → Suggestion, annotated, not blocking"
    assert_equals 'native fs' "$(echo "$out" | jq -r '"\(.source) \(.failure_scenario)"')" "normalise: source native, failure_scenario kept"
}

test_thin_core_normalise_fix_split() {
    local out
    out=$(_tc_norm nit 'The loop stops one early. Fix: use range(n + 1).')
    assert_equals 'The loop stops one early.' "$(echo "$out" | jq -r '.description')" "normalise: description is the text before Fix:"
    assert_equals 'use range(n + 1).' "$(echo "$out" | jq -r '.suggested_fix')" "normalise: suggested_fix drops the Fix: label"
    out=$(_tc_norm nit 'Prefix: the value is wrong.')
    assert_equals 'Prefix: the value is wrong.' "$(echo "$out" | jq -r '.description')" "normalise: no Fix: → whole summary is the description"
    assert_equals '' "$(echo "$out" | jq -r '.suggested_fix')" "normalise: no Fix: → empty suggested_fix"
}

# --- citesOutsideRule (personal-rule guard) ----------------------------------------

# $1 text. Prints true/false for repoDir $_TC_REPO.
_tc_cites() {
    _tc_call citesOutsideRule "$(jq -cn --arg t "$1" --arg r "$_TC_REPO" '[$t, $r]')"
}

test_thin_core_personal_rule_dropped() {
    # The S1 spike's citation shapes, with the session path neutralised.
    assert_equals 'true' "$(_tc_cites 'Breaks ~/.claude/CLAUDE.md: "a brief summary doc comment on public/exported APIs". `def shout(text):` has no docstring.')" \
        "personal rule: Breaks ~/… : cited → dropped"
    assert_equals 'true' "$(_tc_cites 'This breaks the rule in ~/.claude/CLAUDE.md: "If list has more than 3 items: each on its own line".')" \
        "personal rule: breaks the rule in ~/…: → dropped"
    assert_equals 'true' "$(_tc_cites 'The user-level ~/.claude/CLAUDE.md rule reads: "a brief summary doc comment".')" \
        "personal rule: <path> rule reads → dropped"
    assert_equals 'true' "$(_tc_cites 'Breaks /home/someone/CLAUDE.md: "no print".')" \
        "personal rule: absolute path outside repoDir → dropped"
}

test_thin_core_repo_rule_kept() {
    assert_equals 'false' "$(_tc_cites 'Breaks CLAUDE.md: "use logging, not print".')" \
        "repo rule: repo-relative CLAUDE.md cited → kept"
    assert_equals 'false' "$(_tc_cites 'This breaks the rule in /tmp/fx-repo/CLAUDE.md: "use logging, not print".')" \
        "repo rule: absolute repoDir CLAUDE.md cited → kept"
    assert_equals 'false' "$(_tc_cites 'Breaks lib/CLAUDE.md: "no globals".')" \
        "repo rule: nested repo CLAUDE.md cited → kept"
}

test_thin_core_personal_path_mention_kept() {
    assert_equals 'false' "$(_tc_cites 'A user who keeps settings in ~/.claude/CLAUDE.md loses them when install.sh overwrites the file.')" \
        "mention: user-level path mentioned, not cited → kept"
    assert_equals 'false' "$(_tc_cites 'Editing rule-sources.md changes how ~/.claude/CLAUDE.md content is screened.')" \
        "mention: rule-sources.md is not a citation keyword → kept"
}

# --- staticCriticalAllowed ---------------------------------------------------------

# $1 domain, $2 finding json. Prints true/false.
_tc_allowed() {
    _tc_call staticCriticalAllowed "$(jq -cn --arg d "$1" --argjson f "$2" '[$d, $f]')"
}

test_thin_core_static_critical_allow_list() {
    assert_equals 'true' "$(_tc_allowed ruff '{"rule_id":"S105","description":"x"}')" "allow-list: ruff S105 allowed"
    assert_equals 'false' "$(_tc_allowed ruff '{"rule_id":"F401","description":"x"}')" "allow-list: ruff F401 not allowed"
    assert_equals 'true' "$(_tc_allowed eslint '{"rule_id":"security/detect-child-process","description":"x"}')" \
        "allow-list: eslint plugin rule matches without the eslint-plugin- prefix"
    assert_equals 'true' "$(_tc_allowed trivy '{"rule_id":"AVD-GEN-SECRET-0001","description":"x"}')" "allow-list: trivy SECRET glob"
    assert_equals 'true' "$(_tc_allowed trivy '{"rule_id":"AVD-AWS-0017","description":"x"}')" "allow-list: trivy explicit ID"
    assert_equals 'true' "$(_tc_allowed trivy '{"rule_id":"AVD-AWS-9999","description":"Private key committed"}')" \
        "allow-list: trivy title pattern matched against the description"
    assert_equals 'false' "$(_tc_allowed trivy '{"rule_id":"DS-0002","description":"Image runs as root"}')" "allow-list: trivy other rule not allowed"
    assert_equals 'false' "$(_tc_allowed jbinspect '{"rule_id":"PossibleNullReferenceException","description":"x"}')" \
        "allow-list: jbinspect list is empty"
}
