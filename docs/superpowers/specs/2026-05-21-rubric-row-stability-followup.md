# Rubric row 2 stability — follow-up investigation

> **Status:** Open. Surfaced empirically by the A/B harness Phase 1 baseline run
> on 2026-05-21 (commit `2439356`, run dir
> `tests/ab/runs/20260521T152557Z-baseline/`). Three trials of identical input
> produced two different verdicts.
>
> **Not blocking:** the A/B harness ships as designed. This is a downstream
> question about the synthesiser's verdict-mapping layer.

## The observation

Three baseline trials, identical input (PR #29 review against the
production code-review-suite, `model: opus`, `effort: max`, `ultrathink` on),
produced:

| Trial | Wall-clock | Verdict          | Rubric row | Top finding confidence |
|-------|-----------:|------------------|-----------:|-----------------------:|
| 1     | 1267s      | APPROVE          | 4          | 82 (Important)         |
| 2     | 1516s      | APPROVE          | 4          | 95 (reclassified down) |
| 3     |  924s      | REQUEST_CHANGES  | 3 *(was 2)*| 88 (Important)         |

In all three trials the **top finding is the same line**:
`tests/lib/test_sync_notes.sh:1036` — a stale "Class B downgrade" failure
message contradicting the elision contract the PR was intended to ship.

Confidence assigned by the specialists is broadly stable in the 80-95
range. **The verdict swing is happening at the synthesiser's rubric-mapping
step**, not at the specialist or cross-review tier.

> Note: trial 3's stdout records "Rubric row: 3" rather than 2; the rubric
> row label is itself part of the variance. What matters here is the verdict
> outcome (APPROVE vs REQUEST_CHANGES) flipping on the same finding.

## What the synthesiser actually did

**Trial 1** verdict reasoning (verbatim):
> APPROVE (rubric row 4 — no Critical, **no Important ≥70 indicating goal not
> achieved**). Both Important findings are test-suite hygiene and have no
> runtime impact on the changes that ship.

The Important findings (Conf 82 and 88) **survive** at Important severity
but the synthesiser overrides the rubric trigger by adding an unwritten
predicate: *"Important AND goal-not-achieved"*.

**Trial 2** verdict reasoning (verbatim):
> APPROVE (rubric row 4) … no Important findings at confidence ≥ 70 after
> reclassification; intent ledger goals achieved.

Trial 2 went further — it **reclassified the same Important findings down
to Suggestion-tier** before the rubric ever evaluated them. The note
"after reclassification" is the synthesiser admitting it edited the
specialist tier-assignments.

**Trial 3** verdict reasoning (verbatim):
> REQUEST_CHANGES … Finding #1 — Stale "Class B downgrade" failure message
> at tests/lib/test_sync_notes.sh:1036 (Conf 88, Important). Plan Change 2D
> was partially executed: line 1030's failure message was correctly updated
> but the symmetric line-1036 message in the same function still references
> the deleted "Class B downgrade" route.

Trial 3 read the **same** finding as **goal-not-achieved** because Plan
Change 2D was (in its judgment) only partially executed — the elision
contract was not fully enforced. Different framing of the same data.

## Where the load-bearing judgment lives

The synthesiser's verdict rubric (canonical at
`plugins/code-review-suite/includes/verdict-rubric.md`) row 2 is:

> Important consensus finding ≥70 confidence indicating **the PR's stated
> goal was not achieved**.

The "stated goal not achieved" predicate has three layers of subjective
interpretation:

1. **What is the PR's stated goal?** Read from the intent ledger — but the
   ledger compresses goal text into bullets, and the synthesiser must
   reconstruct intent.
2. **Does this finding indicate the goal was not achieved, or merely
   surfaced a hygiene issue alongside the achieved goal?** This is the
   coin-flip in the data above. `test_sync_notes.sh:1036` describes the
   contract this PR was sent to ship; whether a stale contract message
   counts as "goal not achieved" or "tests passed despite stale prose"
   is a judgment call.
3. **Is the synthesiser allowed to reclassify Important → Suggestion before
   the rubric runs?** Trial 2 says yes. Trials 1 and 3 keep the original
   tier and apply the predicate directly.

All three trials are internally consistent. They disagree about which
predicate to apply.

## Why this matters

- **Reproducibility.** A code review tool whose verdict flips on
  identical input is hard to trust at the verdict layer (the inline-comments
  layer is more stable — see "What the data shows is stable" below).
- **Rubric drift.** The "goal not achieved" predicate is doing all the
  load-bearing work. Two of three trials use a tightened predicate
  ("Important AND goal-not-achieved") that the rubric doesn't actually
  spell out.
- **Tier drift.** Trial 2's down-reclassification step is even less
  documented. The rubric does not currently authorise Important → Suggestion
  rewrites by the synthesiser; if it's happening, that's an unwritten contract.

## What the data shows is stable

- **The set of underlying issues** — every trial surfaced
  `test_sync_notes.sh:1036`, the redundant threshold block in
  `test_deletion_detection.sh`, and the `_max_contiguous_deletions_w`
  comment / monolithic awk concerns.
- **Specialist confidence** — 80-95 across trials for the top finding.
- **The fact that something matters about line 1036** — the synthesiser
  agrees, even when downgrading.

What's volatile is the verdict, not the diagnosis.

## Phase 2 follow-up — what to investigate

These are open questions, not a plan. The A/B harness is the right tool
to answer them, once Phase 2 corpus YAML lands.

1. **Pin down whether Important → Suggestion reclassification is
   sanctioned.** Read the verdict-rubric and the synthesiser agent prompt;
   either authorise the reclassification explicitly (with criteria) or
   forbid it. Trial 2's behaviour is currently untracked.
2. **Tighten or remove the "goal not achieved" predicate.** Options worth
   weighing:
    - Drop it: any Important finding ≥70 → REQUEST_CHANGES (high-recall,
      low-precision).
    - Sharpen it: define "goal not achieved" via intent-ledger
      cross-reference (Important finding directly contradicts a ledger
      goal bullet → REQUEST_CHANGES).
    - Replace it with a separate severity tier "Important-but-not-blocking"
      that the synthesiser is explicitly authorised to assign.
3. **Run an A/B trial with the new rubric** against ≥10 trials per arm to
   measure verdict-flip rate before and after. Phase 1's 3-trial sample is
   not statistically meaningful for stability claims — it only suffices to
   demonstrate the variance exists.
4. **Check whether `effort=max` and `ultrathink` actually improve verdict
   stability.** Phase 1's ultrathink experiment will inform this.

## Where the durable record lives

- **Run dir:** `tests/ab/runs/20260521T152557Z-baseline/` (preserved by
  `.gitignore`'s exclusion of `tests/ab/runs/`; copy out if you want to
  retain across cleanups).
- **Per-trial reports:** `trial-NNN/synthesiser-report.md` for the
  full text; `trial-NNN/stdout.log` for the raw orchestrator output.
- **Top-finding identity:** every trial cites `test_sync_notes.sh:1036`.
  A future PR that fixes that one line and re-runs the harness should
  see all three baseline trials converge on APPROVE.

## Filing convention

This is not a Phase 1 deliverable. Filed as a `*-followup.md` rather than
a `*-design.md` to mark it for later prioritisation. Promote to a design
doc + plan when the team commits to the work.
