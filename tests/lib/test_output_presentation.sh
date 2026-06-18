#!/usr/bin/env bash
# Output-presentation tests: schema relaxation, log payload, anchor ladder,
# body construction, dependency reformat. review-core.mjs logic is exercised by
# evaluating the whole script with mock globals (see _op_run_core below).

_op_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
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

# Runs review-core.mjs end-to-end with mock globals. $1 = JSON args string.
# A crafted mock agent returns the envelope passed via OP_SYNTH_ENVELOPE (json)
# for the synthesiser label, and empty-ok specialist/cross outputs otherwise.
_op_run_core() {
    local wf
    wf="$(_op_cr_dir)/workflows/review-core.mjs"
    WF="$wf" OP_ARGS="$1" OP_SYNTH_ENVELOPE="$2" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const synthEnv = JSON.parse(process.env.OP_SYNTH_ENVELOPE);
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "review-synthesiser") return synthEnv;
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "", escalations: [] };
            return { status: "ok", findings: [] };           // specialists
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

_op_args() {
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"logTimestamp\":\"2026-06-18T00:00:00Z\"}"
}

test_posted_set_respects_verdict() {
    local args env_rc out
    args=$(_op_args)
    # REQUEST_CHANGES with a conf-55 consensus Suggestion: it MUST still post.
    env_rc='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"Important [#1] conf 88","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":88,"description":"d1","suggested_fix":"f1"},{"file":"b.cs","line":20,"severity":"Suggestion","confidence":55,"description":"d2","suggested_fix":"f2"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> prose\n## Consensus Findings\n#### Finding #1 — t1\n#### Finding #2 — t2\n"}'
    out=$(_op_run_core "$args" "$env_rc")
    # Both consensus findings post as comments under REQUEST_CHANGES.
    local n
    n=$(echo "$out" | jq '.comments | length' 2>/dev/null || echo "ERR")
    assert_equals "2" "$n" "REQUEST_CHANGES posts all consensus findings (incl conf 55)"
}

test_anchor_ladder_routes_comments() {
    local args env out
    args=$(_op_args)
    # Three findings: line-anchored, file-anchored (line 0), fileless (no file).
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"r","tiers":{"consensus":[{"file":"a.cs","line":42,"severity":"Important","confidence":90,"description":"line-anchored","suggested_fix":"f"},{"file":"b.cs","line":0,"severity":"Important","confidence":90,"description":"file-anchored","suggested_fix":"f"}],"synthesiser":[{"line":0,"severity":"Suggestion","confidence":90,"description":"fileless repo-wide","suggested_fix":"add changelog"}],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> prose\n"}'
    out=$(_op_run_core "$args" "$env")
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
    local args env out body
    args=$(_op_args)
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"consensus Important [#1] confidence 88","tiers":{"consensus":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"the defect","suggested_fix":"fix it"}],"synthesiser":[],"contested":[{"file":"a.cs","line":42,"severity":"Critical","confidence":82,"description":"CONTESTED SEVERITY","suggested_fix":"x"}],"dismissed":[{"file":"z.cs","line":1,"severity":"Suggestion","confidence":40,"description":"DISMISSED NOISE","suggested_fix":"x"}]},"bodyText":"## Summary\n1 file | 1 finding\n## Synthesiser Assessment\n> This is the centrepiece.\n> Second line.\n## Consensus Findings\n#### Finding #1 — the defect\nblah\n## Contested Findings\nCONTESTED SEVERITY\n## Dismissed Findings\nDISMISSED NOISE\n## Cost\ntokens: 999\n"}'
    out=$(_op_run_core "$args" "$env")
    body=$(echo "$out" | jq -r '.bodyText')
    # Headline verdict at the very top, bold.
    if echo "$body" | head -1 | grep -qF "**REQUEST_CHANGES**"; then
        pass "body opens with bold verdict headline"
    else
        fail "body opens with bold verdict headline" "first line: $(echo "$body" | head -1)"
    fi
    # Assessment promoted: the centrepiece text present WITHOUT a leading '>'.
    if echo "$body" | grep -qF "This is the centrepiece." && ! echo "$body" | grep -qE "^> This is the centrepiece"; then
        pass "Synthesiser Assessment promoted out of block-quote"
    else
        fail "Synthesiser Assessment promoted out of block-quote" "assessment still quoted or missing"
    fi
    # Finding index: one summary line pointing inline; NOT the full prose block.
    if echo "$body" | grep -qE "the defect.*a.cs:42"; then
        pass "finding index summary line present"
    else
        fail "finding index summary line present" "expected compact index line for finding"
    fi
    # Dropped sections absent from the body.
    assert_not_matches "DISMISSED NOISE" "$body" "Dismissed section dropped from body"
    assert_not_matches "CONTESTED SEVERITY" "$body" "Contested section dropped from body"
    assert_not_matches "tokens: 999" "$body" "Cost section dropped from body"
    assert_not_matches "## Summary" "$body" "Summary counts dropped from body"
}

test_log_payload_flattens_all_tiers() {
    local args env out
    args=$(_op_args)
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"consensus Important [#1] confidence 88","tiers":{"consensus":[{"file":"a.cs","line":42,"severity":"Important","confidence":88,"description":"d","suggested_fix":"f"}],"synthesiser":[{"line":0,"severity":"Suggestion","confidence":60,"description":"s","suggested_fix":"f"}],"contested":[{"file":"a.cs","line":42,"severity":"Critical","confidence":82,"description":"c","suggested_fix":"f"}],"dismissed":[{"file":"z.cs","line":1,"severity":"Suggestion","confidence":40,"description":"x","suggested_fix":"f"}]},"bodyText":"## Synthesiser Assessment\n> prose\n"}'
    out=$(_op_run_core "$args" "$env")
    local nlog rel
    nlog=$(echo "$out" | jq '.log.findings | length')
    assert_equals "4" "$nlog" "log payload flattens all four tiers (4 findings)"
    # The conf-88 consensus Important is verdict_relevant under RC row 3.
    rel=$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant == true)] | length')
    assert_equals "1" "$rel" "exactly the rubric-driving finding marked verdict_relevant"
    # Full verbatim prose retained in the log.
    if echo "$out" | jq -r '.log.bodyText' | grep -qF "## Synthesiser Assessment"; then
        pass "log.bodyText retains verbatim synthesiser prose"
    else
        fail "log.bodyText retains verbatim synthesiser prose" "prose missing from log payload"
    fi
}

test_freshness_states() {
    local args base_env out
    args=$(_op_args)
    # No Dependency Freshness section at all → omitted from body.
    base_env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> all good\n"}'
    out=$(_op_run_core "$args" "$base_env")
    assert_not_matches "Dependency Freshness" "$(echo "$out" | jq -r '.bodyText')" "no freshness section when synth emitted none"
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
    local cr file ok=1
    cr=$(_op_cr_dir)
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if grep -qF 'orchestration.full_log' "$path" \
           && grep -qF '.claude/code-review-suite/logs' "$path" \
           && grep -qF 'plugin_sha' "$path"; then
            pass "host documents durable opt-in log: $file"
        else
            fail "host documents durable opt-in log: $file" \
                "Step 7 must gate on orchestration.full_log (default off), write to ~/.claude/code-review-suite/logs, and stamp plugin_sha"
            ok=0
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
    local cr f
    cr=$(_op_cr_dir)
    # The core must not emit the count-of-hidden-findings footer.
    if grep -qF 'additional finding' "$cr/workflows/review-core.mjs"; then
        fail "no teasing footer in review-core.mjs" "the 'N additional finding(s)' footer must be removed"
    else
        pass "no teasing footer in review-core.mjs"
    fi
    # Behavioural: an APPROVE with a sub-75 consensus finding posts NO footer.
    local args env out body
    args=$(_op_args)
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":5,"severity":"Suggestion","confidence":55,"description":"low conf","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> ok\n"}'
    out=$(_op_run_core "$args" "$env")
    body=$(echo "$out" | jq -r '.bodyText')
    assert_not_matches "additional finding" "$body" "APPROVE body has no teasing footer for the dropped conf-55 finding"
}

test_end_to_end_pr80_shape() {
    local args env out body
    args=$(_op_args)
    env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"consensus Important [#1] confidence 88","tiers":{"consensus":[{"file":"RightToWorkClient.cs","line":240,"severity":"Important","confidence":88,"description":"SUPERSEDED filter case-sensitive.","suggested_fix":"OrdinalIgnoreCase"},{"file":"PollRtwHandlerLog.cs","line":104,"severity":"Suggestion","confidence":70,"description":"EventId ordering.","suggested_fix":"reorder"}],"synthesiser":[{"file":"RightToWorkStatusWire.cs","line":11,"severity":"Suggestion","confidence":55,"description":"missing XML docs.","suggested_fix":"add summary"}],"contested":[{"file":"RightToWorkClient.cs","line":240,"severity":"Critical","confidence":82,"description":"compliance bypass.","suggested_fix":"x"}],"dismissed":[{"file":"x.cs","line":1,"severity":"Suggestion","confidence":40,"description":"var doc false positive.","suggested_fix":"x"}]},"bodyText":"## Summary\n16 files\n## Synthesiser Assessment\n> Intent vs implementation analysis.\n## Consensus Findings\n#### Finding #1 — SUPERSEDED\n## Dependency Freshness\n> deps\n| Package | Current | Latest GA | Drift | Notes |\n|---|---|---|---|---|\n| AWSSDK | 4.0.4 | 4.0.5 | patch | x |\n## Dismissed Findings\nvar doc\n## Cost\ntokens 999\n"}'
    out=$(_op_run_core "$args" "$env")
    body=$(echo "$out" | jq -r '.bodyText')
    assert_equals "3" "$(echo "$out" | jq '.comments | length')" "3 posted findings become comments (2 consensus + 1 synth)"
    assert_matches "REQUEST_CHANGES" "$(echo "$body" | head -1)" "headline verdict"
    assert_not_matches "compliance bypass" "$body" "contested dispute not in body"
    assert_not_matches "var doc" "$body" "dismissed not in body"
    assert_not_matches "tokens 999" "$body" "cost not in body"
    if echo "$body" | grep -qF "Latest GA"; then
        pass "dependency table retained in body"
    else
        fail "dependency table retained in body" "freshness table missing"
    fi
    assert_equals "5" "$(echo "$out" | jq '.log.findings | length')" "log retains all 5 findings across tiers"
}
