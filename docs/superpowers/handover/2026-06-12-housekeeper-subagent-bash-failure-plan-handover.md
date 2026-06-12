# Handover — turn the housekeeper subagent Bash-failure spec into a plan, then implement

**Date:** 2026-06-12
**Repos:** spans **two** repos — read carefully.
- Plugin fixes (A, C, D): `~/.claude/plugins/marketplaces/jodre11-plugins` (the
  personal plugin marketplace — independently versioned, own CI/CLAUDE.md/test
  suite; push to its own `origin`, NOT `claude-settings`). House rule:
  direct-push to `main`, push immediately after each commit.
- Permission/template fix (B): `~/.claude` (`claude-settings`) plus the public
  upstream seed `~/Repos/claude-settings-template/`. A plugin CANNOT grant itself
  host Bash permission, so B must land in settings, not the marketplace.

---

## 1. Where we are

The investigation is **done and the design is approved**. The previous session
verified root cause from two real review transcripts, ran the four-option fix
menu past the user (all four recommendations accepted), wrote the spec, and
committed it:

- **Spec:** `docs/superpowers/specs/2026-06-12-housekeeper-subagent-bash-failure-design.md`
  (commit `b72ef56` on the plugin repo's `main`). **Read it in full first** — it
  is the source of truth and contains the verified root cause, the four fixes,
  the affected-file list, and the validation plan.
- The prior **investigation handover** (still useful for the raw transcript
  evidence and record indices) is
  `docs/superpowers/handover/2026-06-12-housekeeper-subagent-bash-failure-investigation-handover.md`.

**Status check before doing anything:** confirm `b72ef56` is pushed
(`git -C ~/.claude/plugins/marketplaces/jodre11-plugins log --oneline -3`). The
previous session committed but may not have pushed. If unpushed, push it — never
leave unpushed work in this dir (see [[project_marketplace_autoupdate_wiped_branch]]).

---

## 2. First action (mandatory)

The design is signed off, so **skip brainstorming**. Invoke
**`superpowers:writing-plans`** to turn the approved spec into an implementation
plan. Then execute via **`superpowers:subagent-driven-development`** (the user's
standard execution mode for this programme — fresh implementer per task + the
two-stage review: spec-compliance then code-quality).

Do NOT start editing files before the plan exists and the user has had a chance
to review it.

---

## 3. The four fixes (summary — the spec has full detail)

Verified root cause: **A** and **B** are the two independent roots; **C** is an
accelerant; **D** makes the result invisible.

- **Fix A — pipeline injects the *resolved* temp-dir path (root; all specialists).**
  The pipeline emits the literal unexpanded line `Use $CLAUDE_TEMP_DIR for
  temporary files.`; the SessionStart hook never exports the var (verified:
  `printenv CLAUDE_TEMP_DIR` exits 1 even in the main session — it is injected as
  context text only). So a subagent's `> $CLAUDE_TEMP_DIR/…` redirect expands to
  `> /…` and hits a read-only filesystem. The orchestrator must substitute the
  concrete `/tmp/claude-<session-id>/` path into `$AGENT_PROMPT`. Edit
  `includes/review-pipeline.md` Step 2.9 **and the two synced consumers**
  (`skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`) in lockstep — the
  test suite checks they match. Also correct the **false** "Bash expands it /
  unexpanded token is expected — do not abort" paragraph, which is present in
  **all five** static specialists (`housekeeper-reviewer.md`,
  `jbinspect-reviewer.md`, `eslint-reviewer.md`, `trivy-reviewer.md`,
  `ruff-reviewer.md`) and in the §4 wording of
  `includes/static-analysis-context.md`. Housekeeper manifests this bug because
  it has NO `Write` tool and its engine reads inputs from files — it is the only
  specialist forced to pre-write a temp file via Bash.

- **Fix B — allowlist `housekeeper-freshness` (root; housekeeper-specific) —
  `claude-settings` + template.** `~/.claude/hooks/allow-permissions.sh`
  auto-approves subagent Bash by base command and already covers
  `ruff|nbqa|trivy|eslint|biome|jb|python3|git` — but NOT `housekeeper-freshness`,
  so a background subagent auto-denies the engine call. Add it to
  `allow-permissions.sh` and add `Bash(housekeeper-freshness *)` to
  `permissions.allow`. **Edit the `.tmpl` and re-hydrate — never edit
  `settings.json` directly** (see [[feedback_settings_template_workflow]]).
  Propagate the mechanism to the public template repo
  (`~/Repos/claude-settings-template/`) — it is a generic mechanism change, so
  per the CRITICAL VOCABULARY rule in `~/.claude/CLAUDE.md` it belongs in BOTH
  the local `.tmpl` and the template repo. Document the host-side prerequisite in
  the code-review-suite `README.md`.

- **Fix C — harden the agent's own commands (accelerant) — plugin only.**
  Rewrite `housekeeper-reviewer.md` "Tool invocation" so every command is a
  single hook-safe Bash call: no `&&`, no `;`, no heredoc. Use single
  redirections and `printf '%s\n' …` writes (which already succeed in the
  transcripts) instead of `git diff … && cat` and `cat > f << EOF`.

- **Fix D — loud failure + ban fabrication (observability) — plugin only.**
  `housekeeper-reviewer.md`: on Bash-denied/exhausted, emit a **distinct**
  `FAILED — …` status (NOT `Skipped — …`, which is reserved for legitimate
  python3/PATH-absent skips), and explicitly forbid the manual-knowledge
  dependency fallback (it violates "engine is the sole source of truth"). The
  failing transcript fabricated a manual dep list and emitted `Skipped`.
  `review-synthesiser.md`: surface a specialist `FAILED` state visibly instead of
  silently omitting it (the synthesiser dropped the housekeeper entirely — 0
  mentions in `agent-a490f09578bd7f89f.jsonl`).

---

## 4. PR sequencing (user's housekeeping convention)

The user prefers housekeeping/enabling changes to land **separately and first**.
B is the single fix that actually unblocks the engine and lives in a different
repo, so:

- **PR 1 (lands first) — `claude-settings` + template:** Fix B (allowlist +
  hydrate + template propagation). This is a settings repo change; follow the
  `.tmpl` → `hydrate.sh` → `setup-platform.sh` workflow.
- **PR 2 (plugin) — `jodre11-plugins`:** Fixes A, C, D together (they are all
  agent/pipeline prose edits in the code-review-suite plugin) + test updates.

Confirm this split with the user during planning — they may want A's "all five
specialists" wording fix and the test work scoped as its own commit within PR 2.

---

## 5. Things to get right (cheap to miss)

1. **Synced-copy lockstep (Fix A).** `includes/review-pipeline.md` is the
   canonical source; its content is **inlined verbatim** into
   `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`. The test suite
   verifies they match. Edit canonical first, propagate to both, run
   `tests/run.sh`.
2. **`.tmpl`, not `settings.json` (Fix B).** Editing the hydrated
   `settings.json` directly will be overwritten. Edit `settings.json.tmpl`, run
   `hydrate.sh`, then `setup-platform.sh`. Mirror to the template repo.
3. **Two distinct repos, two pushes (Fix B).** `~/.claude` and
   `~/Repos/claude-settings-template/` are separate git repos with separate
   `origin` remotes. Don't conflate "the .tmpl file" (a hydration source in any
   repo) with "the template repo" (the public seed). If genuinely ambiguous, ASK.
4. **Don't widen scope.** The hook-exemption option (exempting subagents from
   `bash-guard.sh` globally) was deliberately **deferred**, not chosen — see spec
   §4. Do not implement it. The Go modules feature slice is separate future work.
5. **Validation (spec §6).** The real proof is re-running the failing scenario:
   dispatch the housekeeper as a background subagent in a real review against a
   repo with stale deps, confirm the engine runs and the synthesiser includes the
   findings. Plus the negative path (permission-denied → FAILED, not Skipped) and
   the no-fabrication check.

---

## 6. Evidence locations (if you need to re-verify)

- Failing housekeeper subagent transcripts:
  - `~/.claude/projects/-Users-jodre11-Repos-haven-finance-erp/67ec783b-4951-4676-a0ac-e17c4f643647/subagents/agent-a7f35b45ffb3fecce.jsonl` (70 records; engine denied at [35],[38]; empty-token redirect at [16]; hook denial at [13])
  - `~/.claude/projects/-Users-jodre11-Repos-haven-finance-erp/7ac503dd-4d60-4c59-9898-4068a80a1785/subagents/agent-ae9b69009e40aff2e.jsonl` (28 records; same pattern)
  - synthesiser (0 housekeeper mentions): `…/67ec783b…/subagents/agent-a490f09578bd7f89f.jsonl`
- Hooks: `~/.claude/hooks/allow-permissions.sh` (the allowlist — Fix B target),
  `~/.claude/hooks/bash-guard.sh` (the accelerant — Fix C context),
  `~/.claude/hooks/session-init.sh` (proves the var is context-text-only — Fix A).
- A reusable transcript parser was written to a prior session's temp dir and is
  gone; rewrite it if needed (~30 lines: load jsonl, walk `message.content`
  blocks, print `tool_use` where `name=="Bash"` and `tool_result` where
  `is_error` or text contains permission/denied/violation/read-only). **Note:**
  inline `python3 -c "…"` with newlines is itself denied by `bash-guard.sh` (you
  will hit the very bug under investigation) — write the parser to a file with
  the `Write` tool and run `python3 <file>`.

---

## 7. Relevant memories

[[project_code_review_suite_backlog]], [[project_housekeeper_specialist_slice4]],
[[feedback_settings_template_workflow]], [[feedback_claudemd_compliance]],
[[project_marketplace_autoupdate_wiped_branch]],
[[feedback_plugins_update_after_push]],
[[project_security_reviewer_live_data]].
