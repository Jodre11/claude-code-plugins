## Verdict Rubric

<!-- REFERENCE — describes behaviour implemented in code. The verdict rubric, the
tier mapping and the posting routes are computed by `workflows/review-core.js`
(`mapSpreadToTierConfidence`, `routeFinding`, `applyRubric`, `finalizeBundle`). No
agent reads this file at runtime; keep it in step with the code when either changes. -->

### Tiers (panel tally, per finding)

Each Stage-1 specialist finding is voted on by every panelist (`is_real`, `severity`,
`tractability`, `blocks_goal`). Net-new findings a panelist raises are clustered across
panelists by file and a three-line window.

| Finding | Tier |
|---|---|
| A panel majority votes it not real (any domain, static included) | Dismissed |
| Static analyser (eslint, ruff, trivy, jbinspect), unanimous real, locked severity ≥ Important | Consensus |
| Static analyser, otherwise | Contested |
| Housekeeper, not dismissed | Contested, rendered in the Dependency Freshness table |
| LLM specialist, severity majority Critical or Important | Consensus |
| LLM specialist, severity majority Suggestion | Contested |
| LLM specialist, no severity majority | Contested, marked as a judgement call |
| Panel-raised cluster corroborated by at least ⌈2s/3⌉ raises (s = surviving panelists) | Consensus |
| Panel-raised cluster, otherwise | Contested |

Confidence is the discrete agreement flag (`high`, `medium` or `low`), never a number.

### Verdict rubric (PR mode only, first match wins)

| # | Condition | Verdict |
|---|---|---|
| 1 | The intent ledger states a `goal` AND a panel majority says a consensus or contested finding shows the goal is not achieved (`blocks_goal`) | `REQUEST_CHANGES` |
| 2 | Any consensus **Critical** finding | `REQUEST_CHANGES` |
| 3 | Any consensus **Important** finding (a severity majority — there is no confidence gate) | `REQUEST_CHANGES` |
| 4 | Otherwise | `APPROVE` |

The rubric produces only `APPROVE` or `REQUEST_CHANGES`. The orchestrator never
auto-downgrades a verdict to `COMMENT`; the only route to `COMMENT` is an explicit user
override at the Class A confirmation prompt.

In `local` (pre-review) mode the rubric does not apply: pre-review produces no verdict —
the human reader decides what (if anything) to act on.

### Posting routes

Every finding carries an explicit `posting` route, so which findings post is decided in
code, not by the orchestrator.

| Finding | Route |
|---|---|
| Consensus Critical or Important (blocking) | Inline comment, "fix in this PR". An Open-ended remedy also carries a do-not-dispatch-a-fix-agent note. |
| Suggestion (any tier), Mechanical | Inline comment, "fix in this PR" |
| Suggestion (any tier), Bounded | Review body, "raise as a follow-up" |
| Suggestion (any tier), Open-ended | Dropped (Dismissed tier) |
| Judgement call | Review body |
| Contested Critical or Important (not blocking) | Review body |
| Housekeeper | Dependency Freshness table in the review body |

Under `APPROVE`, when open-ended Suggestions were dropped, the posted body carries a single
disclosure line — `N finding(s) pruned (open-ended suggestions not surfaced).` — so an
APPROVE never looks cleaner than the run actually was.

A finding anchored to a file outside the diff moves to the review body; one anchored to a
line the diff did not touch becomes a file-level comment.

### Body construction

The body is built by `review-core.js` `buildBody` from parts: the verdict headline with the
rubric reason, the Panel Assessment written by the panel writer (its only contribution), a
compact finding index, body notes for findings with no file, the pruned-findings disclosure,
and the Dependency Freshness table. The local pre-review report (`buildLocalReport`) uses the
same parts without the verdict headline, with every finding rendered in full.

Findings that share a file and a posting route and sit within three lines of each other
(`groupColocated`) render as ONE inline comment — headed by the most severe, every member's
text kept — and one index line. This is rendering only: the verdict is computed first.
