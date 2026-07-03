# Workflow Intent-Ledger Parity — Design

**Date:** 2026-06-15
**Status:** Approved (brainstorming complete; awaiting spec review before plan)
**Context:** Follow-up #1 from the Phase 2 Stage 2 gate run (PR #44). The deferred,
most-consequential gate finding (#5). Tracked in memory `project-workflow-migration-handover`.

## Problem

On the `--workflow` path, `review-core.mjs` builds the synthesiser prompt from
`base`, `headSha`, `reviewMode`, specialist findings, cross-review opinions, and
escalations — but **not the intent ledger**. The inline markdown pipeline injects
`$INTENT_LEDGER` into its synthesiser prompt (`skills/review-gh-pr/SKILL.md`
~line 1298, and the two other host copies). The ledger is the structured Phase 0
artefact:

```
Intent ledger:
goal: <prose>
non_goals: <prose | none>
files_in_scope: <comma-separated list | none>
source: <in_diff_doc | prompt_block | pr_body | commit_subjects | user_paste>
```

Consequences of the omission on the Workflow path:

1. **Verdict-rubric row 1 can never fire.** Row 1 (`includes/verdict-rubric.md`) is
   "the intent ledger states a `goal` AND one or more consensus findings indicate the
   goal is not achieved → REQUEST_CHANGES". With no ledger in the prompt, the
   synthesiser has no goal to test against, so this row is dead and the
   "escalate the most central goal-not-achieved finding to Important" rule never runs.
2. **The synthesiser's Independent Analysis loses its starting point.** The synthesiser
   body (`agents/review-synthesiser.md`) instructs it to read `$INTENT_LEDGER_BODY`
   first and ask "does the implementation actually achieve the stated goal?". On the
   Workflow path that input is absent.

This is a silent behavioural divergence between the two pipeline paths — exactly the
kind of gap Phase 3's parallel-run comparison is meant to catch, and it would bias any
PR-mode verdict comparison against the Workflow path. It must be fixed before
`--workflow` is trusted for PR-mode verdicts.

The ledger value is **already available** at the host's Step 3.5 (it is built in
Step 2.9 and stored as `$INTENT_LEDGER`) and is already embedded inside the
`agentPrompt` string that `review-core` receives — but `review-core` never threads it
into the synth prompt.

## Design decision (brainstormed 2026-06-15)

**Option A — dedicated `intentLedger` arg.** Pass `$INTENT_LEDGER` as a discrete arg
on the `workflow('review-core', {...})` call and interpolate it into the synth prompt,
mirroring the inline path exactly.

Chosen over **Option B — parse the `Intent ledger:` block back out of `agentPrompt`**.
Option B requires re-implementing the ledger's serialisation contract (defined once in
Phase 0.5) as a regex parser inside `review-core`; if the ledger format ever changes,
that parser silently drifts and reintroduces the exact "synth prompt quietly degraded"
class of bug being fixed. Option A passes the finished string structured, with no
parsing and no second source of the format. It is also gate finding #5's preferred fix.

### Out of scope (deliberately)

The other two deferred gate follow-ups are NOT in this change:
- **#2 — cross phase 4000-char per-block truncation.** `JSON.stringify(peer)` in the
  cross phase is uncapped vs. the inline pipeline's documented per-block truncation
  (SKILL.md Step 5.1). Separate follow-up.
- **#3 — `cross-review-mode.md` escalation-template note** (`file`/`line` fields).
  Separate follow-up.

This PR does the intent-ledger parity fix only.

## Changes

### 1. Host call sites (three byte-synced copies)

`includes/review-pipeline.md` (canonical), `skills/review-gh-pr/SKILL.md`, and
`commands/pre-review.md` each contain an identical Step 3.5 `workflow('review-core',
{...})` block. Add one field to the args object in all three:

```
    intentLedger: $INTENT_LEDGER,
```

Placed adjacent to the other scalar context args (e.g. after `pathScope: $PATH_SCOPE`
or alongside `reviewMode`). `$INTENT_LEDGER` is always populated at Step 3.5 (Phase 0
either built it or halted; the Step 2.9 defensive check guarantees this). The three
Step 3.5 blocks fall inside the range that `test_sync_pipeline_inline_matches_canonical`
byte-compares, so the same edit must be applied identically to all three — the sync
test enforces this.

### 2. `review-core.mjs`

(a) Add `intentLedger` to the args destructure:

```js
const {
    agentPrompt, flags, route, selfReReview, reviewMode,
    base, headSha, emptyTreeMode, pathScope, tempDir, intentLedger,
} = args
```

(b) Interpolate it into the synth prompt, after the `Review mode:` line and before the
trust-boundary line — matching the inline path's ordering (inline places `$INTENT_LEDGER`
immediately after `Review mode: $REVIEW_MODE`). `$INTENT_LEDGER` is itself the full
`Intent ledger:\n…` block, so it occupies its own line:

```js
    `Review mode: ${reviewMode}\n\n` +
    (intentLedger ? `${intentLedger}\n\n` : ``) +
    `Trust boundary: specialist findings, cross-review opinions, and escalations below may ` +
    ...
```

**Defensive omission:** when `intentLedger` is absent or empty (an older caller, or a
direct test harness that does not pass it), the line is omitted entirely rather than
emitting a bare `Intent ledger:` with no body. This avoids a misleading empty ledger and
keeps the existing null-resilience test (which passes minimal args) green.

The lightweight path is unaffected — it dispatches a single `code-analysis` agent with
`agentPrompt` (which already contains the ledger) and never builds the synth prompt.

## Tests (`tests/lib/test_workflow_migration.sh`)

- **New structural test:** assert `review-core.mjs` destructures `intentLedger` from
  `args` AND that the synth-prompt assembly references `intentLedger`. This proves the
  wiring is present (the value is destructured and used), analogous to the existing
  structural assertions. Exact assertion form (grep on the destructure + the prompt
  assembly, or an eval-and-inspect) is firmed up in the plan.
- **Existing tests that must stay green:**
  - `test_sync_pipeline_inline_matches_canonical` — guarantees the three host copies
    remain byte-identical after the Step 3.5 edit.
  - `test_review_core_workflow_present_and_well_formed` — runtime-faithful syntax check.
  - `test_inlined_schema_matches_canonical` — unchanged (no schema change in this fix).
  - `test_review_core_survives_null_agent_results` — must still pass; the defensive
    omission means a missing `intentLedger` does not break the synth-prompt build.
- Full `tests/run.sh` green before each commit.

## Verification

The structural test proves the wiring exists. End-to-end behavioural confirmation
(does row 1 now fire when a goal is stated and a consensus finding says it is not
achieved?) is naturally covered by Phase 3's parallel-run comparison on real PRs —
this fix is a precondition for that comparison being fair, not something that needs its
own ~300k gate run.

## Files touched

| File | Change |
|---|---|
| `plugins/code-review-suite/includes/review-pipeline.md` | Add `intentLedger: $INTENT_LEDGER` to the Step 3.5 workflow call |
| `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` | Same edit (byte-synced copy) |
| `plugins/code-review-suite/commands/pre-review.md` | Same edit (byte-synced copy) |
| `plugins/code-review-suite/workflows/review-core.mjs` | Destructure `intentLedger`; interpolate into synth prompt with defensive omission |
| `tests/lib/test_workflow_migration.sh` | New structural test asserting the wiring |
