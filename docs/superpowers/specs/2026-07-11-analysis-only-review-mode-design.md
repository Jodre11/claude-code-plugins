# Analysis-only review mode — design

**Date:** 2026-07-11
**Plugin:** `code-review-suite`
**Motivating blocker:** the panel-vs-classic A/B harness (spec
`2026-07-10-panel-classic-ab-design.md`) cannot measure merged PRs — the review
skill halts the entire pipeline on a `MERGED` PR before any specialist runs,
producing a "review halted" stub with no findings and no report body to diff.

## Context and motivation

The A/B harness runs `/review-gh-pr` against a corpus of **merged** PRs, relying on
the spec's stated no-post safety:

> `review-gh-pr/SKILL.md` §B.1 already refuses to submit a review to a `CLOSED` or
> `MERGED` PR — it renders the report to stdout and halts cleanly. So every corpus
> run auto-halts at the posting step with the report on stdout.

The first live capture run (classic arm, PR #98) **falsified this assumption**. The
run finished in 61 seconds with verdict `INCONCLUSIVE` and a stub body: "Review
halted — PR already merged." No specialists dispatched, no findings, no report.

**Root cause — an emergent short-circuit, not a coded halt.** The skill's §B.1
merged-PR gate is at **Stage 6** (SKILL.md:1449) and behaves correctly — it refuses
to *post* and renders the report to stdout. But the model, upon seeing `state:
MERGED` in the Stage 1 PR data, reasoned (verbatim from the run's stdout): "the
entire review-and-submit workflow has no actionable target — any verdict would be
refused" and halted at **Stage 1**, before dispatching any specialist. Nothing in
Stage 1 instructs that halt; it is emergent from the model rationalising that a
merged PR is not worth reviewing.

This breaks the A/B experiment at its foundation: the merged-PR corpus is the spec's
no-post safety mechanism, and it produces nothing to measure.

## Goal

Add an **`analysis_only`** orchestration mode: run the **full** review pipeline (all
specialists, cross-review, synthesis, sealed bundle, durable-log write) to
completion, but **render the report to stdout instead of posting to GitHub**,
**regardless of PR state**. This gives the A/B harness a real full-review artefact to
harvest on merged PRs, and gives interactive users a retrospective-analysis
affordance the §B.1 halt message already gestures at.

## Non-goals (scope fence)

- **No change to `workflows/review-core.mjs`.** The Workflow core does not post — the
  host skill does. All posting-suppression edits are host-side.
- **No change to specialists, synthesiser, or the sealed-bundle contract**
  (`{verdict, bodyText, comments[]}`).
- **No Phase 0 narrative-bar or CI-green bypass.** Those gates still halt cleanly if
  they fire. `analysis_only` defeats only the emergent MERGED short-circuit and
  suppresses posting; it does not force a report on an arbitrary PR. The operator
  picks corpus PRs that were merged with a narrative body and green CI (the normal
  case for a real merged PR).
- **No default behaviour change.** `analysis_only` defaults `false`; when the key is
  absent, production review behaviour is byte-unchanged.

## Architecture — two seams

The fix has two independent seams, because the failure spans two stages:

1. **Defeat the early short-circuit** (Stage 1) — an explicit instruction that, under
   `analysis_only`, a `CLOSED`/`MERGED` state MUST NOT halt the pipeline. This
   directly counters the model's emergent "a merged PR isn't worth reviewing"
   rationalisation by naming and forbidding it.
2. **Guarantee no-post** (Stage 6 + Phase 0.4) — at every GitHub-write site, suppress
   the write and render to stdout instead, independent of PR state.

### The byte-synced constraint (load-bearing)

The pipeline body from `Follow these instructions exactly. Do not skip steps or
reorder.` (SKILL.md:123) through `Present the synthesiser's formatted report to the
user.` (SKILL.md:1126) is **byte-synced verbatim across three files**:

- `includes/review-pipeline.md` — canonical source
- `skills/review-gh-pr/SKILL.md` — consumer
- `commands/pre-review.md` — consumer

`tests/lib/test_sync_notes.sh::test_sync_pipeline_inline_matches_canonical` extracts
that range from the canonical and asserts both consumers contain it verbatim; any
drift fails CI. Edits therefore fall on two sides of this boundary:

- **Config resolution** (SKILL.md:1035, the existing `orchestration.review_mode` /
  `panel_size` block) sits **inside** the synced range → the new key's resolution
  must land in the canonical include **and** both consumers, byte-identical.
- **Stage 1 gather** (SKILL.md:15) and **Stage 6 posting** (SKILL.md:1351) sit
  **outside** the synced range and are **SKILL.md-only** (`pre-review.md` reviews
  local changes, has no PR-state Stage 1 and no `gh pr review` posting stage) → the
  short-circuit-defeat and posting-suppression edits touch only SKILL.md.

## Components / edits

| Edit | File(s) | Location vs synced range | Responsibility |
|---|---|---|---|
| A — resolve `analysis_only` | `includes/review-pipeline.md` + `skills/review-gh-pr/SKILL.md` + `commands/pre-review.md` (byte-identical) | **inside** | Add `analysis_only` to the orchestration-resolution block; two-layer first-match-wins (repo `.claude/code-review.toml` then user-level `~/.claude/code-review.toml`); missing/malformed = not set; default `false`. Sets `$ANALYSIS_ONLY`. |
| B — defeat MERGED short-circuit | `skills/review-gh-pr/SKILL.md` (Stage 1) | **outside** (line ~15–89) | Explicit instruction: under `$ANALYSIS_ONLY = true`, a `CLOSED`/`MERGED` state MUST NOT halt — proceed through all stages to synthesis. State-based posting refusal is deferred to Stage 6. |
| C — suppress posting | `skills/review-gh-pr/SKILL.md` (Stage 6 + Phase 0.4) | **outside** (Stage 6 line ~1351; Phase 0.4) | Under `$ANALYSIS_ONLY = true`, every GitHub-write site renders to stdout instead of calling `gh pr review` / `gh api ...comments`: Stage 6 (skip Class A confirm, Class C inline posting, verdict submission — render `bundle.bodyText` + verdict + `bundle.comments[]` to stdout); Phase 0.4 thin-narrative placeholder (render the halt notice to stdout, post nothing). |

### Composition and orthogonality

`analysis_only` is orthogonal to `review_mode` (classic/panel) and `full_log` — all
resolve from the same two config layers and compose freely. The A/B harness runs
`review_mode ∈ {classic, panel}` × `analysis_only = true` × `full_log = true`.

### Durable-log harvest falls out for free

Because `analysis_only` runs the **full** pipeline including the Step 3.6 durable-log
write (gated on `full_log`, which the harness forces on), the log the harness harvests
is produced naturally. No extra wiring is needed for harvest.

## Harness activation

`tests/ab/lib/orchestration.sh::orchestration_apply_arm` already writes the temp
user-level `~/.claude/code-review.toml` `[orchestration]` block (backup + restore
trap). Add one line — `analysis_only = true` — to that heredoc. Every A/B arm then
runs full-pipeline-no-post automatically; no `run.sh` dispatcher or corpus change. The
existing backup/restore trap already covers the new key (it backs up and restores the
whole file).

## Testing

Shell suite (`tests/run.sh`):

- **Sync gate (extend `test_sync_notes.sh`):** assert the `analysis_only` resolution
  prose is byte-identical across all three synced copies (rides the existing
  pipeline-inline sync assertion — no new mechanism, just confirm the edit lands in
  the canonical and propagates).
- **Skill prose guards (grep-based):** confirm the Stage 1 short-circuit-defeat
  instruction and the Stage 6 + Phase 0.4 posting-suppression prose are present in
  `SKILL.md`.
- **Harness (extend `test_ab_orchestration.sh`):** assert `orchestration_apply_arm`
  writes `analysis_only = true` and that `orchestration_restore_arm` cleanly restores
  the pre-run state (round-trip, including the `MANUAL_REVERT_REQUIRED` marker path).
- **Not automated:** the actual full-run-no-post behaviour — verified organically by
  re-running the arm-tell capture on merged PR #98, which must now produce a real
  multi-finding report rendered to stdout (and a harvestable durable log), not a
  "review halted" stub.

## Deliverables

1. `analysis_only` config resolution added to all three byte-synced pipeline copies
   (Edit A).
2. Stage 1 short-circuit-defeat + Stage 6/Phase 0.4 posting-suppression in SKILL.md
   (Edits B, C).
3. Harness one-line activation in `orchestration.sh` + extended round-trip test.
4. Sync-gate + prose-guard tests; `tests/run.sh` green.

## Housekeeping

Per the standing repo rule, planning runs the freshness / dependency /
GitHub-Actions / runner check and proposes any stale-dependency work as a **separate
small PR landing first**, kept out of this feature PR.
