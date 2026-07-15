# Panel raised-finding line guard — design

## Context

Point 3 of the organic panel-review validation on
`HavenEngineering/lambda-haven-dayforce-integrations` PR #3 (run `wf_06ad0294-58a`,
verdict REQUEST_CHANGES, 83 comments). Of the 83 comments, the **two panel-raised**
net-new findings anchored to non-existent lines: `DayforceOrgUnitsClient.cs:1160`
(the file is 165 lines) and `FunctionHandler.cs:1977` (the file is 407 lines). The
findings themselves are real — those methods exist — but the opus panelist invented
the line numbers.

### Root cause

`RAISED_SHAPE` (review-core.mjs) requires a `line` (schema `minimum: 0`), but
`includes/panel-concern-brief.md` says **nothing** about line numbers. Panelists are
handed the full diff but no explicit changed-line set, so they fabricate a line to
satisfy the schema.

### The structural gap

Every *other* posted finding passes a §5 `$CHANGED_LINES` intersection — the static
specialists apply it inside their own prompts, and the classic synthesiser path is
line-scoped upstream. **Panel-raised findings are the only posting path with no
line-scope filter at all.** A hallucinated line therefore flows straight from
`clusterRaised` → `mapSpreadToTierConfidence` → `renderComments` → the GitHub inline
comment API, where it is 422-rejected (line not in the PR's diff) or, worse on a
partial-file PR, posts against the wrong line.

## Goal

Guarantee that a panel-raised finding never posts against a line the diff did not
touch, while preserving the finding itself (it is real) — demote its anchor rather
than drop it.

## Non-goals

- Touching the classic / synthesiser path (already line-scoped upstream).
- Touching Stage-1 specialist findings (they self-scope in-prompt).
- Any change to how `votes[]` (existing-finding judgements) are handled — this is
  purely about `raised[]` (net-new panel findings).

## Design

Chosen approach: **deterministic guard in review-core + a one-paragraph brief note**
(the deterministic guard is the load-bearing guarantee; the brief note is a quality
lever that reduces demotions so real findings keep precise anchors).

### 1. Data flow — one new arg

The Workflow sandbox has **no filesystem access**, so the changed-line data must
arrive as an `args` value. `skills/review-gh-pr/SKILL.md` Step 2.5 already builds
`$CHANGED_LINES_BLOCK` — a compact, range-collapsed serialisation explicitly noted
(SKILL.md ~line 943-945) as "load-bearing when the block is carried through a Workflow
`args` payload". It is written to `$RESOLVED_TEMP_DIR/changed-lines.txt`.

- Add `changedLinesBlock: $CHANGED_LINES_BLOCK` to the `workflow({scriptPath}, {...})`
  call in SKILL.md (the args object around line 1082-1094).
- Destructure `changedLinesBlock` in review-core's `resolvedArgs` block (~line 189-193).
- Purely additive. The classic and lightweight paths never read it; only the panel
  path consumes it.

### 2. Deterministic guard — review-core.mjs

**New pure helper `parseChangedLines(block)` → `{ [file]: Set<int> }`:**

- Split the block into lines. Skip the `Changed lines:` header and blank lines.
- For each `path: tokens` line, parse the comma-separated tokens:
  - `N-M` → add every integer in the inclusive range to the file's set.
  - bare `N` → add `N`.
  - `near N` → **skip** (deletion anchor, not an added/context line a raised finding
    should anchor to).
- Skip files tagged `(empty — rename only)` and `(deleted)` — they contribute no
  postable added lines (their set stays empty / absent).
- Robust to an empty or missing block: returns `{}`, and the guard below then treats
  every raised finding's file as out-of-scope (safe — demotes to body rather than
  risking a bad post). This is the correct fail-safe direction.

**Guard placement — the raised-cluster → tier loop.**
In `mapSpreadToTierConfidence` (~review-core.mjs:818-837), after the cluster
representative `c.rep` is chosen and **before** it is pushed as a tier finding,
validate its anchor against the parsed map:

```
const changed = parseChangedLines(changedLinesBlock)   // built once, hoisted

// inside the raisedClusters loop, per rep:
const repFile = (rep.file || '').trim()
if (!repFile || !(repFile in changed)) {
    rep.file = ''          // fileless -> isFileless() -> body note, no comment
    rep.line = 0
} else if (!changed[repFile].has(rep.line)) {
    rep.line = 0           // line-0 + real file -> Anchor Ladder -> file-level comment
}
// else: valid inline anchor, keep as-is
```

**Why after clustering, not before.** `clusterRaised` groups raises by
`sameCluster` = same file **and** within `CLUSTER_WINDOW` (3) lines. Zeroing lines
*before* clustering would collapse genuinely distinct same-file findings into one
bogus cluster (all at line 0). The guard therefore runs at the point each surviving
cluster becomes a finding — one representative, one validation.

**Why clearing the file (not just the line) for a bad file.** A finding that names a
file **not in the diff** cannot post even as a file-level comment — GitHub 422s a
file-level comment on a path absent from the PR just as it does a line comment.
Clearing `rep.file` to `''` makes `isFileless(f)` true (review-core.mjs:1011-1014), so
`renderComments` skips it and its detail is carried in the report body instead.

**No new posting code.** Both demotion targets already exist:
- `line = 0` + real file → the `else` branch of `renderComments` (line 1027-1028)
  emits a `subjectType: 'file'` comment.
- empty file → `isFileless` short-circuits (line 1023) → body only.

### 3. Brief note — panel-concern-brief.md

Add one paragraph to the "Rate a finding you raise yourself…" region: a finding you
raise **must** cite a line that appears as an added or context line in the diff you
were handed; if you cannot point to a specific changed line, omit / do not invent one.
This lowers the demotion rate so real raised findings keep their precise inline anchor
— the deterministic guard remains the guarantee regardless of compliance.

## Testing

**Unit (review-core, the existing sandbox-shim harness in `tests/`):**

- `parseChangedLines`:
  - `N-M` range expansion (`12-14` → {12,13,14}).
  - bare integers (`17` → {17}).
  - `near N` anchors skipped.
  - `(empty — rename only)` and `(deleted)` sentinels → no postable lines.
  - empty / missing block → `{}`.
- Guard branches, driven through `mapSpreadToTierConfidence` (or a thin wrapper):
  - raised finding with a valid in-diff line → kept inline, line unchanged.
  - raised finding with a bad line in an in-diff file → `line = 0`, file kept
    (→ file-level).
  - raised finding whose file is not in the diff → `file = ''`, `line = 0`
    (→ fileless / body).
  - clustering integrity: two distinct same-file raises with different bad lines are
    not merged (guard runs post-cluster).

**Structural:** `bash tests/run.sh` (last known green ~794) — meta unchanged, so this
should stay green; confirm.

**Behavioural (the real proof):** re-run the panel review against PR #3 and confirm
the two previously-hallucinated findings (`DayforceOrgUnitsClient` /
`FunctionHandler`) now post as file-level comments (or body notes) rather than
line-anchored to non-existent lines, and that no comment 422s. This same re-run also
verifies Points 2 (jbinspect full path) and 4 (progress-tree phases) from the parent
handover.

## Files touched

- `plugins/code-review-suite/workflows/review-core.mjs` — new `changedLinesBlock`
  destructure, `parseChangedLines` helper, guard in the raised-cluster loop.
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — thread
  `changedLinesBlock: $CHANGED_LINES_BLOCK` into the `workflow()` args object.
- `plugins/code-review-suite/includes/panel-concern-brief.md` — one paragraph on
  citing a real diff line.
- `tests/` — unit coverage for `parseChangedLines` + the three guard branches.

## Sync-note check

The `workflow()` args object is documented in **two** places that must stay in sync:
`skills/review-gh-pr/SKILL.md` (~line 1082-1094) and
`includes/review-pipeline.md` (~line 955-966, confirmed). Adding `changedLinesBlock`
to one requires the identical edit to the other. Check `tests/` for any structural
sync-note assertion over the args key list and extend it if present. The concern-brief
edit is prose-only and carries no sync partner. `review-core.mjs` destructures the new
key at module scope (~line 189-193); helper functions read it as a closure global, the
same pattern `panelSize` / `tempDir` / `intentLedger` already use — no parameter
threading through `panelWrite` → `mapSpreadToTierConfidence`.
