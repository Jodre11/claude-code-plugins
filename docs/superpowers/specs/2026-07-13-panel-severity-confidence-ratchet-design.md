# Panel review — separate severity from realness, mechanical ratchet

**Date:** 2026-07-13
**Status:** design (awaiting review)
**Supersedes fragments of:** `2026-07-09-panel-review-build-design.md`, `2026-07-10-panel-classic-ab-design.md`

## Problem

The panel arm of the code-review orchestrator systematically under-blocks. In the
2026-07-13 A/B pilot against `HavenEngineering/finance-erp-apps` PR #98, the panel
returned APPROVE on 2 of 3 trials where classic returned REQUEST_CHANGES on 3 of 3 — on
identical code — and the divergence was traced to the panel vote schema, not review
quality or capture.

### Root cause: the vote token re-fuses two axes classic separated

The current `PANEL_SCHEMA` (`workflows/review-core.mjs:104`) has each panelist cast a
single `vote: real | minor | not_a_problem` per Stage-1 finding. That token fuses two
orthogonal judgements:

- **realness** — is this a true issue or a false positive? (epistemic)
- **severity** — how much does it matter? (Critical / Important / Suggestion)

A panelist who believes a finding is genuine but low-stakes has no honest token — they
must vote `minor`, which the tally reads as *less real*. The consensus tier
(`mapSpreadToTierConfidence:664`) only counts `real` supermajorities, and `applyRubric`
(`:682`) only blocks on the consensus tier. So severity doubt leaks into the realness
tally, the consensus tier stays empty, and the rubric falls through to APPROVE.

Evidence from the pilot (184 votes across three trials):

| vote value | count | share |
|---|---|---|
| `minor` | 136 | 74% |
| `not_a_problem` | 45 | 24% |
| `real` | 3 | 1.6% |

97/136 (71%) of `minor` votes carried rationales explicitly affirming the finding was
real ("Real observability gap", "Genuine consistency nit"). Panelists were voting `minor`
on **severity** while affirming **realness** in prose. 51 findings across the three trials
drew unanimous `minor` — every panelist agreed the finding was genuine — yet each scored
zero consensus-tier credit.

**This is the exact severity/confidence conflation the classic pipeline already engineered
out** by making `severity` and `confidence` independent fields in `FINDING_SHAPE`
(`review-core.mjs:34-44`) and leaving their combination to a mechanical rubric. The panel
schema regressed it.

## Design principle

> **Deterministic findings get deterministic protection; stochastic findings get
> stochastic scrutiny.**

A finding's exposure to panel re-interpretation is scaled to how much interpretation it
involved in the first place. Static-analysis output (a tool fired a rule) is objective
data — the panel may only express *doubt about applicability*, within a bounded envelope,
and can never re-rate its severity. LLM-specialist findings are themselves judgement
calls, so they are open to the panel's judgement in return.

The panelists emit **two separate honest opinions and do no arithmetic**. All combining,
thresholding, and ratcheting is mechanical, in the rubric — mirroring classic, where the
agent reports raw `severity` + `confidence` and the code decides.

## New panelist output (`PANEL_SCHEMA` change)

Replace `votes[].vote` (the fused enum) with two independent fields. Per Stage-1 finding,
each panelist emits:

| field | type | meaning |
|---|---|---|
| `finding_id` | integer | unchanged — index into the flattened Stage-1 list |
| `is_real` | boolean | true issue vs false positive — **purely epistemic**, independent of importance |
| `severity` | enum `Critical \| Important \| Suggestion` | the panelist's own honest severity opinion |
| `blocks_goal` | boolean | unchanged — shows the stated goal is not achieved |
| `rationale` | string | unchanged |

The concern brief (`includes/panel-concern-brief.md`) is rewritten to instruct: *judge
realness and severity as two separate questions; do not do any threshold arithmetic; a
real-but-minor finding is `is_real: true, severity: Suggestion`.*

## Mechanical combining rule — two tracks

Let `N` = number of surviving panelists (quorum rules unchanged, `checkQuorum:618`).

### Track A — LLM-specialist findings

Domains: `security`, `correctness`, `consistency`, `style`, `archaeology`, `reuse`,
`efficiency`, `alignment` (any finding **not** carrying a static-analysis source tag).

1. **Realness → confidence ratchet.** Start at the Stage-1 specialist's `confidence`.
   Confidence step = `ceil(31 / N)`. The gate is `≥ 70`, so to push a specialist-100
   finding *below* the gate the unanimous drop must exceed 30 — hence a span of 31 (target
   69), not 30 (which lands exactly on 70 and still blocks). Subtract one step for each
   panelist voting `is_real: false`. Result is confidence-anchored: a finding the specialist
   was already unsure about falls more easily; a specialist-100 finding needs unanimous
   `is_real: false` to cross below 70.
2. **Severity → notch ratchet (symmetric).** Map severity to a level:
   `Suggestion = 1, Important = 2, Critical = 3`. Start at the specialist's level.
   **Only `is_real: true` panelists vote on severity** — a panelist who called the finding
   not-real abstains from the notch (a severity opinion on a finding you judged a false
   positive is incoherent; realness is that panelist's honest signal, and it is already
   counted by the confidence ratchet in step 1). `upVotes` = `is_real: true` panelists
   rating strictly higher than the specialist; `downVotes` = `is_real: true` panelists
   rating strictly lower. The divisor stays `N` (surviving panelists), **not** the
   real-only count: abstentions shrink the achievable swing, so a finding half the panel
   thinks is unreal cannot also be severity-upgraded by the other half to a full level.
   `effectiveLevel = clamp(specialistLevel + (upVotes − downVotes) / N, 1, 3)`.
   The notch size is `1/N`, so **unanimous (all-real) agreement in one direction = exactly
   one full level**. Upgrades are allowed and can promote a Suggestion into a blocking
   Important.
3. **Block decision** (classic AND gate): the finding blocks iff
   `round(effectiveLevel) ≥ 2` (≥ Important) **AND** effective confidence `≥ 70`.

   *Spec-author choice (open to review):* `effectiveLevel` is rounded to the nearest
   integer level for the gate, so it takes a **net majority** of directional votes to move
   a finding across a level boundary — a single dissent among 3 does not knock an Important
   down (`2 − 1/3 = 1.67 → rounds to 2`), but two of three does (`2 − 2/3 = 1.33 → 1`).
   Because `N` is a validated **odd** integer, `(upVotes − downVotes) / N` can never equal
   exactly `0.5` (that needs `2·(up−down) = N`, impossible for odd `N`), so `effectiveLevel`
   never lands on a half-integer and no tie-break rule is reachable — do **not** add a
   `.5`-boundary test case, it would be dead. Standard nearest-integer rounding suffices.

### Track B — static-analysis findings

Source tags: `[eslint]`, `[ruff]`, `[trivy]`, `[jbinspect]`, `[housekeeper]`. Honours the
existing classic §10 contract (`includes/static-analysis-context.md:147`) verbatim, with
the step re-gauged for panel size:

1. **Severity is LOCKED.** The Track-A severity notch ratchet does **not** apply. The
   tool's mapped severity is authoritative; no panel override.
2. **Confidence-only ratchet.** Start at 100 (per §6). Confidence step = `ceil(50 / N)`
   (the 100→50-floor span is 50 — the panel is the N-source analogue of classic's 9
   cross-review sources, where the step was 5 for 9 sources). Subtract one step per
   panelist voting `is_real: false` (or, equivalently, downgrade dissent). Clamp:
   `confidence = max(50, 100 − Σsteps)`. Never raised above 100.
3. **Block decision.** Same AND gate as Track A, but with the locked severity: the finding
   blocks iff the tool's **locked** severity is `≥ Important` **AND** the ratcheted
   confidence is `≥ 70`. Only the confidence side moves under panel dissent; severity never
   does.
4. **Never dismissed.** Static findings land only in `consensus` or `contested`. A
   floor-50 finding with heavy dissent lands in `contested`, never `dismissed`.
5. **Housekeeper** keeps its distinct delivery model (§10 housekeeper paragraph):
   uniform `Suggestion`, rendered to the `## Dependency Freshness` table, not
   verdict-affecting, with the single sanctioned escalation break-out unchanged.

### Step sizing summary

| ratchet | span | step (N=3) | step (N=5) | unanimous result |
|---|---|---|---|---|
| Track A realness → confidence | 100→69 | `ceil(31/3)=11` | `ceil(31/5)=7` | crosses below 70 |
| Track A severity → level | 1 level | `1/3` per vote | `1/5` per vote | one full level |
| Track B static confidence | 100→50 | `ceil(50/3)=17` | `ceil(50/5)=10` | clamps at 50 |

## Tier mapping (feeds existing writer + `differential.py` unchanged)

`mapSpreadToTierConfidence` is rewritten to emit the same four-key envelope from the new
per-finding outcome:

- Track A, blocks (severity ≥ Important AND confidence ≥ 70) → **`consensus`**
- Track A, real but non-blocking → **`contested`**
- Track A, majority `is_real: false` → **`dismissed`**
- Track B (static), blocks → **`consensus`**; otherwise → **`contested`** (never `dismissed`)
- `synthesiser` tier remains `[]` in panel mode

**`blocks_goal` is still tallied and stamped, unchanged.** `applyRubric` row 1
(goal-not-achieved) reads `consensus.some(f => f.blocks_goal)` (`review-core.mjs:684`), so
the rewritten `mapSpreadToTierConfidence` MUST keep counting the per-finding `blocks_goal`
panel majority and stamp it onto each emitted finding, exactly as the current code does
(`review-core.mjs:667`, `blocks_goal: tally.blocks_goal > s / 2`). The two-track ratchet
changes only how *tier* and *confidence* are derived; the `blocks_goal` flag rides through
untouched. Omitting it would silently disable rubric row 1.

`applyRubric` is unchanged — it keeps acting on the `consensus` tier, which is now
populated by the ratchet outcome rather than a near-impossible `real` supermajority.

## `raised[]` (net-new panelist findings)

Out of scope. `raised[]` findings have no Stage-1 specialist severity to anchor the
ratchet on; they keep the existing corroboration path (`clusterRaised:642`,
`mapSpreadToTierConfidence:669-674`). Folding raised findings into the two-track model is
a possible follow-up, flagged here, not built now.

## Panel size

`panelSize` remains a validated odd integer ≥ 3 (`review-pipeline.md:944`). The ratchet
steps derive from `N` (surviving panelists), so 3 and 5 both work with no constant to
retune. Choice of default (3 vs 5) is an operational tuning question for the follow-up
A/B, not a schema constraint.

## Scope of change

- `PANEL_SCHEMA` (`review-core.mjs:104`) — replace `vote` enum with `is_real` + `severity`.
- `tallyVotes` (`:623`) — tally `is_real` counts, collect per-panelist severity opinions
  (from `is_real: true` panelists only — non-real votes abstain from the severity notch),
  and keep tallying `blocks_goal` unchanged.
- `mapSpreadToTierConfidence` (`:658`) — replace the `real/minor/not_a_problem` tiering with
  the two-track ratchet (source-tag dispatch, confidence + severity ratchets, tier mapping);
  keep stamping the `blocks_goal` panel majority onto each finding so `applyRubric` row 1
  still fires.
- `includes/panel-concern-brief.md` — rewrite vote instructions to "two separate opinions,
  no maths"; state the `is_real` / `severity` split explicitly.
- New unit tests (TDD, red→green): step sizing for N=3 and N=5; confidence-anchored
  asymmetry (spec-100 needs unanimous, weaker falls to majority); severity notch semantics
  (unanimous-real = one full level; `is_real: false` panelists abstain from the notch);
  static-analysis lock + floor-50 + never-dismissed; realness majority veto; `blocks_goal`
  still drives rubric row 1. **No `.5`-boundary rounding test** — unreachable for odd `N`.
- `applyRubric` — unchanged.

## Out of scope / deferred

- **Panelist independence.** The pilot showed same-model panelists converging (trial-002:
  three panelists produced finding-by-finding identical votes with differently-worded
  rationales — genuine independent generation, but correlated conclusions). Diverse models
  / temperatures to decorrelate the panel is a separate concern; this design fixes the
  schema conflation, which stands regardless of independence.
- **`raised[]` two-track treatment** (above).
- **Re-running the A/B.** Validating the fix against PR #98 (and a lighter contrast PR) is
  the natural follow-up once implemented.

## Non-goals

- No change to classic. `applyRubric`, `FINDING_SHAPE`, the classic synth path, and the
  static-analysis §10 contract for classic are untouched.
- No LLM arithmetic. Panelists never compute thresholds, steps, or tiers.
