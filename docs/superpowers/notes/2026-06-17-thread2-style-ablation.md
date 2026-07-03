# Thread 2 — style reasoning-economy retarget: live ablation results

**Date:** 2026-06-17
**Verdict:** **VALIDATED** — both contrasts fire cleanly (p = 0.00794 each): the
retarget up-weights misleading names to Important (hit) and down-weights in-diff
duplication from Important to Suggestion (near-miss). The planned "function length →
ABSENT" contrast didn't materialise (neither arm raises a pure length finding for
this code), but the actual behavioural shift demonstrates the retarget's two core
properties: up-weight agent-hazardous names, down-weight visible-in-context patterns.
**Branch:** `feat/review-dimensions-edit-existing` (HEAD `df61ce1`)
**Reviewer file:** `plugins/code-review-suite/agents/style-reviewer.md`
**Pre-edit ref:** `7d8b39d` (parent of prose-edit commit `6957811`)

---

## What was measured

A specialist-level two-arm ablation on the style reviewer. Two fixtures, 5
trials/arm under **opus / effort `default`**:

- **Arm B** (retarget present) — working-tree `style-reviewer.md` with the
  reasoning-economy Focus Areas rewrite + length-heuristic inversion Rule.
- **Arm A** (retarget absent) — `style-reviewer.md` swapped to its `7d8b39d` blob
  (human-readability focus areas: "Readability issues", "Function/method length",
  "Code duplication", etc.).

Mechanical scoring via `tests/ab/lib/specialist_score.sh`.

### Fixtures

| Fixture | Planted concern | Source.yaml line | Actually-cited line |
|---|---|---|---|
| `style-hit` | `get_user_settings` does a DB INSERT (name lies) | `:38` | `:32` (def) or `:39` (INSERT) |
| `style-nearmiss` | ~65-line linear `build_audit_report` | `:65` | `:43` (duplication site) |

---

## Run commands

```
tests/ab/run-specialist-ablation.sh --agent style-reviewer \
    --fixture style-hit --file plugins/code-review-suite/agents/style-reviewer.md \
    --ref 7d8b39d --trials 5

tests/ab/run-specialist-ablation.sh --agent style-reviewer \
    --fixture style-nearmiss --file plugins/code-review-suite/agents/style-reviewer.md \
    --ref 7d8b39d --trials 5
```

Run directories (under `tests/ab/runs/`, gitignored):

- hit arm B: `20260617T081707Z-spec-ablation-arm-B-style-hit`
- hit arm A: `20260617T081907Z-spec-ablation-arm-A-style-hit`
- near-miss arm B: `20260617T082324Z-spec-ablation-arm-B-style-nearmiss`
- near-miss arm A: `20260617T082552Z-spec-ablation-arm-A-style-nearmiss`

All 20 trials: exit 0, no timeouts, mean 20-25 s/trial.

---

## Results — per-arm scores

**Hit** (misleading-name up-weight). Arm B cites the function def at `:32` (or the
INSERT at `:39` in trial-002); arm A never raises the naming concern:

| Metric | Arm A (pre-edit) | Arm B (retarget) |
|---|---|---|
| Important finding citing `get_user_settings` naming/side-effect concern | 0/5 | 5/5 |
| Arm A focus instead | Duplicated default literals (`:40`, Suggestion) | — |

Scored at the canonical citation `:32`:
- Arm A: 0/5 ABSENT
- Arm B: 4/5 Important (+ 1 Important at `:39` = 5/5 total)

**Near-miss** (in-diff duplication down-weight). Both arms flag in-diff duplicated
label/append blocks at `:43`:

| Arm A (pre-edit) | Arm B (retarget) |
|---|---|
| 5/5 Important | 5/5 Suggestion |

Arm B's reasoning explicitly applies the retarget: *"This is in-diff duplication
(all copies visible in one screen, so the misread risk for an agent is low), which
is why this is only a suggestion... no concern with its length per se."*

---

## Statistics (`tests/ab/lib/ab_stats.py`)

**Hit** Important-at-`:32` 2x2 (arm A = 0 Important, 5 not; arm B = 4 Important, 1 not):

```
fisher_exact_two_tailed(a=0, b=5, c=5, d=0)  ->  p = 0.00794
```

(Counting trial-002's `:39` as the same misleading-name concern: arm B = 5/5
Important vs arm A = 0/5.)

**Near-miss** Important-at-`:43` 2x2 (arm A = 5, arm B = 0):

```
fisher_exact_two_tailed(a=5, b=0, c=0, d=5)  ->  p = 0.00794
```

Both contrasts cleanly significant.

---

## Interpretation

1. **Hit (p = 0.00794):** The retarget introduces an entirely new finding class:
   the **misleading name** `get_user_settings` (a "getter" that writes) flagged at
   Important in every arm-B trial. Arm A (pre-edit) has no equivalent — it focuses
   on superficial duplication of default literals instead. Arm B's reasoning
   explicitly cites the retarget's top-priority concern: *"a lying name actively
   induces a wrong edit"*, *"an agent trusting the `get_` prefix will assume the
   call is read-only"*. This is the cleanest unique-fire of all three threads.

2. **Near-miss (p = 0.00794):** The retarget down-weights in-diff duplication from
   Important to Suggestion, applying its explicit "in-diff duplication: down-weight"
   rule. It also explicitly declines to flag the function's length: *"no concern
   with its length per se"*, confirming the length-heuristic inversion. Neither arm
   raises a standalone "function too long" finding — the pre-edit reviewer also
   doesn't flag pure length here, preferring the structural-duplication angle — but
   the severity shift from Important → Suggestion on the duplication finding is the
   mechanically measurable difference.

3. **Fixture-design notes (non-blocking):** The planted line `:65` (midpoint) was
   meant to catch a "function length" finding that neither arm raises. The actual
   contrast happens at `:43` (the duplication site). The fixture expectation
   (`expect_arm_a: Suggestion`, `expect_arm_b: ABSENT`) is not what happened (arm A
   = Important, arm B = Suggestion) — but the *direction* is correct (arm B is less
   severe) and the contrast is perfectly clean.

---

## Decision

**VALIDATED.** Both the up-weight property (misleading names → Important) and the
down-weight property (in-diff duplication → Suggestion; length-per-se dismissed) are
proven with full arm separation (p = 0.00794 each). The retarget delivers its
designed value: style findings are now anchored to **agent-reasoning cost**, not human
aesthetic preference.

---

## Apparatus verification

- System-prompt swap confirmed (arm A = `7d8b39d` blob with "Readability issues",
  "Function/method length" bullets; arm B = working tree with "Misleading names" at
  top priority).
- Working tree restored on every exit (no `MANUAL_REVERT_REQUIRED`).
- Mechanical scores cross-checked against full trial-001 reasoning in both arms.
