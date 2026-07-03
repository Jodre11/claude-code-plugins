# Correctness unique-fire fixture — live ablation results

**Date:** 2026-06-17
**Verdict:** **VALIDATED** — the new `silentfail-unique-hit` fixture isolates a clean
unique-fire contrast for the correctness silent-failure-path retarget. Fisher
p = 0.00071 at n=10/arm.
**Branch:** `feat/correctness-unique-fire-fixture`
**Reviewer file:** `plugins/code-review-suite/agents/correctness-reviewer.md`
**Pre-edit ref (arm A):** `eae463b`
**Fixture suite_sha:** `a07ab82`

---

## Why this fixture exists

PR #53's thread-4 ablation (`2026-06-17-thread4-silentfail-ablation.md`) found the
original `silentfail-hit` could not isolate the retarget: its planted defect (a bare
`except Exception: return None`) sits in the OVERLAP of the pre-edit "swallowed
exceptions" bullet and the new "silent failure path" clause, so both arms fired
Important (Fisher p = 1.0). The retarget's value rested solely on the near-miss
false-positive reduction (p = 0.00794). This follow-up adds a second hit whose planted
defect exercises ONLY the new clause.

## The defect that works (and three that did not)

The validated fixture plants a **fallback-returns-default with no signal**:
`resolve_tenant_rate_limit` returns `DEFAULT_RATE_LIMIT` when the API response omits
`rate_limit`, with nothing logged. This is legitimate, non-buggy control flow — no
exception, no `None` return, no missing error path — so the pre-edit bullets have
minimal purchase, while it matches the new clause's wording verbatim ("a fallback that
returns a default without signalling").

Three earlier shapes failed shape-confirm and informed the final design:

1. **Retry-exhausted-returns-None** (`await_dispatch` polls then `return None`). Confirm
   round 1: arm A ABSENT, arm B Important (looked clean). Confirm round 2 (after an
   unrelated tightening): arm A fired Important at the byte-identical line-38 code. The
   "returns None on a give-up branch" concern is reachable by the pre-edit "missing error
   paths" bullet — an overlap, not a unique fire.
2. **Fallback-default WITH a confound.** A `get_global_rate_limit()` helper plus a
   docstring saying "global default" while the code returned a hardcoded constant. Both
   arms locked onto that comment/behaviour mismatch (an agent-hazard) as Important,
   masking the silent-fallback signal. Arm B rated the intended concern only Suggestion.
   This produced a *premature* negative conclusion that was an artefact of the confound,
   not the retarget.
3. **(2) with the confound stripped** is the validated fixture below.

**Lesson:** an Important-grade silent failure with any error/exception/give-up dimension
overlaps the pre-edit "swallowed exceptions / missing error paths" bullets. The unique
fire requires a defect that is otherwise-legitimate control flow whose ONLY fault is the
missing signal. Confounds (stray agent-hazard bait like a docstring/behaviour mismatch)
must be scrubbed or they dominate the score.

---

## Run commands

```
tests/ab/run-specialist-ablation.sh --agent correctness-reviewer \
    --fixture silentfail-unique-hit \
    --file plugins/code-review-suite/agents/correctness-reviewer.md \
    --ref eae463b --trials 5    # run twice → n=10/arm pooled
```

Run directories (under `tests/ab/runs/`, gitignored):

- batch 1 arm B: `20260617T144953Z-spec-ablation-arm-B-silentfail-unique-hit`
- batch 1 arm A: `20260617T145313Z-spec-ablation-arm-A-silentfail-unique-hit`
- batch 2 arm B: `20260617T150529Z-spec-ablation-arm-B-silentfail-unique-hit`
- batch 2 arm A: `20260617T150816Z-spec-ablation-arm-A-silentfail-unique-hit`

All 20 trials: exit 0, no timeouts.

---

## Results — severity at planted line 21

| Batch | Arm A (pre-edit) | Arm B (retarget) |
|---|---|---|
| 1 (n=5) | 1 Important, 1 Suggestion, 3 ABSENT → 1/5 Important | 5/5 Important |
| 2 (n=5) | 4 ABSENT, 1 Important → 1/5 Important | 5/5 Important |
| **pooled (n=10)** | **2/10 Important** | **10/10 Important** |

## Statistics (`tests/ab/lib/ab_stats.py`)

Pooled 2x2 (arm A = 2 Important, 8 not; arm B = 10 Important, 0 not):

```
fisher_exact_two_tailed(a=2, b=8, c=10, d=0)  ->  p = 0.00071
wilson_interval(10, 10)  ->  (0.722, 1.0)    # arm B Important rate
wilson_interval(2, 10)   ->  (0.057, 0.510)  # arm A Important rate
```

Batch 1 alone was marginal (p = 0.0476, arm A 1/5). The second batch held arm A's leak
at ~20%, driving the pooled p to 0.00071.

---

## Interpretation

The retarget is a **reliability extension**, not a categorical one. The silent-fallback
concern IS reachable from the pre-edit prompt (~20% of trials, Wilson CI [0.06, 0.51]),
but always WITHOUT the new clause's framing — arm A's two Important fires reasoned about
"cannot distinguish no-override from resolution-failed", not "fallback without signal".
The retarget makes detection deterministic (10/10) AND consistently framed. This is a
statistically decisive (p = 0.00071) unique-fire contrast — the clean hit the original
`silentfail-hit` could not provide.

The original `silentfail-hit` is RETAINED (it still validates arm B fires on the
catch-and-swallow shape); this is a SECOND hit that adds the unique-fire proof.

## Apparatus verification

- System-prompt diff confirmed each round: arm A blob (`eae463b`) has 0 occurrences of
  "silent failure paths"; working-tree arm B has 1.
- Working tree restored on every exit (no `MANUAL_REVERT_REQUIRED`).
- Mechanical scoring via `tests/ab/lib/specialist_score.sh` at planted line 21; arm A's
  two Important fires (batch1 trial-003, batch2 trial-005) hand-read to confirm they are
  genuine pre-edit-bullet fires, not scorer artefacts.
