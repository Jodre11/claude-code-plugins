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
resolution, triggered in Step 1. **This is orchestrator-only** — Step 1 runs in the main
session (no `agent_type`), so the fetch is permitted. It must land in **pipeline-only prose,
placed *after* the `Store as $BASE` line** — never inside the numbered items 1–4, which are
byte-synced with `specialist-context.md` (see §2d) and therefore may not carry an
orchestrator-only fetch a reviewer would be forbidden to run.

**b) Local mode (`pre-review`).** No PR, no origin base to pin. Keep existing bare-name
resolution. **The correct base for pre-review (local `main` vs `origin/main`) is an open
question, explicitly deferred — see Open Questions.**

**c) EMPTY_TREE mode.** Untouched. When `$BASE = EMPTY_TREE` there is no origin base; two-arg
diff stays as-is. Pin logic engages only when a real PR base exists.

**d) The mirrored resolvers.** Base resolution is duplicated across three files, but only
**two** independently *resolve* a base; the third is a pure prompt consumer:
- `includes/review-pipeline.md` Step 1 (mirrored into `SKILL.md`, ~L752 "Step 1: Determine
  base branch") — the **orchestrator** resolver.
- `includes/specialist-context.md` "Determine base branch" (~L41) — the **standalone
  specialist** resolver. Items 1–4 are byte-identical to the pipeline's, enforced by
  `test_sync_base_branch_steps_match` (which extracts only items `[1-4]` between
  `Try these in order:`/`1. If ...` and the `Store as` line — anything after `Store as $BASE`
  is *not* byte-synced).
- `agents/review-synthesiser.md` Context Gathering (~L55) — **not a resolver.** It extracts
  the base *only* from the `Base branch:` prompt line (its own sync note at ~L51 records that
  "the extraction mechanism differs"). It has no `gh pr view` branch to modify.

Changes:
- **Orchestrator → all subagents (the primary path):** the orchestrator pins `$BASE` to the
  SHA (§1, or §2a on the `--no-worktree` path) and passes `Base branch: $BASE` (now a SHA,
  `SKILL.md:922`) in the specialist and synthesiser prompts. Every subagent reading the prompt
  gets the pinned SHA for free — their diff commands are unchanged, and the synthesiser needs
  no change at all (it only ever consumes the prompt line). **In normal operation this is the
  only path that matters** — subagents are always dispatched with a pinned `Base branch:`.
- **Standalone specialist runs (degraded, read-only):** a specialist invoked directly against
  a live PR (no orchestrator, no `Base branch:` SHA in its prompt) hits item 2
  (`gh pr view --json baseRefName`). `gh pr view` is a **read** and is permitted for reviewers;
  `git fetch` is **not** — `is_mutating_git` (`~/.claude/hooks/_lib.sh:77`) classifies `fetch`
  as mutating and the read-only reviewer guard (`allow-permissions.sh:32-34`) denies it for
  every `*-reviewer` / `code-analysis` / `review-synthesiser`. So the standalone path
  **cannot fetch.** Instead, in `specialist-context.md` prose *after* the `Store as $BASE` line
  (outside the byte-synced items 1–4): additionally read `baseRefOid`
  (`gh pr view --json baseRefOid`), and **if that SHA is already present in the local object
  store** (`git cat-file -e <oid>` succeeds — normally true, the base is an ancestor already
  fetched), pin `$BASE` to it; **otherwise keep the bare `baseRefName` and log a warning** that
  the base could not be origin-pinned (fetch would be a read-only-mandate violation). This is
  strictly better than today's unconditional bare name, needs no fetch, and never touches the
  byte-synced block.

The net structural effect: the byte-synced items 1–4 are **unchanged**, so
`test_sync_base_branch_steps_match` stays green without touching its matcher. The new logic
lives entirely in pipeline-only prose (§2a) and specialist-only prose (this item), each after
the `Store as $BASE` seam.

### 3. Diff syntax

Unchanged — three-dot when `$EMPTY_TREE_MODE = false` (now with a SHA base), two-arg when
true. This matches GitHub's Files-changed tab and absorbs base-branch drift via the
merge-base.

## Testing

- **Byte-sync invariant stays green untouched:** the new pin logic lives *after* the
  `Store as $BASE` seam in each file, so the items 1–4 that
  `test_sync_base_branch_steps_match` compares are unchanged — the test passes with no matcher
  change. This is deliberate: the orchestrator (fetch-capable) and the standalone specialist
  (fetch-forbidden) need *different* prose after the seam, which the byte-synced block could
  not express. (This suite has caught real sync drift before — see memory
  `project_structural_tests_handoff`.)
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
