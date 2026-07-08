# review-gh-pr Step→Stage Renumber Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the Step-numbering collision in `review-gh-pr/SKILL.md` by relabelling the outer skill-orchestration scheme to `Stage 1–7`, leaving the byte-locked inner review-pipeline `Step` scheme untouched.

**Architecture:** SKILL.md interleaves two independent `Step N` sequences — an outer skill-orchestration scheme (`##` headings: Gather, Analyse, Plan, Re-check, Inline, Verdict, Summarize) and an inner review-pipeline scheme (`###` headings, inlined verbatim from `includes/review-pipeline.md`). Numbers 1–4 collide. The inner scheme is byte-locked across three files and named from `.mjs`/agent files, so it is immovable; the outer scheme is renamed `Step → Stage`. Two byte-locked pipeline references to "SKILL.md Step 1" are reworded to drop the number entirely (permanent fix). This is a clarity-only change: no review behaviour changes.

**Tech Stack:** Markdown prompt files, bash test harness (`tests/run.sh`), git.

## Global Constraints

- **Bash guard (CLAUDE.md):** one simple command per Bash call — no `&&`, `;`, `|`, `$(...)`, subshells. The `git commit` HEREDOC is the sole exemption.
- **Byte-lock:** `tests/lib/test_sync_notes.sh` → `test_sync_pipeline_inline_matches_canonical` requires the inlined pipeline body (`Follow these instructions exactly…` through `Present the synthesiser's formatted report to the user.`) to be **byte-identical** across `includes/review-pipeline.md`, `skills/review-gh-pr/SKILL.md`, and `commands/pre-review.md`. Any edit inside that range must be applied identically to all three files.
- **Inner scheme is immovable:** never rename `### Step 1: Determine base branch`, `### Step 2`, `Step 2.5`, `### Step 3: Route`, `### Step 3.5`, `### Step 4: Present results`, `Step 7a`, or any `Step 2.1`/`2.9`/etc. prose reference to a pipeline step. Only the OUTER scheme changes.
- **Protected repo:** `claude-code-plugins` requires a PR. Never `git push origin main`.
- **Test cwd gotcha:** `tests/run.sh` must be run from INSIDE `~/.claude/plugins/marketplaces/jodre11-plugins`. If `git rev-parse --show-toplevel` resolves to the outer `~/.claude` repo, the A/B suite sourcing aborts.
- **No behavioural text changes:** only heading labels and cross-references. If a change would alter what any agent does, it is out of scope.

---

## File Structure

- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — MODIFY. Rename 7 outer headings + outer back-references (outside byte-lock) + 2 byte-locked reword sites.
- `plugins/code-review-suite/includes/review-pipeline.md` — MODIFY. 2 byte-locked reword sites only.
- `plugins/code-review-suite/commands/pre-review.md` — MODIFY. 2 byte-locked reword sites only.
- `plugins/code-review-suite/commands/address-pr-comments.md` — MODIFY. 2 cross-file references (`SKILL.md Step 1/4` → `Stage 1/4`).
- `tests/lib/test_sync_notes.sh` — MODIFY. Update the `## Step 6`/`## Step 7` sed anchors in `test_skill_md_step6_references_rubric_and_classes` to `## Stage 6`/`## Stage 7`.

**Task ordering rationale:** The byte-locked reword (Task 1) touches all three synced files identically and is verified by the existing sync test — do it first and in isolation so a byte-lock failure is unambiguous. Then the outer relabel + test-anchor update (Task 2) is SKILL-local plus the two consumer references. Splitting this way means a reviewer can reject the byte-lock edit independently of the heading relabel.

---

## Task 1: Reword the byte-locked self-re-review references (drop the number)

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (2 sites, lines ~836 and ~867)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (2 sites, lines ~942 and ~973)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (2 sites, lines ~837 and ~868)
- Test: `tests/lib/test_sync_notes.sh` → `test_sync_pipeline_inline_matches_canonical` (existing, no change)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. This task is self-contained.

Both reword sites in each file share the identical substring `` `skills/review-gh-pr/SKILL.md` Step 1) `` (note the trailing `)`). This substring appears **exactly twice** in each of the three files and nowhere else, so a single `replace_all` per file is safe and hits both sites. Reword to drop the number: `` `skills/review-gh-pr/SKILL.md`) `` — i.e. delete the ` Step 1` between the closing backtick and the `)`.

Full context of the two sites (identical wording across all three files):

Site A (self-re-review carve-out):
```
- **Self-re-review carve-out:** if the caller is in self-re-review mode (a validated `$LAST_REVIEW_SHA` is set — see `skills/review-gh-pr/SKILL.md` Step 1), append this line to the prompt: `Skip alignment findings …
```
Site B (`$SELF_RE_REVIEW` resolution):
```
Resolve `$SELF_RE_REVIEW` for the args object below: `true` when the caller
is in self-re-review mode (a validated `$LAST_REVIEW_SHA` is set — see
`skills/review-gh-pr/SKILL.md` Step 1), `false` otherwise.
```

- [ ] **Step 1: Run the sync test to confirm the pre-edit baseline passes**

Run (from inside the marketplace repo):
```bash
cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins
```
Then:
```bash
bash tests/run.sh
```
Expected: all tests PASS (baseline is clean on `main` @ current HEAD). Note the total pass count for comparison after edits.

- [ ] **Step 2: Reword both sites in the canonical `includes/review-pipeline.md`**

Use Edit with `replace_all: true` on `includes/review-pipeline.md`:
- old_string: `` `skills/review-gh-pr/SKILL.md` Step 1) ``
- new_string: `` `skills/review-gh-pr/SKILL.md`) ``

This replaces both occurrences (Site A ~836 and Site B ~867) in one call.

- [ ] **Step 3: Reword both sites in `skills/review-gh-pr/SKILL.md`**

Use Edit with `replace_all: true` on `skills/review-gh-pr/SKILL.md`:
- old_string: `` `skills/review-gh-pr/SKILL.md` Step 1) ``
- new_string: `` `skills/review-gh-pr/SKILL.md`) ``

- [ ] **Step 4: Reword both sites in `commands/pre-review.md`**

Use Edit with `replace_all: true` on `commands/pre-review.md`:
- old_string: `` `skills/review-gh-pr/SKILL.md` Step 1) ``
- new_string: `` `skills/review-gh-pr/SKILL.md`) ``

- [ ] **Step 5: Verify no stale byte-locked "SKILL.md Step 1" reference remains**

Run:
```bash
grep -rn "review-gh-pr/SKILL.md\` Step 1" plugins/code-review-suite
```
Expected: **no matches** (all six sites reworded). If any match remains, an Edit missed a file — re-apply.

- [ ] **Step 6: Run the sync test to confirm the byte-lock still holds**

Run:
```bash
bash tests/run.sh
```
Expected: all tests PASS, same total count as Step 1. In particular `pipeline inline sync: skills/review-gh-pr/SKILL.md matches canonical` and `pipeline inline sync: commands/pre-review.md matches canonical` must PASS — this proves the three files stayed byte-identical. If either fails, the diff output will show which file diverged; re-apply the identical reword there.

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md
git commit -m "$(cat <<'EOF'
refactor(code-review): drop stale step number from self-re-review pointer

The inlined pipeline body referenced "SKILL.md Step 1" for self-re-review
detection. Reword to a numberless pointer so a forthcoming outer-scheme
renumber (Step->Stage) cannot make it stale. Byte-identical across all three
synced files.
EOF
)"
```

---

## Task 2: Relabel the outer scheme Step→Stage and update anchors

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (7 headings + outer back-refs, all OUTSIDE the byte-lock)
- Modify: `plugins/code-review-suite/commands/address-pr-comments.md` (lines 60-61)
- Modify: `tests/lib/test_sync_notes.sh` (`test_skill_md_step6_references_rubric_and_classes` sed anchors)
- Test: `tests/run.sh` (existing suite)

**Interfaces:**
- Consumes: Task 1 complete (byte-locked reword landed, so no `Step 1` pointer remains to confuse the relabel).
- Produces: nothing consumed by later tasks.

**Outer-vs-inner classification (apply exactly — do NOT blanket-replace):**

RENAME to `Stage` (outer scheme):
- 7 headings: `## Step 1: Gather PR Information`, `## Step 2: Analyse Changes`, `## Step 3: Plan Comments`, `## Step 4: Re-check PR State Before Posting`, `## Step 5: Add Inline Comments`, `## Step 6: Submit Review Verdict`, `## Step 7: Summarize`.
- Outer back-references (prose + HTML sync-notes), by line:
  - L51 (HTML comment): `Step 4 GraphQL query below` → `Stage 4 GraphQL query below`
  - L72: `the Step 1 PR data` → `the Stage 1 PR data`
  - L74: `the Step 1 PR data` → `the Stage 1 PR data`
  - L1126: `and Step 3 below` → `and Stage 3 below`
  - L1145: `see the open-thread-only rule in Step 5` → `…in Stage 5`
  - L1160: `gathering PR information (Step 1)` → `…(Stage 1)`
  - L1189 (HTML comment): `variant of the Step 1 query above` → `variant of the Stage 1 query above`
  - L1191: `as in Step 1.` → `as in Stage 1.`
  - L1193: `Compare against Step 1 data:` → `Compare against Stage 1 data:`
  - L1194: `the open-thread-only rule in Step 5` → `…in Stage 5`
  - L1195: `during Step 1` → `during Stage 1`; and `fields in Step 5` → `fields in Stage 5`
  - L1396: `at the start of Step 6` → `at the start of Stage 6`

LEAVE UNCHANGED (inner pipeline scheme — byte-locked or pipeline concept):
- L90 `if Step 3 routes to the lightweight path` (inner Route step)
- L94 `the Step 4.4 alignment carve-out` (pre-existing dangling ref; out of scope)
- L110 `Then skip directly to Step 3.` — **EXCEPTION: this is OUTER.** In self-re-review mode the pipeline dispatch is skipped and control jumps to the outer Plan Comments step → rename to `Stage 3`. (See Step 3 below for the exact edit.)
- All `Step 2.1 / 2.2 / 2.4 / 2.5 / 2.7 / 2.85 / 2.9 / 3.5` references, `Step 0.3`, `Step 1` (base branch), `Step 4 / report rendering`, `Step 7a` — inner pipeline, byte-locked, untouched.

- [ ] **Step 1: Rename the 7 outer headings**

Apply 7 Edit calls on `skills/review-gh-pr/SKILL.md` (each old_string is unique):
1. old: `## Step 1: Gather PR Information` → new: `## Stage 1: Gather PR Information`
2. old: `## Step 2: Analyse Changes` → new: `## Stage 2: Analyse Changes`
3. old: `## Step 3: Plan Comments` → new: `## Stage 3: Plan Comments`
4. old: `## Step 4: Re-check PR State Before Posting` → new: `## Stage 4: Re-check PR State Before Posting`
5. old: `## Step 5: Add Inline Comments` → new: `## Stage 5: Add Inline Comments`
6. old: `## Step 6: Submit Review Verdict` → new: `## Stage 6: Submit Review Verdict`
7. old: `## Step 7: Summarize` → new: `## Stage 7: Summarize`

- [ ] **Step 2: Rename the L110 outer back-reference**

Edit `skills/review-gh-pr/SKILL.md`:
- old_string (unique — it is the last line of the self-re-review "Choose review approach" block, before `**Otherwise (standard full review):**`):
```
Then skip directly to Step 3.
```
- new_string:
```
Then skip directly to Stage 3.
```
Confirm uniqueness first with `grep -n "Then skip directly to Step 3." plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (expect exactly one match at ~L110).

- [ ] **Step 3: Rename the remaining outer prose/HTML back-references**

Apply these Edit calls on `skills/review-gh-pr/SKILL.md`. Each old_string below is chosen to be unique in the file (verify with grep if an Edit reports a non-unique match, and widen with surrounding context):

- old: `     - Step 4 GraphQL query below — intentionally omits path` → new: `     - Stage 4 GraphQL query below — intentionally omits path` (L51)
- old: `Resolve `$BASE` from the `baseRefName` field of the Step 1 PR data.` → new: `Resolve `$BASE` from the `baseRefName` field of the Stage 1 PR data.` (L72)
- old: `Resolve `$HEAD_SHA` from the `headRefOid` field of the Step 1 PR data` → new: `Resolve `$HEAD_SHA` from the `headRefOid` field of the Stage 1 PR data` (L74)
- old: `continue with the additional checks and Step 3 below.` → new: `continue with the additional checks and Stage 3 below.` (L1126)
- old: `see the open-thread-only rule in Step 5):` → new: `see the open-thread-only rule in Stage 5):` (L1145)
- old: `delay between gathering PR information (Step 1) and posting` → new: `delay between gathering PR information (Stage 1) and posting` (L1160)
- old: `this GraphQL query is a variant of the Step 1 query above` → new: `this GraphQL query is a variant of the Stage 1 query above` (L1189)
- old: `until all threads are fetched, as in Step 1.` → new: `until all threads are fetched, as in Stage 1.` (L1191)
- old: `Compare against Step 1 data:` → new: `Compare against Stage 1 data:` (L1193)
- old: `Drop any planned replies (per the open-thread-only rule in Step 5).` → new: `Drop any planned replies (per the open-thread-only rule in Stage 5).` (L1194)
- old: `If `headRefOid` differs from the SHA used during Step 1, update `{head_sha}`` → new: `If `headRefOid` differs from the SHA used during Stage 1, update `{head_sha}`` (L1195)
- old: `value for all subsequent comment `commit_id` fields in Step 5.` → new: `value for all subsequent comment `commit_id` fields in Stage 5.` (L1195)
- old: `Run two checks at the start of Step 6, BEFORE presenting` → new: `Run two checks at the start of Stage 6, BEFORE presenting` (L1396)

- [ ] **Step 4: Verify no outer Step reference was missed and no inner Step was touched**

Run:
```bash
grep -nE '(^|[^.0-9])Step [0-9]' plugins/code-review-suite/skills/review-gh-pr/SKILL.md
```
Expected remaining `Step N` matches are ALL inner-pipeline references only: the `### Step 1/2/2.5/3/3.5/4` headings, `Step 2.1/2.2/2.4/2.5/2.7/2.9`, `Step 3.5`, `Step 0.3`, `Step 7a`, `Step 4 (report rendering)`, the byte-locked `Step 1` base-branch prose, the L90 `Step 3` route, and the L94 `Step 4.4` dangling ref. Confirm NO outer heading or outer back-reference (Gather/Analyse/Plan/Re-check/Inline/Verdict/Summarize context) still says `Step`. If one does, apply the missing Edit.

- [ ] **Step 5: Update the cross-file references in `address-pr-comments.md`**

Two Edit calls on `commands/address-pr-comments.md`:
- old: `     - skills/review-gh-pr/SKILL.md Step 1 GraphQL query — omits` → new: `     - skills/review-gh-pr/SKILL.md Stage 1 GraphQL query — omits` (L60)
- old: `     - skills/review-gh-pr/SKILL.md Step 4 GraphQL query — omits path` → new: `     - skills/review-gh-pr/SKILL.md Stage 4 GraphQL query — omits path` (L61)

- [ ] **Step 6: Update the test anchor in `test_sync_notes.sh`**

In `tests/lib/test_sync_notes.sh`, `test_skill_md_step6_references_rubric_and_classes` extracts Step 6's body with a sed range keyed on the heading. Edit both anchors:
- old_string:
```
    step6=$(sed -n '/^## Step 6: Submit Review Verdict/,/^## Step 7/p' "$skill")
```
- new_string:
```
    step6=$(sed -n '/^## Stage 6: Submit Review Verdict/,/^## Stage 7/p' "$skill")
```

Then scan the test file for any other anchor keyed on an outer SKILL.md `## Step N` heading:
```bash
grep -nE '## Step [0-9]' tests/lib/test_sync_notes.sh
```
Expected after the edit: only inner-scheme or non-SKILL anchors remain (e.g. the intent-ledger/ci-status-gate tests key on `## Phase …` and prose, not outer `## Step`). If any other test anchors an outer SKILL.md `## Step N` heading, update it to `## Stage N`.

- [ ] **Step 7: Run the full suite**

Run:
```bash
bash tests/run.sh
```
Expected: all tests PASS, same total count as Task 1 Step 1's baseline. In particular:
- `SKILL.md Step 6 rubric and classes: …` assertions PASS (the retargeted anchor now finds `## Stage 6`).
- All `pipeline inline sync` / `intent-ledger inline sync` / `ci-status-gate inline sync` / `verdict-rubric inline sync` PASS (inner scheme untouched).
If the Step-6 test fails with "Step 6 section extracted / not found", the sed anchor edit in Step 6 was incomplete.

- [ ] **Step 8: Manual read-through for unambiguous references**

Read `skills/review-gh-pr/SKILL.md` end-to-end. Confirm:
- Outer flow reads `Stage 1 → 2 → [pipeline] → 3 → 4 → 5 → 6 → 7` with no backwards jumps.
- Every `Stage N` reference resolves to an outer heading; every remaining `Step N` resolves to an inner pipeline step.
- No dangling reference introduced (the pre-existing `Step 4.4` at L94 is left as-is, out of scope).

- [ ] **Step 9: Commit**

```bash
git add plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/address-pr-comments.md tests/lib/test_sync_notes.sh
git commit -m "$(cat <<'EOF'
refactor(code-review): relabel review-gh-pr outer steps to Stage 1-7

Resolve the Step-numbering collision: the outer skill-orchestration scheme and
the inlined inner pipeline scheme both used Step 1-4, making cross-references
ambiguous. Rename the outer scheme to Stage 1-7 (Gather/Analyse/Plan/Re-check/
Inline/Verdict/Summarize); the byte-locked inner pipeline Step scheme is
untouched. Updates the SKILL.md Step references in address-pr-comments.md and
retargets the Step-6 test anchor in test_sync_notes.sh. Clarity only; no review
behaviour changes.
EOF
)"
```

---

## Task 3: Open the PR

**Files:** none (git/gh only).

**Interfaces:**
- Consumes: Tasks 1 and 2 committed on a feature branch.

- [ ] **Step 1: Create a feature branch (if not already on one)**

```bash
git checkout -b refactor/review-gh-pr-stage-numbering
```
(If the branch already exists from earlier, skip.)

- [ ] **Step 2: Push the branch**

```bash
git push -u origin refactor/review-gh-pr-stage-numbering
```

- [ ] **Step 3: Write the PR body to a temp file**

Write to `$RESOLVED_TEMP_DIR/pr-body.md` (resolve `CLAUDE_TEMP_DIR` from session context). The body must open with a 1–3 sentence non-technical contextual summary (per CLAUDE.md PR rules), then the technical change list. Suggested content:

```
This PR is a readability fix for the code-review plugin's PR-review skill,
part of an ongoing pass to tidy the skills surfaced by the writing-great-skills
assessment. The skill's instructions used the word "Step" for two different
numbered sequences at once, so cross-references like "continue to Step 4" were
ambiguous to both readers and the agent executing them. This change gives the
two sequences distinct names so every reference is unambiguous.

## Changes
- Relabel the outer skill-orchestration scheme in `review-gh-pr/SKILL.md` from
  `Step 1-7` to `Stage 1-7` (Gather, Analyse, Plan, Re-check, Inline, Verdict,
  Summarize). The inner review-pipeline `Step` scheme (inlined verbatim from
  `includes/review-pipeline.md`, byte-locked across three files) is unchanged.
- Reword the byte-locked self-re-review pointer from "SKILL.md Step 1" to a
  numberless pointer so a future renumber cannot make it stale (applied
  identically to all three synced files).
- Update the `SKILL.md Step 1/4` cross-references in `address-pr-comments.md`
  to `Stage 1/4`.
- Retarget the Step-6 heading anchor in `tests/lib/test_sync_notes.sh`.

Clarity-only change: no review behaviour is altered. Structural test suite
(`tests/run.sh`) passes, including all inline byte-lock sync tests.
```

- [ ] **Step 4: Create the PR**

```bash
gh pr create --repo Jodre11/claude-code-plugins --title "refactor(code-review): relabel review-gh-pr outer steps to Stage 1-7" --body-file "$RESOLVED_TEMP_DIR/pr-body.md"
```

- [ ] **Step 5: Report the PR URL to the user.**

---

## Self-Review

**Spec coverage** (checked against `docs/superpowers/specs/2026-07-08-review-gh-pr-step-numbering-design.md`):
- Spec edit-list A (7 outer headings) → Task 2 Step 1. ✓
- Spec edit-list B (outer back-refs, incl. the L90/L94 leave-unchanged and L110 outer exception) → Task 2 Steps 2-3-4. ✓
- Spec edit-list C (6 byte-locked reword sites) → Task 1. ✓
- Spec edit-list D (address-pr-comments 2 refs) → Task 2 Step 5. ✓
- Spec edit-list E (test anchor) → Task 2 Step 6. ✓
- Spec "out of scope" (disclosure cuts, Step 4.4 dangling ref, inner scheme) → honoured; L94 explicitly left. ✓
- Spec verification (cd-into-repo + tests/run.sh, manual read, no behaviour change) → Task 1 Steps 1/6, Task 2 Steps 7/8. ✓
- Spec landing (PR, protected repo) → Task 3. ✓

**Placeholder scan:** No TBD/TODO/"handle appropriately". Every edit gives exact old/new strings.

**Type/label consistency:** `Stage` used uniformly; inner `Step` labels never renamed. The reword substring is identical across Tasks (`` `skills/review-gh-pr/SKILL.md` Step 1) `` → `` `skills/review-gh-pr/SKILL.md`) ``).
