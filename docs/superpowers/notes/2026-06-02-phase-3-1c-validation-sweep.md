# Phase 3.1c — validation-sweep result

**Date:** 2026-06-02
**Run dir:** `tests/ab/runs/20260602T073653Z-ruff-baseline-validation/` (local only; gitignored)
**Sweep SHA:** `ed437cb` (head of `feat/phase-3-1c-tighten-contracts` at sweep time)
**Config:** `tests/ab/configs/per-agent/ruff-baseline.yaml` (Sonnet/default)
**Corpus:** `ruff-smoke-bad-py`
**Trials:** 20
**Stream-json:** on
**Cost:** ~50 k Bedrock tokens, ~10 minutes wall-clock (20 trials, mean 26 s/trial, 0 timeouts)

## Provenance note

This is the second execution of the 3.1c validation sweep. The first run
(2026-06-01, also 20/20 PASS) and the entire 3.1c branch were lost when a
Claude Code marketplace `autoUpdate` re-cloned the working directory on session
startup before the branch had been pushed. The harness changes were reconstructed
byte-for-byte from the implementation-session transcript and the committed plan
(verified by the canonical-hash pre-flight and the offline test suite), then this
sweep was re-run as the genuine merge gate. The result reproduces the original:
a clean 20/20.

## Sweep command

The run mode is derived from the config YAML (`mode: per-agent` in
`ruff-baseline.yaml`); `tests/ab/run.sh` has no `--mode` flag (Amendment 4):

```bash
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-baseline.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json \
    --name ruff-baseline-validation
```

## Acceptance gate

| Metric | Threshold | Actual | Pass |
|---|---|---|---|
| NORMAL | ≥ 80 % | 20/20 (100.0 %) | ✓ |
| DRIFT | < 10 % | 0/20 (0.0 %) | ✓ |
| EMPTY | = 0 | 0 | ✓ |
| validate-or-die fires | = 0 | 0 | ✓ |

**Gate result:** PASS.

## Per-trial classification

All 20 trials classified NORMAL — findings_count 1, canonical tuple hash
`7b003236…91c3`, rule F401, no validate-or-die fire, no timeout. The harness's own
`summary.csv` corroborates the classification row-for-row (exit_code 0,
findings_count 1, findings_hash canonical, first_finding_rule F401, inconclusive
false, timed_out false for every trial).

| Trial | Class | Findings count | validate-or-die fired | Reason (if fired) |
|---|---|---|---|---|
| trial-001 | NORMAL | 1 | false | |
| trial-002 | NORMAL | 1 | false | |
| trial-003 | NORMAL | 1 | false | |
| trial-004 | NORMAL | 1 | false | |
| trial-005 | NORMAL | 1 | false | |
| trial-006 | NORMAL | 1 | false | |
| trial-007 | NORMAL | 1 | false | |
| trial-008 | NORMAL | 1 | false | |
| trial-009 | NORMAL | 1 | false | |
| trial-010 | NORMAL | 1 | false | |
| trial-011 | NORMAL | 1 | false | |
| trial-012 | NORMAL | 1 | false | |
| trial-013 | NORMAL | 1 | false | |
| trial-014 | NORMAL | 1 | false | |
| trial-015 | NORMAL | 1 | false | |
| trial-016 | NORMAL | 1 | false | |
| trial-017 | NORMAL | 1 | false | |
| trial-018 | NORMAL | 1 | false | |
| trial-019 | NORMAL | 1 | false | |
| trial-020 | NORMAL | 1 | false | |

(Generated from `classification.csv` in the run dir.)

## Wilson 95 % CIs

- NORMAL: 20/20 = 100.0 % (Wilson 95 % CI [83.89 %, 100.00 %])
- DRIFT: 0/20 = 0.0 % (Wilson 95 % CI [0.00 %, 16.11 %])

## Verdict

The validation gate passes. The 30 % EMPTY incidence and 65 % DRIFT incidence observed
in 3.1a's Haiku/`low` sweep collapse to 0 % and 0 % respectively at Sonnet/default with
the harness fallback + validate-or-die + parser tightening + §7 example block in place.
Not a single trial required the fallback path (every trial emitted canonical text in the
terminal `.result` envelope) and not a single trial drifted from canonical §7. The
apparatus-level noise floor that blocked the static-specialist tuning sweep is eliminated
on the per-agent stream-json substrate.

The Phase 3.1a-identified upstream Claude Code envelope-finalisation gap remains as a side
artefact (tracked separately for upstream filing); the harness is now insulated from it
via the fallback recovery, and the validate-or-die assertion converts any residual
unrecoverable case from a silent success into a loud failure.

## Cross-references

- Spec: `docs/superpowers/specs/2026-06-01-phase-3-1c-tighten-contracts-design.md`
- Plan: `docs/superpowers/plans/2026-06-01-phase-3-1c-tighten-contracts-plan.md`
- Phase 3.1a result report: `docs/superpowers/notes/2026-05-29-empty-stdout-investigation-result.md`
- PR: https://github.com/Jodre11/claude-code-plugins/pull/39
