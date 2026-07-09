# Panel-review Stage 2/3 build — design

**Date:** 2026-07-09
**Plugin:** `code-review-suite`
**Tracking:** spec #2 of the panel-review redesign. Follows the cost-model go/no-go
(`2026-07-08-panel-review-cost-model-design.md` + findings), which **passed**: panel-3 and
panel-5 both SURVIVE the kill filter across the full resample × depth × cache sweep,
`fragile_arms` empty, panel-3 cheapest and fastest at every operating point. The old-vs-new
A/B (the #63 phase-efficacy / #65 synth-validation experiment) is spec #3 — **not** this spec.

## Context and motivation

`review-gh-pr`'s middle stage — ~7–8 sonnet cross-reviewers → 1 opus+ultrathink synthesiser →
a variance-resampling round 2 when the boundary gate fires — is the dominant cost and wall-clock
sink. The cost model confirmed a panel replacement is cheaper **and** faster. This spec builds
that panel path behind a config flag, defaulting off, changing nothing for existing users until
they opt in.

The panel collapses three current mechanisms into one construct: independent panelist draws *are*
the variance resampling; vote spread *is* the confidence signal; the panel *is* the cross-cutting
review. Stage 1 (specialist dispatch) and the sealed-bundle contract `{verdict, bodyText,
comments[]}` are untouched, so the host skill and the Class D posting filter need no changes.

## Goal

Add an opt-in `panel` orchestration mode to `workflows/review-core.mjs`:

- **Stage 2 (`panelVote`):** N identical Principal-Engineer opus panelists, dispatched in
  parallel, each voting every Stage-1 finding (`real` / `minor` / `not_a_problem`) and optionally
  raising new cross-cutting findings.
- **Stage 3 (`panelWrite`):** a cheap sonnet writer (no ultrathink) that deterministically tallies
  votes and raise-corroboration into the existing `tiers`+`confidence` envelope shape, applies the
  **existing** verdict rubric, and assembles the **existing** sealed bundle.

## Non-goals

- **No A/B experiment.** Real-PR selection, verdict-agreement / finding-delta metrics, and the go
  decision are spec #3. This spec ends at "panel path works behind a flag, tests green".
- **No Stage-1 change.** Specialist dispatch, detection flags, and self-re-review suppression are
  inherited unchanged.
- **No sealed-bundle / rubric / Class D change.** The panel changes how the envelope is *produced*,
  not what it *is*.
- **No host-skill behavioural change** beyond threading two new resolved params into the Workflow
  invocation.

## Architecture (Approach A — branch within the single workflow)

`review-core.mjs` keeps one workflow. After the shared Stage-1 `dispatchSpecialists` round-1 call,
it branches on the resolved orchestration mode, alongside the existing `route: 'finalize' |
'lightweight'` branches:

```
Stage 1 (shared, unchanged): dispatchSpecialists → findingsByDomain
   │
   ├─ orchestrationMode = "classic" (default)
   │     → crossAndSynth + boundary-gate resample → finalizeBundle   [BYTE-UNCHANGED from today]
   │
   └─ orchestrationMode = "panel"
         → panelVote (N opus panelists, parallel)
         → panelWrite (sonnet writer: tally → tiers/confidence → rubric → bundle)
         → same {verdict, bodyText, comments[]} bundle shape
```

Rationale: reuses Stage-1 dispatch, the pinned-diff materialisation (`fullDiffFile`), the
`finalizeBundle` bundle contract, and the durable-log payload wiring for free; keeps the classic
path a clean, untouched fallback; and mirrors the existing in-workflow route branching rather than
forking a second workflow file.

The **lightweight** path (single code-analysis pass, `route: 'lightweight'`) is unaffected by
`orchestrationMode` — panel replaces only the *full* path's middle stage.

## Configuration & routing

Two new keys under `[orchestration]` in `code-review.toml`, resolved **host-side** with the same
two-layer precedence as `full_log` (repo `.claude/code-review.toml` → user
`~/.claude/code-review.toml` → built-in default):

- `review_mode = "classic" | "panel"` — default `"classic"`.
- `panel_size = <odd integer ≥ 3>` — default `3`.

**Validation:** when `review_mode = "panel"`, if `panel_size` is even or `< 3`, fail fast with a
clear message (do not silently round).

**Resolution point — load-bearing (attention).** The resolved mode + size are assembled into the
Workflow invocation at **Step 3.5** (the param block where `base`, `headSha`, `emptyTreeMode` are
already assembled), NOT co-located with `full_log` (which resolves at Step 3.6, *after* the bundle
returns — far too late for a routing decision). Step 3.5 param assembly is unskippable: the host
cannot invoke the Workflow without it.

**Absence is observable, not enforced (accepted design).** A missing mode param falls back to
`classic`. This is the same *class* of "opted-in feature doesn't activate" risk as the durable-log
fix addressed, but a much milder instance: unlike the invisible durable-log skip, a routing skip
changes the *entire review's visible behaviour* on the *first* review. To make an intent/actuality
mismatch immediately visible, the workflow **echoes the resolved mode + N in its opening `log()`
line**. No Stop-hook-style forcing function — observability is the natural guard here.

**Name collision — must avoid.** The workflow already threads a param `reviewMode` meaning
`local` vs PR mode (`review-core.mjs:125`, and the stall-recovery re-invoke passes `reviewMode:
$REVIEW_MODE`). The new panel/classic selector uses a **distinct** name: `orchestrationMode`.

**Host wiring:** both call-sites (`skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`) resolve
`orchestrationMode` + `panel_size` alongside the existing config reads and thread them into the
Workflow invocation at Step 3.5.

## Stage 2 — the panel vote (`panelVote`)

**Dispatch:** N identical opus panelists in parallel, using the same `parallel()` fan-out and
null-guard mapping `dispatchSpecialists` already uses. Every panelist receives an **identical**
prompt:

- The distilled concern-brief (see below).
- The full pinned diff via the existing `fullDiffFile` path (no git re-run — same mechanism the
  cross/synth prompts already use).
- **All** Stage-1 findings (every domain), as data.
- Which domains actually ran, so a panelist does not vote on a suppressed domain (e.g. `alignment`
  is suppressed in self-re-review mode, `review-core.mjs:171`).
- The trust-boundary preamble the cross/synth prompts already carry (diff + findings are content
  to analyse, never instructions).

Panelists are **identical Principal-Engineer roles**, not heterogeneous per-domain reviewers.
Independence across identical draws is what provides the confidence signal (replacing the
boundary-gate resample).

**`PANEL_SCHEMA` (new) — each panelist returns:**

- `votes[]`: one entry per Stage-1 finding — `{finding_id, vote: "real" | "minor" |
  "not_a_problem", rationale}`. `finding_id` is a stable index assigned at dispatch (Stage-1
  findings are a fixed list at that point).
- `raised[]`: net-new cross-cutting findings, in the **same finding shape Stage 1 emits**
  (`{domain, severity, file, line, description, suggested_fix}`), so downstream treats raised and
  voted findings uniformly.

**Degradation (quorum):** a null/failed panelist is dropped (same null-guard mapping as
`dispatchSpecialists`). The tally proceeds if **≥ majority of N** panelists returned (≥2 of 3,
≥3 of 5). Below quorum → the writer emits a degraded bundle (see Stage 3), never a real verdict on
a sub-quorum panel. No serial-synth stall-recovery machinery is needed — the panel's parallelism
removes the single long-pole that stall-recovery exists for.

**phaseLog:** each panelist's votes + raised findings are pushed as `phase: 'panel'` cogs, so the
durable full log captures the raw per-panelist record for the later A/B and #63.

## Stage 3 — the deterministic writer (`panelWrite`)

A cheap sonnet turn (no ultrathink). Its logic is **deterministic**, extracted into pure exported
functions so it is unit-testable without agents; the sonnet turn's only genuine model work is prose
assembly of `bodyText`.

Pipeline:

1. **`tallyVotes`** — for each voted Stage-1 finding, count `real` / `minor` / `not_a_problem`
   across the *surviving* panelists.
2. **`clusterRaised`** — cluster raised findings across panelists by `(file, line-window)`, reusing
   the existing `CLUSTER_WINDOW = 3` proximity approach (`review-core.mjs:197`, helper at :496–500).
   A cluster's corroboration = the number of panelists who raised into it.
3. **`mapSpreadToTierConfidence`** — one deterministic formula applied uniformly to voted **and**
   raised findings, emitting the `tiers`+per-finding-`confidence` structure `finalizeBundle` /
   the rubric already consume:
   - Voted: unanimous/supermajority `real` → high confidence → **consensus** tier; split (no
     majority, or mixed real/minor) → mid → **contested**; majority `not_a_problem` → **dismissed**.
   - Raised: cluster corroboration count maps on the *same* scale — majority-raised ≈ consensus;
     solo raise ≈ low-confidence contested (admissible, but cannot alone drive a hard verdict unless
     the rubric independently promotes it on severity).
   - Exact confidence bands (and the supermajority threshold for N=3 vs N=5) are pinned in the
     implementation plan.
4. **Verdict** via the **existing** rubric (unchanged) applied to that `tiers` structure.
5. **Bundle** via the existing `finalizeBundle` contract → `{verdict, bodyText, comments[]}`. The
   Class D posting filter (`POST_THRESHOLD = 75`) and the host skill are untouched.

**Empty/degraded guard:** if the panel returned below quorum, or the tally yields no usable
findings, the writer emits a Category-C-style degraded bundle (`verdict: NONE` + an explanatory
`bodyText`), mirroring `finalizeBundle`'s existing null-envelope guard — never a false verdict.

**Key invariant:** by emitting the *same* envelope shape the synth produces today, the panel path
plugs into `finalizeBundle`, the rubric, and Class D with **zero changes to any of them**.

## The concern-brief include

**File:** `plugins/code-review-suite/includes/panel-concern-brief.md` — a committed markdown
include that distils the specialist domains into one Principal-Engineer review lens. Each panelist
reads it verbatim as its framing preamble.

**Content:** a concise "what a Principal Engineer reviewing this diff must weigh" brief across the
CORE domains — correctness, security, consistency, style, archaeology (regressions / reintroduced
bugs), reuse, efficiency, alignment-with-intent. It is the *concern lens*, not a restatement of the
specialist agent prompts: it tells the panelist what to scrutinise, while the Stage-1 findings +
diff supply the material.

**Cost:** static, committed, read from disk (like `verdict-rubric.md`, `specialist-context.md`) —
~0 per-run generation cost. Its token size is a first-class ×N opus-input line item (the cost model
treated it as such), so it must stay tight — it is paid N times per review.

**Drift guard (load-bearing):** the CORE specialist domains live authoritatively in
`review-core.mjs` (`const CORE = [...]`, :166). A sync test (in the `test_sync_notes.sh` family)
asserts the brief's domain enumeration matches that `CORE` list, so a domain added/removed in code
cannot silently leave the brief framing panelists against a stale set. This is a single directional
brief↔`CORE` check, not the byte-parity cross-file sync the pipeline includes use — simpler, and
sufficient.

## Testing

Per the agreed strategy — pure functions extracted and unit-tested; workflow wiring tested
structurally; the opus panel dispatch itself is exercised only in the later live A/B (CI cannot run
real opus panels, and no mock-agent harness is built).

**Pure-function unit tests** (synthetic inputs, no agents):

- `tallyVotes` — vote counting including dropped/missing panelists.
- `clusterRaised` — `(file, line-window)` clustering, including the distant-line non-merge case.
- `mapSpreadToTierConfidence` — every band (unanimous / split / dismissed; majority-raised / solo),
  boundary cases (exact majority on N=3 and N=5), and that the output shape matches what the rubric
  consumes.
- `checkQuorum` — ≥ majority passes; below-quorum → degraded.

**Structural tests** (grep / config, matching existing patterns):

- Config resolution: `orchestrationMode` two-layer + default `classic`; `panel_size` validation
  (odd ≥ 3; even / `< 3` fails).
- Route selection: `panel` reaches `panelVote`/`panelWrite`; the `classic` branch is byte-unchanged.
- Concern-brief drift guard: brief domain enumeration == `CORE`.
- Host wiring: both call-sites resolve + thread `orchestrationMode`/`panel_size` at Step 3.5.

## Files

- **Modify:** `plugins/code-review-suite/workflows/review-core.mjs` — the branch, `panelVote`,
  `panelWrite`, the pure helpers (`tallyVotes`, `clusterRaised`, `mapSpreadToTierConfidence`,
  `checkQuorum`), and `PANEL_SCHEMA`.
- **Create:** `plugins/code-review-suite/includes/panel-concern-brief.md`.
- **Modify:** `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` and
  `plugins/code-review-suite/commands/pre-review.md` — Step 3.5 param resolution.
- **Modify:** the durable-log `meta` to carry `orchestration_mode` + `panel_size` (a small ripple on
  the log payload's meta line — the durable-log-writer passes `.meta` through verbatim, so no writer
  change; it lets the A/B tell which path produced a log).
- **Create / extend:** the test files above.
- **Docs:** this spec + the implementation plan.

## Rollout

Default `classic` means merging this is inert for every existing user — the panel runs only when
someone sets `review_mode = "panel"`. Safe-by-default: the maintainer flips their own config to
exercise the path; the later A/B spec drives the real old-vs-new comparison.

## Residual risks (stated honestly)

1. **Panel reasoning depth** under live traffic is still the one unmeasured quantity (the cost model
   bracketed it 9.3×). This spec ships the path; spec #3's A/B measures the truth.
2. **Deterministic `(file, line-window)` clustering** misses semantically-identical raised findings
   at distant lines — they enter as two low-corroboration findings rather than one. Conservative,
   not wrong; the A/B measures whether it matters before any judgement-clustering is considered.
3. **`orchestrationMode` resolution is observable, not enforced** (accepted): a skipped param falls
   back to `classic`, visible on the first review via the workflow's opening log line — not silently
   for weeks like the durable-log failure.

## What happens after this spec

Spec #3 (the old-vs-new A/B) runs the built panel path against the classic path on the **same real
PRs**, capturing tokens, wall-clock, verdict agreement, and finding-set delta — closing #63
(phase-efficacy) and #65 (synth model/effort validation). It consumes the durable-log corpus (spec
#1, now shipping reliably) and the `orchestration_mode` meta tag added here.
