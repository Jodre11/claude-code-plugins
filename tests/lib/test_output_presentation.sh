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
