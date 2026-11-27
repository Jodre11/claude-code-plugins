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

# STATIC_CRITICAL_ALLOW is a copy of each static agent's `## Critical-allow-list:` section; the
# two drift silently unless compared. housekeeper has no section and must allow nothing.
test_thin_core_static_critical_allow_list_matches_agents() {
    local out tool
    out=$(CR="$REPO_ROOT/plugins/code-review-suite" node "$REPO_ROOT/tests/lib/_allow_parity.js" 2>&1 || true)
    if ! echo "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
        fail "allow-list parity: extractor ran" "${out:0:200}"
        return 0
    fi
    for tool in ruff eslint trivy jbinspect; do
        assert_equals "$(echo "$out" | jq -c --arg t "$tool" '.[$t].doc')" \
            "$(echo "$out" | jq -c --arg t "$tool" '.[$t].code')" \
            "allow-list parity: review-core matches agents/$tool-reviewer.md"
    done
    assert_equals '{"ids":[],"idPatterns":[],"titleWords":[]}' "$(echo "$out" | jq -c '.housekeeper.code')" \
        "allow-list parity: housekeeper allows no Critical"
    assert_equals '["eslint","housekeeper","jbinspect","ruff","trivy"]' "$(echo "$out" | jq -c 'keys')" \
        "allow-list parity: one entry per static tool"
}

# --- The thin flow, end to end -----------------------------------------------------

_TC_CHANGED='Changed lines:\nstats.py: 10-20\nlib/a.py: 1-5\n'

# Review args. $1 review mode (pr|local), $2 nativeTarget (defaults to a valid range).
_tc_args() {
    local mode="${1:-pr}" target="${2-$_TC_REPO $_TC_BASE...$_TC_HEAD}"
    jq -cn --arg mode "$mode" --arg cl "$(printf '%b' "$_TC_CHANGED")" --arg t "$target" \
        --arg r "$_TC_REPO" --arg h "$_TC_HEAD" \
        '{agentPrompt: "static prompt", flags: {py: true, housekeeping: true}, reviewMode: $mode,
          base: "main", headSha: $h, emptyTreeMode: false, pathScope: "", tempDir: "/tmp/claude-test/x",
          repoDir: $r, changedLinesBlock: $cl, nativeTarget: $t, cliVersion: "2.1.332"}'
}

# Native's result text for a findings array. $1 the array JSON.
_tc_native_text() {
    jq -cn --arg a "$1" '"I found some problems.\n\n```json\n" + $a + "\n```"'
}

# Runs review-core. $1 args, $2 native result (a JSON string literal, or null), $3 specialists
# json, $4 editor json (or THROW).
_tc_run() {
    WF="$(_tc_wf)" TC_ARGS="$1" TC_NATIVE="$2" TC_SPECIALISTS="${3:-{\}}" TC_EDITOR="${4:-null}" \
        node "$REPO_ROOT/tests/lib/_tc_runner.js" 2>&1 || true
}

_TC_NAT_IMPORTANT='[{"file":"stats.py","line":17,"summary":"Off by one. Fix: add 1.","failure_scenario":"f([1,2,3],3) returns []","severity":"important"}]'
_TC_NAT_NIT='[{"file":"stats.py","line":12,"summary":"Name is vague. Fix: rename.","failure_scenario":"A reader guesses wrong.","severity":"nit"}]'

test_thin_core_verdict_request_changes() {
    local out
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$_TC_NAT_IMPORTANT")")
    assert_equals 'REQUEST_CHANGES' "$(echo "$out" | jq -r '.bundle.verdict')" "verdict: native important → REQUEST_CHANGES"
    assert_matches '^\*\*REQUEST_CHANGES\*\* — 1 blocking finding' "$(echo "$out" | jq -r '.bundle.bodyText')" "verdict: headline carries the reason"
    assert_equals 'true ' "$(echo "$out" | jq -r '"\(.bundle.native.ran) \(.bundle.native.reason)"')" "bundle: native.ran true, empty reason"
}

test_thin_core_verdict_approve() {
    local out
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$_TC_NAT_NIT")")
    assert_equals 'APPROVE' "$(echo "$out" | jq -r '.bundle.verdict')" "verdict: only a nit → APPROVE"
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text '[]')")
    assert_equals 'APPROVE' "$(echo "$out" | jq -r '.bundle.verdict')" "verdict: empty array → APPROVE"
    assert_matches 'no blocking findings' "$(echo "$out" | jq -r '.bundle.bodyText')" "verdict: APPROVE reason"
}

test_thin_core_verdict_static_blocks() {
    local specs out
    specs='{"ruff":[{"file":"lib/a.py","line":2,"rule_id":"S105","severity":"Critical","description":"Hardcoded password.","suggested_fix":"Use a secret store."}]}'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text '[]')" "$specs")
    assert_equals 'REQUEST_CHANGES' "$(echo "$out" | jq -r '.bundle.verdict')" "verdict: allow-listed static Critical blocks"
    specs='{"ruff":[{"file":"lib/a.py","line":2,"rule_id":"E501","severity":"Important","description":"Line too long.","suggested_fix":"Wrap."}]}'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text '[]')" "$specs")
    assert_equals 'REQUEST_CHANGES' "$(echo "$out" | jq -r '.bundle.verdict')" "verdict: static Important blocks"
}

test_thin_core_static_critical_not_allow_listed() {
    local specs out
    specs='{"ruff":[{"file":"lib/a.py","line":2,"rule_id":"F401","severity":"Critical","description":"Unused import.","suggested_fix":"Remove it."}]}'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text '[]')" "$specs")
    assert_equals 'APPROVE' "$(echo "$out" | jq -r '.bundle.verdict')" "static guard: non-listed Critical does not block"
    assert_equals '1' "$(echo "$out" | jq '.bundle.comments | length')" "static guard: non-listed Critical still posts"
    assert_matches "^\*\*Critical\*\* — not blocking \(rule not on the tool's Critical allow-list\)" \
        "$(echo "$out" | jq -r '.bundle.comments[0].body')" "static guard: comment carries the A8 note"
    assert_equals 'severity-unreachable false' \
        "$(echo "$out" | jq -r '.bundle.log.findings[] | select(.source == "ruff") | "\(.filtered) \(.blocking)"')" \
        "static guard: logged filtered severity-unreachable, not blocking"
}

test_thin_core_native_not_run_causes() {
    local out reason
    out=$(_tc_run "$(_tc_args)" '"SKILL_ERROR: skill not found"')
    assert_equals 'NONE' "$(echo "$out" | jq -r '.bundle.verdict')" "not run: SKILL_ERROR → NONE"
    out=$(_tc_run "$(_tc_args)" '"No array here."')
    assert_equals 'NONE' "$(echo "$out" | jq -r '.bundle.verdict')" "not run: no array → NONE"
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text '[{"file":"a.py","line":1,"summary":"s","failure_scenario":"f","severity":"high"}]')")
    assert_equals 'NONE' "$(echo "$out" | jq -r '.bundle.verdict')" "not run: bad element → NONE"
    out=$(_tc_run "$(_tc_args)" 'null')
    assert_equals 'NONE' "$(echo "$out" | jq -r '.bundle.verdict')" "not run: null agent result → NONE"
    out=$(_tc_run "$(_tc_args pr "$_TC_REPO --comment $_TC_BASE...$_TC_HEAD")" "$(_tc_native_text "$_TC_NAT_IMPORTANT")")
    assert_equals 'NONE' "$(echo "$out" | jq -r '.bundle.verdict')" "not run: bad nativeTarget → NONE"
    assert_equals '0' "$(echo "$out" | jq '[.dispatches[] | select(.label == "native")] | length')" \
        "not run: bad nativeTarget → native never dispatched"
    reason=$(echo "$out" | jq -r '.bundle.native.reason')
    assert_matches 'native target' "$reason" "not run: bundle.native.reason names the cause"
}

test_thin_core_none_carries_static_comments() {
    local specs out
    specs='{"ruff":[{"file":"lib/a.py","line":2,"rule_id":"E501","severity":"Important","description":"Line too long.","suggested_fix":"Wrap."}]}'
    out=$(_tc_run "$(_tc_args)" '"SKILL_ERROR: boom"' "$specs")
    assert_equals 'NONE' "$(echo "$out" | jq -r '.bundle.verdict')" "NONE: verdict"
    assert_equals '1' "$(echo "$out" | jq '.bundle.comments | length')" "NONE: static comments still carried"
    assert_matches '^\*\*COMMENT\*\* — native review did not run \(SKILL_ERROR: boom\); static-analysis findings only' \
        "$(echo "$out" | jq -r '.bundle.bodyText')" "NONE: A9 headline"
    assert_equals 'false' "$(echo "$out" | jq -r '.bundle.native.ran')" "NONE: native.ran false"
}

test_thin_core_anchor_routes() {
    local nat out
    nat='[{"file":"stats.py","line":17,"summary":"In diff.","failure_scenario":"x","severity":"nit"},
          {"file":"stats.py","line":40,"summary":"Unchanged line.","failure_scenario":"x","severity":"nit"},
          {"file":"other.py","line":3,"summary":"Not in diff.","failure_scenario":"x","severity":"nit"}]'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$(echo "$nat" | jq -c .)")")
    assert_equals '17' "$(echo "$out" | jq -r '.bundle.comments[] | select(.line) | .line')" "anchor: changed line → inline"
    assert_equals 'file' "$(echo "$out" | jq -r '[.bundle.comments[] | select(.subjectType)][0].subjectType')" \
        "anchor: unchanged line (e.g. an uncommitted change) → file-level"
    assert_equals '2' "$(echo "$out" | jq '.bundle.comments | length')" "anchor: file not in diff → no comment"
    assert_matches '### Body notes' "$(echo "$out" | jq -r '.bundle.bodyText')" "anchor: file not in diff → body note"
    assert_matches '`other.py:3` — Not in diff' "$(echo "$out" | jq -r '.bundle.bodyText')" "anchor: body note keeps where it pointed"
}

test_thin_core_anchor_path_scope() {
    local args out
    # A scoped review's changed-lines block names only the scoped files, so a stray finding
    # outside the scope lands in the body by the file-not-in-diff rule.
    args=$(_tc_args pr "$_TC_REPO $_TC_BASE...$_TC_HEAD -- lib" | jq -c '.pathScope = "lib" | .changedLinesBlock = "Changed lines:\nlib/a.py: 1-5\n"')
    out=$(_tc_run "$args" "$(_tc_native_text "$_TC_NAT_NIT")")
    assert_equals 'APPROVE 0' "$(echo "$out" | jq -r '"\(.bundle.verdict) \(.bundle.comments | length)"')" "path scope: out-of-scope finding posts no comment"
    assert_matches '`stats.py:12`' "$(echo "$out" | jq -r '.bundle.bodyText')" "path scope: out-of-scope finding is a body note"
}

test_thin_core_native_and_ruff_merge() {
    local specs out
    specs='{"ruff":[{"file":"stats.py","line":18,"rule_id":"F841","severity":"Suggestion","description":"Unused variable.","suggested_fix":"Remove it."}]}'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$_TC_NAT_IMPORTANT")" "$specs")
    assert_equals '1' "$(echo "$out" | jq '.bundle.comments | length')" "merge: native and ruff on adjacent lines → one comment"
    assert_matches '^\*\*Important\*\* — 2 findings at this location' "$(echo "$out" | jq -r '.bundle.comments[0].body')" \
        "merge: the more severe finding heads the group"
    assert_matches 'Unused variable' "$(echo "$out" | jq -r '.bundle.comments[0].body')" "merge: the ruff finding is in the merged comment"
}

test_thin_core_pre_existing_never_blocks() {
    local nat out
    nat='[{"file":"stats.py","line":12,"summary":"Old bug. Fix: clamp.","failure_scenario":"last_n([1],5) is wrong.","severity":"pre_existing"}]'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$nat")")
    assert_equals 'APPROVE' "$(echo "$out" | jq -r '.bundle.verdict')" "pre-existing: never blocks"
    assert_matches '^\*\*Suggestion\*\* — Pre-existing, not blocking' "$(echo "$out" | jq -r '.bundle.comments[0].body')" \
        "pre-existing: annotation renders on the first line"
    assert_matches 'last_n\(\[1\],5\) is wrong\.' "$(echo "$out" | jq -r '.bundle.comments[0].body')" "comment: failure_scenario rendered verbatim"
    assert_matches '\*\*Suggested fix:\*\* clamp\.' "$(echo "$out" | jq -r '.bundle.comments[0].body')" "comment: suggested fix rendered"
}

test_thin_core_personal_rule_filtered_in_flow() {
    local nat out
    nat='[{"file":"stats.py","line":12,"summary":"No docstring. Fix: add one.","failure_scenario":"Breaks ~/.claude/CLAUDE.md: \"doc comments\".","severity":"nit"}]'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$nat")")
    assert_equals '0' "$(echo "$out" | jq '.bundle.comments | length')" "personal rule: cited finding not posted"
    assert_equals 'rule-source drop' "$(echo "$out" | jq -r '.bundle.log.findings[0] | "\(.filtered) \(.posting)"')" \
        "personal rule: logged filtered rule-source"
}

test_thin_core_local_mode() {
    local out body
    out=$(_tc_run "$(_tc_args local)" "$(_tc_native_text "$_TC_NAT_IMPORTANT")")
    body=$(echo "$out" | jq -r '.bundle.bodyText')
    assert_equals 'NONE 0' "$(echo "$out" | jq -r '"\(.bundle.verdict) \(.bundle.comments | length)"')" "local: no verdict, no comments"
    assert_not_matches 'REQUEST_CHANGES|APPROVE' "$body" "local: no headline"
    assert_not_matches 'code-review-suite -->' "$body" "local: no marker"
    assert_matches '\*\*Important\*\* \(native\)' "$body" "local: each finding names its source"
    out=$(_tc_run "$(_tc_args local)" 'null')
    assert_matches '^> Native review did not run' "$(echo "$out" | jq -r '.bundle.bodyText')" "local: native-not-run note leads"
}

test_thin_core_native_dispatch_shape() {
    local out
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text '[]')")
    assert_equals 'code-review-suite:native-reviewer 600000 false' \
        "$(echo "$out" | jq -r '.dispatches[] | select(.label == "native") | "\(.opts.agentType) \(.opts.stallMs) \(.opts.hasSchema)"')" \
        "dispatch: native-reviewer type, 600 s stall budget, no schema"
    assert_matches "^Skill args: high $_TC_REPO $_TC_BASE\.\.\.$_TC_HEAD\$" \
        "$(echo "$out" | jq -r '.dispatches[] | select(.label == "native") | .prompt' | head -1)" "dispatch: Skill args line is high + the target"
    assert_equals 'housekeeper,native,ruff' "$(echo "$out" | jq -r '[.dispatches[].label] | sort | join(",")')" \
        "dispatch: native plus the flagged static specialists only"
}

test_thin_core_voice_native_only() {
    local specs out
    specs='{"ruff":[{"file":"lib/a.py","line":2,"rule_id":"E501","severity":"Suggestion","description":"Line too long.","suggested_fix":"Wrap."}]}'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$_TC_NAT_IMPORTANT")" "$specs" '{"edits":[{"index":0,"description":"One short.","suggested_fix":"add 1."}]}')
    assert_equals '1' "$(echo "$out" | jq '.editorCalls | length')" "voice: one editor call"
    assert_not_matches 'Line too long' "$(echo "$out" | jq -r '.editorCalls[0].prompt')" "voice: static findings never sent"
    assert_not_matches 'returns \[\]' "$(echo "$out" | jq -r '.editorCalls[0].prompt')" "voice: failure_scenario never sent"
    assert_matches 'One short\.' "$(echo "$out" | jq -r '.bundle.comments[] | select(.path == "stats.py") | .body')" "voice: accepted edit renders"
}

test_thin_core_log_shape() {
    local specs out schema
    schema="$REPO_ROOT/plugins/code-review-suite/includes/finding-schema.json"
    specs='{"ruff":[{"file":"lib/a.py","line":2,"rule_id":"E501","severity":"Suggestion","description":"Line too long.","suggested_fix":"Wrap.","confidence":100}]}'
    out=$(_tc_run "$(_tc_args)" "$(_tc_native_text "$_TC_NAT_IMPORTANT")" "$specs")
    assert_equals 'native 2.1.332' "$(echo "$out" | jq -r '.bundle.log.meta | "\(.finder) \(.cli_version)"')" "log: meta finder and cli_version"
    assert_equals '1' "$(echo "$out" | jq '[.bundle.log.cogs[] | select(.phase == "native")] | length')" "log: one native cog"
    assert_equals 'Off by one. Fix: add 1.' "$(echo "$out" | jq -r '.bundle.log.cogs[] | select(.phase == "native") | .output.findings[0].summary')" \
        "log: native cog keeps the raw array before normalisation"
    assert_equals '[]' "$(echo "$out" | jq -c --slurpfile s "$schema" \
        '([.bundle.log.findings[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties | keys)')" \
        "log: every finding-record key is in the schema"
    assert_equals '[]' "$(echo "$out" | jq -c --slurpfile s "$schema" \
        '[$s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.required[] as $k
          | .bundle.log.findings[] | select(has($k) | not) | $k] | unique')" "log: every finding record has the required keys"
    assert_equals '[]' "$(echo "$out" | jq -c --slurpfile s "$schema" \
        '(.bundle.log.meta | keys) - ($s[0]["$defs"].sealedBundle.properties.log.properties.meta.properties | keys)')" \
        "log: every meta key is in the schema"
    assert_equals '[]' "$(echo "$out" | jq -c --slurpfile s "$schema" \
        '(.bundle | keys) - ($s[0]["$defs"].sealedBundle.properties | keys)')" "bundle: every top-level key is in the schema"
    assert_equals 'null' "$(echo "$out" | jq -r '.bundle.log.findings[] | select(.source == "ruff") | .confidence')" "log: static confidence dropped"
    assert_equals '{"Critical":0,"Important":1,"Suggestion":1}' "$(echo "$out" | jq -c '.bundle.counts.severity')" "counts: by severity"
    assert_equals '{"native":1,"ruff":1}' "$(echo "$out" | jq -c '.bundle.counts.source')" "counts: by source"
}

test_thin_core_bare_invocation_inert() {
    local out
    out=$(_tc_run '{"agentPrompt":"x","route":"full"}' 'null')
    assert_equals 'NONE 0' "$(echo "$out" | jq -r '"\(.bundle.verdict) \(.dispatches | length)"')" \
        "bare: no nativeTarget → inert bundle, nothing dispatched"
}

# --- parseChangedLines (moved from the retired panel suite) -------------------------

_tc_changed() {
    _tc_call parseChangedLines "$(jq -cn --arg b "$1" '[$b]')"
}

# parseChangedLines expands N-M ranges, keeps bare ints and `near N` anchors, and gives a
# (deleted) file an empty set and an (empty — rename only) file no entry.
test_thin_core_parse_changed_lines_grammar() {
    local out
    out=$(_tc_changed 'Changed lines:
a.cs: 12-14, 17, near 22
b.cs: 5
r.txt: (empty — rename only)
d.cs (deleted): near 1
')
    assert_equals '[12,13,14,17,22]' "$(echo "$out" | jq -c '.["a.cs"]')" "changed lines: N-M range expands, bare int and near anchor kept"
    assert_equals '[5]' "$(echo "$out" | jq -c '.["b.cs"]')" "changed lines: bare integer parsed"
    assert_equals '[]' "$(echo "$out" | jq -c '.["d.cs"] // "absent"')" "changed lines: deleted file has no postable lines"
    assert_equals 'null' "$(echo "$out" | jq -c '.["r.txt"]')" "changed lines: rename-only file absent"
}

# An empty block parses to {}: the fail-safe that moves every finding to the body.
test_thin_core_parse_changed_lines_empty_is_failsafe() {
    assert_equals '{}' "$(_tc_changed '')" "changed lines: empty block → {}"
}
