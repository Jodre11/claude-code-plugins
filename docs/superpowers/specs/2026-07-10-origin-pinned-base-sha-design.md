# Origin-pinned base SHA for PR reviews

**Date:** 2026-07-10
**Status:** Design — approved, pending spec sign-off
**Scope:** `code-review-suite` review pipeline base resolution

## Problem

A `/review-gh-pr` run measured a diff against the wrong base: 14 files when the PR
contained 7. Root cause, grounded in the pipeline code:

- **Phase -0.5** (`skills/review-gh-pr/SKILL.md:180-202`) cuts an isolated worktree at the
  PR **head** SHA, fetched and verified from origin. The head endpoint is origin-correct.
- **Step 1** (`SKILL.md:756-760`) resolves `$BASE` to a **bare branch name** (`baseRefName`
  → `main`), completely independently of Phase -0.5.
- **Step 2.2** (`SKILL.md:775`) then runs `git diff "$BASE"...HEAD` inside the worktree.

A git worktree shares the parent repo's **object store and ref namespace**. It does not have
its own refs. So the bare name `main` resolves to the **local** `main` ref — which the
pipeline never fetches. If local `main` diverges from origin (stale, or ahead in unrelated
merged commits), the three-dot diff computes against the wrong merge-base and manufactures a
phantom file delta.

### Why the worktree can't carry the base

A diff has two endpoints. A worktree is a checkout of exactly one commit:

- **Head endpoint** — the worktree embodies it (files on disk *are* the head). ✓
- **Base endpoint** — not a file tree at all. It is a *second commit* named in the diff.
  A checkout cannot embody it; `git diff "$BASE"...` must resolve `$BASE` as a ref lookup,
  and in a worktree that lookup reaches the shared (stale) local ref.

So the base must be pinned explicitly from origin. It cannot be inherited from the worktree.

### Why `origin/main` is also wrong

`git diff origin/main...HEAD` is *not* a robust fix: `origin/main` is a remote-**tracking**
ref that only advances on `git fetch`. An un-fetched tracking ref is just as stale as local
`main`. The only origin-authoritative, immutable-per-fetch base value is the PR's own
`baseRefOid` from the GitHub API.

## Principle

**Only origin is pertinent. Both diff endpoints must be origin-sourced SHAs — never a bare
ref name (local or remote-tracking).**

- Head = `headRefOid` (already pinned in Phase -0.5). ✓
- Base = `baseRefOid` — origin-authoritative, pinned once, fixed for the run. It changes only
  if the PR is remotely retargeted/rebased (which moves `headRefOid`, already detected by
  Phase 0.55).

Diffs stay **three-dot** (`git diff "$BASE"..."$HEAD_SHA"`). Three-dot resolves to the
merge-base, which is exactly what GitHub's "Files changed" tab shows. Two-dot against the
base *tip* would diverge from GitHub if origin's base branch advances after the PR opens.

## Why auto-fetch is safe here (and the head-side rule does not apply)

Phase 0.55.3 states "Do NOT auto-fetch — that is the user's call." That rule is about the
**head**: acting on a head fetch (checking it out) would pull unreviewed commits into the
working tree. The **base** is categorically different:

`git fetch origin <baseRef>` writes only to the object store, `FETCH_HEAD`, and the
remote-tracking ref. It **cannot** touch the working tree, the index, `HEAD`, the local
branch refs, or any worktree checkout — git refuses to move the checked-out branch on a plain
fetch. We never *check out* the base; we only name its SHA in a diff. So auto-fetching the
base is side-effect-free with respect to everything the reviewer analyses. **Auto-fetch, no
halt.**

## Design

### 1. Core change — pin the base in Phase -0.5

On the plugin-owned-worktree path (`SKILL.md:180-202`), alongside the existing head-SHA pin:

```bash
# after $EXPECTED_HEAD_SHA is resolved:
EXPECTED_BASE_SHA = gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json baseRefOid -q .baseRefOid
# validate ^[0-9a-f]{40}$ ; else halt "Phase -0.5 halt: could not resolve PR base SHA"
git -C "$REPO_DIR" fetch origin "$BASE_REF"     # objects only; never touches tree/HEAD/local main
$BASE = $EXPECTED_BASE_SHA                        # pin as a SHA for the whole pipeline
$BASE_PINNED = true
```

`$BASE_REF` is the base branch name from `baseRefName` (used only as the fetch refspec, never
fed to `git diff`). After this, `$BASE` is a validated 40-hex SHA. All downstream three-dot
diffs (`git diff "$BASE"..."$HEAD_SHA"`) are now origin-pinned on both endpoints; no diff can
resolve against a stale local `main`.

Announce the pinned base alongside the existing Phase -0.5 head announcement, e.g.
`> Phase -0.5: base pinned to $BASE (origin baseRefOid)`.

### 2. Fallback paths and propagation

**a) `$WORKTREE_OWNED = false` in PR mode** (`--no-worktree`, external worktree). Phase -0.5
pinning is skipped, so Step 1 must pin instead: when `$BASE_PINNED` is not already set and a
live PR exists, resolve `$BASE` from `baseRefOid` and `git fetch origin <baseRef>` — the same
resolution, triggered in Step 1.

**b) Local mode (`pre-review`).** No PR, no origin base to pin. Keep existing bare-name
resolution. **The correct base for pre-review (local `main` vs `origin/main`) is an open
question, explicitly deferred — see Open Questions.**

**c) EMPTY_TREE mode.** Untouched. When `$BASE = EMPTY_TREE` there is no origin base; two-arg
diff stays as-is. Pin logic engages only when a real PR base exists.

**d) The three mirrored resolvers.** Base resolution is deliberately duplicated across:
- `includes/review-pipeline.md` Step 1 (and `SKILL.md:756`),
- `includes/specialist-context.md:43` ("Determine base branch"),
- `agents/review-synthesiser.md` Context Gathering.

The structural test suite enforces "items 1–5 match across these files." Changes:
- **Orchestrator → specialists:** the orchestrator pins `$BASE` to the SHA and passes
  `Base branch: $BASE` (now a SHA, `SKILL.md:922`) in the specialist prompt. Specialists
  reading the prompt get the pinned SHA for free — their diff commands are unchanged.
- **Standalone runs:** add the same `baseRefOid`-pin-and-fetch to the `gh pr view` branch
  (item 2) in all three resolvers, so a standalone specialist/synthesiser against a live PR
  is also origin-correct. The same new step lands in all three, preserving the invariant.

### 3. Diff syntax

Unchanged — three-dot when `$EMPTY_TREE_MODE = false` (now with a SHA base), two-arg when
true. This matches GitHub's Files-changed tab and absorbs base-branch drift via the
merge-base.

## Testing

- **Three-way sync invariant:** adding the same pin step to all three resolvers keeps
  `tests/run.sh` green. Verify the sync-check regex still matches the new step; widen its
  matcher if needed (this suite has caught real sync drift before —
  see memory `project_structural_tests_handoff`).
- **Regression guard (the specific defect):** assert that on the PR/owned-worktree path the
  base fed to `git diff` is a 40-hex SHA, not a bare name — Phase -0.5 pins `baseRefOid` and
  Step 2.2 consumes `$BASE` as a validated SHA.
- **No behavioural A/B.** This is a correctness fix to diff inputs, not a model-tuning change;
  the gated-sweep apparatus does not apply.

## Open questions (deferred — out of scope for this fix)

1. **pre-review base choice.** Local mode reviews the uncommitted working tree, so its base
   arguably should be local `main` (what you branched from and merge back to). But a stale
   local `main` reintroduces the same phantom-file class of bug. Whether pre-review should
   diff against local `main`, `origin/main` (fetched), or the merge-base is its own decision.
   Deferred to a separate brainstorm.

## Non-goals

- Changing the head-side no-auto-fetch rule (Phase 0.55) — head fetching stays user-driven.
- Changing EMPTY_TREE or local-mode diff behaviour.
- Any refactor of the three-way base-resolution duplication beyond adding the pin step.
