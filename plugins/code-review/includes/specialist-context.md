## Context Gathering

Determine the base branch, then gather the diff and changed files yourself.

### Determine base branch

1. If `$ARGUMENTS` is provided and non-empty, extract the base branch from it. If a `Base branch: <ref>` line is present, extract the ref after the colon. Otherwise, treat the entire value of `$ARGUMENTS` as a bare branch name.
2. `gh pr view --json baseRefName -q .baseRefName 2>/dev/null`
3. Run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null` and strip the `refs/remotes/origin/` prefix from the output
4. Fall back to `main`

Store as `$BASE`.

If a `Head SHA: <sha>` line is present in `$ARGUMENTS`, extract it and store as `$HEAD_SHA`. Otherwise, run `git rev-parse HEAD` and store as `$HEAD_SHA` — but log a warning: "Head SHA not found in prompt — using current HEAD; results may differ from pipeline's measurement." Using a pinned SHA ensures all agents review the same commit even if new commits land during the review.

### Gather context

1. `git diff "$BASE"..."$HEAD_SHA" --name-only` — changed files. If empty, report "No changes found against $BASE" and stop.
2. `git diff "$BASE"..."$HEAD_SHA"` — full diff.
3. Read `CLAUDE.md` in the repo root (if it exists) for project conventions.
4. Read each changed file for full context. If more than 20 files changed, prioritise non-test source files with the largest diffs. Skip generated files, lock files, and vendored dependencies.
