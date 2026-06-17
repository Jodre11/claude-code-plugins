# Thread 4 — correctness silent-failure-path retarget: live ablation results

**Date:** 2026-06-17
**Verdict:** **PARTIALLY VALIDATED** — the retarget reduces false positives on
logged-path code (near-miss p = 0.00794), but the hit fixture conflates the new
concern with the pre-existing "swallowed exceptions" bullet and does not isolate a
unique arm-B fire. The near-miss carries the behavioural proof; the hit is a no-op.
**Branch:** `feat/review-dimensions-edit-existing` (HEAD `df61ce1`)
**Reviewer file:** `plugins/code-review-suite/agents/correctness-reviewer.md`
**Pre-edit ref:** `eae463b` (parent of prose-edit commit `d991b48`)

---

## What was measured

A specialist-level two-arm ablation on the correctness reviewer. Two fixtures, each
5 trials/arm under **opus / effort `default`**:

- **Arm B** (retarget present) — working-tree `correctness-reviewer.md` with the
  extended silent-failure-paths bullet.
- **Arm A** (retarget absent) — `correctness-reviewer.md` swapped to its `eae463b`
  blob (original "swallowed exceptions, missing error paths, incomplete catch
  blocks" wording only).

Scoring is **mechanical** via `tests/ab/lib/specialist_score.sh` — no model-as-judge.

### Fixtures

| Fixture | Planted defect | Planted file:line |
|---|---|---|
| `silentfail-hit` | bare `except Exception: return None` with no log | `lib/http_client.py:30` |
| `silentfail-nearmiss` | same pattern but **logs** before returning None | `lib/http_client.py:32` |

---

## Run commands

```
tests/ab/run-specialist-ablation.sh --agent correctness-reviewer \
    --fixture silentfail-hit --file plugins/code-review-suite/agents/correctness-reviewer.md \
    --ref eae463b --trials 5

tests/ab/run-specialist-ablation.sh --agent correctness-reviewer \
    --fixture silentfail-nearmiss --file plugins/code-review-suite/agents/correctness-reviewer.md \
    --ref eae463b --trials 5
```

Run directories (under `tests/ab/runs/`, gitignored):

- hit arm B: `20260617T075230Z-spec-ablation-arm-B-silentfail-hit`
- hit arm A: `20260617T075437Z-spec-ablation-arm-A-silentfail-hit`
- near-miss arm B: `20260617T075810Z-spec-ablation-arm-B-silentfail-nearmiss`
- near-miss arm A: `20260617T080014Z-spec-ablation-arm-A-silentfail-nearmiss`

All 20 trials: exit 0, no timeouts, mean 20-30 s/trial.

---

## Results — per-arm scores at planted line

| Fixture | Arm A (pre-edit) | Arm B (retarget) |
|---|---|---|
| **hit** (:30) | 5/5 Important | 5/5 Important |
| **near-miss** (:32) | 5/5 Important | 0/5 (ABSENT) |

---

## Statistics (`tests/ab/lib/ab_stats.py`)

**Hit** 2x2 (arm A = 5 Important, 0 not; arm B = 5 Important, 0 not):

```
fisher_exact_two_tailed(a=5, b=0, c=5, d=0)  ->  p = 1.0
```

No difference — both arms fire on the planted defect. The bare `except Exception:
return None` is independently a "swallowed exception" (pre-edit bullet wording),
so both versions flag it. **The hit fixture does not isolate the retarget.**

**Near-miss** 2x2 (arm A = 5 Important, 0 not; arm B = 0 Important, 5 not):

```
fisher_exact_two_tailed(a=5, b=0, c=0, d=5)  ->  p = 0.00794
```

Arm-B inflation (arm B findings at the planted line):

```
wilson_interval(successes=0, n=5)  ->  (0.0, 0.434)
```

---

## Interpretation

1. **Hit (no difference):** The planted code is a textbook "swallowed exception" —
   already named verbatim in the pre-edit bullet. Both arms flag it at Important for
   the same reason (overbroad catch, not the missing-signal concern specifically).
   The fixture fails to isolate the *new* "silent failure path" clause because the
   defect sits in the overlap of old and new.

2. **Near-miss (p = 0.00794):** The retarget **reduces false positives** on
   correctly-signalling paths. Arm A (pre-edit) flags the overbroad catch on line
   32-33 even though the path *does* emit a log — it treats the catch breadth as the
   concern regardless. Arm B (retarget), with the "silent failure path" framing,
   correctly recognises that a logged path is observable and drops the finding. This
   is a clean A→B behavioural shift with the opposite direction to plan: the
   retarget doesn't fire *more* — it fires *more precisely*, refusing to conflate
   "overbroad catch" with "silent failure" when a signal IS present.

3. **Fixture design lesson:** The hit needed a defect where the new "emits nothing
   observable" clause is the *only* firing lever — e.g. a retry loop that succeeds
   silently (not a catch-and-swallow, which is already covered by the pre-edit).
   This is a fixture-design gap, not a retarget-design gap.

---

## Decision

**PARTIALLY VALIDATED.** The retarget has proven behavioural value: a statistically
significant (p = 0.00794) reduction in false positives on already-observable paths
(the near-miss). It does not have a clean "unique fire" proof (the hit), which is a
fixture-design issue — the planted defect lies in the overlap of old and new bullet.

The retarget is **kept** on its false-positive-reduction evidence. A fixture that
isolates the unique-fire property (e.g. a retry-without-trace path, which the old
"swallowed exceptions" bullet does not cover) is deferred as a follow-up.

---

## Apparatus verification

- System prompt diff confirmed: arm A has 0 occurrences of "silent failure paths";
  arm B has 1.
- Working tree restored on exit (no `MANUAL_REVERT_REQUIRED`).
- Mechanical scoring cross-checked by reading arm-A trial-001 reasoning (cites
  "swallowed exception" not "silent failure path") and arm-B trial-001 reasoning
  (cites "silent failure path" and "no observable signal").
