# Panel review — impact-based severity + tractability routing

**Date:** 2026-07-14
**Status:** design
**Builds on:** `2026-07-13-panel-severity-confidence-ratchet-design.md` (the two-axis split)
**Motivated by:** post-ratchet smoke test on `HavenEngineering/finance-erp-apps` PR #98

## Problem

The severity/realness ratchet (shipped 2026-07-13, PR #102) fixed the *schema* defect that
made the panel under-block: `is_real` and `severity` are now independent axes, so severity
doubt no longer drains the realness tally. A post-fix smoke test confirmed the mechanism
works — all three panelists now vote `is_real: true` on every finding, exactly as intended.

But the panel **still returned APPROVE** on PR #98 where classic returns REQUEST_CHANGES
3/3. The divergence moved upstream, from schema to *elicitation*: the panel is answering
the severity question in a way that systematically under-rates real defects, and it has no
signal that distinguishes "fix this here" from "this is real but don't touch it in this PR."

### Root cause 1 — severity asked "in a vacuum"

`includes/panel-concern-brief.md` poses severity as *"how much it matters, your honest
opinion."* That abstract framing let all three panelists rate the PR's most important
finding — a missing role gate on `/api/approve` + `PUT /api/budget-margins`, a reachable
finance-pipeline privilege gap — as **Suggestion**. The intent ledger declared authZ a
non-goal deferred to issue #100, and an abstract "how much does it matter" reads a declared
non-goal as low-importance. Classic, by contrast, reasoned about **consequence in context**
("the endpoints are reachable once deployed, nothing enforces the deferral") and blocked.

Evidence from the smoke test (`tests/ab/runs/20260713T214102Z-orchestration-pilot/`): the
authZ gap was rated Important (conf 88) by a Stage-1 specialist, then downgraded to
Suggestion by all three panelists. Classic rated the same finding a consensus **Important,
conf 78**, and blocked on rubric row 3.

### Root cause 2 — no axis for "real, but don't fix it here"

The panel can only say block / don't-block. It has no way to express the distinction a
senior engineer makes constantly: *this is a genuine problem, but the fix is uncertain or
risky, so it belongs in a follow-up, not this PR.* Worse, the pipeline has been posting
open-ended suggestions inline, and dispatched fix-agents have broken working code chasing
them — a concrete, recurring harm.

## Design

Two independent, majority-voted axes per finding; **do no arithmetic in the panelist** —
the rubric combines them mechanically. This preserves the founding rule the ratchet
established: never let one token fuse two judgements.

### Axis 1 — Severity (re-anchored to impact-if-manifested)

Severity answers: **if this issue manifested as a problem, how badly would it affect the
system?**

- **Critical** — takes down the whole system, or a large enough part that core
  functionality cannot be delivered.
- **Important** — some functionality would actually go wrong / not work. If the issue
  manifested, a real feature breaks.
- **Suggestion** — what we have works; this is a better way, nicer, or a non-blocking
  improvement (not an accessibility or correctness problem).

This replaces "how much it matters, your honest opinion." The re-anchoring is what fixes
PR #98: a reachable privilege gap on a finance-approval endpoint means real functionality
misbehaves (unauthorised principals can act) → **Important**, regardless of whether authZ
was a stated goal.

**Static-analysis carve-out (unchanged):** for eslint, ruff, trivy, jbinspect, and
housekeeper findings, severity is the **tool's locked value**, full confidence, not voted.
Panelist severity opinions on static findings are ignored (this is the existing Track B).

### Axis 2 — Tractability (new)

Tractability answers: **how well-understood and contained is the fix?** One fused ordinal —
uncertainty and risk are not split, because uncertainty *is* the dominant source of risk
(the main way a fix goes wrong is that we didn't understand it and deviated from intent).

- **Mechanical** — the remedy is obvious and local; you could name the diff now; negligible
  chance of collateral damage.
- **Bounded** — understood but non-trivial: touches something load-bearing or needs care,
  but the shape of the fix is clear.
- **Open-ended** — the remedy is uncertain, **or** fixing it risks deviating from intent /
  introducing a new class of bug. Needs investigation before anyone touches it.

Panelists provide tractability for **every** finding they vote on, including net-new
findings they raise themselves.

### The verdict rubric — severity governs, bluntly

Tractability does **not** touch the PR verdict. A hard-to-fix Important bug is *more* reason
not to merge, not less — so difficulty of remedy must never excuse a real defect from
blocking.

- Majority or unanimous **Critical or Important** → **REQUEST_CHANGES**.
- **Severity scatter** (no majority — e.g. 1 Critical / 1 Important / 1 Suggestion on N=3)
  → does **not** block; the finding drops out of the verdict path into the **judgement-call
  bin** (see Surfacing).
- **Suggestion** (majority) → never blocks.

This stays honest — and does not re-import classic's over-blunt blocking — *only because
severity is strictly defined by impact*. Genuine nits are Suggestions, not Importants, so
"any Important blocks" does not over-fire.

### What tractability does instead — route and prune Suggestions, recommend the action

Tractability operates entirely below the verdict line, doing two jobs:

**1. Prune / route the Suggestion tier:**

| Severity | Mechanical | Bounded | Open-ended |
|---|---|---|---|
| Suggestion | Fix now | Optional | **Drop entirely** |

Open-ended suggestions are dropped from the report altogether — this is the fix for the
fix-agent-breaks-working-code harm. Their expected value is negative: low upside, real risk
when a downstream agent tries to action them.

**2. Recommend the action on what survives, and annotate blockers:**

- For findings that stay in the report, tractability drives the recommendation:
  **fix now in this PR** vs **raise a follow-up issue**.
- On a blocking (Critical/Important) finding, an Open-ended tractability adds an
  **annotation** — "the remedy is open-ended; do not dispatch a fix-agent, this needs a
  designed change" — surfaced to the human but **not** altering the block.

### Confidence — panel agreement, asymmetric by axis

Confidence is derived from **how uniform the panelists are on each axis**, carried as a
discrete flag — no interpolation, no centroid arithmetic (false precision, since we set the
threshold anyway):

- **3/3** → majority value, **high** confidence.
- **2/1** → majority value, **medium** confidence; the dissent is preserved as a **minority
  report** in the prose.
- **1/1/1** → no majority → **scatter**, handled per-axis below.

More panelists give finer agreement gradations; the `panel:N` knob is retained. Default
N=3 (hunch: sufficient; the smoke test was cleanly unanimous, so 3 gave a crisp signal).

The two axes' scatter behaviours are **asymmetric**, because a scatter means different
things on each:

- **Severity scatter** = disagreement about *stakes* → **demote out of the verdict path**
  into the judgement-call bin. "We couldn't agree how serious this is" is exactly a human's
  call.
- **Tractability scatter** = disagreement about *fix-risk* → **resolve to the more cautious
  value** (lean less-tractable → follow-up, not fix-now, and toward Drop for Suggestions).
  The disagreement is itself evidence the fix is not well-understood; the pipeline can take
  the safer route without escalating to a human.

Confidence only ever **de-escalates the action** (softens a block to a note, routes a
fix-now to a ticket, moves toward Drop). It never promotes: a lone Critical among two
Suggestions never blocks — it becomes a minority report. Nothing is ever silently dropped
except the one explicitly-chosen cell (open-ended suggestions).

### Surfacing contract — inline vs PR-level

**Inline comments** — reserved for anything **actionable**, regardless of timing. The test
is *"is there a concrete thing to do at this line?"*:

- Blockers (REQUEST_CHANGES findings).
- Fix-now suggestions (Mechanical).
- Follow-up-issue findings — still actionable, just deferred; inline comment says "raise as
  a follow-up."

**PR-level body only (no inline)** — things that are *not* a specific action at a specific
line:

- **Judgement calls** — severity-scatter findings, "open to interpretation, needs human
  judgement."
- The **housekeeping / dependency-freshness report** (already PR-level today).
- The verdict, its reasoning, and any minority reports.

**Dropped entirely** — open-ended suggestions (no inline, no PR-level).

## Worked examples (PR #98, against the final model)

- **Missing role gate** on `/api/approve` + `PUT /api/budget-margins`: severity
  **Important** (impact-based — real functionality misbehaves: unauthorised principals can
  promote a GL journal), majority → **REQUEST_CHANGES**, inline comment. Tractability
  **Open-ended** (a whole role-policy design deferred to #100) → annotation: "do not
  dispatch a fix-agent; needs a designed role policy." **The panel now blocks, matching
  classic — and the severity re-definition, not a new axis, does the work.**
- **Tautological idempotence assertion** (`MarginJournalKeysShould.cs`): **Suggestion +
  Mechanical** → fix now, inline comment.
- A hypothetical **Suggestion + Open-ended** refactor: **dropped** — not posted anywhere.

## What changes in code

- `includes/panel-concern-brief.md` — re-anchor the severity definition to impact; add the
  tractability axis definition and the "provide both for raised findings too" instruction.
- `workflows/review-core.mjs`:
  - `PANEL_SCHEMA` — add a `tractability` enum field per vote; keep `is_real`, `severity`,
    `blocks_goal`.
  - `tallyVotes` — tally tractability alongside severity; compute per-axis majority +
    confidence flag; implement the asymmetric scatter handling.
  - `mapSpreadToTierConfidence` / rubric — derive confidence from agreement (not the old
    realness ratchet); severity-only verdict rule; tractability routes Suggestions and sets
    the fix-now/follow-up recommendation; drop open-ended suggestions.
  - `applyRubric` — "majority Critical/Important → REQUEST_CHANGES"; severity scatter →
    judgement-call bin (non-blocking, PR-level only).
  - Posting/`isPosted` + writer prompt — enforce the inline-vs-PR-level surfacing contract
    and the Drop rule.

## Cruft this removes

This model is simpler than what it replaces — it matches how a senior engineer actually
reasons (impact + fixability), and it lets us delete machinery the ratchet needed:

- **The realness→confidence ratchet arithmetic** — `mapSpreadToTierConfidence`'s
  `step = ceil(31/s)` / `ceil(50/s)` decay and the Track A/Track B numeric confidence
  derivation. Confidence now comes from panelist *agreement* (high/medium/low), not from
  decrementing a seed confidence per `is_real:false` vote. The whole numeric apparatus goes.
- **The `is_real` axis is a removal candidate.** Empirically panelists vote `is_real: true`
  on every finding (round-1 tools surface genuine issues), so the epistemic axis carries
  near-zero signal — severity-scatter now expresses "we're unsure about this." Flagged, not
  yet cut: confirm via A/B that dropping it changes no verdicts before removing it.
- **`blocks_goal` likely folds into impact-severity** — "real functionality breaks" already
  captures goal-failure (see open questions).

## Open questions for the plan

- Exact **Critical + Open-ended** cell wording (block now vs block + strong follow-up note)
  — the matrix leaves it "confirm later"; the verdict is REQUEST_CHANGES regardless, so this
  is only an annotation-wording question.
- Whether tractability is even *elicited* for static findings (their fixes are usually
  mechanical by nature — bump the version, fix the lint) or defaulted to Mechanical.
- Whether the existing `blocks_goal` axis survives as-is or folds into the impact-based
  severity (goal-failure is arguably now captured by "real functionality breaks").

## Validation

A/B smoke re-run against PR #98 (reuse
`tests/ab/runs/20260713T090815Z-orchestration-pilot/corpus.yaml`): the panel should return
**REQUEST_CHANGES** on the authZ finding. Confirm the tautological test lands as a fix-now
inline suggestion, and that no open-ended suggestion is posted. Full A/B methodology per
`2026-07-10-panel-classic-ab-design.md`; model-as-judge remains permanently banned.
