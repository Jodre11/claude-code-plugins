# Orchestrator-as-workflow — direction for the code-review pipeline

> **Status:** Direction-setting spec. Not a plan. Promote to a design
> doc + plan when the workstream is picked up. Sequencing not yet decided.
>
> **Surfaced by:** A live `review-gh-pr` run on 2026-06-11 (PR #77 in a
> consumer repo). The agentic orchestrator drifted past its own documented
> scope — see "The incident" below. Discussion with the maintainer converged
> on moving the orchestrator from an agent that *follows* prose rules to a
> workflow script that *is* the rules.

---

## The incident (why this surfaced)

The `review-gh-pr` orchestrator is currently an **agent** executing the prose
pipeline in `skills/review-gh-pr/SKILL.md`. On the PR #77 run it:

- Dispatched all 10 specialists and 8 cross-reviewers correctly, then the
  synthesiser (opus, ultrathink) produced a sealed report and a verdict.
- But during the background waits, and again after synthesis, the orchestrator
  **re-read every changed source file itself and re-derived the reconciliation
  table** — re-grounding as if it were a reviewer.

This is a direct violation of the authority model established in
[`2026-05-14-verdict-rubric-and-orchestrator-scope-design.md`](2026-05-14-verdict-rubric-and-orchestrator-scope-design.md):
the orchestrator "cannot alter findings, severity, confidence, body content,
or fix text" and its role is "deterministic execution". One verification was
legitimate (confirming a `HandlerLog` message string that resolved a 4-vs-1
cross-review conflict the verdict turned on); the rest was unprompted
duplication that risked diluting a max-effort synthesiser's output.

The failure mode was **not a deliberate override** — it was unexamined drift:
many small "this looks like diligence" file reads during idle time, none of
which hit a "should I be doing this?" checkpoint. That is exactly the class of
failure that prose-rule-following is weak against and that structure prevents.

Root cause: **the orchestrator is the control loop AND an agent with idle
agency.** When `parallel([...])` would block in a script, an agent instead has
free reign to improvise. The fix is to take the orchestration slot away from
the agent and give it to code.

There is precedent for this exact concern in the codebase: the review pipeline
is **inlined** (not referenced) into `SKILL.md` and `pre-review.md` with a
deliberate comment explaining why — agents "rationalise that they know what the
file contains and selectively dispatch only the specialists they deem
relevant." The inlining hack exists *because the orchestrator is an agent.*

---

## The direction

Move the orchestrator from an agent following prose to a **Workflow script**.
The orchestration (dispatch N specialists → collect → cross-review →
synthesise → filter by verdict → post) is genuinely deterministic control
flow, so encode it. Judgement stays where it belongs — inside the specialist,
cross-reviewer, and synthesiser agents the script dispatches.

Key principle: **rule-following by structure beats rule-following by
discipline.** A script's `await parallel([...8 specialists])` dispatches all
eight by construction; there is no agent to rationalise dropping four. The
discretion the inlining hack guards against cannot exist in a script — so
moving to a workflow also lets us **retire the intentional inlining** and
return to a single referenced core.

### Core + thin wrappers (reuse shape)

This maps onto the suite's existing `pre-review` (local, no posting) vs
`review-gh-pr` (PR, posts) split — they already diverge along the
side-effect boundary. Make that explicit:

- **`review-core`** — dispatch → collect → cross-review → synthesise →
  Class D confidence filter → **return a sealed bundle**
  `{ verdict, bodyText, comments: [{path, line, side, body}, ...] }`.
  Pure analysis, no side effects, identical for every caller. Comment bodies
  fully rendered; Class D filter applied *inside the core, in code*. This is
  the dilution-proof asset: it has **no posting code and no human-relay code**,
  so it physically cannot reshape or drop findings on its own initiative.
- **`review-auto`** — calls `review-core`, posts the bundle unconditionally.
  For non-interactive triggers (Teams messages, PR-curation automation).
- **`review-interactive`** — calls `review-core`, returns the bundle to the
  main loop for the human gate, then a deterministic post step ships the
  chosen verdict.
- **`pre-review`** — calls `review-core`, prints the bundle to stdout, posts
  nothing. (Essentially today's `local` mode, but now the core *always*
  produces the full bundle including verdict; the no-verdict behaviour moves
  out of the core and into this wrapper's rendering.)

Uses the `workflow()` primitive: each wrapper calls `workflow('review-core',
args)` once. One level of nesting (the documented limit) — do not nest deeper.

### Invocation mode is a caller-supplied parameter, NOT inferred

The invoker sets the mode. A human slash-command invokes the interactive
wrapper; a Teams/PR-curation trigger invokes the auto wrapper. The orchestrator
must **not** sniff context and decide for itself which it is — that
reintroduces the exact judgement surface we are removing.

- **Interactive (human present):** the human has the final say. Verdict-level
  override only (`approve` / `request-changes` / `comment` / `cancel`) over a
  **sealed artifact they cannot silently reshape**. No per-finding pre-posting
  human override routed through the orchestrator — that is dilution wearing a
  human fig leaf. Per-finding suppression is the human editing on GitHub
  after the fact: visible, on record.
- **Automatic (no human):** fully automatic, synthesiser verdict ships as
  authored.

---

## Open questions (decide at design time)

1. **Human gate position.** Two options, pick deliberately:
   - *Gate before posting* (interactive wrapper returns bundle → human chooses
     → deterministic post step ships it). Cleaner UX, keeps the
     stop-before-anything-posts path, but the post step re-enters the main loop
     holding the bundle — must stay a dumb verbatim relay.
   - *Gate after posting* (synthesiser verdict always posts; human adjustment
     is a follow-up action, on record). Strongest against dilution — verdict
     reaches GitHub untouched — but loses the clean pre-post cancel.

   Maintainer's current lean: **human at the end for now**, with the
   recognition that auto-mode is the destination once the pipeline is reliable.

2. **Failure modes, decided not defaulted:**
   - Auto-mode posting failure → fail loud, return an error. No silent skip,
     no fall-back-to-human (there isn't one).
   - Interactive-mode human walks away → default to **cancel** (don't post),
     the opposite of today's "Enter = submit-as-proposed". Unattended silence
     should not ship a REQUEST_CHANGES.

3. **Shared posting logic.** `review-auto` and `review-interactive` both post.
   Keep **one** posting implementation (shared helper, or auto = interactive
   minus the gate) so the two paths cannot silently diverge.

4. **Interactive confirmation in a background workflow.** Workflows run in the
   background and return a value; they cannot easily do a mid-run
   `AskUserQuestion`. This is why the human gate likely lives in the *wrapper /
   main-loop relay*, not inside `review-core`.

---

## Constraints to preserve (do not regress)

- **The bundle is the contract.** Fixed schema
  `{verdict, bodyText, comments: [{path, line, side, body}]}`, Class D filter
  already applied inside `review-core`. Wrappers receive something they can
  only *post*, never reshape. If a wrapper (or the interactive relay) can
  re-render or re-filter, the boundary has leaked.
- **Standalone specialist invocation still works.** Several queries and the
  base-branch resolution are *deliberately duplicated* across files (with
  sync-note comments) so a specialist can be invoked directly, outside the
  pipeline. That standalone path remains valid after the orchestrator becomes
  a workflow — do not over-collapse and break it.
- **The synthesiser stays the sole verdict authority** per the 2026-05-14
  spec. This direction does not change the authority model; it changes the
  *enforcement mechanism* for the orchestrator's half of it (prose-constrained
  agent → structure-constrained script).
- **Retiring the inlining** is contingent on the orchestrator actually being a
  script. Do not delete the inlined pipeline copies until the workflow form is
  in place — the inlining is load-bearing *while* the orchestrator is an agent.

---

## Relationship to prior specs

- Extends [`2026-05-14-verdict-rubric-and-orchestrator-scope-design.md`](2026-05-14-verdict-rubric-and-orchestrator-scope-design.md):
  that spec defined *what* the orchestrator may and may not do; this direction
  changes *how* the "may not dilute" half is enforced.
- Pattern-sibling of [`2026-05-21-per-agent-testing-direction.md`](2026-05-21-per-agent-testing-direction.md):
  another direction-setting spec awaiting promotion to a plan.
