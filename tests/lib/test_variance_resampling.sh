#!/usr/bin/env bash
# Variance-resampling boundary-gate tests. Runs review-core.mjs end-to-end with
# mock globals: round-1 synth returns VR_ENV1, round-2 synth returns VR_ENV2;
# stochastic specialists return VR_STOCH_R1 / VR_STOCH_R2 keyed by phase. The
# harness emits a JSON probe: the bundle, per-phase dispatch counts, synth-call
# count, and the verbatim round-2 synth prompt (for agreement-count inspection).

_vr_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# $1 args json, $2 env1 json, $3 env2 json, $4 stoch-r1 map json, $5 stoch-r2 map json
_vr_run_core() {
    local wf stochR1 stochR2
    wf="$(_vr_cr_dir)/workflows/review-core.mjs"
    # Default the stochastic maps to an empty object. NB: a `${4:-{}}` default is
    # mis-parsed by bash as `${4:-{}` plus a literal `}`, which appends a stray brace
    # to a supplied arg and yields malformed JSON — assign the defaults explicitly.
    stochR1='{}'
    stochR2='{}'
    [ "$#" -ge 4 ] && stochR1="$4"
    [ "$#" -ge 5 ] && stochR2="$5"
    WF="$wf" VR_ARGS="$1" VR_ENV1="$2" VR_ENV2="$3" VR_STOCH_R1="$stochR1" VR_STOCH_R2="$stochR2" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const env1 = JSON.parse(process.env.VR_ENV1);
        const env2 = JSON.parse(process.env.VR_ENV2);
        const r1 = JSON.parse(process.env.VR_STOCH_R1);
        const r2 = JSON.parse(process.env.VR_STOCH_R2);
        let synthCalls = 0;
        let round2SynthPrompt = "";
        const dispatch = { dispatch: 0, resample: 0 };
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            const ph = (opts && opts.phase) || "";
            if (label === "review-synthesiser") {
                synthCalls++;
                if (synthCalls >= 2) round2SynthPrompt = prompt;
                return synthCalls === 1 ? env1 : env2;
            }
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "", escalations: [] };
            // specialist dispatch
            if (ph === "resample") { dispatch.resample++; return { status: "ok", findings: r2[label] || [] }; }
            dispatch.dispatch++;
            return { status: "ok", findings: r1[label] || [] };
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
            const bundle = await fn(agent, parallel, pipeline, phase, log, process.env.VR_ARGS, workflow);
            clearTimeout(timeoutId);
            process.stdout.write(JSON.stringify({ bundle, dispatch, synthCalls, round2SynthPrompt }));
            process.exit(0);
        })().catch(e => { clearTimeout(timeoutId); process.stdout.write("THREW: " + e.message); process.exit(1); });
    ' 2>&1
}

_vr_args() {
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\"}"
}

_vr_args_local() {
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"local\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\"}"
}

# B1: APPROVE with a consensus Important in [60,80) → fire round 2; env2 flips to RC.
test_gate_fires_b1_and_uses_round2() {
    local out
    local env1='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":72,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    local env2='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"Important [#1] conf 88","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":88,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r2\n"}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env2")
    assert_equals "2" "$(echo "$out" | jq -r '.synthCalls')" "B1 fires: synthesiser runs twice"
    assert_equals "8" "$(echo "$out" | jq -r '.dispatch.resample')" "B1 fires: 8 stochastic specialists re-dispatched (core only)"
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.bundle.verdict')" "B1 fires: round-2 verdict adopted"
}

# Strong APPROVE (no consensus Important, no contested) → no round 2.
test_gate_skips_strong_approve() {
    local out
    local env1='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> clean\n"}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env1")
    assert_equals "1" "$(echo "$out" | jq -r '.synthCalls')" "strong APPROVE: synthesiser runs once"
    assert_equals "0" "$(echo "$out" | jq -r '.dispatch.resample')" "strong APPROVE: no resample"
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.bundle.verdict')" "strong APPROVE: verdict stable"
}

# B2: APPROVE with a contested finding present → fire round 2.
test_gate_fires_b2_contested() {
    local out
    local env1='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[{"file":"a.cs","line":5,"severity":"Important","confidence":55,"description":"contested","suggested_fix":"f"}],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env1")
    assert_equals "2" "$(echo "$out" | jq -r '.synthCalls')" "B2 fires: synthesiser runs twice on contested presence"
    assert_equals "8" "$(echo "$out" | jq -r '.dispatch.resample')" "B2 fires: stochastic specialists re-dispatched"
}

# Strong RC (consensus Critical, or Important >= 80) → no round 2.
test_gate_skips_strong_rc() {
    local out
    local env1='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"Important [#1] conf 90","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":90,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env1")
    assert_equals "1" "$(echo "$out" | jq -r '.synthCalls')" "strong RC: synthesiser runs once"
    assert_equals "0" "$(echo "$out" | jq -r '.dispatch.resample')" "strong RC: no resample"
}

# B3: RC driven solely by a single Important in [70,80) → fire round 2.
test_gate_fires_b3_single_shaky_important() {
    local out
    local env1='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"Important [#1] conf 74","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":74,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env1")
    assert_equals "2" "$(echo "$out" | jq -r '.synthCalls')" "B3 fires: shaky single Important re-sampled"
    assert_equals "8" "$(echo "$out" | jq -r '.dispatch.resample')" "B3 fires: stochastic specialists re-dispatched"
}

# RC with two corroborating Importants >= 70 → not "sole" → no round 2.
test_gate_skips_rc_multiple_importants() {
    local out
    local env1='{"verdict":"REQUEST_CHANGES","rubricRowApplied":3,"rubricReason":"two Important","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":74,"description":"d1","suggested_fix":"f"},{"file":"b.cs","line":20,"severity":"Important","confidence":76,"description":"d2","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env1")
    assert_equals "1" "$(echo "$out" | jq -r '.synthCalls')" "multiple corroborating Importants: no resample"
    assert_equals "0" "$(echo "$out" | jq -r '.dispatch.resample')" "multiple corroborating Importants: stochastic dispatched once"
}

# Union: a finding present in both draws within +/-3 lines gets agreement 2; a
# round-2-only finding gets agreement 1. Inspect the round-2 synth prompt JSON.
test_union_agreement_counts_in_round2_prompt() {
    local out prompt
    local env1='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":72,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    local env2="$env1"
    local r1='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":72,"description":"dup pred","suggested_fix":"f"}]}'
    # round 2: one matching (line 12, within +/-3 of 10) + one new (line 99).
    local r2='{"correctness":[{"file":"a.cs","line":12,"severity":"Important","confidence":70,"description":"dup pred","suggested_fix":"f"},{"file":"a.cs","line":99,"severity":"Suggestion","confidence":60,"description":"new","suggested_fix":"f"}]}'
    out=$(_vr_run_core "$(_vr_args)" "$env1" "$env2" "$r1" "$r2")
    # Guard: a malformed probe (e.g. a harness regression that breaks the node mock)
    # must fail loudly here, not silently abort the whole `set -euo pipefail` suite via a
    # downstream empty jq/grep read. See the brace-default bug fixed in commit 6ebc1a2.
    if ! echo "$out" | jq -e . >/dev/null 2>&1; then
        fail "union: _vr_run_core emitted valid JSON" "probe was not valid JSON: ${out:0:120}"
        return
    fi
    prompt=$(echo "$out" | jq -r '.round2SynthPrompt')
    # The matched cluster carries agreement 2; the round-2-only finding carries agreement 1.
    # `|| true` keeps a no-match grep from aborting the suite under `set -euo pipefail`.
    local agreements
    agreements=$(echo "$prompt" | grep -oE '"agreement":[0-9]+' | sort | uniq -c | tr -s ' ' || true)
    if echo "$prompt" | grep -qE '"description":"dup pred"[^}]*"agreement":2|"agreement":2[^}]*"description":"dup pred"'; then
        pass "union: cross-draw match annotated agreement 2"
    else
        # Fallback: assert at least one agreement:2 and one agreement:1 present.
        if echo "$prompt" | grep -qF '"agreement":2' && echo "$prompt" | grep -qF '"agreement":1'; then
            pass "union: round-2 prompt carries both agreement 2 and agreement 1"
        else
            fail "union: round-2 prompt carries agreement counts" "agreements seen: $agreements"
        fi
    fi
}

# local mode returns before the gate → never resamples, verdict NONE.
test_gate_never_fires_in_local_mode() {
    local out
    local env1='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":72,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    out=$(_vr_run_core "$(_vr_args_local)" "$env1" "$env1")
    assert_equals "1" "$(echo "$out" | jq -r '.synthCalls')" "local mode: synthesiser runs once"
    assert_equals "0" "$(echo "$out" | jq -r '.dispatch.resample')" "local mode: no resample"
    assert_equals "NONE" "$(echo "$out" | jq -r '.bundle.verdict')" "local mode: verdict NONE"
}
