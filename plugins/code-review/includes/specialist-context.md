## Context Gathering

Determine the base branch, then gather the diff and changed files yourself.

### Determine base branch

This duplicates the logic in `includes/review-pipeline.md` "Step 1: Determine base branch" intentionally — specialists must resolve `$BASE` independently so they work standalone. Steps 1–5 here must match `review-pipeline.md` Step 1 items 1–5. Changes to either location must be mirrored in the other.

1. If `$ARGUMENTS` is provided and non-empty, extract the base branch from it. If a `Base branch: <ref>` line is present, extract the ref after the colon. Otherwise, treat the entire value of `$ARGUMENTS` as a bare branch name.
2. `gh pr view --json baseRefName -q .baseRefName 2>/dev/null`
3. Run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null` and strip the `refs/remotes/origin/` prefix from the output
4. Fall back to `main`

Store as `$BASE`. If `$BASE` is exactly `EMPTY_TREE`, resolve it by running `git hash-object -t tree /dev/null` and store the resulting SHA as `$BASE`. Set `$EMPTY_TREE_MODE = true`. Otherwise set `$EMPTY_TREE_MODE = false`.

If an `Empty tree mode: true` line is present in `$ARGUMENTS`, set `$EMPTY_TREE_MODE = true` — this overrides the above (the pipeline orchestrator already resolved the SHA and passes the flag through).

Validate that `$BASE` matches `^[a-zA-Z0-9/_.\-]+$` — if it does not, report "Invalid base branch ref: $BASE" and stop.

**Diff syntax:** When `$EMPTY_TREE_MODE` is true, use two-arg `git diff $BASE $HEAD_SHA` instead of `git diff "$BASE"..."$HEAD_SHA"` for ALL diff commands. When false, use three-dot syntax as normal.

5. If a `Path scope: <pathspec>` line is present in `$ARGUMENTS`, extract the pathspec after the colon and store as `$PATH_SCOPE`. If not present, leave `$PATH_SCOPE` empty. When `$PATH_SCOPE` is set, append `-- $PATH_SCOPE` after all flags in every `git diff` command (e.g., `git diff "$BASE"..."$HEAD_SHA" --name-only -- $PATH_SCOPE`).

If a `Head SHA: <sha>` line is present in `$ARGUMENTS`, extract it and store as `$HEAD_SHA`. Otherwise, run `git rev-parse HEAD` and store as `$HEAD_SHA` — but log a warning: "Head SHA not found in prompt — using current HEAD; results may differ from pipeline's measurement." Using a pinned SHA ensures all agents review the same commit even if new commits land during the review. Validate that `$HEAD_SHA` matches `^[0-9a-f]{40}$` — if it does not, report "Invalid HEAD SHA: $HEAD_SHA" and stop.

### Gather context

1. Run `git diff` to get changed files (append `-- $PATH_SCOPE` if set). Use the diff syntax determined by `$EMPTY_TREE_MODE` (two-arg when true, three-dot when false). If empty, report "No changes found against $BASE" and stop.
2. Run `git diff` to get the full diff (append `-- $PATH_SCOPE` if set). Use the same diff syntax as above.
3. Read `CLAUDE.md` in the repo root (if it exists) for project conventions.
4. Read `includes/severity-definitions.md` (if it exists) for the severity classification definitions to apply when assigning severity to findings.
5. Read each changed file for full context. If more than 20 files changed, prioritise non-test source files with the largest diffs. Skip generated files, lock files, and vendored dependencies.
