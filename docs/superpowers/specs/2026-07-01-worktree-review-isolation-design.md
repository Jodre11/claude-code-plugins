# Ephemeral worktree isolation for code-review-suite

## Context

The `code-review-suite` PR-review pipeline currently runs against whatever the target
repository has checked out. This causes two problems:

1. **No isolation.** Two reviews cannot run against the same repo at once, and a review
   interferes with (and is interfered with by) whatever work is live in that checkout.
2. **Silent wrong-commit risk.** Phase 0.55 asks the *human* to fetch and halts if the
   local tree is behind the remote head. That guard fails exactly when the user is moving
   fast — a review can run against stale code without anyone noticing.

This change reviews a committed PR against an **ephemeral git worktree cut from the exact
PR head SHA**, discarded when the review completes. A worktree shares the repo's `.git`
object store but has its own working directory and index, so concurrent reviews get
separate worktrees and neither disturbs the user's primary checkout.

## Scope

In scope:
- **`review-gh-pr`** (PR mode): default to an ephemeral, plugin-owned worktree.
- **`shakedown`** (private, `~/.claude`): supplies its own **persistent, externally-owned**
  worktree that accumulates commits across cycles. The plugin uses it but never creates or
  tears it down.

Out of scope:
- **`pre-review`** (local mode): reviews the uncommitted working tree. A worktree cut from
  a commit would not contain the user's dirty changes; replicating that state into a
  separate worktree adds correctness risk (the review could analyse different bytes than
  the tree holds) for zero isolation gain — pre-review is already read-only and never
  mutates the tree, so it neither blocks a concurrent review nor disturbs live work. Left
  unchanged.

## Prerequisite fix (ships regardless)

`review-core.mjs` reads `repoDir` (lines 126, 356) to tell the **synthesiser** which tree
to read, but the host skill's `workflow()` call (`skills/review-gh-pr/SKILL.md` lines
912-923) never passes it. Today the synthesiser silently reads cwd. Under a worktree this
would make the synthesiser read the *wrong* tree.

**Fix:** add `repoDir: $REPO_DIR` to the `workflow()` args object. Standalone correctness
fix; the worktree work depends on it.

## Component 1 — `bin/review-worktree` (deterministic helper)

A new bash executable (`chmod +x`, matching the `bin/housekeeper-freshness` idiom). The
fragile multi-step git sequence is deterministic, unit-testable shell — never
LLM-improvised prose (per the repo's repeated lesson: drive determinism from a real
script, don't rely on the agent to execute a multi-step procedure).

### `review-worktree add <repoDir> <branch> <expectedHeadSha>`

Verifies-then-creates. Prints the absolute worktree path on success; exits non-zero and
creates nothing on any failure.

1. **Prune stale plugin-owned worktrees** (self-heal): before creating, remove any
   plugin-owned worktrees under the temp root older than a threshold, then
   `git -C <repoDir> worktree prune`. A worktree leaked by an earlier crashed run
   self-heals here.
2. **Fetch the exact head by branch:** `git -C <repoDir> fetch origin <branch>`.
3. **Verify the fetched ref matches the expected SHA:** resolve `origin/<branch>` (or
   `FETCH_HEAD`) and assert it equals `<expectedHeadSha>`. If not, exit non-zero — the
   fetch did not land the commit GitHub reported as the head.
4. **Create the worktree detached at the immutable SHA:**
   `git -C <repoDir> worktree add --detach <path> <expectedHeadSha>`, where `<path>` is
   under `$CLAUDE_TEMP_DIR` (session-scoped).
5. **Post-condition assertion:** `git -C <path> rev-parse HEAD` must equal
   `<expectedHeadSha>`. On mismatch, tear down the partial worktree and exit non-zero.
6. Print the absolute `<path>` to stdout.

### `review-worktree remove <worktreePath>`

Idempotent teardown: `git worktree remove --force <path>` then `git worktree prune`.
No-op (exit 0) if the path is already gone.

### Correctness chain

`GitHub head SHA (gh pr view --json headRefOid)` → fetched → worktree cut at that SHA →
`rev-parse HEAD` re-asserted equal → pinned as `$HEAD_SHA` for the rest of the pipeline.
Three independent checkpoints replace the single manual "please fetch". Any break in the
chain is a hard halt: the pipeline never reviews an unverified tree.

## Component 2 — `review-gh-pr` skill changes (host layer)

The Workflow core runs in a sandbox with no shell/filesystem access, so worktree lifecycle
*must* live in the host skill. All downstream phases already consume `$REPO_DIR` and
`$HEAD_SHA` verbatim, so only the following change:

### (a) `repoDir` fix
As above — add `repoDir: $REPO_DIR` to the `workflow()` args.

### (b) New Phase -0.5 "Ephemeral worktree" (after Phase -1, opt-out)

Runs only for `$REVIEW_MODE = pr`. Skipped entirely for `local`.

Resolve mode, first match wins:
- **External worktree supplied** — `$ARGUMENTS` carries a `Worktree: <abs-path>` line:
  set `$REPO_DIR = <abs-path>`, `$WORKTREE_OWNED = false`. Skip create **and** teardown.
  (The shakedown accumulation case.)
- **`--no-worktree` token present:** skip; keep today's in-place behaviour against
  `$REPO_DIR`. `$WORKTREE_OWNED = false`.
- **Default (owned):** resolve `$EXPECTED_HEAD_SHA` from
  `gh pr view --repo "$OWNER_REPO" --json headRefOid -q .headRefOid` (validate
  `^[0-9a-f]{40}$`). Call
  `bin/review-worktree add "$REPO_DIR" "$branch" "$EXPECTED_HEAD_SHA"`, capture the printed
  worktree path. Reassign `$REPO_DIR` to it, set `$WORKTREE_OWNED = true`, and pin
  `$HEAD_SHA = $EXPECTED_HEAD_SHA`. On non-zero exit from the helper, hard-halt with the
  helper's message — no review runs.

### (c) Phase 0.55 gating

The owned-worktree path is cut from the freshly-verified head, so the "local HEAD behind
remote" staleness halt is redundant there. Run the existing Phase 0.55 checks **only when
`$WORKTREE_OWNED = false`** (the `--no-worktree` and external-worktree paths keep today's
guard).

### (d) Teardown on every exit path

If `$WORKTREE_OWNED = true`, call `bin/review-worktree remove "$REPO_DIR"` on **every**
pipeline exit — success, clean halt, or error. Combined with the prune-on-next-`add`
self-heal (Component 1 step 1), a worktree leaked by a hard crash between `add` and
`remove` is reclaimed on the next review.

## Component 3 — `shakedown` (private, `~/.claude`) integration

Shakedown already resolves an explicit `$REPO_DIR` and requires it clean at PR head. To use
an externally-owned persistent worktree, shakedown passes a `Worktree: <abs-path>` line in
the `agentPrompt`/args it hands to `review-gh-pr` / `review-core`, so the plugin treats it
as `$WORKTREE_OWNED = false` (no create, no teardown). Shakedown owns that worktree's
lifecycle across its cycles and its single end-of-run push. No plugin-side teardown ever
touches it.

(Detailed shakedown wiring is a follow-on task in the private repo; this spec fixes the
plugin contract — the `Worktree:` line — that shakedown targets.)

## Mid-review head drift

The worktree pins to the PR head **at review start**. If the PR head advances mid-review,
that is out of scope to chase: the existing Step 4 / Class B.2 pre-post check re-reads
`headRefOid` before submitting and warns the user that findings may be stale. A post-hoc
push effectively invalidates the snapshot review somewhat — discerned at submission time,
not chased mid-analysis. "Right commit at start, detect drift before posting" is covered
end to end.

## Error handling

- Helper `add` fails (fetch miss, SHA mismatch, post-condition fail) → non-zero exit,
  nothing created, skill hard-halts. Never review an unverified tree.
- Helper `remove` is idempotent — safe to call on any exit path, safe to double-call.
- Leaked worktree (crash between add/remove) → reclaimed by prune-on-next-`add`.
- `$WORKTREE_OWNED = false` paths preserve every current guard (Phase 0.55 staleness halt).

## Testing

Extend `tests/run.sh`:
- `review-worktree add` against a fixture repo: asserts the worktree exists, is detached at
  the expected SHA, and `rev-parse HEAD` matches.
- SHA-mismatch path: `add` with a wrong `expectedHeadSha` exits non-zero and creates
  nothing.
- `remove` idempotency: remove an existing worktree, then remove again → exit 0 both times.
- Prune-on-next-`add`: a pre-seeded stale worktree is reclaimed.
- Executable bit present on `bin/review-worktree`.
- Manifest/convention checks (LF endings, indentation, final newline) — existing harness.

## Files touched

- **New:** `plugins/code-review-suite/bin/review-worktree` (executable).
- **Edit:** `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — `repoDir` arg fix,
  Phase -0.5, Phase 0.55 gating, teardown.
- **Edit:** `plugins/code-review-suite/tests/run.sh` — helper tests.
- **Edit:** `README.md` — note the new `bin/` tool and `--no-worktree` / `Worktree:` flags.
- **Follow-on (private `~/.claude`):** `commands/shakedown.md` passes the `Worktree:` line.
