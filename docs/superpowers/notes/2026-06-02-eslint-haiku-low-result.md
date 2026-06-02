# Phase 3.2 — eslint-reviewer Haiku/low probe result

**Date:** 2026-06-02
**Status:** inconclusive
**Spec:** ../specs/2026-06-02-phase-3-2-eslint-haiku-low-design.md
**Plan:** ../plans/2026-06-02-phase-3-2-eslint-haiku-low.md
**Precedent (ruff):** ./2026-06-02-ruff-haiku-low-result.md
**Apparatus baseline (3.1c):** ./2026-06-02-phase-3-1c-validation-sweep.md
**Baseline run dir:** `tests/ab/runs/20260602T115559Z-eslint-sonnet-determinism/` (gitignored)
**Sweep run dir:** `tests/ab/runs/20260602T121117Z-eslint-haiku-low-probe/` (gitignored)
**Sweep SHA:** `a7bdaa4`

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `eslint-reviewer`. Fixture: `eslint-smoke-bad-js` (4-rule set on a single JS file).
- Model / effort: Haiku / `low`. Trials: n=20. Timeout: 600 s.

## Baseline (freshly captured this phase, n=3)

Sonnet/default determinism check: 3/3 NORMAL, canonical hash `8d62c08e…1148`
(4 tuples: `no-var`, `prefer-const`, `no-unused-vars`, `eqeqeq` on `bad.js`
lines 1/2/3/6), Wilson 95 % CI **[43.85 %, 100.00 %]**. The finding set was
hand-verified against `eslint --format json` (covers all four reported rules,
fabricates none). All three trials produced the byte-identical hash, so the
baseline is internally deterministic — but at n=3 the confidence interval is wide.

> **Baseline-power caveat (load-bearing for the verdict).** The spec's
> decision 1 sized the Sonnet baseline cheaply (1 capture + 3 determinism
> trials) on the premise — carried from the ruff result — that Sonnet would be
> rock-solid and Haiku would match it 20/20. The Haiku arm broke that premise
> (it has a tail), so the n=3 baseline is no longer adequate to interpret the
> Haiku arm. An 85 %-true-rate model produces 3/3 clean trials ≈ 61 % of the
> time, so this n=3 baseline is statistically **consistent with the same ~15 %
> divergence rate** observed in the Haiku arm. We therefore cannot assert that
> Sonnet outperforms Haiku here. Resolving this needs a symmetric 20-trial
> Sonnet sweep — deliberately deferred (see "Next step").

## Class breakdown (n=20, Haiku/low)

| Class  | Count | Percentage | Wilson 95% CI       |
|--------|-------|------------|---------------------|
| NORMAL | 17    | 85.00 %    | [63.96 %, 94.76 %]  |
| DRIFT  | 3     | 15.00 %    | [5.24 %, 36.04 %]   |
| EMPTY  | 0     | 0.00 %     | [0.00 %, 16.11 %]   |
| OTHER  | 0     | 0.00 %     | [0.00 %, 16.11 %]   |

17 of 20 trials returned `findings_count == 4`, the canonical
`findings_hash` (`8d62c08e…1148`), and `first_finding_rule == no-var`, with
`exit_code 0`, `inconclusive false`, and `timed_out false`. Corroborated
row-for-row against the harness-native `summary.csv`.

### The 3 divergent (DRIFT) trials — all recall-side, no fabrications

| Trial | Mode | Detail |
|-------|------|--------|
| trial-015 | recall loss / structured-output drop | Prose claimed "Found 4 Important violations across all changed lines (1, 2, 3, 6)" but emitted **zero** §7 finding blocks → parser correctly yielded `[]`. |
| trial-016 | spurious tool-skip | Emitted `Skipped — eslint/biome not available on PATH or in node_modules.` (INCONCLUSIVE marker) though eslint ran fine in the other 17 trials. |
| trial-019 | spurious tool-skip | Same as 016: claimed "ESLint is not available on PATH or in node_modules" and skipped. |

All three are **recall-side**: Haiku either skips the tool it should have run
or drops the structured output it claims to have produced. None fabricate a
finding eslint did not surface. Trials 016/019 classify as **DRIFT** (not
EMPTY): exit 0 with a non-canonical/`skipped` hash and no
`launch_assert_trial_recoverable` fire — they are agent-level spurious skips,
not the upstream CLI envelope-finalisation bug.

## Wall-clock

Mean 65.0 s, range 34–134 s. The Sonnet baseline mean was 48.7 s, so the
cost delta is **+16.3 s on the mean**. Two Haiku trials sit at 134 s
(trial-008, trial-018) — both produced the canonical hash with `timed_out false`;
they pull the mean up but are not failures.

> **Footnote — spurious "1 timeouts" in the run summary.** The completion
> summary printed `1 timeouts`, but the authoritative per-trial data shows
> **zero** genuine timeouts: no trial has `timed_out true` in `summary.csv`,
> none exited `124`, and the slowest trial (134 s) is far under the 600 s
> limit. This is a completion-summary aggregation miscount, not a real timeout;
> it does not affect classification (the classifier reads the per-trial
> `timed_out` column).

## Verdict

**inconclusive.** Two independent reasons, either sufficient on its own:

1. **Asymmetric baseline power (dominant).** The Sonnet baseline is n=3
   (CI [43.85 %, 100.00 %]) against a Haiku arm of n=20 (NORMAL CI
   [63.96 %, 94.76 %]). The intervals overlap heavily; the n=3 baseline cannot
   distinguish Sonnet from an 85 %-NORMAL model. We have no statistically
   sound basis to call Haiku worse — or equivalent.
2. **Within-arm non-determinism.** The Haiku arm produced mixed hashes (17
   canonical + 3 divergent). Per spec decision 4 (carried verbatim from 3.1b),
   mixed within-arm hashes default the verdict to `inconclusive` regardless of
   the rate.

The NORMAL-rate movement (100 % → 85 % = −15 pts) is *within* the parent spec's
>25 % movement guard, so the result does not reach "worse" on the rate axis
alone. The recall direction is unambiguous — Haiku **misses/skips, never
fabricates** — but the apparatus is not powered to convert that observation
into a directional verdict.

This probe is **informational** — it does **not** flip `eslint-reviewer.md`'s
`model:` field, which remains `sonnet`.

## Residual unrecoverable EMPTY

Zero. No trial fired `launch_assert_trial_recoverable`; the denominator is the
full n=20 with no adjustment. No upstream-CLI envelope footnote is required for
this sweep (contrast 3.1a, where the EMPTY class was non-zero).

## Apparatus changes landed this phase (not config tuning)

Two production-touching changes shipped alongside the probe, both genuine
fixes rather than probe-specific tuning:

1. **`eslint-reviewer.md` §7 worked example.** The first live Sonnet capture
   revealed the agent was *not* emitting the canonical
   `static-analysis-context.md` §7 block shape — it improvised a
   `**[N]**`/blockquote layout under a `### <Severity>` group heading with
   plain (non-bold) bullets, which the shared parser extracts as zero tuples.
   Root cause: the agent cited §7 but, unlike `ruff-reviewer.md` (fixed in
   3.1c), carried no worked example pinning the shape. Adding a multi-rule
   worked example fixed it; the re-captured Sonnet output conformed exactly and
   parsed to the 4-tuple set. **This is a systemic gap** — a
   `grep "Worked example"` across the four static specialists matched only ruff
   before this phase, and ruff + eslint after. **trivy (3.3) and jbinspect
   (3.4) will hit the same zero-tuple wall on first capture** and should each
   capture-then-pin their own worked example rather than authoring one blind.

2. **Parser-dispatch refactor.** `agent_capture_parse_ruff_trial` is now a thin
   shim over a parameterised `agent_capture_parse_trial <agent> <trial_dir>`
   driven by a per-agent dispatch table (heading, skip sentinel, zero-state).
   The ruff path is byte-identical (existing tests are the regression guard).
   A latent `run.sh` faithfulness-synth bug was fixed in passing: the
   expected-markdown filename uses the short tool key (`findings-eslint.md`)
   while `$_AB_CONFIG_AGENT` carries the full `eslint-reviewer` name.

## Next step (deferred, deliberately)

Prompt-hardening for Haiku/low precedes any further baselining. The two failure
modes this sweep diagnosed — spurious tool-skip and prose/structured recall
loss — are the hardening targets. A symmetric 20-trial Sonnet baseline is
**not** run now, because it would measure an agent that is about to change;
the baseline is re-established *after* the hardening, then both arms are swept
at matched n. The spurious-skip mode also smells effort-driven (`low`), so the
follow-up should consider a Haiku-*default*-effort arm to separate the effort
axis from the prompt axis.

## Cross-references

- Parent spec: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Phase 3.1b (ruff) result: ./2026-06-02-ruff-haiku-low-result.md
- Phase 3.1c validation: ./2026-06-02-phase-3-1c-validation-sweep.md
