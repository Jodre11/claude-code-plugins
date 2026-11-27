# Review eval results: suite, native and hybrid

**Outcome.** Anthropic's bundled `/code-review` ("native") found more of the planted bugs and rule breaks than the
code-review suite, at 29 % of the cost and half the wall-clock, with noise equal at the point estimate. The
decision rule returned KEEP only because the noise interval is too wide to rule out a 10-point loss, and the
benchmark cannot supply enough PRs to narrow it. The hybrid arm (the suite plus Anthropic's pipeline as a
specialist) gained nothing at 1.7× the cost. The owner chose a native finder with a thin suite: `/code-review`
does the LLM finding; the suite keeps its static analysers, the housekeeper and the GitHub posting and reply flow,
none of which this eval measured. That design is a separate spec.

Design and decision rule: [`docs/specs/2026-11-25-review-eval.md`](../specs/2026-11-25-review-eval.md) (PR #144).
Harness: `evals/` (PR #146).

## Runs

| Pass | Cases | Cost | Notes |
|---|---|---|---|
| First pass | 29 fixtures × 3 arms × 3 runs | $187 | an SSO token expired 14:59–15:09 on 2026-11-25; the runs it broke failed `valid-*` |
| Rerun A | 12 Qodo fixtures × 3 arms × 3 | $231 | replaces the broken decision-set runs |
| Rerun C | 7 refreshed fixtures × 3 arms, plus 3 leftover cases, × 3 | $206 | every run valid |
| Extension | 16 new Qodo fixtures × suite, native × 3 | $202 | every run valid |

Total about $826, inside the approved $750 plus the approved ~$180 extension. Judge: sonnet, three votes per
criterion; 97.8–99.4 % of llm verdicts were unanimous in every arm.

## Deviations from the spec

- **PATH leak.** The eval child inherits the host session's `PATH`, including installed plugins' `bin/`, so the
  first pilot ran the installed `review-diff`. Every counted run used the stripped `PATH` in `evals/README.md`, and
  the `valid-plugin-under-test` grader rejects a run that reaches the plugin cache.
- **Route grader.** The model does not print the route announcement, so `route-full` reads review-core's `route`
  argument instead.
- **Intent leads.** Seven Qodo descriptions (a dependency-bot body, heading-and-bullet bodies) halted the suite's
  Phase 0 at random, which would have measured description style. The porter now opens such a description with a
  plain two-sentence lead and keeps the original below; all runs of those fixtures before the change were dropped
  (`curate.py --drop`) and rerun (rerun C).
- **Regrade.** The hybrid `valid-anthropic-ok` pattern rejected valid wordings of the status line
  ("anthropic (plugin pipeline …): ok"). It was loosened and re-applied to earlier runs' final messages with
  `curate.py --regrade valid-anthropic-ok` (5 verdicts flipped to pass). One run whose line said "completed"
  stays invalid.
- **Extension.** The 12-PR result was inconclusive, so 16 more PRs were ported (seven per repo) and run in the
  suite and native arms only; the hybrid had already been ruled out. `aggregate.py --arms suite native` pairs all
  28 PRs over those two arms. Ghost#7 was skipped because its test files carry upstream private keys, which the
  repo's secret scan refuses; the next eligible PR (Ghost#12) replaced it.

## Results: 12 PRs, three arms

| Arm | BR | RR | NP | Must-fix | Cost/review | Wall-clock |
|---|---|---|---|---|---|---|
| suite | 86.3 % | 47.7 % | 72.2 % | 74.4 % | $2.69 | 3.8 min |
| native | 86.3 % | 48.6 % | 83.3 % | 75.2 % | $0.76 | 1.8 min |
| hybrid | 86.3 % | 47.0 % | 70.6 % | 71.3 % | $4.58 | 5.2 min |

Hybrid − suite, 90 % cluster-bootstrap CI: bug +0.0 [−2.7, +2.7], rule −0.7 [−8.5, +11.6], noise −1.7
[−16.7, +14.4], must-fix −3.1 [−6.5, −0.2]; cost 1.71×. Rule 1 (HYBRID) does not hold.

Per-issue overlap (76 issues; an arm "finds" an issue in a majority of its runs): both arms 48, neither 25, suite
only 1, native only 2. The better arm per issue reaches 74 % against about 68 % for either alone, and most of that
gap is run-to-run variation. The two finders catch the same issues, so combining them, in the hybrid or a leaner
variant, adds little.

An early read on three PRs showed the hybrid ahead on rule recall (67 % against 44 %); it did not survive the
full set.

## Results: 28 PRs, suite against native

| Arm | BR | RR | NP | Must-fix | Cost/review | Wall-clock |
|---|---|---|---|---|---|---|
| suite | 78.9 % | 44.6 % | 71.4 % | 69.7 % | $2.79 | 3.8 min |
| native | 83.1 % | 53.6 % | 69.0 % | 71.6 % | $0.82 | 1.9 min |

| Native − suite | Point | 90 % CI |
|---|---|---|
| bug | +4.2 pp | [+1.1, +7.4] |
| rule | +9.0 pp | [+0.8, +18.6] |
| noise | −2.4 pp | [−17.9, +13.1] |
| must-fix | +1.9 pp | [−1.6, +5.6] |

**Decision rule: KEEP.** Rule 2 (SWITCH candidate) needs BR and RR lower bounds above −5 pp (+1.1 and +0.8: met),
cost at most 0.50× (0.29×: met) and an NP lower bound above −10 pp (−17.9: not met). Noise is graded once per
run, so its interval narrows slowly; reaching −10 pp at this point estimate would take about four times as many
PRs, more than the four permissive Qodo repos hold.

Native did better on 17 PRs, worse on 4 and tied on 7. The largest gap is the largest diff, tauri-5 (36 files,
1,444 lines): 24 % suite, 57 % native.

## Sanity set

Not in the rule: the suite was tuned on these fixtures, and most route lightweight.

| Fixture | suite | native |
|---|---|---|
| api-contract-nearmiss | 100 % | 33 % |
| reuse-nearmiss | 100 % | 0 % |
| silentfail-nearmiss | 100 % | 0 % |
| test-adequacy-f1-hit | 0 % | 100 % |
| test-quality-nearmiss | 0 % | 0 % |

The other 12 fixtures were 100 % in both arms. Native reported three of the suite's near-miss patterns as
must-fix, which is the noise risk the decision-set interval cannot exclude; the thin-suite design should keep an
eye on it.

## Not measured

The static analysers (ruff, eslint, jbinspect, trivy), the housekeeper, the GitHub posting and reply flow and the
intent ledger. Qodo issues are graded by an llm judge against a description, and none of them is a dependency
or IaC finding.
