# Design: resolve the Step-numbering collision in `review-gh-pr` SKILL.md

## Context

`plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (~1465 lines) is a load-bearing
review prompt. A skills-quality assessment (via `mattpocock-skills:writing-great-skills`)
ranked its defects; finding #2 was **sprawl + a Step-numbering collision**. The user chose
a **renumber-only** scope: fix the collision, defer all disclosure/extraction cuts.

This is a clarity-only change. It must not alter review behaviour, and it must respect the
deliberate inlining of the review pipeline (agents skip file-path references, so the pipeline
body is inlined on purpose — see the DRY-violation comment at SKILL.md ~114-119).

## The problem

SKILL.md interleaves **two independent `Step N` sequences**:

- **Outer (skill orchestration, `##` headings):**
  Step 1 Gather PR Information → Step 2 Analyse Changes → *[pipeline inlined here]* →
  Step 3 Plan Comments → Step 4 Re-check PR State → Step 5 Add Inline Comments →
  Step 6 Submit Review Verdict → Step 7 Summarize.
- **Inner (review pipeline, `###` headings, inlined from `includes/review-pipeline.md`):**
  Step 1 Determine base branch → Step 2 Measure diff → Step 2.5 → Step 3 Route →
  Step 3.5 → Step 4 Present results.

Bare numbers **1, 2, 3, 4 each appear in both schemes**, and document order runs
outer-2 → inner-1 → inner-4 → outer-3 (the numbering jumps backwards twice). Cross-references
such as "continue to Step 4" or "as in Step 1" are genuinely ambiguous to a reader or agent.

## Constraints discovered (ground truth, not in the original handover)

1. **The inner (pipeline) scheme is off-limits.** Its labels (`Step 2.1`, `2.5`, `2.9`,
   `3.5`, …) are:
   - **byte-locked across three files** by `tests/lib/test_sync_notes.sh` →
     `test_sync_pipeline_inline_matches_canonical` (canonical `includes/review-pipeline.md`
     ≡ `skills/review-gh-pr/SKILL.md` ≡ `commands/pre-review.md`), and
   - **referenced by name** from `workflows/review-core.mjs`, `agents/review-synthesiser.md`,
     and the specialist agent definitions.

   Renumbering the inner scheme is a whole-ecosystem edit — the opposite of low-risk.
   Therefore the **outer** scheme is the one to change.

2. **The outer scheme cannot simply be re-numbered as `Step`** — the inner scheme already
   occupies `Step 1–4`. The outer scheme needs a **distinct label**.

3. **`## Step 6` / `## Step 7` are test anchors.**
   `test_skill_md_step6_references_rubric_and_classes` extracts the slice
   `/^## Step 6: Submit Review Verdict/,/^## Step 7/`. Renaming these headings requires
   updating that test in lockstep.

4. **A cross-file reference exists.** `commands/address-pr-comments.md` (lines 60-61)
   references "skills/review-gh-pr/SKILL.md Step 1" and "…Step 4" (the GraphQL query
   variants). These point at outer steps and must be updated.

5. **The byte-locked pipeline body references outer Step 1 twice per file.** The inlined
   pipeline text contains, in **each** of the three synced files:
   - the **self-re-review carve-out** (canonical line ~836): "…see
     `skills/review-gh-pr/SKILL.md` Step 1…", and
   - the **`$SELF_RE_REVIEW` resolution** (canonical line ~867): "…see
     `skills/review-gh-pr/SKILL.md` Step 1), `false` otherwise."

   Both point at the outer Gather step (self-re-review detection). Renaming outer Step 1
   makes them stale.

## Decision

**Relabel the outer scheme `Stage 1–7`.** "Stage" reads naturally for skill-level
orchestration and leaves the shared pipeline vocabulary (`Step …`) completely untouched.

Resulting structure:

```
## Stage 1: Gather PR Information
## Stage 2: Analyse Changes
   ## Review Pipeline            (inlined, byte-locked — UNCHANGED)
     ### Step 1: Determine base branch
     ### Step 2 / 2.5 / 3 / 3.5 / 4
## Stage 3: Plan Comments
## Stage 4: Re-check PR State Before Posting
## Stage 5: Add Inline Comments
## Stage 6: Submit Review Verdict
## Stage 7: Summarize
```

**The byte-locked self-re-review references are reworded to drop the number entirely**
(not retargeted to "Stage 1"). New wording: "…see the self-re-review detection in
`skills/review-gh-pr/SKILL.md`…". Rationale: this removes the fragile cross-scheme numeric
pointer permanently, so a future renumber can never break it again. It remains a byte-identical
3-way edit (all six sites).

## Edit list (exhaustive)

### A. `skills/review-gh-pr/SKILL.md` — outer heading relabels (7)

Rename the seven outer `##`/`####` `Step N` headings to `Stage N`:

- `## Step 1: Gather PR Information` → `## Stage 1: Gather PR Information`
- `## Step 2: Analyse Changes` → `## Stage 2: Analyse Changes`
- `## Step 3: Plan Comments` → `## Stage 3: Plan Comments`
- `## Step 4: Re-check PR State Before Posting` → `## Stage 4: …`
- `## Step 5: Add Inline Comments` → `## Stage 5: …`
- `## Step 6: Submit Review Verdict` → `## Stage 6: …`
- `## Step 7: Summarize` → `## Stage 7: Summarize`

> Note: `#### Step 7a: Durable full log` is a sub-section of the **inlined pipeline** block
> (present in the canonical and in `commands/pre-review.md`), NOT an outer-scheme heading.
> It stays `Step 7a` — renaming it would break the byte-lock. It is out of scope.

### B. `skills/review-gh-pr/SKILL.md` — outer-scheme back-references

Update every prose reference that points at an **outer** step, to the new `Stage` label.
These are all OUTSIDE the byte-locked pipeline range (which spans "Follow these instructions
exactly…" through "Present the synthesiser's formatted report to the user."). Confirmed sites
(line numbers approximate, verify against current file):

- Line ~90: "if Step 3 routes to the lightweight path" — **inner Step 3 (Route)**, NOT outer.
  LEAVE UNCHANGED.
- Line ~94: "the Step 4.4 alignment carve-out" — **pre-existing dangling reference.** No
  "Step 4.4" heading exists in either scheme (it appears exactly once in the whole plugin).
  It is not part of the collision and predates this change. LEAVE UNCHANGED — fixing it is
  scope creep beyond the renumber. (Noted for a future cleanup pass.)
- Line ~110: "Then skip directly to Step 3." — **outer → `Stage 3` (Plan Comments).** In
  self-re-review mode the pipeline's dispatch steps (inner Step 3 Route / 3.5 Dispatch) are
  explicitly NOT run ("Do NOT dispatch the full agent team… Review the diff yourself"), so
  this jumps past the whole pipeline to the outer Plan Comments step.
- Line ~1126: "continue with the additional checks and Step 3 below" → this points at the
  outer **Plan Comments** step → `Stage 3`.
- Line ~1145: "see the open-thread-only rule in Step 5" → outer → `Stage 5`.
- Line ~1160: "delay between gathering PR information (Step 1)…" → outer → `Stage 1`.
- Line ~1191: "as in Step 1" (pagination) → outer Gather → `Stage 1`.
- Line ~1193: "Compare against Step 1 data" → outer → `Stage 1`.
- Line ~1194: "per the open-thread-only rule in Step 5" → outer → `Stage 5`.
- Line ~1195: "for all subsequent comment `commit_id` fields in Step 5" → outer → `Stage 5`.
- Line ~1396: "Run two checks at the start of Step 6" → outer → `Stage 6`.
- Lines 72, 74: "Step 1 PR data" (inside Stage 1's self-re-review sub-section) → refers to
  the outer Gather step's fetched data → `Stage 1`.

> **Implementation rule:** for each `Step N` reference, determine whether it points at the
> **outer** scheme (Gather/Analyse/Plan/Re-check/Inline/Verdict/Summarize) or the **inner**
> pipeline scheme (base branch/measure/route/dispatch/present). Only outer references become
> `Stage`. Inner references (`Step 2.1`, `Step 2.5`, `Step 2.9`, `Step 3.5`, "Step 4 / report
> rendering", etc.) stay `Step` — they are byte-locked and correct. When ambiguous, read the
> surrounding sentence to resolve which pipeline step it means; do not blanket-replace.

### C. Byte-locked self-re-review reword (6 sites: 2 per file × 3 files)

In **all three** synced files (`includes/review-pipeline.md`, `skills/review-gh-pr/SKILL.md`,
`commands/pre-review.md`), reword both occurrences so they carry no step/stage number:

1. Self-re-review carve-out (canonical ~836): "…(a validated `$LAST_REVIEW_SHA` is set — see
   the self-re-review detection in `skills/review-gh-pr/SKILL.md`)…"
2. `$SELF_RE_REVIEW` resolution (canonical ~867): "…(a validated `$LAST_REVIEW_SHA` is set —
   see the self-re-review detection in `skills/review-gh-pr/SKILL.md`), `false` otherwise."

These edits must be **byte-identical** across the three files or
`test_sync_pipeline_inline_matches_canonical` fails.

### D. `commands/address-pr-comments.md` — cross-file references (2)

- Line 60: "skills/review-gh-pr/SKILL.md Step 1 GraphQL query…" → "…SKILL.md Stage 1
  GraphQL query…"
- Line 61: "skills/review-gh-pr/SKILL.md Step 4 GraphQL query…" → "…SKILL.md Stage 4
  GraphQL query…"

(These name the outer Gather/Re-check GraphQL queries, which live under Stage 1 and Stage 4
after the relabel.)

### E. `tests/lib/test_sync_notes.sh` — test anchor update

`test_skill_md_step6_references_rubric_and_classes` extracts
`sed -n '/^## Step 6: Submit Review Verdict/,/^## Step 7/p'`. Update both anchors to
`## Stage 6: Submit Review Verdict` and `## Stage 7`.

Scan the rest of the test file for any other anchor keyed on an outer `## Step N` heading of
SKILL.md and update those too. (The pipeline-inline / intent-ledger / ci-status-gate / verdict-
rubric sync tests key on the **inner** pipeline headings and prose, which are unchanged.)

## Out of scope (explicitly deferred)

- Disclosure/extraction of Phase 0.7 (trivial-mode), Step 2.5 (`$CHANGED_LINES` algorithm),
  or Step 7a (durable log). Deferred to a possible later PR.
- Any change to the inner pipeline scheme, the inlining, or the pipeline body content.
- `datadog-log-link` frontmatter fix (finding #1) and the `md-to-clipboard`/`web-search`
  prose cuts (findings #3/#4) — separate work items.

## Verification

1. `cd` INTO `~/.claude/plugins/marketplaces/jodre11-plugins` first (the structural suite
   aborts if `git rev-parse --show-toplevel` resolves to the outer `~/.claude` repo), then run
   `tests/run.sh`. All sync tests must pass — in particular the pipeline-inline byte-lock and
   the updated Step-6/7 anchor test.
2. Manually re-read SKILL.md end-to-end: confirm every `Stage N` / `Step N` reference now
   resolves unambiguously, no backwards number jumps within a single scheme, and no dangling
   references.
3. Confirm no behavioural text changed — only labels and pointers.

## Landing

Feature branch + PR (`claude-code-plugins` is a protected repo; never `git push origin main`).
This is a plugin-repo change → PR required.
