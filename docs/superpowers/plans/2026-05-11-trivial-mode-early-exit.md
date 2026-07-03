# Trivial-mode Early Exit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Phase 0.7 trivial-mode tier to the code-review pipeline that lets the orchestrator handle docs/config-only PRs (≤3 files, ≤30 lines, allow-listed paths) with a 3-comment-cap mini-review and zero specialist agent dispatch, saving tokens and wall-clock time on the high-volume tail of trivial diffs.

**Architecture:** Insert a new `## Phase 0.7: Trivial-mode early exit` section in `plugins/code-review/includes/review-pipeline.md` between the existing Phase 0.6 (CI Status Gate) subtree and `### Step 1`. Phase 0.7 does its own minimal base-branch resolution and `git diff --shortstat` so it can short-circuit before Step 1; the duplication with Step 1/Step 2 is the cost of early-exit positioning. The mini-review runs in the orchestrator turn (no agent dispatch); the user confirms the verdict before any `gh pr review` call. The same content is then propagated verbatim into the two consumer files (`skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`); the existing `test_sync_pipeline_inline_matches_canonical` regression test enforces this sync.

**Tech Stack:** Markdown-only changes (canonical pipeline + 2 inlined consumers). Bash test harness in `tests/run.sh` validates structural sync.

**Path conventions used in this plan:**

- `$REPO_ROOT` — the repository root, resolved as `$(git rev-parse --show-toplevel)`. All shell snippets below use `$REPO_ROOT/<relative-path>` so the plan re-executes correctly from any working directory or machine.
- `$CLAUDE_TEMP_DIR` — per-session temp directory injected by the SessionStart hook (see `~/.claude/CLAUDE.md`). All commit-message bodies and intermediate files are written here.

Resolve `$REPO_ROOT` once at the start of execution — e.g. `REPO_ROOT="$(git rev-parse --show-toplevel)"` — then run subsequent commands with that variable in scope. `$CLAUDE_TEMP_DIR` is already set by the harness.

---

## File Structure

Files modified:
- `plugins/code-review/includes/review-pipeline.md` — canonical source; insert `## Phase 0.7: Trivial-mode early exit` between Phase 0.6's subtree and `### Step 1`
- `plugins/code-review/skills/review-gh-pr/SKILL.md` — re-spliced consumer (must match canonical body verbatim)
- `plugins/code-review/commands/pre-review.md` — re-spliced consumer (must match canonical body verbatim)
- `plugins/code-review/README.md` — short note that trivial-mode exists (only if there's a relevant section to amend; not blocking)

No new files. No new tests beyond the existing sync tests (which already enforce the canonical→consumer relationship and will catch drift automatically).

## Self-contained reference: the Phase 0.7 prose to insert

This is the verbatim text that goes into the canonical and gets propagated to both consumers. It is reproduced once here so each task below can reference "the Phase 0.7 block" without the engineer needing to scroll. **The exact same text MUST appear in all three files** — this is what the sync test enforces.

````markdown
## Phase 0.7: Trivial-mode early exit

Run Phase 0.7 AFTER Phase 0.6 and BEFORE Step 1. Phase 0.7 is an orchestrator-only
short-circuit for diffs that are clearly low-risk (docs-only / config-only edits). It
saves tokens and wall-clock time by avoiding agent dispatch entirely on the high-volume
tail of trivial PRs (typo fixes, version bumps, README edits).

The bar is deliberately conservative — when in doubt, fall through to Step 1 and let
the full pipeline (or lightweight path) handle the diff. Trivial-mode is not a routing
optimisation; it is an early exit for cases where dispatching even one specialist is
overkill.

### 0.7.1 Skip if overridden

If `$ARGUMENTS` contains the bare token `--force` (matching as a whitespace-delimited
word, not as a substring), skip Phase 0.7 entirely and continue to Step 1. The
`--force` token signals the user wants the full pipeline regardless of diff size.

If `.claude/code-review.toml` exists and contains
`intent.skip_trivial_check = true`, skip Phase 0.7 entirely and continue to Step 1.
Skip silently if the file is missing or malformed — this is optional configuration.

### 0.7.2 Resolve $TRIVIAL_BASE

To evaluate the trivial bar before Step 1's full base-branch resolution, Phase 0.7
must resolve `$BASE` itself. Apply the same priority order as Step 1 (items 1-4):

1. If `$ARGUMENTS` is provided and non-empty, extract the base branch from it. If a
   `Base branch: <ref>` line is present, extract the ref after the colon. Otherwise,
   treat the entire value of `$ARGUMENTS` (with `--force` stripped if present) as a
   bare branch name.
2. `gh pr view --json baseRefName -q .baseRefName 2>/dev/null` — use if a PR already
   exists.
3. Run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null` and strip the
   `refs/remotes/origin/` prefix from the output — default branch.
4. Fall back to `main`.

Store as `$TRIVIAL_BASE`. Validate that `$TRIVIAL_BASE` matches
`^[a-zA-Z0-9/_.\-]+$` — if it does not, skip Phase 0.7 and continue to Step 1
(Step 1's own validation will surface the error to the user there).

If `$TRIVIAL_BASE` is exactly `EMPTY_TREE`, resolve it by running
`git hash-object -t tree /dev/null` and set `$TRIVIAL_EMPTY_TREE_MODE = true`.
Otherwise set `$TRIVIAL_EMPTY_TREE_MODE = false`. Use two-arg diff syntax
(`git diff $TRIVIAL_BASE HEAD`) when `$TRIVIAL_EMPTY_TREE_MODE` is true, three-dot
syntax (`git diff "$TRIVIAL_BASE"...HEAD`) otherwise, for ALL diff commands in
0.7.3 and 0.7.6 below.

### 0.7.3 Measure for the trivial bar

Run these commands using the diff syntax determined by `$TRIVIAL_EMPTY_TREE_MODE`:

```
git diff --name-only [diff-syntax]    # store as $TRIVIAL_FILES (one path per line)
git diff --shortstat [diff-syntax]    # parse to $TRIVIAL_FILE_COUNT, $TRIVIAL_LINE_COUNT
```

`$TRIVIAL_FILE_COUNT` is the count from `X file(s) changed`. `$TRIVIAL_LINE_COUNT` is
insertions + deletions from the same shortstat line. If only insertions or only
deletions appear, treat the absent count as 0. If `$TRIVIAL_FILES` is empty (no diff),
skip Phase 0.7 — Step 1 will then halt with "No changes found".

### 0.7.4 Apply the allow-list

The trivial-mode allow-list is configurable via `.claude/code-review.toml` under
`intent.trivial_paths.allow_extensions` (array of extensions, with leading dot, e.g.
`[".md", ".json"]`) and `intent.trivial_paths.exclude_paths` (array of glob patterns).
If either key is absent or malformed, fall back to the default list below.

**Default allow-list (extensions):** `.md`, `.markdown`, `.json`, `.toml`, `.yaml`,
`.yml`, `.txt`, `.gitignore`, `.gitattributes`, `.editorconfig`. Plus bare-name match
for `LICENSE` (any path whose basename is exactly `LICENSE`).

**Default exclude paths (load-bearing prompts — these files have `.md` extensions but
they are code, not docs):**
- `plugins/*/agents/`
- `plugins/*/skills/`
- `plugins/*/commands/`
- `plugins/*/includes/`

For each file in `$TRIVIAL_FILES`:

1. If the file path matches any exclude pattern (using glob semantics), the trivial
   bar fails — skip to "Trivial bar failed" below.
2. If the file's extension (or bare name, for `LICENSE`) is not in the allow list,
   the trivial bar fails — skip to "Trivial bar failed".

If every file in `$TRIVIAL_FILES` passes both checks, continue to 0.7.5.

### 0.7.5 Apply the size bar

The bar passes only if both:

- `$TRIVIAL_FILE_COUNT <= 3`
- `$TRIVIAL_LINE_COUNT <= 30`

If either is false, the trivial bar fails.

### 0.7.6 Check for significant deletions

Run `git diff [diff-syntax]` and scan hunks for any single hunk with 10+ contiguous
deleted lines. This duplicates Step 2.6's `$SIGNIFICANT_DELETIONS` logic; the
duplication is intentional to keep Phase 0.7 self-contained as a fast-path pre-check.

If any such hunk exists, the trivial bar fails — fall through to Step 1.

### Trivial bar failed

If any of 0.7.4 / 0.7.5 / 0.7.6 caused the bar to fail, announce
`> Trivial-mode bar not met — continuing to Step 1` and continue to Step 1. The
values measured in 0.7.3 are NOT reused by Step 2 — Step 2 re-measures
independently. The cost of re-measuring is one or two extra `git diff` calls
(negligible).

### 0.7.7 Trigger trivial-mode mini-review

If the bar passed (allow-listed paths, ≤3 files, ≤30 lines, no significant
deletions, no override), enter the mini-review.

Announce:
`> Trivial-mode triggered: $TRIVIAL_FILE_COUNT files, $TRIVIAL_LINE_COUNT lines (docs/config only)`

Read each file in `$TRIVIAL_FILES` and run `git diff [diff-syntax]` to see the full
hunks. Form an opinion on what changed and why.

Draft a structured mini-review:

- **Verdict:** `APPROVE` if everything looks fine, `COMMENT` if minor observations are
  worth surfacing, `REQUEST_CHANGES` if anything is wrong.
- **Top-level body (2-3 sentences):** Explain what changed and why the diff qualifies
  for trivial-mode. End the body with the verbatim line:
  `Reviewed via trivial-mode fast path: docs/config diff under the size bar.`
- **Inline comments (HARD CAP of 3):** Only if any are warranted. Each one attached
  to a specific `file:line`. If you would naturally have more than 3 issues, do NOT
  truncate silently — instead, fail the bar (announce `> Trivial-mode aborted: more
  than 3 issues warrant comment — falling through to Step 1` and continue to Step 1).
  Same tone guidelines as full reviews (use "Consider…", "Would it be worth…", etc).

### 0.7.8 User confirmation

Present the draft mini-review to the user (verdict + body + inline comments) and ask:

```
> Trivial-mode mini-review complete. Verdict: <VERDICT>. <N> inline comments.
> Review the draft above. Submit? [y/N]
```

Read one line. If the answer begins with `y` or `Y`, continue to 0.7.9. Otherwise
halt cleanly with `> Trivial-mode halt: user declined` and stop the pipeline. Do
NOT fall through to Step 1 (the user's "no" applies to the whole review, not just
trivial-mode — they can re-invoke with `--force` if they want the full pipeline).

### 0.7.9 Post the mini-review

**Mode `pr`:**

For each inline comment, post via the `gh api repos/{owner}/{repo}/pulls/{pr}/comments`
pattern documented in Step 5 of `skills/review-gh-pr/SKILL.md` (use `--input -`
heredoc for the body, `-F` for integer parameters, `-f side='LEFT|RIGHT'` based on
diff polarity).

After all inline comments post, submit the verdict via `gh pr review` using
`--approve`, `--request-changes`, or `--comment` per the verdict, with `--input -`
heredoc for the body.

**Mode `local`:**

Print the full mini-review to stdout (verdict header + body + each inline comment
prefixed with `file:line —`). Do NOT post anything to GitHub.

After posting (or printing) succeeds, announce
`> Trivial-mode review complete — pipeline exited without dispatching specialists`
and stop the pipeline cleanly. Do not proceed to Step 1.
````

End of Phase 0.7 block.

---

## Tasks

### Task 1: Branch setup

**Files:**
- None modified yet — branch creation only.

- [ ] **Step 1: Verify base state**

Run:
```
git -C "$(git rev-parse --show-toplevel)" switch main
git -C "$(git rev-parse --show-toplevel)" pull --ff-only
git -C "$(git rev-parse --show-toplevel)" status
```

Expected: on `main`, up to date with `origin/main`, working tree clean (untracked file `docs/superpowers/plans/2026-05-05-restore-orphaned-improvements.md` is allowed and unrelated).

- [ ] **Step 2: Create feature branch**

Run:
```
git -C "$(git rev-parse --show-toplevel)" switch -c feat/trivial-mode-early-exit
```

Expected: switched to new branch `feat/trivial-mode-early-exit`.

- [ ] **Step 3: Run baseline test suite**

Run:
```
bash $REPO_ROOT/tests/run.sh
```

Expected: `103 tests: 103 passed`. (Output may include skip lines if dev tools are missing — only count passes/fails.) If any test fails on the unmodified branch, STOP and investigate before proceeding.

---

### Task 2: Add Phase 0.7 to the canonical pipeline

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md` — insert the Phase 0.7 block between `### Progress line format` and `### Step 1: Determine base branch`.

- [ ] **Step 1: Locate the insertion point**

Open `plugins/code-review/includes/review-pipeline.md`. Find the lines:

```
Where `<Xs>` is seconds since that agent was dispatched, and `R` counts down to 0.

### Step 1: Determine base branch
```

The new Phase 0.7 block goes between these two paragraphs — after the progress-format trailer line and before `### Step 1`.

- [ ] **Step 2: Insert the Phase 0.7 block**

Use the Edit tool to perform a unique-string replacement:

- `old_string` (the exact existing text):
  ```
  Where `<Xs>` is seconds since that agent was dispatched, and `R` counts down to 0.
  
  ### Step 1: Determine base branch
  ```

- `new_string` (the existing trailer + a blank line + the entire Phase 0.7 block from this plan's "Self-contained reference: the Phase 0.7 prose to insert" section + a blank line + `### Step 1: Determine base branch`):

  Use the verbatim Phase 0.7 block from this plan above. The replacement must produce a file where:
  1. Phase 0.7 starts with `## Phase 0.7: Trivial-mode early exit`
  2. Phase 0.7 ends with `… and stop the pipeline cleanly. Do not proceed to Step 1.`
  3. Step 1's heading is unchanged on the next line

- [ ] **Step 3: Verify the file structure**

Run:
```
grep -n "^## Phase\|^### Step" $REPO_ROOT/plugins/code-review/includes/review-pipeline.md
```

Expected output (in this order):
```
## Phase 0: Intent Ledger
## Phase 0.6: CI Status Gate
## Phase 0.7: Trivial-mode early exit
### Step 1: Determine base branch
### Step 2: Measure the diff and build agent prompt
### Step 3: Route
### Step 4: Dispatch specialists
### Step 5: Cross-review
### Step 6: Dispatch synthesiser
### Step 7: Present results
```

If `Phase 0.7` is missing or in the wrong position, fix and re-run.

- [ ] **Step 4: Verify the canonical-only sync test now FAILS**

Run:
```
bash $REPO_ROOT/tests/run.sh 2>&1 | grep -A1 "pipeline inline sync"
```

Expected: `pipeline inline sync: review-gh-pr/SKILL.md matches canonical` and `pipeline inline sync: commands/pre-review.md matches canonical` BOTH FAIL with diff output. This confirms the test is doing its job — the consumers haven't been updated yet, so they should diverge.

If the test shows PASS, the canonical didn't actually change — re-check Step 2 above.

- [ ] **Step 5: Commit**

Run:
```
git -C "$(git rev-parse --show-toplevel)" add plugins/code-review/includes/review-pipeline.md
```

Then commit with a body file at `${CLAUDE_TEMP_DIR}/commit-msg-task2.txt`:

```
feat(code-review): add Phase 0.7 trivial-mode early exit to canonical pipeline

Adds an orchestrator-only short-circuit for docs/config-only diffs (≤3 files,
≤30 lines, allow-listed extensions, excluding load-bearing prompt paths under
plugins/*/agents|skills|commands|includes/). Trivial-mode forms a structured
mini-review (verdict + 2-3 sentence body + ≤3 inline comments) without
dispatching any specialist agents and posts after user confirmation.

The block is added to the canonical only — consumers (review-gh-pr SKILL and
pre-review command) are propagated in follow-up commits to keep each diff
inspectable in isolation.

This commit intentionally breaks the test_sync_pipeline_inline_matches_canonical
sync test until the consumers are propagated. The next two commits restore the
test to passing.
```

Then run:
```
git -C "$(git rev-parse --show-toplevel)" commit -F $CLAUDE_TEMP_DIR/commit-msg-task2.txt
```

Expected: pre-commit hooks pass; one new commit on `feat/trivial-mode-early-exit`.

If the pre-commit secret-scan hook flags anything, investigate the false positive (do NOT skip the hook).

---

### Task 3: Propagate Phase 0.7 to review-gh-pr SKILL.md

**Files:**
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md` — same insertion as Task 2.

- [ ] **Step 1: Locate the insertion point in the consumer**

Open `plugins/code-review/skills/review-gh-pr/SKILL.md`. Find the same anchor used in Task 2:
```
Where `<Xs>` is seconds since that agent was dispatched, and `R` counts down to 0.

### Step 1: Determine base branch
```

This anchor appears once in the inlined pipeline body.

- [ ] **Step 2: Insert the same Phase 0.7 block, verbatim**

Use the Edit tool with the SAME `old_string` and `new_string` as Task 2 Step 2. The block must be byte-identical to the canonical — the sync test diffs character-by-character.

- [ ] **Step 3: Verify the consumer structure**

Run:
```
grep -n "^## Phase\|^### Step 1\|^### Step 2\|^### Step 3" $REPO_ROOT/plugins/code-review/skills/review-gh-pr/SKILL.md
```

Expected: Phase 0.7 line appears between Phase 0.6 and Step 1, in the inlined pipeline section. (The file also has its own `## Step 1: Gather PR Information`, `## Step 3: Plan Comments`, etc. at `##` level — those are the SKILL's own outer steps, not the inlined pipeline.)

- [ ] **Step 4: Run the sync test for this consumer only**

Run:
```
bash $REPO_ROOT/tests/run.sh 2>&1 | grep "pipeline inline sync"
```

Expected: `pipeline inline sync: review-gh-pr/SKILL.md matches canonical` PASSES. `pipeline inline sync: commands/pre-review.md matches canonical` should still FAIL (pre-review hasn't been propagated yet).

If review-gh-pr fails, the inlined block isn't byte-identical — diff the canonical and consumer to find the discrepancy:
```
diff <(sed -n '/^Follow these instructions exactly/,/^Present the synthesiser.*formatted report to the user\.$/p' $REPO_ROOT/plugins/code-review/includes/review-pipeline.md) <(sed -n '/^Follow these instructions exactly/,/^Present the synthesiser.*formatted report to the user\.$/p' $REPO_ROOT/plugins/code-review/skills/review-gh-pr/SKILL.md)
```

- [ ] **Step 5: Commit**

Body file at `${CLAUDE_TEMP_DIR}/commit-msg-task3.txt`:

```
feat(code-review): propagate Phase 0.7 trivial-mode into review-gh-pr SKILL

Re-splices the canonical Phase 0.7 block into the inlined pipeline body in
skills/review-gh-pr/SKILL.md. Restores the test_sync_pipeline_inline_matches_canonical
test for this consumer. The pre-review command consumer is propagated in the
next commit.
```

Run:
```
git -C "$(git rev-parse --show-toplevel)" add plugins/code-review/skills/review-gh-pr/SKILL.md
git -C "$(git rev-parse --show-toplevel)" commit -F $CLAUDE_TEMP_DIR/commit-msg-task3.txt
```

---

### Task 4: Propagate Phase 0.7 to pre-review command

**Files:**
- Modify: `plugins/code-review/commands/pre-review.md` — same insertion as Task 2.

- [ ] **Step 1: Locate the insertion point**

Open `plugins/code-review/commands/pre-review.md`. Find the same anchor:
```
Where `<Xs>` is seconds since that agent was dispatched, and `R` counts down to 0.

### Step 1: Determine base branch
```

- [ ] **Step 2: Insert the same Phase 0.7 block, verbatim**

Use the Edit tool with the same `old_string` and `new_string` as Tasks 2 and 3. Byte-identical to canonical.

- [ ] **Step 3: Run the full sync test suite**

Run:
```
bash $REPO_ROOT/tests/run.sh
```

Expected: `103 tests: 103 passed` — back to the baseline. All sync tests now pass; Phase 0.7 is in all three pipeline files byte-identical.

If any sync test fails:
- Diff the canonical against the failing consumer (use the same diff command as Task 3 Step 4 with the appropriate path)
- Identify the byte-level discrepancy (often a stray space, a tab vs spaces, or a missing newline)
- Fix and re-run

- [ ] **Step 4: Commit**

Body file at `${CLAUDE_TEMP_DIR}/commit-msg-task4.txt`:

```
feat(code-review): propagate Phase 0.7 trivial-mode into pre-review command

Re-splices the canonical Phase 0.7 block into the inlined pipeline body in
commands/pre-review.md. With this commit, all three pipeline files
(canonical + 2 consumers) are byte-identical for the Phase 0.7 block and the
test_sync_pipeline_inline_matches_canonical sync test passes again.
```

Run:
```
git -C "$(git rev-parse --show-toplevel)" add plugins/code-review/commands/pre-review.md
git -C "$(git rev-parse --show-toplevel)" commit -F $CLAUDE_TEMP_DIR/commit-msg-task4.txt
```

---

### Task 5: Update plugin README to mention trivial-mode

**Files:**
- Modify: `plugins/code-review/README.md` — add a short paragraph in the appropriate section.

- [ ] **Step 1: Read the README**

Read `plugins/code-review/README.md` end-to-end. Identify the section that describes routing tiers (lightweight vs. full review). Trivial-mode belongs in the same section as the smallest sibling.

- [ ] **Step 2: Add a trivial-mode paragraph**

Add a short paragraph (3-4 sentences) describing:
- What trivial-mode does (orchestrator-only mini-review for docs/config edits)
- The bar (≤3 files, ≤30 lines, allow-listed extensions, excludes load-bearing prompt paths)
- The override (`--force` arg or `intent.skip_trivial_check = true` in `.claude/code-review.toml`)
- How it integrates with the existing pipeline (runs after Phase 0/0.6, before Step 1; falls through to the normal lightweight/full path if the bar isn't met)

If the README has no obvious section for routing/tiers, place the paragraph next to the existing description of the routing thresholds. If there's no such description at all, this task can be skipped — the canonical pipeline is the source of truth.

- [ ] **Step 3: Verify and commit**

Run:
```
bash $REPO_ROOT/tests/run.sh
```

Expected: still 103 tests passing.

Body file at `${CLAUDE_TEMP_DIR}/commit-msg-task5.txt`:

```
docs(code-review): document trivial-mode early exit in plugin README

Adds a short paragraph next to the existing routing-tier description so users
know about the new orchestrator-only path for docs/config diffs and the
override flag.
```

Run:
```
git -C "$(git rev-parse --show-toplevel)" add plugins/code-review/README.md
git -C "$(git rev-parse --show-toplevel)" commit -F $CLAUDE_TEMP_DIR/commit-msg-task5.txt
```

If the README has no relevant section to amend, skip this task (no commit) and note it in the PR body.

---

### Task 6: Push and open PR

**Files:**
- None modified.

- [ ] **Step 1: Push the branch**

Run:
```
git -C "$(git rev-parse --show-toplevel)" push -u origin feat/trivial-mode-early-exit
```

- [ ] **Step 2: Draft PR body**

Write the body to `${CLAUDE_TEMP_DIR}/trivial-mode-pr-body.md`. Body structure (per the global CLAUDE.md non-technical-summary opener convention):

1. **Lead paragraph (1-3 sentences, non-technical):** What trivial-mode is, why it exists (docs PRs going through the full agent fan-out is wasteful), where it sits in the pipeline. Mention this is item 1 of 3 from the differential-analysis backlog (link spec PR #15).

2. **`## Summary` section:** Bullet points covering:
   - New `## Phase 0.7: Trivial-mode early exit` section between Phase 0.6 and Step 1 in the canonical pipeline
   - Allow-list bar (≤3 files, ≤30 lines, allow-listed extensions, excludes `plugins/*/agents|skills|commands|includes/`)
   - `--force` arg and `intent.skip_trivial_check` config override
   - Mini-review with hard cap of 3 inline comments and user-confirm gate
   - Same canonical block re-spliced into both consumers
   - README updated (or skipped — note if applicable)

3. **`## Context` section:** Reference the spec PR (#15), the comparison doc (`docs/adamsreview-comparison.md`), and call out the next two items (changed-line filter, token instrumentation).

4. **`## Test plan` section:** Bulleted checklist:
   - [ ] `bash tests/run.sh` passes (103 tests, no regressions)
   - [ ] Sync tests verify Phase 0.7 is byte-identical across canonical and both consumers
   - [ ] Dogfood by running `/code-review:review-gh-pr <this-pr>` against the PR itself; confirm Phase 0.7 does NOT trigger (this PR exceeds the trivial bar) and the full pipeline runs

- [ ] **Step 3: Open the PR**

Run:
```
gh pr create --base main --head feat/trivial-mode-early-exit --title "feat(code-review): add Phase 0.7 trivial-mode early exit" --body-file $CLAUDE_TEMP_DIR/trivial-mode-pr-body.md
```

Capture the resulting PR URL — the next task uses the PR number.

---

### Task 7: Dogfood the new behaviour against the PR itself

**Files:**
- None modified.

- [ ] **Step 1: Wait for CI**

The PR triggers GitHub Actions (gitleaks, lint, etc). Wait for CI to settle. Run:
```
gh pr checks <pr-number>
```

Expected: all checks PASS or PENDING / IN_PROGRESS.

- [ ] **Step 2: Refresh local plugin cache**

This PR's changes do NOT take effect in the running session — the pipeline is loaded from the marketplace cache. To dogfood the new behaviour, the user must run `/plugins update` in a fresh session against the merged version. For the **pre-merge dogfood** here, we run the existing (unmodified) pipeline against the new PR — this exercises the existing behaviour against the new diff and confirms no regressions in the parts of the pipeline that were NOT changed.

(The post-merge dogfood — running the new pipeline against new diffs — happens after merge, when the user runs `/plugins update`. This is captured in the user-facing followup, not this task.)

Continue to Step 3.

- [ ] **Step 3: Run the review**

In the active Claude Code session, invoke:
```
/code-review:review-gh-pr <pr-number>
```

Expected behaviour (using the existing pipeline, since cache is unchanged):
- Phase 0 sufficiency check passes (the PR body has a clear narrative paragraph)
- Phase 0.6 CI gate passes (assuming CI is green)
- Step 2 measures: 3-4 files (canonical + 2 consumers + maybe README), several hundred lines — exceeds the trivial bar even if 0.7 were active
- Step 3 routes to lightweight or full pipeline (depends on `$LINE_COUNT` against the 150 threshold)
- Specialists run; synthesiser reports

Confirm:
- The review actually completes
- No new errors surface from interaction with the unchanged-pipeline-against-changed-diff scenario
- Findings are about the actual pipeline change quality, not pipeline malfunctions

- [ ] **Step 4: Address dogfood findings**

Triage the findings:
- **Blockers** → fix in additional commits on the same branch, push, request human review only after blockers are resolved
- **Suggestions** → respond inline (accept, defer, dispute) per the existing PR-review workflow
- **Style/nitpicks** → judgement call

Track the round-trip: which findings were valid, which were false positives, which the synthesiser dismissed.

- [ ] **Step 5: Request human review**

Once the dogfood pass is settled (no blockers outstanding, suggestions handled), the PR is ready for human (the user) review. Surface the PR link to the user with a one-line summary of the dogfood outcome.

---

### Task 8: Post-merge follow-up reminder

**Files:**
- None modified.

- [ ] **Step 1: After human review and merge, remind the user**

Once the user merges the PR, in the same active session, remind them to run:

```
/plugins update
/reload-plugins
```

This refreshes the marketplace cache and makes Phase 0.7 active for the next review. Without this, item 2 (changed-line filter) and the post-merge state of this PR run against a stale pipeline.

(Memory note `feedback_plugins_update_after_push.md` already captures this rule. The reminder is a manual nudge to the user.)

- [ ] **Step 2: Move on to item 2 (changed-line filter)**

Item 2's plan is created in a separate writing-plans cycle once item 1 is merged. The two are independent.

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Plan task |
|---|---|
| New Phase 0.7 between Phase 0.6 and Step 1 | Task 2 |
| Allow-list extensions (`.md`, `.json`, etc) | Task 2 (in 0.7.4 of the inserted block) |
| Exclude `plugins/*/agents|skills|commands|includes/` | Task 2 (in 0.7.4) |
| Bar: ≤3 files, ≤30 lines, no significant deletions | Task 2 (in 0.7.5, 0.7.6) |
| Override: `--force` arg, `intent.skip_trivial_check` config | Task 2 (in 0.7.1) |
| Hard cap of 3 inline comments | Task 2 (in 0.7.7) |
| User confirms verdict before posting | Task 2 (in 0.7.8) |
| Local mode prints to stdout, does NOT post | Task 2 (in 0.7.9 mode `local`) |
| Re-splice into both consumers | Tasks 3, 4 |
| Sync test enforces canonical=consumers | Tasks 2 step 4, 4 step 3 (uses existing test) |
| Optional `.claude/code-review.toml` schema | Task 2 documents the keys in the prose; schema doc itself is implicit |

All spec requirements have task coverage. The optional `.claude/code-review.toml` schema doc was deferred to prose-only documentation, matching the existing pattern for `intent.doc_paths` (which is also documented in prose, not in a separate schema file).

**Placeholder scan:** No "TBD", "TODO", or "implement later" tokens. Each task step has either explicit code/text to insert or a specific command to run with expected output.

**Type consistency:**
- `$TRIVIAL_BASE`, `$TRIVIAL_FILES`, `$TRIVIAL_FILE_COUNT`, `$TRIVIAL_LINE_COUNT`, `$TRIVIAL_EMPTY_TREE_MODE` — all used consistently in 0.7.2, 0.7.3, 0.7.4, 0.7.5, 0.7.6
- `$BASE`, `$FULL_DIFF`, `$FILE_COUNT`, `$LINE_COUNT`, `$SIGNIFICANT_DELETIONS` — these are Step 2's variables and are NOT shared with Phase 0.7 (intentional — 0.7 has its own copies prefixed with `TRIVIAL_` to avoid confusion when the bar fails and Step 2 re-measures)

**Position-vs-mechanism resolution:** The spec says "between Phase 0.6 and Step 1" and the user's instruction repeats this. The mechanical question (Phase 0.7 needs base-branch resolution and diff measurement, which are Step 1's and Step 2's jobs) is resolved by having Phase 0.7 do its own minimal copies of those operations. The cost is one extra `git diff --shortstat` and one extra `git diff` invocation in the non-trivial case. This was the most faithful interpretation of the spec without re-designing.

**Re-review interaction:** Self-re-review mode in `review-gh-pr` SKILL.md takes a path that bypasses the inlined pipeline entirely (Step 2 of the SKILL: "If self-re-review mode: Do NOT dispatch the full agent team … Then skip directly to Step 3"). Phase 0.7 lives inside the inlined pipeline, so it does not run in self-re-review mode — no special-casing needed.

**No new tests:** The existing `test_sync_pipeline_inline_matches_canonical` already enforces canonical-vs-consumer parity for the entire pipeline body, including the new Phase 0.7 block. The existing 103-test baseline becomes the verification gate.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-11-trivial-mode-early-exit.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
