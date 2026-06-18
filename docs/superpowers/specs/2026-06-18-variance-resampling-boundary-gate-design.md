# Variance-Resampling on a Boundary Gate — Design

**Date:** 2026-06-18
**Plugin:** `code-review-suite`
**Status:** Approved (brainstorming), pending spec review

## Problem

A full PR review (`/code-review-suite:review-gh-pr 571`) returned APPROVE with one
Suggestion. Another run of the *same pipeline* — submitted by reviewer `dotnetAL` —
returned CHANGES_REQUESTED with four Important findings. The two runs reached opposite
verdicts on identical input.

Post-incident analysis, verified against source, localised the cause to three layered
defects:

1. **Root cause — specialist recall variance.** `review-core.mjs` dispatches each
   stochastic specialist exactly once (`parallel()` over the fixed list, line ~162). A
   single stochastic draw never *generated* the whitespace-asymmetry finding (#4) or the
   duplicate-predicate finding (#2); a different draw did. Recall on a single sample is a
   draw from a distribution with wide spread near the verdict boundary.

2. **Amplifier — pro-cyclical APPROVE filter.** Under APPROVE the orchestrator suppresses
   sub-75-confidence findings from posting (`isPosted()`, line ~306; posting policy in
   `verdict-rubric.md`). A low-recall run is *more* likely to land on APPROVE, so the
   engine hides its own thin output precisely when output is thinnest.

3. **Architectural gap — verified prior ignored.** Self-re-review mode reacts only to the
   *current user's* prior review; other reviewers' findings are fetched solely for dedup,
   never fed to the synthesiser to verify-or-refute. Adjudicating a prior claim is exactly
   what the engine is good at, and the architecture declined to use it.

A single pipeline run is not reproducible enough to be authoritative on a borderline PR.

## Goal

Raise recall and verdict stability for **generic** full reviews (the common case: reviewed
once, no external prior), at a cost proportional to the actual variance/risk of each PR —
not a flat tax on every review.

## Non-goals

- **Prior-ingestion** (feeding other reviewers' findings to the synthesiser). Most PRs have
  no external prior, so its generic value is near zero; it also carries anchoring/sycophancy
  and prompt-injection risk. Multi-sample is the *generic* form of "cross-check against a
  verified prior" (cross-check against your own resamples). Deferred as an optional later
  enhancement for multi-reviewer PRs, behind trust-boundary handling.
- **Resampling deterministic specialists.** Static analysers (`jbinspect`, `eslint`,
  `ruff`, `trivy`) and the registry-backed `housekeeper` engine produce identical output
  per run; resampling them is pure waste.
- **Resampling the synthesiser.** Resampling the adjudicator reintroduces the
  non-determinism we are removing from its inputs.
- **Lowering the inline-posting bar.** We do not start posting sub-75 findings as inline
  comments; the 75-bar exists to suppress low-confidence noise.
- **Model-tier changes.** The 10 stochastic specialists currently run on Sonnet. This
  design is tier-agnostic and does not change the model.

## Scope of resampling

The split already exists in `review-core.mjs:182`:

```js
const STATIC = new Set(['jbinspect', 'eslint', 'ruff', 'trivy', 'housekeeper'])
```

**Resampled (10 stochastic LLM specialists):** `security`, `correctness`, `consistency`,
`style`, `archaeology`, `reuse`, `efficiency`, `alignment` (the 8 core), plus the two
conditional LLM specialists `ui` and `test-quality` — and only those present for the given
PR's detection flags.

**Single-run (unchanged):** the 5 deterministic specialists above; cross-review (operates
on already-aggregated data — single pass per round); the opus synthesiser (the adjudicator).

## Cost model (verified)

Investigation correction: the diff is **not** embedded in `$AGENT_PROMPT`
(SKILL.md:813–824). The prompt carries only base branch, head SHA, intent ledger, and a
*changed-lines block* (file:line numbers). Each specialist **fetches the diff itself** via
its own tool calls inside the subagent (SKILL.md:863). Consequences:

- There is **no orchestrator-assembled shared diff prefix** to cache across the parallel
  dispatches. The heavy token load (file reads, diff hunks) is generated independently
  inside each agent and is already non-shared today.
- A resample therefore pays close to **full freight** — there is no caching discount to
  bank on. This argues *for* gating rather than a flat 2× tax.
- Estimated marginal cost of one extra stochastic sweep on a ~548-line PR:
  **~$0.80–2.00**, scaling up with the number of files each agent must read.

Boundary gating concentrates this spend on genuinely borderline PRs (~a minority of full
reviews) and adds ~$0 to clean-cut reviews.

## Design

### 1. Flow (full path only)

```
Round 1:  dispatch 10 stochastic (×1) + static (×1) → cross → synth
              │
              ▼
        boundary gate?  ── no ──▶  bundle (unchanged, 1× cost)
              │ yes
              ▼
Round 2:  re-dispatch the 10 stochastic (2nd independent draw)
          union + agreement-count vs round 1
              │
              ▼
        cross (single pass over unioned findings) → synth (agreement counts as input) → bundle
```

- Lightweight path: untouched (never resamples).
- `local`/pre-review mode: gate never fires (no verdict to be near a boundary).
- Round 2 re-dispatches **only** the stochastic specialists; static findings from round 1
  are reused verbatim (deterministic — re-running would produce identical output).
- Cross-review and synth run **once per round**, not resampled.

### 2. Boundary predicate (when round 2 fires)

Intent: "would one finding moving slightly flip the verdict?" The gate reads the
synthesiser's **structured** output (`verdict`, `rubricRowApplied`, tier classification,
per-finding `severity`/`confidence`) — no prose parsing. Fire round 2 when **any** of:

- **B1.** Verdict APPROVE **and** ≥1 *consensus* Important finding with confidence in
  **[60, 80)** — just under rubric row 3's 70 line, or in the 70–75 post-suppression band
  (the incident's shape).
- **B2.** Verdict APPROVE **and** ≥1 *contested*-tier finding the synth declined to
  promote (if real, it could fire rubric row 1/2/3).
- **B3.** Verdict REQUEST_CHANGES driven **solely** by a single Important finding at
  confidence **[70, 80)** — symmetric: do not request changes on a shaky single draw.

Skip round 2 (1× cost) when none fire: a strong APPROVE with nothing borderline, or
REQUEST_CHANGES on a Critical / high-confidence (≥80) Important / multiple corroborating
Important findings.

The boundary bands are the most tunable knob: too wide fires round 2 too often (cost); too
narrow misses borderline cases (recall). Initial bands [60,80) / [70,80) are a starting
point to be confirmed during validation.

### 3. Union + agreement mechanics

Mechanical clustering in-code; semantic merge left to the opus synthesiser (its existing
cross-domain dedup role).

- Cluster round-1 and round-2 findings by **same file + line within ±3 lines** (cheap,
  in-code; reuses the proximity approach already used for deletion anchors).
- Attach an **agreement count** per cluster: `2` = both draws found it, `1` = single draw.
- Feed the synthesiser the unioned set *with* agreement counts. It performs the final
  semantic merge and treats `2/2` as corroboration, `1/2` as single-source — a real
  multi-sample signal replacing a single run's self-reported confidence guess.
- **Agreement is advisory to the synthesiser, not a hard mechanical confidence floor.** The
  synth weighs it alongside its own judgement; we do not mechanically clamp confidence by
  agreement count. (Decision recorded: advisory, per design discussion.)

**Schema change:** `FINDING_SHAPE` gains one optional field `agreement` (integer). Omitted
in round-1-only output and on the lightweight path. The synthesiser schema/prompt learns to
read it. Because the finding schema is inlined (sandbox cannot resolve `$ref` — Phase 0
spike R2-B) and shared via the `FINDING_SHAPE` const, the parity test that flattens the
canonical `#/$defs/finding` must be updated in lockstep.

### 4. De-pro-cyclical honesty

The boundary gate absorbs most of the amplifier: a thin APPROVE with borderline findings now
*triggers a second draw* instead of shipping silently. The residual change is **disclosure,
not posting volume**:

- When APPROVE suppresses sub-75 findings, the posted body gains one disclosure line:
  *"N finding(s) below the posting threshold — see synthesiser report."*
- This ensures an APPROVE never *looks* cleaner than the run actually was.
- We do **not** post sub-75 findings as inline comments (preserves the 75-bar's noise
  suppression).

### 5. Components touched

- **`workflows/review-core.mjs`** — the bulk: boundary-gate predicate, round-2 re-dispatch
  of the stochastic subset, clustering + agreement-count computation, `agreement` field on
  `FINDING_SHAPE`, disclosure-line addition in `buildBody`.
- **`agents/review-synthesiser.md`** — prompt learns to read `agreement` as a corroboration
  signal; output unchanged in shape.
- **`includes/verdict-rubric.md`** — document the disclosure line in the posting policy;
  the rubric rows themselves are unchanged.
- **Parity/structural tests** — update the finding-schema parity test for the new
  `agreement` field; add gate-behaviour coverage.

## Testing & validation

Per the suite's independent-A/B-sweep culture:

1. **Incident replay.** Re-run PR #571 through the new path. Round 2 **must** fire (B1/B2)
   and the union **must** recover the duplicate-predicate (#2) and whitespace-asymmetry (#4)
   findings, flipping the verdict toward REQUEST_CHANGES.
2. **No-regression on clean PRs.** n≥10 sweep on a clean-cut PR: the gate must **not** fire
   (confirming no cost regression on the common case) and the verdict must stay stable
   across runs.
3. **Schema parity.** The finding-schema parity test passes with the new `agreement` field.
4. **Gate-band sensitivity.** Spot-check that the [60,80)/[70,80) bands fire on borderline
   inputs and skip on decisive ones; adjust bands if the incident replay or clean sweep show
   mis-calibration.

## Open knobs (to confirm during implementation/validation)

- Boundary bands [60,80) / [70,80) — confirm against incident replay + clean sweep.
- ±3-line clustering window — confirm it merges genuine duplicates without collapsing
  distinct adjacent findings.
- Whether B2 (contested-tier presence) fires too eagerly on PRs with many low-value
  contested findings; may need a confidence floor on the contested trigger.

## Cost envelope summary

- Clean-cut full reviews: **+$0** (gate does not fire).
- Borderline full reviews: **+~$0.80–2.00** (one extra stochastic sweep, no caching
  discount).
- Lightweight / local / pre-review paths: **unchanged**.
