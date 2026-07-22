# Latent-hazard specialist — design

**Date:** 2026-07-22
**Issue:** [#114](https://github.com/Jodre11/claude-code-plugins/issues/114) — Panel `is_real`
vote is binary; conflates hallucination filter with stochastic-hazard likelihood.
**Status:** design approved, pending spec review → implementation plan.

## Context

A retrospective quality A/B ran the five core `code-review-suite` specialists standalone against
commit `cf9bc9d` of `HavenEngineering/finance-erp-apps` PR #158 — the exact commit an external
reviewer ("Marlon") reviewed with his own tool — and scored our output against his five findings.
Result: **caught 2/5, missed 3/5**. The two caught were structural/coverage gaps (test-adequacy on
`MarginExtractBuilder`, test-quality on an AND-across-columns filter). The three missed were all
judgement-heavy: the **ZB61 silent-failure** in `MarginReportReader.cs`, and a pair of comment-truth
findings.

The ZB61 miss is the archetype this design targets. The A&L sub-department column is read
*optionally* (missing → `""`) rather than *required* (throw). If ZB61 is ever absent from A&L output
(report-layout drift, or the path const duplicated in `MarginReportFilter` edited but not here),
every A&L row's sub-department **silently blanks to `""`, which reads as the legitimate value
`000 = None`** — wrong data shown to finance, no error. The mechanism is unconditionally present in
the code; whether it *bites* is conditional; when it bites it fails *silently*.

Our correctness specialist stood on the exact line and did **not** raise this. It raised a
*different, false* concern ("verify the `IsDescription` guard is present" — the guard is present at
`MarginReportReader.cs:82`), and its own prose hedged: *"I cannot see the full body… this may already
be handled."* Its true internal state was **uncertain**, but it laundered that into a confident-
sounding Important that was actually a coin-flip.

### Why origination, not adjudication

Issue #114 frames the loss at the **panel `is_real` vote** — the binary gate at
`review-core.mjs:847` (`is_real_false > is_real_true → dismissed`) has nowhere honest to land a
conditional hazard, so a conscientious panellist routes it to `not_real`. That analysis is correct
and remains open. **But this design deliberately fixes the layer upstream of it.** The panel only
ever grades what it is handed; the ZB61 case never reached the panel as a well-stated finding at all
— it was an **origination** failure. Fixing origination is the higher-leverage first move: a
well-stated silent-conditional finding gives the (still-binary) panel something it can adjudicate
honestly, and lets us measure whether origination *alone* closes the gap before we redesign the vote.

**Explicitly deferred (tracked in #114 and its comment, plus #61/#62):** the `is_real` binary
redesign, the two-orthogonal-axes (impact × trigger/likelihood) proposal, and the aggregation-end
work. Revisited only if origination proves insufficient.

## Decision summary

| Question | Decision |
|---|---|
| Which layer to change | **Origination first** — teach a specialist to *raise* the hazard crisply. |
| Where the capability lives | A **dedicated Stage-1 specialist** (`latent-hazard-reviewer`). |
| Relationship to correctness | **Carve out + hand off** — silent/conditional moves out of correctness; single owner. |
| Dispatch model | **Conditional**, gated on the existing `flags.production` (as `test-adequacy`). |
| Panel / rubric changes | **None** — deferred (see above). |
| Validation | **Re-score the same `cf9bc9d` case** against Marlon's 5; target **2/5 → 3/5**. |

## Section 1 — The specialist's charter

**Agent:** `latent-hazard-reviewer` (working name).

**Charter (one sentence):** detect defects whose *mechanism is unconditionally present in the changed
code* but whose *manifestation is conditional* on a future or external state, and which fail
**silently** (wrong data / data loss, no error signal) when the condition is met.

A finding is in-scope only when **all three** hold — this triple is the anti-flood discipline:

1. **Mechanism present now** — the hazardous code is in the diff, not hypothetical. (This is the
   origination-time analogue of the future `is_real` "does the mechanism exist?" gate.)
2. **Concrete named trigger** — the reviewer must state the *specific* condition that makes it bite
   (ZB61: "if the A&L sub-department column is ever absent — layout drift, or the duplicated path
   const in `MarginReportFilter` edited but not here"). **No concrete trigger → not a finding.** You
   cannot rate a hazard "conditional" without naming the condition; that requirement is what starves
   speculative "if X ever changes…" noise.
3. **Silent / integrity impact** — when it fires it yields wrong results or data loss with **no error
   signal** (ZB61: the blank silently reads as the legitimate value `000 = None`). A conditional path
   that *throws loudly* is out of scope — correctness owns that.

**Load-bearing behavioural mandate — trace before you raise.** The specialist must follow the
mechanism to ground (read the called code, confirm optional-vs-required reads, walk duplicated
constants across files) **before** emitting. Specialists already have `Read`/`Grep` over the whole
repo and read unchanged context freely; only their *output* is changed-line-filtered. If the trace is
inconclusive, the specialist says so honestly and **does not launder uncertainty into a confident
finding** — the exact failure mode that produced the false ZB61-adjacent Important. A finding it
cannot substantiate by tracing is not raised.

## Section 2 — Carve-out from the correctness reviewer

Today `correctness-reviewer.md:79` owns "silent failure paths" as one clause inside eight focus
areas. That buried clause is what got skipped on ZB61. The carve-out makes ownership a partition, not
an overlap.

**Correctness keeps** — deterministic bugs that fire on the path as written, and *loud* error-handling
bugs: logic errors, off-by-one, null/undefined deref, races, resource leaks, type mismatches,
async pitfalls, and error paths that are simply wrong. Its "error handling gaps" bullet keeps the loud
cases; the long "silent failure paths" residue (a path that emits nothing observable) **moves out**.

**Latent-hazard takes** — the silent **and** conditional class: a present mechanism that fails
silently only when a named trigger fires.

**The dividing line, stated reciprocally in both agent files:**
- Fires **every time** the path runs, **or** fails **loudly** → **correctness**.
- Fires **only under a named condition** *and* fails **silently** → **latent-hazard**.

**Deterministic-and-silent stays with correctness.** A silent failure that fires every time (an
always-taken empty `catch`) is *not* conditional, so it does not route to latent-hazard. The
"conditional" leg is the router. This means a truly deterministic silent failure now has a single
owner rather than two sets of eyes — an accepted trade (double-ownership is what let ZB61 fall between
stools); the panel's raised-finding clustering (`sameCluster`) remains a backstop, not the design.

## Section 3 — Pipeline wiring

Mirrors how `test-adequacy` was added (commit 251050b) — the proven template.

**Dispatch registration** (`workflows/review-core.mjs`, `CONDITIONAL` list ~L244-253):
- Add `['latent-hazard', flags.production]`. Gated on `flags.production`
  (`$PRODUCTION_SOURCE_DETECTED`, computed in `review-pipeline.md` Step 4 ~L899 and passed to the
  Workflow ~L1011). Latent hazards only live in production source, so this skips doc/test/config-only
  PRs at zero coverage cost. **No new detection logic** — the flag is reused verbatim.

**Cross-review membership** (`review-core.mjs` `NON_CROSS` set ~L268):
- Add `latent-hazard` to `NON_CROSS`. Like `test-adequacy` and `api-contract`, it is an LLM
  specialist with no cross-review-mode contract and is not severity-locked. Its findings are still
  *shown to* every cross-reviewer (so correctness can Agree/Disagree/Escalate on them); it simply
  does not *receive* a cross-review pass. This keeps the carve-out honest — the two specialists see
  each other's output at the cross-review stage even though they do not overlap at origination.
- Update the explanatory comment at ~L262-268 to name the new `NON_CROSS` member.

**Downstream is automatic** — `panelVote(flat, …, allSpecialists)` (~L291) already iterates
`allSpecialists`; the panel votes latent-hazard findings, the rubric grades them, cross-review sees
them. **No schema change**: latent-hazard emits the standard finding shape (File / line / Severity /
Confidence / Description / Suggested fix), coerced by the `agent()` schema param like every LLM
specialist.

**Files touched in this section:**
- `workflows/review-core.mjs` — `CONDITIONAL` list + `NON_CROSS` set + comment.
- `includes/review-pipeline.md` — Step 4 conditional-dispatch prose registry (mirrors the code).
- `agents/latent-hazard-reviewer.md` — **new** agent file (structure per `test-adequacy-reviewer.md`).
- `agents/correctness-reviewer.md` — remove the silent-failure clause; add the reciprocal boundary note.
- `.claude-plugin/plugin.json`, `README.md` — register/document the new agent (the structural test
  suite checks these are populated).

**Deliberately NOT touched:** `includes/panel-concern-brief.md`, `includes/verdict-rubric.md`,
`includes/severity-definitions.md`. The first two are the deferred adjudication redesign. The third is
shared by all 18 specialists — shifting its bar is out of scope and risky (see Section 4).

## Section 4 — Severity calibration and validation

### Severity calibration (in the agent prompt, not the shared file)

The specialist rates by the standard `severity-definitions.md` ladder, but the carve-out exposes a
tension: line 15 requires an Important-class defect to be observable "during normal use — **not only
under contrived or theoretical conditions**." A conditional hazard reads as exactly "contrived /
theoretical" — the origination-side version of the same anti-stochastic bias the panel has. The
specialist's charter states the honest rule directly:

> A silent-conditional hazard with a **concrete named trigger** and a **silent data-integrity impact**
> is **Important** — it manifests as silently-wrong data a human or downstream system relies on (ZB61's
> blank reading as `000 = None` during the finance sense-check). This clears Important via the existing
> **agent-hazard basis** (`severity-definitions.md:21`), which already reaches Important with no runtime
> defect required today. Reaches **Important only, never Critical**.

The **concrete-trigger requirement is the anti-inflation guardrail**: no named trigger → Suggestion or
not raised. This lives in the agent prompt only. We do **not** edit the shared
`severity-definitions.md` — that would move the bar for all 18 specialists, out of scope and risky.

### Validation — like-for-like re-score against the existing baseline

"Feels right, unproven" is the honest state until this runs. No prompt ships on intuition.

**Baseline (frozen):** the prior A/B scorecard against `cf9bc9d` — **caught 2/5, missed 3/5** of
Marlon's findings. ZB61 was one of the three misses.

**Primary test — same case, re-scored:**
- **Same commit** `cf9bc9d`, **same reference set** (Marlon's 5 findings), **same scoring** (caught /
  missed / noise).
- **New configuration** = prior specialist set **+ `latent-hazard`**, with the correctness carve-out
  applied.
- **Success = the scorecard moves to 3/5**, driven by latent-hazard **originating the ZB61
  silent-blank finding with a concrete trigger**, where correctness previously raised a false
  adjacent concern.

**Two honest caveats (stated so the result is not over-read):**
1. **Target is 2/5 → 3/5, not 2/5 → 5/5.** ZB61 is the *only* one of the three misses this specialist
   is chartered to catch. The other two misses are comment-truth — an **api-contract origination**
   failure, out of this specialist's scope. They *should* stay missed; that is correct, not a
   regression. A 3/5 is the success target.
2. **n=1 on a real PR.** The original scorecard was itself n=1 (the #114 body says so). Re-scoring the
   same case proves the *specific* miss is closed and the carve-out did not break correctness; it does
   **not** establish general precision. That is what the anti-flood controls are for.

**Anti-flood / precision controls:**
- Run against a **deterministic-and-loud** control PR and a **doc/config-only** PR.
- Success = **near-zero** latent-hazard findings — the concrete-trigger triple should starve
  speculation. If it floods, the triple is too loose; tighten before shipping.

**No-regression check:**
- After removing the silent-failure clause from correctness, confirm correctness still catches its
  retained deterministic bugs — the carve-out must not silently drop coverage.

**Harness:** follow the established standalone-specialist-on-a-pinned-diff A/B pattern used by the
housekeeper/ruff/eslint sweeps, scaled down. This is a coverage/precision check, not a
Haiku-vs-Sonnet equivalence sweep, so a handful of runs per case suffices — not n=20.

## Out of scope (deferred, tracked)

- Panel `is_real` binary redesign / two-axis (impact × trigger) proposal — #114 core + its comment.
- Aggregation-end lossiness — #61 (pro-cyclical APPROVE filter), #62 (synthesiser prior-ingestion).
- Any edit to the shared `severity-definitions.md` bar.
- Comment-truth origination (the other two `cf9bc9d` misses) — an api-contract concern, separate work.
