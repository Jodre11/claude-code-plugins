# Task 7 — agent-hazard basis ablation: live trial results

**Date:** 2026-06-17
**Verdict:** **VALIDATED** — the agent-hazard basis fires on the hit (p = 0.00794)
and does not inflate the near-miss (0/5 arm-B false positives).
**Spec:** `docs/superpowers/specs/2026-06-16-agent-hazard-ab-trial-design.md`
**Plan:** `docs/superpowers/plans/2026-06-16-agent-hazard-ab-trial.md` (Task 7)
**Feasibility note (the honest caveat this discharges):**
`docs/superpowers/notes/2026-06-16-synth-feasibility.md`
**PR under test:** #52 (agent-hazard basis at the Important tier).

---

## What was measured

A matched-pair ablation at the review-synthesiser. Two fixtures, each run through
two arms:

- **Arm B** (basis present) — `agents/review-synthesiser.md` as shipped by PR #52.
- **Arm A** (basis absent) — the three PR #52 files reverted to their `0c89cf6`
  pre-PR blob; the load-bearing revert is the synthesiser agent body, fed as the
  system prompt via `--append-system-prompt-file`.

Both arms pin **opus** / effort `default` (`tests/ab/configs/per-agent/synthesiser-baseline.yaml`).
Only the basis text varies. Each trial scored **mechanically** by tier heading
(`tests/ab/lib/synth_score.sh`) on the planted finding at `lib/cache.py:42` — no
model-as-judge.

- **hit** fixture: a lying comment on *correct* code (the `move_to_end(key)` call
  in `put` is load-bearing for the re-insertion path; the comment falsely calls it
  "safe to drop"). Goal achieved → rubric row 1 does not fire, so the agent-hazard
  basis is the only lever that can keep it Important.
- **near-miss** fixture: an accurate-but-vague comment on the same correct code.
  Should stay Suggestion in both arms (guardrail: vague ≠ misleading).

## Run commands

```
tests/ab/run-ablation.sh --fixture synth-hazard-hit --trials 5
tests/ab/run-ablation.sh --fixture synth-hazard-nearmiss --trials 5
```

Run directories (under `tests/ab/runs/`, gitignored):

- hit arm B: `20260617T055408Z-ablation-arm-B-synth-hazard-hit`
- hit arm A: `20260617T055940Z-ablation-arm-A-synth-hazard-hit`
- near-miss arm B: `20260617T060515Z-ablation-arm-B-synth-hazard-nearmiss`
- near-miss arm A: `20260617T061021Z-ablation-arm-A-synth-hazard-nearmiss`

All 20 trials: exit 0, no timeouts, mean ~45-62 s/trial (the synthesiser is a
single agent, far faster than the end-to-end-mode banner estimate).

## Results — per-arm Important counts

Scored on the planted finding `lib/cache.py:42`; `Important` counts `Critical` too
(none observed).

| Fixture | Arm A (basis absent) | Arm B (basis present) |
|---|---|---|
| **hit** | 0 / 5 Important (all 5 Suggestion) | 5 / 5 Important |
| **near-miss** | 0 / 5 Important (all 5 Suggestion) | 0 / 5 Important (all 5 Suggestion) |

Every trial placed the planted finding under a tier heading in `## Consensus
Findings` (no procedural dismissals). Hand-verified by eye against the mechanical
scores; the qualitative reasoning matches the tier in every spot-checked report:

- **hit arm A** explicitly applies the single-runtime-defect bar and reclassifies
  Important → Suggestion: *"a misleading comment with no current observable
  misbehaviour does not meet the Important bar"* (citing `severity-definitions.md`).
- **hit arm B** escalates via the named basis: `Rubric row applied: 3`, *"the
  severity classification holds under the agent-hazard basis … capped at Important
  because there is no runtime defect today."*
- **near-miss arm B** considers the basis and correctly declines to escalate:
  *"this meets neither the runtime-defect bar nor the agent-hazard basis"* → APPROVE.

## Statistics (`tests/ab/lib/ab_stats.py`, stdlib only)

Hit 2×2 (arm A = (0 Important, 5 not); arm B = (5 Important, 0 not)):

```
fisher_exact_two_tailed(a=0, b=5, c=5, d=0)  ->  p = 0.00794
```

Near-miss arm-B inflation (0 of 5 trials wrongly Important):

```
wilson_interval(successes=0, n=5)  ->  (0.0, 0.434)
```

## Decision rule applied

- **Hit firing:** Fisher p = 0.00794 < 0.05 with arm B fully skewed to Important
  (5/5) vs arm A (0/5) — a clean, complete A→B shift. **The basis fires.**
- **Near-miss inflation:** 0 observed false positives in arm B; Wilson upper bound
  0.434 reflects only the n=5 sample size, not observed inflation. **Acceptably low.**

Both conditions of the VALIDATED branch are met. **Verdict: VALIDATED.**

## On the feasibility note's caveat

The two n=1 sonnet probes (feasibility note §"Second confirmatory probe") kept the
hit at Important in *both* arms — arm A did not apply the single-bar downgrade. The
note flagged two reasons that was not the trial's answer: (a) n=1 cannot separate
"no effect" from noise; (b) the probes used sonnet for cost while the trial pins
opus. The opus run at 5/cell resolves it in favour of (b): **opus honours the arm-A
single-runtime-defect downgrade faithfully** (all 5 arm-A hit trials reclassified to
Suggestion), so the basis is the load-bearing difference between the arms. The
caveat is discharged by the data, not assumed away.

## Follow-up

- **PR #52 "Validation status" caveat can be discharged** — the basis has
  behavioural evidence at the synthesiser: it fires on a genuine agent-hazard and
  does not inflate an honest-but-vague comment, at opus.
- Canonical arm-B reports captured to
  `tests/ab/corpus/synth-hazard-{hit,nearmiss}/expected/report.md`; `suite_sha`
  stamped (`0b12af5`) in both fixtures.
- **Harness fixes made during execution** (apparatus-correctness, not basis/fixture
  tuning):
  1. `run.sh` routed every per-agent trial through the static-specialist findings
     parser, which hard-fails for `review-synthesiser` (it emits a tiered report,
     not a `## <tool> Findings` block) and aborted the run under `set -euo
     pipefail`. The feasibility probes drove the synthesiser by hand, bypassing
     `run.sh`, so this path was never exercised offline. Guarded the parser call
     (commit `0b12af5`).
  2. `synth_score.sh` demanded an exact `lib/cache.py:42` match, but opus cites the
     planted line three ways — `42`, `42 (comment at lines 39-41)`, and the range
     `39-42`. The scorer under-counted (symmetrically across arms). Hardened the
     line matcher to read the leading linespec token and accept a range that
     brackets the planted line; added unit-test coverage for both formats.
