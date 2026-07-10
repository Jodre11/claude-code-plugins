#!/usr/bin/env bash
# Panel-review path tests. Drives review-core.mjs end-to-end with mock globals:
# specialist dispatch returns PAN_SPECIALISTS[label]; each `panel-<i>` agent returns
# PAN_PANELISTS[i] (null when absent → a dropped panelist); the `panel-writer` agent
# returns {bodyText}. The pure helpers are exercised through the returned bundle,
# mirroring test_variance_resampling.sh (review-core.mjs cannot export them — the
# sandbox evals the stripped source, so an `export function` would break it).

_pan_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# $1 args json, $2 specialists-map json (domain→findings), $3 panelists json (array),
# $4 writer bodyText string (optional, defaults to a minimal valid body).
# $5 synth envelope json (optional, defaults to null → classic path hits Category-C).
_pan_run_core() {
    local wf writerBody synthEnvJson
    wf="$(_pan_cr_dir)/workflows/review-core.mjs"
    writerBody="## Synthesiser Assessment\n> panel prose\n"
    synthEnvJson=""
    [ "$#" -ge 4 ] && writerBody="$4"
    [ "$#" -ge 5 ] && synthEnvJson="$5"
    WF="$wf" PAN_ARGS="$1" PAN_SPECIALISTS="$2" PAN_PANELISTS="$3" PAN_WRITER="$writerBody" PAN_SYNTH_ENV="$synthEnvJson" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const specialists = JSON.parse(process.env.PAN_SPECIALISTS);
        const panelists = JSON.parse(process.env.PAN_PANELISTS);
        const writerBody = process.env.PAN_WRITER;
        const synthEnvRaw = process.env.PAN_SYNTH_ENV;
        const synthEnv = synthEnvRaw ? JSON.parse(synthEnvRaw) : null;
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "panel-writer") return { bodyText: writerBody };
            if (label.startsWith("panel-")) {
                const i = parseInt(label.slice("panel-".length), 10);
                return panelists[i] === undefined ? null : panelists[i];
            }
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "", escalations: [] };
            if (label === "review-synthesiser") return synthEnv;
            return { status: "ok", findings: specialists[label] || [] };  // specialist dispatch
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
            const bundle = await fn(agent, parallel, pipeline, phase, log, process.env.PAN_ARGS, workflow);
            clearTimeout(timeoutId);
            process.stdout.write(JSON.stringify(bundle));
            process.exit(0);
        })().catch(e => { clearTimeout(timeoutId); process.stdout.write("THREW: " + e.message); process.exit(1); });
    ' 2>&1
}

# args for a PR-mode panel run of size N (default 3). No intent ledger (goal absent).
_pan_args() {
    local n="${1:-3}"
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\",\"orchestrationMode\":\"panel\",\"panelSize\":${n},\"panelBrief\":\"BRIEF\"}"
}

# args with a goal-bearing intent ledger (matches the /(^|\n)\s*goal:\s*\S/ detector).
_pan_args_goal() {
    local n="${1:-3}"
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local ledger="Intent ledger:\ngoal: ship the widget end to end.\nnon_goals: none\nsource: pr_body\n"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"${ledger}\",\"orchestrationMode\":\"panel\",\"panelSize\":${n},\"panelBrief\":\"BRIEF\"}"
}

# One Important consensus finding, unanimously voted real by 3 panelists → RC via rubric row 3.
test_panel_unanimous_real_important_is_rc() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":50,"description":"the bug","suggested_fix":"fix"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    if ! echo "$out" | jq -e . >/dev/null 2>&1; then
        fail "panel unanimous-real: valid JSON bundle" "probe: ${out:0:160}"
        return
    fi
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "unanimous-real Important → RC (rubric row 3)"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "the consensus finding posts as one comment"
}

# Split vote (2 real / 1 not_a_problem on N=3): real=2 >= ceil(6/3)=2 → consensus.
# A Suggestion in consensus does not trigger RC → APPROVE.
test_panel_split_majority_real_suggestion_approves() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"nit","suggested_fix":"tidy"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"not_a_problem","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "majority-real Suggestion → APPROVE (no blocking finding)"
    # confidence 80 (real=2, not unanimous) ≥ 75 → posts under APPROVE.
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "80-confidence consensus Suggestion posts under APPROVE"
}

# Contested (1 real / 1 minor / 1 not_a_problem on N=3): real=1 < 2, real+minor=2 > 1 →
# contested tier. Contested findings are not consensus → not posted; verdict APPROVE.
test_panel_contested_not_posted() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":50,"description":"maybe","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"minor","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"not_a_problem","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "contested-only → APPROVE"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "contested finding is not posted (not consensus)"
    assert_equals "contested" "$(echo "$out" | jq -r '.log.findings[0].tier')" "contested finding lands in contested tier"
}

# Dismissed (majority not_a_problem): 1 real / 2 not_a_problem on N=3 → dismissed.
test_panel_dismissed_tier() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Critical","confidence":50,"description":"false alarm","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"not_a_problem","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"not_a_problem","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    # A dismissed Critical must NOT drive RC (it is not in the consensus tier).
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "dismissed Critical does not trigger RC"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority not_a_problem → dismissed"
}

# N=5 supermajority: real=3 < ceil(10/3)=4 → NOT consensus (contested). Proves the
# threshold scales with N (a bare majority on N=5 is not enough for consensus).
test_panel_n5_bare_majority_is_contested() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":50,"description":"split5","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"not_a_problem","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"not_a_problem","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 5)" "$specs" "$pans")
    assert_equals "contested" "$(echo "$out" | jq -r '.log.findings[0].tier')" "N=5 real=3 < 4 → contested, not consensus"
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "N=5 bare-majority Important → APPROVE"
}

# A raised finding corroborated by 2 of 3 panelists (within ±3 lines) → consensus,
# stamped domain "panel". Posted as a comment. Stage-1 findings all not_a_problem.
test_panel_raised_majority_is_consensus() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"n.cs","line":20,"severity":"Important","confidence":40,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[{"file":"n.cs","line":22,"severity":"Important","confidence":90,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "2-of-3 raised Important → consensus → RC row 3"
    assert_equals "1" "$(echo "$out" | jq '[.log.findings[] | select(.domain=="panel")] | length')" "raised finding stamped domain panel"
    # confidence overwritten from corroboration (80), NOT the panelist-supplied 40/90.
    assert_equals "80" "$(echo "$out" | jq -r '[.log.findings[] | select(.domain=="panel")][0].confidence')" "raised confidence set from corroboration, not panelist value"
}

# A solo raise (1 of 3) → contested, confidence 40, not posted, verdict APPROVE.
test_panel_solo_raise_is_low_contested() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"s.cs","line":5,"severity":"Important","confidence":88,"description":"solo concern","suggested_fix":"f"}]},{"votes":[],"raised":[]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "solo raise does not drive a verdict"
    assert_equals "40" "$(echo "$out" | jq -r '[.log.findings[] | select(.domain=="panel")][0].confidence')" "solo raise → contested confidence 40"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "solo-raise contested finding not posted"
}

# Distant-line duplicates (line 5 vs line 99, same file) do NOT merge — two separate
# solo clusters, not one corroborated cluster (the residual-risk-#2 conservative case).
test_panel_distant_raises_do_not_merge() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"d.cs","line":5,"severity":"Suggestion","confidence":50,"description":"dup far","suggested_fix":"f"}]},{"votes":[],"raised":[{"file":"d.cs","line":99,"severity":"Suggestion","confidence":50,"description":"dup far","suggested_fix":"f"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "2" "$(echo "$out" | jq '[.log.findings[] | select(.domain=="panel")] | length')" "distant-line raises enter as two separate findings"
}

# Row 1 fires: goal present + a consensus finding blocks_goal by majority (2 of 3).
# The finding is only a Suggestion (rows 2/3 would NOT fire) → proves row 1 drove it.
test_panel_row1_fires_on_goal_block() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "row 1 fires: goal + majority blocks_goal → RC on a mere Suggestion"
}

# Row 1 does NOT fire when the ledger has no goal, even with unanimous blocks_goal
# votes — a Suggestion alone → APPROVE. Proves hasGoal gates row 1.
test_panel_row1_inert_without_goal() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":true,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "no goal in ledger → row 1 inert → APPROVE"
}

# Only 1 of 3 panelists returns (the harness returns null for indices past the array).
# 1 < floor(3/2)+1 = 2 → below quorum → degraded bundle (verdict NONE, no comments).
test_panel_below_quorum_degrades() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Critical","confidence":50,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "NONE" "$(echo "$out" | jq -r '.verdict')" "below quorum → verdict NONE (no false verdict)"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "below quorum → no comments posted"
}

# Exactly quorum (2 of 3) → NOT degraded; a unanimous-among-survivors Critical → RC.
test_panel_exact_quorum_proceeds() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Critical","confidence":50,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    # real=2 of s=2 survivors; superT=ceil(4/3)=2 → consensus Critical → RC row 2.
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "exact quorum proceeds: consensus Critical → RC"
}

# blocks_goal without a consensus majority (1 of 3) → row 1 does not fire.
test_panel_row1_needs_consensus_majority() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "goal present but blocks_goal not a majority → APPROVE"
}

# The durable-log payload carries one panel cog per surviving panelist + the meta tags.
test_panel_log_carries_cogs_and_meta() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":50,"description":"b","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"vote":"real","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "3" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="panel")] | length')" "one panel cog per surviving panelist"
    assert_equals "panel" "$(echo "$out" | jq -r '.log.meta.orchestration_mode')" "log meta records orchestration_mode=panel"
    assert_equals "3" "$(echo "$out" | jq -r '.log.meta.panel_size')" "log meta records panel_size=3"
}

# orchestrationMode absent → classic path: inject a real APPROVE synth envelope so
# finalizeBundle reaches buildLogPayload and the meta key is present. Proves default-
# classic routing distinctly from a panel run (panel sets orchestration_mode="panel").
test_absent_mode_takes_classic_path() {
    local args specs synth_env out
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    # Note: no orchestrationMode key at all.
    args="{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\"}"
    specs='{"correctness":[]}'
    synth_env='{"verdict":"APPROVE","rubricRowApplied":0,"rubricReason":"","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> all good\n"}'
    out=$(_pan_run_core "$args" "$specs" "[]" "" "$synth_env")
    assert_equals "classic" "$(echo "$out" | jq -r '.log.meta.orchestration_mode')" "absent mode → classic path (meta proves it)"
    assert_equals "null" "$(echo "$out" | jq -r '.log.meta.panel_size')" "absent mode → panel_size null (not a panel run)"
}

# route lightweight ignores orchestrationMode=panel (panel only replaces the full middle).
test_panel_mode_ignored_on_lightweight_route() {
    local args out
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    args="{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"lightweight\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\",\"orchestrationMode\":\"panel\",\"panelSize\":3,\"panelBrief\":\"BRIEF\"}"
    # The lightweight mock: the code-analysis agent (label 'code-analysis') returns findings.
    # _pan_run_core's mock returns specialists[label] for non-panel/cross labels, so
    # 'code-analysis' → specialists["code-analysis"].
    out=$(_pan_run_core "$args" '{"code-analysis":[{"file":"a.cs","line":1,"severity":"Suggestion","confidence":90,"description":"lw","suggested_fix":"f"}]}' "[]")
    assert_equals "NONE" "$(echo "$out" | jq -r '.verdict')" "lightweight route → verdict NONE regardless of panel mode"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "lightweight route still posts its code-analysis finding"
}

