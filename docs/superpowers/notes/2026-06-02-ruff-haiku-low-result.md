# Phase 3.1b — ruff-reviewer Haiku/low re-probe result

**Date:** 2026-06-02
**Status:** equivalent
**Spec:** ../specs/2026-06-02-phase-3-1b-ruff-haiku-low-design.md
**Plan:** ../plans/2026-06-02-phase-3-1b-ruff-haiku-low-reprobe.md
**Precedent (pre-fix sweep):** ./2026-05-29-empty-stdout-investigation-result.md
**Baseline (cited):** ./2026-06-02-phase-3-1c-validation-sweep.md
**Run dir:** `tests/ab/runs/20260602T095222Z-ruff-haiku-low-reprobe/` (gitignored)
**Sweep SHA:** `9eb48c8`

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `ruff-reviewer`. Fixture: `ruff-smoke-bad-py` (single canonical F401).
- Model / effort: Haiku / `low`. Trials: n=20. Timeout: 600 s.

## Baseline (cited, not re-run)

Sonnet/default, 3.1c validation sweep: 20/20 NORMAL, canonical hash `7b003236…91c3`,
Wilson 95 % CI [83.89 %, 100.00 %]. Provenance: 3.1c swept `ed437cb`; `main` is the
squash-merge `a01c876`; the functional harness (`tests/ab/lib/`, `run.sh`, expected
baseline, configs) is byte-identical across the two SHAs — the only `tests/ab/` delta
is the `suite_sha` provenance string in `source.yaml`.

## Class breakdown (n=20)

| Class  | Count | Percentage | Wilson 95% CI       |
|--------|-------|------------|---------------------|
| NORMAL | 20    | 100.00 %   | [83.89 %, 100.00 %] |
| DRIFT  | 0     | 0.00 %     | [0.00 %, 16.11 %]   |
| EMPTY  | 0     | 0.00 %     | [0.00 %, 16.11 %]   |
| OTHER  | 0     | 0.00 %     | [0.00 %, 16.11 %]   |

Every one of the 20 trials returned `findings_count == 1`, the canonical
`findings_hash` (`7b003236…91c3`), and `first_finding_rule == F401`, with
`exit_code 0`, `inconclusive false`, and `timed_out false`. Corroborated
row-for-row against the harness-native `summary.csv`.

## Before / after vs Phase 3.1a (same arm, same fixture, n=20)

| Class  | 3.1a (pre-fix) | 3.1b (post-3.1c) | Movement   |
|--------|----------------|-------------------|------------|
| NORMAL | 5.00 %         | 100.00 %          | +95.00 pts |
| DRIFT  | 65.00 %        | 0.00 %            | −65.00 pts |
| EMPTY  | 30.00 %        | 0.00 %            | −30.00 pts |

Both 3.1a pathologies cleared completely. This confirms the 3.1a EMPTY (CLI
envelope-finalisation gap, Category C) and DRIFT (prose-vs-JSON parser mismatch)
were apparatus-level noise — not a model deficiency — and that the 3.1c harness
fallback + pinned §7 parser eliminate them on the per-agent stream-json substrate.

## Wall-clock

Mean 34.5 s, range 16–113 s (cost delta vs 3.1a mean 22 s: +12.5 s on the mean).
The mean is pulled up by two outliers (trial-012 87 s, trial-020 113 s); the bulk
of trials sit in the 16–40 s band. The delta is within Bedrock latency variance and
does not affect finding sets.

## Verdict

**equivalent.** Haiku/low matches the Sonnet/default baseline exactly on finding
sets: 100 % NORMAL, identical Wilson 95 % CI [83.89 %, 100.00 %], and the same
canonical tuple hash on every trial. No movement against the parent spec's >25 %
movement guard. No within-arm non-determinism — all 20 hashes are identical, so
there is no transmission-task defect. No misses and no fabrications: the recall
direction is exact-match on both arms.

This probe is **informational** — it informs a later adoption decision and does
**not** flip `ruff-reviewer.md`'s `model:` field.

## Residual unrecoverable EMPTY (if any)

Zero. No trial fired `launch_assert_trial_recoverable`; the equivalence denominator
is the full n=20 with no adjustment. No upstream-CLI footnote is required for this
sweep.

## Cross-references

- Parent spec: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Phase 3.1a result: ./2026-05-29-empty-stdout-investigation-result.md
- Phase 3.1c validation: ./2026-06-02-phase-3-1c-validation-sweep.md
