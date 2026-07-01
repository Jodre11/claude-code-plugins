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
