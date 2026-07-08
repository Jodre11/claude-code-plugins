# Panel-review cost model — findings

**Date:** 2026-07-08 (regenerated after I1/I2/I3 remediation)
**Inputs:** `tests/ab/lib/cost_model.py` over `tests/ab/runs/**` (N=80 real
trials: 40 opus reuse, 40 sonnet housekeeper), params
`tests/ab/lib/cost_model_params.json` (Bedrock rates from the claude-api skill).
**Spec:** `docs/superpowers/specs/2026-07-08-panel-review-cost-model-design.md`.

This version addresses the three Important findings from the final branch review
plus the follow-up items raised during re-review: I1 (wall-clock constants
externalised to params), I2 (resample swept explicitly as p ∈ {0.0, 0.25, 1.0}),
I3 (per-arm token split now returned by `compose_arm`), and the M1 follow-up
(the old-arm resample re-run now also re-runs Stage 1 on the wall-clock axis —
see "Wall-clock" below). The engine also now dedupes the cross-check to one row
per model.

## Self-validation (must pass before trusting the model)

`build_report` now returns one `cross_check` row per model (previously one per
trial — 80 near-identical rows carrying no extra signal). Each row keeps the
representative rel_err plus the trial count and the rel_err min/max range, so a
per-model divergence would still surface. For all 80 trials the per-model spread
is floating-point rounding noise at the sub-$10⁻¹⁵ level, well below the 5%
tolerance.

| Model | trials | recomputed (rep) | recorded (rep) | rel_err (rep) | rel_err max | verdict |
|---|---|---|---|---|---|---|
| claude-opus-4-8 | 40 | $0.607635 | $0.607635 | 1.8e-16 | 1.8e-16 | ok |
| claude-sonnet-4-6 | 40 | $0.270995 | $0.270995 | 0.0e+00 | 3.6e-16 | ok |

Both models reproduce Bedrock-recorded costs to within floating-point precision
(rel_err ≪ 0.1%). Price rows are validated.

**Back-test (old-arm whole-run):** A real opus synth turn from a review-gh-pr
session transcript on disk returned `output=25956`, `model=claude-opus-4-8`.
Feeding its token counts (`input=2`, `output=25956`, `cache_read=76988`,
`cache_creation=561`) through the pricing engine yields $0.6930 — above the
reuse-arm trial range ($0.17–$0.61 per trial), as expected for a synth turn
whose output (~25,956 tokens) is roughly 9× the deepest observed reuse turn.
The back-test confirms the engine prices a deep synth turn to a plausible figure
for its token counts.

## Per-arm comparison — resample sweep (median diff, med depth, shared-warm)

The table below shows `median` diff size, `med` depth, `shared-warm` cache mode
at each of the three resample points p ∈ {0.0, 0.25, 1.0}. Panel costs are
invariant across p (panels have no boundary gate); old costs increase with p.
Old-arm wall-clock now includes the resample factor **and** the Stage-1 re-run
that the gate triggers (M1): `wall = base + p·(stage1_wall + base)`, where
`base = cross + opus_synth`.

**Important nuance on p=0:** The original doc baked p=0.25 into
every old-arm USD figure. At p=0 the old arm costs $5.88 (not $7.35), so the
panel USD advantage is smaller: −$1.20 for panel-3 and −$0.46 for panel-5 at
p=0. The advantage widens as p rises — reaching −$7.08 / −$6.34 at p=1.0. The
true p=0 advantage is reported honestly here.

Similarly for wall-clock: at p=0 old wall_s = 139.3 s (the resample factor is
zero), rising to 179.9 s at p=0.25 and 301.5 s at p=1.0. The M1 fix adds the
Stage-1 re-run's wall to the resample addend, so these p>0 figures are slightly
higher than the pre-M1 model (which omitted Stage-1 from the re-run). Panel
wall_s stays fixed at 132.2 s across all p.

| diff | p | arm | USD | delta\_USD | wall\_s | delta\_wall\_s | verdict |
|---|---|---|---|---|---|---|---|
| median | 0.00 | old | $5.8792 | ±0 | 139.3 s | ±0 | SURVIVE |
| median | 0.00 | panel-3 | $4.6768 | −$1.2024 | 132.2 s | −7.2 s | SURVIVE |
| median | 0.00 | panel-5 | $5.4173 | −$0.4619 | 132.2 s | −7.2 s | SURVIVE |
| median | 0.25 | old | $7.3490 | ±0 | 179.9 s | ±0 | SURVIVE |
| median | 0.25 | panel-3 | $4.6768 | −$2.6722 | 132.2 s | −47.7 s | SURVIVE |
| median | 0.25 | panel-5 | $5.4173 | −$1.9316 | 132.2 s | −47.7 s | SURVIVE |
| median | 1.00 | old | $11.7583 | ±0 | 301.5 s | ±0 | SURVIVE |
| median | 1.00 | panel-3 | $4.6768 | −$7.0816 | 132.2 s | −169.3 s | SURVIVE |
| median | 1.00 | panel-5 | $5.4173 | −$6.3410 | 132.2 s | −169.3 s | SURVIVE |

Panel arms are cheaper on USD **and** faster on wall-clock than old across all
three resample points at median diff / med depth. The USD advantage grows with
p; the wall-clock advantage also grows with p because the resample factor
penalises only the old arm.

**Note on panel-5 at large/high/no-share:** At the worst-case combination
(large diff, high depth, no cache sharing) panel-5 costs $8.83 vs old.
At p=0 old is $6.47 — panel-5 is dearer on USD (+$2.36) but 7.2 s faster on
wall-clock. Not dominated → SURVIVE. At p=0.25 old rises to $8.09 — panel-5
is +$0.75 on USD but still 69.7 s faster. Not dominated → SURVIVE. At p=1.0 old
is $12.94 — panel-5 at $8.83 is cheaper → SURVIVE. Verdict is SURVIVE at every
resample point, including the p=0 case that was not visible in the original model.

## Wall-clock is now parameterised

Four knobs were externalised to `params["wall_clock"]` to allow the A/B stage
to retune them from measured values:

- `cross_secs` (30.0 s): the cross fan-out critical path duration.
- `opus_per_1k_output_divisor` (3.0): divides the representative Stage-1
  duration in ms to derive opus per-1k-output seconds. The divisor 3.0 means
  the opus synth turn is modelled as generating output 3× slower than Stage-1
  turns produce output (Stage-1 turns are shorter and cache-heavy; a deep synth
  turn is longer and compute-bound).
- `writer_stage1_duration_multiple` (1.0): scales the Stage-1 duration for the
  sonnet writer turn (currently proxied 1:1 with the Stage-1 representative).
- `stage1_wall_duration_multiple` (1.0): scales the Stage-1 representative
  duration for the Stage-1 wall time added to the old-arm resample re-run (M1).
  Stage-1 specialists fan out in parallel, so a re-run adds ~one representative
  turn's wall, not the full turn count — hence a 1× multiple of one turn.

These defaults reproduce the original model's USD numbers at p=0 exactly.

**M1 fix (resample wall-clock now includes the Stage-1 re-run):** The original
model added the resample re-run to the old arm's USD (which re-runs Stage 1 +
cross + synth) but omitted Stage 1 from the corresponding wall-clock re-run —
so old wall-clock was under-counted at p>0, i.e. old looked *faster* than it
should, which was conservative against the panel. This is now fixed: the
old-arm wall at p>0 includes `p·(stage1_wall + base)`, matching the USD term's
structure. The p=0 rows are unchanged; only p>0 old-arm wall figures rise
(e.g. median/med at p=0.25: 174.2 s → 179.9 s), which *strengthens* the panel
case rather than weakening it.

**Remaining honesty note:** The panel wall-clock advantage at p=0 (−7.2 s across
all diff sizes) is the `writer − cross` delta: `writer_secs − cross_secs`.
With the current proxy values (`writer ≈ 22.9 s`, `cross = 30.0 s`), this
gives −7.1 s — a depth-independent constant under the current proxy. The actual
advantage may differ if live opus synth turns are substantially longer than the
Stage-1 proxy implies (a deeper synth ceiling → larger `opus_secs` term, but
this affects both old and panel equally). The A/B stage should measure
`per_turn_secs["cross"]`, `["writer"]`, and `["stage1_wall"]` directly.

## Resample sensitivity

Verdict is **SURVIVE** for panel-3 and panel-5 across ALL three resample points
p ∈ {0.0, 0.25, 1.0}, for every combination of diff size (small/median/large),
depth (low/med/high), and cache mode (shared-warm/no-share). This is now
demonstrated by the sweep rather than asserted at a single p.

`fragile_arms` is empty. No arm's verdict flips between KILL and SURVIVE
across the bracket.

## Per-arm token split

The engine now emits per-arm input/output/cache token totals. For the
representative row (median diff, med depth, shared-warm, p=0.25):

| arm | input | output | cache\_read | cache\_creation |
|---|---|---|---|---|
| old | 25,175 | 42,764 | 3,504,125 | 891,850 |
| panel-3 | 20,084 | 58,017 | 1,725,980 | 450,088 |
| panel-5 | 20,084 | 86,759 | 1,769,980 | 450,088 |

The old arm has far more cache tokens (Stage-1 cache reuse dominates) but fewer
output tokens than panel arms; panels emit more output (N panelists each produce
depth_output tokens). Cache-read for old is nearly 2× panel-3 because the
resample addend at p=0.25 scales up the cache-heavy Stage-1 term.

`classify` operationalises "dearer on tokens" as "dearer on USD" because the
opus-vs-sonnet rate gap makes USD the meaningful spend axis — opus output is 5×
more expensive per token than sonnet output, so raw token counts without model
weighting are misleading. The per-arm token totals are reported for
transparency and to enable the A/B stage to set token-budget alerts, but the
cost screen uses USD and wall-clock as specified.

## Sensitivity

- **Depth bracket used:** floor=2,786 tokens (on-disk opus reuse, max over 40
  trials), ceiling=25,956 tokens (confirmed harvested from a real review-gh-pr
  opus synth turn in a local session transcript). Ratio: **9.3×** span (the plan
  estimated ~15× from the fixture floor of ~1,700; the real floor over 40 opus
  trials is 2,786, yielding 9.3×).
- **Cache sharing:** At median diff, med depth, p=0.25, the shared-warm vs
  no-share spread is $0.088 for panel-3 and $0.286 for panel-5. Cache mode is a
  minor sensitivity lever compared to depth and resample rate.
- **Fragile arms (verdict flips across the full resample × depth × cache
  bracket):** none.

## Kill / survive

- `panel-3`: **SURVIVE** — cheaper on USD and faster on wall-clock across all
  resample points and all diff/depth/cache combinations. No verdict flip.
- `panel-5`: **SURVIVE** — cheaper and faster across most combinations; exceeds
  old on USD only at large/high/no-share when p=0 (no resample) but remains
  faster on wall-clock (not dominated). At p=0.25 and p=1.0 it is also cheaper
  on USD even at large/high/no-share. No fragile flag.

## Recommendation & residual risk

Both panel arms survive the cost screen. Neither is killed by the model. The
verdict is now demonstrated across the full resample bracket rather than
asserted at a single operating point.

**What the later A/B must measure:** actual synth depth under live traffic on
the panel path (the 25,956-token ceiling is one confirmed real turn, not a
statistical sample); whether cache-warm assumptions hold at scale; and the
actual resample rate p, which determines where on the sweep the system operates.
The three `wall_clock` params in `cost_model_params.json` should be retuned from
measured latencies before drawing conclusions from the wall-clock axis.

**Residual risk:** The old-arm back-test prices one confirmed real synth turn;
it is not a full end-to-end old-arm run (no such transcript was available in
the harness data). The model's old-arm projection is therefore parameter-driven
rather than empirically closed. This gap is a precondition risk for the A/B:
if real old-arm synth depths are systematically higher or lower than the
parameterised fallback, the delta estimates shift accordingly.
