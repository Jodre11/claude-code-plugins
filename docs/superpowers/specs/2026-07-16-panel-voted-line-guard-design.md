# Panel voted-finding line guard — design

## Context

Follow-up to PR #107 (`2a43974`, merged), which added a deterministic line-hallucination
guard to the panel **raised**-findings path. A behavioural verification of that fix against
the merged dayforce PR #3 (run `wf_682ceb86-750`, panel size 3, analysis-only) confirmed:

- the raised-path guard is sound and `parseChangedLines` parses the real pipeline
  `$CHANGED_LINES_BLOCK` correctly (no crash, valid bundle);
- Point 2 (jbinspect repo-relative paths) and Point 4 (panel-vote/panel-write phases) work;
- **but 3 of the 65 posted comments still carried hallucinated lines that would 422.**

The three bad anchors were:

| File | Posted line | Real file length | Raising specialist |
|------|-------------|------------------|--------------------|
| `Storage/OrgStructureSnapshotStore.cs` | 931 | 202 | style |
| `Comparison/OrgStructureDiffReport.cs` | 343 | 95 | style |
| `Handler/FunctionHandler.cs` | 1834 | 412 | alignment |

All three were traced to **round-1 specialist output** (confirmed in the run's `cogs`):
a specialist invented the line, the panel voted the finding `is_real: true`, and the
specialist's fabricated line rode straight through `mapSpreadToTierConfidence`'s
**voted-findings loop** → `renderComments` → the posted comment set. The panel raised
**zero** net-new findings that run, so the PR #107 raised-path guard had nothing to act on.

### Root cause

Hallucinated lines reach GitHub through **two** panel posting paths, and PR #107 closed
only one:

1. **Raised path** (`raisedClusters` loop) — panelist net-new findings. Had no `$CHANGED_LINES`
   scope filter at all. **Fixed in PR #107.**
2. **Voted path** (`voteTallies` loop) — Stage-1 specialist findings the panel confirms.
   The only line-scope check is the specialist's own **in-prompt §5 filter**, which is
   model-executed and advisory — an LLM specialist can (and here did) emit a line outside
   the diff, and nothing deterministic catches it before it posts.

The original PR #3 hallucinations (which motivated PR #107) happened to be on the raised
path; this verification run hallucinated on the voted path instead. Same root cause (a model
invents a line to fill the schema-required `line` field), different route.

### Why static findings were unaffected

All 49 jbinspect (static-analyser) findings in the run carried valid, in-diff, repo-relative
lines. Static-tool line numbers come from the tool, not a model, so they do not hallucinate.
The guard below is still applied to them — it is deterministic and a valid line passes
through untouched — but they are not the risk being closed.

## Goal

Guarantee that a **voted** panel finding never posts against a line the diff did not touch —
identical guarantee to PR #107's raised-path guard, applied to the second path. Demote the
anchor (never drop the finding): bad line → file-level comment; absent file → body note.

## Non-goals

- Re-touching the raised path (PR #107 already covers it).
- Changing which findings the panel votes real, their severity, tier, or verdict — the guard
  mutates only `file`/`line`, never tier/severity/confidence.
- Changing the classic/synthesiser path (line-scoped upstream) or the specialists' in-prompt
  §5 filter (it stays as a first-line advisory filter; this adds the deterministic backstop).

## Design

The fix reuses the **exact mechanism** PR #107 already built — `parseChangedLines` and the
`changedLines` map are already computed once at the top of `mapSpreadToTierConfidence`
(review-core.mjs:798). The voted-findings loop begins at line 800 and destructures the
finding's fields (including `file`/`line`) into `rest` at line 801. The guard is a small,
symmetric block inserted immediately after that destructure, mirroring the raised-loop guard
(review-core.mjs:884-890).

### Guard placement — the voted-findings loop

In `mapSpreadToTierConfidence`, immediately after `const { finding_id, ...rest } = finding`
(review-core.mjs:801) and before any tier logic uses `rest`:

```
// Line-hallucination guard (voted path) — mirror of the raised-cluster guard. An LLM
// specialist can emit a line outside the diff; the panel voting it real must not carry
// that fabricated line to a posted comment. Skip findings already fileless (empty or the
// <n/a> alignment sentinel) — they route to the body regardless and their sentinel is
// load-bearing for renderBodyNotes. File not in the diff → clear file+line (body). Line
// not among the file's changed lines → zero the line (Anchor Ladder → file-level). Valid
// in-diff line (incl. line 0 deletion anchors, which are never in the set → file-level) →
// unchanged.
const votedFile = (rest.file || '').trim()
if (votedFile && votedFile !== '<n/a>') {
    if (!(votedFile in changedLines)) {
        rest.file = ''
        rest.line = 0
    } else if (!changedLines[votedFile].has(rest.line)) {
        rest.line = 0
    }
}
```

**Why after the destructure, before the branches.** `rest` feeds both the dismissed branch
(line 840) and the routed branch (line 852). Applying the guard once at line 801 covers both.
Dismissed findings are never posted (`posting: 'drop'`), so the guard is functionally a no-op
for them — but applying it uniformly keeps the durable log's `file`/`line` honest and costs
nothing.

**Why skip already-fileless findings.** The alignment reviewer emits the literal `<n/a>`
sentinel for body-improvement findings (see `isFileless`, review-core.mjs:1011-1014).
Clearing it to `''` would be functionally equivalent (both are fileless) but needlessly
rewrites a load-bearing sentinel; skipping keeps the existing `<n/a>` → body-notes path
untouched.

**Why line 0 is safe.** A deletion-anchor finding carries `line: 0` with a real file.
`changedLines[file]` never contains 0 (the block lists added/context lines only), so the
guard's `else if` zeroes an already-zero line and keeps the file → file-level comment. That
is exactly today's deletion-anchor behaviour — no regression.

**No new posting code.** Both demotion targets already exist and are shared with the raised
path: `line = 0` + real file → `renderComments` file-level branch; empty file → `isFileless`
→ body note.

## Testing

**Unit (extend `tests/lib/test_panel_review.sh`):** the `_pan_args` helper already carries a
`changedLinesBlock` (added in PR #107) covering the raised-fixtures' files. Add voted-path
fixtures that drive Stage-1 findings (via the `specs` map) with bad anchors and assert the
guard demotes them:

- **Voted finding, bad line in an in-diff file** → unanimously voted real → consensus, but
  posts as a **file-level** comment (`subjectType: file`, path kept, no line).
- **Voted finding, file absent from the diff** → voted real → posts **no** comment
  (file cleared → body); assert `comments == 0` and the log finding's `file` is `''`.
- **Voted finding, valid in-diff line** → voted real → posts inline at the original line
  (guard no-op).
- **`<n/a>` sentinel finding** → still routes body-only, sentinel preserved (guard-skip
  branch) — the existing `test_panel_na_sentinel_finding_is_body_only` must stay green.
- **Static (jbinspect) finding with a valid line** → passes through inline unchanged
  (guard applies but is a no-op) — guards against a regression that would demote valid
  static anchors.

The existing raised-path guard tests and all current voted-path tests must stay green
(the guard only mutates `file`/`line` on out-of-scope anchors).

**Behavioural (the real proof — user will re-run):** repeat the PR #3 panel run
(`wf_682ceb86-750` recipe: pinned base `946429e…`, head `994ccca…`, panel size 3,
analysis-only, working-tree/inlined core). Re-run the anchor cross-check
(`pr3-verify/analyse.py`): **BAD line anchors must be 0** and **absent-file comments must
be 0**. If any of the three previously-bad findings recur, confirm they now post as
file-level/body, not at lines 931 / 343 / 1834.

## Files touched

- `plugins/code-review-suite/workflows/review-core.mjs` — the voted-loop guard block after
  the `voteTallies` destructure (review-core.mjs:801). No other file: the `changedLinesBlock`
  arg, `parseChangedLines`, and the three markdown call-sites all already exist from PR #107.
- `tests/lib/test_panel_review.sh` — the five voted-path guard fixtures above.

## Sync-note check

No markdown call-site or args-object change — `changedLinesBlock` is already threaded through
all three (`SKILL.md`, `review-pipeline.md`, `pre-review.md`) by PR #107. The concern-brief
already carries the raised-finding anchoring paragraph; consider (optional) whether Stage-1
**specialist** prompts should gain an equivalent "anchor to a real changed line" reminder —
but that is a soft/advisory lever, and the deterministic guard is the guarantee regardless,
so it is out of scope for this fix and noted only for completeness.

## Branch

PR #107 is merged to `main`. This follow-up lands on a new branch off `main`
(`feat/panel-voted-line-guard`), PR'd on its own.
