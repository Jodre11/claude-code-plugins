# Code Review Dogfood Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address the 18 consensus findings (3 Important + 13 Suggestion + 2 synthesiser) from the 2026-05-14 EMPTY_TREE dogfood review of the code-review plugin, plus 2 user observations: enforce that static-analysis findings flow to stochastic cross-reviewers, and suppress GitHub verdict guidance in `pre-review` (local) mode where no formal review is being produced. Contested findings from the dogfood are excluded.

**Architecture:** Each task targets one finding (or a tightly-coupled group). Where a defect spans the canonical (`includes/review-pipeline.md`) and its inlined consumers (`commands/pre-review.md`, `skills/review-gh-pr/SKILL.md`), the canonical is edited first and the byte-diff sync test (`test_sync_pipeline_inline_matches_canonical`) is the change-detector for propagation. New focused sync tests are added where existing coverage doesn't catch the specific drift class.

**Tech Stack:** Markdown (plugin authoring); Bash (`tests/run.sh`, sync tests using `sed`/`diff`); shell `gh`/`git` for runtime behaviour.

---

## File Structure

Files touched by this plan:

- `plugins/code-review/includes/review-pipeline.md` — canonical pipeline body. Edits here propagate to consumers via byte-diff sync test.
- `plugins/code-review/commands/pre-review.md` — local-mode consumer; inlines pipeline body.
- `plugins/code-review/skills/review-gh-pr/SKILL.md` — PR-mode consumer; inlines pipeline body.
- `plugins/code-review/includes/cross-review-mode.md` — canonical cross-review block; propagation-list comment in HTML header.
- `plugins/code-review/includes/specialist-context.md` — canonical specialist runtime context (parser rules, scope filter).
- `plugins/code-review/includes/intent-ledger.md` — canonical Phase 0 ledger logic.
- `plugins/code-review/agents/{security,correctness,consistency,style,reuse,efficiency,archaeology,ui,code-analysis}-reviewer.md` — 9 agents that inline the `$CHANGED_LINES` rule block.
- `plugins/code-review/agents/review-synthesiser.md` — synthesiser agent definition; reviewer-count and dissent-source counts live here.
- `plugins/code-review/commands/address-pr-comments.md` — auxiliary command; sync-note rephrasing.
- `plugins/code-review/.claude-plugin/plugin.json` — plugin manifest; keywords array.
- `tests/lib/test_sync_notes.sh` — host for new sync tests.
- `tests/run.sh` — test driver (no edits expected; new test functions are picked up by harness).

Each task below is self-contained: it states which files to touch, the exact edits, and the verification command.

---

## Task 1: Fix `$AGENT_PROMPT` `Empty tree mode` literal (Finding #1, Important)

The template contains literal `Empty tree mode: true` while the bullet underneath says omit-when-false. LLMs reproducing the template verbatim emit `Empty tree mode: true` on non-empty-tree runs, which switches specialists to wrong `git diff` syntax. Same defect in all three template copies; the synthesiser-prompt template at line 984/985/1083 already uses the correct interpolated form.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md:571,580`
- Modify: `plugins/code-review/commands/pre-review.md:572,581` (mirrored via byte-diff sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md:670,679` (mirrored via byte-diff sync test)
- Test: `tests/lib/test_sync_notes.sh` (new function `test_sync_agent_prompt_empty_tree_mode_uses_variable`)

- [ ] **Step 1: Add the failing focused sync test**

Append to `tests/lib/test_sync_notes.sh` (after the last test function, before any closing footer):

```bash
test_sync_agent_prompt_empty_tree_mode_uses_variable() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "AGENT_PROMPT empty-tree-mode variable" "code-review plugin not found"
        return
    fi

    # The $AGENT_PROMPT template (Step 2.9 in the canonical) and its inlined copies
    # MUST use $EMPTY_TREE_MODE interpolation, not a literal "true"/"false". Search for
    # the offending literal string within the template fence range.
    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "AGENT_PROMPT empty-tree-mode variable: $basename_file" "file not found"
            continue
        fi

        # Extract the AGENT_PROMPT fenced block: from "Define `\$AGENT_PROMPT`" through
        # the next "```" closer. grep the block for a literal "Empty tree mode: true"
        # OR "Empty tree mode: false" that is NOT inside backticks (the bullet at line
        # ~580 legitimately quotes "Empty tree mode: true" in backticks while documenting
        # the rule — that is fine).
        local block
        block=$(awk '
            /Define `\$AGENT_PROMPT`/ { in_block = 1 }
            in_block && /^```$/ {
                if (saw_fence) { in_block = 0 } else { saw_fence = 1 }
                next
            }
            in_block && saw_fence { print }
        ' "$file")

        if [[ -z "$block" ]]; then
            fail "AGENT_PROMPT empty-tree-mode variable: $basename_file" "AGENT_PROMPT fenced block not found"
            continue
        fi

        if echo "$block" | grep -qE '^Empty tree mode: (true|false)$'; then
            fail "AGENT_PROMPT empty-tree-mode variable: $basename_file" "template literally hardcodes 'Empty tree mode: true|false' instead of '\$EMPTY_TREE_MODE' interpolation"
        else
            pass "AGENT_PROMPT empty-tree-mode variable: $basename_file uses interpolation"
        fi
    done
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/run.sh 2>&1 | grep -E "AGENT_PROMPT empty-tree-mode variable"`
Expected: 3 FAIL lines (one per file) — each says "template literally hardcodes 'Empty tree mode: true|false'".

- [ ] **Step 3: Fix the canonical**

Edit `plugins/code-review/includes/review-pipeline.md`. Change line 571 from:

```
Empty tree mode: true
```

to:

```
Empty tree mode: $EMPTY_TREE_MODE
```

Change line 580 from:

```
- Include the `Empty tree mode: true` line only when `$EMPTY_TREE_MODE` is true; omit the line entirely otherwise
```

to:

```
- Include the `Empty tree mode: $EMPTY_TREE_MODE` line only when `$EMPTY_TREE_MODE` is true; omit the line entirely otherwise (specialists detect `Empty tree mode: true` by exact match — a literal `false` value would not match anyway, but omission is the contract)
```

- [ ] **Step 4: Propagate to consumers**

Apply the same line edits at `plugins/code-review/commands/pre-review.md:572` and `:581`, and at `plugins/code-review/skills/review-gh-pr/SKILL.md:670` and `:679`.

- [ ] **Step 5: Run tests to verify they all pass**

Run: `tests/run.sh`
Expected:
- The 3 new `AGENT_PROMPT empty-tree-mode variable` tests PASS.
- The existing `test_sync_pipeline_inline_matches_canonical` continues to PASS (byte-identity preserved across canonical + 2 consumers).

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md \
        tests/lib/test_sync_notes.sh
git commit -m "fix(code-review): \$AGENT_PROMPT uses \$EMPTY_TREE_MODE interpolation

The template hardcoded 'Empty tree mode: true' regardless of actual flag
value. Specialists copying the template verbatim would switch to two-arg
'git diff' syntax even on three-dot-diff runs, producing wrong-scoped
reviews. Add a focused sync test that asserts the template uses variable
interpolation in canonical + both inlined consumers."
```

---

## Task 2: Fix deletion-path `a/` prefix interaction with specialist scope filter (Finding #2, Important)

The Step 2.5 walk sets `$current_file = a/$pending_original_path` for fully-deleted files. Specialists look up plain paths against `$CHANGED_LINES`, so deleted-file entries are silently invisible to all non-archaeology specialists. Archaeology can match the prefixed key but its inline-comment contract (`file:N` where N is a still-present new-file line) is impossible for fully-deleted files. We adopt **Strategy 1** from the synthesiser report: drop the `a/` prefix, add an explicit `(deleted)` token in the serialised block, and update the archaeology contract to treat fully-deleted-file findings as top-level prose, not inline comments.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md:493,510,517-521`
- Modify: `plugins/code-review/commands/pre-review.md:494,511,518-522` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md:592,609,616-620` (mirrored via sync test)
- Modify: `plugins/code-review/includes/specialist-context.md:36-49` (add `(deleted)` token to parser grammar)
- Modify: `plugins/code-review/agents/archaeology-reviewer.md` (the deletion-finding rule — exact section to be located in Step 1 below)

- [ ] **Step 1: Locate the archaeology-reviewer deletion rule section**

Run: `grep -n "deleted\|deletion" plugins/code-review/agents/archaeology-reviewer.md`
Capture the line numbers covering the inline-comment-anchoring rule for deletions. Read those lines plus 5 lines of surrounding context to confirm the exact text to replace in Step 5 below.

- [ ] **Step 2: Fix the canonical Step 2.5 deletion-path table row**

Edit `plugins/code-review/includes/review-pipeline.md:493`. Change:

```
| `+++ b/<path>` | Set `$current_file = <path>`; if path is `/dev/null` (file deleted), set `$current_file = a/$pending_original_path` so deletions still map; reset `$new_line_no = 0` |
```

to:

```
| `+++ b/<path>` | Set `$current_file = <path>`; if path is `/dev/null` (file deleted), set `$current_file = $pending_original_path` (the original path, no prefix) and mark it as deleted for the serialiser; reset `$new_line_no = 0` |
```

- [ ] **Step 3: Fix the canonical "Deletions of entire files" prose**

Edit `plugins/code-review/includes/review-pipeline.md:509-512`. Change:

```
**Deletions of entire files.** If a file is deleted (`+++ b/dev/null`), all
deleted lines map to `("near", 1)` against the original path under `a/`.
Archaeology-reviewer is the typical consumer; other specialists report 0
findings for fully-deleted files (there's nothing to review on the new side).
```

to:

```
**Deletions of entire files.** If a file is deleted (`+++ b/dev/null`), the
serialiser emits a single line `<original-path> (deleted): near 1` (no `a/`
prefix; the `(deleted)` sentinel is mutually exclusive with `(empty — rename
only)`). Archaeology-reviewer is the typical consumer; other specialists
report 0 findings for fully-deleted files (there's nothing to review on the
new side). Archaeology findings on fully-deleted files cannot be anchored
inline (no still-present line exists in the new tree) — see
`agents/archaeology-reviewer.md` for the top-level-prose rule.
```

- [ ] **Step 4: Update the canonical serialisation example**

Edit `plugins/code-review/includes/review-pipeline.md:517-521`. Change the existing block so it shows the new `(deleted)` token form. Replace:

```
Changed lines:
path/to/file1.cs: 12, 13, 14, 17, near 22
path/to/file2.md: 5, 6, 7
path/to/renamed.txt: (empty — rename only)
```

with:

```
Changed lines:
path/to/file1.cs: 12, 13, 14, 17, near 22
path/to/file2.md: 5, 6, 7
path/to/renamed.txt: (empty — rename only)
path/to/deleted-file.cs (deleted): near 1
```

- [ ] **Step 5: Update the archaeology-reviewer deletion-finding rule**

Edit `plugins/code-review/agents/archaeology-reviewer.md` at the line numbers captured in Step 1. Add (or replace, if a similar rule already exists) the following rule near the existing `near N` guidance:

```
- **Fully-deleted files.** If a file appears in `$CHANGED_LINES` with the
  `(deleted)` sentinel, your finding cannot be inline-anchored — there is no
  still-present line in the new tree to attach a GitHub PR comment to.
  Instead, emit the finding as top-level prose in your `## Archaeology
  Review Findings` section with the file path stated in the body (no `File:`
  citation line). Distinguish these clearly: heading the finding with
  "Finding (deleted file)" or similar so the synthesiser can route it to
  the top-level review summary rather than to an inline comment.
```

- [ ] **Step 6: Update the specialist-context.md parser grammar to recognise `(deleted)`**

Edit `plugins/code-review/includes/specialist-context.md:36-41`. Change:

```
If a `Changed lines:` block is present in `$ARGUMENTS`, store the lines that follow it
(through to the next blank line or end of prompt) as `$CHANGED_LINES_BLOCK`. Parse each
line as `<file path>: <comma-separated tokens>` where tokens are either bare integers
(touched lines in the new file) or `near N` (deletion anchors — used by
`archaeology-reviewer`). A token of `(empty — rename only)` means the file accepts no
findings (rename without content change).
```

to:

```
If a `Changed lines:` block is present in `$ARGUMENTS`, store the lines that follow it
(through to the next blank line or end of prompt) as `$CHANGED_LINES_BLOCK`. Parse each
line as `<file path>[ (sentinel)]: <comma-separated tokens>`. Tokens are one of:
- a bare integer (touched line in the new file)
- `near N` (deletion anchor — used by `archaeology-reviewer`)
- `(empty — rename only)` as the entire token list — file accepts no findings (rename
  without content change)

The optional sentinel after the file path is `(deleted)` for fully-deleted files;
when present, the file accepts findings only from `archaeology-reviewer`, and those
findings must be top-level prose (no inline anchoring) per
`agents/archaeology-reviewer.md`.
```

- [ ] **Step 7: Propagate Step 2/3/4 edits to consumers**

Apply the same edits at `plugins/code-review/commands/pre-review.md:494,511,518-522` and at `plugins/code-review/skills/review-gh-pr/SKILL.md:592,609,616-620`. Use the byte-diff sync test as the change-detector — running `tests/run.sh` after each consumer edit confirms byte-parity with the canonical.

- [ ] **Step 8: Run tests to verify all pass**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES. No other tests regress.

- [ ] **Step 9: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md \
        plugins/code-review/includes/specialist-context.md \
        plugins/code-review/agents/archaeology-reviewer.md
git commit -m "fix(code-review): drop a/ prefix on deleted-file CHANGED_LINES keys

The a/ prefix on deleted-file entries silently broke specialist scope-filter
lookups (specialists key by plain path) and archaeology-reviewer's inline-
comment contract (no still-present line in the new tree). Replace the prefix
with an explicit '(deleted)' sentinel in the serialised block, update the
parser grammar in specialist-context.md, and document the top-level-prose
rule for archaeology findings on fully-deleted files."
```

---

## Task 3: Add `alignment-reviewer.md` to `cross-review-mode.md` propagation list (Finding #3, Important)

The propagation comment in the canonical lists 8 agents but omits `alignment-reviewer.md`, despite the existing sync test (`test_sync_cross_review_mode_inline_matches_canonical`) covering it and the alignment-reviewer agent inlining the block correctly. The comment is the first thing a future editor reads when extending the block, so the omission is observable drift between policy text and reality.

**Files:**
- Modify: `plugins/code-review/includes/cross-review-mode.md:3-5`

- [ ] **Step 1: Edit the propagation-list comment**

Edit `plugins/code-review/includes/cross-review-mode.md`. Change lines 1-5:

```
<!-- CROSS-REVIEW MODE — this is the canonical source.
Edit this file first, then propagate to all specialist agents:
archaeology-reviewer.md, consistency-reviewer.md, correctness-reviewer.md,
efficiency-reviewer.md, reuse-reviewer.md, security-reviewer.md,
style-reviewer.md, ui-reviewer.md.
```

to:

```
<!-- CROSS-REVIEW MODE — this is the canonical source.
Edit this file first, then propagate to all specialist agents:
alignment-reviewer.md, archaeology-reviewer.md, consistency-reviewer.md,
correctness-reviewer.md, efficiency-reviewer.md, reuse-reviewer.md,
security-reviewer.md, style-reviewer.md, ui-reviewer.md.
```

(Alphabetical order. `alignment-reviewer.md` is added at the start of the first line.)

- [ ] **Step 2: Run tests to verify the existing sync test still passes**

Run: `tests/run.sh 2>&1 | grep "cross-review-mode inline sync"`
Expected: 9 PASS lines (one per agent file), unchanged.

- [ ] **Step 3: Commit**

```bash
git add plugins/code-review/includes/cross-review-mode.md
git commit -m "docs(code-review): add alignment-reviewer to cross-review-mode propagation list

The canonical's HTML maintenance comment listed 8 agents but omitted
alignment-reviewer.md, even though the byte-diff sync test already
covers it and the agent inlines the block correctly. Future editors
reading the comment first would have skipped propagation on alignment."
```

---

## Task 4: Clamp `$deletion_anchor` to `max(C, 1)` (Finding #4)

For a hunk like `@@ -1,N +0,0 @@` (deletion at top of fully-deleted file), `C = 0`, producing an invalid `near 0` anchor. The `("near", 1)` override in the prose at line 510 currently masks the bug, but a future refactor that drops the override would silently regress.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md:494`
- Modify: `plugins/code-review/commands/pre-review.md:495` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md:593` (mirrored via sync test)

- [ ] **Step 1: Fix the canonical hunk-handler row**

Edit `plugins/code-review/includes/review-pipeline.md:494`. Change:

```
| `@@ -A,B +C,D @@` | Parse `C` from the new-file range; set `$new_line_no = C`; reset `$deletion_anchor = C` |
```

to:

```
| `@@ -A,B +C,D @@` | Parse `C` from the new-file range; set `$new_line_no = C`; reset `$deletion_anchor = max(C, 1)` (clamp prevents `near 0` for top-of-file deletions where `C = 0`) |
```

- [ ] **Step 2: Propagate to consumers**

Apply the same edit at `plugins/code-review/commands/pre-review.md:495` and at `plugins/code-review/skills/review-gh-pr/SKILL.md:593`.

- [ ] **Step 3: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md
git commit -m "fix(code-review): clamp \$deletion_anchor to max(C, 1) in Step 2.5 walk

For full-file deletions (@@ -1,N +0,0 @@) C is 0, which produces an
invalid 'near 0' anchor. The line-510 override masks this in the
canonical path, but a future refactor that drops the override would
silently regress. Make the clamp explicit at the source."
```

---

## Task 5: Extract `$CHANGED_LINES` rule block to canonical with sync test (Finding #5)

A 7-line scope-filter rule block is duplicated verbatim across 9 agents (`security`, `correctness`, `consistency`, `style`, `reuse`, `efficiency`, `archaeology`, `ui`, `code-analysis`) without a canonical source, propagation comment, or sync test — a notable regression from the canonical+propagation+sync-test pattern used elsewhere. `alignment-reviewer.md` does NOT currently include the rule (verified via `grep -c`); we leave alignment outside this propagation set since alignment findings legitimately span pre-existing lines in scope-aware ways.

**Files:**
- Modify: `plugins/code-review/includes/specialist-context.md` (append canonical rule block)
- Modify: 9 agent files: `plugins/code-review/agents/{security,correctness,consistency,style,reuse,efficiency,archaeology,ui,code-analysis}-reviewer.md` — replace inline block with verbatim copy of the new canonical, add maintenance comment
- Test: `tests/lib/test_sync_notes.sh` (new function `test_sync_changed_lines_rule_matches_canonical`)

- [ ] **Step 1: Capture the existing rule block from a reference agent**

Run: `sed -n '/^- Only report findings on lines listed in/,/^- Be precise/p' plugins/code-review/agents/correctness-reviewer.md`
The output is the canonical text we will extract. Save it (mentally — copy is short) for use in Steps 2 and 4.

- [ ] **Step 2: Add the canonical rule block to specialist-context.md**

Edit `plugins/code-review/includes/specialist-context.md`. Append a new section at the end of the file:

```markdown

### Output line filter

<!-- CHANGED_LINES OUTPUT FILTER — this is the canonical source.
Edit this file first, then propagate to all specialist agents that inline
this block: archaeology-reviewer.md, code-analysis.md, consistency-reviewer.md,
correctness-reviewer.md, efficiency-reviewer.md, reuse-reviewer.md,
security-reviewer.md, style-reviewer.md, ui-reviewer.md.

alignment-reviewer.md does NOT inline this block — alignment findings
legitimately span pre-existing lines (intent drift is rare but can manifest
on lines the diff doesn't touch). Other static-analysis specialists
(jbinspect, eslint, ruff, trivy) inline their own scope rules per
includes/static-analysis-context.md. -->

> **CHANGED_LINES OUTPUT FILTER — MANDATORY**
>
> Only report findings on lines listed in `$CHANGED_LINES` for that file
> (parsed from the `Changed lines:` block in your prompt). Do NOT emit
> findings on unchanged lines, even FYI — pre-existing issues are out of
> scope. You may still *read* unchanged context to understand the change,
> but the finding's `File:` line must reference a `file:line` whose line
> appears in `$CHANGED_LINES[file]`. Files appearing in the `Changed lines:`
> block with `(empty — rename only)` accept no findings at all (the rename
> itself is the only change).
```

- [ ] **Step 3: Add the new sync test (failing initially)**

Append to `tests/lib/test_sync_notes.sh` (next to `test_sync_cross_review_mode_inline_matches_canonical`, ideally directly after it for proximity):

```bash
test_sync_changed_lines_rule_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "CHANGED_LINES rule sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/specialist-context.md"
    if [[ ! -f "$canonical" ]]; then
        skip "CHANGED_LINES rule sync" "canonical file not found"
        return
    fi

    # Extract the canonical block from the MANDATORY blockquote header.
    local canonical_body
    canonical_body=$(sed -n '/^> \*\*CHANGED_LINES OUTPUT FILTER — MANDATORY\*\*/,$ p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "CHANGED_LINES rule sync: canonical body extracted" "no body found"
        return
    fi

    local agent
    for agent in \
        "$cr/agents/archaeology-reviewer.md" \
        "$cr/agents/code-analysis.md" \
        "$cr/agents/consistency-reviewer.md" \
        "$cr/agents/correctness-reviewer.md" \
        "$cr/agents/efficiency-reviewer.md" \
        "$cr/agents/reuse-reviewer.md" \
        "$cr/agents/security-reviewer.md" \
        "$cr/agents/style-reviewer.md" \
        "$cr/agents/ui-reviewer.md"; do

        local basename_agent
        basename_agent=$(basename "$agent")

        if [[ ! -f "$agent" ]]; then
            fail "CHANGED_LINES rule sync: $basename_agent" "file not found"
            continue
        fi

        # Each agent embeds the block bounded by the same blockquote header and the
        # next "---" separator. Mirror the cross-review-mode extraction pattern.
        local inline_body
        inline_body=$(sed -n '/^> \*\*CHANGED_LINES OUTPUT FILTER — MANDATORY\*\*/,/^---$/ p' "$agent" | sed '$ d')

        if [[ -z "$inline_body" ]]; then
            fail "CHANGED_LINES rule sync: $basename_agent" "inline block not found"
            continue
        fi

        if [[ "$canonical_body" == "$inline_body" ]]; then
            pass "CHANGED_LINES rule sync: $basename_agent matches canonical"
        else
            local tmp1 tmp2
            tmp1=$(mktemp)
            tmp2=$(mktemp)
            echo "$canonical_body" > "$tmp1"
            echo "$inline_body" > "$tmp2"
            local diff_output
            diff_output=$(diff -u --label "canonical" --label "$basename_agent" "$tmp1" "$tmp2" | head -30 || true)
            rm -f "$tmp1" "$tmp2"
            fail "CHANGED_LINES rule sync: $basename_agent matches canonical" "$diff_output"
        fi
    done
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `tests/run.sh 2>&1 | grep "CHANGED_LINES rule sync"`
Expected: 9 FAIL lines — each says "inline block not found" (the new bordered blockquote form is not in the agents yet).

- [ ] **Step 5: Replace the inline rule in each of the 9 agents**

For each of the 9 agents listed in Step 3, find the existing 7-line bullet starting with `- Only report findings on lines listed in` (in the `## Rules` section) and replace it with the canonical block form. The agent's `## Rules` section keeps its other bullets; only the scope-filter bullet is replaced. The replacement form is:

```markdown
<!-- CHANGED_LINES OUTPUT FILTER — inlined from includes/specialist-context.md (canonical source).
Edit the include first, then propagate to all listed specialists. -->

> **CHANGED_LINES OUTPUT FILTER — MANDATORY**
>
> Only report findings on lines listed in `$CHANGED_LINES` for that file
> (parsed from the `Changed lines:` block in your prompt). Do NOT emit
> findings on unchanged lines, even FYI — pre-existing issues are out of
> scope. You may still *read* unchanged context to understand the change,
> but the finding's `File:` line must reference a `file:line` whose line
> appears in `$CHANGED_LINES[file]`. Files appearing in the `Changed lines:`
> block with `(empty — rename only)` accept no findings at all (the rename
> itself is the only change).

---
```

The `---` separator at the end is the test's right-anchor; it must be present.

- [ ] **Step 6: Run test to verify it passes**

Run: `tests/run.sh 2>&1 | grep "CHANGED_LINES rule sync"`
Expected: 9 PASS lines.

- [ ] **Step 7: Commit**

```bash
git add plugins/code-review/includes/specialist-context.md \
        plugins/code-review/agents/archaeology-reviewer.md \
        plugins/code-review/agents/code-analysis.md \
        plugins/code-review/agents/consistency-reviewer.md \
        plugins/code-review/agents/correctness-reviewer.md \
        plugins/code-review/agents/efficiency-reviewer.md \
        plugins/code-review/agents/reuse-reviewer.md \
        plugins/code-review/agents/security-reviewer.md \
        plugins/code-review/agents/style-reviewer.md \
        plugins/code-review/agents/ui-reviewer.md \
        tests/lib/test_sync_notes.sh
git commit -m "refactor(code-review): canonicalise \$CHANGED_LINES scope-filter rule

The 7-line scope-filter rule was duplicated verbatim across 9 specialist
agents with no canonical source, no propagation comment, and no sync test
— regressing from the established canonical+propagation+sync-test pattern.
Extract to includes/specialist-context.md, add a maintenance comment, and
add test_sync_changed_lines_rule_matches_canonical to enforce byte-parity."
```

---

## Task 6: Inline `gh api` pattern in Phase 0.7.9 instead of cross-referencing SKILL.md (Finding #6)

Phase 0.7.9's "Mode `pr`" branch references `skills/review-gh-pr/SKILL.md` Step 5 for the inline-comment posting pattern. In `pre-review.md`, that branch is dead code (always `$REVIEW_MODE = local`). In `review-pipeline.md` after inlining into `SKILL.md`, the reference becomes a forward reference within the same document, silently breakable on Step renumbering. Inlining the actual `gh api` invocation pattern is cleaner.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md` (find the Phase 0.7.9 Mode `pr` block — line numbers vary by version; capture in Step 1)
- Modify: `plugins/code-review/commands/pre-review.md` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (mirrored via sync test)

- [ ] **Step 1: Locate the Phase 0.7.9 Mode `pr` block**

Run: `grep -n "Phase 0.7.9\|gh api repos" plugins/code-review/includes/review-pipeline.md`
Capture the line range for the "**Mode `pr`:**" sub-section under Phase 0.7.9 (it spans roughly lines 415–425 in the current canonical, but verify).

- [ ] **Step 2: Inline the `gh api` pattern in the canonical**

Edit `plugins/code-review/includes/review-pipeline.md` at the captured line range. Replace:

```
**Mode `pr`:**

For each inline comment, post via the `gh api repos/{owner}/{repo}/pulls/{pr}/comments`
pattern documented in Step 5 of `skills/review-gh-pr/SKILL.md` (use `--input -`
heredoc for the body, `-F` for integer parameters, `-f side='LEFT|RIGHT'` based on
diff polarity).
```

with:

```
**Mode `pr`:**

For each inline comment, post via:

```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
    --method POST \
    -F commit_id="$HEAD_SHA" \
    -f path="<file path>" \
    -F line=<integer line number> \
    -f side='RIGHT' \
    --input - <<'EOF'
{
  "body": "<comment body>"
}
EOF
```

Use `RIGHT` side for additions and modifications, `LEFT` for deletions. The
`--input -` heredoc carries the comment body to avoid shell-quoting issues.
```

- [ ] **Step 3: Propagate to consumers**

Apply the same edit at the corresponding locations in `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md`. The byte-diff sync test catches any miss.

- [ ] **Step 4: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES. No other tests regress.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md
git commit -m "refactor(code-review): inline gh api pattern in Phase 0.7.9 Mode pr

The cross-reference to 'Step 5 of skills/review-gh-pr/SKILL.md' becomes
a forward reference within SKILL.md itself after inlining, silently
breakable on Step renumbering. Inline the gh api pattern directly."
```

---

## Task 7: Fix `review-synthesiser.md` "8-10 specialist reviewers" → "8–13" (Finding #7)

The synthesiser's frontmatter description says "8-10 specialist reviewers". The pipeline dispatches 8 core + up to 5 conditional (jbinspect, ui, eslint, ruff, trivy) = 8–13.

**Files:**
- Modify: `plugins/code-review/agents/review-synthesiser.md:17`

- [ ] **Step 1: Edit the description line**

Edit `plugins/code-review/agents/review-synthesiser.md:17`. Change:

```
- **Specialist findings** — structured reports from 8-10 specialist reviewers
```

to:

```
- **Specialist findings** — structured reports from 8–13 specialist reviewers (8 core + up to 5 conditional: jbinspect, ui, eslint, ruff, trivy)
```

- [ ] **Step 2: Run tests**

Run: `tests/run.sh`
Expected: no regressions.

- [ ] **Step 3: Commit**

```bash
git add plugins/code-review/agents/review-synthesiser.md
git commit -m "docs(code-review): correct synthesiser specialist count (8-10 -> 8-13)

The pipeline dispatches up to 13 specialists (8 core + 5 conditional)
when all language flags fire. The frontmatter understated the maximum."
```

---

## Task 8: Fix `review-synthesiser.md` cross-reviewer count condition (Finding #8)

The static-analysis carve-out hardcodes "8 cross-reviewers + this synthesiser = 9 sources" and the rendered audit-trail literal says "D of 9 sources dissented". When `$UI_DETECTED` is true there are 9 cross-reviewers and 10 sources. The synthesiser should compute the count from the actual cross-reviewer roster it received.

**Files:**
- Modify: `plugins/code-review/agents/review-synthesiser.md:84-93`

- [ ] **Step 1: Locate exact lines and context**

Run: `sed -n '80,100p' plugins/code-review/agents/review-synthesiser.md`
Confirm the surrounding text before editing.

- [ ] **Step 2: Edit the dissent-budget prose**

Edit `plugins/code-review/agents/review-synthesiser.md:84-87`. Change:

```
and may be adjusted per the per-source dissent budget defined in §10 — each of the 9
sources (8 cross-reviewers + this synthesiser) may apply
up to 5 points of confidence drop based on the strength of its dissent. The clamp is
`Confidence = max(50, 100 - Σ dissent)`.
```

to:

```
and may be adjusted per the per-source dissent budget defined in §10 — each source
(this synthesiser plus every cross-reviewer that fired for the run) may apply up to
5 points of confidence drop based on the strength of its dissent. Let `S` = total
sources = 1 (synthesiser) + cross-reviewer count from the dispatch table at
`includes/review-pipeline.md` Step 5 (8 when `$UI_DETECTED` is false, 9 when true).
The clamp is `Confidence = max(50, 100 - Σ dissent)`.
```

- [ ] **Step 3: Edit the rendered audit-trail literal**

Edit `plugins/code-review/agents/review-synthesiser.md:91-93`. Change:

```
- **Confidence:** <C>  *(adjusted from 100 — <D> of 9 sources dissented)*
```

to:

```
- **Confidence:** <C>  *(adjusted from 100 — <D> of <S> sources dissented)*
```

(where `<S>` resolves to the value computed in Step 2 above).

- [ ] **Step 4: Run tests**

Run: `tests/run.sh`
Expected: no regressions. (Behavioural smoke test for static-analysis severity-locked policy may need an update if it asserts the literal "9 sources"; check `tests/lib/test_static_analysis_behavioural.sh` for hardcoded `9` references.)

- [ ] **Step 5: Update behavioural smoke test if needed**

Run: `grep -n "9 sources\|of 9 sources" tests/lib/test_static_analysis_behavioural.sh`
If matches found, update them to use `<S>` or to expect both `8` and `9` based on the test fixture's UI-detection state. If no matches, no change needed.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review/agents/review-synthesiser.md
# also add the behavioural test if updated in Step 5
git commit -m "fix(code-review): synthesiser dissent-source count is conditional on UI

The hardcoded '9 sources' literal undercounted by one when \$UI_DETECTED
is true (9 cross-reviewers + synthesiser = 10 sources). Replace with a
computed S = 1 + cross-reviewer count from the dispatch table."
```

---

## Task 9: Document self-re-review carve-out impact on `$CROSS_REVIEW_COUNT` (Finding #9)

In self-re-review mode (Step 4.4), `alignment-reviewer` is suppressed as a specialist; Step 5's `$CROSS_REVIEW_COUNT` table doesn't acknowledge that `cross-review-alignment` would have nothing to opine on. Document the carve-out at both Step 4.4 and Step 5.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md` (Step 4.4 + Step 5 table)
- Modify: `plugins/code-review/commands/pre-review.md` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (mirrored via sync test)

- [ ] **Step 1: Locate Step 4.4 and Step 5 in the canonical**

Run: `grep -n "Step 4.4\|Step 5: Cross-review\|CROSS_REVIEW_COUNT" plugins/code-review/includes/review-pipeline.md`

- [ ] **Step 2: Add a sentence to Step 4.4**

Edit `plugins/code-review/includes/review-pipeline.md` Step 4.4. Append a final sentence to the paragraph that describes the carve-out:

```
Step 5's cross-review dispatch must also skip `cross-review-alignment` in
self-re-review mode — there are no alignment-reviewer specialist findings
to feed it, so its run would emit `0 opinions` for trivial reasons.
`$CROSS_REVIEW_COUNT` reduces by 1 in this mode (see Step 5 table footnote).
```

- [ ] **Step 3: Add a footnote to the Step 5 dispatch table**

Edit the `$CROSS_REVIEW_COUNT` table at line ~854 of the canonical. Below the table, add:

```
**Self-re-review carve-out:** `$CROSS_REVIEW_COUNT` decrements by 1 when in
self-re-review mode (see Step 4.4) — `cross-review-alignment` is not
dispatched because alignment-reviewer's specialist pass was suppressed. The
table values above describe the standard (non-re-review) path.
```

- [ ] **Step 4: Propagate to consumers**

Apply both edits to `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md` at the corresponding locations.

- [ ] **Step 5: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md
git commit -m "docs(code-review): document self-re-review impact on \$CROSS_REVIEW_COUNT

Step 4.4 suppresses alignment-reviewer; Step 5 needs to skip
cross-review-alignment too (no findings to opine on). Document the
interaction in both sections so future readers don't infer a stalled
cross-reviewer dispatch."
```

---

## Task 10: Use `--arg` pattern for `$CURRENT_USER` in Phase 0.4 jq filters (Finding #10)

Phase 0.4 builds a jq filter via shell interpolation; `address-pr-comments.md` already uses the safer `--arg user "$CURRENT_USER"` pattern. The injection risk is bounded (GitHub login characters are constrained), so this is consistency + defence-in-depth.

**Files:**
- Modify: `plugins/code-review/commands/pre-review.md:127`
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (line near 225 — verify in Step 1)
- Modify: `plugins/code-review/includes/intent-ledger.md` (line near 121 — verify in Step 1)

- [ ] **Step 1: Locate all three call sites**

Run: `grep -n 'select(.author.login ==' plugins/code-review/commands/pre-review.md plugins/code-review/skills/review-gh-pr/SKILL.md plugins/code-review/includes/intent-ledger.md`
Confirm exact line numbers.

- [ ] **Step 2: Replace interpolation with `--arg` in each location**

Edit each of the three files. Replace:

```bash
gh pr view "$ARGUMENTS" --json reviews --jq '.reviews | map(select(.author.login == "'"$CURRENT_USER"'")) | sort_by(.submittedAt) | reverse | .[0]'
```

with:

```bash
gh pr view "$ARGUMENTS" --json reviews \
  | jq --arg user "$CURRENT_USER" \
       '.reviews | map(select(.author.login == $user)) | sort_by(.submittedAt) | reverse | .[0]'
```

- [ ] **Step 3: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES (assuming the relevant copies are within the synced range).

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md \
        plugins/code-review/includes/intent-ledger.md
git commit -m "refactor(code-review): use jq --arg for \$CURRENT_USER in Phase 0.4 filters

Aligns with the address-pr-comments.md convention and removes the
shell-interpolation seam. Defence-in-depth: GitHub usernames are
currently safe to interpolate, but a future change feeding a non-login
string into the same template would not be."
```

---

## Task 11: Document `$PATH_SCOPE` glob semantics (Finding #11)

The validation regex permits `*`; `Path scope: *` would select all files. Quotes prevent shell glob expansion at invocation but git pathspec interprets the glob. Add an explanatory comment so the behaviour is documented as intentional.

**Files:**
- Modify: `plugins/code-review/includes/specialist-context.md` (line near 22)
- Modify: `plugins/code-review/commands/pre-review.md` (line near 454)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (line near 552)
- Modify: `plugins/code-review/agents/review-synthesiser.md` (line near 33)

- [ ] **Step 1: Locate all four call sites**

Run: `grep -n 'a-zA-Z0-9/_.\\\-\*' plugins/code-review/includes/specialist-context.md plugins/code-review/commands/pre-review.md plugins/code-review/skills/review-gh-pr/SKILL.md plugins/code-review/agents/review-synthesiser.md`

- [ ] **Step 2: Add the explanatory note immediately after each regex**

For each of the four files, find the line containing the regex `^[a-zA-Z0-9/_.\-*]+$` and append (as the next paragraph or as a parenthetical at the end of the existing paragraph):

```
The `*` character is intentional: it is forwarded to `git diff -- <pathspec>`
which interprets it via git pathspec semantics (`*` matches across directory
boundaries; `**` is also recognised). The double-quotes around the value
prevent shell glob expansion; git pathspec is the only consumer of the glob.
A `Path scope: *` selects all files (intentional override behaviour).
```

- [ ] **Step 3: Run tests**

Run: `tests/run.sh`
Expected: relevant sync tests still PASS.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review/includes/specialist-context.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md \
        plugins/code-review/agents/review-synthesiser.md
git commit -m "docs(code-review): clarify \$PATH_SCOPE glob semantics are intentional

The validation regex permits '*' so users can supply git pathspecs like
'src/**/*.cs'. Quotes prevent shell expansion; git pathspec interprets
the glob. Document the contract so a future tightening doesn't surprise
existing users."
```

---

## Task 12: Reword `$INTENT_LEDGER` defensive-check error message (Finding #12)

The Step 2.9 error message says "Phase 0 was bypassed or failed to halt", implying a control-flow defect. An empty `user_paste` source is a data defect; the message points the reader at the wrong root cause.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md:561-563`
- Modify: `plugins/code-review/commands/pre-review.md:561-563` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (line near 661 — verify)

- [ ] **Step 1: Locate and verify line numbers in each file**

Run: `grep -n "INTENT_LEDGER missing" plugins/code-review/includes/review-pipeline.md plugins/code-review/commands/pre-review.md plugins/code-review/skills/review-gh-pr/SKILL.md`

- [ ] **Step 2: Edit the canonical error message**

Edit `plugins/code-review/includes/review-pipeline.md` at the captured line(s). Change:

```
**Defensive check:** if `$INTENT_LEDGER` is empty or unset at this point, this is a
pipeline bug — Phase 0 must have built it or halted. STOP and report
`Pipeline error: $INTENT_LEDGER missing at Step 2.9 — Phase 0 was bypassed or failed
to halt`.
```

to:

```
**Defensive check:** if `$INTENT_LEDGER` is empty or unset at this point, this is a
pipeline bug — Phase 0 must have built it from a sufficient source, halted on
insufficiency, or returned a non-empty user-paste. STOP and report
`Pipeline error: $INTENT_LEDGER missing at Step 2.9 — Phase 0 either built it from
a sufficient source, halted on insufficiency, or returned an empty user-paste; one
of these post-conditions failed to fire`.
```

- [ ] **Step 3: Propagate to consumers**

Apply the same edit at `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md` at the corresponding locations.

- [ ] **Step 4: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md
git commit -m "docs(code-review): clarify \$INTENT_LEDGER defensive-check error

The previous message implied a control-flow defect, missing the
data-defect case where user_paste returned empty. Reword to enumerate
the three possible failed post-conditions."
```

---

## Task 13: Fix `address-pr-comments.md` sync-note `totalCount` attribution (Finding #13)

The sync note says the query "adds isOutdated, isMinimized, totalCount fields". `totalCount` is on `reviewThreads` (the parent edge), not on the comment nodes.

**Files:**
- Modify: `plugins/code-review/commands/address-pr-comments.md` (line near 31 — verify)

- [ ] **Step 1: Locate the sync note**

Run: `grep -n "isOutdated\|isMinimized\|totalCount" plugins/code-review/commands/address-pr-comments.md`

- [ ] **Step 2: Reword the note**

Edit `plugins/code-review/commands/address-pr-comments.md`. Find the sync note that lists `isOutdated, isMinimized, totalCount` and reword to:

```
adds `isOutdated`, `isMinimized` on comment nodes, and `totalCount` on the `reviewThreads` edge
```

(keeping the surrounding context unchanged).

- [ ] **Step 3: Run tests**

Run: `tests/run.sh`
Expected: no regressions.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review/commands/address-pr-comments.md
git commit -m "docs(code-review): clarify totalCount field placement in sync note

totalCount is on the reviewThreads edge, not on comment nodes. The
sync note grouped them together as if all three were at the same
level."
```

---

## Task 14: Add missing keywords to `plugin.json` (Finding #14)

Keywords array omits `alignment`, `pre-review`, `trivial-mode` — all README-prominent features.

**Files:**
- Modify: `plugins/code-review/.claude-plugin/plugin.json:8-22`

- [ ] **Step 1: Edit the keywords array**

Edit `plugins/code-review/.claude-plugin/plugin.json`. Change the `keywords` array from:

```json
  "keywords": [
    "code-review",
    "agents",
    "security",
    "correctness",
    "consistency",
    "style",
    "archaeology",
    "reuse",
    "efficiency",
    "jetbrains",
    "accessibility",
    "ui",
    "synthesis"
  ]
```

to:

```json
  "keywords": [
    "code-review",
    "agents",
    "security",
    "correctness",
    "consistency",
    "style",
    "archaeology",
    "reuse",
    "efficiency",
    "alignment",
    "jetbrains",
    "accessibility",
    "ui",
    "synthesis",
    "pre-review",
    "trivial-mode",
    "static-analysis",
    "eslint",
    "ruff",
    "trivy"
  ]
```

(Adds `alignment` next to other domain keywords; adds `pre-review`, `trivial-mode`, `static-analysis`, `eslint`, `ruff`, `trivy` at the end.)

- [ ] **Step 2: Run tests**

Run: `tests/run.sh`
Expected: manifest schema test still PASSES (no `version` field added; valid JSON).

- [ ] **Step 3: Commit**

```bash
git add plugins/code-review/.claude-plugin/plugin.json
git commit -m "docs(code-review): add missing keywords to plugin manifest

alignment, pre-review, trivial-mode, and the four static-analysis
specialists were absent from keywords despite being prominent features
in the README and runtime."
```

---

## Task 15: Consolidate Step 2's three `git diff` calls into one (Finding #15)

Steps 2.2, 2.3, 2.4 all run `git diff` against the same base/head. Step 2.5 already requires the LLM to walk `$FULL_DIFF` line-by-line, so deriving file count and shortstat from that walk is incremental. Cross-review opinions split (archaeology disagreed; efficiency escalated to also fold in Source 1's call). The synthesiser concluded the original justification has dissolved post-Step-2.5; we consolidate Steps 2.2/2.3/2.4 only and leave Source 1 alone for now (it runs in Phase 0, before Step 2's full diff is captured).

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md:458-465`
- Modify: `plugins/code-review/commands/pre-review.md` (corresponding lines)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (corresponding lines)

- [ ] **Step 1: Locate the Step 2.2/2.3/2.4 block in the canonical**

Run: `grep -n "Step 2:\|2.2\|2.3\|2.4" plugins/code-review/includes/review-pipeline.md | head`
Capture the exact line range.

- [ ] **Step 2: Rewrite Steps 2.2-2.4 as a single full-diff call followed by in-LLM derivation**

Edit `plugins/code-review/includes/review-pipeline.md` at the captured range. Replace the three sub-steps with:

```
2.2. Run `git diff` (append `-- "$PATH_SCOPE"` if set) using the diff syntax
determined by `$EMPTY_TREE_MODE` (two-arg when true, three-dot when false) and
store as `$FULL_DIFF`. If `$FULL_DIFF` is empty, report "No changes found
against $BASE" and stop.

2.3. Derive `$CHANGED_FILES` from `$FULL_DIFF` by collecting the path component
of every `+++ b/<path>` header (or `a/<path>` for `+++ b/dev/null` deletions),
deduplicated.

2.4. Derive `$FILE_COUNT` (count of `$CHANGED_FILES`) and `$LINE_COUNT` (sum
of `+`-prefixed and `-`-prefixed lines in `$FULL_DIFF`, excluding `+++` and
`---` headers) from the same walk that builds `$CHANGED_LINES` in Step 2.5.
A rename with no content change contributes 0 to `$LINE_COUNT`.
```

(This makes Steps 2.3 and 2.4 in-memory derivations; the only `git diff` call is in Step 2.2.)

- [ ] **Step 3: Update Step 2.5's preamble to acknowledge the shared walk**

Edit Step 2.5's first sentence (line ~470 of the canonical) to add:

```
The same line-by-line walk produced by Step 2.4 may compute `$FILE_COUNT`
and `$LINE_COUNT` (Step 2.4) alongside `$CHANGED_LINES` — derive them in a
single pass over `$FULL_DIFF`.
```

- [ ] **Step 4: Propagate to consumers**

Apply the same edits at `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 5: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md
git commit -m "perf(code-review): consolidate Step 2's three git diff calls into one

Step 2.5 already walks \$FULL_DIFF line-by-line; deriving \$CHANGED_FILES,
\$FILE_COUNT, and \$LINE_COUNT from the same walk costs nothing extra and
eliminates two git invocations per review. Source 1's --diff-filter=AM
call in Phase 0 is left intact (it runs before Step 2)."
```

---

## Task 16: Short-circuit Phase 0.7.6 when 0.7.5 has already failed (Finding #16)

Phase 0.7.6 runs a full `git diff` to scan for significant deletions. If 0.7.5 (size bar) has already failed, 0.7.6's result is moot.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md:361-367`
- Modify: `plugins/code-review/commands/pre-review.md` (corresponding lines)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (corresponding lines)

- [ ] **Step 1: Edit the canonical Phase 0.7.6 preamble**

Edit `plugins/code-review/includes/review-pipeline.md:361-367`. Change:

```
### 0.7.6 Check for significant deletions

Run `git diff [diff-syntax]` and scan hunks for any single hunk with 10+ contiguous
deleted lines. This duplicates Step 2.7's `$SIGNIFICANT_DELETIONS` logic; the
duplication is intentional to keep Phase 0.7 self-contained as a fast-path pre-check.

If any such hunk exists, the trivial bar fails — fall through to Step 1.
```

to:

```
### 0.7.6 Check for significant deletions

If 0.7.5 has already failed (file-count or line-count bar exceeded), skip this
sub-step entirely and proceed straight to "Trivial bar failed" — running a full
`git diff` to scan for deletions is moot when the size bar already disqualified
the diff. Otherwise, run `git diff [diff-syntax]` and scan hunks for any single
hunk with 10+ contiguous deleted lines. This duplicates Step 2.7's
`$SIGNIFICANT_DELETIONS` logic; the duplication is intentional to keep Phase 0.7
self-contained as a fast-path pre-check.

If any such hunk exists, the trivial bar fails — fall through to Step 1.
```

- [ ] **Step 2: Propagate to consumers**

Apply the same edit at `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 3: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md
git commit -m "perf(code-review): short-circuit Phase 0.7.6 when size bar already failed

0.7.6 runs a full git diff to scan for significant deletions. If 0.7.5
already failed (file/line count exceeded the trivial bar), the result
is discarded. Skip 0.7.6 in that case."
```

---

## Task 17: Document lightweight-path alignment carve-out for self-re-review (Finding #17)

The lightweight path dispatches `code-analysis` for diffs ≤5 files / ≤150 lines. `code-analysis` covers all domains in a single pass, but Step 4.4's self-re-review carve-out (which excludes `alignment-reviewer` to avoid the diminishing-returns cycle) is not mentioned for the lightweight path. A self-re-review hitting the lightweight path will still raise alignment findings.

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md` (Step 3 routing block)
- Modify: `plugins/code-review/commands/pre-review.md` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (mirrored via sync test)
- Modify: `plugins/code-review/agents/code-analysis.md` (acknowledge the carve-out)

- [ ] **Step 1: Locate Step 3 in the canonical**

Run: `grep -n "Step 3: Route\|Lightweight path" plugins/code-review/includes/review-pipeline.md | head`

- [ ] **Step 2: Add a self-re-review note to Step 3**

Edit `plugins/code-review/includes/review-pipeline.md` Step 3. After the "Lightweight path" condition list and before "Announce: …", add:

```
**Self-re-review carve-out:** if the caller is in self-re-review mode (see
`skills/review-gh-pr/SKILL.md` Step 1), the lightweight path's `code-analysis`
agent receives an additional prompt directive: "Skip alignment findings — this
is a self-re-review pass; intent and scope were evaluated on the prior review."
This preserves the Step 4.4 carve-out's intent on the lightweight path.
Alternatively, a self-re-review may force the full path (skipping Step 3)
if the policy is changed in a future revision; the current behaviour is the
in-prompt directive.
```

- [ ] **Step 3: Update `code-analysis.md` to honour the directive**

Edit `plugins/code-review/agents/code-analysis.md`. Add (after any existing scope rules):

```
- **Self-re-review.** If your prompt contains "Skip alignment findings — this
  is a self-re-review pass", do not emit any finding whose severity rationale
  is intent drift or scope creep. Bugs, regressions, and security issues
  introduced by fix commits remain in scope. This carve-out matches Step 4.4
  in the full pipeline.
```

- [ ] **Step 4: Propagate Step 2 edits to consumers**

Apply the Step 3 edit to `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md`. Also update `skills/review-gh-pr/SKILL.md` Step 1's self-re-review block to add the alignment-skip directive to the `code-analysis` dispatch when on the lightweight path (find the existing dispatch in Step 3 / Step 4 of SKILL.md).

- [ ] **Step 5: Run tests**

Run: `tests/run.sh`
Expected: `test_sync_pipeline_inline_matches_canonical` PASSES.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md \
        plugins/code-review/agents/code-analysis.md
git commit -m "docs(code-review): extend self-re-review carve-out to lightweight path

The lightweight path's code-analysis agent covers all domains including
alignment. Without an explicit carve-out, a self-re-review on a small
diff (lightweight path) still raises alignment findings, defeating the
diminishing-returns prevention from Step 4.4."
```

---

## Task 18: Enumerate `$CHANGED_LINES` parser token forms in `specialist-context.md` (Finding #18)

The parser-rule prose says "tokens are either bare integers (touched lines in the new file) or `near N` (deletion anchors)" but the canonical serialiser also emits `(empty — rename only)` (entire token list) and — after Task 2 — `(deleted)` as a path-suffix sentinel. Enumerate all forms explicitly with examples to avoid LLMs treating non-listed forms as malformed tokens.

**Files:**
- Modify: `plugins/code-review/includes/specialist-context.md:36-49`

This task partially overlaps with Task 2 Step 6, which already updated specialist-context.md to add the `(deleted)` sentinel. Confirm Task 2 ran before this task; this task adds the example block.

- [ ] **Step 1: Confirm Task 2 has merged the `(deleted)` sentinel description**

Run: `grep -n "deleted\|empty — rename only" plugins/code-review/includes/specialist-context.md`
Expected: the parser-rule paragraph already enumerates `(deleted)` as a path-suffix sentinel and `(empty — rename only)` as the entire-token-list sentinel (per Task 2 Step 6).

- [ ] **Step 2: Append an examples block immediately after the parser-rule paragraph**

Edit `plugins/code-review/includes/specialist-context.md`. After the bullet list of token forms (added in Task 2 Step 6), append:

```markdown

**Example block:**

```
Changed lines:
src/Foo.cs: 12, 13, 14, 17, near 22
docs/README.md: 5, 6, 7
src/Renamed.cs: (empty — rename only)
src/RemovedHelper.cs (deleted): near 1
```

In this example, `Foo.cs` accepts findings on lines 12-14 and 17 (added/modified)
and on line 22 (deletion anchor — archaeology only). `README.md` accepts findings
on lines 5-7. `Renamed.cs` accepts no findings (rename without content change).
`RemovedHelper.cs` is fully deleted; only archaeology may emit findings, and they
must be top-level prose (no inline anchor).
```

- [ ] **Step 3: Run tests**

Run: `tests/run.sh`
Expected: no regressions.

- [ ] **Step 4: Commit**

```bash
git add plugins/code-review/includes/specialist-context.md
git commit -m "docs(code-review): add \$CHANGED_LINES parser examples block

The parser-rule paragraph enumerates four token forms (bare integer,
near N, (empty — rename only), (deleted) sentinel). Add an example
block showing all four in context so LLMs reading the rule have a
concrete reference."
```

---

## Task 19: Lock in static-analysis → stochastic-cross-reviewer feed with a structural test (Observation 1)

The current policy is correct and documented in two places: `includes/review-pipeline.md` Step 5.2 sub-step 3 ("Include findings from any static-analysis specialist (`jbinspect`, `eslint`, `ruff`, `trivy`) for ALL cross-reviewers — they are excluded from receiving cross-review, not from being reviewed") and `includes/static-analysis-context.md` §8 ("Their findings ARE shown to the eight cross-reviewers (per Step 5.2 of the pipeline)"). However, this is a quietly load-bearing rule with no automated enforcement: a future edit that drops sub-step 3 or rewords §8 would silently regress the cross-feed without any test failing. Add a structural sync test that asserts both passages remain present and that the static-analysis specialists they enumerate match the dispatch list at `review-pipeline.md` Step 4.2.

Note: this is preventive infrastructure, not a current defect. The behaviour is already correct.

**Files:**
- Test: `tests/lib/test_sync_notes.sh` (new function `test_sync_static_analysis_cross_feed_documented`)

- [ ] **Step 1: Add the failing test**

Append to `tests/lib/test_sync_notes.sh` (next to the other sync tests):

```bash
test_sync_static_analysis_cross_feed_documented() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis cross-feed documentation" "code-review plugin not found"
        return
    fi

    local pipeline="$cr/includes/review-pipeline.md"
    local sa_context="$cr/includes/static-analysis-context.md"
    local cr_mode="$cr/includes/cross-review-mode.md"

    local file
    for file in "$pipeline" "$sa_context" "$cr_mode"; do
        if [[ ! -f "$file" ]]; then
            fail "static-analysis cross-feed documentation: $(basename "$file") present" "file not found"
            return
        fi
    done

    # Assertion 1: review-pipeline.md Step 5.2 sub-step 3 must require static-analysis
    # findings to be included in EVERY cross-reviewer's prompt. The phrase "for ALL
    # cross-reviewers" is the load-bearing part.
    if grep -qE 'Include findings from any static-analysis specialist .*for ALL cross-reviewers' "$pipeline"; then
        pass "static-analysis cross-feed: Step 5.2 sub-step 3 includes findings for ALL cross-reviewers"
    else
        fail "static-analysis cross-feed: Step 5.2 sub-step 3 includes findings for ALL cross-reviewers" \
            "the canonical Step 5.2 sub-step 3 in review-pipeline.md must contain the load-bearing phrase 'Include findings from any static-analysis specialist ... for ALL cross-reviewers' — this is what wires static-analysis findings into the stochastic cross-reviewer prompts"
    fi

    # Assertion 2: static-analysis-context.md §8 must affirm that findings ARE shown
    # to cross-reviewers. The phrase "shown to the" + "cross-reviewers" is the claim.
    if grep -qE 'findings ARE shown to .*cross-reviewers' "$sa_context"; then
        pass "static-analysis cross-feed: §8 affirms findings shown to cross-reviewers"
    else
        fail "static-analysis cross-feed: §8 affirms findings shown to cross-reviewers" \
            "static-analysis-context.md §8 must contain the affirmation 'findings ARE shown to ... cross-reviewers' — this is the consumer-side documentation of the same policy"
    fi

    # Assertion 3: cross-review-mode.md HTML header must restate the same rule for
    # specialists reading their own inlined block.
    if grep -qE 'findings are visible to other cross-reviewers' "$cr_mode"; then
        pass "static-analysis cross-feed: cross-review-mode.md restates rule"
    else
        fail "static-analysis cross-feed: cross-review-mode.md restates rule" \
            "cross-review-mode.md HTML header must restate that static-analysis findings are visible to cross-reviewers"
    fi

    # Assertion 4: the static-analysis specialist list must match across the two
    # canonicals. Both documents enumerate (jbinspect, eslint, ruff, trivy).
    local pipeline_list sa_list
    pipeline_list=$(grep -oE '`jbinspect`,[^)]*`trivy`' "$pipeline" | head -1)
    sa_list=$(grep -oE 'jbinspect, eslint, ruff, trivy' "$sa_context" | head -1)
    if [[ -n "$pipeline_list" && -n "$sa_list" ]]; then
        pass "static-analysis cross-feed: specialist enumeration consistent across canonicals"
    else
        fail "static-analysis cross-feed: specialist enumeration consistent across canonicals" \
            "review-pipeline.md must list (jbinspect, eslint, ruff, trivy) in the cross-feed sub-step; static-analysis-context.md must list them in §8 — found pipeline='$pipeline_list', sa='$sa_list'"
    fi
}
```

- [ ] **Step 2: Run test to verify it passes against current canonical**

Run: `tests/run.sh 2>&1 | grep "static-analysis cross-feed"`
Expected: 4 PASS lines. (The current canonical already satisfies all four assertions; the test exists to catch *future* regression.)

- [ ] **Step 3: Verify the test catches drift (manual check, no commit)**

Temporarily edit `plugins/code-review/includes/review-pipeline.md` to remove the phrase `for ALL cross-reviewers` from Step 5.2 sub-step 3. Run `tests/run.sh 2>&1 | grep "static-analysis cross-feed"`. Expected: 1 FAIL line for the Step 5.2 assertion. Revert the edit.

- [ ] **Step 4: Commit**

```bash
git add tests/lib/test_sync_notes.sh
git commit -m "test(code-review): assert static-analysis cross-feed documentation

The policy that static-analysis findings flow to all stochastic
cross-reviewers (Step 5.2 sub-step 3 + static-analysis-context.md §8)
is load-bearing but had no automated enforcement. Add four structural
assertions that catch regressions in either canonical, including drift
in the specialist enumeration."
```

---

## Task 20: Suppress verdict guidance in `pre-review` (local) mode (Observation 2)

`pre-review` is a local-only command — it produces output for a human reviewer who decides what (if anything) to act on. There is no GitHub review to submit, so verdict guidance (`APPROVE`/`COMMENT`/`REQUEST_CHANGES`) is meaningless and misleading. Currently the synthesiser is mode-blind: its `## CI Status` section talks about "Verdict constraint", its `Rules` section mandates verdict recommendations driven by `$CI_STATUS_BODY`, and the trivial-mode mini-review (Phase 0.7.7) drafts a "Verdict" header in both `pr` and `local` modes. This task makes verdict suppression explicit when `$REVIEW_MODE = local`.

**Files:**
- Modify: `plugins/code-review/agents/review-synthesiser.md` (input list, Output Format `## CI Status` block, Rules section, dispatcher)
- Modify: `plugins/code-review/includes/review-pipeline.md` (Step 6.2 synthesiser dispatch — add `$REVIEW_MODE` to the prompt; Phase 0.7.7 trivial-mode mini-review — verdict optional in local mode)
- Modify: `plugins/code-review/commands/pre-review.md` (mirrored via sync test)
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` (mirrored via sync test)

- [ ] **Step 1: Add `$REVIEW_MODE` to the synthesiser input list**

Edit `plugins/code-review/agents/review-synthesiser.md`. After the existing input bullets at lines 16-22, add:

```
- **Review mode** — `pr` (responding to a formal GitHub PR review) or `local`
  (pre-review of an in-progress branch). When `pr`, the synthesiser provides a
  GitHub-compatible verdict (`APPROVE`/`COMMENT`/`REQUEST_CHANGES`); when
  `local`, no verdict is produced — the human reader will decide whether and
  how to act on findings. See the Rules section.
```

- [ ] **Step 2: Update the synthesiser Context Gathering to detect mode**

Edit `plugins/code-review/agents/review-synthesiser.md` Context Gathering section. Find the existing parsing rules for `Empty tree mode:` / `Path scope:` and add a parallel rule:

```
If a `Review mode:` line is present in your prompt, store its value as
`$REVIEW_MODE` (one of `pr` | `local`). If absent, default to `pr` (the
historical behaviour — the synthesiser was originally only invoked from the
PR review path).
```

- [ ] **Step 3: Update the `## CI Status` Output Format section to be `pr`-only**

Edit `plugins/code-review/agents/review-synthesiser.md` line 139-147 (`## CI Status` Output block). Change the italic conditional comment from:

```
*(Render this section only when `$CI_STATUS_BODY` is present. Definitive failures constrain
the final verdict — no APPROVE. Transient failures (timeouts) flag a rerun-may-resolve
caveat but do not block on their own.)*
```

to:

```
*(Render this section only when `$CI_STATUS_BODY` is present AND `$REVIEW_MODE` is `pr`.
Definitive failures constrain the final verdict — no APPROVE. Transient failures (timeouts)
flag a rerun-may-resolve caveat but do not block on their own. In `local` mode CI status is
irrelevant to the synthesiser output: pre-review runs against the working tree, not against
a CI-tested commit.)*
```

- [ ] **Step 4: Update the verdict-related Rules**

Edit `plugins/code-review/agents/review-synthesiser.md` Rules section (around lines 253-258). Change:

```
- When `$CI_STATUS_BODY` indicates one or more definitive failures, the synthesiser MUST NOT
  recommend `APPROVE` in any summary or guidance to the consumer. Recommend `REQUEST_CHANGES`
  or `COMMENT` only.
- When `$CI_STATUS_BODY` indicates only transient failures (no definitive), recommend
  `COMMENT` and add a "rerun-may-resolve" note alongside the verdict guidance. Do not block
  the review from completing.
```

to:

```
- **Verdict guidance is `pr`-mode only.** When `$REVIEW_MODE` is `local` (pre-review),
  do NOT produce verdict guidance (`APPROVE`/`COMMENT`/`REQUEST_CHANGES`) anywhere in
  the report — including the Synthesiser Assessment, the Summary, and any per-finding
  notes. Pre-review output is consumed by a human author who decides whether to ignore
  findings, fix a subset, or produce a follow-up plan; there is no GitHub review to
  submit.
- When `$REVIEW_MODE` is `pr` and `$CI_STATUS_BODY` indicates one or more definitive
  failures, the synthesiser MUST NOT recommend `APPROVE` in any summary or guidance to
  the consumer. Recommend `REQUEST_CHANGES` or `COMMENT` only.
- When `$REVIEW_MODE` is `pr` and `$CI_STATUS_BODY` indicates only transient failures
  (no definitive), recommend `COMMENT` and add a "rerun-may-resolve" note alongside the
  verdict guidance. Do not block the review from completing.
```

- [ ] **Step 5: Add the mode prefix to the synthesiser dispatch prompt in the canonical**

Edit `plugins/code-review/includes/review-pipeline.md` Step 6.2 (line ~984 — the `Agent({...})` dispatch). The existing prompt template is:

```
prompt: "Base branch: $BASE\nHead SHA: $HEAD_SHA\nEmpty tree mode: $EMPTY_TREE_MODE\nPath scope: $PATH_SCOPE\n\n…"
```

Insert `Review mode: $REVIEW_MODE\n` immediately after `Path scope: $PATH_SCOPE\n` (before the blank line that precedes the `Trust boundary:` paragraph):

```
prompt: "Base branch: $BASE\nHead SHA: $HEAD_SHA\nEmpty tree mode: $EMPTY_TREE_MODE\nPath scope: $PATH_SCOPE\nReview mode: $REVIEW_MODE\n\n…"
```

- [ ] **Step 6: Make the trivial-mode mini-review verdict conditional on mode**

Edit `plugins/code-review/includes/review-pipeline.md` Phase 0.7.7 (lines 388-394). Change:

```
- **Verdict:** `APPROVE` if everything looks fine, `COMMENT` if minor observations are
  worth surfacing, `REQUEST_CHANGES` if anything is wrong.
```

to:

```
- **Verdict** (omit entirely when `$REVIEW_MODE` is `local` — no verdict is produced
  in pre-review): `APPROVE` if everything looks fine, `COMMENT` if minor observations
  are worth surfacing, `REQUEST_CHANGES` if anything is wrong.
```

Edit Phase 0.7.8 (line 406). Change:

```
> Trivial-mode mini-review complete. Verdict: <VERDICT>. <N> inline comments.
> Review the draft above. Submit? [y/N]
```

to:

```
> Trivial-mode mini-review complete. <verdict-or-mode-note>. <N> inline comments.
> Review the draft above. Submit? [y/N]
```

with a clarifying paragraph immediately below:

```
`<verdict-or-mode-note>` resolves to:
- `Verdict: <VERDICT>` when `$REVIEW_MODE` is `pr`
- `Mode: pre-review (no verdict)` when `$REVIEW_MODE` is `local`
```

Edit Phase 0.7.9 Mode `local` block (lines 428-431). Change:

```
**Mode `local`:**

Print the full mini-review to stdout (verdict header + body + each inline comment
prefixed with `file:line —`). Do NOT post anything to GitHub.
```

to:

```
**Mode `local`:**

Print the full mini-review to stdout (body + each inline comment prefixed with
`file:line —`; no verdict header — pre-review produces no verdict). Do NOT post
anything to GitHub.
```

- [ ] **Step 7: Propagate to consumers**

Apply Steps 5 and 6 edits to `plugins/code-review/commands/pre-review.md` and `plugins/code-review/skills/review-gh-pr/SKILL.md` at the corresponding locations. The byte-diff sync test catches any miss.

- [ ] **Step 8: Add a sync test that asserts the `Review mode:` line is present in synthesiser dispatch prompt**

Append to `tests/lib/test_sync_notes.sh`:

```bash
test_sync_synthesiser_dispatch_includes_review_mode() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch Review mode" "code-review plugin not found"
        return
    fi

    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "synthesiser dispatch Review mode: $basename_file" "file not found"
            continue
        fi

        # Find the synthesiser dispatch prompt (single line containing the prompt
        # template) and assert it includes "Review mode: $REVIEW_MODE".
        if grep -qE 'subagent_type: "code-review:review-synthesiser"' "$file"; then
            if grep -qE 'Review mode: \$REVIEW_MODE' "$file"; then
                pass "synthesiser dispatch Review mode: $basename_file includes \$REVIEW_MODE"
            else
                fail "synthesiser dispatch Review mode: $basename_file includes \$REVIEW_MODE" \
                    "the synthesiser dispatch prompt must include 'Review mode: \$REVIEW_MODE\\n' so the synthesiser can suppress verdict guidance in local mode"
            fi
        else
            # File doesn't dispatch the synthesiser — skip silently
            :
        fi
    done
}
```

- [ ] **Step 9: Run all tests**

Run: `tests/run.sh`
Expected:
- The new `synthesiser dispatch Review mode` test PASSES (3 PASS lines after Step 7 propagation).
- `test_sync_pipeline_inline_matches_canonical` PASSES (canonical + 2 consumers all updated).
- No other tests regress.

- [ ] **Step 10: Commit**

```bash
git add plugins/code-review/agents/review-synthesiser.md \
        plugins/code-review/includes/review-pipeline.md \
        plugins/code-review/commands/pre-review.md \
        plugins/code-review/skills/review-gh-pr/SKILL.md \
        tests/lib/test_sync_notes.sh
git commit -m "feat(code-review): suppress verdict guidance in pre-review (local) mode

pre-review is consumed by the human author, who decides whether to
ignore findings, fix a subset, or produce a follow-up plan. There is
no GitHub review to submit, so APPROVE/COMMENT/REQUEST_CHANGES are
meaningless and misleading. Plumb \$REVIEW_MODE through to the
synthesiser dispatch prompt and the trivial-mode mini-review; gate
verdict-related output on \$REVIEW_MODE = pr."
```

---

## Self-Review

**Spec coverage:**
- Finding #1 (Empty tree mode literal) → Task 1 ✓
- Finding #2 (deletion-path a/ prefix) → Task 2 ✓
- Finding #3 (cross-review-mode propagation list) → Task 3 ✓
- Finding #4 ($deletion_anchor clamp) → Task 4 ✓
- Finding #5 ($CHANGED_LINES rule duplication) → Task 5 ✓
- Finding #6 (Phase 0.7.9 cross-reference) → Task 6 ✓
- Finding #7 (8-10 specialists) → Task 7 ✓
- Finding #8 (8 cross-reviewers) → Task 8 ✓
- Finding #9 ($CROSS_REVIEW_COUNT self-re-review) → Task 9 ✓
- Finding #10 (jq --arg) → Task 10 ✓
- Finding #11 ($PATH_SCOPE glob) → Task 11 ✓
- Finding #12 ($INTENT_LEDGER error message) → Task 12 ✓
- Finding #13 (totalCount sync note) → Task 13 ✓
- Finding #14 (plugin.json keywords) → Task 14 ✓
- Finding #15 (three git diff calls) → Task 15 ✓
- Finding #16 (Phase 0.7.6 short-circuit) → Task 16 ✓
- Finding #17 (lightweight-path alignment carve-out) → Task 17 ✓
- Finding #18 ($CHANGED_LINES parser enumeration) → Task 18 ✓
- Observation 1 (static-analysis cross-feed enforcement) → Task 19 ✓
- Observation 2 (no verdict in pre-review mode) → Task 20 ✓

All 18 consensus findings + 2 user observations covered.

**Placeholder scan:** No "TBD", "implement later", or "fill in details". Every step has exact commands or exact text replacements. The line numbers cited as "approximately" are explicitly verified in a Step 1 of each affected task.

**Type consistency:** Variable names (`$AGENT_PROMPT`, `$EMPTY_TREE_MODE`, `$CHANGED_LINES`, `$CHANGED_FILES`, `$FULL_DIFF`, `$FILE_COUNT`, `$LINE_COUNT`, `$DELETION_ANCHOR`, `$CROSS_REVIEW_COUNT`, `$PATH_SCOPE`, `$INTENT_LEDGER`, `$CURRENT_USER`, `$REVIEW_MODE`) match across tasks. Token-form names (`(empty — rename only)`, `(deleted)`) match between Tasks 2 and 18.

**Cross-task ordering:**
- Task 18 explicitly depends on Task 2 (the `(deleted)` sentinel must be in the parser grammar before the example block can reference it).
- Task 20 is independent of Task 19 — both can run in any order relative to each other and to the rest. Task 20 introduces a new variable (`$REVIEW_MODE`) and a new sync-test function; neither conflicts with the existing 18 tasks.
- All other tasks are independent and can run in any order.
