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
