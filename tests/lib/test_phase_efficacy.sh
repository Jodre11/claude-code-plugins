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

test_phaselog_captures_synth_cog() {
    local args env out
    args=$(_pe_args)
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> ok\n"}'
    out=$(_pe_run_core "$args" "$env")
    assert_equals "1" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="synth")] | length')" "one synth cog (no gate fire)"
    # Synth cog input carries the findingsByDomain it synthesised from.
    assert_equals "false" "$(echo "$out" | jq -r '[.log.cogs[] | select(.phase=="synth")][0].input.findingsByDomain == null')" "synth cog carries findingsByDomain input"
    # No round-2 / union records when the gate did not fire.
    assert_equals "0" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="round2" or .phase=="union")] | length')" "no round2/union records when gate quiet"
}

test_phaselog_captures_round2_union_when_gate_fires() {
    local args env out
    args=$(_pe_args)
    # B1: APPROVE with a consensus Important in [60,80) → gate fires, round 2 runs.
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[{"file":"a.cs","line":10,"severity":"Important","confidence":72,"description":"d","suggested_fix":"f"}],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> r1\n"}'
    out=$(_pe_run_core "$args" "$env")
    # Round-2 cogs present (one per stochastic domain).
    assert_equals "8" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="round2")] | length')" "8 round-2 cogs when gate fires"
    # Exactly one union record.
    assert_equals "1" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="union")] | length')" "one union record when gate fires"
    # Two synth cogs (round 1 + round 2) — both draws captured.
    assert_equals "2" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="synth")] | length')" "two synth cogs when gate fires"
    # cross2 namespace populated and distinct from cross.
    assert_equals "8" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="cross2")] | length')" "8 cross2 cogs (round-2 cross-review)"
}

# ---------------------------------------------------------------------------
# Replay contract: pins the diff-reconstruction recipe documented in
# specialist-context.md so that a specialist can always regenerate its exact
# input from the four durable meta keys (base, head_sha, empty_tree_mode,
# path_scope). If the diff syntax that specialists use ever changes, BOTH this
# test AND the spec's reconstruction recipe in specialist-context.md must change
# in lockstep.
#
# The helper below encodes the recipe. Each test_* function below derives its
# "specialist's actual command" side INDEPENDENTLY (literal git commands written
# per specialist-context.md) so the two sides can genuinely diverge if the
# recipe drifts.
# ---------------------------------------------------------------------------

# Encode the reconstruction recipe from specialist-context.md §44-46.
# $1=base $2=head_sha $3=empty_tree_mode (true|false) $4=path_scope (may be empty)
# Emits the diff piped through git hash-object --stdin.
_pe_reconstruct_diff() {
    local base head_sha empty_tree_mode path_scope hash
    base="$1"
    head_sha="$2"
    empty_tree_mode="$3"
    path_scope="$4"
    if [ "$empty_tree_mode" = "true" ]; then
        # Two-arg syntax for empty-tree mode (spec §44).
        if [ -n "$path_scope" ]; then
            hash=$(git -C "$REPO_ROOT" diff "$base" "$head_sha" -- "$path_scope" | git -C "$REPO_ROOT" hash-object --stdin)
        else
            hash=$(git -C "$REPO_ROOT" diff "$base" "$head_sha" | git -C "$REPO_ROOT" hash-object --stdin)
        fi
    else
        # Three-dot syntax for normal mode (spec §44).
        if [ -n "$path_scope" ]; then
            hash=$(git -C "$REPO_ROOT" diff "$base"..."$head_sha" -- "$path_scope" | git -C "$REPO_ROOT" hash-object --stdin)
        else
            hash=$(git -C "$REPO_ROOT" diff "$base"..."$head_sha" | git -C "$REPO_ROOT" hash-object --stdin)
        fi
    fi
    echo "$hash"
}

# Fixture 1: normal three-dot, no path scope.
test_reconstruction_round_trip_normal() {
    local base head specialist_hash recipe_hash unscoped_diff
    base=$(git -C "$REPO_ROOT" rev-parse HEAD~1)
    head=$(git -C "$REPO_ROOT" rev-parse HEAD)
    # Specialist's literal command (specialist-context.md §44: three-dot when empty_tree_mode=false).
    specialist_hash=$(git -C "$REPO_ROOT" diff "$base"..."$head" | git -C "$REPO_ROOT" hash-object --stdin)
    # Recipe output from meta keys.
    recipe_hash=$(_pe_reconstruct_diff "$base" "$head" "false" "")
    assert_equals "$specialist_hash" "$recipe_hash" "normal: recipe hash matches specialist three-dot diff"
    # Diff must be non-empty (HEAD~1..HEAD always has content).
    unscoped_diff=$(git -C "$REPO_ROOT" diff "$base"..."$head")
    if [ -n "$unscoped_diff" ]; then
        pass "normal: HEAD~1..HEAD diff is non-empty"
    else
        fail "normal: HEAD~1..HEAD diff is non-empty" "diff was empty — fixture assumption broken"
    fi
}

# Fixture 2: three-dot with path scope.
# Uses HEAD~2..HEAD~1 (which always has ≥2 changed files on this branch) so
# scoping to one file genuinely narrows the diff.
test_reconstruction_round_trip_path_scope() {
    local base head path_scope specialist_hash recipe_hash unscoped_hash
    base=$(git -C "$REPO_ROOT" rev-parse HEAD~2)
    head=$(git -C "$REPO_ROOT" rev-parse HEAD~1)
    # A real path that changed in HEAD~2..HEAD~1 (confirmed at authoring time).
    path_scope="tests/lib/test_phase_efficacy.sh"
    # Specialist's literal command (spec §44 three-dot + §46 path scope).
    specialist_hash=$(git -C "$REPO_ROOT" diff "$base"..."$head" -- "$path_scope" | git -C "$REPO_ROOT" hash-object --stdin)
    # Recipe output from meta keys.
    recipe_hash=$(_pe_reconstruct_diff "$base" "$head" "false" "$path_scope")
    assert_equals "$specialist_hash" "$recipe_hash" "path-scope: recipe hash matches specialist scoped diff"
    # Scoping must actually narrow the diff — scoped hash must differ from unscoped.
    unscoped_hash=$(git -C "$REPO_ROOT" diff "$base"..."$head" | git -C "$REPO_ROOT" hash-object --stdin)
    if [ "$recipe_hash" != "$unscoped_hash" ]; then
        pass "path-scope: scoped diff differs from unscoped (-- pathspec is applied)"
    else
        fail "path-scope: scoped diff differs from unscoped (-- pathspec is applied)" "hashes identical — path scope had no effect"
    fi
}

# Fixture 3: empty-tree two-arg mode (and branch-matters proof).
test_reconstruction_round_trip_empty_tree() {
    local empty_tree head specialist_hash recipe_hash normal_hash
    empty_tree="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    head=$(git -C "$REPO_ROOT" rev-parse HEAD)
    # Specialist's literal command (spec §44: two-arg when empty_tree_mode=true).
    specialist_hash=$(git -C "$REPO_ROOT" diff "$empty_tree" "$head" | git -C "$REPO_ROOT" hash-object --stdin)
    # Recipe output from meta keys.
    recipe_hash=$(_pe_reconstruct_diff "$empty_tree" "$head" "true" "")
    assert_equals "$specialist_hash" "$recipe_hash" "empty-tree: recipe hash matches specialist two-arg diff"
    # Branch matters: empty-tree (two-arg) hash must differ from normal three-dot HEAD~1..HEAD hash.
    # If _pe_reconstruct_diff ignored empty_tree_mode and always used three-dot, fixture 3 would fail.
    normal_hash=$(_pe_reconstruct_diff "$(git -C "$REPO_ROOT" rev-parse HEAD~1)" "$head" "false" "")
    if [ "$recipe_hash" != "$normal_hash" ]; then
        pass "empty-tree: two-arg hash differs from three-dot HEAD~1..HEAD (empty_tree_mode branch is exercised)"
    else
        fail "empty-tree: two-arg hash differs from three-dot HEAD~1..HEAD (empty_tree_mode branch is exercised)" "hashes identical — empty_tree_mode has no effect"
    fi
}
