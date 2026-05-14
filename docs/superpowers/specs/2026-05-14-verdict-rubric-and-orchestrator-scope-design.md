# Verdict Rubric, Orchestrator Scope, and Synthesiser Effort Design

**Date:** 2026-05-14
**Status:** approved (brainstorm complete; awaiting plan)
**Scope:** code-review plugin only

---

## Summary

Three coupled changes to the code-review plugin, shipped in a single spec:

1. **Synthesiser max-effort fix.** Make the synthesiser actually run at max thinking
   budget. Today the `ultrathink: true` frontmatter line is a no-op; the dispatch
   prompt does not contain the keyword that triggers max effort. Fix by adding the
   keyword to the dispatch prompt body.
2. **CI gate hardening.** Phase 0.6 becomes a hard halt: any non-green-and-settled
   CI state stops the review before specialists are dispatched. Removes the
   definitive/transient distinction, the user-acknowledge prompt, and the
   `$CI_STATUS` flow into the synthesiser.
3. **Verdict rubric, orchestrator scope, and output filtering.** The synthesiser
   becomes the sole authority for the PR review verdict (`APPROVE` /
   `REQUEST_CHANGES`) via a canonical four-row rubric. The orchestrator's role
   shrinks to deterministic execution: it cannot alter findings, severity,
   confidence, body content, or fix text. It owns four narrow classes of
   decisions (user-confirmation, PR-thread state, submission mechanics, output
   filtering), all mechanical or pass-through-to-user.

Changes 2 and 3 are coupled: dropping CI as a verdict-rubric input is only safe
because change 2 guarantees CI is green by construction at synthesiser time.
Change 1 is independent but small enough to ride in the same spec.

---

## Change 1 — Synthesiser max-effort fix

### Current state
- `plugins/code-review/agents/review-synthesiser.md:6` declares `ultrathink: true`
  in frontmatter. This is **not a supported subagent frontmatter field**
  (supported: `name`, `description`, `tools`, `disallowedTools`, `model`,
  `permissionMode`, `skills`, `hooks`, `color`). The line is silently ignored.
- The synthesiser dispatch prompt at `includes/review-pipeline.md:1051` (and
  inlined copies in `commands/pre-review.md` and `skills/review-gh-pr/SKILL.md`)
  does **not** contain the `ultrathink` keyword. The keyword detector triggers
  max thinking budget when it appears in prompt content; today nothing fires.
- The progress comment at `:1055` and announce-line at `:1057` claim the
  synthesiser runs at ultrathink, misrepresenting reality.

### Target state
- `ultrathink` keyword prepended to the synthesiser dispatch prompt body. Position:
  very first token of the prompt, followed by `\n\n`, before the
  `Base branch: $BASE` line.
- `ultrathink: true` removed from the synthesiser agent frontmatter (it is a
  no-op and lying).
- Prose comment at `review-pipeline.md:1055` rewritten to describe the real
  mechanism: "The synthesiser dispatch prompt opens with the `ultrathink`
  keyword, which Claude Code detects to set max thinking budget. The model
  alias `model: \"opus\"` remains floating so the synthesiser rides the latest
  frontier."
- Announce-line `> Dispatching synthesiser (opus, ultrathink)...` is now
  accurate; keep it.
- New focused sync test asserts the dispatch prompt in all three locations
  begins with the `ultrathink` keyword. Belt-and-braces alongside the byte-diff
  sync test: failure message is explicit if a future edit moves or deletes the
  keyword.

### Rationale
- Per Anthropic and Claude Code docs, max thinking budget on a subagent
  dispatch is triggered by the textual `ultrathink` keyword in the prompt
  content; there is no API/frontmatter knob exposed at the subagent layer.
- Pinning the model alias is intentionally avoided. `model: "opus"` rides the
  latest frontier; max effort is the lever where the platform supports it.
- Synthesiser-only (not specialists or cross-reviewers) — the synthesiser does
  the deepest analytical work and produces the verdict. Other reviewers are
  focused, parallel, and cost-sensitive at 8-13 dispatches per run.

### Files touched (Change 1)
- `plugins/code-review/agents/review-synthesiser.md` — drop frontmatter line.
- `plugins/code-review/includes/review-pipeline.md` — prepend keyword to
  dispatch prompt; rewrite prose comment.
- `plugins/code-review/commands/pre-review.md` — propagate via byte-diff sync test.
- `plugins/code-review/skills/review-gh-pr/SKILL.md` — propagate via byte-diff sync test.
- `tests/lib/test_sync_notes.sh` — new function
  `test_sync_synthesiser_dispatch_uses_ultrathink`.

---

## Change 2 — CI gate hardening

### Current state (Phase 0.6 in `includes/ci-status-gate.md`)
- Phase 0.6.3 classifies checks as `failing-definitive`
  (`FAILURE`/`ERROR`/`ACTION_REQUIRED`), `failing-transient` (`TIMED_OUT`), or
  `non-failing` (`SUCCESS`/`NEUTRAL`/`SKIPPED`/`PENDING`/`IN_PROGRESS`/`QUEUED`/
  `CANCELLED`).
- Phase 0.6.4 builds a `$CI_STATUS` block carrying definitive and transient
  failure lists for the synthesiser.
- Phase 0.6.5 surfaces failures to the user with an "Acknowledge and proceed?
  [y/N]" prompt; if the user proceeds, the review continues despite known
  failures.
- The synthesiser receives `$CI_STATUS_BODY` and renders a `## CI Status`
  section; its rules tie verdict guidance to definitive/transient classification.

### Principle
The implementer is responsible for ensuring CI is green before requesting
review. If there is any doubt, that is a review failure. The plugin enforces
this: it refuses to spend tokens on a doomed review.

### Target state
- Phase 0.6 becomes a hard halt. Two outcomes only: all checks green and
  settled → proceed; anything else → halt.
- "Green and settled" set: `SUCCESS`, `NEUTRAL`, `SKIPPED`, `CANCELLED`. The
  `CANCELLED` exclusion remains because multi-trigger workflows legitimately
  cancel one trigger when another takes over.
- Any check in `FAILURE`, `ERROR`, `ACTION_REQUIRED`, `TIMED_OUT`, `IN_PROGRESS`,
  `PENDING`, or `QUEUED` halts the review. In-progress/pending checks halt
  because "we don't know yet" answers the question "has CI passed?" with
  "doubt", which is itself a review failure.
- Halt message lists which checks are non-green with their states; tells the
  user to wait for CI to settle (or fix it) and re-invoke. No
  user-acknowledge-to-proceed prompt; the halt is final.
- `$REVIEW_MODE = local` still no-ops this entire section.

### Knock-on simplifications
- `$CI_STATUS`, `$CI_STATUS_BODY`, `$CI_DEF`, `$CI_TRA` are removed from the
  pipeline.
- The synthesiser's `## CI Status` Output Format section is deleted.
- The synthesiser's verdict-constraint Rules tied to CI failures are deleted
  (handled by Change 3).
- The "Phase 0 halt: CI failures not acknowledged" path collapses to the
  single halt path.
- The definitive/transient classification logic is deleted in its entirety.

### Files touched (Change 2)
- `plugins/code-review/includes/ci-status-gate.md` — rewrite. Phases 0.6.1
  (skip in local), 0.6.2 (fetch), 0.6.3 (classify into green/non-green),
  0.6.4 (halt or proceed). 0.6.5 deleted.
- `plugins/code-review/agents/review-synthesiser.md` — delete `## CI Status`
  Output Format block; delete CI-related Rules.
- `plugins/code-review/includes/review-pipeline.md` — remove `$CI_STATUS_BODY`
  from synthesiser dispatch prompt; remove CI-related references.
- `plugins/code-review/commands/pre-review.md` — propagate.
- `plugins/code-review/skills/review-gh-pr/SKILL.md` — propagate.
- `tests/lib/test_sync_notes.sh` — remove or update assertions tied to the
  definitive/transient distinction.

---

## Change 3 — Verdict rubric and orchestrator scope

### Authority model
- The PR review verdict (`APPROVE` / `REQUEST_CHANGES`) is decided by the
  synthesiser. PR mode only — `local` mode produces no verdict, per the
  earlier dogfood-followup spec.
- The orchestrator (Step 6 of `skills/review-gh-pr/SKILL.md`) executes that
  verdict. It cannot alter findings, severity, confidence, fix text, file/line
  attribution, or the synthesiser-produced verdict on its own initiative.
- The single deterministic transformation the orchestrator may apply is the
  APPROVE → COMMENT downgrade described in Class B. This is rule-driven, not
  judgement-driven.
- The user is sovereign over the final action submitted. At the confirmation
  prompt the user can override the proposed action to any of `APPROVE`,
  `REQUEST_CHANGES`, or `COMMENT`. This is the documented caveat to
  synthesiser-as-sole-authority.

### Verdict rubric (canonical, PR mode only, first match wins)

| # | Condition | Verdict |
|---|---|---|
| 1 | Intent-ledger states a `goal` AND any consensus finding indicates the goal is not achieved | `REQUEST_CHANGES` |
| 2 | Any consensus **Critical** finding (at any confidence) | `REQUEST_CHANGES` |
| 3 | Any consensus **Important** finding with confidence ≥ 70 | `REQUEST_CHANGES` |
| 4 | Otherwise | `APPROVE` |

The synthesiser produces only `APPROVE` or `REQUEST_CHANGES`. `COMMENT` is
never a synthesiser output.

By construction under `APPROVE`:
- No Critical findings exist (row 2 caught them).
- Important findings only exist below confidence 70 (row 3 caught the rest).
- Suggestions exist at any confidence.

### Posting policy (orchestrator, mechanical)

The orchestrator filters which findings get posted to GitHub based on the
verdict. The filter is deterministic — same input, same output, no model
judgement. It does not constitute "altering findings" because the synthesiser's
sealed report (severity, confidence, body, fix text) is unchanged; only which
subset gets posted is decided.

| Verdict path | Filter |
|---|---|
| `REQUEST_CHANGES` | Post **every** consensus finding. No filter. The implementer needs the full picture; an under-powered orchestrator must not dilute what a max-effort synthesiser produced. Verbose by design. |
| `APPROVE` (and APPROVE → COMMENT downgrade) | Post consensus findings with **confidence ≥ 75**. Sub-threshold findings remain visible in the synthesiser's stdout report but are not posted to GitHub. |

The 75 threshold is intentionally above the rubric's 70 cutoff for Important
findings. Below 70: don't block. Above 75: surface under APPROVE. The 70-75
band is judged not-confident-enough to distract an author who is already
getting an APPROVE.

### Body construction (orchestrator)

The GitHub top-level review body posts the synthesiser's body verbatim except
for three deterministic transformations:

- References to filtered-out findings are elided (see Synthesiser contract
  update below).
- `## Cost` section stripped — instrumentation, not author-facing. Stays in
  stdout for the implementer.
- `## Dismissed` section stripped — false-positives, noise for the author.
  Stays in stdout for the implementer.

When any findings were filtered, the orchestrator appends a footer to the
GitHub body:

> *N additional finding(s) below the 75% confidence threshold were not posted.
> Run pre-review locally to see the full report.*

(`N` resolves to the count of filtered findings.)

### Synthesiser contract update

For Class D filtering to be mechanical, the synthesiser must produce a body
where finding references are **structurally distinguishable**. Each finding
gets a stable `[#N]` token (or per-finding section heading with a stable
anchor) the orchestrator can grep and strip without parsing prose. This is a
synthesiser-side change driven by Change 3.

The exact form (token, section, or both) is left to the implementation plan,
but the contract is: orchestrator can drop any finding by ID and elide its
references in the body via deterministic string operations.

### Class A — User confirmation flow

The orchestrator presents a single confirmation prompt with the proposed
action. The proposed action is the synthesiser's verdict, after the Class B
transformations have been applied.

**Prompt template (no peer-blocking review, synthesiser proposed APPROVE):**

```
> Synthesiser proposes: APPROVE
>   Rubric row 4: no high-confidence Critical/Important findings, goal achieved
>   <tier counts> across <N> files
>
> Submit as proposed [s], override to REQUEST_CHANGES [r],
> or cancel without submitting [n]? [s/r/n]
```

**Prompt template (synthesiser proposed APPROVE, downgraded to COMMENT by Class B):**

```
> Synthesiser proposes: APPROVE
>   Rubric row 4: no high-confidence Critical/Important findings, goal achieved
> Orchestrator adjustment: APPROVE → COMMENT
>   Reason: prior reviewer @<login> has outstanding REQUEST_CHANGES (review #<id>)
>           — APPROVE would override; posting as COMMENT instead.
>
> Submit as COMMENT [s], override to APPROVE [a], override to REQUEST_CHANGES [r],
> or cancel without submitting [n]? [s/a/r/n]
```

**Prompt template (synthesiser proposed REQUEST_CHANGES):**

```
> Synthesiser proposes: REQUEST_CHANGES
>   Rubric row <N>: <condition>
>   <tier counts> across <N> files
>
> Submit as proposed [s], override to APPROVE [a], override to COMMENT [c],
> or cancel without submitting [n]? [s/a/c/n]
```

**Behaviour:**
- Default (Enter, no input): submit-as-proposed.
- Override actions require explicit keypress.
- Cancel: halt without submission. Synthesiser report has already rendered to
  stdout, so the user keeps the analysis.

**Audit trail (announce-line on submission):**

```
> Review submitted: <FINAL_VERDICT> (<provenance>) | URL: <pr-review-url>
```

Where `<provenance>` is one of:
- `synthesiser-proposed` — submitted exactly as the synthesiser proposed
- `orchestrator-adjusted to <FINAL>, originally synthesiser-proposed <ORIGINAL>` — Class B downgrade applied, user accepted
- `user override of synthesiser-proposed <ORIGINAL>` — user changed the verdict
- `user override of orchestrator-adjusted <ADJUSTED>, originally synthesiser-proposed <ORIGINAL>` — Class B downgrade and user override both applied

### Class B — PR-thread state handling

The orchestrator runs three checks at the start of Step 6, before presenting
the confirmation prompt. All three use `gh api` / `gh pr view` against live
PR state.

1. **PR closed or merged since review started.** Refuse to submit. Print:
   `> PR #N has been <closed|merged> since the review started. Skipping
   submission. Synthesiser report rendered to stdout for your reference.`
   Halt cleanly. No confirmation prompt.

2. **New commits pushed since synthesiser ran.** Compare current PR
   `headRefOid` against `$HEAD_SHA`. If different, present a warning before
   the confirmation prompt:

   ```
   > Warning: PR head has advanced since this review was started.
   >   Synthesiser analysed: <synth-sha>
   >   Current HEAD:         <head-sha> (<N> new commits)
   > Findings may be stale. Continue with submission, or cancel and re-run? [s/n]
   ```

   On `s`: continue to the confirmation prompt. Inline comments still anchor
   to `$HEAD_SHA` (the synthesiser's analysed commit), not to current HEAD —
   safest, no dangling anchors, reviewers can navigate to current head from
   GitHub UI.

   On `n`: halt cleanly without submission.

3. **Outstanding peer REQUEST_CHANGES.** Query review threads for
   non-dismissed `REQUEST_CHANGES` from another reviewer on the latest commit.
   If present and the synthesiser proposed `APPROVE`, transform the proposed
   action to `COMMENT`. The author of an outstanding peer block is not
   silently dodged by an APPROVE.

### Class C — Submission mechanics

- Inline comments are posted before the top-level review verdict.
- Order: file order from `$CHANGED_FILES`, then ascending line number.
- Side: `RIGHT` for additions/modifications, `LEFT` for deletions.
- Verdict (`gh pr review`) is submitted only after all inline comments
  succeed.
- No artificial cap on inline comment count. If the synthesiser produced
  N findings (or N filtered findings under APPROVE), all N are posted.
- On any inline-comment posting failure: stop, surface error and the failed
  item, ask user retry / skip-this-comment / cancel-the-whole-submission. No
  silent partial submissions.

### Class D — Output filtering

Already specified above (Posting policy + Body construction). Listed here for
completeness; the orchestrator's filtering is its sole content-shaping power
and is mechanical.

### Files touched (Change 3)

- `plugins/code-review/includes/verdict-rubric.md` — **new canonical**
  containing the rubric, posting policy, and body construction rules.
- `plugins/code-review/agents/review-synthesiser.md` — inline the rubric;
  restructure `## Verdict` Output section to emit a structured verdict block
  (`Verdict:` line, `Rubric row applied:` line); update Rules to drop
  CI-related verdict guidance; produce body with structurally-distinguishable
  finding references (`[#N]` tokens or per-finding sections).
- `plugins/code-review/skills/review-gh-pr/SKILL.md` — Step 6 rewrite. Remove
  the existing decision matrix; replace with a reference to the rubric, the
  Class A confirmation flow, the Class B state checks, the Class C mechanics,
  and the Class D filtering.
- `plugins/code-review/includes/review-pipeline.md` — references the verdict
  rubric where relevant; remove CI-status flow to synthesiser (also Change 2).
- `plugins/code-review/commands/pre-review.md` — propagate.
- `tests/lib/test_sync_notes.sh` — new sync test for `verdict-rubric.md`
  canonical-and-inlined byte parity; new structural test asserting the
  synthesiser's `## Verdict` Output section emits the rubric-row line; new
  structural test asserting Step 6 of `SKILL.md` references the rubric and
  the Class A/B/C decision rules.

---

## Cross-change concerns

### Coupling
- Change 1 is independent of Changes 2 and 3.
- Change 2 must precede or accompany Change 3 in the implementation plan: the
  rubric in Change 3 omits CI as an input on the assumption that CI is green
  by construction at synthesiser time, which Change 2 enforces. If Change 3
  shipped without Change 2, the rubric would be silently weaker than today's
  guidance.
- The implementation plan should bundle Changes 2 and 3 in tightly-ordered
  tasks. Change 1 can be an early or late task; placement does not matter.

### Out of scope
- Pinning the model alias. Explicitly your direction: keep `model: "opus"`
  floating so the synthesiser rides the latest frontier.
- Applying ultrathink to specialists or cross-reviewers. Synthesiser only.
- The `/effort` user command (session-level user action, orthogonal to
  per-dispatch agent config).
- Changes to the cross-review verdict (`Agree`/`Disagree`/`Escalate`) —
  different concept entirely; out of scope for this spec.
- Changes to per-finding confidence model or dissent budget — settled by the
  static-analysis severity-confidence policy spec.
- Changes to severity tier classification rules.
- Aggressive content curation (per-section configurability, etc.). Filtering
  is purely the threshold rule + the three deterministic body strips.

### Risks and mitigations
- **Synthesiser body filterability constraint.** New requirement on the
  synthesiser output format. Mitigation: pin the contract in
  `verdict-rubric.md` and assert in a structural test that the synthesiser's
  prompt instructs the model to emit findings with stable IDs.
- **The `gh pr view` queries for Class B (peer REQUEST_CHANGES, head
  advance, PR state)** add latency to Step 6. Mitigation: batched into one
  GraphQL call where possible; Step 6 is end-of-pipeline so a few extra
  seconds are immaterial against the synthesiser's runtime.
- **User-override flexibility could be abused.** A user can always override
  REQUEST_CHANGES → APPROVE. Mitigation: every override is recorded in the
  announce-line audit trail; the synthesiser's report (with its original
  recommendation and rubric reasoning) remains on stdout.

---

## Acceptance criteria (for the plan to satisfy)

- `tests/run.sh` passes including new sync tests.
- `ultrathink` keyword present at the start of the synthesiser dispatch prompt
  in canonical and both inlined consumers (asserted by sync test). This is a
  deliberate per-invocation cost choice: the synthesiser is the sole verdict
  authority, runs once per review (the load-bearing decision in the pipeline),
  and one extended-thinking dispatch per PR is judged worthwhile against the
  alternative of a default-budget verdict on the entire specialist + cross-
  review aggregate. Documented here so the cost is not implicit in the
  dispatch prompt.
- `ultrathink: true` no longer present in any agent frontmatter.
- `$INTENT_LEDGER` appears in the synthesiser dispatch prompt at all three
  sites (`includes/review-pipeline.md`, `commands/pre-review.md`,
  `skills/review-gh-pr/SKILL.md`), positioned between the Review mode line
  and the trust boundary advisory, so the synthesiser can evaluate verdict
  rubric row 1 (intent-ledger goal unachieved) deterministically rather than
  inferring the goal from the diff. Verified by sync test
  `test_sync_synth_dispatch_passes_intent_ledger`.
- `includes/ci-status-gate.md` Phase 0.6 rewritten to halt on any non-green
  state; no acknowledge-to-proceed prompt; no definitive/transient
  classification.
- `includes/verdict-rubric.md` canonical exists; inlined into `review-pipeline`,
  `review-synthesiser`, and Step 6 of `SKILL.md` per byte-diff sync test.
- Synthesiser produces only `APPROVE` or `REQUEST_CHANGES`. Verified via
  structural test asserting the Output Format block restricts to those two
  values.
- Step 6 of `SKILL.md` no longer contains a decision matrix; instead
  references the rubric and presents the Class A confirmation flow.
- Sub-75-confidence findings are dropped from GitHub posting under APPROVE
  (asserted via documentation; behavioural smoke test optional).
- `## CI Status`, `## Cost`, `## Dismissed` sections are stripped from posted
  body under both verdicts; verified via structural assertion in the
  synthesiser body-construction rules.
