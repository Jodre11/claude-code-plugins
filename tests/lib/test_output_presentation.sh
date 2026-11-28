#!/usr/bin/env bash
# Output-presentation tests: finding/log schema, anchor ladder, body construction, the
# Dependency Freshness section, co-located merging and the local-mode bundle. review-core.js
# runs end to end through tests/lib/_tc_runner.js: native returns a fixture findings array and
# the static specialists return fixture findings, so every assertion runs through the real
# guards, verdict and renderers.

_op_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# $CHANGED_LINES_BLOCK for the fixtures below. The housekeeper manifests
# (.github/workflows/ci.yml, Directory.Packages.props) are deliberately ABSENT: the
# housekeeper audits the whole touched project, so its findings must bypass the anchor guard
# and keep their file:line in the freshness table.
_OP_CHANGED_BLOCK='Changed lines:\na.py: 1-60\nb.py: 1-40\n'
_OP_REPO='/tmp/fx-repo'
_OP_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

# Review args. $1 review mode (pr|local, default pr); $2 flags json (default {"py":true}).
_op_args() {
    local mode="${1:-pr}" flags="${2:-}"
    [ -n "$flags" ] || flags='{"py":true}'
    jq -cn --arg mode "$mode" --argjson flags "$flags" --arg cl "$(printf '%b' "$_OP_CHANGED_BLOCK")" \
        --arg r "$_OP_REPO" --arg h "$_OP_SHA" \
        '{agentPrompt: "x", flags: $flags, reviewMode: $mode, base: "main", headSha: $h,
          emptyTreeMode: false, pathScope: "", tempDir: "/tmp/claude-test/x", repoDir: $r,
          changedLinesBlock: $cl, nativeTarget: ($r + " " + ("b" * 40) + "..." + $h), cliVersion: "2.1.332"}'
}

# Native's result text for a findings array ($1, default []).
_op_native() {
    jq -cn --arg a "${1:-[]}" '"Review done.\n\n```json\n" + $a + "\n```"'
}

# One native finding. $1 file, $2 line, $3 severity (important|nit|pre_existing), $4 summary.
_op_n() {
    jq -cn --arg f "$1" --argjson l "$2" --arg s "$3" --arg m "$4" \
        '{file: $f, line: $l, summary: $m, failure_scenario: ("How " + $m + " shows."), severity: $s}'
}

# Runs review-core. $1 args, $2 native findings array json, $3 specialists json.
_op_run_core() {
    WF="$(_op_cr_dir)/workflows/review-core.js" TC_ARGS="$1" TC_NATIVE="$(_op_native "$2")" \
        TC_SPECIALISTS="${3:-{\}}" node "$REPO_ROOT/tests/lib/_tc_runner.js" 2>&1 | jq -c '.bundle' 2>/dev/null \
        || echo 'RUNNER_FAILED'
}

# Guard: the run produced a JSON bundle. Fails loudly (and returns 1) otherwise, so a
# crash never surfaces as a cascade of misleading assertion failures.
_op_is_bundle() {
    if echo "$1" | jq -e .verdict >/dev/null 2>&1; then
        return 0
    fi
    fail "$2: valid JSON bundle" "probe: ${1:0:200}"
    return 1
}

test_finding_file_is_optional() {
    local schema
    schema="$(_op_cr_dir)/includes/finding-schema.json"
    # `file` MUST NOT be in finding.required (fileless findings are valid).
    if jq -e '.["$defs"].finding.required | index("file")' "$schema" >/dev/null 2>&1; then
        fail "finding.file is optional" "file still listed in finding.required"
    else
        pass "finding.file is optional (not in required)"
    fi
    if jq -e '.["$defs"].finding.properties.file' "$schema" >/dev/null 2>&1; then
        pass "finding.file still a declared property"
    else
        fail "finding.file still a declared property" "file property was removed entirely"
    fi
    if jq -e '.["$defs"].sealedBundle.properties.comments.items.properties.subjectType' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.comments[].subjectType documented"
    else
        fail "sealedBundle.comments[].subjectType documented" "missing optional file-level anchor discriminator"
    fi
    if jq -e '.["$defs"].sealedBundle.properties.log' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.log documented"
    else
        fail "sealedBundle.log documented" "missing log payload field"
    fi
    assert_equals 'null' "$(jq -c '.["$defs"].finding.properties.confidence' "$schema")" "finding has no confidence field"
}

# The log sub-schema declares additionalProperties:false, so every key and enum value the
# real bundle emits must be declared there. Drives a run that populates every posting route.
test_log_payload_conforms_to_schema() {
    local schema nat specs out extra
    schema="$(_op_cr_dir)/includes/finding-schema.json"
    nat="[$(_op_n a.py 10 important bug),$(_op_n b.py 5 nit 'Breaks ~/.claude/CLAUDE.md: style')]"
    specs='{"housekeeper":[{"file":".github/workflows/ci.yml","line":12,"severity":"Suggestion","description":"actions/checkout is at v3; latest GA is v4.","suggested_fix":"bump"}],"ruff":[{"file":"zz.py","line":3,"rule_id":"F401","severity":"Critical","description":"unused","suggested_fix":"drop"}]}'
    out=$(_op_run_core "$(_op_args pr '{"py":true,"housekeeping":true}')" "$nat" "$specs")
    _op_is_bundle "$out" "log schema conformance" || return 0
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.findings[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties | keys)')
    assert_equals "[]" "$extra" "every log.findings key is declared in the schema"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '($b.log.meta | keys) - ($s[0]["$defs"].sealedBundle.properties.log.properties.meta.properties | keys)')
    assert_equals "[]" "$extra" "every log.meta key is declared in the schema"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.findings[].posting] | unique) - $s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties.posting.enum')
    assert_equals "[]" "$extra" "every emitted posting route is in the schema posting enum"
    assert_equals '["drop","inline","table"]' "$(echo "$out" | jq -c '[.log.findings[].posting] | unique')" \
        "fixture exercises all three posting routes"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.findings[].filtered | select(.)] | unique) - $s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties.filtered.enum')
    assert_equals "[]" "$extra" "every emitted filtered value is in the schema enum"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.cogs[].phase] | unique) - $s[0]["$defs"].sealedBundle.properties.log.properties.cogs.items.properties.phase.enum')
    assert_equals "[]" "$extra" "every emitted cog phase is in the schema enum"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.comments[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.comments.items.properties | keys)')
    assert_equals "[]" "$extra" "every comment key is declared in the schema"
}

test_anchor_ladder_routes_comments() {
    local nat out total line_c file_c
    # Three native findings: on a changed line, on an unchanged line, and in a file not in the diff.
    nat="[$(_op_n a.py 42 important line-anchored),$(_op_n b.py 90 important file-anchored),$(_op_n docs/x.md 4 nit 'outside the diff')]"
    out=$(_op_run_core "$(_op_args)" "$nat")
    _op_is_bundle "$out" "anchor ladder" || return 0
    total=$(echo "$out" | jq '.comments | length')
    line_c=$(echo "$out" | jq '[.comments[] | select(.subjectType == null and .line != null)] | length')
    file_c=$(echo "$out" | jq '[.comments[] | select(.subjectType == "file")] | length')
    assert_equals "2" "$total" "fileless finding produces no comment (2 of 3 anchor)"
    assert_equals "1" "$line_c" "changed-line finding → line-level comment"
    assert_equals "1" "$file_c" "unchanged-line finding → file-level comment"
    if echo "$out" | jq -r '.bodyText' | grep -qF "outside the diff"; then
        pass "fileless finding detail lands in body"
    else
        fail "fileless finding detail lands in body" "fileless description not found in bodyText"
    fi
}

test_body_is_headline_and_index() {
    local out body
    out=$(_op_run_core "$(_op_args)" "[$(_op_n a.py 42 important 'the defect. Fix: fix it.')]")
    _op_is_bundle "$out" "body construction" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    if echo "$body" | head -1 | grep -qF "**REQUEST_CHANGES** — 1 blocking finding(s)"; then
        pass "body opens with bold verdict headline and reason"
    else
        fail "body opens with bold verdict headline and reason" "first line: $(echo "$body" | head -1)"
    fi
    if echo "$body" | grep -qE "the defect.*a\.py:42.*↳ inline"; then
        pass "finding index summary line present"
    else
        fail "finding index summary line present" "expected compact index line for finding"
    fi
    assert_not_matches "Panel Assessment|pruned" "$body" "no assessment and no pruned-findings line"
    assert_not_matches "Dependency Freshness" "$body" "no freshness section when the housekeeper did not run"
    assert_matches 'code-review-suite -->$' "$body" "body ends with the marker"
}

# --- Dependency Freshness section -------------------------------------------------------
# Three states, rendered by review-core: absent when the housekeeper did not run cleanly; an
# all-current line when it ran and found nothing; otherwise one table row per finding.

test_freshness_absent_when_housekeeper_did_not_run() {
    local out mode
    for mode in pr local; do
        out=$(_op_run_core "$(_op_args "$mode")" '[]')
        _op_is_bundle "$out" "freshness absent ($mode, not dispatched)" || return 0
        assert_not_matches "Dependency Freshness" "$(echo "$out" | jq -r '.bodyText')" \
            "$mode: no freshness section when the housekeeper was not dispatched"
        out=$(_op_run_core "$(_op_args "$mode" '{"housekeeping":true}')" '[]' \
            '{"housekeeper":{"status":"skipped","statusReason":"python3 too old","findings":[]}}')
        _op_is_bundle "$out" "freshness absent ($mode, skipped)" || return 0
        assert_not_matches "Dependency Freshness" "$(echo "$out" | jq -r '.bodyText')" \
            "$mode: no freshness section when the housekeeper skipped"
    done
}

test_freshness_all_current_when_housekeeper_clean() {
    local out body mode
    for mode in pr local; do
        out=$(_op_run_core "$(_op_args "$mode" '{"housekeeping":true}')" '[]')
        _op_is_bundle "$out" "freshness all-current ($mode)" || return 0
        body=$(echo "$out" | jq -r '.bodyText')
        assert_matches "### Dependency Freshness" "$body" "$mode: freshness heading present when the housekeeper ran"
        assert_matches "✓ Dependencies checked — all current" "$body" "$mode: clean housekeeper renders the all-current line"
        assert_not_matches "Latest GA" "$body" "$mode: no empty table under the all-current line"
    done
}

test_freshness_table_rows_parse_description() {
    local specs out body mode
    # Row 1: plain template. Row 2: pipe in the item and a trailing note. Row 3: description
    # off the template keeps its full text in Notes. Manifests are outside the diff on purpose.
    specs='{"housekeeper":[{"file":".github/workflows/ci.yml","line":12,"severity":"Suggestion","description":"actions/checkout is at v3; latest GA is v4.","suggested_fix":"bump"},{"file":"Directory.Packages.props","line":7,"severity":"Suggestion","description":"Foo|Bar is at 1.0.0; latest GA is 2.0.0. Licence changed from MIT to BUSL.","suggested_fix":"bump"},{"file":"Directory.Packages.props","line":9,"severity":"Suggestion","description":"Old.Pkg is deprecated by its publisher.","suggested_fix":"replace"}]}'
    for mode in pr local; do
        out=$(_op_run_core "$(_op_args "$mode" '{"housekeeping":true}')" '[]' "$specs")
        _op_is_bundle "$out" "freshness rows ($mode)" || return 0
        body=$(echo "$out" | jq -r '.bodyText')
        if echo "$body" | grep -qxF '| Package / Action | Current | Latest GA | File | Notes |'; then
            pass "$mode: freshness table header rendered"
        else
            fail "$mode: freshness table header rendered" "header row missing"
        fi
        if echo "$body" | grep -qxF '| actions/checkout | v3 | v4 | `.github/workflows/ci.yml:12` |  |'; then
            pass "$mode: template description parsed into item/current/latest with file:line kept"
        else
            fail "$mode: template description parsed into item/current/latest with file:line kept" \
                "row: $(echo "$body" | grep -F 'actions/checkout')"
        fi
        if echo "$body" | grep -qxF '| Foo\|Bar | 1.0.0 | 2.0.0 | `Directory.Packages.props:7` | Licence changed from MIT to BUSL. |'; then
            pass "$mode: pipe in a cell escaped; trailing note lands in Notes"
        else
            fail "$mode: pipe in a cell escaped; trailing note lands in Notes" \
                "row: $(echo "$body" | grep -F 'Bar')"
        fi
        if echo "$body" | grep -qxF '|  |  |  | `Directory.Packages.props:9` | Old.Pkg is deprecated by its publisher. |'; then
            pass "$mode: off-template description keeps its full text in Notes"
        else
            fail "$mode: off-template description keeps its full text in Notes" \
                "row: $(echo "$body" | grep -F 'Old.Pkg')"
        fi
        assert_not_matches "all current" "$body" "$mode: real drift not collapsed to 'all current'"
    done
}

test_freshness_drift_with_keyword_pkg() {
    local specs out body
    # A package whose name contains a column keyword ("Current") must still render a row.
    specs='{"housekeeper":[{"file":"x.csproj","line":4,"severity":"Suggestion","description":"Current.User.Sdk is at 1.0.0; latest GA is 2.0.0.","suggested_fix":"bump"}]}'
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" '[]' "$specs")
    _op_is_bundle "$out" "freshness keyword package" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    if echo "$body" | grep -qF "| Current.User.Sdk | 1.0.0 | 2.0.0 |"; then
        pass "drift row with keyword package name survives into body"
    else
        fail "drift row with keyword package name survives into body" "row missing from freshness table"
    fi
    assert_not_matches "all current" "$body" "real drift not collapsed to 'all current'"
}

# Housekeeper findings are informational: they never post inline, never enter the findings
# index, and never move the verdict, even labelled Important on a changed line.
test_freshness_findings_never_post_or_block() {
    local specs out body
    specs='{"housekeeper":[{"file":"a.py","line":10,"severity":"Important","description":"Risky.Pkg is at 1.0.0; latest GA is 3.0.0.","suggested_fix":"bump"}]}'
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" '[]' "$specs")
    _op_is_bundle "$out" "housekeeper informational" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "an Important housekeeper finding does not block"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "housekeeper finding posts no inline comment"
    assert_not_matches "### Findings" "$body" "housekeeper finding not in the findings index"
    assert_matches "Risky.Pkg" "$body" "housekeeper finding rendered in the freshness table"
    assert_equals "housekeeper|table|false" \
        "$(echo "$out" | jq -r '.log.findings[0] | "\(.source)|\(.posting)|\(.verdict_relevant)"')" \
        "log: housekeeper finding on the table route, not verdict-relevant"
}

test_local_mode_emits_log() {
    local nat specs out body
    nat="[$(_op_n a.py 42 important 'the blocking defect. Fix: guard it.'),$(_op_n b.py 5 nit 'tidy name. Fix: rename.')]"
    specs='{"ruff":[{"file":"b.py","line":30,"rule_id":"E501","severity":"Suggestion","description":"line too long","suggested_fix":"wrap"}]}'
    out=$(_op_run_core "$(_op_args local)" "$nat" "$specs")
    _op_is_bundle "$out" "local mode" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "NONE" "$(echo "$out" | jq -r '.verdict')" "local mode verdict is NONE"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "local mode posts no comments"
    assert_equals "3" "$(echo "$out" | jq '.log.findings | length')" "local mode bundle carries the durable log payload"
    assert_equals "$body" "$(echo "$out" | jq -r '.log.bodyText')" "local mode log.bodyText is the report"
    assert_not_matches "REQUEST_CHANGES" "$body" "local report carries no verdict headline"
    assert_matches '#### `a.py:42`' "$body" "local report heads each finding with its location"
    assert_matches "the blocking defect" "$body" "local report renders the blocking finding"
    assert_matches "Suggested fix:\*\* guard it" "$body" "local report renders the suggested fix in full"
    assert_matches "\*\*Suggestion\*\* \(ruff\)" "$body" "local report names the static source"
}

test_host_documents_file_level_comments() {
    local path
    path="$(_op_cr_dir)/skills/review-gh-pr/SKILL.md"
    if grep -qF 'subject_type' "$path" && grep -qF 'subjectType' "$path"; then
        pass "host documents file-level comment posting: skills/review-gh-pr/SKILL.md"
    else
        fail "host documents file-level comment posting: skills/review-gh-pr/SKILL.md" \
            "Class C must handle bundle comments with subjectType=file via a gh api subject_type=file call"
    fi
}

test_host_documents_durable_log() {
    local cr file path
    cr=$(_op_cr_dir)
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        path="$cr/$file"
        if grep -qF 'orchestration.full_log' "$path" \
           && grep -qF '.claude/code-review-suite/logs' "$path" \
           && grep -qF 'PLUGIN_SHA' "$path"; then
            pass "host documents durable opt-in log: $file"
        else
            fail "host documents durable opt-in log: $file" \
                "Step 3.6 must gate on orchestration.full_log (default off), write to ~/.claude/code-review-suite/logs, and resolve PLUGIN_SHA"
        fi
    done
    if grep -qiE 'default.*(false|off)|off by default' "$cr/skills/review-gh-pr/SKILL.md"; then
        pass "durable log documented as default-off"
    else
        fail "durable log documented as default-off" "the toggle's default-false must be explicit"
    fi
}

test_no_teasing_footer() {
    local out body
    if grep -qF 'additional finding' "$(_op_cr_dir)/workflows/review-core.js"; then
        fail "no teasing footer in review-core.js" "the 'N additional finding(s)' footer must be removed"
    else
        pass "no teasing footer in review-core.js"
    fi
    out=$(_op_run_core "$(_op_args)" "[$(_op_n a.py 5 nit later)]")
    _op_is_bundle "$out" "no teasing footer" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "a nit alone → APPROVE"
    assert_not_matches "additional finding" "$body" "APPROVE body has no teasing footer"
}

# --- Co-located findings ------------------------------------------------------------------
# Native and a static tool flagging the same spot must reach the author as ONE thread: posted
# findings on the same file within three lines merge into one comment, anchored at the most
# severe, with every member's text kept, and one index line. Rendering only.
test_colocated_findings_merge_into_one_comment() {
    local nat specs out body first b
    nat="[$(_op_n a.py 11 important 'null deref on retry.'),$(_op_n a.py 40 important 'separate defect.'),$(_op_n a.py 13 nit 'same retry path, native nit.')]"
    specs='{"ruff":[{"file":"a.py","line":10,"rule_id":"F841","severity":"Suggestion","description":"same retry path, ruff view.","suggested_fix":"drop"}]}'
    out=$(_op_run_core "$(_op_args)" "$nat" "$specs")
    _op_is_bundle "$out" "co-located merge" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "merging never changes the verdict"
    assert_equals "2" "$(echo "$out" | jq '.comments | length')" "three co-located findings + one distant → 2 comments"
    first=$(echo "$out" | jq -c '[.comments[] | select(.line < 20)][0]')
    assert_equals "11" "$(echo "$first" | jq -r '.line')" "merged comment anchored at the most severe member"
    assert_matches "^\*\*Important\*\* — 3 findings at this location" "$(echo "$first" | jq -r '.body')" \
        "merged comment opens with the top severity and the member count"
    b=$(echo "$first" | jq -r '.body')
    assert_matches "null deref on retry" "$b" "merged comment keeps the native Important text"
    assert_matches "native nit" "$b" "merged comment keeps the native nit text"
    assert_matches "ruff view" "$b" "merged comment keeps the ruff text"
    assert_equals "2" "$(echo "$body" | grep -c '^- \*\*\[')" "index has one line per comment"
    assert_matches "\(\+2 more here\) — \`a.py:11\`" "$body" "merged index line counts the extra members"
    assert_equals "4" "$(echo "$out" | jq '.log.findings | length')" "the log keeps every member separately"
}

# Local mode groups co-located findings the same way.
test_local_report_groups_colocated_findings() {
    local out body
    out=$(_op_run_core "$(_op_args local)" "[$(_op_n a.py 11 important 'null deref.'),$(_op_n a.py 12 important 'same spot.')]")
    _op_is_bundle "$out" "local co-located" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "1" "$(echo "$body" | grep -c '^#### ')" "one heading for the co-located pair"
    assert_matches "2 findings at this location" "$body" "local group shows the member count"
}
