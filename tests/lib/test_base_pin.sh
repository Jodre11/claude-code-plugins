#!/usr/bin/env bash
# Origin-pinned base SHA regression guards (spec 2026-07-10-origin-pinned-base-sha).
# The pipeline body is byte-synced across three files; these guards assert the new
# base-pin prose landed in the CANONICAL (includes/review-pipeline.md) and, for the
# read-only path, in includes/specialist-context.md. The existing pipeline-inline sync
# test enforces propagation to SKILL.md and pre-review.md.

test_base_pin_phase_minus05_pins_baserefoid() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin Phase -0.5" "code-review-suite plugin not found"
        return
    fi
    local canonical="$cr/includes/review-pipeline.md"
    # Scope to the Phase -0.5 section so §2a's later baseRefOid addition cannot false-pass this.
    local phase
    phase=$(sed -n '/^## Phase -0.5: Ephemeral worktree$/,/^## Phase 0: Intent Ledger$/p' "$canonical")
    if grep -qF 'baseRefOid' <<<"$phase" && grep -qF 'BASE_PINNED = true' <<<"$phase"; then
        pass "base pin Phase -0.5: canonical resolves baseRefOid and sets \$BASE_PINNED"
    else
        fail "base pin Phase -0.5: canonical resolves baseRefOid and sets \$BASE_PINNED" \
            "review-pipeline.md Phase -0.5 (owned-worktree path) must resolve the PR baseRefOid and set \$BASE_PINNED = true so the base diff endpoint is an origin-pinned SHA"
    fi
}

test_base_pin_step1_skips_when_pinned() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin Step 1 guard" "code-review-suite plugin not found"
        return
    fi
    local canonical="$cr/includes/review-pipeline.md"
    # The guard must sit BEFORE "Try these in order:" so it never enters the byte-synced
    # items 1-4. Extract Step 1's head (heading -> "Try these in order:") and assert it.
    local head
    head=$(sed -n '/^### Step 1: Determine base branch$/,/^Try these in order:$/p' "$canonical")
    if grep -qF 'BASE_PINNED' <<<"$head" && grep -qiF 'skip items 1' <<<"$head"; then
        pass "base pin Step 1 guard: canonical skips re-resolution when \$BASE_PINNED is true"
    else
        fail "base pin Step 1 guard: canonical skips re-resolution when \$BASE_PINNED is true" \
            "Step 1 must guard on \$BASE_PINNED BEFORE 'Try these in order:' — otherwise item 2 (gh pr view --json baseRefName) overwrites the Phase -0.5 SHA pin with a bare branch name"
    fi
}

test_base_pin_step1_noworktree_fallback() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin Step 1 fallback" "code-review-suite plugin not found"
        return
    fi
    local canonical="$cr/includes/review-pipeline.md"
    # The --no-worktree fallback lives AFTER "Store as" (outside byte-synced items 1-4) and
    # before Step 2. It must pin baseRefOid and fetch (orchestrator-only, main session).
    local tail
    tail=$(sed -n '/^Store as /,/^### Step 2: Measure the diff/p' "$canonical")
    if grep -qF 'baseRefOid' <<<"$tail" && grep -qF 'fetch origin' <<<"$tail"; then
        pass "base pin Step 1 fallback: canonical pins baseRefOid + fetches on the --no-worktree path"
    else
        fail "base pin Step 1 fallback: canonical pins baseRefOid + fetches on the --no-worktree path" \
            "Step 1 must, after 'Store as \$BASE', pin baseRefOid and 'git fetch origin' for the --no-worktree PR path (orchestrator-only, guarded by \$BASE_PINNED not true and \$REVIEW_MODE = pr)"
    fi
}

test_base_pin_specialist_readonly() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin specialist read-only" "code-review-suite plugin not found"
        return
    fi
    local spec="$cr/includes/specialist-context.md"
    # Standalone specialists may pin baseRefOid ONLY if the SHA is already local (git cat-file
    # -e). They must NEVER fetch (read-only mandate; the guard blocks it).
    if grep -qF 'baseRefOid' "$spec" && grep -qF 'git cat-file -e' "$spec"; then
        pass "base pin specialist read-only: specialist-context pins baseRefOid guarded by cat-file"
    else
        fail "base pin specialist read-only: specialist-context pins baseRefOid guarded by cat-file" \
            "specialist-context.md must read baseRefOid and gate the pin on 'git cat-file -e' (SHA already in the local object store)"
    fi
}

test_base_pin_specialist_never_fetches() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "base pin specialist never fetches" "code-review-suite plugin not found"
        return
    fi
    local spec="$cr/includes/specialist-context.md"
    if grep -qF 'fetch origin' "$spec"; then
        fail "base pin specialist never fetches: specialist-context contains no 'fetch origin'" \
            "specialist-context.md must contain no 'fetch origin' — reviewers are read-only and the reviewer guard (allow-permissions.sh) blocks a fetch"
    else
        pass "base pin specialist never fetches: specialist-context contains no 'fetch origin'"
    fi
}
