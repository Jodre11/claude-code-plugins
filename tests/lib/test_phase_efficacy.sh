#!/usr/bin/env bash
# Per-cog I/O instrumentation tests. The first group calls buildLogPayload in isolation (the
# call mode of tests/lib/_tc_runner.js). Later groups run review-core.js end to end through
# the same runner and assert on bundle.log.

_pe_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Invoke buildLogPayload(findings, bodyText, phaseLog) in isolation. $1 = findings json,
# $2 = phaseLog json. Emits the payload JSON.
_pe_build_log_payload() {
    WF="$(_pe_cr_dir)/workflows/review-core.js" TC_CALL=buildLogPayload \
        TC_INPUT="$(jq -cn --argjson f "$1" --argjson p "$2" '[$f, "body", $p]')" \
        node "$REPO_ROOT/tests/lib/_tc_runner.js" 2>&1 | jq -c '.result' 2>/dev/null || echo 'RUNNER_FAILED'
}

test_buildlogpayload_emits_meta_and_cogs() {
    local f pl out
    f='[{"source":"native","severity":"Important","blocking":true,"posting":"inline","file":"a.py","line":3,"description":"d","suggested_fix":"","failure_scenario":"fs"}]'
    pl='{"meta":{"base":"main","head_sha":"abc123","empty_tree_mode":false,"path_scope":"","finder":"native","cli_version":"x"},"cogs":[{"phase":"round1","domain":"ruff","output":{"findings":[]}}]}'
    out=$(_pe_build_log_payload "$f" "$pl")
    assert_equals "main" "$(echo "$out" | jq -r '.meta.base')" "meta.base passed through"
    assert_equals "abc123" "$(echo "$out" | jq -r '.meta.head_sha')" "meta.head_sha passed through"
    assert_equals "ruff" "$(echo "$out" | jq -r '.cogs[0].domain')" "cog domain passed through"
    assert_equals "round1" "$(echo "$out" | jq -r '.cogs[0].phase')" "cog phase passed through"
    assert_equals "true true fs" "$(echo "$out" | jq -r '.findings[0] | "\(.blocking) \(.verdict_relevant) \(.failure_scenario)"')" \
        "finding record: blocking, verdict_relevant = blocking, failure_scenario kept"
}

# Runs review-core.js end to end. $1 = flags json, $2 = native findings array json.
_pe_run_core() {
    local args native
    args=$(jq -cn --argjson flags "$1" \
        '{agentPrompt: "x", flags: $flags, reviewMode: "pr", base: "main", headSha: ("a" * 40),
          emptyTreeMode: false, pathScope: "", tempDir: "/tmp/claude-test/x", repoDir: "/tmp/fx-repo",
          changedLinesBlock: "Changed lines:\na.py: 1-40\n", cliVersion: "2.1.332",
          nativeTarget: ("/tmp/fx-repo " + ("b" * 40) + "..." + ("a" * 40))}')
    native=$(jq -cn --arg a "$2" '"Done.\n\n```json\n" + $a + "\n```"')
    WF="$(_pe_cr_dir)/workflows/review-core.js" TC_ARGS="$args" TC_NATIVE="$native" \
        node "$REPO_ROOT/tests/lib/_tc_runner.js" 2>&1 | jq -c '.bundle' 2>/dev/null || echo 'RUNNER_FAILED'
}

_PE_NAT='[{"file":"a.py","line":10,"summary":"d","failure_scenario":"f","severity":"important"}]'

test_phaselog_captures_round1_native_and_meta() {
    local out
    out=$(_pe_run_core '{"py":true,"iac":true}' "$_PE_NAT")
    assert_equals "main" "$(echo "$out" | jq -r '.log.meta.base')" "log.meta.base captured"
    assert_equals "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$(echo "$out" | jq -r '.log.meta.head_sha')" "log.meta.head_sha captured"
    assert_equals "false" "$(echo "$out" | jq -r '.log.meta.empty_tree_mode')" "log.meta.empty_tree_mode captured"
    assert_equals "native 2.1.332" "$(echo "$out" | jq -r '.log.meta | "\(.finder) \(.cli_version)"')" "log.meta finder and cli_version captured"
    assert_equals "ruff,trivy" "$(echo "$out" | jq -r '[.log.cogs[] | select(.phase=="round1") | .domain] | sort | join(",")')" \
        "one round-1 cog per flagged static specialist"
    assert_equals "1" "$(echo "$out" | jq '[.log.cogs[] | select(.phase=="native")] | length')" "one native cog"
    assert_equals "ok 1" "$(echo "$out" | jq -r '.log.cogs[] | select(.phase=="native") | "\(.output.status) \(.output.findings | length)"')" \
        "native cog carries native's raw array"
    assert_equals "null" "$(echo "$out" | jq -r '[.log.cogs[] | select(.phase=="round1")][0].input // "null"')" "round-1 cog omits input"
}

test_phaselog_phases_match_schema_enum() {
    local out schema
    schema="$(_pe_cr_dir)/includes/finding-schema.json"
    out=$(_pe_run_core '{"py":true}' "$_PE_NAT")
    assert_equals '["native","round1"]' "$(echo "$out" | jq -c '[.log.cogs[].phase] | unique')" "cogs record only round1 and native phases"
    assert_equals '["native","round1"]' \
        "$(jq -c '.["$defs"].sealedBundle.properties.log.properties.cogs.items.properties.phase.enum | sort' "$schema")" \
        "schema cog phase enum is exactly round1 + native"
}

# ---------------------------------------------------------------------------
# Replay contract: pins the diff-reconstruction recipe documented in
# static-analysis-context.md so that a specialist can always regenerate its exact
# input from the four durable meta keys (base, head_sha, empty_tree_mode,
# path_scope). If the diff syntax that specialists use ever changes, BOTH this
# test AND the reconstruction recipe in static-analysis-context.md must change
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
# per static-analysis-context.md) so the two sides can genuinely diverge if the
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

# Encode the reconstruction recipe from static-analysis-context.md §1.
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
        # Two-arg syntax for empty-tree mode (static-analysis-context.md §1).
        if [ -n "$path_scope" ]; then
            hash=$(git -C "$repo" diff "$base" "$head_sha" -- "$path_scope" | git -C "$repo" hash-object --stdin)
        else
            hash=$(git -C "$repo" diff "$base" "$head_sha" | git -C "$repo" hash-object --stdin)
        fi
    else
        # Three-dot syntax for normal mode (static-analysis-context.md §1).
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
    # Specialist's literal command (static-analysis-context.md §1: three-dot when empty_tree_mode=false).
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
    # Specialist's literal command (static-analysis-context.md §1: three-dot + path scope).
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
    # Specialist's literal command (static-analysis-context.md §1: two-arg when empty_tree_mode=true).
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
    # cogs MUST NOT be in log.required (the bare-invocation bundle carries no log).
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
