# Thread 1 — reuse triviality-bifurcation retarget: live ablation results

**Date:** 2026-06-17
**Verdict:** **PARTIALLY VALIDATED** — the retarget significantly de-escalates
trivial duplication (near-miss Important→Suggestion, p = 0.00794) and keeps flagging
non-trivial canonical reimplementation with no regression (hit). It does not fully
suppress trivial dup to ABSENT as planned — it down-weights one tier instead.
**Branch:** `feat/review-dimensions-edit-existing` (HEAD `df61ce1`)
**Reviewer file:** `plugins/code-review-suite/agents/reuse-reviewer.md`
**Pre-edit ref:** `0700d6f` (parent of prose-edit commit `429eac0`)

---

## What was measured

A specialist-level two-arm ablation on the reuse reviewer. Two fixtures, 5
trials/arm under **opus / effort `default`**:

- **Arm B** (retarget present) — working-tree `reuse-reviewer.md` with the
  blast-radius/cold-start rationale + triviality-bifurcation Rule.
- **Arm A** (retarget absent) — `reuse-reviewer.md` swapped to its `0700d6f` blob
  (maintenance-burden rationale, no triviality Rule).

Mechanical scoring via `tests/ab/lib/specialist_score.sh`.

### Fixtures

| Fixture | Planted duplication | Source.yaml line | Actually-cited line |
|---|---|---|---|
| `reuse-hit` | 15-line branching `format_currency` reimplemented in `invoice.py` | `:21` | `:18` (or `18-27`) |
| `reuse-nearmiss` | 1-line `slugify` reimplemented in `reports.py` | `:6` | `:6` |

---

## Run commands

```
tests/ab/run-specialist-ablation.sh --agent reuse-reviewer \
    --fixture reuse-nearmiss --file plugins/code-review-suite/agents/reuse-reviewer.md \
    --ref 0700d6f --trials 5

tests/ab/run-specialist-ablation.sh --agent reuse-reviewer \
    --fixture reuse-hit --file plugins/code-review-suite/agents/reuse-reviewer.md \
    --ref 0700d6f --trials 5
```

Run directories (under `tests/ab/runs/`, gitignored):

- near-miss arm B: `20260617T080509Z-spec-ablation-arm-B-reuse-nearmiss`
- near-miss arm A: `20260617T080733Z-spec-ablation-arm-A-reuse-nearmiss`
- hit arm B: `20260617T081024Z-spec-ablation-arm-B-reuse-hit`
- hit arm A: `20260617T081309Z-spec-ablation-arm-A-reuse-hit`

All 20 trials: exit 0, no timeouts, mean 23-28 s/trial.

---

## Results — per-arm scores

**Near-miss** (the behavioural contrast), scored at planted `lib/reports.py:6`:

| Arm A (pre-edit) | Arm B (retarget) |
|---|---|
| 5/5 Important | 5/5 Suggestion |

**Hit** (no-regression check). Reviewers cite the reimplementation at `:18`, not the
planted `:21`; scored at the cited `lib/invoice.py:18`:

| Arm A (pre-edit) | Arm B (retarget) |
|---|---|
| 5/5 Important | 5/5 Important |

(Scored at the planted `:21`, both arms register mostly ABSENT — the citation/plant
mismatch, see Fixture notes. The behavioural reading is at the actually-cited line.)

---

## Statistics (`tests/ab/lib/ab_stats.py`)

**Near-miss** Important-count 2x2 (arm A = 5 Important, 0 not; arm B = 0 Important, 5 not):

```
fisher_exact_two_tailed(a=5, b=0, c=0, d=5)  ->  p = 0.00794
```

A clean, complete A→B severity de-escalation on the trivial duplication.

**Hit** (at `:18`): no difference — both arms 5/5 Important. The retarget does **not**
regress the kept case: non-trivial canonical reimplementation is still flagged.

---

## Interpretation

1. **Near-miss (p = 0.00794):** The retarget recognises the triviality of a 1-line
   `slugify` dup and **de-escalates Important → Suggestion** in every trial. Arm B's
   reasoning explicitly engages the triviality framing ("Although the body is short,
   this is reimplementation of a dedicated, named utility..."). The behavioural shift
   is real and statistically significant — but it lands at Suggestion, not the
   planned ABSENT. The model treats reuse of a **named, exported** helper as still
   worth a non-blocking note even when the body is trivial, declining to fully drop
   it. This is a defensible reading of the bifurcation Rule (which says drop trivial
   dup, but the existence of a dedicated `slugify` export is a signal of intent the
   model weighs).

2. **Hit (no regression):** Non-trivial canonical reimplementation (a 15-line
   branching `format_currency`) is flagged Important by both arms — the retarget does
   not weaken the kept case. The WATCH-ITEM from the handover (does the contrast hold
   from code, not a removed README breadcrumb?) is **confirmed**: arm-B reasoning
   cites the actual code duplication (`invoice.py:18-27` duplicates
   `utils/formatting.py:7-21`), not any leftover hint.

3. **Fixture-design notes (for follow-up, not blocking):**
   - **Hit planted line is off:** `source.yaml` plants `:21`, but reviewers
     consistently cite the reimplementation start at `:18` (or range `18-27`). The
     plant should be `:18`. The behavioural result is unaffected once scored at the
     cited line, but the fixture's `planted.line` and `expect_arm_*` (Suggestion)
     don't match observed behaviour (Important).
   - **Both arms call the hit Important, not Suggestion** as the fixture predicted.
     The no-regression property (arms identical) holds regardless.

---

## Decision

**PARTIALLY VALIDATED.** The retarget delivers its core value — a statistically
significant (p = 0.00794) de-escalation of trivial duplication — and preserves the
non-trivial case with no regression. It de-escalates rather than fully suppresses
(Suggestion, not ABSENT) for named-exported-helper dups; whether that is the desired
endpoint is a prose-tuning question for the user, not an apparatus failure.

The retarget is **kept**. Two fixture-design follow-ups (correct the hit plant line
to `:18`; reconcile the near-miss expectation with the observed de-escalate-not-drop
behaviour) are deferred.

---

## Apparatus verification

- System-prompt swap confirmed by the harness (arm A = `0700d6f` blob, arm B =
  working tree).
- Working tree restored on every exit (no `MANUAL_REVERT_REQUIRED`).
- Mechanical scores cross-checked against arm-A and arm-B trial-001 reasoning.
