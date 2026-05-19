# Whitespace-aware deletion detection and orchestrator COMMENT elision

**Date:** 2026-05-19
**Status:** approved (brainstorm complete; awaiting plan)
**Scope:** code-review-suite plugin only

---

## Summary

Two independent fixes to the code-review-suite, shipped in a single spec:

1. **Whitespace-aware deletion detection.** The "10+ contiguous deleted lines"
   significant-deletion check (Phase 0.7.6 trivial-mode bar and Step 2.7 routing
   flag) currently fires on whitespace-only re-indents whose `-` lines are
   re-added immediately as `+` lines with adjusted whitespace. Re-measure with
   `git diff -w` (ignore-all-whitespace) so the check counts only deletions
   that survive after whitespace differences are collapsed.

2. **Orchestrator COMMENT elision.** Remove every code path where the
   orchestrator (or trivial-mode mini-review) auto-emits a `COMMENT` verdict.
   `final = synth` for every review path. `COMMENT` only ever reaches
   GitHub via explicit user override at the Class A confirmation prompt.

The two changes are unrelated mechanically. Bundling them is a packaging
choice — both surfaced in the same review session, both are small, and
both touch the canonical pipeline include + the verdict rubric, so they
share the same propagation path through inlined consumer files.

---

## Change 1 — Whitespace-aware deletion detection

### Current state

Two sites enforce the "10+ contiguous deleted lines" rule, both raw on the
unfiltered `git diff` output:

- `plugins/code-review-suite/includes/review-pipeline.md` Phase 0.7.6
  (and inlined copies in `commands/pre-review.md` and
  `skills/review-gh-pr/SKILL.md`). Trivial-mode pre-check: if any hunk has 10+
  contiguous `-` lines, fail the trivial bar and fall through to Step 1.
- Same canonical file, Step 2.7 (and inlined copies). Routing flag:
  if any hunk has 10+ contiguous `-` lines, set `$SIGNIFICANT_DELETIONS = true`
  and force the full pipeline path (skipping the lightweight code-analysis
  fast lane).

The duplication is intentional and documented; the two checks share the same
algorithm but execute at different stages so Phase 0.7 can short-circuit
without running Step 2.

The rule misfires on **whitespace-only re-indents.** A 12-line block that is
re-indented (each line emitted as `-` then `+` with different leading
whitespace) registers as 12 contiguous deletions, even though the `-w` view
of the same diff shows zero changed lines for that block. A documented
incident: HavenEngineering/finance-erp-config PR #319 (1 file, 26 lines: a
single value tweak plus a 12-line re-indent of an unchanged
`DistillerConfig` block) triggered both checks and was routed to the full
8-specialist pipeline. Wildly disproportionate for a 1-line semantic change.

### Target state

Both sites measure significant deletions using `git diff -w` (alias for
`--ignore-all-space`, which collapses every whitespace difference — leading,
trailing, and internal). The measurement still scans hunks for 10+ contiguous
`-` lines, but on the `-w` view of the diff. Lines that were re-added with
only whitespace differences are not counted as deletions because they do not
appear as `-` lines in the `-w` output.

The original (non-`-w`) `$FULL_DIFF` remains the authoritative artifact for
the rest of the pipeline — `$CHANGED_LINES`, `$LINE_COUNT`, `$CHANGED_FILES`,
specialist prompts, archaeology-reviewer anchors. Only the deletion-detection
scan switches to `-w`. Whitespace edits remain reviewable surface; the change
is solely about whether a whitespace-driven `-`/`+` pair counts toward the
"this hunk drops a non-trivial chunk of code" heuristic.

### Concrete edits

**Phase 0.7.6 — `plugins/code-review-suite/includes/review-pipeline.md`** and
both inlined copies (`commands/pre-review.md`, `skills/review-gh-pr/SKILL.md`):

Replace the body of the section with content equivalent to:

> If 0.7.5 has already failed (file-count or line-count bar exceeded), skip
> this sub-step entirely and proceed straight to "Trivial bar failed" —
> running a full `git diff` to scan for deletions is moot when the size bar
> already disqualified the diff. Otherwise, run
> `git diff -w [diff-syntax]` and scan hunks for any single hunk with 10+
> contiguous deleted lines. The `-w` flag collapses whitespace-only
> differences before the deletion count is taken: a re-indent that emits each
> line as `-` then `+` with different leading whitespace is not a deletion
> at all under `-w` and contributes zero to the contiguous-`-` run. This
> duplicates Step 2.7's `$SIGNIFICANT_DELETIONS` logic; the duplication is
> intentional to keep Phase 0.7 self-contained as a fast-path pre-check.
>
> If any such hunk exists, the trivial bar fails — fall through to Step 1.

**Step 2.7 — same canonical file** and inlined copies:

Replace the line that reads
`Scan $FULL_DIFF hunks for **significant deletions:** if any single hunk contains 10+ contiguous deleted lines, set $SIGNIFICANT_DELETIONS = true`
with content equivalent to:

> 2.7. Scan for **significant deletions:** run `git diff -w` (using the diff
> syntax determined by `$EMPTY_TREE_MODE`, append `-- "$PATH_SCOPE"` if set)
> and scan its hunks for any single hunk with 10+ contiguous deleted lines.
> If any such hunk exists, set `$SIGNIFICANT_DELETIONS = true`. The `-w`
> view drops whitespace-only differences before the deletion count is taken,
> so re-indents and other whitespace-only edits do not register as
> significant deletions. **Do NOT replace `$FULL_DIFF` with the `-w` view** —
> `$FULL_DIFF` (already captured in 2.2 without `-w`) remains the
> authoritative artifact for `$CHANGED_LINES`, `$LINE_COUNT`, specialists,
> and archaeology anchors. Only the deletion-detection scan uses `-w`.

(Step 2.7 currently scans `$FULL_DIFF` in-memory rather than re-running git
— the new wording requires a separate `git diff -w` invocation. This is one
extra subprocess per review and avoids a second in-memory diff representation
that the rest of the pipeline does not need.)

### Edge cases and confirmations

- **Mixed whitespace + content edits.** A hunk where some `-` lines pair with
  `+` lines that differ only in whitespace, AND other `-` lines have no
  matching `+` (or matching `+` with content differences), counts only the
  unmatched/content-changed lines under `-w`. This is the desired behaviour:
  the unmatched run is the part that would worry archaeology, the
  whitespace-paired part is not.
- **Pure whitespace-only PRs.** A diff whose every `-` line pairs with a
  whitespace-different `+` line will have a `-w` view with zero deletions and
  zero insertions. The trivial-mode size bar still applies (file count, line
  count); these bars use the original diff, not the `-w` view, so a 200-line
  re-indent fails the size bar at 0.7.5 before reaching 0.7.6. Routing-side
  Step 2.7 sets `$SIGNIFICANT_DELETIONS = false`, so the diff routes to
  lightweight or full path based purely on file/line counts and security
  flags — i.e. lightweight for small re-indents.
- **Significant-deletions detection on file-deletion hunks.** A whole-file
  deletion appears as N contiguous `-` lines in `git diff` (where N is the
  file's line count) and is unaffected by `-w` (no `+` to pair against). The
  10-line threshold continues to flag these for full-pipeline routing, which
  is correct — a deleted file is exactly the kind of significant deletion
  archaeology-reviewer exists to investigate.
- **Performance.** `git diff -w` on a typical PR diff is in the tens of
  milliseconds. The Phase 0.7 short-circuit only runs when the trivial bar
  has otherwise passed (≤3 files, ≤30 lines, allow-listed extensions), so
  cost is negligible.

### Test coverage

A focused fixture-based test under `tests/lib/`:

- A unit-style helper test that invokes the deletion-detection logic against
  a synthetic diff fixture containing (a) a 12-line re-indent of an
  otherwise-unchanged block and (b) a 12-line genuine deletion. Assert that
  case (a) does not trigger the flag and case (b) does.
- A sync-test assertion that both consumer copies of the Phase 0.7.6 / Step
  2.7 wording match the canonical, alongside the existing sync checks.

The existing structural-tests harness scans the inlined pipeline content
byte-for-byte against the canonical via `test_sync_notes.sh` — the new
wording propagates through that machinery automatically as long as the spec
edits all three locations identically.

### Files touched (Change 1)

- `plugins/code-review-suite/includes/review-pipeline.md` — canonical edits
  for Phase 0.7.6 and Step 2.7.
- `plugins/code-review-suite/commands/pre-review.md` — inlined copy
  re-synced to canonical.
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — inlined copy
  re-synced to canonical.
- `tests/fixtures/<new>` — new diff fixtures (re-indent vs real deletion).
- `tests/lib/<new or amended>` — assertion that the detection logic
  classifies the two fixtures correctly.

---

## Change 2 — Orchestrator COMMENT elision

### Current state

Three independent code paths can produce a `COMMENT` verdict without an
explicit user-override action. The user has decided that none of them should
exist; `final = synth` for every review path, full stop.

1. **Class B.3 APPROVE → COMMENT downgrade.**
   `skills/review-gh-pr/SKILL.md` Step 6 Class B.3 (current
   "Outstanding peer REQUEST_CHANGES" check). If a different reviewer has a
   live `CHANGES_REQUESTED` review on the current head and the synthesiser
   proposes APPROVE, the orchestrator transforms the proposed action to
   COMMENT to avoid silently overriding the peer. This logic is removed —
   if the synth proposes APPROVE in the face of a peer REQUEST_CHANGES, the
   orchestrator submits APPROVE openly. The user is sovereign at the
   confirmation prompt and can downgrade to COMMENT manually if they wish.

2. **Class A.3 downgraded-prompt template.** `skills/review-gh-pr/SKILL.md`
   Step 6 Class A.3 currently renders three confirmation-prompt templates:
   APPROVE-no-downgrade, APPROVE-downgraded-to-COMMENT-by-Class-B, and
   REQUEST_CHANGES. The middle template, plus the `$DOWNGRADE_REASON`
   variable that drives it, is removed. Two templates remain.

3. **Phase 0.7.7 trivial-mode COMMENT verdict.** `includes/review-pipeline.md`
   (and both inlined consumers) currently lists `COMMENT` as a permitted
   trivial-mode verdict for "minor observations worth surfacing". The verdict
   options are restricted to `APPROVE` and `REQUEST_CHANGES`. Minor
   observations on a trivial-mode mini-review are still expressible as
   inline comments on an APPROVE — that is the existing fallback for any
   APPROVE-with-nudges flow.

### Target state — single rule

> **The orchestrator never auto-emits COMMENT.** `$FINAL_VERDICT` equals the
> synth's verdict (or, in trivial-mode, the mini-review's verdict, which is
> restricted to APPROVE/REQUEST_CHANGES). `COMMENT` is only submitted when
> the user explicitly overrides at the Class A confirmation prompt
> (the `[c]` keypress in the REQUEST_CHANGES template).

That is the entire policy. Everything else is mechanical removal of the
old paths.

### Concrete edits

#### A. `includes/verdict-rubric.md` (canonical) — and inlined copies in `agents/review-synthesiser.md`, `skills/review-gh-pr/SKILL.md` Step 6.

- **Remove the parenthetical "(and APPROVE → COMMENT downgrade)"** from
  the Posting policy table (currently
  `| APPROVE (and APPROVE → COMMENT downgrade) | Post consensus findings…`).
  The row reads `| APPROVE | Post consensus findings with confidence ≥ 75. …`.
- **Rewrite the rubric paragraph** at canonical line 29-32:
  - Old: `The synthesiser produces only APPROVE or REQUEST_CHANGES. COMMENT
    is never a synthesiser output — it can only emerge from the
    orchestrator's APPROVE → COMMENT downgrade (see Posting policy below) or
    from a user override at the confirmation prompt.`
  - New: `The synthesiser produces only APPROVE or REQUEST_CHANGES. COMMENT
    is never a synthesiser output, and the orchestrator never auto-downgrades
    a synth verdict to COMMENT. The only route to a COMMENT verdict is an
    explicit user override at the Class A confirmation prompt.`

#### B. `skills/review-gh-pr/SKILL.md` Step 6 — Class A and Class B edits.

- **Class A.3 — delete the second prompt template** (the
  "synthesiser proposed APPROVE, downgraded to COMMENT by Class B" variant)
  in its entirety. Delete the surrounding rendering instruction
  ("Render ONE of three…") and replace with a two-template equivalent
  ("Render ONE of two…"). Remove all references to `$DOWNGRADE_REASON`
  in Class A (header paragraph + A.2's "If the Class B state checks…
  downgrade APPROVE to COMMENT, $PROPOSED_ACTION = COMMENT and
  $DOWNGRADE_REASON is populated" sentence).
- **Class A.3 — remove provenance variants** for the deleted path. The
  `<provenance>` enumeration loses
  `orchestrator-adjusted to <FINAL>, originally synthesiser-proposed <ORIGINAL>`
  and
  `user override of orchestrator-adjusted <ADJUSTED>, originally synthesiser-proposed <ORIGINAL>`.
  The remaining variants are
  `synthesiser-proposed` and `user override of synthesiser-proposed <ORIGINAL>`.
- **Class A.2 — simplify** to a single line:
  `$PROPOSED_ACTION = $SYNTH_VERDICT.` (no Class B influence).
- **Class B.3 — delete the entire sub-section.** The "Outstanding peer
  REQUEST_CHANGES" check is removed. The Class B opening paragraph drops
  "Run three checks…" and reads "Run two checks…". Class B.1 and B.2 are
  unchanged.
- **Class C — submission mechanics paragraph.** The sentence
  `The flag (--approve / --request-changes / --comment) is selected from
  $FINAL_VERDICT after the user's confirmation prompt response in Class A.`
  is unchanged textually — `--comment` is still selected when the user
  manually overrides at the prompt. (The flag enumeration documents what
  `gh pr review` accepts; it does not assert that the orchestrator emits
  COMMENT on its own.)

#### C. `includes/review-pipeline.md` Phase 0.7.7 — and inlined copies.

- **Strip `COMMENT` from the trivial-mode verdict bullet.** Old:
  `Verdict (omit entirely when $REVIEW_MODE is local — no verdict is produced
  in pre-review): APPROVE if everything looks fine, COMMENT if minor
  observations are worth surfacing, REQUEST_CHANGES if anything is wrong.`
  New: `Verdict (omit entirely when $REVIEW_MODE is local — no verdict is
  produced in pre-review): APPROVE if everything looks fine,
  REQUEST_CHANGES if anything is wrong. (COMMENT is not a permitted
  trivial-mode verdict; minor observations ride alongside APPROVE as
  inline comments.)`
- **Phase 0.7.9 unchanged.** The submission line
  `submit the verdict via gh pr review using --approve, --request-changes,
  or --comment per the verdict` already enumerates only what `gh pr review`
  accepts; the trivial-mode flow naturally won't pick `--comment` once the
  verdict bullet excludes it. No edit needed there.

#### D. Class D — keep as-is.

`Class D — Output filtering` already references `$FINAL_VERDICT == COMMENT`
as the APPROVE→COMMENT downgrade path. With the downgrade removed,
`$FINAL_VERDICT == COMMENT` can still occur via Class A user-override of an
APPROVE proposal. The Class D filter behaviour ("APPROVE or COMMENT —
post consensus findings with confidence ≥ 75") is correct for both routes
and stays. The variable list and assertions in Step 5.5 (`P` =
filtered-by-confidence count) are unchanged for the same reason.

### Test coverage

- **Sync test (`tests/lib/test_sync_notes.sh`).** The existing assertion at
  line ~1030 enforces the synthesiser output's `Verdict:` line includes only
  `APPROVE | REQUEST_CHANGES`. Update its supporting failure message to drop
  "or a Class B downgrade" — the message currently reads
  `… COMMENT is never a synthesiser output, only a Class B downgrade or user override`.
  New text: `… COMMENT is never a synthesiser output, only a user override`.
- **New negative-presence sync assertions.** Add three checks:
  - `skills/review-gh-pr/SKILL.md` does NOT contain
    `Outstanding peer REQUEST_CHANGES` (Class B.3 deleted).
  - `skills/review-gh-pr/SKILL.md` does NOT contain `$DOWNGRADE_REASON`
    (variable retired).
  - `includes/review-pipeline.md` does NOT contain
    `COMMENT if minor observations` (trivial-mode COMMENT option retired).
  All three propagation sites (canonical + 2 inlined) get the
  same assertion via the existing `for skill in "$skill_canonical"
  "$skill_inlined_a" …` loop pattern in `test_sync_notes.sh`.
- **Existing assertions unaffected.** The
  `filtered-by-confidence` rationale and the `C == R - D - X - P`
  reconciliation formula stay because `$FINAL_VERDICT == COMMENT` (via user
  override) still routes through Class D's APPROVE-path filter.

### Files touched (Change 2)

- `plugins/code-review-suite/includes/verdict-rubric.md` — canonical
  rubric paragraph + Posting policy table.
- `plugins/code-review-suite/agents/review-synthesiser.md` — inlined rubric.
- `plugins/code-review-suite/includes/review-pipeline.md` — Phase 0.7.7
  trivial-mode verdict bullet.
- `plugins/code-review-suite/commands/pre-review.md` — inlined Phase 0.7.7.
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — inlined rubric;
  Step 6 Class A.2/A.3 simplification, Class B.3 deletion, header tidy-up.
- `tests/lib/test_sync_notes.sh` — failure-message tweak + three new
  negative-presence assertions.

---

## Out of scope / explicitly deferred

- **Whitespace-aware deletion in archaeology-reviewer's own prompts.** This
  spec does not change the archaeology-reviewer agent definition; the
  agent's analysis still sees the original diff via its self-served
  `git diff` call. Only the orchestrator-side routing flag changes. If the
  agent over-reports on whitespace-only deletions in practice, that is a
  separate prompt-tuning concern.
- **Net-deletion or whitespace-stripped pairing alternative.** The
  brainstorm considered counting `count(-) − count(+)` per hunk, or
  stripping whitespace and pairing `-`/`+` lines. Both were rejected in
  favour of `-w`: it is the simplest, the diff-tool-native semantic
  match, and avoids inventing a new metric.
- **DISMISSED / prior-verdict semantics.** An earlier draft considered a
  prior-verdict mapping table (latest non-DISMISSED verdict → final
  verdict transformation). The user's final policy collapsed this entire
  apparatus: `final = synth`, no prior-verdict lookup. None of that
  machinery is added.
- **User-confirmation prompt redesign.** The two remaining templates
  (APPROVE-no-downgrade, REQUEST_CHANGES) keep their existing copy,
  keypress sets, and override semantics. Only the third template is
  removed. The `[c]` override under the REQUEST_CHANGES template is
  preserved — that is the user's only path to a COMMENT submission and
  the spec keeps it.
- **APPROVE → COMMENT user override.** The APPROVE template currently
  offers `[s/r/n]` (submit / request-changes / cancel) with no `[c]`
  option. This is intentional and unchanged by the spec — the only
  user-driven COMMENT path remains REQUEST_CHANGES → COMMENT via `[c]`.
  Adding an APPROVE → COMMENT user-override path is a separate UX
  decision and is not part of this spec.
