# Whitespace-aware deletion detection and orchestrator COMMENT elision — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the "10+ contiguous deleted lines" significant-deletion check to measure on `git diff -w` (so whitespace-only re-indents stop forcing the full-pipeline route), and remove every code path where the orchestrator (or trivial-mode mini-review) auto-emits a `COMMENT` verdict. After this plan: `final = synth` for every review path; `COMMENT` only ever reaches GitHub via the existing `[c]` user override under the `REQUEST_CHANGES` confirmation prompt.

**Architecture:** Canonical-and-inlined plugin docs. Edits land in three canonicals (`includes/review-pipeline.md`, `includes/verdict-rubric.md`) and propagate **byte-identically** into their consumers (`commands/pre-review.md`, `skills/review-gh-pr/SKILL.md`, `agents/review-synthesiser.md`). The structural test suite (`tests/lib/test_sync_notes.sh`) enforces byte-equality and forbids legacy strings. A new fixture-based shell test (`tests/lib/test_deletion_detection.sh`) exercises the deletion-detection logic against synthetic re-indent vs real-deletion diffs.

**Tech Stack:** Plugin Markdown (orchestrator prose), Bash + awk + git for fixture-based tests, the existing pass/fail/skip harness in `tests/lib/harness.sh`.

**Branch:** `feat/deletion-detection-and-comment-elision`, branched from `main`. Do NOT merge — stop after preparing/opening a PR.

**Repo conventions to honour throughout:**
- No compound shell (`&&`, `||`, `;`), no command substitution, no subshells, no piping/redirection in Bash tool calls outside the explicit HEREDOC carve-out for `git commit -m "$(cat <<'EOF' … EOF)"`. Run each command as a separate `Bash` tool call.
- `plugin.json` files have no `version` field — do NOT add one.
- Use `$CLAUDE_TEMP_DIR` for any temp files (the SessionStart hook already created it).
- Markdown indentation: 2 spaces; shell scripts: 4 spaces; LF line endings; final newline on every text file.
- Do NOT commit unless the user explicitly asks. Land work as commits on the feature branch only when given the green light.

---

## File Structure

**Edits (canonicals + inlined consumers):**

- `plugins/code-review-suite/includes/review-pipeline.md` — canonical for Phase 0.7.6 (significant-deletion fast-path check), Step 2.7 (`$SIGNIFICANT_DELETIONS` flag), Phase 0.7.7 (trivial-mode mini-review verdict bullet).
- `plugins/code-review-suite/commands/pre-review.md` — re-sync inlined pipeline copy.
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — re-sync inlined pipeline copy AND inlined verdict-rubric block in Step 6; AND substantive Class A/B edits in Step 6 (this is the only consumer that contains the orchestrator-side Class A/B/C/D logic — it lives nowhere else).
- `plugins/code-review-suite/includes/verdict-rubric.md` — canonical for the rubric paragraph and Posting policy table.
- `plugins/code-review-suite/agents/review-synthesiser.md` — re-sync inlined verdict-rubric block.

**Tests (new and amended):**

- `tests/lib/test_sync_notes.sh` — amend the existing failure-message string for the `Verdict:` restriction test, and add a new function with three negative-presence assertions.
- `tests/lib/test_deletion_detection.sh` — NEW. Exercises the "10+ contiguous deleted lines on `git diff -w`" rule against two pre-canned fixture diffs (re-indent vs real deletion).
- `tests/fixtures/deletion-detection/reindent.diff` — NEW. Fixture #1: 12-line whitespace-only re-indent block.
- `tests/fixtures/deletion-detection/real-deletion.diff` — NEW. Fixture #2: 12-line genuine block deletion.

**Reference files (read-only, used to copy canonical body):**

- `tests/lib/harness.sh` — pass/fail/skip helpers, `assert_equals`, `REPO_ROOT`.
- `tests/run.sh` — entry point, sources every `tests/lib/test_*.sh`.

---

## Order of operations

The work has tight cross-file coupling (sync tests are byte-strict). Execute in this order so test failures stay focused:

1. Set up the branch.
2. **Change 1A** — Phase 0.7.6 + Step 2.7 wording in the canonical `includes/review-pipeline.md`.
3. **Change 1B** — propagate the same edits into both inlined consumers (`commands/pre-review.md` + `skills/review-gh-pr/SKILL.md`).
4. **Change 1C** — add deletion-detection fixtures + new test file.
5. Run the test suite (`bash tests/run.sh`). Sync tests must stay green; the new test must pass.
6. **Change 2A** — verdict-rubric canonical wording (`includes/verdict-rubric.md`) + Phase 0.7.7 trivial-mode bullet in `includes/review-pipeline.md`.
7. **Change 2B** — propagate verdict-rubric block into `agents/review-synthesiser.md` + `SKILL.md` Step 6; propagate Phase 0.7.7 bullet into both pipeline consumers.
8. **Change 2C** — surgically edit `SKILL.md` Step 6 Class A/B (delete B.3, simplify A.2, delete A.3 downgrade template + provenance variants, drop `$DOWNGRADE_REASON`, drop the Step 6 preamble's "single deterministic transformation" claim).
9. **Change 2D** — `tests/lib/test_sync_notes.sh` failure-message tweak + new negative-presence assertion function.
10. Run the test suite. All sync tests + new assertions green.
11. Push branch and open the PR. Stop. Do NOT merge.

The plan below carves each numbered phase into bite-sized steps.

---

## Task 0: Branch setup

**Files:**
- No file changes; git state only.

- [ ] **Step 0.1: Verify clean working tree (other than the spec doc)**

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins status --short`

Expected: only the new untracked spec file `docs/superpowers/specs/2026-05-19-deletion-detection-and-comment-elision-design.md` and (after writing this plan) `docs/superpowers/plans/2026-05-19-deletion-detection-and-comment-elision.md` show. No tracked-file modifications. If anything else is dirty, stop and surface it to the user.

- [ ] **Step 0.2: Verify base is `main`, fast-forward expected**

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins fetch origin main`
Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins log --oneline origin/main..main`

Expected: empty (local `main` has no extra commits) OR the few diverging commits the user knows about. Don't reset.

- [ ] **Step 0.3: Create the feature branch off `main`**

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins switch -c feat/deletion-detection-and-comment-elision main`

Expected output: `Switched to a new branch 'feat/deletion-detection-and-comment-elision'`.

- [ ] **Step 0.4: Confirm branch is correct**

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins branch --show-current`

Expected: `feat/deletion-detection-and-comment-elision`.

---

## Task 1: Change 1A — canonical `review-pipeline.md` deletion-detection edits

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md`
  - Phase 0.7.6 body (currently lines ~451-460)
  - Step 2.7 (currently line ~688)

- [ ] **Step 1.1: Read the current Phase 0.7.6 wording (sanity check before edit)**

Run: `Read` on `plugins/code-review-suite/includes/review-pipeline.md`, look at lines ~450-466.

Confirm the current body matches the spec's "Current state" excerpt.

- [ ] **Step 1.2: Edit Phase 0.7.6 body**

In `plugins/code-review-suite/includes/review-pipeline.md`, replace the current Phase 0.7.6 body (everything between `### 0.7.6 Check for significant deletions` and the next `### Trivial bar failed` heading, exclusive of those headings).

`old_string` (the exact paragraph + its blank lines in canonical, between the heading and the `### Trivial bar failed` heading):

```
If 0.7.5 has already failed (file-count or line-count bar exceeded), skip this
sub-step entirely and proceed straight to "Trivial bar failed" — running a full
`git diff` to scan for deletions is moot when the size bar already disqualified
the diff. Otherwise, run `git diff [diff-syntax]` and scan hunks for any single
hunk with 10+ contiguous deleted lines. This duplicates Step 2.7's
`$SIGNIFICANT_DELETIONS` logic; the duplication is intentional to keep Phase 0.7
self-contained as a fast-path pre-check.

If any such hunk exists, the trivial bar fails — fall through to Step 1.
```

`new_string`:

```
If 0.7.5 has already failed (file-count or line-count bar exceeded), skip this
sub-step entirely and proceed straight to "Trivial bar failed" — running a full
`git diff` to scan for deletions is moot when the size bar already disqualified
the diff. Otherwise, run `git diff -w [diff-syntax]` and scan hunks for any
single hunk with 10+ contiguous deleted lines. The `-w` flag (alias for
`--ignore-all-space`) collapses whitespace-only differences before the deletion
count is taken: a re-indent that emits each line as `-` then `+` with different
leading whitespace is not a deletion at all under `-w` and contributes zero to
the contiguous-`-` run. This duplicates Step 2.7's `$SIGNIFICANT_DELETIONS`
logic; the duplication is intentional to keep Phase 0.7 self-contained as a
fast-path pre-check.

If any such hunk exists, the trivial bar fails — fall through to Step 1.
```

Use the `Edit` tool with `replace_all=false` (the paragraph is unique in the canonical).

- [ ] **Step 1.3: Edit Step 2.7**

In the same file, replace the current Step 2.7 line.

`old_string`:

```
2.7. Scan `$FULL_DIFF` hunks for **significant deletions:** if any single hunk contains 10+ contiguous deleted lines, set `$SIGNIFICANT_DELETIONS = true`
```

`new_string`:

```
2.7. Scan for **significant deletions:** run `git diff -w` (using the diff syntax determined by `$EMPTY_TREE_MODE`, append `-- "$PATH_SCOPE"` if set) and scan its hunks for any single hunk with 10+ contiguous deleted lines. If any such hunk exists, set `$SIGNIFICANT_DELETIONS = true`. The `-w` view drops whitespace-only differences before the deletion count is taken, so re-indents and other whitespace-only edits do not register as significant deletions. **Do NOT replace `$FULL_DIFF` with the `-w` view** — `$FULL_DIFF` (already captured in 2.2 without `-w`) remains the authoritative artifact for `$CHANGED_LINES`, `$LINE_COUNT`, specialists, and archaeology anchors. Only the deletion-detection scan uses `-w`.
```

Use `Edit` with `replace_all=false`.

- [ ] **Step 1.4: Confirm canonical edits applied**

Run: `grep -n 'git diff -w' plugins/code-review-suite/includes/review-pipeline.md`

Expected: at least two hits — one in the Phase 0.7.6 paragraph and one in Step 2.7.

Run: `grep -n 'Scan \`\$FULL_DIFF\` hunks for \*\*significant deletions:\*\*' plugins/code-review-suite/includes/review-pipeline.md`

Expected: zero hits (the old wording is gone).

---

## Task 2: Change 1B — propagate to both inlined consumers

The pipeline content in `commands/pre-review.md` and `skills/review-gh-pr/SKILL.md` must remain **byte-identical** to the canonical from "Follow these instructions exactly" through "Present the synthesiser's formatted report to the user." (the range checked by `test_sync_pipeline_inline_matches_canonical`). Apply the same two edits in each consumer.

**Files:**
- Modify: `plugins/code-review-suite/commands/pre-review.md`
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`

- [ ] **Step 2.1: Apply Phase 0.7.6 edit to `commands/pre-review.md`**

Use the same `old_string` / `new_string` pair as Task 1 Step 1.2, but on `plugins/code-review-suite/commands/pre-review.md`.

- [ ] **Step 2.2: Apply Step 2.7 edit to `commands/pre-review.md`**

Use the same `old_string` / `new_string` pair as Task 1 Step 1.3, but on `plugins/code-review-suite/commands/pre-review.md`.

- [ ] **Step 2.3: Apply Phase 0.7.6 edit to `skills/review-gh-pr/SKILL.md`**

Use the same `old_string` / `new_string` pair as Task 1 Step 1.2, but on `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 2.4: Apply Step 2.7 edit to `skills/review-gh-pr/SKILL.md`**

Use the same `old_string` / `new_string` pair as Task 1 Step 1.3, but on `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 2.5: Run the pipeline-inline sync test in isolation**

Run: `bash -c 'cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins && source tests/lib/harness.sh && source tests/lib/test_sync_notes.sh && test_sync_pipeline_inline_matches_canonical && summary'`

Expected: 2 passes (one per consumer), no failures.

If a diff is reported, the consumer copy drifted — fix the affected `Edit` and re-run.

---

## Task 3: Change 1C — fixtures + new deletion-detection test

**Files:**
- Create: `tests/fixtures/deletion-detection/reindent.diff`
- Create: `tests/fixtures/deletion-detection/real-deletion.diff`
- Create: `tests/lib/test_deletion_detection.sh`

The test exercises the rule textually: "any single hunk in `git diff -w` output with 10+ contiguous `-` lines (where `-` is NOT `---`)." We do not invoke a separate plugin runtime; the test embeds the same awk one-liner that the prose specifies, and asserts behaviour against pre-canned diff fixtures so future drift in the prose is caught downstream.

- [ ] **Step 3.1: Create the re-indent fixture**

Create `tests/fixtures/deletion-detection/reindent.diff` with this exact content (a synthetic minimal diff representing a 12-line re-indent — each old line is removed and re-emitted with adjusted leading whitespace):

```
diff --git a/sample.cs b/sample.cs
index 1111111..2222222 100644
--- a/sample.cs
+++ b/sample.cs
@@ -1,15 +1,15 @@
 using System;
 namespace Demo;
-public class DistillerConfig
-{
-    public int Threshold { get; set; }
-    public string Mode { get; set; } = "default";
-    public bool Enabled { get; set; } = true;
-    public TimeSpan Window { get; set; }
-    public int RetryCount { get; set; }
-    public string Tag { get; set; } = "";
-    public DateTime CreatedAt { get; set; }
-    public Guid CorrelationId { get; set; }
-    public IReadOnlyList<string> Notes { get; set; } = Array.Empty<string>();
-    public override string ToString() => $"{Threshold}/{Mode}";
-}
+    public class DistillerConfig
+    {
+        public int Threshold { get; set; }
+        public string Mode { get; set; } = "default";
+        public bool Enabled { get; set; } = true;
+        public TimeSpan Window { get; set; }
+        public int RetryCount { get; set; }
+        public string Tag { get; set; } = "";
+        public DateTime CreatedAt { get; set; }
+        public Guid CorrelationId { get; set; }
+        public IReadOnlyList<string> Notes { get; set; } = Array.Empty<string>();
+        public override string ToString() => $"{Threshold}/{Mode}";
+    }
 // end of file
```

End with a trailing newline.

- [ ] **Step 3.2: Create the real-deletion fixture**

Create `tests/fixtures/deletion-detection/real-deletion.diff` with this exact content (a synthetic diff that genuinely deletes a 12-line block with no replacement on the `+` side):

```
diff --git a/sample.cs b/sample.cs
index 1111111..2222222 100644
--- a/sample.cs
+++ b/sample.cs
@@ -1,15 +1,3 @@
 using System;
 namespace Demo;
-public class DistillerConfig
-{
-    public int Threshold { get; set; }
-    public string Mode { get; set; } = "default";
-    public bool Enabled { get; set; } = true;
-    public TimeSpan Window { get; set; }
-    public int RetryCount { get; set; }
-    public string Tag { get; set; } = "";
-    public DateTime CreatedAt { get; set; }
-    public Guid CorrelationId { get; set; }
-    public IReadOnlyList<string> Notes { get; set; } = Array.Empty<string>();
-    public override string ToString() => $"{Threshold}/{Mode}";
-}
 // end of file
```

End with a trailing newline.

- [ ] **Step 3.3: Write the new test file (failing first)**

Create `tests/lib/test_deletion_detection.sh` with this content:

```bash
#!/usr/bin/env bash
# Whitespace-aware significant-deletion detection — fixture-based tests.
#
# The pipeline's Phase 0.7.6 and Step 2.7 use the rule:
#   "Any single hunk in `git diff -w` output with 10+ contiguous deleted lines."
#
# These tests bake the same rule into a small awk helper and exercise it against
# pre-canned fixtures so the policy is verifiable in isolation. The fixtures live
# under tests/fixtures/deletion-detection/.

# _max_contiguous_deletions <diff-file>
# Echoes the largest contiguous run of `-` lines (excluding `---` file headers)
# in the supplied diff. Mirrors the algorithm that the orchestrator's prose
# specifies for the Phase 0.7.6 / Step 2.7 deletion scan.
_max_contiguous_deletions() {
    local diff_file="$1"
    awk '
        BEGIN { run = 0; max = 0 }
        /^---/ { run = 0; next }
        /^-/ { run++; if (run > max) max = run; next }
        { run = 0 }
        END { print max }
    ' "$diff_file"
}

# _max_contiguous_deletions_w <diff-file>
# Same as _max_contiguous_deletions but applied to the `-w`-stripped view of the
# diff. The fixtures are pre-canned static diffs (not derived from a working
# tree), so we simulate `git diff -w` by stripping every `-`/`+` pair whose
# whitespace-collapsed bodies are equal. For the canned fixtures this is
# equivalent to running `git diff -w` on the same source.
_max_contiguous_deletions_w() {
    local diff_file="$1"
    awk '
        # Pass 1: emit a sanitised diff where lines that pair as whitespace-only
        # changes are dropped. Specifically:
        #   - Buffer every `-` line.
        #   - On the next `+` line, compare whitespace-stripped bodies.
        #     If equal, discard both. Otherwise emit them in original order.
        #   - Anything else flushes the buffer.
        function flush() {
            for (i = 1; i <= n_buf; i++) print buf[i]
            n_buf = 0
        }
        function strip_ws(s) {
            gsub(/[[:space:]]/, "", s)
            return s
        }
        BEGIN { n_buf = 0 }
        /^---/ || /^\+\+\+/ { flush(); print; next }
        /^@@/ { flush(); print; next }
        /^-/ { n_buf++; buf[n_buf] = $0; next }
        /^\+/ {
            line = $0
            consumed = 0
            if (n_buf > 0) {
                neg_body = substr(buf[1], 2)
                pos_body = substr(line, 2)
                if (strip_ws(neg_body) == strip_ws(pos_body)) {
                    # Drop the paired `-` line and skip emitting this `+` line.
                    for (i = 1; i < n_buf; i++) buf[i] = buf[i + 1]
                    n_buf--
                    consumed = 1
                }
            }
            if (!consumed) {
                flush()
                print line
            }
            next
        }
        { flush(); print }
        END { flush() }
    ' "$diff_file" | awk '
        BEGIN { run = 0; max = 0 }
        /^---/ { run = 0; next }
        /^-/ { run++; if (run > max) max = run; next }
        { run = 0 }
        END { print max }
    '
}

test_deletion_detection_real_block_triggers() {
    local fixtures="$REPO_ROOT/tests/fixtures/deletion-detection"
    local diff_file="$fixtures/real-deletion.diff"

    if [[ ! -f "$diff_file" ]]; then
        fail "deletion-detection: real-deletion fixture present" "missing: $diff_file"
        return
    fi

    local raw run_w
    raw=$(_max_contiguous_deletions "$diff_file")
    run_w=$(_max_contiguous_deletions_w "$diff_file")

    # Both measurements should report a 12-line run for a genuine block deletion.
    assert_equals "12" "$raw" \
        "real-deletion fixture: raw scan reports 12 contiguous `-` lines"
    assert_equals "12" "$run_w" \
        "real-deletion fixture: -w scan reports 12 contiguous `-` lines"

    if (( run_w >= 10 )); then
        pass "real-deletion fixture: -w scan trips the 10+ threshold (\$SIGNIFICANT_DELETIONS = true)"
    else
        fail "real-deletion fixture: -w scan trips the 10+ threshold (\$SIGNIFICANT_DELETIONS = true)" \
            "expected run_w >= 10, got $run_w"
    fi
}

test_deletion_detection_reindent_does_not_trigger() {
    local fixtures="$REPO_ROOT/tests/fixtures/deletion-detection"
    local diff_file="$fixtures/reindent.diff"

    if [[ ! -f "$diff_file" ]]; then
        fail "deletion-detection: reindent fixture present" "missing: $diff_file"
        return
    fi

    local raw run_w
    raw=$(_max_contiguous_deletions "$diff_file")
    run_w=$(_max_contiguous_deletions_w "$diff_file")

    # Raw scan would falsely flag 12 contiguous `-` lines; the -w view collapses
    # the whitespace-only re-indent and reports zero deletions.
    assert_equals "12" "$raw" \
        "reindent fixture: raw scan reports 12 contiguous `-` lines (the bug)"
    assert_equals "0" "$run_w" \
        "reindent fixture: -w scan collapses whitespace-only deletions (the fix)"

    if (( run_w < 10 )); then
        pass "reindent fixture: -w scan does NOT trip the 10+ threshold (\$SIGNIFICANT_DELETIONS stays false)"
    else
        fail "reindent fixture: -w scan does NOT trip the 10+ threshold (\$SIGNIFICANT_DELETIONS stays false)" \
            "expected run_w < 10, got $run_w"
    fi
}
```

Make the file executable: `chmod +x tests/lib/test_deletion_detection.sh`.

(The harness `source`s every `test_*.sh` so an executable bit is not strictly required, but the rest of `tests/lib/` is `+x` for consistency.)

- [ ] **Step 3.4: Run only the new test (verify it passes against the post-edit pipeline)**

Run: `bash -c 'cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins && source tests/lib/harness.sh && source tests/lib/test_deletion_detection.sh && test_deletion_detection_real_block_triggers && test_deletion_detection_reindent_does_not_trigger && summary'`

Expected: 6 passes (3 per test), 0 failures.

If the reindent test fails, the awk `_max_contiguous_deletions_w` helper has a bug — most likely the whitespace-pairing loop. Re-read the awk and trace by hand against `reindent.diff`.

- [ ] **Step 3.5: Run the full test suite to confirm no regression**

Run: `bash /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins/tests/run.sh`

Expected: every existing test still passes; the two new test functions appear in the output (each producing 3 passes).

If `test_sync_pipeline_inline_matches_canonical` fails, the consumer copies drifted in Task 2 — diff and re-sync.

---

## Task 4: Change 2A — verdict-rubric canonical wording + Phase 0.7.7 trivial bullet

**Files:**
- Modify: `plugins/code-review-suite/includes/verdict-rubric.md`
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Phase 0.7.7 verdict bullet only)

- [ ] **Step 4.1: Edit verdict-rubric Posting policy table**

In `plugins/code-review-suite/includes/verdict-rubric.md`, drop the parenthetical `(and APPROVE → COMMENT downgrade)` from the APPROVE row.

`old_string`:

```
| `APPROVE` (and APPROVE → COMMENT downgrade) | Post consensus findings with **confidence ≥ 75**. Sub-threshold findings remain visible in the synthesiser's stdout report but are not posted to GitHub. |
```

`new_string`:

```
| `APPROVE` | Post consensus findings with **confidence ≥ 75**. Sub-threshold findings remain visible in the synthesiser's stdout report but are not posted to GitHub. |
```

- [ ] **Step 4.2: Edit verdict-rubric paragraph**

In the same file, replace the paragraph that follows the rubric table.

`old_string`:

```
The synthesiser produces only `APPROVE` or `REQUEST_CHANGES`. `COMMENT` is
never a synthesiser output — it can only emerge from the orchestrator's
APPROVE → COMMENT downgrade (see Posting policy below) or from a user override
at the confirmation prompt.
```

`new_string`:

```
The synthesiser produces only `APPROVE` or `REQUEST_CHANGES`. `COMMENT` is
never a synthesiser output, and the orchestrator never auto-downgrades a synth
verdict to `COMMENT`. The only route to a `COMMENT` verdict is an explicit user
override at the Class A confirmation prompt.
```

- [ ] **Step 4.3: Edit Phase 0.7.7 trivial-mode verdict bullet (canonical pipeline)**

In `plugins/code-review-suite/includes/review-pipeline.md`, replace the verdict bullet at the start of the mini-review draft.

`old_string`:

```
- **Verdict** (omit entirely when `$REVIEW_MODE` is `local` — no verdict is produced
  in pre-review): `APPROVE` if everything looks fine, `COMMENT` if minor observations
  are worth surfacing, `REQUEST_CHANGES` if anything is wrong.
```

`new_string`:

```
- **Verdict** (omit entirely when `$REVIEW_MODE` is `local` — no verdict is produced
  in pre-review): `APPROVE` if everything looks fine, `REQUEST_CHANGES` if anything
  is wrong. (`COMMENT` is not a permitted trivial-mode verdict; minor observations
  ride alongside `APPROVE` as inline comments.)
```

- [ ] **Step 4.4: Sanity-check Step 4 edits**

Run: `grep -nF 'APPROVE → COMMENT downgrade' plugins/code-review-suite/includes/verdict-rubric.md`
Expected: zero hits.

Run: `grep -nF 'COMMENT if minor observations' plugins/code-review-suite/includes/review-pipeline.md`
Expected: zero hits.

Run: `grep -nF 'never auto-downgrades a synth' plugins/code-review-suite/includes/verdict-rubric.md`
Expected: 1 hit.

---

## Task 5: Change 2B — propagate verdict-rubric block + Phase 0.7.7 bullet to inlined consumers

**Files:**
- Modify: `plugins/code-review-suite/agents/review-synthesiser.md` — inlined verdict-rubric block.
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — inlined verdict-rubric block in Step 6 + inlined Phase 0.7.7 bullet in the pipeline section.
- Modify: `plugins/code-review-suite/commands/pre-review.md` — inlined Phase 0.7.7 bullet only.

The verdict-rubric block must remain **byte-identical** to the canonical from `### Verdict rubric (PR mode only, first match wins)` through `operations — no prose parsing.` (the range checked by `test_sync_verdict_rubric_inline_matches_canonical`).

- [ ] **Step 5.1: Apply verdict-rubric Posting policy edit to `agents/review-synthesiser.md`**

Use the same `old_string` / `new_string` pair as Task 4 Step 4.1, but on `plugins/code-review-suite/agents/review-synthesiser.md`.

- [ ] **Step 5.2: Apply verdict-rubric paragraph edit to `agents/review-synthesiser.md`**

Use the same `old_string` / `new_string` pair as Task 4 Step 4.2, but on `plugins/code-review-suite/agents/review-synthesiser.md`.

- [ ] **Step 5.3: Apply verdict-rubric Posting policy edit to `skills/review-gh-pr/SKILL.md`**

Use the same `old_string` / `new_string` pair as Task 4 Step 4.1, but on `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 5.4: Apply verdict-rubric paragraph edit to `skills/review-gh-pr/SKILL.md`**

Use the same `old_string` / `new_string` pair as Task 4 Step 4.2, but on `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 5.5: Apply Phase 0.7.7 verdict-bullet edit to `commands/pre-review.md`**

Use the same `old_string` / `new_string` pair as Task 4 Step 4.3, but on `plugins/code-review-suite/commands/pre-review.md`.

- [ ] **Step 5.6: Apply Phase 0.7.7 verdict-bullet edit to `skills/review-gh-pr/SKILL.md`**

Use the same `old_string` / `new_string` pair as Task 4 Step 4.3, but on `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`.

- [ ] **Step 5.7: Run only the verdict-rubric and pipeline sync tests**

Run: `bash -c 'cd /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins && source tests/lib/harness.sh && source tests/lib/test_sync_notes.sh && test_sync_verdict_rubric_inline_matches_canonical && test_sync_pipeline_inline_matches_canonical && summary'`

Expected: 4 passes total (2 per sync test), 0 failures.

If a diff is reported, re-sync the affected consumer.

---

## Task 6: Change 2C — `SKILL.md` Step 6 Class A/B surgical edits

This is the largest mechanical edit cluster. Apply each `Edit` independently to limit blast radius.

**File:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (Step 6, currently lines ~1522-1838)

The verdict-rubric block within Step 6 was already updated in Task 5; this task only edits the Step-6-specific orchestrator logic that lives below the rubric.

- [ ] **Step 6.1: Drop the Step 6 preamble's "single deterministic transformation" claim**

The Step 6 intro paragraph currently asserts that the orchestrator may apply one APPROVE → COMMENT downgrade. With Class B.3 deleted, the orchestrator applies no transformation — keep the synthesiser-as-sole-authority sentence and the user-sovereign sentence, but excise the transformation claim.

`old_string`:

```
The synthesiser is the sole authority for the PR review verdict. The orchestrator
(this step) executes that verdict — it cannot alter findings, severity, confidence,
fix text, file/line attribution, or the synthesiser-produced verdict on its own
initiative. The single deterministic transformation the orchestrator may apply is
the APPROVE → COMMENT downgrade described in the Class B state checks below.

The user is sovereign over the final action submitted. At the confirmation prompt
the user can override the proposed action to any of `APPROVE`, `REQUEST_CHANGES`,
or `COMMENT`. This is the documented caveat to synthesiser-as-sole-authority.
```

`new_string`:

```
The synthesiser is the sole authority for the PR review verdict. The orchestrator
(this step) executes that verdict — it cannot alter findings, severity, confidence,
fix text, file/line attribution, or the synthesiser-produced verdict on its own
initiative. `$FINAL_VERDICT` equals the synthesiser's verdict for every review
path; the orchestrator never auto-emits `COMMENT`.

The user is sovereign over the final action submitted. At the confirmation prompt
the user can override the proposed action; the user's `[c]` keypress under the
`REQUEST_CHANGES` prompt is the only path to a `COMMENT` submission. This is the
documented caveat to synthesiser-as-sole-authority.
```

- [ ] **Step 6.2: Rewrite Class A header paragraph (drop `$DOWNGRADE_REASON`)**

`old_string`:

```
### Class A — User confirmation flow

Class A reads two variables from earlier work: `$SYNTH_VERDICT` /
`$SYNTH_RUBRIC_ROW` are parsed below from the synthesiser's report;
`$DOWNGRADE_REASON` is populated by Class B §B.3 when an APPROVE → COMMENT
downgrade applies, and is unset (empty) otherwise. The downgraded prompt
template (the second variant in §A.3) is rendered ONLY when `$PROPOSED_ACTION
= COMMENT` and `$DOWNGRADE_REASON` is non-empty — otherwise the standard
APPROVE template is used.
```

`new_string`:

```
### Class A — User confirmation flow

Class A reads two variables from earlier work: `$SYNTH_VERDICT` and
`$SYNTH_RUBRIC_ROW` are parsed below from the synthesiser's report. There is
no orchestrator-driven downgrade — Class A renders one of two confirmation
prompts based purely on `$SYNTH_VERDICT`.
```

- [ ] **Step 6.3: Simplify Class A.2 (no Class B influence)**

`old_string`:

```
#### A.2 Compute proposed action

By default `$PROPOSED_ACTION = $SYNTH_VERDICT`. If the Class B state checks
(next section) downgrade APPROVE to COMMENT, `$PROPOSED_ACTION = COMMENT`
and `$DOWNGRADE_REASON` is populated.
```

`new_string`:

```
#### A.2 Compute proposed action

`$PROPOSED_ACTION = $SYNTH_VERDICT.`
```

- [ ] **Step 6.4: Replace Class A.3 — three templates → two templates**

The full Class A.3 section currently spans the rendering instruction "Render ONE of three confirmation prompts based on the proposed action:", three template fences, the "**Behaviour:**" subsection, the "**Audit trail (announce-line on submission):**" subsection, and the four `<provenance>` enumeration bullets. Replace all of it.

`old_string`:

````
#### A.3 Render confirmation prompt

Render ONE of three confirmation prompts based on the proposed action:

**Prompt template (synthesiser proposed APPROVE, no downgrade):**

```
> Synthesiser proposes: APPROVE
>   Rubric row $SYNTH_RUBRIC_ROW: <reason from synthesiser ## Verdict Reason: line>
>   <tier counts> across <N> files
>
> Submit as proposed [s], override to REQUEST_CHANGES [r],
> or cancel without submitting [n]? [s/r/n]
```

**Prompt template (synthesiser proposed APPROVE, downgraded to COMMENT by Class B):**

```
> Synthesiser proposes: APPROVE
>   Rubric row $SYNTH_RUBRIC_ROW: <reason from synthesiser ## Verdict Reason: line>
> Orchestrator adjustment: APPROVE → COMMENT
>   Reason: $DOWNGRADE_REASON
>
> Submit as COMMENT [s], override to APPROVE [a], override to REQUEST_CHANGES [r],
> or cancel without submitting [n]? [s/a/r/n]
```

**Prompt template (synthesiser proposed REQUEST_CHANGES):**

```
> Synthesiser proposes: REQUEST_CHANGES
>   Rubric row $SYNTH_RUBRIC_ROW: <reason from synthesiser ## Verdict Reason: line>
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
````

`new_string`:

````
#### A.3 Render confirmation prompt

Render ONE of two confirmation prompts based on the proposed action:

**Prompt template (synthesiser proposed APPROVE):**

```
> Synthesiser proposes: APPROVE
>   Rubric row $SYNTH_RUBRIC_ROW: <reason from synthesiser ## Verdict Reason: line>
>   <tier counts> across <N> files
>
> Submit as proposed [s], override to REQUEST_CHANGES [r],
> or cancel without submitting [n]? [s/r/n]
```

**Prompt template (synthesiser proposed REQUEST_CHANGES):**

```
> Synthesiser proposes: REQUEST_CHANGES
>   Rubric row $SYNTH_RUBRIC_ROW: <reason from synthesiser ## Verdict Reason: line>
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
- `user override of synthesiser-proposed <ORIGINAL>` — user changed the verdict
````

- [ ] **Step 6.5: Replace the Class B opener paragraph (three checks → two checks) and delete §B.3 entirely**

The Class B section opens with a paragraph saying "Run three checks…". Class B.1 and B.2 are unchanged; §B.3 ("Outstanding peer REQUEST_CHANGES") is removed in full. Combine the opener rewrite and §B.3 deletion into one `Edit` to keep the rewrite atomic.

`old_string`:

````
### Class B — PR-thread state handling

Run three checks at the start of Step 6, BEFORE presenting the Class A
confirmation prompt. All three use `gh api` / `gh pr view` against live PR state.
Batch them into one GraphQL call where possible to amortise latency.
````

`new_string`:

````
### Class B — PR-thread state handling

Run two checks at the start of Step 6, BEFORE presenting the Class A
confirmation prompt. Both use `gh api` / `gh pr view` against live PR state.
Batch them into one GraphQL call where possible to amortise latency.
````

Then in a separate `Edit`, delete the entire §B.3 block.

`old_string`:

````
#### B.3 Outstanding peer REQUEST_CHANGES

```bash
gh pr view "$ARGUMENTS" --json reviews \
  | jq --arg head "$HEAD_SHA" \
       --arg user "$CURRENT_USER" \
       '.reviews | map(select(.state == "CHANGES_REQUESTED" and .commit.oid == $head and .author.login != $user)) | length'
```

`$HEAD_SHA` was captured and validated in Step 2.1 of the pipeline (regex
`^[0-9a-f]{40}$`); reusing it here is preferred over re-fetching `headRefOid`
from the live PR. The reused value is zero network cost, eliminates a TOCTOU
window (force-push between two `gh pr view` calls would mismatch `reviews`
against `headRefOid`), and aligns the check semantics with B.2 — both
B-checks gate on "the commit the synthesiser analysed", not "whatever the
head currently is".

If the result is `> 0`, there is at least one non-dismissed peer
`REQUEST_CHANGES` from another reviewer on the latest commit. If the
synthesiser proposed `APPROVE`, transform the proposed action to `COMMENT` and
populate `$DOWNGRADE_REASON` with:

```
prior reviewer @<login> has outstanding REQUEST_CHANGES (review #<id>) — APPROVE would override; posting as COMMENT instead
```

Capture `<login>` and `<id>` from the same query (extend the jq pipeline to
return the first matching review's `author.login` and `databaseId`).

If the synthesiser proposed `REQUEST_CHANGES`, no transform applies (the
peer's REQUEST_CHANGES is already aligned with the synthesiser's proposal).

This is the SOLE deterministic transformation the orchestrator is allowed to
apply to the synthesiser's proposed verdict. It is rule-driven, not
judgement-driven.

### Class C — Submission mechanics
````

`new_string`:

````
### Class C — Submission mechanics
````

- [ ] **Step 6.6: Sanity-check Step 6 surgical edits**

Run: `grep -cF 'Outstanding peer REQUEST_CHANGES' plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: `0`.

Run: `grep -cF '$DOWNGRADE_REASON' plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: `0`.

Run: `grep -cF 'Run two checks at the start of Step 6' plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: `1`.

Run: `grep -cF 'Render ONE of two confirmation prompts' plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: `1`.

Run: `grep -cF 'orchestrator-adjusted to <FINAL>' plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
Expected: `0`.

If any expected count is wrong, re-read the affected `Edit` and adjust before continuing.

---

## Task 7: Change 2D — `tests/lib/test_sync_notes.sh` failure-message + new negative-presence assertions

**File:**
- Modify: `tests/lib/test_sync_notes.sh`

- [ ] **Step 7.1: Tweak the existing failure message**

Find the failure-message string in `test_synthesiser_verdict_output_restricted_to_two_values` that mentions "Class B downgrade or user override". Update it.

`old_string`:

```
            "the synthesiser's ## Verdict Output Format block must contain a 'Verdict: <APPROVE | REQUEST_CHANGES>' line — COMMENT is never a synthesiser output, only a Class B downgrade or user override"
```

`new_string`:

```
            "the synthesiser's ## Verdict Output Format block must contain a 'Verdict: <APPROVE | REQUEST_CHANGES>' line — COMMENT is never a synthesiser output, only a user override"
```

- [ ] **Step 7.2: Append the new negative-presence assertion function**

Append a new test function to `tests/lib/test_sync_notes.sh` (after the last existing function, before EOF). The function asserts the three legacy strings are absent from the contractually-expected sites.

```bash

test_orchestrator_comment_elision_negative_presence() {
    # After the orchestrator-COMMENT elision (spec 2026-05-19), three legacy
    # strings must not reappear in the contractually-expected sites:
    #
    # 1. SKILL.md must not contain "Outstanding peer REQUEST_CHANGES" — Class B.3
    #    was deleted in full. Reintroduction would mean the peer-RC downgrade
    #    path crept back, contradicting `final = synth`.
    # 2. SKILL.md must not contain `$DOWNGRADE_REASON` — the variable is retired
    #    along with Class A.3's middle template. Any reference would be dangling.
    # 3. The trivial-mode mini-review verdict bullet ("COMMENT if minor
    #    observations") was removed from the canonical pipeline and both inlined
    #    consumers. Reintroduction in any of the three sites would re-enable
    #    trivial-mode COMMENT verdicts.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "orchestrator COMMENT elision negative presence" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "orchestrator COMMENT elision: SKILL.md present" "missing: $skill"
        return
    fi

    if grep -qF 'Outstanding peer REQUEST_CHANGES' "$skill"; then
        fail "orchestrator COMMENT elision: SKILL.md drops 'Outstanding peer REQUEST_CHANGES'" \
            "Class B.3 (Outstanding peer REQUEST_CHANGES) was deleted by the 2026-05-19 spec — reintroduction reinstates the APPROVE → COMMENT downgrade path that conflicts with 'final = synth'"
    else
        pass "orchestrator COMMENT elision: SKILL.md drops 'Outstanding peer REQUEST_CHANGES'"
    fi

    if grep -qF '$DOWNGRADE_REASON' "$skill"; then
        fail "orchestrator COMMENT elision: SKILL.md drops \$DOWNGRADE_REASON" \
            "the \$DOWNGRADE_REASON variable was retired by the 2026-05-19 spec — any reference is dangling"
    else
        pass "orchestrator COMMENT elision: SKILL.md drops \$DOWNGRADE_REASON"
    fi

    local pipeline_canonical="$cr/includes/review-pipeline.md"
    local pipeline_skill="$skill"
    local pipeline_command="$cr/commands/pre-review.md"

    local site
    for site in "$pipeline_canonical" "$pipeline_skill" "$pipeline_command"; do
        local label
        label=$(basename "$(dirname "$site")")/$(basename "$site")

        if [[ ! -f "$site" ]]; then
            fail "orchestrator COMMENT elision: $label present" "missing: $site"
            continue
        fi

        if grep -qF 'COMMENT if minor observations' "$site"; then
            fail "orchestrator COMMENT elision: $label drops 'COMMENT if minor observations'" \
                "the trivial-mode mini-review's COMMENT verdict bullet was removed by the 2026-05-19 spec — reintroduction in any of the three propagation sites re-enables trivial-mode COMMENT verdicts"
        else
            pass "orchestrator COMMENT elision: $label drops 'COMMENT if minor observations'"
        fi
    done
}
```

- [ ] **Step 7.3: Run the full test suite**

Run: `bash /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins/tests/run.sh`

Expected:
- Every existing test still passes.
- `test_synthesiser_verdict_output_restricted_to_two_values` continues to pass (the failure-message tweak does not change the assertion logic).
- `test_orchestrator_comment_elision_negative_presence` produces 5 passes (`SKILL.md` × 2 + 3 propagation sites).
- `test_deletion_detection_real_block_triggers` and `test_deletion_detection_reindent_does_not_trigger` continue to pass.

If any sync test fails, the canonical/inlined wording drifted — diff the affected pair via the test output and re-sync.

---

## Task 8: Final verification + handoff

**Files:**
- No source edits; verification only.

- [ ] **Step 8.1: Repo-wide grep for residual COMMENT-downgrade references**

Run: `grep -rnF 'APPROVE → COMMENT downgrade' plugins/code-review-suite/`
Expected: zero hits.

Run: `grep -rnF 'orchestrator-adjusted' plugins/code-review-suite/`
Expected: zero hits.

Run: `grep -rnF 'Class B downgrade' plugins/code-review-suite/`
Expected: zero hits.

Run: `grep -rnF '$DOWNGRADE_REASON' plugins/code-review-suite/`
Expected: zero hits.

Any stray hits indicate a missed propagation site — re-edit before opening the PR.

- [ ] **Step 8.2: Repo-wide grep for residual `git diff`-without-`-w` significant-deletion references**

Run: `grep -nF 'Scan \`$FULL_DIFF\` hunks for **significant deletions:**' plugins/code-review-suite/`
Expected: zero hits.

Run: `grep -rcF 'git diff -w' plugins/code-review-suite/`
Expected: at least 6 hits (Phase 0.7.6 paragraph and Step 2.7 in canonical + 2 inlined consumers, all mention `git diff -w` once each).

- [ ] **Step 8.3: Final test-suite run**

Run: `bash /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins/tests/run.sh`

Expected: ALL tests pass. Note the total count and pass/fail summary.

- [ ] **Step 8.4: Show the user the working tree diff for review**

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins diff --stat main..HEAD`
Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins status --short`

Surface the file list and diff stats to the user.

- [ ] **Step 8.5: Pause for user instruction before committing**

The user's standing instruction is: do NOT commit unless explicitly asked. STOP here and ask the user how they want to proceed:

- Commit-and-push, then prepare a PR via `gh pr create`?
- Commit only (no push, no PR)?
- Something else?

Do not invoke `gh pr create` until the user gives the explicit green light.

- [ ] **Step 8.6: When the user authorises commit + PR**

Stage the touched files explicitly (no `-A` / `.`):

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/includes/verdict-rubric.md plugins/code-review-suite/agents/review-synthesiser.md plugins/code-review-suite/commands/pre-review.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md tests/lib/test_sync_notes.sh tests/lib/test_deletion_detection.sh tests/fixtures/deletion-detection/reindent.diff tests/fixtures/deletion-detection/real-deletion.diff docs/superpowers/specs/2026-05-19-deletion-detection-and-comment-elision-design.md docs/superpowers/plans/2026-05-19-deletion-detection-and-comment-elision.md`

Then commit (HEREDOC carve-out is permitted for `git commit -m`):

```bash
git commit -m "$(cat <<'EOF'
feat(code-review-suite): whitespace-aware deletion detection + orchestrator COMMENT elision

Two unrelated fixes bundled because they touch the same canonical files
and propagate through the same byte-strict sync tests.

1. Whitespace-aware deletion detection. Phase 0.7.6 (trivial-mode bar) and
   Step 2.7 (full-pipeline routing flag) now scan `git diff -w` for the
   "10+ contiguous deleted lines" rule. Whitespace-only re-indents no
   longer trip $SIGNIFICANT_DELETIONS. $FULL_DIFF stays un--w for the
   rest of the pipeline.

2. Orchestrator COMMENT elision. final = synth for every review path.
   Class B.3 (peer REQUEST_CHANGES → COMMENT downgrade) deleted in full;
   $DOWNGRADE_REASON retired; Class A.3 reduced from three templates to
   two; trivial-mode COMMENT verdict bullet dropped. COMMENT only ever
   reaches GitHub via the existing [c] user override under the
   REQUEST_CHANGES confirmation prompt.

Tests: tests/lib/test_sync_notes.sh failure-message tweak; new
test_orchestrator_comment_elision_negative_presence (5 assertions);
new tests/lib/test_deletion_detection.sh with two fixture-based tests.
EOF
)"
```

Per the user's CLAUDE.md, do NOT add a `Co-Authored-By: Claude` trailer.

Push the branch:

Run: `git -C /Users/jodre11/.claude/plugins/marketplaces/jodre11-plugins push -u origin feat/deletion-detection-and-comment-elision`

Open the PR. Use `gh pr create --body-file "$CLAUDE_TEMP_DIR/pr-body.md"` (the user's CLAUDE.md prefers `--body-file` over HEREDOC for PR bodies).

First write the PR body to `$CLAUDE_TEMP_DIR/pr-body.md` using the `Write` tool. Suggested content (no Claude Code advertising trailer per CLAUDE.md):

```markdown
This pair of fixes addresses two annoyances that came out of reviewing PR #319 on
HavenEngineering/finance-erp-config: a 1-line semantic change buried in a 12-line
re-indent was routed to the full 8-specialist pipeline, and the orchestrator
auto-downgraded an APPROVE to COMMENT when an unrelated peer review was hanging
around. Both behaviours are now removed. The work lands as a single PR because
both surfaces touch the canonical pipeline include and the verdict rubric, and
both propagate through the same byte-strict sync tests; splitting would have
forced the second PR to re-do the first PR's sync churn.

## Changes

**1. Whitespace-aware deletion detection (Phase 0.7.6 + Step 2.7).**
- The "10+ contiguous deleted lines" rule now measures on `git diff -w`
  output, so whitespace-only re-indents no longer trip
  `$SIGNIFICANT_DELETIONS`.
- `$FULL_DIFF` stays un-`-w` for everything else (specialists, archaeology
  anchors, `$CHANGED_LINES`, `$LINE_COUNT`).
- Edits land in the canonical `includes/review-pipeline.md` and propagate
  byte-identically to `commands/pre-review.md` and
  `skills/review-gh-pr/SKILL.md`.

**2. Orchestrator COMMENT elision.**
- `final = synth` for every review path. The orchestrator never auto-emits
  `COMMENT`.
- Class B.3 (peer `REQUEST_CHANGES` → `COMMENT` downgrade) deleted in full.
- `$DOWNGRADE_REASON` retired; Class A.3 reduced from three confirmation
  templates to two; Class A.2 simplified to a single line.
- Trivial-mode mini-review's `COMMENT` verdict bullet dropped (Phase 0.7.7).
- `COMMENT` still reaches GitHub only via the existing `[c]` user override
  under the `REQUEST_CHANGES` confirmation prompt — that path is preserved.

## Tests

- `tests/lib/test_sync_notes.sh` — failure-message tweak on the existing
  `Verdict:` restriction test, plus a new
  `test_orchestrator_comment_elision_negative_presence` function with five
  negative-presence assertions across `SKILL.md` and the three pipeline
  propagation sites.
- `tests/lib/test_deletion_detection.sh` (NEW) — two fixture-based tests
  exercising the deletion-detection rule against pre-canned re-indent vs
  real-deletion diffs.
- `tests/fixtures/deletion-detection/{reindent,real-deletion}.diff` (NEW).
- All existing structural tests (`bash tests/run.sh`) remain green.

Spec: `docs/superpowers/specs/2026-05-19-deletion-detection-and-comment-elision-design.md`.
Plan: `docs/superpowers/plans/2026-05-19-deletion-detection-and-comment-elision.md`.
```

Run: `gh pr create --base main --head feat/deletion-detection-and-comment-elision --title "feat(code-review-suite): whitespace-aware deletion detection + orchestrator COMMENT elision" --body-file "$CLAUDE_TEMP_DIR/pr-body.md"`

Stop. Do NOT merge — the user owns the merge decision.

---

## Notes for the executor

- The repository's CLAUDE.md forbids compound shell, command substitution, subshells, and most piping/redirection in `Bash` tool calls. Carve-outs are the `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC and the `2>&1` stderr capture. `awk` inline scripts in test files are fine — they run inside the test harness's invocation of `bash run.sh`, not via the Bash tool.
- `plugin.json` files in this marketplace deliberately omit `version`. The SHA-based versioning is documented in the project's CLAUDE.md.
- Use `$CLAUDE_TEMP_DIR` (already created by the SessionStart hook) for the PR-body file in Step 8.6.
- After every cluster of edits, read the test failure (if any) carefully — the `diff` output that `test_sync_*` produces is usually enough to spot the drift.
- Sync-test extraction patterns are very specific: the `verdict-rubric` extraction ends at `operations — no prose parsing.`; the `pipeline` extraction ends at `Present the synthesiser's formatted report to the user.`. Don't rephrase those exact end-anchor lines.
