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

# Runs review-core.mjs end-to-end. $1 = args json, $2 = synth envelope json,
# $3 = round-1 specialist findings map (domain -> findings[]), optional.
_pe_run_core() {
    local wf r1
    wf="$(_pe_cr_dir)/workflows/review-core.mjs"
    r1='{}'
    [ "$#" -ge 3 ] && r1="$3"
    WF="$wf" PE_ARGS="$1" PE_ENV="$2" PE_R1="$r1" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const env = JSON.parse(process.env.PE_ENV);
        const r1 = JSON.parse(process.env.PE_R1);
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "review-synthesiser") return env;
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "op-" + label, escalations: [] };
            return { status: "ok", findings: r1[label] || [] };  // specialists
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const timeoutId = setTimeout(() => { process.stdout.write("TIMEOUT"); process.exit(1); }, 15000);
        (async () => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            const bundle = await fn(agent, parallel, pipeline, phase, log, process.env.PE_ARGS, workflow);
            clearTimeout(timeoutId);
            process.stdout.write(JSON.stringify(bundle));
            process.exit(0);
        })().catch(e => { clearTimeout(timeoutId); process.stdout.write("THREW: " + e.message); process.exit(1); });
    ' 2>&1
}

_pe_args() {
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\"}"
}

test_phaselog_captures_round1_and_meta() {
    local args env out
    args=$(_pe_args)
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> ok\n"}'
    out=$(_pe_run_core "$args" "$env")
    # meta carries the four reconstruction keys.
    assert_equals "main" "$(echo "$out" | jq -r '.log.meta.base')" "log.meta.base captured"
    assert_equals "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$(echo "$out" | jq -r '.log.meta.head_sha')" "log.meta.head_sha captured"
    assert_equals "false" "$(echo "$out" | jq -r '.log.meta.empty_tree_mode')" "log.meta.empty_tree_mode captured"
    # One round-1 cog per core specialist (8 core, no conditionals).
    assert_equals "8" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="round1")] | length')" "8 round-1 cogs (core list)"
    # Round-1 cogs carry no input (diff reconstructed from meta).
    assert_equals "null" "$(echo "$out" | jq -r '[.log.cogs[] | select(.phase=="round1")][0].input // "null"')" "round-1 cog omits input"
}

test_phaselog_captures_cross_io() {
    local args env out
    args=$(_pe_args)
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> ok\n"}'
    out=$(_pe_run_core "$args" "$env")
    # Cross cogs: one per stochastic domain (8 core, none static here).
    assert_equals "8" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="cross")] | length')" "8 cross cogs"
    # Each cross cog carries its peer-set input and opinions output.
    local first
    first=$(echo "$out" | jq -c '[.log.cogs[] | select(.phase=="cross")][0]')
    assert_equals "false" "$(echo "$first" | jq -r '(.input.peer == null)')" "cross cog carries peer input"
    assert_equals "false" "$(echo "$first" | jq -r '(.output.opinionsMarkdown == null)')" "cross cog carries opinions output"
    # Peer set excludes the reviewer's own domain.
    local dom hasself
    dom=$(echo "$first" | jq -r '.domain')
    hasself=$(echo "$first" | jq -r --arg d "$dom" '.input.peer | has($d)')
    assert_equals "false" "$hasself" "cross cog peer set excludes own domain"
}
