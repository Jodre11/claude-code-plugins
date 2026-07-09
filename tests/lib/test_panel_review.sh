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
_pan_run_core() {
    local wf writerBody
    wf="$(_pan_cr_dir)/workflows/review-core.mjs"
    writerBody="## Synthesiser Assessment\n> panel prose\n"
    [ "$#" -ge 4 ] && writerBody="$4"
    WF="$wf" PAN_ARGS="$1" PAN_SPECIALISTS="$2" PAN_PANELISTS="$3" PAN_WRITER="$writerBody" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const specialists = JSON.parse(process.env.PAN_SPECIALISTS);
        const panelists = JSON.parse(process.env.PAN_PANELISTS);
        const writerBody = process.env.PAN_WRITER;
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label === "panel-writer") return { bodyText: writerBody };
            if (label.startsWith("panel-")) {
                const i = parseInt(label.slice("panel-".length), 10);
                return panelists[i] === undefined ? null : panelists[i];
            }
            if (label.startsWith("cross-")) return { status: "ok", opinionsMarkdown: "", escalations: [] };
            if (label === "review-synthesiser") return null;
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
