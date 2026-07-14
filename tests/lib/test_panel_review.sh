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

# Capture the exact prompt string the panel-writer agent receives. Same eval mechanism
# as _pan_run_core, but the panel-writer stub prints the prompt to stdout (prefixed with
# a sentinel) and exits — so a test can assert what the writer is/ isn't shown. $1 args,
# $2 specialists-map, $3 panelists.
_pan_capture_writer_prompt() {
    local wf
    wf="$(_pan_cr_dir)/workflows/review-core.mjs"
    WF="$wf" PAN_ARGS="$1" PAN_SPECIALISTS="$2" PAN_PANELISTS="$3" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const specialists = JSON.parse(process.env.PAN_SPECIALISTS);
        const panelists = JSON.parse(process.env.PAN_PANELISTS);
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "panel-writer") { process.stdout.write("WRITER_PROMPT<<<" + prompt); process.exit(0); }
            if (label.startsWith("panel-")) {
                const i = parseInt(label.slice("panel-".length), 10);
                return panelists[i] === undefined ? null : panelists[i];
            }
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "", escalations: [] };
            if (label === "review-synthesiser") return null;
            return { status: "ok", findings: specialists[label] || [] };
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {}; const log = () => {}; const pipeline = async () => []; const workflow = async () => null;
        (async () => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            await fn(agent, parallel, pipeline, phase, log, process.env.PAN_ARGS, workflow);
        })().catch(e => { process.stdout.write("THREW: " + e.message); process.exit(1); });
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
# Majority: all 3 vote Important → agreement=high → consensus → blocks.
test_panel_unanimous_real_important_is_rc() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"the bug","suggested_fix":"fix"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    if ! echo "$out" | jq -e . >/dev/null 2>&1; then
        fail "panel unanimous-real: valid JSON bundle" "probe: ${out:0:160}"
        return
    fi
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "unanimous-real Important → RC (rubric row 3)"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "the consensus finding posts as one comment"
    assert_equals "high" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "unanimous → confidence_flag high"
}

# Split vote (2 is_real:true Suggestion / 1 is_real:false on N=3):
# Majority-real: 2/3 > 1/2; sevVotes=[Suggestion,Suggestion] → majority Suggestion → contested.
# Contested not posted → APPROVE, 0 comments.
test_panel_split_majority_real_suggestion_approves() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"nit","suggested_fix":"tidy"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "Suggestion non-blocking → contested → APPROVE"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "contested Suggestion not posted"
}

# The findings-index pointer must reflect real posting, not infer it from the line number.
# A Suggestion+Bounded finding routes posting:body (follow-up) — it has a positive line but
# does NOT post inline, so the index must say "in body", not "inline". Guards the pointer
# reading f.line>0 instead of f.posting.
test_panel_index_pointer_reflects_body_routing() {
    local specs pans out index
    # Two real Suggestions: #0 Mechanical (→ inline), #1 Bounded (→ body/follow-up).
    specs='{"style":[{"file":"a.cs","line":10,"severity":"Suggestion","confidence":50,"description":"mechanical nit","suggested_fix":"rename"},{"file":"b.cs","line":20,"severity":"Suggestion","confidence":50,"description":"bounded refactor","suggested_fix":"restructure"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"},{"finding_id":1,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"},{"finding_id":1,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"},{"finding_id":1,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    index=$(echo "$out" | jq -r '.bodyText')
    assert_matches "b.cs:20\` ↳ in body" "$index" "Bounded suggestion indexed as in-body follow-up, not inline"
    assert_matches "a.cs:10\` ↳ inline" "$index" "Mechanical suggestion indexed as inline"
}

# A body-improvement finding carries the literal `<n/a>` file sentinel (alignment-reviewer
# convention). It must NOT post as an inline/file comment on a nonexistent path — it renders
# body-only. Guards the sentinel-vs-falsy mismatch in isFileless/renderComments.
test_panel_na_sentinel_finding_is_body_only() {
    local specs pans out
    specs='{"alignment":[{"file":"<n/a>","line":0,"severity":"Important","confidence":80,"description":"PR body omits the deferred lifecycle-rule dependency","suggested_fix":"note it in the PR body"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "<n/a> finding posts no inline/file comment"
    assert_not_matches "n/a" "$(echo "$out" | jq -r '.comments')" "no comment anchored to the <n/a> sentinel"
    assert_matches "### Body notes" "$(echo "$out" | jq -r '.bodyText')" "<n/a> finding rendered in the Body notes section"
    assert_matches "PR body omits" "$(echo "$out" | jq -r '.bodyText')" "<n/a> finding full detail present in body"
}

# The writer must see confidence ONLY as the discrete flag, never the FLAG_TO_NUM shim
# number — else it echoes it back as a false-precision "90 %" in the prose. Assert the
# tiers JSON in the writer prompt carries confidence_flag but no numeric "confidence":,
# and that the prompt instructs flag-word-not-number. Guards the deferred presentation fix.
test_panel_writer_prompt_strips_numeric_confidence() {
    local specs pans prompt tiersblock
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"the bug","suggested_fix":"fix"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    prompt=$(_pan_capture_writer_prompt "$(_pan_args 3)" "$specs" "$pans")
    # Isolate the Tiers JSON block (everything after the "Tiers (JSON):" marker).
    tiersblock="${prompt#*Tiers (JSON):}"
    assert_matches "confidence_flag" "$tiersblock" "writer tiers keep the confidence_flag"
    assert_not_matches '"confidence":' "$tiersblock" "writer tiers drop the numeric confidence shim"
    assert_matches "never as a number or percentage" "$prompt" "writer prompt forbids numeric/percentage confidence"
    assert_matches "Do NOT assert exact finding counts" "$prompt" "writer prompt forbids exact finding counts"
}

# Mixed severity with NO majority (1 Important / 1 Suggestion real, 1 not-real):
# severity votes among real = [Important, Suggestion] → no majority → SCATTER →
# judgement call (contested, non-blocking) → APPROVE. (Old ratchet rounded to Important+RC.)
test_panel_mixed_severity_scatter_is_judgement_call() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"maybe","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "severity scatter does not block → APPROVE"
    assert_equals "contested" "$(echo "$out" | jq -r '.log.findings[0].tier')" "severity scatter → contested judgement-call bin"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].judgement_call')" "scatter finding flagged judgement_call"
}

# 1 real Critical / 2 not-real: majority-not-real fires FIRST → dismissed → APPROVE.
# (Old ratchet kept conf=78 ≥ 70 and blocked; the new model never reaches severity for a
# majority-not-real finding.)
test_panel_lone_real_critical_majority_notreal_dismissed() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Critical","confidence":100,"description":"false alarm","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "majority not-real → dismissed → APPROVE"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority not-real → dismissed"
}

# 2/1 majority Important (one dissent on is_real) STILL BLOCKS — difficulty/doubt never
# excuses a real defect. confidence_flag=medium, but a medium majority Important blocks.
test_panel_two_one_majority_important_blocks() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"solid bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "2/1 majority Important blocks (no confidence gate)"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "2/1 majority Important → consensus"
    assert_equals "medium" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "2/1 majority → medium confidence flag"
}

# A raised finding corroborated by 2 of 3 panelists (within ±3 lines) → consensus,
# stamped domain "panel". Posted as a comment. Stage-1 findings all not_a_problem.
test_panel_raised_majority_is_consensus() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"n.cs","line":20,"severity":"Important","tractability":"Bounded","confidence":40,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[{"file":"n.cs","line":22,"severity":"Important","tractability":"Bounded","confidence":90,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "2-of-3 raised Important → consensus → RC row 3"
    assert_equals "1" "$(echo "$out" | jq '[.log.findings[] | select(.domain=="panel")] | length')" "raised finding stamped domain panel"
    # confidence_flag set from corroboration (2-of-3 → high), NOT the panelist-supplied numbers.
    assert_equals "high" "$(echo "$out" | jq -r '[.log.findings[] | select(.domain=="panel")][0].confidence_flag')" "raised confidence_flag set from corroboration, not panelist value"
}

# A solo raise (1 of 3) → contested, confidence 40, not posted, verdict APPROVE.
test_panel_solo_raise_is_low_contested() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"s.cs","line":5,"severity":"Important","tractability":"Bounded","confidence":88,"description":"solo concern","suggested_fix":"f"}]},{"votes":[],"raised":[]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "solo raise does not drive a verdict"
    assert_equals "low" "$(echo "$out" | jq -r '[.log.findings[] | select(.domain=="panel")][0].confidence_flag')" "solo raise → contested confidence_flag low"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "solo-raise contested finding not posted"
}

# Distant-line duplicates (line 5 vs line 99, same file) do NOT merge — two separate
# solo clusters, not one corroborated cluster (the residual-risk-#2 conservative case).
test_panel_distant_raises_do_not_merge() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"d.cs","line":5,"severity":"Suggestion","tractability":"Bounded","confidence":50,"description":"dup far","suggested_fix":"f"}]},{"votes":[],"raised":[{"file":"d.cs","line":99,"severity":"Suggestion","tractability":"Bounded","confidence":50,"description":"dup far","suggested_fix":"f"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "2" "$(echo "$out" | jq '[.log.findings[] | select(.domain=="panel")] | length')" "distant-line raises enter as two separate findings"
}

# A raised Suggestion + Open-ended is DROPPED even when corroborated by 2 panelists.
test_panel_raised_suggestion_openended_dropped() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"n.cs","line":20,"severity":"Suggestion","tractability":"Open-ended","confidence":40,"description":"open refactor","suggested_fix":"rethink"}]},{"votes":[],"raised":[{"file":"n.cs","line":22,"severity":"Suggestion","tractability":"Open-ended","confidence":90,"description":"open refactor","suggested_fix":"rethink"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "raised open-ended suggestion is not posted"
    assert_equals "true" "$(echo "$out" | jq -r '[.log.findings[] | select(.domain=="panel")][0].dropped')" "raised open-ended suggestion marked dropped"
}

# A raised Important corroborated by 2 of 3 → consensus → RC, posted inline.
test_panel_raised_important_blocks() {
    local specs pans out
    specs='{"correctness":[]}'
    pans='[{"votes":[],"raised":[{"file":"n.cs","line":20,"severity":"Important","tractability":"Bounded","confidence":40,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[{"file":"n.cs","line":22,"severity":"Important","tractability":"Bounded","confidence":90,"description":"missing null check","suggested_fix":"guard"}]},{"votes":[],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "corroborated raised Important → RC"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "corroborated raised Important posts inline"
}

# Row 1 fires: goal present + a finding with majority blocks_goal (2 of 3).
# Suggestion does not block (effLevel=1<2) → contested. Row 1 (widened) scans
# consensus ∪ contested for blocks_goal → fires → RC despite the Suggestion severity.
test_panel_row1_fires_on_goal_block() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "row 1 fires: goal + majority blocks_goal → RC on a mere Suggestion"
}

# Row 1 fires on a mere Suggestion → the durable log must flag that Suggestion
# verdict_relevant. Under the new ratchet, the Suggestion does not block → contested
# (not consensus); row 1 (widened) still fires by scanning contested for blocks_goal.
test_panel_row1_finding_is_verdict_relevant() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "1" "$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant==true)] | length')" "row 1 RC flags exactly the blocks_goal finding verdict_relevant"
    assert_equals "contested" "$(echo "$out" | jq -r '[.log.findings[] | select(.verdict_relevant==true)][0].tier')" "the verdict-relevant finding is in contested tier (Suggestion does not block)"
}

# APPROVE (row 4) must flag NOTHING verdict_relevant, even with a lone blocks_goal vote.
# Guards contract A against over-flagging: the row gate, not blocks_goal alone, decides.
test_panel_approve_flags_nothing_verdict_relevant() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "1-of-3 blocks_goal → row 1 inert → APPROVE"
    assert_equals "0" "$(echo "$out" | jq '[.log.findings[] | select(.verdict_relevant==true)] | length')" "APPROVE flags nothing verdict_relevant despite a lone blocks_goal"
}

# Row 1 does NOT fire when the ledger has no goal, even with unanimous blocks_goal
# votes — a Suggestion alone → APPROVE. Proves hasGoal gates row 1.
test_panel_row1_inert_without_goal() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "no goal in ledger → row 1 inert → APPROVE"
}

# Only 1 of 3 panelists returns (the harness returns null for indices past the array).
# 1 < floor(3/2)+1 = 2 → below quorum → degraded bundle (verdict NONE, no comments).
test_panel_below_quorum_degrades() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Critical","confidence":50,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
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
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    # 2 is_real:true of s=2 survivors, all vote Critical → majority=high → consensus → RC row 2.
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "exact quorum proceeds: consensus Critical → RC"
}

# blocks_goal without a consensus majority (1 of 3) → row 1 does not fire.
test_panel_row1_needs_consensus_majority() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "goal present but blocks_goal not a majority → APPROVE"
}

# The durable-log payload carries one panel cog per surviving panelist + the meta tags.
test_panel_log_carries_cogs_and_meta() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":50,"description":"b","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
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

# Majority model tests (A-F)

# Test A — unanimous Important majority promotes a Suggestion to a blocking Important.
# N=3, specialist Suggestion, all 3 vote is_real:true severity=Important.
# sevVotes=[Important,Important,Important] → majority Important, agreement=high → consensus → RC.
test_panel_trackA_severity_upgrade_blocks() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"nit that matters","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "unanimous Important majority blocks → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "unanimous Important majority → consensus"
}

# Test B — unanimous is_real:false → majority-not-real → dismissed → APPROVE.
test_panel_trackA_majority_notreal_dismissed() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"maybe false","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "unanimous is_real:false → majority-not-real → dismissed → APPROVE"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority is_real:false → dismissed"
}

# Test D — Non-real panelists abstain from severity tally.
# N=3, specialist Suggestion. 2 vote is_real:false (severity Critical — must be ignored).
# 1 votes is_real:true severity=Critical. sevVotes=[Critical] only (from the 1 real vote).
# is_real_false=2 > is_real_true=1 → majority not-real → dismissed → APPROVE.
test_panel_trackA_nonreal_abstains_from_severity() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"nit","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "non-real votes abstain from severity tally → majority not-real → dismissed"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "majority is_real:false → dismissed regardless of their severity field"
}

# Test E — Static severity is LOCKED and never dismissed.
# Domain eslint (in STATIC), specialist Important. All 3 vote is_real:false severity=Suggestion.
# Static locking: severity=Important (locked), confidence_flag=high, tractability=Mechanical → not blocking only if <Important.
# Important ≥ 2 → consensus even with full dissent — static rules override realness majority.
test_panel_trackB_static_locked_and_never_dismissed() {
    local specs pans out
    specs='{"eslint":[{"file":"a.js","line":2,"severity":"Important","confidence":100,"rule_id":"no-eval","description":"eval used","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":false,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_js 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "static Important always blocks regardless of realness votes → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "static Important → consensus, NEVER dismissed"
    assert_equals "Important" "$(echo "$out" | jq -r '.log.findings[0].severity')" "static severity is locked — panel Suggestion votes ignored"
    assert_equals "high" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "static confidence_flag always high"
}

# Test F — Static blocks when undissented.
# Domain trivy (in STATIC), Important, all 3 is_real:true → severity locked Important → consensus → RC.
test_panel_trackB_static_blocks_when_undissented() {
    local specs pans out
    specs='{"trivy":[{"file":"main.tf","line":5,"severity":"Important","confidence":100,"rule_id":"AVD-AWS-0089","description":"public bucket","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_iac 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "undissented static Important → consensus → RC"
    assert_equals "consensus" "$(echo "$out" | jq -r '.log.findings[0].tier')" "undissented static → consensus"
    assert_equals "high" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "static confidence_flag=high"
}

# Test G — row 1 still fires: a goal-blocking Suggestion lands in contested, widened
# row 1 scans consensus ∪ contested for blocks_goal → RC.
test_panel_row1_still_fires_on_suggestion() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":100,"description":"incomplete feature","suggested_fix":"finish it"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":true,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args_goal 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "goal + majority blocks_goal on a Suggestion → RC row 1"
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

# A reachable defect that is deferred/tracked, or only coarsely mitigated, must NOT be
# severity-discounted: severity is impact-if-manifested, decided before any plan or
# partial control. Guards the PR #98 regression where panelists voted a reachable authZ
# gap down to Suggestion citing the issue-#100 deferral + Entra audience restriction.
test_panel_brief_forbids_deferral_and_mitigation_severity_discount() {
    local brief
    brief="$REPO_ROOT/plugins/code-review-suite/includes/panel-concern-brief.md"
    assert_matches "deferred to a future ticket" "$(cat "$brief")" "brief: deferral does not lower severity"
    assert_matches "does not lower it" "$(cat "$brief")" "brief: tracked defect keeps its severity"
    assert_matches "reduces likelihood, not impact" "$(cat "$brief")" "brief: coarse mitigation is likelihood not impact"
    assert_matches "same severity ladder" "$(cat "$brief")" "brief: raised findings use the same severity ladder"
}

# Suggestion + Mechanical → fix-now, posted inline as one comment.
test_panel_suggestion_mechanical_is_fix_now_inline() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"tidy this","suggested_fix":"rename"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Mechanical","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "Suggestion never blocks → APPROVE"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "Suggestion+Mechanical posts inline (fix-now)"
    assert_equals "fix-now" "$(echo "$out" | jq -r '.log.findings[0].recommendation')" "Suggestion+Mechanical → fix-now"
}

# Suggestion + Open-ended → DROPPED: no comment, recorded in dismissed with dropped:true.
test_panel_suggestion_openended_is_dropped() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"big refactor idea","suggested_fix":"rethink module"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "open-ended suggestion posts nothing"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].dropped')" "open-ended suggestion recorded dropped in log"
    assert_equals "dismissed" "$(echo "$out" | jq -r '.log.findings[0].tier')" "dropped suggestion sits in dismissed tier"
}

# Suggestion + Bounded → body only (follow-up), no inline comment.
test_panel_suggestion_bounded_is_body_only() {
    local specs pans out
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":50,"description":"worth a follow-up","suggested_fix":"later"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "bounded suggestion is not an inline comment"
    assert_equals "follow-up" "$(echo "$out" | jq -r '.log.findings[0].recommendation')" "bounded suggestion → follow-up"
}

# Open-ended BLOCKER: still blocks (RC), posts inline, carries the do-not-dispatch annotation.
test_panel_openended_blocker_annotated_still_blocks() {
    local specs pans out
    specs='{"security":[{"file":"api.cs","line":12,"severity":"Important","confidence":88,"description":"missing role gate","suggested_fix":"add policy"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "open-ended Important still blocks"
    assert_equals "1" "$(echo "$out" | jq '.comments | length')" "blocker posts inline"
    assert_matches "do not dispatch" "$(echo "$out" | jq -r '.log.findings[0].annotation')" "open-ended blocker carries the do-not-dispatch annotation"
}

# Judgement call (severity scatter) → PR-body only, no inline comment.
test_panel_judgement_call_is_body_only() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":9,"severity":"Important","confidence":100,"description":"contested stakes","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Critical","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "judgement call does not block"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "judgement call is not an inline comment"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].judgement_call')" "scatter finding flagged judgement_call"
}

# The durable log carries the discrete confidence_flag, tractability, and recommendation
# for a panel finding.
test_panel_log_records_flag_and_tractability() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"bug","suggested_fix":"f"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_equals "high" "$(echo "$out" | jq -r '.log.findings[0].confidence_flag')" "log records confidence_flag"
    assert_equals "Bounded" "$(echo "$out" | jq -r '.log.findings[0].tractability')" "log records tractability"
    assert_equals "fix-now" "$(echo "$out" | jq -r '.log.findings[0].recommendation')" "log records recommendation"
}

# An inline panel comment body renders the discrete flag, not a bare number, plus the fix-now
# recommendation.
test_panel_comment_body_shows_flag() {
    local specs pans out
    specs='{"correctness":[{"file":"a.cs","line":10,"severity":"Important","confidence":100,"description":"bug","suggested_fix":"do x"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Important","tractability":"Bounded","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    assert_matches "confidence high" "$(echo "$out" | jq -r '.comments[0].body')" "comment body renders discrete flag"
    assert_not_matches "confidence 90" "$(echo "$out" | jq -r '.comments[0].body')" "comment body does not print the shim number"
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

# Finding #1 regression: a panel APPROVE with a dropped open-ended Suggestion must disclose
# the prune count in bodyText. The dismissed tier carries the dropped finding but was NOT
# counted toward suppressedCount — the disclosure line was dead code.
test_panel_dropped_openended_approve_discloses_prune() {
    local specs pans out
    # 3/3 unanimous real Suggestion + Open-ended → routeFinding drops it → dismissed tier,
    # dropped:true. All 3 vote is_real:true so majority-not-real does NOT fire; the finding
    # lands as consensus Suggestion, then routeFinding routes it to dismissed (Open-ended drop).
    specs='{"style":[{"file":"a.cs","line":3,"severity":"Suggestion","confidence":80,"description":"open refactor","suggested_fix":"redesign everything"}]}'
    pans='[{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]},{"votes":[{"finding_id":0,"is_real":true,"severity":"Suggestion","tractability":"Open-ended","blocks_goal":false,"rationale":"r"}],"raised":[]}]'
    out=$(_pan_run_core "$(_pan_args 3)" "$specs" "$pans")
    if ! echo "$out" | jq -e . >/dev/null 2>&1; then
        fail "panel dropped-openended-approve: valid JSON bundle" "probe: ${out:0:200}"
        return
    fi
    assert_equals "APPROVE" "$(echo "$out" | jq -r '.verdict')" "open-ended Suggestion → dropped → APPROVE"
    assert_equals "0" "$(echo "$out" | jq '.comments | length')" "dropped finding is not posted as comment"
    assert_equals "true" "$(echo "$out" | jq -r '.log.findings[0].dropped')" "finding marked dropped in log"
    assert_matches "pruned" "$(echo "$out" | jq -r '.bodyText')" "APPROVE with dropped finding discloses prune count in bodyText"
}

# Finding #2 regression: classic path must keep the >=70 gate on consensus Important for
# verdict_relevant. A sub-70 consensus Important alongside a Critical (which drives RC via
# row 2) must NOT be flagged verdict_relevant on the classic path.
test_classic_sub70_important_not_verdict_relevant() {
    local args specs synth_env out
    local sha40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    # Classic path: no orchestrationMode key.
    args="{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"intentLedger\":\"\"}"
    specs='{"correctness":[]}'
    # Synth envelope: consensus Critical (drives RC row 2) + consensus Important confidence 50
    # (sub-70, does not independently drive row 3). No confidence_flag on classic findings.
    synth_env='{"verdict":"REQUEST_CHANGES","rubricRowApplied":2,"rubricReason":"Critical finding present","tiers":{"consensus":[{"file":"a.cs","line":1,"severity":"Critical","confidence":90,"description":"critical bug","suggested_fix":"fix it"},{"file":"b.cs","line":5,"severity":"Important","confidence":50,"description":"marginal issue","suggested_fix":"maybe fix"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> critical issue\n"}'
    out=$(_pan_run_core "$args" "$specs" "[]" "" "$synth_env")
    if ! echo "$out" | jq -e . >/dev/null 2>&1; then
        fail "classic sub-70 Important verdict_relevant: valid JSON bundle" "probe: ${out:0:200}"
        return
    fi
    assert_equals "REQUEST_CHANGES" "$(echo "$out" | jq -r '.verdict')" "classic RC driven by Critical"
    # The Critical (confidence 90 ≥ 70) is verdict_relevant. The Important (confidence 50 < 70) is NOT.
    assert_equals "false" "$(echo "$out" | jq -r '[.log.findings[] | select(.severity=="Important")][0].verdict_relevant')" "classic sub-70 Important must NOT be verdict_relevant"
    assert_equals "true" "$(echo "$out" | jq -r '[.log.findings[] | select(.severity=="Critical")][0].verdict_relevant')" "classic Critical (>=70) IS verdict_relevant"
}
