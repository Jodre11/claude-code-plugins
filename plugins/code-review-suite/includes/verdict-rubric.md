## Verdict Rubric

<!-- REFERENCE — describes behaviour implemented in code. `workflows/review-core.js` is the
source of truth: normalisation (`normaliseNative`), the guards (`citesOutsideRule`,
`staticCriticalAllowed`, `anchorFinding`), the verdict and the rendering (`buildBody`,
`buildLocalReport`). No agent reads this file at runtime; keep it in step with the code when
either changes. -->

### Findings

Two finders feed one review: Claude Code's bundled `/code-review` (`native`) and the
static-analysis specialists the diff selects (`jbinspect`, `eslint`, `ruff`, `trivy`,
`housekeeper`). Every finding keeps its `source`.

Native's findings are mapped in code:

| Native | Finding |
|---|---|
| `severity: important` | `Important`, blocking |
| `severity: nit` | `Suggestion` |
| `severity: pre_existing` | `Suggestion`, annotated pre-existing, never blocking |
| `summary` before `Fix:` | `description` |
| `summary` from `Fix:` on | `suggested_fix` (empty when absent) |
| `failure_scenario` | rendered verbatim under the description |

A static finding keeps the severity its tool mapping gave it
(`includes/static-analysis-context.md` §10). A static `Critical` or `Important` blocks; a
static `Critical` whose rule is not on its tool's `Critical-allow-list:` posts with a
not-blocking note and does not block. Housekeeper findings never block.

A native finding that cites a `CLAUDE.md` outside the reviewed repository as its rule source
is dropped and logged (`filtered: rule-source`): personal instructions never become findings.

### Verdict (PR mode only, first match wins)

| # | Condition | Verdict |
|---|---|---|
| 1 | Native did not run (skill error, no parseable findings array, a malformed finding, no result, or a bad native target) | `NONE` |
| 2 | Any blocking finding | `REQUEST_CHANGES` |
| 3 | Otherwise | `APPROVE` |

Under `NONE` the bundle still carries the static-analysis comments, and the body headline
reads `**COMMENT** — native review did not run (<reason>); static-analysis findings only`.
The host asks the user whether to post them as a `COMMENT` review; it never submits
`APPROVE` or `REQUEST_CHANGES` for a `NONE` bundle.

Otherwise the code never produces `COMMENT`; the only route to it is an explicit user
override at the Class A confirmation prompt.

In `local` (pre-review) mode the verdict is always `NONE`: pre-review produces no verdict —
the human reader decides what (if anything) to act on.

### Anchors and posting

| Finding | Where it posts |
|---|---|
| File not in the diff | Review body, with its original location |
| File in the diff, line not a changed line | File-level comment |
| File and line in the diff | Inline comment |
| Housekeeper | Dependency Freshness table in the review body |
| Filtered as a personal rule | Not posted; logged only |

Findings on one file within three lines of each other (`groupColocated`) render as ONE
comment — headed by the most severe, every member's text kept — and one index line. Native
and static findings on the same lines share that comment. This is rendering only: the
verdict is computed first. Posted comments do not name a finding's source; the log and the
local report do.

### Body construction

The PR body is built by `buildBody` from parts: the verdict headline with its reason, a
compact finding index, body notes for findings that could not anchor in the diff, the
Dependency Freshness table, and the hidden marker line `<!-- code-review-suite -->`. The
local pre-review report (`buildLocalReport`) uses the same parts without the verdict
headline, with every finding rendered in full and its source shown.

Before either is built, the voice phase (`voicePass`) rewords native's surfaced findings to
`includes/comment-voice.md`; a code guard keeps the original of any field whose rewrite
changes a fact. The wording pass never touches the verdict, a severity, a native
`failure_scenario` or a static-analysis finding. In PR mode every comment body and the review
body end with the marker line.
