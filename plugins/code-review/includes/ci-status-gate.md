## Phase 0.6: CI Status Gate

<!-- CANONICAL SOURCE — do not delete.
This file is the single source of truth for the CI-status gate. Its content is inlined
verbatim into both consumer files:
  - skills/review-gh-pr/SKILL.md
  - commands/pre-review.md

WHY INLINED: same rationale as review-pipeline.md — agents skip file-path references and
must see the rule in context. PR #10 incident, 2026-05-05.

In mode `local` this section is a no-op (no PR exists). In mode `pr` it halts the
review on any non-green-and-settled CI state. The implementer is responsible for
ensuring CI is green before requesting review; if there is doubt, that is itself a
review failure. The plugin enforces this by refusing to spend tokens on a doomed run.

MAINTENANCE: Edit this file first, then propagate to both consumers. The test suite verifies
the inlined copies match this canonical source. Heading levels are relative — H2 here
renders as H2 in consumers; do not change without auditing both. -->

### 0.6.1 Skip in local mode

If `$REVIEW_MODE` is `local`, skip this entire section and continue to Step 1.

### 0.6.2 Fetch CI status

Run:

```bash
gh pr checks "$ARGUMENTS" --json name,state,workflow,link --jq '.[]'
```

Store the parsed list as `$CI_CHECKS`. If the call fails (e.g. no CI configured), set
`$CI_CHECKS = []` and continue without gating.

### 0.6.3 Classify states

A check `c` is **green-and-settled** if `c.state` is one of `SUCCESS`, `NEUTRAL`,
`SKIPPED`, or `CANCELLED`. `CANCELLED` remains in this set because multi-trigger
workflows legitimately cancel one trigger when another takes over.

Any other state — `FAILURE`, `ERROR`, `ACTION_REQUIRED`, `TIMED_OUT`, `IN_PROGRESS`,
`PENDING`, or `QUEUED` — is **non-green**. In-progress and pending checks count as
non-green because "we don't know yet" answers the question "has CI passed?" with
"doubt", which is itself a review failure.

Compute `$CI_NON_GREEN` = list of `(c.name, c.state)` for every non-green check.

### 0.6.4 Halt or proceed

If `$CI_NON_GREEN` is empty: announce `> CI: all checks green and settled` and continue
to Step 1.

Otherwise, halt the review. Print:

```
> Phase 0 halt: CI is not green.
> Non-green checks:
> <c.name (c.state)>
> <c.name (c.state)>
> ...
>
> The implementer is responsible for ensuring CI is green before requesting review.
> Wait for CI to settle (or fix the failures) and re-invoke. The plugin will not
> spend tokens on a review whose answer to "has CI passed?" is "doubt".
```

The halt is final — there is no acknowledge-to-proceed prompt. Stop the pipeline cleanly.

<!-- COUPLING: this hard halt was paired with the deletion of the synthesiser-side CI
verdict constraint (the `## CI Status` Output block and the two `$CI_STATUS_BODY`-driven
verdict-constraint Rules in `agents/review-synthesiser.md`, removed in PR #27). The two
mechanisms were redundant by design when both existed (defence in depth). They are now
collapsed into this single hard halt: if the synthesiser is reached, CI is green by
construction.

If this halt is ever softened — restoring an acknowledge-to-proceed path, exempting
specific check states such as `TIMED_OUT`, or reintroducing a transient-vs-definitive
classification — the synthesiser-side constraint MUST be restored as defence in depth.
A single softened gate with no synthesiser-side check would let the synthesiser emit
APPROVE on a failing CI state, a real correctness regression. -->

