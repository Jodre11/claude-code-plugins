# Panel-review redesign — cost-model stage design

**Date:** 2026-07-08
**Plugin:** `code-review-suite`
**Tracking:** relates to GitHub issues #63 (phase-efficacy), #64 (per-specialist sweep),
#65 (synthesiser model/effort validation). This is the first, standalone stage of a larger
panel-review redesign; the panel build + A/B are a separate later design.

## Context and motivation

The `review-gh-pr` pipeline's token spend and wall-clock time are excessive enough to make
the maintainer a key token user in the organisation, with knock-on cost for others who have
adopted the skill. The question is whether a radically different second-stage structure can
hold review quality while cutting spend, timeouts, and wall-clock wait.

The proposed redesign (scoped in full during brainstorming, built in later stages) replaces
the two expensive middle stages of `workflows/review-core.mjs`:

- **Today:** ~7–8 **sonnet** cross-reviewers (heterogeneous per-domain Agree/Disagree/
  Escalate) + **1 opus + ultrathink** synthesiser (`review-core.mjs:355,386` — `model: 'opus'`,
  `stallMs: 600000`), plus a variance-resampling round 2 when the boundary gate fires.
- **Proposed:** a panel of **N (3 or 5, odd) identical Principal-Engineer opus panelists**,
  each primed with a distilled amalgamated concern-set + the full diff + all Stage-1
  findings; each votes every finding (real / minor / not-a-problem) **and** may raise new
  cross-cutting findings; followed by a **cheap sonnet writer** (no ultrathink) that tallies
  votes into spread-derived confidence, dedups panel-added findings, computes the verdict via
  the existing rubric, and writes the report + sealed bundle.

Stage 1 (haiku static specialists + sonnet agentic specialists) is unchanged. The sealed-bundle
contract `{verdict, bodyText, comments[]}` is unchanged, so the host skill and the Class D
posting filter are untouched.

The redesign collapses three current mechanisms — heterogeneous cross-review, variance-
resampling round 2, and the synth's per-source dissent-budget confidence arithmetic — into one
panel construct: independent draws *are* the resampling, vote spread *is* the confidence signal,
the panel *is* the cross-cutting review.

## The problem this stage solves

Whether the redesign actually **reduces token spend** is not obvious. With the panel at
opus-high the arithmetic inverts relative to the maintainer's original "cheaper panel"
intuition:

- Deleted: ~7–8 sonnet cross-review turns + the opus-max synth's deep reasoning + the resample.
- Added: N opus-high deep-reasoning turns on large prompts (concern-set + full diff + all findings).

The result could be a saving, a wash, or an increase, depending on N and per-panelist reasoning
depth. A robust **wall-clock** win is expected regardless (N panelists run in *parallel*, vs
today's serial 2min+ opus-max synth long pole — the reason `stallMs` is 600000), but the token
question needs answering before any build.

**Success bar (ranked, agreed during brainstorming):** a token saving is wanted; but if a token
saving conflicts with wall-clock / quality / simplicity, the latter win. An arm that is dearer on
**both** tokens and wall-clock is killed; an arm that is flat-on-tokens but wins big on wall-clock
+ simplicity survives.

**This stage produces the evidence to make that go/no-go decision cheaply — with zero new review
tokens — before committing build effort to any arm.**

## Goal

A standalone cost-model analysis (a script plus a short findings write-up) that predicts
per-arm token spend, wall-clock, and USD from data already on disk, and recommends go/no-go per
arm against the ranked success bar.

This is an **analysis artifact, not a pipeline change.** It touches no agent, no workflow, no
review behaviour.

## Non-goals

- **No pipeline change.** The panel path, the flag, the Stage-3 writer, and the Step 7a
  instrumentation fix all belong to later stages, not this one.
- **No new review runs.** The model reads existing on-disk harness data; it does not dispatch
  agents or run reviews. (Grounding opus per-turn cost is done from pricing + a reasoning-depth
  parameter, not by running opus.)
- **No decision on N or panel model.** The model *informs* that choice by pricing candidate
  arms; the actual production setting is resolved by the later A/B on real quality data.

## Data sources (verified present on disk)

1. **Harness per-turn usage** — `tests/ab/runs/**/trial-*/stream.jsonl`, the `{type:"result"}`
   record. Verified to carry `usage` (`input_tokens`, `output_tokens`,
   `cache_creation_input_tokens`, `cache_read_input_tokens`), `num_turns`, `duration_ms`,
   `duration_api_ms`, and `total_cost_usd` per agent turn. Four run directories currently exist
   (housekeeper + reuse specialists).
   - **Caveat, load-bearing:** these runs are **per-agent, single-specialist** turns, and
     **none are opus**. They ground *sonnet* and *haiku* per-turn costs from real data. The
     **opus panelist** and the **opus-max synth** per-turn costs must be *estimated* (opus
     pricing × a reasoning-depth parameter), because no opus ground-truth turn is on disk.

2. **Architecture turn-counts** — from the verified pipeline map:
   - Stage 1 full run: 8 core sonnet agentic + up to ~4 conditional (haiku statics +
     sonnet ui/test-quality), ~11 dispatches typical.
   - Cross-review: ~7–8 sonnet re-dispatches (non-static domains only).
   - Synth: 1 opus + ultrathink turn.
   - Resample (when boundary gate fires): +~7–8 sonnet specialists +~7–8 cross +1 opus synth.

3. **Model pricing constants** — externalised (see Parameters), not inlined. Bedrock per-model
   input/output/cache token prices for haiku / sonnet / opus.

## What the model computes

For a representative diff size, compose per-turn costs into per-**arm** totals:

| Arm | Composition |
|---|---|
| `old` | Stage 1 + ~7–8 sonnet cross + 1 opus-max synth (+ resample variant) |
| `panel-3` | Stage 1 + 3 opus-high panel + 1 sonnet writer |
| `panel-5` | Stage 1 + 5 opus-high panel + 1 sonnet writer |

Since Stage 1 is common to all arms, the model reports both **total** and **delta-from-old**
(the middle-stage change is where all differences live).

**Outputs, per arm:**

- Predicted total tokens (input / output / cache split).
- Predicted wall-clock, accounting for the structural difference: `old` has a serial opus-max
  synth long pole after the cross fan-out; the panel arms have a parallel panel fan-out then a
  short sonnet writer.
- Predicted USD.
- Delta vs `old`, and a **go/no-go recommendation** per arm against the ranked bar.

**Honesty requirements (the panel's reasoning depth is the one unknowable input):**

- Parameterise panel per-turn reasoning as low / medium / high reasoning-token assumptions and
  report a **range**, not a point estimate.
- **Sensitivity:** report how the go/no-go verdict flips across the depth assumptions. A "go"
  that holds only at optimistic depth is flagged as fragile.

## Model self-validation (how we trust it without running the panel)

- **Back-test the known arm:** reconstruct the `old` path's predicted cost from per-turn data
  and check it against at least one real end-to-end old-path run's actual total (from a CLI
  session transcript, `~/.claude/projects/**/*.jsonl`). If the model cannot reproduce today's
  known cost, it cannot be trusted to predict the panel's — this is a gating check on the model
  itself.
- **Sensitivity table** as above — the model must expose, not hide, its dependence on the depth
  assumption.

## Parameters (externalised — no inlined magic constants)

Per the standing lesson that models overlook tuning hooks, every knob lives in one config block
the analysis reads, so the later A/B stage can re-run the model with *measured* depth:

- Per-model token prices (haiku / sonnet / opus, input / output / cache-read / cache-creation).
- Per-stage turn counts (Stage 1 core + conditionals, cross count, resample multiplier).
- Panel N candidates (`3`, `5`).
- Panel reasoning-depth assumptions (low / med / high output-token bands).
- Representative diff size / cache-hit assumptions.

## Deliverables

1. A cost-model script (reads harness `stream.jsonl` usage + the parameter block; emits the
   per-arm comparison table). Placed under the suite's analysis/tooling area, not in the
   review path.
2. A short findings write-up: the table, the back-test result, the sensitivity table, and a
   go/no-go recommendation per arm.

## What happens after this stage

- If **≥1 panel arm survives** go/no-go: proceed to the **panel-build + A/B** stage — its own
  design. That stage builds the panel path behind a flag (the `--no-workflow` R1 rollback
  pattern), fixes Step 7a durable logging as a prerequisite (which maps onto the existing
  per-cog instrumentation design, `2026-06-19-phase-efficacy-instrumentation-design.md`, for
  #63), and runs old-vs-new on the **same real PRs** — capturing tokens, wall-clock, verdict
  agreement, and finding-set delta. That A/B **is** the #63 phase-efficacy and #65 synth-
  validation experiment, closing both.
- If **no arm survives**: the redesign is not worth building for cost; revisit only if the goal
  reweights toward wall-clock/simplicity as the primary win (the ranked bar allows this, but the
  model will have quantified the trade explicitly).
