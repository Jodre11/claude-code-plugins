# Housekeeper Subagent Bash-Failure Remediation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four independent causes of `housekeeper-reviewer` Bash failures when dispatched as a background subagent, making failures loud and success deterministic.

**Architecture:** Two PRs across two repos. PR 1 (`claude-settings` + template) adds the `housekeeper-freshness` binary to the hook allowlist and settings.json permission pattern. PR 2 (`jodre11-plugins`) rewrites the pipeline temp-dir injection (Fix A), hardens the housekeeper's Bash commands (Fix C), and adds loud failure + no-fabrication rules (Fix D). The two PRs are independent at the code level but PR 1 must land first operationally.

**Tech Stack:** Shell (hooks), JSON (settings), Markdown (agent/pipeline prompts), Bash (test suite)

---

## PR 1 — `claude-settings` + template: Fix B (allowlist `housekeeper-freshness`)

### Task 1: Add `housekeeper-freshness` to the hook allowlist

**Files:**
- Modify: `~/.claude/hooks/allow-permissions.sh:48` (add to static-analysis case arm)
- Modify: `~/Repos/claude-settings-template/hooks/allow-permissions.sh:48` (mirror)

- [ ] **Step 1: Edit the local `allow-permissions.sh`**

In `~/.claude/hooks/allow-permissions.sh`, add `housekeeper-freshness` to the static-analysis case arm (line 48). Change:

```bash
    ruff|nbqa|trivy|eslint|biome) hook_allow "$REASON" ;;
```

to:

```bash
    ruff|nbqa|trivy|eslint|biome|housekeeper-freshness) hook_allow "$REASON" ;;
```

- [ ] **Step 2: Mirror to the template repo**

Apply the identical edit to `~/Repos/claude-settings-template/hooks/allow-permissions.sh` (same case arm).

- [ ] **Step 3: Verify both files match on the static-analysis line**

Run: `grep "ruff|nbqa" ~/.claude/hooks/allow-permissions.sh ~/Repos/claude-settings-template/hooks/allow-permissions.sh`

Expected: both lines identical, both contain `housekeeper-freshness`.

---

### Task 2: Add `Bash(housekeeper-freshness *)` to permissions.allow in the .tmpl

**Files:**
- Modify: `~/.claude/settings.json.tmpl:20` (add after the `biome` line)
- Modify: `~/Repos/claude-settings-template/settings.json.tmpl` (mirror)

- [ ] **Step 1: Edit the local settings.json.tmpl**

In `~/.claude/settings.json.tmpl`, add a new line after `"Bash(biome:*)"` (line 20):

```json
      "Bash(housekeeper-freshness:*)",
```

The colon-wildcard pattern matches the hook's base-command extraction (first word of the command string). This is consistent with the existing `Bash(ruff:*)` / `Bash(trivy:*)` patterns.

- [ ] **Step 2: Mirror to the template repo**

Apply the identical addition to `~/Repos/claude-settings-template/settings.json.tmpl` at the same position.

- [ ] **Step 3: Run hydrate.sh to regenerate settings.json**

Run: `~/.claude/hydrate.sh --force`

Expected: exits 0, `settings.json` now contains `"Bash(housekeeper-freshness:*)"`.

- [ ] **Step 4: Verify the hydrated settings.json**

Run: `grep "housekeeper-freshness" ~/.claude/settings.json`

Expected: one line matching `"Bash(housekeeper-freshness:*)"`.

---

### Task 3: Commit and push PR 1

**Files:**
- Commit in `~/.claude`: `hooks/allow-permissions.sh`, `settings.json.tmpl`, `settings.json`
- Commit in `~/Repos/claude-settings-template/`: `hooks/allow-permissions.sh`, `settings.json.tmpl`

- [ ] **Step 1: Commit in claude-settings**

```bash
cd ~/.claude
git add hooks/allow-permissions.sh settings.json.tmpl settings.json
git commit -m "fix(hooks): allowlist housekeeper-freshness for dispatched subagents

The housekeeper-reviewer engine binary was missing from allow-permissions.sh
and permissions.allow, causing auto-deny when dispatched as a background
subagent (Claude Code issue #18950 workaround). Add it alongside ruff/trivy/eslint."
```

- [ ] **Step 2: Push claude-settings**

Run: `git -C ~/.claude push`

- [ ] **Step 3: Commit in the template repo**

```bash
cd ~/Repos/claude-settings-template
git add hooks/allow-permissions.sh settings.json.tmpl
git commit -m "fix(hooks): allowlist housekeeper-freshness for dispatched subagents

Mirror of the local claude-settings change. The housekeeper-freshness engine
binary needs pre-authorisation for background subagent dispatch."
```

- [ ] **Step 4: Push the template repo**

Run: `git -C ~/Repos/claude-settings-template push`

---

## PR 2 — `jodre11-plugins`: Fixes A, C, D

### Task 4: Fix A — Rewrite pipeline Step 2.9 temp-dir line (canonical)

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md:715`

- [ ] **Step 1: Edit the pipeline canonical source**

In `plugins/code-review-suite/includes/review-pipeline.md`, change line 715 from:

```
Review only the lines listed in the `Changed lines:` block above for each file. Use $CLAUDE_TEMP_DIR for temporary files.
```

to:

```
Review only the lines listed in the `Changed lines:` block above for each file. Use $RESOLVED_TEMP_DIR for temporary files.
```

This is the line inside the `$AGENT_PROMPT` code block. The orchestrator now substitutes the resolved `/tmp/claude-<session-id>/` path into `$RESOLVED_TEMP_DIR` before dispatching.

- [ ] **Step 2: Add a resolution instruction above the code block**

Immediately before the code block that defines `$AGENT_PROMPT` (the line that reads "Define `$AGENT_PROMPT` with the following lines, replacing all variables with their resolved values:"), add one bullet to the existing list of instructions explaining the resolution:

After the existing bullet `- `$CHANGED_LINES_BLOCK` is always populated (Step 2.5 either built it or halted)`, add:

```
- `$RESOLVED_TEMP_DIR` — the concrete `/tmp/claude-<session-id>/` path from the SessionStart hook's `additionalContext` text. Read the session ID from the `CLAUDE_SESSION_ID=<uuid>` line or the `CLAUDE_TEMP_DIR=/tmp/claude-<uuid>` line in the conversation context injected by the SessionStart hook. The orchestrator resolves this once and substitutes the literal absolute path into the prompt — subagents do not have the environment variable or the hook context, so the literal path is the only mechanism that works. Example resolved value: `/tmp/claude-5bf0f026-ba82-43b7-8c4d-4c116b4bebf7/`.
```

- [ ] **Step 3: Update the synthesiser prompt in Step 6.2**

In the same file, line 1154, the synthesiser prompt also ends with `Use $CLAUDE_TEMP_DIR for temporary files.`. Change it to `Use $RESOLVED_TEMP_DIR for temporary files.` (same resolution mechanism — the orchestrator substitutes the concrete path).

- [ ] **Step 4: Verify no other `$CLAUDE_TEMP_DIR` occurrences in agent prompts remain**

Run: `grep -n 'Use \$CLAUDE_TEMP_DIR for temporary files' plugins/code-review-suite/includes/review-pipeline.md`

Expected: zero matches (the only two occurrences are now `$RESOLVED_TEMP_DIR`).

Note: other `$CLAUDE_TEMP_DIR` references in the pipeline (e.g. `$CLAUDE_TEMP_DIR/tokens.jsonl`) refer to the *orchestrator's own* temp dir usage, not the dispatched subagent prompt — those remain unchanged (the orchestrator IS the main session and CAN read the context text).

---

### Task 5: Fix A — Propagate pipeline change to synced consumers

**Files:**
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md`
- Modify: `plugins/code-review-suite/commands/pre-review.md`

- [ ] **Step 1: Copy the updated canonical body into SKILL.md**

The test `test_sync_pipeline_inline_matches_canonical` extracts the pipeline body (after the leading HTML comment) and checks verbatim match against the inlined copy in the consumers. Copy the full pipeline body from `includes/review-pipeline.md` (from `Follow these instructions exactly.` to end-of-file) into `skills/review-gh-pr/SKILL.md`, replacing the existing inlined pipeline section.

- [ ] **Step 2: Copy the updated canonical body into pre-review.md**

Same operation for `commands/pre-review.md`.

- [ ] **Step 3: Run the sync test**

Run: `tests/run.sh`

Expected: all tests pass, specifically `test_sync_pipeline_inline_matches_canonical` passes.

---

### Task 6: Fix A — Replace the false paragraph in all five static specialists

**Files:**
- Modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md:30` (the paragraph)
- Modify: `plugins/code-review-suite/agents/jbinspect-reviewer.md:44` (the paragraph)
- Modify: `plugins/code-review-suite/agents/eslint-reviewer.md:46` (the paragraph)
- Modify: `plugins/code-review-suite/agents/trivy-reviewer.md:37` (the paragraph)
- Modify: `plugins/code-review-suite/agents/ruff-reviewer.md:47` (the paragraph)

- [ ] **Step 1: Identify the false paragraph text**

The paragraph to replace is (present with minor wording variations in each file):

```
The temp-dir contract (`includes/static-analysis-context.md` §4) is satisfied by the literal `Use $CLAUDE_TEMP_DIR for temporary files.` instruction line in your prompt. That line carries the token `$CLAUDE_TEMP_DIR` **unexpanded** — the dispatcher does not substitute the resolved path into the prompt text; Bash expands it from your environment when a command actually runs. Seeing the literal `$CLAUDE_TEMP_DIR` in your prompt is expected and **does** satisfy the contract — do not treat the unexpanded token as a missing temp dir and abort. The contract is violated only if the instruction line is entirely absent.
```

The replacement text for all five specialists:

```
The temp-dir contract (`includes/static-analysis-context.md` §4) is satisfied by the `Use <path> for temporary files.` line in your prompt. The dispatcher resolves the absolute path before dispatching — you receive a concrete literal path (e.g. `/tmp/claude-5bf0f026-…/`), not an environment variable. Read the path from that line and use it directly in all Bash commands. If the line is entirely absent from your prompt, report the omission and stop.
```

- [ ] **Step 2: Replace in housekeeper-reviewer.md**

Replace the paragraph starting with `The temp-dir contract` in the "Tool invocation" section.

- [ ] **Step 3: Replace in jbinspect-reviewer.md**

Same replacement.

- [ ] **Step 4: Replace in eslint-reviewer.md**

Same replacement.

- [ ] **Step 5: Replace in trivy-reviewer.md**

Same replacement.

- [ ] **Step 6: Replace in ruff-reviewer.md**

Same replacement.

- [ ] **Step 7: Verify no false paragraph remnants remain**

Run: `grep -rl "Bash expands it from your environment" plugins/code-review-suite/agents/`

Expected: zero matches.

---

### Task 7: Fix A — Tighten the static-analysis-context.md §4 wording

**Files:**
- Modify: `plugins/code-review-suite/includes/static-analysis-context.md` (§4 block)

- [ ] **Step 1: Update §4 wording**

The current §4 text is:

```
## 4. Temp-dir contract

Require `$CLAUDE_TEMP_DIR` from the prompt (the path from `Use <path> for temporary files`). If
absent, report the omission and stop — never fall back to bare `/tmp/`. All intermediate files
written by the specialist's tool invocation live under `$CLAUDE_TEMP_DIR`.
```

Replace with:

```
## 4. Temp-dir contract

The dispatcher injects a resolved absolute path via the `Use <path> for temporary files.` line in the specialist's prompt. Read the concrete path from that line (e.g. `/tmp/claude-5bf0f026-…/`) and use it directly — it is NOT an environment variable and does not require shell expansion. If the line is absent, report the omission and stop — never fall back to bare `/tmp/`. All intermediate files written by the specialist's tool invocation live under the resolved path.
```

- [ ] **Step 2: Run tests**

Run: `tests/run.sh`

Expected: all tests pass (the sync test checks pipeline copies, not §4 wording in the include).

---

### Task 8: Fix C — Harden housekeeper-reviewer.md tool invocation commands

**Files:**
- Modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md` (Tool invocation section)

- [ ] **Step 1: Rewrite the Tool invocation section**

Replace the current "Tool invocation" section (from the replacement paragraph in Task 6 Step 2 through to the end of step 3's code block, before "The engine is the sole source of truth") with:

```
## Tool invocation

The temp-dir contract (`includes/static-analysis-context.md` §4) is satisfied by the `Use <path> for temporary files.` line in your prompt. The dispatcher resolves the absolute path before dispatching — you receive a concrete literal path (e.g. `/tmp/claude-5bf0f026-…/`), not an environment variable. Read the path from that line and use it directly in all Bash commands. If the line is entirely absent from your prompt, report the omission and stop.

Let `$TD` denote the resolved temp-dir path read from your prompt. Execute each step as a **separate, single-command Bash call** — no `&&`, no `;`, no heredocs, no multi-line command bodies.

1. Write the changed file list to `$TD/housekeeper-files.txt`:
   ```
   git diff --name-only <diff-args> > $TD/housekeeper-files.txt
   ```
   Use the diff syntax determined by `$EMPTY_TREE_MODE` (two-arg when true, three-dot when false), as resolved by the base-context procedure. **If that file ends up empty** — no base resolved, or the working tree is not a git repository — fall back to the paths named in the `Changed lines:` block of your prompt: each non-blank, non-header entry has the shape `  <path>: <lines>`, so the text before the first colon is a changed file. Write one path per line using separate `printf` calls:
   ```
   printf '%s\n' 'path/to/file1' > $TD/housekeeper-files.txt
   ```
   ```
   printf '%s\n' 'path/to/file2' >> $TD/housekeeper-files.txt
   ```
   The `Changed lines:` block is the pipeline's authoritative scope input; the engine needs this file list to scan workflows and gate npm solutions, so never run the engine against an empty list when the prompt names changed files.

2. Write the `Changed lines:` block from your prompt to `$TD/housekeeper-lines.txt`. Use separate `printf` calls — one per line of the block:
   ```
   printf '%s\n' '.github/workflows/ci.yml: 12, 15' > $TD/housekeeper-lines.txt
   ```
   ```
   printf '%s\n' 'package.json: 4' >> $TD/housekeeper-lines.txt
   ```

3. Run the engine (live registry mode — no `--registry-fixtures`):
   ```
   housekeeper-freshness --root . --changed-files-from $TD/housekeeper-files.txt --changed-lines-from $TD/housekeeper-lines.txt
   ```
   It prints a JSON array of stale-version tuples to stdout. Parse it inline.
```

- [ ] **Step 2: Verify no prohibited patterns remain in the section**

Run: `grep -n '&&\|heredoc\|<<' plugins/code-review-suite/agents/housekeeper-reviewer.md`

Expected: zero matches (the `<<` pattern should not appear in any code block).

---

### Task 9: Fix D — Add loud failure and no-fabrication rules to housekeeper-reviewer.md

**Files:**
- Modify: `plugins/code-review-suite/agents/housekeeper-reviewer.md` (add section after Tool invocation, before Output)

- [ ] **Step 1: Add a "Failure handling" section**

Insert a new section between "Tool invocation" (which ends with step 3) and "Output" (which starts with `Per includes/static-analysis-context.md §7`). Add:

```
## Failure handling

If any Bash call in the invocation sequence is **denied** (permission denied, hook rejection) or the engine exits non-zero:

- Emit a **distinct** terminal status: `FAILED — housekeeper-freshness could not be invoked (<reason>).` where `<reason>` is the specific error (e.g. `Bash permission denied`, `hook rejection: compound command`, `engine exit code 1`).
- Do NOT emit `Skipped — …` for a denied/failed invocation. The `Skipped` prefix is reserved exclusively for legitimate tool-absence scenarios: `python3 not available on PATH`, `python3 ≥3.11 required`, or `housekeeper-freshness not available on PATH`.
- Do NOT substitute a manual dependency analysis from trained knowledge under any circumstance. If the engine cannot run, the only permitted output is the FAILED status line. Fabricating dependency information violates the "engine is the sole source of truth" contract and produces misleading findings that cannot be verified.
- Stop immediately after emitting the FAILED line. Do not attempt retries, alternative approaches, or partial results.
```

- [ ] **Step 2: Verify the section is in place**

Run: `grep -c "FAILED —" plugins/code-review-suite/agents/housekeeper-reviewer.md`

Expected: at least 2 (one in the failure handling section text, one in the description).

---

### Task 10: Fix D — Surface specialist FAILED status in the synthesiser

**Files:**
- Modify: `plugins/code-review-suite/agents/review-synthesiser.md` (Rules section)

- [ ] **Step 1: Add a rule about FAILED specialist state**

In `agents/review-synthesiser.md`, in the `## Rules` section (after the last `-` bullet, currently line 381), add:

```
- **Specialist FAILED state:** If any specialist's report is a `FAILED — …` status line (as
  opposed to a legitimate `Skipped — …` or normal findings), surface it in the Synthesiser
  Assessment section as a one-line note: `**Note:** <specialist-name> reported FAILED —
  <reason>. Findings from this domain are absent.` Do NOT silently omit a failed specialist
  from the report — the reader must know that a domain was not covered. A `Skipped — …` status
  (tool legitimately absent) need not be surfaced as a failure.
```

- [ ] **Step 2: Verify the rule is in place**

Run: `grep -c "Specialist FAILED state" plugins/code-review-suite/agents/review-synthesiser.md`

Expected: 1.

---

### Task 11: Fix B doc side — Add host-side prerequisite note to README

**Files:**
- Modify: `plugins/code-review-suite/README.md:110` (after the python3 prerequisite)

- [ ] **Step 1: Add a note about background subagent authorisation**

After the `python3` prerequisite line (line 110), add:

```
- **Background subagent dispatch:** When the housekeeper runs as a dispatched background subagent (the normal mode in `review-gh-pr`), the host machine must pre-authorise the `housekeeper-freshness` command in `hooks/allow-permissions.sh` and `permissions.allow` (pattern: `Bash(housekeeper-freshness:*)`). Without this, the subagent auto-denies the engine call. The same pattern applies to `ruff`, `trivy`, `eslint`, and `jb` — all static-analysis engine binaries require host-side permission for background dispatch.
```

- [ ] **Step 2: Verify**

Run: `grep "Background subagent dispatch" plugins/code-review-suite/README.md`

Expected: one match.

---

### Task 12: Run full test suite and commit PR 2

**Files:**
- All modified files in the plugin repo

- [ ] **Step 1: Run the full test suite**

Run: `tests/run.sh`

Expected: all tests pass. The sync test confirms the three pipeline copies match.

- [ ] **Step 2: Stage all changed files**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md \
       plugins/code-review-suite/skills/review-gh-pr/SKILL.md \
       plugins/code-review-suite/commands/pre-review.md \
       plugins/code-review-suite/includes/static-analysis-context.md \
       plugins/code-review-suite/agents/housekeeper-reviewer.md \
       plugins/code-review-suite/agents/jbinspect-reviewer.md \
       plugins/code-review-suite/agents/eslint-reviewer.md \
       plugins/code-review-suite/agents/trivy-reviewer.md \
       plugins/code-review-suite/agents/ruff-reviewer.md \
       plugins/code-review-suite/agents/review-synthesiser.md \
       plugins/code-review-suite/README.md
```

- [ ] **Step 3: Commit**

```bash
git commit -m "fix(housekeeper): resolve subagent Bash failures (A+C+D)

Fix A: pipeline now injects the resolved /tmp/claude-<id>/ path into
subagent prompts (was literal unexpanded \$CLAUDE_TEMP_DIR). Corrects
the false 'Bash expands it' paragraph in all five static specialists.

Fix C: harden housekeeper-reviewer tool invocation to single-command
Bash calls (no &&, no heredocs) — compatible with bash-guard.sh hook.

Fix D: add loud FAILED status (distinct from Skipped) and explicit
no-fabrication rule. Synthesiser now surfaces FAILED specialists.

Root cause verified from two failing review transcripts (67ec783b,
7ac503dd). See docs/superpowers/specs/2026-06-12-housekeeper-subagent-
bash-failure-design.md for the full investigation."
```

- [ ] **Step 4: Push**

Run: `git push`

---

## Validation (post-implementation)

These are out-of-band checks the user runs after both PRs land:

1. **Re-run the failing scenario:** dispatch `housekeeper-reviewer` via `review-gh-pr` against a repo with stale deps. Confirm the engine runs, emits findings, and the synthesiser includes them.
2. **Negative path:** temporarily remove `housekeeper-freshness` from the allowlist and confirm the agent emits `FAILED — … Bash permission denied` (not `Skipped`).
3. **No-fabrication:** confirm no manual dependency list appears when the engine cannot run.
4. **Regression:** confirm the four other static specialists still resolve their temp dir correctly.
