# ruff / eslint / trivy — apparatus-fix re-validation (backlog #3)

**Date:** 2026-06-04
**Outcome:** Verdicts re-validated PASS from existing run data. No re-sweep, no
Bedrock spend. Cost-ratios for ruff/eslint flagged as inflated (not corrected).

## Why this was asked

All three specialists were flipped to `haiku`+`effort:low` under the OLD harness,
before `830905b` (2026-06-04 12:24) based the per-agent trial dirs under
`/tmp/claude-`. Their EQUIVALENT verdicts and cost-ratios predate the fix, so they
carried latent risk from the hook-leak confound (an absolute `/private/tmp/...`
path in a subagent tool command tripping the operator's `bash-guard.sh`
TEMP-DIRECTORY-VIOLATION policy and forcing a retry / mis-scored skip).

## Method (offline)

`grep -rl 'TEMP DIRECTORY VIOLATION' tests/ab/runs/` over each specialist's final
paired run, cross-referenced against the per-trial `summary.csv` (exit_code,
findings_hash, inconclusive, timed_out) and the result-note verdicts.

## Finding 1 — the verdicts are SAFE

Every final haiku-low sweep recovered to an identical canonical findings hash with
zero timeouts. Hook denials appear in the stream traces but the agents retried
onto a `/tmp/claude-` path and produced the canonical finding set.

| Specialist | Final haiku-low run | Result |
|---|---|---|
| ruff | `20260602T095222Z-ruff-haiku-low-reprobe` | 20/20 hash `7b003236…`, 0 inconclusive |
| eslint | `20260603T114412Z-eslint-haiku-low` (canonical per result note) | 19/20 canonical `8d62c08e…` + 1 agent-side skip (trial 011) |
| trivy | `20260603T173119Z-trivy-haiku-low` | 20/20 hash `b0888193…`, 0 inconclusive |

**eslint disjointness proof.** The 3 divergent eslint trials (3/11/17 — documented
tier-1 resolution skips) are DISJOINT from the 4 hook-tripped trials (1/14/15/16).
So the divergences were genuine agent-side resolution-ladder skips, not the
apparatus confound. The 85% NORMAL rate is real, not a hook artifact.

**`830905b` confirmed working:** the post-fix jbinspect final run
(`20260604T114635Z-jbinspect-haiku-low`) has **0** violations.

## Finding 2 — the handover premise was WRONG

The handover claimed ruff/eslint/trivy "stream stdout rather than passing an
absolute solution path the way jbinspect did", implying they were immune. False —
trivy invokes `trivy config … /private/tmp/per-agent-<ts>/trial-NNN/Dockerfile`,
an absolute path that trips the hook in 12/20 trials. The confound bit all three;
it just manifested as retry-turns rather than skips because they recovered.

## Finding 3 — cost-ratios are CONTAMINATED, asymmetrically

Hook denials force extra retry turns → inflated `num_turns` / tokens on whichever
arm tripped them. Violation incidence per final paired run:

| Specialist | haiku-low arm | baseline arm | symmetry | published ratio |
|---|---|---|---|---|
| trivy | 12/20 | 12/20 | **symmetric** | 2.34× (roughly fair) |
| eslint | 15/20 (run `121608Z`) / 4/20 (canonical `114412Z`) | 0/20 | **asymmetric** | 2.17× (inflated) |
| ruff | 2/20 | 0/20 | **asymmetric** | 2.20× (inflated, mildly) |

trivy's ratio is approximately fair (both arms equally taxed). **ruff's and
eslint's published ratios are inflated** — only the haiku arm paid the hook-retry
tax. The true haiku/baseline cost-ratios for ruff and eslint are somewhat LOWER
than published.

## Decision

Verdict re-validation is the load-bearing question and it PASSES offline. The
cost-ratios are secondary list-price estimates (already caveated as
non-Bedrock list-price in the result notes), so the operator chose **document
only** — no gated re-sweep. If a future cross-specialist cost comparison needs
trustworthy ruff/eslint numbers, re-sweep those two arms on the fixed harness
(trivy is already roughly fair).
