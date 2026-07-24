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
    echo "{\"agentPrompt\":\"x\",\"flags\":{},\"route\":\"full\",\"selfReReview\":false,\"reviewMode\":\"pr\",\"base\":\"main\",\"headSha\":\"${sha40}\",\"emptyTreeMode\":false,\"pathScope\":\"\",\"tempDir\":\"/tmp/claude-test/x\",\"orchestrationMode\":\"classic\"}"
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
    # One round-1 cog per core specialist (9 core, no conditionals).
    assert_equals "9" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="round1")] | length')" "9 round-1 cogs (core list)"
    # Round-1 cogs carry no input (diff reconstructed from meta).
    assert_equals "null" "$(echo "$out" | jq -r '[.log.cogs[] | select(.phase=="round1")][0].input // "null"')" "round-1 cog omits input"
}

test_phaselog_captures_cross_io() {
    local args env out
    args=$(_pe_args)
    env='{"verdict":"APPROVE","rubricRowApplied":4,"rubricReason":"clean","tiers":{"consensus":[],"synthesiser":[],"contested":[],"dismissed":[]},"bodyText":"## Synthesiser Assessment\n> ok\n"}'
    out=$(_pe_run_core "$args" "$env")
    # Cross cogs: one per cross-eligible domain (9 core minus api-contract in NON_CROSS = 8; none static here).
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
# Each fixture builds its OWN throwaway git repo (via _pe_make_fixture_repo)
# with exactly the commit shape it needs. This makes the tests hermetic — they
# depend on nothing in the ambient environment (no HEAD~1, no rev-list, no
# minimum clone depth, no global git identity), so they behave identically on a
# full clone, a shallow CI checkout, or a contributor's machine.
#
# The helper below encodes the recipe. Each test_* function derives its
# "specialist's actual command" side INDEPENDENTLY (literal git commands written
# per specialist-context.md) so the two sides can genuinely diverge if the
# recipe drifts.
# ---------------------------------------------------------------------------

# Build a hermetic throwaway git repo for the reconstruction fixtures and echo
# its path; the caller rm -rf's it when done. Identity/signing are set locally
# (never touching global config) so commits succeed in a bare CI environment.
# Layout: C0 adds alpha.txt; C1 adds beta.txt AND gamma.txt — so C0..C1 touches
# two files (the path-scope fixture needs ≥2 to prove scoping narrows) and the
# full snapshot at C1 (three files) differs from the C0..C1 delta (two files),
# which is what the empty-tree branch-matters assertion relies on.
_pe_make_fixture_repo() {
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "phase-efficacy test"
    git -C "$dir" config commit.gpgsign false
    printf 'alpha 1\n' > "$dir/alpha.txt"
    git -C "$dir" add alpha.txt
    git -C "$dir" commit -q -m "C0: add alpha"
    printf 'beta 1\n' > "$dir/beta.txt"
    printf 'gamma 1\n' > "$dir/gamma.txt"
    git -C "$dir" add beta.txt gamma.txt
    git -C "$dir" commit -q -m "C1: add beta and gamma"
    echo "$dir"
}

# Encode the reconstruction recipe from specialist-context.md §44-46.
# $1=repo $2=base $3=head_sha $4=empty_tree_mode (true|false) $5=path_scope (may be empty)
# Emits the diff piped through git hash-object --stdin.
_pe_reconstruct_diff() {
    local repo base head_sha empty_tree_mode path_scope hash
    repo="$1"
    base="$2"
    head_sha="$3"
    empty_tree_mode="$4"
    path_scope="$5"
    if [ "$empty_tree_mode" = "true" ]; then
        # Two-arg syntax for empty-tree mode (spec §44).
        if [ -n "$path_scope" ]; then
            hash=$(git -C "$repo" diff "$base" "$head_sha" -- "$path_scope" | git -C "$repo" hash-object --stdin)
        else
            hash=$(git -C "$repo" diff "$base" "$head_sha" | git -C "$repo" hash-object --stdin)
        fi
    else
        # Three-dot syntax for normal mode (spec §44).
        if [ -n "$path_scope" ]; then
            hash=$(git -C "$repo" diff "$base"..."$head_sha" -- "$path_scope" | git -C "$repo" hash-object --stdin)
        else
            hash=$(git -C "$repo" diff "$base"..."$head_sha" | git -C "$repo" hash-object --stdin)
        fi
    fi
    echo "$hash"
}

# Fixture 1: normal three-dot, no path scope.
test_reconstruction_round_trip_normal() {
    local repo base head specialist_hash recipe_hash unscoped_diff
    repo=$(_pe_make_fixture_repo)
    base=$(git -C "$repo" rev-parse HEAD~1)
    head=$(git -C "$repo" rev-parse HEAD)
    # Specialist's literal command (specialist-context.md §44: three-dot when empty_tree_mode=false).
    specialist_hash=$(git -C "$repo" diff "$base"..."$head" | git -C "$repo" hash-object --stdin)
    # Recipe output from meta keys.
    recipe_hash=$(_pe_reconstruct_diff "$repo" "$base" "$head" "false" "")
    assert_equals "$specialist_hash" "$recipe_hash" "normal: recipe hash matches specialist three-dot diff"
    # Diff must be non-empty (C0..C1 always has content).
    unscoped_diff=$(git -C "$repo" diff "$base"..."$head")
    if [ -n "$unscoped_diff" ]; then
        pass "normal: C0..C1 diff is non-empty"
    else
        fail "normal: C0..C1 diff is non-empty" "diff was empty — fixture assumption broken"
    fi
    rm -rf "$repo"
}

# Fixture 2: three-dot with path scope.
# The fixture repo's C0..C1 touches two files (beta.txt + gamma.txt) by
# construction, so scoping to one of them genuinely narrows the diff and the
# scoped-hash != unscoped-hash assertion is always meaningful — no runtime
# discovery and no dependency on the ambient repo's history.
test_reconstruction_round_trip_path_scope() {
    local repo base head path_scope specialist_hash recipe_hash unscoped_hash
    repo=$(_pe_make_fixture_repo)
    base=$(git -C "$repo" rev-parse HEAD~1)
    head=$(git -C "$repo" rev-parse HEAD)
    path_scope="beta.txt"
    # Specialist's literal command (spec §44 three-dot + §46 path scope).
    specialist_hash=$(git -C "$repo" diff "$base"..."$head" -- "$path_scope" | git -C "$repo" hash-object --stdin)
    # Recipe output from meta keys.
    recipe_hash=$(_pe_reconstruct_diff "$repo" "$base" "$head" "false" "$path_scope")
    assert_equals "$specialist_hash" "$recipe_hash" "path-scope: recipe hash matches specialist scoped diff"
    # Scoping must actually narrow the diff — scoped hash must differ from unscoped.
    unscoped_hash=$(git -C "$repo" diff "$base"..."$head" | git -C "$repo" hash-object --stdin)
    if [ "$recipe_hash" != "$unscoped_hash" ]; then
        pass "path-scope: scoped diff differs from unscoped (-- pathspec is applied)"
    else
        fail "path-scope: scoped diff differs from unscoped (-- pathspec is applied)" "hashes identical — path scope had no effect"
    fi
    rm -rf "$repo"
}

# Fixture 3: empty-tree two-arg mode (and branch-matters proof).
test_reconstruction_round_trip_empty_tree() {
    local repo empty_tree base head specialist_hash recipe_hash delta_hash
    repo=$(_pe_make_fixture_repo)
    empty_tree="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    base=$(git -C "$repo" rev-parse HEAD~1)
    head=$(git -C "$repo" rev-parse HEAD)
    # Specialist's literal command (spec §44: two-arg when empty_tree_mode=true).
    specialist_hash=$(git -C "$repo" diff "$empty_tree" "$head" | git -C "$repo" hash-object --stdin)
    # Recipe output from meta keys.
    recipe_hash=$(_pe_reconstruct_diff "$repo" "$empty_tree" "$head" "true" "")
    assert_equals "$specialist_hash" "$recipe_hash" "empty-tree: recipe hash matches specialist two-arg diff"
    # Branch matters: the empty-tree two-arg diff (full snapshot at C1 — three
    # files) must differ from the three-dot C0..C1 delta (two files). If
    # _pe_reconstruct_diff ignored empty_tree_mode and always used three-dot,
    # this would fail. Independent literal — NOT via the helper — so a
    # correlated helper bug cannot produce a false pass.
    delta_hash=$(git -C "$repo" diff "$base"..."$head" | git -C "$repo" hash-object --stdin)
    if [ "$recipe_hash" != "$delta_hash" ]; then
        pass "empty-tree: two-arg full-snapshot hash differs from three-dot C0..C1 delta (empty_tree_mode branch is exercised)"
    else
        fail "empty-tree: two-arg full-snapshot hash differs from three-dot C0..C1 delta (empty_tree_mode branch is exercised)" "hashes identical — empty_tree_mode has no effect"
    fi
    rm -rf "$repo"
}

test_schema_documents_cog_payload() {
    local cr schema
    cr=$(_pe_cr_dir)
    schema="$cr/includes/finding-schema.json"
    # log.meta documented.
    if jq -e '.["$defs"].sealedBundle.properties.log.properties.meta' "$schema" >/dev/null 2>&1; then
        pass "log.meta documented in schema"
    else
        fail "log.meta documented in schema" "missing meta in log payload"
    fi
    # log.cogs documented as an array.
    if [[ "$(jq -r '.["$defs"].sealedBundle.properties.log.properties.cogs.type' "$schema" 2>/dev/null)" == "array" ]]; then
        pass "log.cogs documented as array"
    else
        fail "log.cogs documented as array" "cogs missing or not array"
    fi
    # meta/cogs MUST NOT be in log.required (omitted on lightweight/no-capture).
    if jq -e '.["$defs"].sealedBundle.properties.log.required | index("cogs")' "$schema" >/dev/null 2>&1; then
        fail "log.cogs is optional" "cogs wrongly listed in log.required"
    else
        pass "log.cogs is optional (not in required)"
    fi
}

test_both_hosts_document_cog_jsonl() {
    local cr file
    cr=$(_pe_cr_dir)
    # JSONL format (meta/cog/finding/token rows) is now owned by bin/durable-log-write.
    # Host prose delegates via the writer CLI; verify the writer binary emits meta and cog rows.
    local writer="$cr/bin/durable-log-write"
    if grep -qF 'type:"meta"' "$writer" && grep -qF 'type:"cog"' "$writer"; then
        pass "host documents per-cog JSONL: writer binary"
    else
        fail "host documents per-cog JSONL: writer binary" "writer binary must emit type:meta and type:cog rows"
    fi
    # Both host call sites must invoke the writer.
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        if grep -qF 'bin/durable-log-write' "$cr/$file"; then
            pass "host invokes durable-log-write: $file"
        else
            fail "host invokes durable-log-write: $file" "host must invoke bin/durable-log-write (writer owns JSONL format)"
        fi
    done
}
