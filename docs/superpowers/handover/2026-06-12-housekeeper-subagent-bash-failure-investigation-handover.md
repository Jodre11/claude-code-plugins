# Handover — investigate the housekeeper subagent Bash-failure (then propose, don't fix yet)

**Date:** 2026-06-12
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (the personal plugin
marketplace — independently versioned; own CI/CLAUDE.md/test suite; push to its
own `origin`, NOT `claude-settings`).
**Mode the user wants:** **investigate → brainstorm → propose first.** Do NOT edit
the plugin or settings yet. Produce a written root-cause + remediation proposal
(brainstorm, then a spec/plan) for the user to approve. The blast radius is live
reviews in other repos, so the bar is "agree the fix shape before touching files."

---

## 1. The problem (user's words, then decoded)

When `housekeeper-reviewer` runs **as a dispatched subagent** in a real review
(the `code-review` / `review-gh-pr` pipeline), its **Bash calls get denied /
exhausted, so the engine never runs and the specialist's findings are never
produced**. The user has to notice this manually and re-run the housekeeper inside
the orchestrator/main session — defeating the point of the specialist. A
downstream consequence: the housekeeper's freshness findings are missing from the
synthesiser's final cross-check that should sit alongside the **security-reviewer**
output (the user called this "the cross-hash view by the security viewer" — read
it as: the freshness cross-check next to the security view went missing because
the housekeeper skipped). **Confirm this synthesiser-consequence reading during
the investigation — it was inferred, not verified.**

---

## 2. What I already found (transcript evidence — this is solid, verified)

I grepped/parsed the real review transcripts. The evidence lives in:

- **Session 1:** `~/.claude/projects/-Users-jodre11-Repos-haven-finance-erp/67ec783b-4951-4676-a0ac-e17c4f643647/subagents/agent-a7f35b45ffb3fecce.jsonl` (the housekeeper subagent; 70 records)
- **Session 2:** `~/.claude/projects/-Users-jodre11-Repos-haven-finance-erp/7ac503dd-4d60-4c59-9898-4068a80a1785/subagents/agent-ae9b69009e40aff2e.jsonl` (28 records)
- Parser I used (reusable): `/tmp/claude-<session>/parse_hk.py` — walks a `.jsonl`
  transcript, prints every `Bash` tool_use command + every error/permission/denial
  tool_result. **Rewrite it fresh** (it was in this session's temp dir, now gone).
  It's ~25 lines: load jsonl, iterate `message.content` blocks, print `tool_use`
  where `name=="Bash"` and `tool_result` where `is_error` or text contains
  permission/safety/denied/unavailable.

**Root cause is NOT the Bedrock auto-mode classifier outage** I first hypothesised.
It is **Bash-permission exhaustion, with the user's own CLAUDE.md Bash-rules hook
as a major accelerant, plus an unset `$CLAUDE_TEMP_DIR` in the subagent.** Three
compounding failures, all observed in the transcripts:

1. **The global CLAUDE.md Bash-rules hook fires INSIDE the dispatched subagent**
   and rejects the housekeeper's own documented commands:
   - Session 1 record [12]: `git diff --name-only main...HEAD > $CLAUDE_TEMP_DIR/housekeeper-files.txt && cat …`
     → blocked: `CLAUDE.md VIOLATION (Bash rules): compound operator '&&' detected`.
   - Session 2 records [7],[9],[20]: `cat > "$CLAUDE_TEMP_DIR/…" << 'EOF'` heredocs
     → blocked: `CLAUDE.md VIOLATION (Bash rules): newline command separator detected`.
   Each rejection burns a turn and pushes the agent into more retries.

2. **`$CLAUDE_TEMP_DIR` is empty/unset in the subagent.** Session 2 record [13]:
   `printf … > "$CLAUDE_TEMP_DIR/housekeeper-files.txt"` →
   `(eval):1: read-only file system: /housekeeper-files.txt` — i.e. the var
   expanded to empty so the redirect target became `/housekeeper-files.txt`. The
   agent doc (`housekeeper-reviewer.md` §"Tool invocation") even has a paragraph
   insisting the literal `$CLAUDE_TEMP_DIR` token is fine and "Bash expands it from
   your environment" — but in the dispatched subagent it demonstrably does NOT
   expand. This is arguably the deepest bug and is not cleanly covered by the
   obvious fixes.

3. **Bash permission is denied/exhausted for the subagent.** Once the scaffolding
   commands above have churned, the actual engine call gets
   `Permission to use Bash has been denied…`:
   - Session 1 records [34],[37]: `housekeeper-freshness --root . --changed-files-from … --changed-lines-from …` → denied, retried → denied again.
   - Session 2 record [25]: same engine call → denied.
   The agent then emitted (verbatim, session 1):
   *"Skipped — housekeeper-freshness engine could not execute… the temporary input
   files were successfully prepared… but Bash execution permissions were exhausted
   before the engine invocation could complete. To proceed, please retry this
   analysis in a new session or with restored Bash permissions."*

**Scope check I ran:** in session 1, of all subagents only the housekeeper hit
`Bash has been denied` (`grep -c "Bash has been denied" …/subagents/*.jsonl`
→ only `agent-a7f35b45…:4`). security-reviewer and the read-only specialists ran
clean. This is **housekeeper-specific because it is the only specialist that must
shell out** to a binary; the others are Read/Grep/Glob-driven.

---

## 3. Why it matters / the shape of the bug

The housekeeper is the one specialist whose entire value is a Bash invocation of
`housekeeper-freshness`. Three things conspire so that in a dispatched-subagent
context the one command that matters never runs:
- the hook eats turns rejecting hook-illegal scaffolding the agent itself emits,
- the temp-dir redirect target is invalid because the env var is empty,
- and Bash permission is denied/exhausted by the time the engine call is reached.

A silent `Skipped — …` then makes it look like "nothing stale" rather than
"specialist failed," so the gap is easy to miss in the synthesised report.

---

## 4. The four candidate fixes the user has SEEN (pre-selected 3 of 4)

I offered these via AskUserQuestion. The user **pre-selected the first three** and
explicitly left out the hook-exemption one — but then chose to clarify rather than
finalise, so treat these as the live design menu to evaluate in the brainstorm,
NOT as settled decisions:

- **(SELECTED) Pre-authorise the engine command** — add a permission allowlist
  entry so `housekeeper-freshness …` (and the `git diff` / file-write commands it
  needs) never trigger a permission prompt the subagent can't answer. NB: think
  about WHERE — project `.claude/settings.json` in the marketplace repo? the
  consuming repo? the plugin's own declared permissions? A plugin can't grant
  itself host Bash permission silently — investigate how a plugin-shipped agent is
  supposed to get a pre-authorised command on an end-user machine.
- **(SELECTED) Harden the agent's own commands** — rewrite the
  `housekeeper-reviewer.md` "Tool invocation" steps to be hook-safe (no `&&`, no
  heredoc — use separate calls / `printf` without compound operators) AND robust to
  an unset `$CLAUDE_TEMP_DIR` (fail fast with a clear message, or fall back to a
  computed temp path). This stops the agent generating commands that get blocked.
- **(SELECTED) Make skip loud, not silent** — a Bash-denied/exhausted state should
  emit a clearly-flagged FAILED/ERROR status the synthesiser surfaces, distinct
  from the legitimate `Skipped — python3 not available`. Today both look like
  "Skipped".
- **(NOT selected, but RAISE it again)** **Exempt subagent Bash from the hook** —
  stop the global CLAUDE.md Bash-rules hook firing inside dispatched review
  subagents. The user left this out; my view is it deserves re-litigating, because
  if the hook stays active in subagents then *every* plugin agent must forever
  write hook-safe Bash, and the hook is a `claude-settings`/`dotfiles`-level
  concern, not a plugin concern. **Surface the tradeoff explicitly; let the user
  decide.** (Note the CRITICAL VOCABULARY in `~/.claude/CLAUDE.md`: the hook lives
  in the settings repo, and a generic mechanism change may belong in the public
  template too — do not conflate "the .tmpl file" with "the template repo".)

The user did NOT answer the scope question; they then said: **investigate &
propose first, in a clean session, using this handover.** So: scope = propose.

---

## 5. Open questions to resolve DURING the investigation (don't assume)

1. **Why is `$CLAUDE_TEMP_DIR` empty in the dispatched subagent** when it's present
   in the main session? Is it injected only by the SessionStart hook into the
   top-level env and not inherited by subagent Bash? Is the per-agent harness
   (which scrubs subprocess env — see the A/B notes) related, or is this the
   *interactive* review path, not the harness? The two failing transcripts are
   under `…-Repos-haven-finance-erp/…` (real interactive reviews), NOT under
   `…per-agent-2026…` (A/B trials) — so this is the live pipeline, env-scrub is a
   red herring here. Pin down the real reason the var is empty.
2. **Where does the permission denial originate** — an interactive prompt the
   subagent can't answer (so it auto-denies), a `deny` rule, or genuine
   budget/quota exhaustion after N prompts? The tool_result text is the generic
   "Permission to use Bash has been denied…". Determine the mechanism before
   choosing between "pre-authorise" vs "exempt hook" vs "harden commands".
3. **Does the synthesiser actually drop/mis-handle a housekeeper skip** (the
   "cross-hash with security-reviewer" consequence)? Verify against the session-1
   main transcript (`…/67ec783b-….jsonl`) and the synthesiser subagent, rather
   than inferring.
4. **How are the OTHER Bash-using specialists configured** that they DON'T hit
   this? (ruff/eslint/trivy/jbinspect all shell out in the per-agent harness.) Is
   it that they only run under the harness with pre-authorised commands, while the
   housekeeper is the only one dispatched into interactive reviews needing live
   Bash? Compare their agent defs + any permission declarations. This likely points
   straight at the correct fix.

---

## 6. Deliverable for the clean session

1. Use **`superpowers:brainstorming`** to explore the root cause + fix menu (§4)
   with the user — do NOT jump to code. Resolve the §5 questions with real
   transcript/codebase evidence first.
2. Then produce a short **spec** (and, if the user approves, a plan) under
   `docs/superpowers/specs/` describing the chosen remediation. Mirror the existing
   housekeeper spec/plan style in that dir.
3. **Do not edit `housekeeper-reviewer.md`, settings.json, or any hook** until the
   user approves the proposal. This is explicitly an investigate-and-propose task.

---

## 7. Context: what was JUST completed (so you don't re-do it)

The **housekeeper PyPI slice (vertical slice 4)** shipped to `main` earlier today
(commits `e6e7489`..`7a5c41e`), executed via subagent-driven-development, A/B
EQUIVALENT 20/20. That work is DONE and pushed. Memory updated in `~/.claude`
(`project_housekeeper_specialist_slice4`). The **next planned feature slice is Go
modules** — but that is NOT this task and must not be started without the user.

THIS task is a separate, newly-raised **bug investigation** into the
dispatched-subagent Bash failure, which the user wants understood and proposed
before any more feature work.

Relevant files for the investigation:
- Agent def: `plugins/code-review-suite/agents/housekeeper-reviewer.md`
  (§"Tool resolution" lines ~24-26, §"Tool invocation" lines ~28-44 — the Bash
  steps and the `$CLAUDE_TEMP_DIR`-expands-fine paragraph that is contradicted by
  the evidence).
- Pipeline/synthesiser: `plugins/code-review-suite/includes/review-pipeline.md`,
  `plugins/code-review-suite/agents/review-synthesiser.md`, and the three synced
  trigger files.
- The user's CLAUDE.md Bash-rules hook: defined in the `claude-settings` repo
  (`~/.claude`) — find it via the hooks config in `~/.claude/settings.json` /
  `.tmpl`. It is the thing emitting `CLAUDE.md VIOLATION (Bash rules): …`.
- Failing transcripts: the two `.jsonl` paths in §2.

Relevant memories (in `~/.claude`): `project_plugin_cache_staleness`,
`feedback_plugins_update_after_push`, `project_code_review_suite_backlog`,
`project_housekeeper_specialist_slice4`, and the security-reviewer live-data one
(`project_security_reviewer_live_data`).
