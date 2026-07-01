#!/usr/bin/env bash
# Tests for the ephemeral worktree review isolation feature:
# the repoDir Workflow arg, the bin/review-worktree helper, and the
# Phase -0.5 / Phase 0.55-gating / teardown prose.

_rw_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

test_review_worktree_repodir_threaded() {
    local cr
    cr=$(_rw_cr_dir)
    local missing=()
    local f
    for f in \
        "includes/review-pipeline.md" \
        "skills/review-gh-pr/SKILL.md" \
        "commands/pre-review.md"; do
        if ! grep -qF 'repoDir: $REPO_DIR' "$cr/$f" 2>/dev/null; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "repoDir threaded into workflow() args in all three consumers"
    else
        fail "repoDir threaded into workflow() args in all three consumers" \
            "missing 'repoDir: \$REPO_DIR' in: ${missing[*]}"
    fi
}

# Build a fixture repo with an 'origin' remote and one commit on 'main'.
# Echoes: "<repoDir> <bareOrigin> <headSha>". Caller rm -rf's both dirs.
_rw_make_fixture() {
    local origin work
    origin=$(mktemp -d)
    work=$(mktemp -d)
    git init -q --bare "$origin"
    git init -q -b main "$work"
    git -C "$work" config user.email "t@example.com"
    git -C "$work" config user.name "T"
    echo "hello" > "$work/file.txt"
    git -C "$work" add file.txt
    git -C "$work" commit -qm "v1"
    git -C "$work" remote add origin "$origin"
    git -C "$work" push -q -u origin main
    printf '%s %s %s\n' "$work" "$origin" "$(git -C "$work" rev-parse HEAD)"
}

test_review_worktree_add_happy_path() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree add: happy path" "helper missing or not executable"
        return
    fi
    local root fixture work origin sha wt_path actual
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)

    wt_path=$(CLAUDE_TEMP_DIR="$root" "$helper" add "$work" main "$sha")
    if [[ -d "$wt_path" ]]; then
        pass "review-worktree add: prints an existing worktree path"
    else
        fail "review-worktree add: prints an existing worktree path" "path: $wt_path"
    fi

    actual=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)
    assert_equals "$sha" "$actual" "review-worktree add: worktree HEAD is the expected SHA"

    # Detached HEAD -> symbolic-ref fails.
    if git -C "$wt_path" symbolic-ref -q HEAD >/dev/null 2>&1; then
        fail "review-worktree add: worktree is detached" "HEAD is on a branch"
    else
        pass "review-worktree add: worktree is detached"
    fi

    git -C "$work" worktree remove --force "$wt_path" 2>/dev/null || true
    rm -rf "$root" "$work" "$origin"
}

test_review_worktree_add_sha_mismatch_halts() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree add: SHA mismatch halts" "helper missing"
        return
    fi
    local root work origin sha wrong out rc before after
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)
    wrong="0000000000000000000000000000000000000000"

    before=$(find "$root" -maxdepth 1 -type d -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')
    set +e
    out=$(CLAUDE_TEMP_DIR="$root" "$helper" add "$work" main "$wrong" 2>&1)
    rc=$?
    set -e
    after=$(find "$root" -maxdepth 1 -type d -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')

    if [[ $rc -ne 0 ]]; then
        pass "review-worktree add: SHA mismatch exits non-zero"
    else
        fail "review-worktree add: SHA mismatch exits non-zero" "exit 0, stdout: $out"
    fi
    assert_equals "$before" "$after" "review-worktree add: SHA mismatch creates no worktree"

    rm -rf "$root" "$work" "$origin"
}

test_review_worktree_add_prunes_stale() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree add: prunes stale worktrees" "helper missing"
        return
    fi
    local root work origin sha stale wt_path
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)

    # Seed a stale plugin-owned dir aged past a 1-minute threshold.
    mkdir -p "$root/review-worktrees"
    stale="$root/review-worktrees/wt-staleseed000-1"
    mkdir -p "$stale"
    # Set mtime to 10 minutes ago using POSIX touch -t (works on GNU and BSD)
    touch -t "$(date -v-600S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-600 seconds' +%Y%m%d%H%M.%S)" "$stale"

    wt_path=$(CLAUDE_TEMP_DIR="$root" REVIEW_WORKTREE_STALE_MINUTES=1 "$helper" add "$work" main "$sha")

    if [[ -d "$stale" ]]; then
        fail "review-worktree add: prunes stale worktrees" "stale dir survived"
    else
        pass "review-worktree add: prunes stale worktrees"
    fi

    git -C "$work" worktree remove --force "$wt_path" 2>/dev/null || true
    rm -rf "$root" "$work" "$origin"
}

test_review_worktree_remove_idempotent() {
    local helper
    helper="$(_rw_cr_dir)/bin/review-worktree"
    if [[ ! -x "$helper" ]]; then
        fail "review-worktree remove: idempotent" "helper missing"
        return
    fi
    local root work origin sha wt_path rc1 rc2
    root=$(mktemp -d)
    read -r work origin sha < <(_rw_make_fixture)
    wt_path=$(CLAUDE_TEMP_DIR="$root" "$helper" add "$work" main "$sha")

    set +e
    CLAUDE_TEMP_DIR="$root" "$helper" remove "$wt_path"; rc1=$?
    CLAUDE_TEMP_DIR="$root" "$helper" remove "$wt_path"; rc2=$?
    set -e

    if [[ ! -d "$wt_path" ]]; then
        pass "review-worktree remove: worktree gone after remove"
    else
        fail "review-worktree remove: worktree gone after remove" "still present"
    fi
    assert_equals "0" "$rc1" "review-worktree remove: first remove exits 0"
    assert_equals "0" "$rc2" "review-worktree remove: second remove (already gone) exits 0"

    rm -rf "$root" "$work" "$origin"
}
