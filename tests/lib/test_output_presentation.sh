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

test_posted_set_respects_verdict() {
    local args env_rc out sha40
    sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    args="{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"logTimestamp\":\"2026-06-18T00:00:00Z\"}"
    # REQUEST_CHANGES with a conf-55 consensus Suggestion: it MUST still post.
    env_rc='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"Important [#1] conf 88","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":88,"description":"d1","suggested_fix":"f1"},{"file":"b.cs","line":20,"severity":"Suggestion","confidence":55,"description":"d2","suggested_fix":"f2"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> prose\n## Consensus Findings\n#### Finding #1 — t1\n#### Finding #2 — t2\n"}'
    out=$(_op_run_core "$args" "$env_rc")
    # Both consensus findings post as comments under REQUEST_CHANGES.
    local n
    n=$(echo "$out" | jq '.comments | length' 2>/dev/null || echo "ERR")
    assert_equals "2" "$n" "REQUEST_CHANGES posts all consensus findings (incl conf 55)"
}
