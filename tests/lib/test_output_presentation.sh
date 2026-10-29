#!/usr/bin/env bash
# Output-presentation tests: finding/log schema, anchor ladder, body construction, the
# Dependency Freshness section, and the local-mode bundle. review-core.js is exercised by
# evaluating the whole script with mock globals (see _op_run_core below): specialists return
# fixture findings, three mock panelists return fixture votes, and the panel writer returns
# fixture prose, so every assertion runs through the real tally, rubric and renderers.

_op_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Runs review-core.js end-to-end with mock globals.
# $1 args json; $2 specialists map json (domain → findings array, or a full
# {status, findings} object to simulate a skipped/failed specialist); $3 panelists json
# (array, one entry per seat; a missing entry is a dropped panelist); $4 writer bodyText as
# a JSON string literal (optional, so '\n' escapes become real newlines).
_op_run_core() {
    local wf writer
    wf="$(_op_cr_dir)/workflows/review-core.js"
    writer='"## Panel Assessment\n> panel prose\n"'
    [ "$#" -ge 4 ] && writer="$4"
    WF="$wf" OP_ARGS="$1" OP_SPECIALISTS="$2" OP_PANELISTS="$3" OP_WRITER="$writer" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const specialists = JSON.parse(process.env.OP_SPECIALISTS);
        const panelists = JSON.parse(process.env.OP_PANELISTS);
        const writerBody = JSON.parse(process.env.OP_WRITER);
        const roster = ["Cronus", "Rhea", "Oceanus", "Hyperion", "Themis"];
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "panel-writer") return { bodyText: writerBody };
            if (label.startsWith("panel-")) {
                const i = roster.indexOf(label.slice("panel-".length));
                return panelists[i] === undefined ? null : panelists[i];
            }
            const s = specialists[label];
            if (Array.isArray(s)) return { status: "ok", findings: s };
            if (s) return s;
            return { status: "ok", findings: [] };
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const timeoutId = setTimeout(() => { process.stdout.write("TIMEOUT"); process.exit(1); }, 10000);
        (async () => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            const bundle = await fn(agent, parallel, pipeline, phase, log, process.env.OP_ARGS, workflow);
            clearTimeout(timeoutId);
            process.stdout.write(JSON.stringify(bundle));
            process.exit(0);
        })().catch(e => { clearTimeout(timeoutId); process.stdout.write("THREW: " + e.message); process.exit(1); });
    ' 2>&1
}

# $CHANGED_LINES_BLOCK for the fixtures below. The housekeeper manifests
# (.github/workflows/ci.yml, Directory.Packages.props) are deliberately ABSENT: the
# housekeeper audits the whole touched project, so its findings must bypass the
# line-hallucination guard and keep their file:line in the freshness table.
_OP_CHANGED_BLOCK='Changed lines:\na.cs: 1-60\nb.cs: 1-40\nRightToWorkClient.cs: 230-250\nPollRtwHandlerLog.cs: 100-110\nRightToWorkStatusWire.cs: 1-20\n'

# Panel-run args. $1 review mode (pr|local, default pr); $2 flags json (default {}).
_op_args() {
    local mode="${1:-pr}" flags="${2:-}"
    [ -n "$flags" ] || flags='{}'
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":${flags},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"${mode}\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\",\"panelSize\":3,\"panelBrief\":\"BRIEF\",\"changedLinesBlock\":\"${_OP_CHANGED_BLOCK}\"}"
}

# One vote. $1 finding_id, $2 is_real, $3 severity, $4 tractability.
_op_v() {
    echo "{\"finding_id\":$1,\"is_real\":$2,\"severity\":\"$3\",\"tractability\":\"$4\",\"blocks_goal\":false,\"rationale\":\"r\"}"
}

# Three panelists casting the same votes ($1, json array). $2 (optional json array) is
# raised by the first panelist only, so it lands as a solo (uncorroborated) raise.
_op_pans() {
    jq -cn --argjson v "$1" --argjson r "${2:-[]}" \
        '[range(3)] | map(. as $i | {votes: $v, raised: (if $i == 0 then $r else [] end)})'
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
    local cr
    cr=$(_op_cr_dir)
    local schema="$cr/includes/finding-schema.json"
    # `file` MUST NOT be in finding.required (fileless findings are valid).
    if jq -e '.["$defs"].finding.required | index("file")' "$schema" >/dev/null 2>&1; then
        fail "finding.file is optional" "file still listed in finding.required"
    else
        pass "finding.file is optional (not in required)"
    fi
    # `file` MUST still be a declared property (optional, not removed).
    if jq -e '.["$defs"].finding.properties.file' "$schema" >/dev/null 2>&1; then
        pass "finding.file still a declared property"
    else
        fail "finding.file still a declared property" "file property was removed entirely"
    fi
    # sealedBundle.comments items document the optional subjectType discriminator.
    if jq -e '.["$defs"].sealedBundle.properties.comments.items.properties.subjectType' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.comments[].subjectType documented"
    else
        fail "sealedBundle.comments[].subjectType documented" "missing optional file-level anchor discriminator"
    fi
    # sealedBundle documents the log payload field.
    if jq -e '.["$defs"].sealedBundle.properties.log' "$schema" >/dev/null 2>&1; then
        pass "sealedBundle.log documented"
    else
        fail "sealedBundle.log documented" "missing log payload field"
    fi
}

# The log sub-schema declares additionalProperties:false, so every key and enum value the
# real bundle emits must be declared there — otherwise the documented contract lies about
# the durable log. Drives a run that populates every tier and every posting route.
test_log_payload_conforms_to_schema() {
    local schema specs votes pans out
    schema="$(_op_cr_dir)/includes/finding-schema.json"
    # correctness a.cs:10 → consensus inline; style b.cs:5 Bounded → body; style b.cs:9
    # Open-ended → dropped; efficiency a.cs:30 voted not real → dismissed; housekeeper → table.
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":90,"description":"bug","suggested_fix":"f"}],"style":[{"file":"b.cs","line":5,"severity":"Suggestion","confidence":80,"description":"follow","suggested_fix":"f"},{"file":"b.cs","line":9,"severity":"Suggestion","confidence":80,"description":"vague","suggested_fix":"f"}],"efficiency":[{"file":"a.cs","line":30,"severity":"Important","confidence":60,"description":"fp","suggested_fix":"f"}],"housekeeper":[{"file":".github/workflows/ci.yml","line":12,"severity":"Suggestion","confidence":100,"description":"actions/checkout is at v3; latest GA is v4.","suggested_fix":"bump"}]}'
    votes="[$(_op_v 0 true Important Bounded),$(_op_v 1 true Suggestion Bounded),$(_op_v 2 true Suggestion Open-ended),$(_op_v 3 false Important Bounded),$(_op_v 4 true Suggestion Mechanical)]"
    pans=$(_op_pans "$votes")
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" "$specs" "$pans")
    _op_is_bundle "$out" "log schema conformance" || return 0
    local extra
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.findings[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties | keys)')
    assert_equals "[]" "$extra" "every log.findings key is declared in the schema"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '($b.log.meta | keys) - ($s[0]["$defs"].sealedBundle.properties.log.properties.meta.properties | keys)')
    assert_equals "[]" "$extra" "every log.meta key is declared in the schema"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.findings[].tier] | unique) - $s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties.tier.enum')
    assert_equals "[]" "$extra" "every emitted tier is in the schema tier enum"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.log.findings[].posting] | unique) - $s[0]["$defs"].sealedBundle.properties.log.properties.findings.items.properties.posting.enum')
    assert_equals "[]" "$extra" "every emitted posting route is in the schema posting enum"
    assert_equals '["body","drop","inline","table"]' "$(echo "$out" | jq -c '[.log.findings[].posting] | unique')" \
        "fixture exercises all four posting routes"
    extra=$(jq -cn --argjson b "$out" --slurpfile s "$schema" \
        '([$b.comments[] | keys[]] | unique) - ($s[0]["$defs"].sealedBundle.properties.comments.items.properties | keys)')
    assert_equals "[]" "$extra" "every comment key is declared in the schema"
}

test_posted_set_respects_verdict() {
    local specs pans out
    # Consensus Important (blocks) + a Mechanical Suggestion: both post inline under RC.
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":88,"description":"d1","suggested_fix":"f1"}],"style":[{"file":"b.cs","line":20,"severity":"Suggestion","confidence":55,"description":"d2","suggested_fix":"f2"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Important Bounded),$(_op_v 1 true Suggestion Mechanical)]")
    out=$(_op_run_core "$(_op_args)" "$specs" "$pans")
    _op_is_bundle "$out" "posted set" || return 0
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "consensus Important → REQUEST_CHANGES"
    assert_equals "2" "$(echo "$out" | jq '.comments | length')" "blocking finding and Mechanical Suggestion both post inline"
}

test_anchor_ladder_routes_comments() {
    local specs pans out
    # Three inline-routed findings: line-anchored, file-anchored (line 0), fileless (<n/a>).
    specs='{"correctness":[{"file":"a.cs","line":42,"severity":"Important","confidence":90,"description":"line-anchored","suggested_fix":"f"},{"file":"b.cs","line":0,"severity":"Important","confidence":90,"description":"file-anchored","suggested_fix":"f"}],"alignment":[{"file":"<n/a>","line":0,"severity":"Suggestion","confidence":90,"description":"fileless repo-wide","suggested_fix":"add changelog"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Important Bounded),$(_op_v 1 true Important Bounded),$(_op_v 2 true Suggestion Mechanical)]")
    out=$(_op_run_core "$(_op_args)" "$specs" "$pans")
    _op_is_bundle "$out" "anchor ladder" || return 0
    local total line_c file_c
    total=$(echo "$out" | jq '.comments | length')
    line_c=$(echo "$out" | jq '[.comments[] | select(.subjectType == null and .line != null)] | length')
    file_c=$(echo "$out" | jq '[.comments[] | select(.subjectType == "file")] | length')
    assert_equals "2" "$total" "fileless finding produces no comment (2 of 3 anchor)"
    assert_equals "1" "$line_c" "line-anchored finding → line-level comment"
    assert_equals "1" "$file_c" "file-anchored finding (line 0, has file) → file-level comment"
    # The fileless finding's detail must appear in the body instead.
    if echo "$out" | jq -r '.bodyText' | grep -qF "fileless repo-wide"; then
        pass "fileless finding detail lands in body"
    else
        fail "fileless finding detail lands in body" "fileless description not found in bodyText"
    fi
}

test_body_is_headline_and_index() {
    local specs pans writer out body
    specs='{"correctness":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"the defect","suggested_fix":"fix it"},{"file":"a.cs","line":50,"severity":"Suggestion","confidence":40,"description":"DISMISSED NOISE","suggested_fix":"x"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Important Bounded),$(_op_v 1 false Suggestion Bounded)]")
    # The writer emits extra sections; only the Panel Assessment is promoted into the body.
    # Its own Dependency Freshness section must not leak through either — review-core
    # renders that table itself, and the housekeeper did not run here.
    writer='"## Summary\n1 file | 1 finding\n## Panel Assessment\n> This is the centrepiece.\n> Second line.\n## Consensus Findings\n#### Finding #1 — the defect\nblah\n## Dismissed Findings\nDISMISSED NOISE\n## Dependency Freshness\n| WRITER TABLE | 1 | 2 |\n## Cost\ntokens: 999\n"'
    out=$(_op_run_core "$(_op_args)" "$specs" "$pans" "$writer")
    _op_is_bundle "$out" "body construction" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    # Headline verdict at the very top, bold, with the rubric reason.
    if echo "$body" | head -1 | grep -qF "**REQUEST_CHANGES** — consensus Important"; then
        pass "body opens with bold verdict headline and rubric reason"
    else
        fail "body opens with bold verdict headline and rubric reason" "first line: $(echo "$body" | head -1)"
    fi
    # Assessment promoted: the centrepiece text present WITHOUT a leading '>'.
    if echo "$body" | grep -qF "This is the centrepiece." && ! echo "$body" | grep -qE "^> This is the centrepiece"; then
        pass "Panel Assessment promoted out of block-quote"
    else
        fail "Panel Assessment promoted out of block-quote" "assessment still quoted or missing"
    fi
    # Finding index: one summary line pointing inline; NOT the full prose block.
    if echo "$body" | grep -qE "the defect.*a\.cs:42.*↳ inline"; then
        pass "finding index summary line present"
    else
        fail "finding index summary line present" "expected compact index line for finding"
    fi
    # Writer-only sections are absent from the body.
    assert_not_matches "DISMISSED NOISE" "$body" "dismissed finding absent from body"
    assert_not_matches "tokens: 999" "$body" "writer Cost section dropped from body"
    assert_not_matches "## Summary" "$body" "writer Summary counts dropped from body"
    assert_not_matches "WRITER TABLE" "$body" "writer-rendered freshness table dropped from body"
    assert_not_matches "Dependency Freshness" "$body" "no freshness section when the housekeeper did not run"
}

test_log_payload_flattens_all_tiers() {
    local specs pans out
    # consensus Important; contested Bounded Suggestion; dismissed (not real); dismissed
    # (open-ended Suggestion, dropped).
    specs='{"correctness":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"d","suggested_fix":"f"}],"style":[{"file":"b.cs","line":5,"severity":"Suggestion","confidence":60,"description":"s","suggested_fix":"f"},{"file":"b.cs","line":9,"severity":"Suggestion","confidence":60,"description":"o","suggested_fix":"f"}],"efficiency":[{"file":"a.cs","line":30,"severity":"Suggestion","confidence":40,"description":"x","suggested_fix":"f"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Important Bounded),$(_op_v 1 true Suggestion Bounded),$(_op_v 2 true Suggestion Open-ended),$(_op_v 3 false Suggestion Bounded)]")
    out=$(_op_run_core "$(_op_args)" "$specs" "$pans")
    _op_is_bundle "$out" "log flattening" || return 0
    assert_equals "4" "$(echo "$out" | jq '.log.findings | length')" "log payload flattens every tier (4 findings)"
    assert_equals '{"consensus":1,"contested":1,"dismissed":2}' \
        "$(echo "$out" | jq -c '.log.findings | group_by(.tier) | map({(.[0].tier): length}) | add')" \
        "log findings split 1 consensus / 1 contested / 2 dismissed"
    # Only the consensus Important drives REQUEST_CHANGES (rubric row 3).
    assert_equals "1" "$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant == true)] | length')" \
        "exactly the rubric-driving finding marked verdict_relevant"
    # Full verbatim writer prose retained in the log.
    if echo "$out" | jq -r '.log.bodyText' | grep -qF "## Panel Assessment"; then
        pass "log.bodyText retains verbatim panel-writer prose"
    else
        fail "log.bodyText retains verbatim panel-writer prose" "prose missing from log payload"
    fi
}

# --- Dependency Freshness section -------------------------------------------------------
# Three states, rendered by review-core (never by the writer): absent when the housekeeper
# did not run cleanly; an all-current line when it ran and nothing survived the panel's
# existence gate; otherwise one table row per housekeeper finding.

test_freshness_absent_when_housekeeper_did_not_run() {
    local out mode
    for mode in pr local; do
        # Not dispatched: flags.housekeeping off.
        out=$(_op_run_core "$(_op_args "$mode")" '{}' "$(_op_pans '[]')")
        _op_is_bundle "$out" "freshness absent ($mode, not dispatched)" || return 0
        assert_not_matches "Dependency Freshness" "$(echo "$out" | jq -r '.bodyText')" \
            "$mode: no freshness section when the housekeeper was not dispatched"
        # Dispatched but skipped (nothing was checked): still absent, never "all current".
        out=$(_op_run_core "$(_op_args "$mode" '{"housekeeping":true}')" \
            '{"housekeeper":{"status":"skipped","statusReason":"python3 too old","findings":[]}}' "$(_op_pans '[]')")
        _op_is_bundle "$out" "freshness absent ($mode, skipped)" || return 0
        assert_not_matches "Dependency Freshness" "$(echo "$out" | jq -r '.bodyText')" \
            "$mode: no freshness section when the housekeeper skipped"
    done
}

test_freshness_all_current_when_housekeeper_clean() {
    local out body mode
    for mode in pr local; do
        out=$(_op_run_core "$(_op_args "$mode" '{"housekeeping":true}')" '{}' "$(_op_pans '[]')")
        _op_is_bundle "$out" "freshness all-current ($mode)" || return 0
        body=$(echo "$out" | jq -r '.bodyText')
        assert_matches "### Dependency Freshness" "$body" "$mode: freshness heading present when the housekeeper ran"
        assert_matches "✓ Dependencies checked — all current" "$body" "$mode: clean housekeeper renders the all-current line"
        assert_not_matches "Latest GA" "$body" "$mode: no empty table under the all-current line"
    done
    # A housekeeper finding the panel majority dismisses as not real leaves nothing current
    # to report: the section collapses to the all-current line rather than a stale row.
    local specs
    specs='{"housekeeper":[{"file":"package.json","line":3,"severity":"Suggestion","confidence":100,"description":"left-pad is at 1.0.0; latest GA is 1.3.0.","suggested_fix":"bump"}]}'
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" "$specs" "$(_op_pans "[$(_op_v 0 false Suggestion Mechanical)]")")
    _op_is_bundle "$out" "freshness all-current after dismissal" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_matches "all current" "$body" "dismissed housekeeper finding → all-current line"
    assert_not_matches "left-pad" "$body" "dismissed housekeeper finding renders no row"
}

test_freshness_table_rows_parse_description() {
    local specs pans out body mode
    # Row 1: plain template. Row 2: pipe in the item and a trailing note. Row 3: description
    # off the template keeps its full text in Notes. Manifests are outside the diff on purpose.
    specs='{"housekeeper":[{"file":".github/workflows/ci.yml","line":12,"severity":"Suggestion","confidence":100,"description":"actions/checkout is at v3; latest GA is v4.","suggested_fix":"bump"},{"file":"Directory.Packages.props","line":7,"severity":"Suggestion","confidence":100,"description":"Foo|Bar is at 1.0.0; latest GA is 2.0.0. Licence changed from MIT to BUSL.","suggested_fix":"bump"},{"file":"Directory.Packages.props","line":9,"severity":"Suggestion","confidence":100,"description":"Old.Pkg is deprecated by its publisher.","suggested_fix":"replace"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Suggestion Mechanical),$(_op_v 1 true Suggestion Mechanical),$(_op_v 2 true Suggestion Mechanical)]")
    for mode in pr local; do
        out=$(_op_run_core "$(_op_args "$mode" '{"housekeeping":true}')" "$specs" "$pans")
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
    # Local mode keeps the writer prose ahead of the table.
    assert_matches "panel prose" "$body" "local: writer prose retained alongside the freshness table"
}

test_freshness_drift_with_keyword_pkg() {
    local specs out body
    # A package whose name contains a column keyword ("Current") must still render a row
    # and must not collapse the section to "all current".
    specs='{"housekeeper":[{"file":"x.csproj","line":4,"severity":"Suggestion","confidence":100,"description":"Current.User.Sdk is at 1.0.0; latest GA is 2.0.0.","suggested_fix":"bump"}]}'
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" "$specs" "$(_op_pans "[$(_op_v 0 true Suggestion Mechanical)]")")
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
# index, and never move the verdict — even when the panel votes one Important and it sits
# on a changed line. A real upgrade concern reaches the verdict only as a panelist raise.
test_freshness_findings_never_post_or_block() {
    local specs pans out body
    specs='{"housekeeper":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"Risky.Pkg is at 1.0.0; latest GA is 3.0.0.","suggested_fix":"bump"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Important Mechanical)]")
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" "$specs" "$pans")
    _op_is_bundle "$out" "housekeeper informational" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "unanimous-real Important housekeeper finding does not block"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "housekeeper finding posts no inline comment"
    assert_not_matches "### Findings" "$body" "housekeeper finding not in the findings index"
    assert_matches "Risky.Pkg" "$body" "housekeeper finding rendered in the freshness table"
    assert_equals "contested|Suggestion|table|false" \
        "$(echo "$out" | jq -r '.log.findings[0] | "\(.tier)|\(.severity)|\(.posting)|\(.verdict_relevant)"')" \
        "log: housekeeper finding is contested Suggestion on the table route, not verdict-relevant"
}

test_local_mode_emits_log() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"d","suggested_fix":"f"}],"style":[{"file":"b.cs","line":5,"severity":"Suggestion","confidence":60,"description":"s","suggested_fix":"f"}],"efficiency":[{"file":"a.cs","line":30,"severity":"Suggestion","confidence":40,"description":"x","suggested_fix":"f"}]}'
    pans=$(_op_pans "[$(_op_v 0 true Important Bounded),$(_op_v 1 true Suggestion Mechanical),$(_op_v 2 false Suggestion Bounded)]")
    out=$(_op_run_core "$(_op_args local)" "$specs" "$pans")
    _op_is_bundle "$out" "local mode" || return 0
    # Local mode: no verdict, no comments — but the durable log MUST be present.
    assert_equals "NONE" "$(echo "$out" | jq -r '.verdict')" "local mode verdict is NONE"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "local mode posts no comments"
    assert_equals "3" "$(echo "$out" | jq '.log.findings | length')" "local mode bundle carries the durable log payload (all tiers)"
    if echo "$out" | jq -r '.log.bodyText' | grep -qF "## Panel Assessment"; then
        pass "local mode log.bodyText retains verbatim prose"
    else
        fail "local mode log.bodyText retains verbatim prose" "prose missing from local-mode log payload"
    fi
    # Local mode returns the writer prose verbatim (no headline/index rewrite).
    assert_matches "## Panel Assessment" "$(echo "$out" | jq -r '.bodyText')" "local mode bodyText is the writer prose"
}

test_host_documents_file_level_comments() {
    local cr file
    cr=$(_op_cr_dir)
    for file in skills/review-gh-pr/SKILL.md; do
        local path="$cr/$file"
        if grep -qF 'subject_type' "$path" && grep -qF 'subjectType' "$path"; then
            pass "host documents file-level comment posting: $file"
        else
            fail "host documents file-level comment posting: $file" \
                "Class C must handle bundle comments with subjectType=file via a gh api subject_type=file call"
        fi
    done
}

test_host_documents_durable_log() {
    local cr file
    cr=$(_op_cr_dir)
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if grep -qF 'orchestration.full_log' "$path" \
           && grep -qF '.claude/code-review-suite/logs' "$path" \
           && grep -qF 'PLUGIN_SHA' "$path"; then
            pass "host documents durable opt-in log: $file"
        else
            fail "host documents durable opt-in log: $file" \
                "Step 3.6 must gate on orchestration.full_log (default off), write to ~/.claude/code-review-suite/logs, and resolve PLUGIN_SHA"
        fi
    done
    # Default-off guarantee must be stated.
    if grep -qiE 'default.*(false|off)|off by default' "$cr/skills/review-gh-pr/SKILL.md"; then
        pass "durable log documented as default-off"
    else
        fail "durable log documented as default-off" "the toggle's default-false must be explicit"
    fi
}

test_no_teasing_footer() {
    local cr
    cr=$(_op_cr_dir)
    # The core must not emit the count-of-hidden-findings footer.
    if grep -qF 'additional finding' "$cr/workflows/review-core.js"; then
        fail "no teasing footer in review-core.js" "the 'N additional finding(s)' footer must be removed"
    else
        pass "no teasing footer in review-core.js"
    fi
    # Behavioural: an APPROVE with a body-routed (Bounded) Suggestion posts NO footer.
    local specs out body
    specs='{"style":[{"file":"a.cs","line":5,"severity":"Suggestion","confidence":55,"description":"later","suggested_fix":"f"}]}'
    out=$(_op_run_core "$(_op_args)" "$specs" "$(_op_pans "[$(_op_v 0 true Suggestion Bounded)]")")
    _op_is_bundle "$out" "no teasing footer" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "Bounded Suggestion alone → APPROVE"
    assert_not_matches "additional finding" "$body" "APPROVE body has no teasing footer"
}

test_no_disclosure_when_nothing_pruned() {
    local specs out body
    # APPROVE with a single Mechanical Suggestion (posted inline) → nothing dropped → no
    # pruned-findings disclosure line.
    specs='{"style":[{"file":"a.cs","line":5,"severity":"Suggestion","confidence":80,"description":"posted","suggested_fix":"f"}]}'
    out=$(_op_run_core "$(_op_args)" "$specs" "$(_op_pans "[$(_op_v 0 true Suggestion Mechanical)]")")
    _op_is_bundle "$out" "no disclosure" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "Mechanical Suggestion posts inline"
    assert_not_matches "pruned" "$body" "no disclosure line when nothing is pruned"
}

test_end_to_end_pr80_shape() {
    local specs votes raised pans out body
    # consensus Important (RightToWorkClient.cs:240), Mechanical Suggestion
    # (PollRtwHandlerLog.cs:104), a solo panel raise (RightToWorkStatusWire.cs:11,
    # Mechanical → inline), a false positive the panel dismisses, and a housekeeper drift row.
    specs='{"correctness":[{"file":"RightToWorkClient.cs","line":240,"severity":"Important","confidence":88,"description":"SUPERSEDED filter case-sensitive.","suggested_fix":"OrdinalIgnoreCase"}],"style":[{"file":"PollRtwHandlerLog.cs","line":104,"severity":"Suggestion","confidence":70,"description":"EventId ordering.","suggested_fix":"reorder"},{"file":"RightToWorkClient.cs","line":231,"severity":"Suggestion","confidence":40,"description":"var doc false positive.","suggested_fix":"x"}],"housekeeper":[{"file":"Directory.Packages.props","line":14,"severity":"Suggestion","confidence":100,"description":"AWSSDK.Core is at 4.0.4; latest GA is 4.0.5.","suggested_fix":"bump"}]}'
    votes="[$(_op_v 0 true Important Bounded),$(_op_v 1 true Suggestion Mechanical),$(_op_v 2 false Suggestion Mechanical),$(_op_v 3 true Suggestion Mechanical)]"
    raised='[{"file":"RightToWorkStatusWire.cs","line":11,"severity":"Suggestion","confidence":55,"description":"missing XML docs.","suggested_fix":"add summary","tractability":"Mechanical"}]'
    pans=$(_op_pans "$votes" "$raised")
    out=$(_op_run_core "$(_op_args pr '{"housekeeping":true}')" "$specs" "$pans" '"## Summary\n16 files\n## Panel Assessment\n> Intent vs implementation analysis.\n## Cost\ntokens 999\n"')
    _op_is_bundle "$out" "end-to-end PR shape" || return 0
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "3" "$(echo "$out" | jq '.comments | length')" "3 inline comments (consensus Important, Mechanical Suggestion, panel raise)"
    assert_matches "REQUEST_CHANGES" "$(echo "$body" | head -1)" "headline verdict"
    assert_matches "Intent vs implementation analysis." "$body" "Panel Assessment promoted"
    assert_not_matches "var doc" "$body" "dismissed finding not in body"
    assert_not_matches "tokens 999" "$body" "cost not in body"
    if echo "$body" | grep -qF '| AWSSDK.Core | 4.0.4 | 4.0.5 |'; then
        pass "dependency drift row in the freshness table"
    else
        fail "dependency drift row in the freshness table" "AWSSDK.Core row missing"
    fi
    assert_equals "5" "$(echo "$out" | jq '.log.findings | length')" "log retains all 5 findings across tiers"
}
