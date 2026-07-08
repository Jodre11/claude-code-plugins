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
  Escalate) + **1 opus + ultrathink** synthesiser (`review-core.mjs:355,390` — `model: 'opus'`,
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
depth. A **wall-clock** win is *expected* — the win is structural (dropping the serial ~7–8 sonnet
cross fan-out from the critical path; the reason today's synth carries `stallMs: 600000`), not a
claim that a deep opus panel turn is fast — but its magnitude is itself depth-dependent and the
model must quantify it rather than assert it. The token question needs answering before any build.

**Success bar (ranked, agreed during brainstorming):** a token saving is wanted; but if a token
saving conflicts with wall-clock / quality / simplicity, the latter win. An arm that is dearer on
**both** tokens and wall-clock is killed; an arm that is flat-on-tokens but wins big on wall-clock
+ simplicity survives.

**This stage produces the evidence to make that go/no-go decision cheaply — with zero new review
tokens — before committing build effort to any arm.**

## Goal

A standalone cost-model analysis (a script plus a short findings write-up) that predicts
per-arm token spend, wall-clock, and USD from data already on disk, and classifies each arm as
**kill** or **survive-to-A/B** against the ranked success bar (a cost model filters; it cannot
recommend "go" — see decision semantics under What the model computes).

This is an **analysis artifact, not a pipeline change.** It touches no agent, no workflow, no
review behaviour.

## Non-goals

- **No pipeline change.** The panel path, the flag, the Stage-3 writer, and the Step 7a
  instrumentation fix all belong to later stages, not this one.
- **No new review runs.** The model reads existing on-disk data; it does not dispatch agents or
  run reviews. Opus per-turn cost is grounded by harvesting the **real opus-max synth turn** from
  an existing session transcript (`~/.claude/projects/**/*.jsonl`) — the same transcript the
  back-test reads anyway — to anchor a reasoning-depth curve; no *new* opus turn is run.

## Data sources (verified present on disk)

1. **Harness per-turn usage** — `tests/ab/runs/**/trial-*/stream.jsonl`, the `{type:"result"}`
   record. Verified to carry `usage` (`input_tokens`, `output_tokens`,
   `cache_creation_input_tokens`, `cache_read_input_tokens`), `num_turns`, `duration_ms`,
   `duration_api_ms`, and `total_cost_usd` per agent turn. Four run directories currently exist
   (housekeeper + reuse specialists).
   - **Caveat, load-bearing:** these runs are **per-agent, single-specialist** turns, and
     **none are opus**. They ground *sonnet* and *haiku* per-turn costs from real data, and their
     recorded `total_cost_usd` doubles as an end-to-end check on the price×token engine for
     non-opus turns (see Self-validation). No opus turn exists in *this* corpus — but the real
     **opus-max synth** turn is recoverable from a session transcript (source 4), so the **opus
     panelist** cost is an *anchored extrapolation* (a synth-anchored depth curve), not an
     unanchored guess.

2. **Architecture turn-counts** — from the verified pipeline map:
   - Stage 1 full run: 8 core sonnet agentic + up to ~4 conditional (haiku statics +
     sonnet ui/test-quality), ~11 dispatches typical.
   - Cross-review: ~7–8 sonnet re-dispatches (non-static domains only).
   - Synth: 1 opus + ultrathink turn.
   - Resample (when boundary gate fires): +~7–8 sonnet specialists +~7–8 cross +1 opus synth.

3. **Model pricing constants** — externalised (see Parameters), not inlined. **Bedrock** per-model
   input / output / cache-read / cache-creation prices for haiku / sonnet / opus (pin which opus —
   4.8 — and its Bedrock rate). Canonical arm cost = token-counts × this price block. Recorded
   `total_cost_usd` in the harness data is only comparable if it was Bedrock-priced: token counts
   transfer across providers, recorded USD does not — so never fold recorded USD into a recomputed
   arm total (use it only as the engine cross-check in source 1's caveat).

4. **Real opus-max synth turn** — one end-to-end old-path run's session transcript
   (`~/.claude/projects/**/*.jsonl`) carries the actual opus synth `usage` (input / output-incl-
   thinking / cache) and `duration_ms`. This both anchors the opus depth curve (source 1 caveat)
   and is the back-test target (Self-validation). **Precondition:** the plan's first action must
   confirm such a run is recoverable — Step 7a durable logging is known not to be firing, so this
   is not guaranteed and it gates the whole self-validation approach.

## What the model computes

Across a **sweep of representative diff sizes** (small / median / large, drawn from real
`review-gh-pr` history where recoverable, else synthetic bands), compose per-turn costs into
per-**arm** totals. Diff size is swept, not pinned to one PR, because the delta is *not* size-
neutral: `old` ingests the diff across ~7–8 *sonnet* cross turns, the panel across 3–5 *opus*
turns, and opus input is materially dearer — so the panel's input disadvantage grows with diff
size and a single pinned size would hide that flip.

| Arm | Composition |
|---|---|
| `old` | Stage 1 + ~7–8 sonnet cross + 1 opus-max synth, with resample as a probabilistic addend (below) |
| `panel-3` | Stage 1 + 3 opus-high panel (each ingesting brief + diff + all findings) + 1 sonnet writer |
| `panel-5` | Stage 1 + 5 opus-high panel (each ingesting brief + diff + all findings) + 1 sonnet writer |

Since Stage 1 is common to all arms, the model reports both **total** and **delta-from-old**
(the middle-stage change is where all differences live). The distilled concern-brief is a
build-time, drift-guarded artifact (≈0 per-run generation cost), but its **token size is a
first-class ×N opus-input addend** on the panel arms and must appear as a line item, not be
absorbed silently. The `old` resample is **probabilistic**: model it as `P(gate fires) × resample
cost`, or present `old` as an explicit `[no-resample … always-resample]` bracket — and require the
kill/survive call to hold across that bracket.

**Outputs, per arm (per diff-size band):**

- Predicted total tokens (input / output / cache split).
- Predicted wall-clock. The panel win is **structural, not per-turn**: it removes the ~7–8 sonnet
  cross fan-out from the critical path (`old` = cross fan-out → serial opus-max synth long pole;
  panel = parallel opus fan-out → short sonnet writer). Because each opus-high panelist reasons on
  a *larger* prompt than today's synth, the model must derive the panel long pole from the same
  depth parameter and state honestly that at high depth a single parallel panel turn could be flat
  or slower than the synth it replaces — the win is dropping the serial cross stage, not faster
  deep reasoning.
- Predicted USD (token-counts × the Bedrock price block).
- Delta vs `old`, and a **kill / survive-to-A/B** classification per arm (see decision semantics).

**Decision semantics — the model filters, it does not "go":** a cost-only model cannot recommend
"go", because quality and simplicity (which outrank tokens in the ranked bar) are not cost-
observable. Its verdict space is exactly **KILL** (arm is dearer on *both* tokens and wall-clock —
dominated, the bar's kill condition) or **SURVIVE-to-A/B** (not dominated — the later quality A/B
decides it), plus a cost-attractiveness ranking among survivors.

**Honesty requirements — two co-equal unknowable inputs, not one:**

- **Panel reasoning depth.** Parameterise panel per-turn reasoning (thinking + vote output) as
  low / medium / high bands, anchored at the top by the harvested real synth turn (source 4) and
  extrapolated *down* — noting the synth's output *overstates* a panelist's (the synth writes the
  full report; a panelist only votes and may add findings — the sonnet writer writes the report).
  Report a **range**, not a point estimate.
- **Cross-panelist cache sharing.** The panel sends a large shared prefix (brief + full diff + all
  findings) to N opus turns; whether parallel Bedrock dispatches share a warm cache is not
  guaranteed and, at opus input rates, brackets between `1× cache-creation + (N−1)× cache-read`
  and `N× full-price input` — a swing that can dominate the input side. Treat it as a first-class
  ranged input with the same sensitivity treatment as depth.
- **Sensitivity:** report how the kill/survive classification flips across *both* the depth and
  cache-sharing assumptions (and across diff-size bands). A survive that holds only at optimistic
  depth *and* optimistic cache sharing is flagged fragile.

## Model self-validation (how we trust it without running the panel)

- **Precondition (gates everything below):** confirm at least one real end-to-end old-path run is
  recoverable from a session transcript (`~/.claude/projects/**/*.jsonl`). Step 7a durable logging
  is known not to be firing, so this is not guaranteed; if no such run exists the self-validation
  gate cannot run, and that must be surfaced as the primary risk, ahead of any depth estimate.
- **Back-test the known arm:** reconstruct the `old` path's predicted cost from per-turn data and
  check it against that run's actual total. If the model cannot reproduce today's known cost it
  cannot be trusted to predict the panel's. This same transcript yields the real opus-max synth
  `usage` that anchors the opus depth curve (source 4) — the back-test and the opus anchor are the
  same harvest.
- **Engine cross-check (free):** the recorded `total_cost_usd` on the real sonnet / haiku harness
  turns validates the price×token engine end-to-end for non-opus turns, independent of the opus
  estimate. Use it; never mix recorded USD *into* a recomputed arm total.
- **Sensitivity table** as above — the model must expose, not hide, its dependence on the depth
  *and* cache-sharing assumptions across the diff-size sweep.

## Parameters (externalised — no inlined magic constants)

Per the standing lesson that models overlook tuning hooks, every knob lives in one config block
the analysis reads, so the later A/B stage can re-run the model with *measured* depth:

- Per-model **Bedrock** token prices (haiku / sonnet / opus, input / output / cache-read /
  cache-creation); opus pinned to 4.8.
- Per-stage turn counts (Stage 1 core + conditionals, cross count).
- Resample: `P(gate fires)` (or the `[no-resample … always-resample]` bracket).
- Panel N candidates (`3`, `5`).
- Panel reasoning-depth bands (low / med / high thinking+output tokens), with the harvested synth
  turn as the anchoring upper reference.
- Cross-panelist cache-sharing bracket (shared-warm ↔ no-sharing).
- Distilled concern-brief token size (the ×N opus-input addend).
- Diff-size sweep set (small / median / large representative sizes).

## Deliverables

1. A cost-model script (reads harness `stream.jsonl` usage + the parameter block; emits the
   per-arm comparison table). Placed under the suite's analysis/tooling area, not in the
   review path.
2. A short findings write-up: the table, the back-test result, the sensitivity table, and a
   kill / survive-to-A/B classification per arm.

## What happens after this stage

- If **≥1 panel arm survives** the kill filter: proceed to the **panel-build + A/B** stage — its
  own design. That stage builds the panel path behind a flag (the `--no-workflow` R1 rollback
  pattern), fixes Step 7a durable logging as a prerequisite (which maps onto the existing
  per-cog instrumentation design, `2026-06-19-phase-efficacy-instrumentation-design.md`, for
  #63), and runs old-vs-new on the **same real PRs** — capturing tokens, wall-clock, verdict
  agreement, and finding-set delta. That A/B **is** the #63 phase-efficacy and #65 synth-
  validation experiment, closing both.
- If **no arm survives**: the redesign is not worth building for cost; revisit only if the goal
  reweights toward wall-clock/simplicity as the primary win (the ranked bar allows this, but the
  model will have quantified the trade explicitly).
