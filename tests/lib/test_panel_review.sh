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

# args with flags.js=true — enables the eslint specialist (Track B test E).
_pan_args_js() {
    local n="${1:-3}"
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{\"js\":true},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\",\"orchestrationMode\":\"panel\",\"panelSize\":${n},\"panelBrief\":\"BRIEF\"}"
}

# args with flags.iac=true — enables the trivy specialist (Track B test F).
_pan_args_iac() {
    local n="${1:-3}"
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "{\"agentPrompt\":\"x\",\"flags\":{\"iac\":true},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\",\"orchestrationMode\":\"panel\",\"panelSize\":${n},\"panelBrief\":\"BRIEF\"}"
}

# args with a goal-bearing intent ledger (matches the /(^|\n)\s*goal:\s*\S/ detector).
_pan_args_goal() {
    local n="${1:-3}"
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local ledger="Intent ledger:\ngoal: ship the widget end to end.\nnon_goals: none\nsource: pr_body\n"
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"${ledger}\",\"orchestrationMode\":\"panel\",\"panelSize\":${n},\"panelBrief\":\"BRIEF\"}"
}

# One Important consensus finding, unanimously voted real by 3 panelists → RC via rubric row 3.
# Ratchet: 0 is_real:false → conf=100≥70; effLevel=2 (all vote Important=spec) → blocks → consensus.
test_panel_unanimous_real_important_is_rc() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"the bug","suggested_fix":"fix"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    if ! echo "$out" | jq -e . >/dev/null 2>&1; then
        fail "panel unanimous-real: valid JSON bundle" "probe: ${out:0:160}"
        return
    fi
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "unanimous-real Important → RC (rubric row 3)"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "the consensus finding posts as one comment"
}

# Split vote (2 is_real:true Suggestion / 1 is_real:false on N=3):
# Ratchet: 1 is_real:false → conf=89≥70; Suggestion effLevel=1 < 2 → does NOT block.
# Majority-not-real? 1/3 < 1/2 → no. → contested. Contested not posted → APPROVE, 0 comments.
test_panel_split_majority_real_suggestion_approves() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"nit","suggested_fix":"tidy"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "Suggestion non-blocking → contested → APPROVE"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "contested Suggestion not posted"
}

# Mixed vote (1 is_real:true Important / 1 is_real:true Suggestion (was minor) / 1 is_real:false on N=3):
# Ratchet: 1 is_real:false → conf=89≥70; is_real:true votes: Important (same) + Suggestion (down=1);
# effLevel=clamp(2+(0-1)/3,1,3)=1.667, round=2=Important → blocks → consensus → RC.
test_panel_mixed_severity_rounds_to_important_blocks() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"maybe","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "Important effLevel rounds to Important, conf=89 → consensus → RC"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "consensus Important is posted"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "blocking Important → consensus"
}

# 1 is_real:true Critical / 2 is_real:false on N=3:
# Ratchet: 2 is_real:false → conf=100-22=78≥70; Critical effLevel=3≥2 → blocks → consensus → RC.
# Under the new ratchet conf=78 still clears the 70 threshold, so this is NOT dismissed.
test_panel_critical_survives_two_dissents() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Critical","confidence":100,"description":"false alarm","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    # Critical conf=78 (2 is_real:false, step=11) still blocks (78≥70) → consensus → RC.
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "Critical conf=78 still blocks → consensus → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "blocking Critical → consensus (not dismissed)"
}

# N=5 bare majority: 3 is_real:true / 2 is_real:false on Important.
# Ratchet: step=ceil(31/5)=7; 2 is_real:false → conf=100-14=86≥70; Important effLevel=2≥2 → blocks → consensus → RC.
test_panel_n5_bare_majority_is_contested() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"split5","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 5)" "$specs" "$pans")
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "N=5 Important conf=86 blocks → consensus"
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "N=5 consensus Important → RC"
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

# Row 1 fires: goal present + a finding with majority blocks_goal (2 of 3).
# Suggestion does not block (effLevel=1<2) → contested. Row 1 (widened) scans
# consensus ∪ contested for blocks_goal → fires → RC despite the Suggestion severity.
test_panel_row1_fires_on_goal_block() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "row 1 fires: goal + majority blocks_goal → RC on a mere Suggestion"
}

# Row 1 fires on a mere Suggestion → the durable log must flag that Suggestion
# verdict_relevant. Under the new ratchet, the Suggestion does not block → contested
# (not consensus); row 1 (widened) still fires by scanning contested for blocks_goal.
test_panel_row1_finding_is_verdict_relevant() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "1" "$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant==true)] | length')" "row 1 RC flags exactly the blocks_goal finding verdict_relevant"
    assert_equals "contested" "$(echo "$out" | jq -r '[.log.findings[] | select(.verdict_relevant==true)][0].tier')" "the verdict-relevant finding is in contested tier (Suggestion does not block)"
}

# APPROVE (row 4) must flag NOTHING verdict_relevant, even with a lone blocks_goal vote.
# Guards contract A against over-flagging: the row gate, not blocks_goal alone, decides.
test_panel_approve_flags_nothing_verdict_relevant() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "1-of-3 blocks_goal → row 1 inert → APPROVE"
    assert_equals "0" "$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant==true)] | length')" "APPROVE flags nothing verdict_relevant despite a lone blocks_goal"
}

# Row 1 does NOT fire when the ledger has no goal, even with unanimous blocks_goal
# votes — a Suggestion alone → APPROVE. Proves hasGoal gates row 1.
test_panel_row1_inert_without_goal() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "no goal in ledger → row 1 inert → APPROVE"
}

# Only 1 of 3 panelists returns (the harness returns null for indices past the array).
# 1 < floor(3/2)+1 = 2 → below quorum → degraded bundle (verdict NONE, no comments).
test_panel_below_quorum_degrades() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Critical","confidence":50,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "NONE" "$(echo "$out" | jq -r '.verdict')" "below quorum → verdict NONE (no false verdict)"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "below quorum → no comments posted"
    # Follow-up #2: the Category-C degrade must still carry the captured log (cogs + meta),
    # not silently discard the surviving panelist's work. One panel cog survived (1 of 3).
    assert_equals "1" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="panel")] | length')" "below quorum still logs the surviving panel cog"
    assert_equals "panel" "$(echo "$out" | jq -r '.log.meta.orchestration_mode')" "below quorum log meta records orchestration_mode=panel"
}

# Exactly quorum (2 of 3) → NOT degraded; a unanimous-among-survivors Critical → RC.
test_panel_exact_quorum_proceeds() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Critical","confidence":100,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    # 2 is_real:true of s=2 survivors, 0 is_real:false → conf=100; Critical → consensus → RC row 2.
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "exact quorum proceeds: consensus Critical → RC"
}

# blocks_goal without a consensus majority (1 of 3) → row 1 does not fire.
test_panel_row1_needs_consensus_majority() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "goal present but blocks_goal not a majority → APPROVE"
}

# The durable-log payload carries one panel cog per surviving panelist + the meta tags.
test_panel_log_carries_cogs_and_meta() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":50,"description":"b","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
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

# Task 4: Two-track ratchet tests (A-F)

# Test A — Track A severity UPGRADE promotes a Suggestion to a blocking Important.
# N=3, specialist Suggestion/100, all 3 vote is_real:true severity=Important.
# sevVotes from real votes: all Important (level=2). specLevel=1. up=3, down=0.
# effLevel=clamp(1+3/3,1,3)=2 → Important; no is_real:false → conf=100 ≥ 70 → blocks → consensus → RC.
test_panel_trackA_severity_upgrade_blocks() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"nit that matters","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "unanimous severity upgrade Suggestion→Important blocks → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "upgraded finding lands in consensus"
}

# Test B — Track A realness ratchet: unanimous is_real:false drops a spec-100 Important below 70 → dismissed.
# N=3, step=ceil(31/3)=11, 3×11=33, conf=100-33=67 < 70 → not blocking.
# majority-not-real: 3/3 > 1/2 → dismissed → APPROVE.
test_panel_trackA_realness_drops_below_gate() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"maybe false","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "unanimous is_real:false → confidence 67 < 70 → not blocking"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority is_real:false → dismissed"
}

# Test C — Track A single dissent still blocks.
# N=3, spec-100 Important, 1 is_real:false → conf=100-11=89 ≥ 70.
# sevVotes from 2 real votes: both Important (same level) → up=0, down=0 → effLevel=2 → Important → blocks → consensus → RC.
test_panel_trackA_single_dissent_still_blocks() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"solid bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "spec-100 Important with 1 dissent → confidence 89 ≥ 70 → still blocks"
}

# Test D — Non-real panelists abstain from severity notch.
# N=3, specialist Suggestion/100. 2 vote is_real:false (severity Critical — must be ignored).
# 1 votes is_real:true severity=Critical. sevVotes=[Critical] only (from the 1 real vote).
# up=1 (Critical > Suggestion), down=0. effLevel=clamp(1+1/3,1,3)=1.333, round=1 → Suggestion → not blocking.
# is_real_false=2 > is_real_true=1 → majority not-real → dismissed → APPROVE.
test_panel_trackA_nonreal_abstains_from_severity() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"nit","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "non-real Critical votes abstain from notch → stays Suggestion, majority not-real → dismissed"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority is_real:false → dismissed regardless of their severity field"
}

# Test E — Track B static severity is LOCKED and never dismissed.
# Domain eslint (in STATIC), specialist Important. All 3 vote is_real:false severity=Suggestion.
# step=ceil(50/3)=17. conf=max(50, 100-3*17)=max(50,49)=50 < 70 → not blocking → contested (NOT dismissed).
test_panel_trackB_static_locked_and_never_dismissed() {
    local specs pans out
    specs='{"eslint":[{"file":"a.js","line":2,"severity":"Important","confidence":100,"rule_id":"no-eval","description":"eval used","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_js 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "static floor-50 confidence < 70 → not blocking"
    assert_equals "contested" "$(echo "$out" | jq -r '.log.findings[0].tier')" "static finding with heavy dissent → contested, NEVER dismissed"
    assert_equals "Important" "$(echo "$out" | jq -r '.log.findings[0].severity')" "static severity is locked — panel Suggestion votes ignored"
    assert_equals "50" "$(echo "$out" | jq -r '.log.findings[0].confidence')" "static confidence clamps at floor 50"
}

# Test F — Track B static blocks when undissented.
# Domain trivy (in STATIC), Important, all 3 is_real:true → no is_real:false → conf=100.
# Severity locked Important ≥ 2, conf=100 ≥ 70 → blocks → consensus → RC.
test_panel_trackB_static_blocks_when_undissented() {
    local specs pans out
    specs='{"trivy":[{"file":"main.tf","line":5,"severity":"Important","confidence":100,"rule_id":"AVD-AWS-0089","description":"public bucket","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_iac 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "undissented static Important (conf 100) → consensus → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "undissented static → consensus"
}

# Test G — row 1 still fires after the ratchet: a goal-blocking Suggestion (conf 100,
# 2-of-3 blocks_goal:true) lands in contested (Suggestion does not block), but widened
# row 1 scans consensus ∪ contested for blocks_goal → RC.
test_panel_ratchet_row1_still_fires() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "goal + majority blocks_goal on a Suggestion → RC row 1 (blocks_goal survived ratchet)"
}

# N=5 scaling: Track A realness step=ceil(31/5)=7; unanimous is_real:false on spec-100
# Important → conf=100-5×7=65 < 70 → not blocking → dismissed → APPROVE.
test_panel_n5_realness_scaling() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"n5 bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 5)" "$specs" "$pans")
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "N=5: 5×ceil(31/5)=35 drop → conf 65 < 70 → dismissed"
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "N=5 unanimous not-real → APPROVE"
}

# The concern brief must define severity by impact-if-manifested and must define
# the three tractability tiers by name, so panelists elicit the new axes.
test_panel_brief_defines_impact_severity_and_tractability() {
    local brief
    brief="$REPO_ROOT/plugins/code-review-suite/includes/panel-concern-brief.md"
    assert_matches "impact" "$(cat "$brief")" "brief anchors severity to impact"
    assert_matches "Tractability" "$(cat "$brief")" "brief names the Tractability axis"
    assert_matches "Mechanical" "$(cat "$brief")" "brief defines Mechanical tier"
    assert_matches "Bounded" "$(cat "$brief")" "brief defines Bounded tier"
    assert_matches "Open-ended" "$(cat "$brief")" "brief defines Open-ended tier"
}

# PANEL_SCHEMA.votes require tractability; PANEL_SCHEMA.raised items carry tractability.
test_panel_schema_has_tractability() {
    local wf result
    wf="$(_pan_cr_dir)/workflows/review-core.mjs"
    result=$(WF="$wf" node -e '
        const fs = require("fs");
        const wf = fs.readFileSync(process.env.WF, "utf8");
        const cut = wf.indexOf("const resolvedArgs");
        const prefix = wf.slice(0, cut).replace(/^export\s+const\s+meta/m, "const meta");
        const { PANEL_SCHEMA } = new Function(prefix + "\nreturn { PANEL_SCHEMA };")();
        const vote = PANEL_SCHEMA.properties.votes.items;
        const raised = PANEL_SCHEMA.properties.raised.items;
        const voteOk = vote.required.includes("tractability")
            && vote.properties.tractability.enum.join(",") === "Mechanical,Bounded,Open-ended";
        const raisedOk = !!raised.properties.tractability
            && raised.properties.tractability.enum.join(",") === "Mechanical,Bounded,Open-ended";
        console.log(voteOk && raisedOk ? "OK" : "MISMATCH vote=" + voteOk + " raised=" + raisedOk);
    ' 2>&1)
    assert_equals "OK" "$result" "PANEL_SCHEMA votes + raised carry the tractability enum"
}
