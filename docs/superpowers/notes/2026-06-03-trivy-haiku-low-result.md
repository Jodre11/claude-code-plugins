# Phase 3.3 — trivy-reviewer Haiku/low A/B result

**Date:** 2026-06-03
**Status:** inconclusive (decision-4) — residual tail is agent-side, not apparatus
**Spec:** ../specs/2026-05-29-static-specialist-tuning-sweep.md
**Plan:** ../plans/2026-06-03-phase-3-3-trivy-ab-baseline.md
**Precedent (eslint, inconclusive + agent-side tail):** ./2026-06-02-eslint-haiku-low-reprobe-result.md
**Precedent (ruff, equivalent):** ./2026-06-02-ruff-haiku-low-result.md
**Baseline run dir:** `tests/ab/runs/20260603T153718Z-trivy-baseline/` (gitignored)
**Sweep run dir:** `tests/ab/runs/20260603T153722Z-trivy-haiku-low/` (gitignored)
**Sweep SHA:** `5e28ed0`

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `trivy-reviewer`. Fixture: `trivy-smoke-bad-dockerfile` (three
  deterministic IaC findings on a single `Dockerfile`: `DS-0001` `:latest` tag
  on line 1, `DS-0004` `EXPOSE 22` on line 7, `DS-0031` secret-in-`ENV` on line
  9). trivy 0.71.0, `trivy config --format=json --severity=MEDIUM,HIGH,CRITICAL
  --exit-code=0`.
- Arms: Sonnet/default (`trivy-baseline.yaml`) and Haiku/low
  (`trivy-haiku-low.yaml`), n=20 each.
- Apparatus: trivy is global-on-PATH (like ruff) — NO `setup:` provisioning
  block, so there is no install race. The fixture Dockerfile is copied per-trial
  into a hermetic working dir.
- The worked example was live-captured and pinned in `trivy-reviewer.md`
  (`323997a`) before this sweep — the capture-then-pin discipline that closed the
  zero-tuple parse gap (per [[worked-example-gap]]). The §7 layout is now read
  correctly: 39/40 trials across both arms parsed cleanly to the canonical tuples.

## Canonical hash re-established at n=20

The Sonnet/default arm is a perfect **20/20** on canonical hash
`b0888193a342580fc476804f9a3d69a7b69cfd35f04008e8dd226c7c170e8a98` — the
3-tuple set:

```json
[{"file":"Dockerfile","line":1,"rule_id":"DS-0001","severity":"Suggestion","confidence":100},
 {"file":"Dockerfile","line":7,"rule_id":"DS-0004","severity":"Suggestion","confidence":100},
 {"file":"Dockerfile","line":9,"rule_id":"DS-0031","severity":"Critical","confidence":100}]
```

Every Sonnet trial emitted `findings_count == 3`, the canonical hash,
`first_finding_rule == DS-0001`, `exit_code 0`, `inconclusive false`,
`timed_out false`. The canonical hash matches the Task-5 gated re-capture hash
exactly — confirmed at n=20, not carried forward from a single trial.

The agent emits bare `DS-NNNN` IDs with a capitalised `(Dockerfile)` provider
token, as the fixture and worked example agree.

## Hash distribution (canonical = `b0888193…`, the 3-tuple set)

| Arm | canonical | zero-findings (`37517e5f…`) | skipped | NORMAL rate |
|---|---|---|---|---|
| **Sonnet/default** | **20 / 20** | 0 | 0 | **100 %** |
| **Haiku/low** | 19 / 20 | 1 (trial 016) | 0 | **95 %** |

The Sonnet arm is perfectly deterministic at n=20. The Haiku arm reproduces the
canonical 3-tuple set on 19 of 20 trials; the single divergence (trial 016) is a
self-aborted skip mis-classified as zero-findings (below).

## The 1 divergent Haiku trial — agent-side, NOT apparatus

Both arms received the byte-identical prompt, which ends with the literal line
`… Use $CLAUDE_TEMP_DIR for temporary files.` (verified in
`trial-016/user-message.txt` and `trial-001/user-message.txt`). 19/20 Haiku
trials ran `trivy config` directly and never needed a temp file — the passing
trials don't write the JSON to disk at all, they parse trivy's stdout inline.

Trial 016 is the lone exception: Haiku fixated on the **unexpanded** `$CLAUDE_TEMP_DIR`
token, reasoned itself into a corner ("the temp directory variable wasn't
injected into this agent context … the system prohibits using fallback temp
locations"), and self-aborted with:

```
## Trivy IaC Findings

Skipped — unable to create temporary files. The scan requires `CLAUDE_TEMP_DIR` to be available in the agent context.
```

This is a **recall-side skip, no fabrication** — consistent with the recall
direction seen in eslint/ruff (Haiku misses/skips, never invents findings).

### Two distinct, model-agnostic defects surfaced (informational)

1. **Temp-dir contract over-literalism (agent body / shared context).**
   `static-analysis-context.md` §4 says "Require `$CLAUDE_TEMP_DIR` from the
   prompt … If absent, report the omission and stop." The harness passes the
   literal string `$CLAUDE_TEMP_DIR` (the variable is not shell-expanded in the
   prompt), so a model that reads "is the *expanded path* present?" rather than
   "is the *instruction* present?" can wrongly conclude the contract is violated
   and abort — even though `trivy config` parses stdout and needs no temp file
   for this fixture. The trivy body (§"Tool invocation") routes trivy output to
   `$CLAUDE_TEMP_DIR/trivy-config.json`, reinforcing the idea that a temp file is
   mandatory when in practice inline stdout parsing is fine. This is an
   under-specification that could bite any model; Sonnet happened not to trip it.
   A model-agnostic fix would clarify that the literal `$CLAUDE_TEMP_DIR` token
   in the prompt satisfies the contract, and that streaming trivy stdout inline
   (no temp file) is acceptable. **Characterised, not fixed.**

2. **Parser skip-sentinel is too narrow (harness).** The trivy parser matches
   only `^Skipped — trivy not available` (`agent_capture.sh`). Trial 016 said
   `Skipped — unable to create temporary files …` → did **not** match → was
   mis-classified as a genuine **0-findings** result (hash `37517e5f…`), NOT a
   skip/INCONCLUSIVE. This silently understates the skip rate and pollutes the
   zero-findings class — the exact same defect class eslint's 3.2b re-probe found
   (where `Skipped — eslint not available` missed the `/biome`-optional
   sentinel). The sentinel should tolerate any `Skipped — …` opener for this
   specialist (or at minimum the temp-dir-abort phrasing). **Characterised, not
   fixed.**

Per the tuning-to-the-test guard, neither is patched here: any fix must be a
general correctness improvement (helping Sonnet too) and earns its own
before/after at n=20 on both arms.

## Cost delta

Per-trial cost columns captured in `summary.csv` from the stream `result`
envelope (`total_cost_usd`, `num_turns`, `usage.output_tokens`,
`usage.cache_read_input_tokens`).

| Arm | n | mean cost/trial* | mean turns | mean out tok | mean cache-read tok |
|---|---|---|---|---|---|
| Sonnet/default | 20 | **$0.10985** | 6.15 | 1,257 | 161,582 |
| Haiku/low | 20 | **$0.05383** | 7.40 | 1,657 | 188,002 |

**Cost ratio Sonnet ÷ Haiku = 2.04×.**

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative of the **ratio**, not the actual Bedrock bill. The 2.04× ratio
> is the reportable figure; it sits just below ruff (informational ~2.2×) and the
> eslint post-fix 2.17× / pre-fix 2.46×, so the price-tier saving is stable and
> in family across all three static specialists.

Consistent with the programme's earlier finding: cost is dominated by turns ×
cached context, not output tokens (Haiku's mean output is *higher* than
Sonnet's, yet it costs 2.04× less — the lever is the price tier, not verbosity).

## Wall-clock

Sonnet mean 34 s (one 78 s outlier, trial 015); Haiku mean 30 s, range 24–43 s.
Both well within Bedrock latency variance; neither affects finding sets.

## Verdict (framework verbatim)

- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean,
  single-hash arm).
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive
  regardless of rate.
- **WORSE** — >25 % NORMAL-rate drop.

**INCONCLUSIVE by decision-4 (mixed within-arm hashes).** The Haiku arm produced
mixed hashes (19 canonical + 1 zero-findings); per the parent spec's decision 4
(carried from 3.1b/eslint), mixed within-arm hashes default the verdict to
inconclusive regardless of rate. The 5 % NORMAL-rate movement is far below the
25 % WORSE threshold, and the single divergence is a **genuine, characterised,
agent-side skip** — not an apparatus artefact (the worked example parses cleanly,
the prompt was identical across arms, 19/20 succeeded). The recall direction is
unambiguous: **Haiku skips, never fabricates.**

This probe is **informational** — it does **not** flip `trivy-reviewer.md`'s
`model:` field, which remains `sonnet`.

## Production-flip recommendation

**Do NOT flip to Haiku/low on this result.** The flip gate is a clean
**EQUIVALENT** verdict; trivy returned INCONCLUSIVE. (The effort-field blocker
that held eslint/ruff is now resolved — `effort:` is a documented subagent
frontmatter key, low/medium/high/xhigh/max, and eslint/ruff were flipped to
`model: haiku` + `effort: low` at `3b3a255`; so a clean trivy EQUIVALENT *would*
have flipped both fields. But the verdict is not clean.)

The single divergence is plausibly closable by the two characterised fixes above
(temp-dir contract clarification + skip-sentinel widening) — both general
correctness improvements that pass the asymmetry test. If the operator wants to
pursue a Haiku/low trivy adoption, the next step mirrors eslint's PR C: ship both
fixes, then re-sweep both arms at n=20 as a fix-validation pass. Until then,
trivy stays `model: sonnet`.

## Cross-references

- Parent spec: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Phase 3.2b eslint re-probe (closest precedent — agent-side tail + skip
  sentinel): ./2026-06-02-eslint-haiku-low-reprobe-result.md
- Phase 3.1b ruff (equivalent precedent): ./2026-06-02-ruff-haiku-low-result.md
- Worked-example gap (why trivy's first capture parsed to zero — now closed):
  see memory `project_worked_example_gap.md`
