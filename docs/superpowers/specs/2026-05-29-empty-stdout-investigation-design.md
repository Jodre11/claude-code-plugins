# Empty-stdout investigation — Phase 3.1a directional probe

**Date:** 2026-05-29
**Status:** Approved (design); not yet implemented
**Author:** Christian Haddrell
**Builds on / supersedes:** [`2026-05-21-orchestrator-empty-stdout-anomaly.md`](2026-05-21-orchestrator-empty-stdout-anomaly.md) — the original anomaly report (Phase 1 Trial 2, no-ultrathink, 2026-05-21). This spec executes its "What we SHOULD do" §1–2 + §5 actions on the per-agent codepath, where reproduction is approximately fifty times cheaper.
**Cross-reference:** [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md) — Phase 3.1a is the prerequisite that unblocks Phase 3.1b (ruff cost-tuning resume) and the subsequent 3.2 / 3.3 / 3.4 specialist probes.

## Context

Phase 3.1's 3-trial Haiku/low probe against `ruff-smoke-bad-py` (run dir `tests/ab/runs/20260529T144359Z-ruff-haiku-low/`, 2026-05-29) reproduced the empty-stdout anomaly first observed in Phase 1 Trial 2. Both observations share the same shape: `claude -p` exits with rc=0, stdout contains exactly 1 byte (single newline), stderr is empty, no timeout. The two observations together — 1/6 in Phase 1 (end-to-end mode, no-ultrathink) and 1/3 in Phase 3.1 (per-agent mode, Haiku/low) — give a wide-CI incidence around 17–33% across two completely different orchestrator paths.

Until the noise floor is characterised, every faithfulness check in the static-specialist tuning sweep (Phase 3.1b / 3.2 / 3.3 / 3.4) is statistically uninterpretable. A 3-trial result of 2/3 hash-match could be 100% real findings + 1 anomaly, or 2/3 real findings + 1 unrelated divergence. The verdicts the Phase 3 spec relies on (`3/3 = adopt`, `0/3 = reject`, `1-2/3 = non-deterministic`) all assume the anomaly's incidence is materially below the per-trial-divergence rate they are trying to detect.

This phase is the cheapest possible characterisation: a 20-trial sweep at Haiku/low against the existing smoke fixture, with `claude -p --output-format stream-json` so the per-event tool-use trace is captured for any empty-stdout occurrence. Approximate cost ~50–100k tokens. Outcome is a probable-cause hypothesis and a noise-floor number, not a fix.

## The fixture-cost story behind the per-agent substrate choice

The 2026-05-21 anomaly spec proposed §1 reproduce-on-baseline at ≥10 trials and §2 reproduce-on-no-ultrathink at ≥10 trials. Each end-to-end trial at sonnet/default costs ~250k Bedrock tokens, so executing the original spec verbatim would cost ~5M tokens. Phase 3.1a uses per-agent mode at Haiku/low against the smoke fixture as a substitute substrate: each per-agent trial costs ~2.5–5k tokens, so 20 trials cost ~50–100k tokens. Approximately fifty times cheaper for the same forensic outcome — provided the failure mode is invocation-shaped (`claude -p` returning rc=0 with empty stdout) rather than orchestrator-skill-shaped (specific to the review-gh-pr SKILL).

Both observations to date span **different orchestrator paths**:

- Phase 1 Trial 2 was end-to-end mode: orchestrator runs `review-gh-pr/SKILL.md`, dispatches specialists, dispatches synthesiser, applies verdict rubric, emits final assistant turn.
- Phase 3.1 trial-003 was per-agent mode: harness reconstructs an agent prompt and dispatches `ruff-reviewer` directly via `--append-system-prompt-file`. There is no synthesiser, no orchestrator skill, no rubric. Just the agent's own session, ending normally per its file's instructions.

The same 1-byte-stdout signature appearing across these two completely disjoint codepaths is strong evidence the failure is invocation-shaped, not skill-shaped. That justifies using per-agent as the cheap reproduction substrate.

## Goals

**Primary goal.** Measure the empty-stdout incidence rate at Haiku/low on the per-agent codepath with a tight enough confidence interval to either confirm the bug as reproducible (≥1 occurrence in 20) or bound it (≤5% at 95% CI if zero in 20). Inspect the stream-json trace for any occurrence to hypothesise a probable cause. Produce a one-page report.

**Concrete questions Phase 3.1a must answer:**

1. Across 20 trials of Haiku/low against `ruff-smoke-bad-py`, what is the empty-stdout incidence rate (with 95% CI)?
2. For any occurrence, what is the orchestrator's last observed action in the stream-json trace before non-emission?
3. Is the failure mode invocation-shaped (CLI bug, Bedrock streaming hiccup) or session-shape-dependent (the dispatched session early-exits inside a tool-use cycle)?

**Success criteria.**

- 20-trial sweep completed with stream-json captures.
- Incidence rate measured; Wilson 95% CI computed.
- For each occurrence: stream-json trace inspected, last-tool-use-or-text-event recorded, probable-cause category assigned.
- One-page report at `docs/superpowers/notes/2026-XX-XX-empty-stdout-investigation-result.md`.
- A status-line update in the original anomaly spec promoting it from `Open` to `Investigated 2026-XX-XX; <fixed | escalated | bounded>` with a link to the Phase 3.1a report.

## Non-goals

- **Not a fix.** The cause may be in the Claude Code CLI or in Bedrock; we do not control either. The fix lives in Phase 3.1c (the cross-cutting "tighten contracts + fail-loud" programme item, not yet brainstormed) or in an upstream issue against `claude` / Bedrock; not here.
- **Not a harness assertion.** Adding the structural-test-time empty-stdout-with-rc-0 assertion is a 3.1c concern alongside the rest of the validate-or-die layer.
- **Not a Phase 1 reproduction.** End-to-end mode reproduction at ≥10 trials per arm (the 2026-05-21 spec's §1+§2) costs ~5M Bedrock tokens. Phase 3.1a uses per-agent as a cheap reproduction substrate; the Phase 1 question is deferred. If the per-agent rate is decisively below the 2/9 observed combined rate, the original spec's question may not need direct end-to-end reproduction — the bug is invocation-shaped and characterised on the cheaper path.
- **Not a multi-specialist sweep.** Same fixture (`ruff-smoke-bad-py`), same agent (`ruff-reviewer`), same arm (Haiku/low) for all 20 trials. Cross-specialist transfer is implied (the bug is invocation-shaped, not specialist-shaped) but not measured.
- **Not a model-axis split.** Phase 3.1 changed both model and effort simultaneously (Sonnet/default → Haiku/low). 3.1a does NOT split that. Splitting axes is a 3.1b concern (ruff cost-tuning resume with richer fixture and separated arms).
- **Not a CI gate.**

## Methodology

### Step 1 — Harness extension: `--output-format stream-json` plumbing

Add an optional flag to `tests/ab/run.sh --mode per-agent`:

- `--stream-json` — pass `--output-format stream-json` to `claude -p`; persist the JSONL trace to `trial-NNN/stream.jsonl` per trial. The original final-text-only stdout still lands in `trial-NNN/stdout.log` (unchanged) so existing parsers and the faithfulness check continue to work bit-identically.

Implementation site: `tests/ab/lib/launch.sh` `launch_run_per_agent_trial` — append the flag conditionally based on a new `_AB_STREAM_JSON=true|false` global propagated from `run.sh` argv. Existing default behaviour is unchanged (`--stream-json` flag absent → pre-3.1a behaviour, unchanged stdout shape).

Empirical confirmation point: before plumbing, run `command claude -p --output-format stream-json --help 2>&1` (or read the live `--help` output) to confirm the exact flag spelling, the JSONL event schema, and whether the final-text-only output is still produced on stdout when stream-json is on (or whether it has to be reconstructed from the JSONL events). Phase 2 hit this kind of CLI-flag empirical-grounding problem at Task 5; the same lesson applies here.

This extension is reusable infrastructure — every future probe (3.1b, 3.2, 3.3, 3.4) can opt into stream-json forensics, and 3.1c's validate-or-die layer is much easier to author when the per-event trace is recoverable.

### Step 2 — 20-trial sweep at Haiku/low against `ruff-smoke-bad-py`

```
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json
```

Each trial produces `trial-NNN/{stdout.log, stderr.log, stream.jsonl, agent-output.md, findings.json, findings_hash.txt, timing.json, system-prompt.md, user-message.txt}`. The faithfulness check is NOT used here — we are measuring incidence, not adoption.

Wall-clock budget: smoke-fixture trials at Haiku/low have run at 20–40s each in the existing run dir (`20260529T144359Z-ruff-haiku-low/timing.json`). 20 sequential trials ≈ 7–14 minutes. Budget for ~20 minutes including the inter-trial 5-second sleep already in `_ab_run_per_agent`.

Cost-aware stop-and-investigate rules (same as Phase 2b's Task 9 Step 6 and Phase 3.1's Task 3 Step 3):

- Per-trial wall-clock above ~60s on the smoke fixture is a smell — capture and inspect; do not silently retry.
- A trial returning INCONCLUSIVE (the `Skipped — ruff not available on PATH.` marker) is a different anomaly entirely (PATH leak in the trial subshell); halt the run for inspection.
- Any underlying-CLI non-zero exit code (rc ≠ 0 from `claude` itself, distinct from the comparison helper) halts the run.
- The empty-stdout occurrences themselves are the SIGNAL we are collecting. They do not halt the run; the loop continues to N=20.

### Step 3 — Per-trial classification

For each of the 20 trials, assign exactly one of these classes:

| Class | Detection rule |
|---|---|
| **EMPTY** | `stdout.log` size ≤ 1 byte AND rc=0 AND `timed_out=false` |
| **DRIFT** | `stdout.log` non-empty AND `agent-output.md` non-empty AND `findings.json` is `[]` (parser-mismatch on present content) |
| **NORMAL** | `findings.json` is non-empty (any number of findings, regardless of hash-match against baseline) |
| **OTHER** | None of the above (timeout, INCONCLUSIVE marker, non-zero rc, etc.) |

Compile counts. Compute Wilson 95% CI for the EMPTY incidence rate.

DRIFT classification is incidental — it is not the question Phase 3.1a is trying to answer, but capturing the count avoids losing data. The format-drift problem is the explicit subject of Phase 3.1c.

### Step 4 — Stream-json trace inspection (per EMPTY trial)

For each EMPTY trial, open `trial-NNN/stream.jsonl` and walk to the last event before session end. Categorise:

| Category | Rule | Maps to original-anomaly hypothesis |
|---|---|---|
| **A** | Last event is a `tool_use` block with no terminating text turn afterwards | Hypothesis 2 (session ends inside tool-use cycle) |
| **B** | Last event is a Bedrock-shaped error or partial-stream marker | Hypothesis 3 (Bedrock API blip) |
| **C** | Last event is a normal text turn with non-empty content, but `stdout.log` shows only `\n` | Hypothesis 1 (CLI emission swallow) |
| **D** | None of the above; trace inconclusive or unreadable | Original spec's "we don't know" residue |

Record category counts. The expectation given the existing 2026-05-21 forensic record (synthesiser produced 158K tokens in Phase 1 Trial 2, but the orchestrator turn was empty) leans towards category A on the end-to-end path. Per-agent trials don't have a synthesiser — so category A on per-agent would imply a different tool-use cycle (the agent reading the static-analysis include? running ruff via Bash? listing a directory via Glob?).

### Step 5 — Probable cause hypothesis + report

Synthesise:

- The numerical incidence rate plus 95% CI.
- The category distribution from Step 4.
- Comparison against the existing Phase 1 Trial 2 forensic record (which has full intermediate artefacts but no stream-json — so it can only contribute to category D in this analysis).

Write a one-page report at `docs/superpowers/notes/2026-XX-XX-empty-stdout-investigation-result.md` with:

- Run dir reference.
- Incidence rate + Wilson 95% CI.
- Category breakdown table (counts per A/B/C/D).
- One-paragraph probable-cause statement.
- Recommended fix surface — to be picked up by Phase 3.1c. Possibilities:
  - CLI-level (upstream `claude` issue).
  - Orchestrator-level safety net in `review-gh-pr/SKILL.md` (only addresses the end-to-end variant).
  - Harness-level guard (validate-or-die in run.sh).
  - Some combination.

### Step 6 — Update the original anomaly spec

Edit `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md`:

- Status line: `Open — anomaly worth investigating` → `Investigated 2026-XX-XX; see notes/2026-XX-XX-empty-stdout-investigation-result.md`.
- Append a "Results" section linking to the Phase 3.1a report and summarising the verdict in 2–3 sentences.
- Leave the original observation, hypothesis space, and cross-references intact — they are durable forensic record.

## Outcomes and what each one unblocks

| Outcome | What 3.1a says | Effect on programme |
|---|---|---|
| **≥3 EMPTY in 20 (15%+ rate)** | Bug is real and reliable on per-agent path; category breakdown points the fix | 3.1c gains a concrete fix surface; 3.1b waits for fix-or-mitigation |
| **1-2 EMPTY in 20 (5-10% rate)** | Bug is real but rare; trace inspection narrows hypothesis space | 3.1c authors the validate-or-die layer; 3.1b proceeds with N≥5 trials per arm to absorb noise |
| **0 EMPTY in 20** | Bug not reliably reproducible at N=20 on this codepath; ≤5% upper bound at 95% CI is acceptable noise floor | Document the bound; bake the empty-stdout assertion into the harness as 3.1c work; proceed to 3.1c then 3.1b without delay |
| **Trace inspection identifies category A on per-agent** | Different tool-use cycle than Phase 1 (no synthesiser); failure mode is "any session that ends mid-tool-use" | Strong signal for a CLI-level fix or harness assertion regardless of rate |
| **Trace inspection identifies category B (Bedrock blip)** | Failure is upstream API-shaped | Programme cannot fix; harness must absorb (validate-or-die at the harness layer becomes load-bearing) |
| **Trace inspection identifies category C (CLI swallow)** | Failure is upstream CLI-shaped | File an upstream Claude Code issue; harness must absorb until upstream fixes |

## Cost expectations

| Step | Tokens | Wall-clock |
|---|---|---|
| Step 1 — harness extension (TDD; one structural test for the new flag) | 0 (offline) | ~30 minutes |
| Step 2 — 20-trial sweep at Haiku/low | ~50–100k | ~10–20 minutes |
| Step 3-4 — classification + trace inspection | 0 (offline) | ~30 minutes |
| Step 5 — report | 0 (offline) | ~15 minutes |
| Step 6 — anomaly spec update | 0 (offline) | ~10 minutes |
| **Total** | **~50–100k** | **~1.5–2 hours** |

Compare with the original 2026-05-21 spec's §1+§2 actions (≥10 baseline + ≥10 no-ultrathink end-to-end trials at ~250k tokens each) which would cost approximately 5M tokens. Phase 3.1a is approximately fifty times cheaper for the same forensic outcome on the per-agent codepath.

## Sequencing within the broader programme

```
Phase 3.1   (PR carrying this spec + plan + handover; Phase 3.1 abandoned-for-cause)
  ↓
Phase 3.1a  empty-stdout reproduction       ← THIS spec; ~50-100k tokens
  ↓
Phase 3.1c  tighten contracts + fail-loud   (its own spec, not yet brainstormed)
  ↓
Phase 3.1b  redo ruff cost-tuning           (its own spec, not yet brainstormed; richer
                                             fixture, separated model+effort axes)
  ↓
Phase 3.2 / 3.3 / 3.4   eslint / trivy / jbinspect, inheriting pinned contracts
                         and characterised anomaly noise floor
```

3.1c is itself a substantial cross-cutting programme item (every model-emitted artefact gets an explicit MUST-shape contract + every consumer validates and fails loudly). It will need its own brainstorm + spec + plan when its turn comes. Phase 3.1a's report names a specific fix surface to seed 3.1c's brainstorming.

## Verifications during implementation

- Confirm the exact `--output-format stream-json` flag spelling and the JSONL event schema before plumbing it into `lib/launch.sh`. Empirically ground from `command claude -p --help` and a small probe trial. Do not transcribe a flag spelling into code from memory.
- Confirm whether `--output-format stream-json` still produces final-text-only stdout on rc-clean exit, or whether the harness must reconstruct the final text by walking the JSONL events. Either is workable; the parser at `lib/agent_capture.sh` reads `stdout.log` so the simplest plumbing is to keep stdout unchanged and dump JSONL alongside it.
- The dirty-tree assertion in `tests/lib/test_ab_harness.sh:550` will fire mid-iteration during the harness extension's TDD cycle (any uncommitted edit elsewhere in the working tree trips it). Commit work in progress before re-running the suite if you see that single test fail; clean HEAD always passes it.

## What we will NOT do (explicit non-actions)

- **No retry-on-empty-stdout in the harness.** That would mask the signal. Empty-stdout trials remain visible in summary.csv as `findings_count=0`.
- **No production agent edits.** `plugins/code-review-suite/agents/ruff-reviewer.md` stays at `model: sonnet`. Same for the other static specialists. Phase 3.1's headline edit was conditional on a positive 3-trial verdict; the verdict was negative-by-cause; no edit ships.
- **No spec change to `2026-05-29-static-specialist-tuning-sweep.md`.** Its methodology is intact for static specialists; only the verdict-shape questions assumed a noise floor that 3.1a is now characterising.
- **No new fixture.** Reuse `ruff-smoke-bad-py` exactly as-is. The single-finding case is not a limitation here — the question Phase 3.1a asks is invocation-shaped, not finding-distribution-shaped.
- **No model / effort sweep.** The 20 trials are all Haiku/low. Cross-arm questions are 3.1b's concern.

## Cross-references

- Original anomaly spec: [`2026-05-21-orchestrator-empty-stdout-anomaly.md`](2026-05-21-orchestrator-empty-stdout-anomaly.md)
- Static-specialist tuning sweep (which 3.1a unblocks): [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)
- Phase 2 plan / chassis: [`../plans/2026-05-28-per-agent-harness-phase-2-plan.md`](../plans/2026-05-28-per-agent-harness-phase-2-plan.md)
- Phase 3.1 plan (abandoned-for-cause; informs the reframe): [`../plans/2026-05-29-static-specialist-tuning-ruff-plan.md`](../plans/2026-05-29-static-specialist-tuning-ruff-plan.md)
- Per-agent testing direction (the framing the whole programme inherits): [`2026-05-21-per-agent-testing-direction.md`](2026-05-21-per-agent-testing-direction.md)
- Phase 3.1c cross-cutting "tighten contracts + fail-loud" — not yet authored; will brainstorm separately after 3.1a's report is in.
- Phase 3.1b ruff cost-tuning resume — not yet authored; will brainstorm separately after 3.1c is settled.
