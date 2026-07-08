# Panel-review cost model — findings

**Date:** 2026-07-08
**Inputs:** `tests/ab/lib/cost_model.py` over `tests/ab/runs/**` (N=80 real
trials: 40 opus reuse, 40 sonnet housekeeper), params
`tests/ab/lib/cost_model_params.json` (Bedrock rates from the claude-api skill).
**Spec:** `docs/superpowers/specs/2026-07-08-panel-review-cost-model-design.md`.

## Self-validation (must pass before trusting the model)

The `cross_check` list has one entry per trial (80 total). For this table, rows
are deduped to one representative per model; all cross-check rows for a given
model are numerically identical (only floating-point rounding noise at the
sub-$10⁻¹⁵ level, well below the 5% tolerance).

| Model | recomputed (representative) | recorded (representative) | rel_err | verdict |
|---|---|---|---|---|
| claude-opus-4-8 | $0.607635 | $0.607635 | 1.8e-16 | ok |
| claude-sonnet-4-6 | $0.270995 | $0.270995 | 0.0e+00 | ok |

Both models reproduce Bedrock-recorded costs to within floating-point precision
(rel_err ≪ 0.1%). Price rows are validated.

**Back-test (old-arm whole-run):** A real `review-gh-pr` opus-max synth turn on
disk returned `output=25956`, `model=claude-opus-4-8`. Feeding its token counts
(`input=2`, `output=25956`, `cache_read=76988`, `cache_creation=561`) through
the pricing engine yields $0.6930 — above the reuse-arm trial range ($0.17–$0.61
per trial), as expected for a synth turn whose output (~25,956 tokens) is roughly
9× the deepest observed reuse turn. The back-test confirms the engine prices a
deep synth turn to a plausible figure for its token counts.

## Per-arm comparison (delta vs old)

Representative rows at each diff size, `med` depth, `shared-warm` cache mode.
`old` delta is always $0 by definition; all depths and cache modes shown in the
full `--json` report.

| diff\_size | arm | USD | delta\_USD | wall\_s | delta\_wall\_s | verdict |
|---|---|---|---|---|---|---|
| small | old | $7.2490 | ±0 | 139.3 s | ±0 | SURVIVE |
| small | panel-3 | $4.4528 | −$2.7962 | 132.2 s | −7.2 s | SURVIVE |
| small | panel-5 | $5.1773 | −$2.0716 | 132.2 s | −7.2 s | SURVIVE |
| median | old | $7.3490 | ±0 | 139.3 s | ±0 | SURVIVE |
| median | panel-3 | $4.6768 | −$2.6722 | 132.2 s | −7.2 s | SURVIVE |
| median | panel-5 | $5.4173 | −$1.9316 | 132.2 s | −7.2 s | SURVIVE |
| large | old | $7.7240 | ±0 | 139.3 s | ±0 | SURVIVE |
| large | panel-3 | $5.5168 | −$2.2072 | 132.2 s | −7.2 s | SURVIVE |
| large | panel-5 | $6.3173 | −$1.4066 | 132.2 s | −7.2 s | SURVIVE |

Panel arms are cheaper on tokens **and** faster on wall-clock than old across
small→large diffs at medium depth. The token advantage shrinks as diff size
grows (large diffs charge more opus input cost per panelist), but remains
material even at large.

**Note on panel-5 at large/high/no-share:** At the worst-case combination
(large diff, high depth, no cache sharing), panel-5 costs $8.83 vs old $8.09
— dearer on tokens — but is still faster on wall-clock (−7.2 s). It is
therefore not dominated and remains SURVIVE.

## Sensitivity

- **Depth bracket used:** floor=2,786 tokens (on-disk opus reuse, max over 40
  trials), ceiling=25,956 tokens (confirmed harvested from a real review-gh-pr
  opus synth turn). Ratio: **9.3×** span (the plan estimated ~15× from the
  fixture floor of ~1,700; the real floor over 40 opus trials is 2,786, yielding
  9.3×).
- **Cache sharing:** At median diff, med depth, the shared-warm vs no-share
  spread is $0.088 for panel-3 and $0.286 for panel-5. Cache mode is a minor
  sensitivity lever compared to depth.
- **Fragile arms (verdict flips across brackets):** none. All three arms return
  SURVIVE across every combination of diff size (small/median/large), depth
  (low/med/high), and cache mode (shared-warm/no-share).

## Kill / survive

- `panel-3`: **SURVIVE** — cheaper on tokens (−$2.67 at median diff/med depth)
  and faster on wall-clock (−7.2 s) across all brackets. No verdict flip.
- `panel-5`: **SURVIVE** — cheaper on tokens and faster across most brackets;
  exceeds old on tokens only at large/high/no-share but remains faster on
  wall-clock (not dominated). No fragile flag.

## Recommendation & residual risk

Both panel arms survive the cost screen. Neither is killed by the model. The
depth bracket is grounded by a real harvested synth ceiling (25,956 tokens);
the floor (2,786 tokens) is the maximum observed on-disk opus reuse output.
The 9.3× floor→ceiling span is the primary sensitivity surface — a deeper
synth turn would push panel costs up proportionally, but even at ceiling depth
both panel arms remain cheaper or faster than old.

**What the later A/B must measure:** actual synth depth under live traffic on
the panel path (the 25,956-token ceiling is one confirmed real turn, not a
statistical sample) and whether cache-warm assumptions hold at scale.

**Residual risk:** The old-arm back-test prices one confirmed real synth turn;
it is not a full end-to-end old-arm run (no such transcript was available in
the harness data). The model's old-arm projection is therefore parameter-driven
rather than empirically closed. This gap is a precondition risk for the A/B:
if real old-arm synth depths are systematically higher or lower than the
parameterised fallback, the delta estimates shift accordingly.
