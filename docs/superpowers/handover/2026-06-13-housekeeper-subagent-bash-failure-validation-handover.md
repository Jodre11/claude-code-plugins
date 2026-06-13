# Handover — validate the shipped housekeeper subagent Bash-failure fix (spec §6)

**Date:** 2026-06-13
**Stage:** implementation is DONE and pushed. Your job is the **out-of-band
validation** the spec marked user-run (§6) — confirm the fix actually works in a
real dispatched-subagent review. This is verification, NOT implementation. Do not
re-open the fix unless validation finds a defect.

---

## 1. Outer context — what this is and why it matters

The `housekeeper-reviewer` is one of several static-analysis specialists in the
`code-review-suite` plugin. When the full review pipeline (`review-gh-pr` /
`pre-review`) dispatches it **as a background subagent**, its Bash calls were
failing and the `housekeeper-freshness` engine never ran. The specialist then
emitted a silent `Skipped — …`, fabricated a manual dependency analysis from
trained knowledge (which its own contract forbids), and the synthesiser dropped
the freshness view from the final report. A 2-PR remediation just shipped to fix
this at the roots and make any residual failure loud.

**This validation is the last open item from that work.** It gates nothing you
*must* do, but it closes the loop before the next project (the Workflow migration —
see §5) builds on the review pipeline.

---

## 2. What shipped (already pushed — do not redo)

**PR 1 — permission unblock (`claude-settings` + public template):**
- `~/.claude` commit `8ee1e0d` and `~/Repos/claude-settings-template/` commit
  `02e5db7`: allowlisted the `housekeeper-freshness` engine binary in
  `hooks/allow-permissions.sh` (static-analysis case arm) and added
  `Bash(housekeeper-freshness:*)` to `permissions.allow` via `settings.json.tmpl`
  → `hydrate.sh`. Dispatched subagents inherit hooks but NOT `permissions.allow`
  (Claude Code issue #18950), so the allowlist is what auto-approves the engine
  call in a background subagent.
- NOTE: `~/.claude/settings.json` is `skip-worktree` (per-machine hydration
  artifact) — it was correctly NOT committed; only the `.tmpl` source ships. The
  live hydrated file on THIS machine already contains the permission.

**PR 2 — the plugin fix (`jodre11-plugins` commit `de212fe`, docs `5551b4d`):**
- **Fix A:** the pipeline orchestrator now substitutes the *resolved*
  `/tmp/claude-<session-id>/` path into the dispatched prompt via
  `$RESOLVED_TEMP_DIR` (was the literal, never-expanded `$CLAUDE_TEMP_DIR` token —
  the SessionStart hook only injects that as orchestrator *context text*, never an
  env var, so subagents got an empty path and writes failed at `/`). The false
  "Bash expands it from your environment" paragraph was corrected in all five
  static specialists; the canonical `includes/review-pipeline.md` change was
  propagated byte-for-byte to the two inlined consumers
  (`skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`); the shared
  `includes/static-analysis-context.md` temp-dir contract (§3/§4/§9) was updated.
- **Fix C:** `agents/housekeeper-reviewer.md`'s Tool invocation section was
  rewritten so every Bash command is a single hook-safe call (no `&&`, `;`, or
  heredoc — uses `printf … >`/`>>`), compatible with the global `bash-guard.sh`
  hook that fires inside subagents. Temp-dir refs use a `<TEMP_DIR>` angle-bracket
  placeholder (deliberately NOT a `$`-prefixed token) with an explicit
  "substitute the literal path, never emit a variable" instruction — because the
  plan's original `$TD` placeholder would have recreated the very bug being fixed
  (shell state does not persist between separate Bash tool calls).
- **Fix D:** the housekeeper now emits a distinct `FAILED — …` status (separate
  from the legitimate tool-absence `Skipped — …`), bans trained-knowledge
  fabrication outright, and the synthesiser (`agents/review-synthesiser.md`)
  surfaces a FAILED specialist instead of silently dropping it.

Full test suite is green on the clean committed tree (399 passed, 0 failed,
1 skipped — the skip is the `CLAUDE_CODE_E2E_TESTS=1`-gated smoke).

The verified root cause and full reasoning are in the spec:
`docs/superpowers/specs/2026-06-12-housekeeper-subagent-bash-failure-design.md`
(see §2 "Verified root cause" and §6 "Validation").

---

## 3. First action (mandatory) — refresh the plugin registry

The fix is **pushed but the in-session plugin registry may be stale**. Before
validating, make the running session use the on-disk fix:

1. `/plugins update` — refreshes the on-disk plugin cache from GitHub.
2. `/reload-plugins` — reloads the in-memory registry from current disk.

(Or just start a fresh session, which loads current disk.) If you skip this, you
may validate the OLD agent definition and get a misleading result. See memory
[[project_plugin_cache_staleness]] and [[feedback_plugins_update_after_push]].

Sanity check before running anything heavy: confirm the live agent file has the
fix — `grep -c '<TEMP_DIR>' <plugin-cache>/agents/housekeeper-reviewer.md` should
be ≥ 8, and `grep -c 'CLAUDE_TEMP_DIR' …` on the same file should be 0.

---

## 4. The validation (spec §6 — four checks)

Run the housekeeper **as a dispatched background subagent inside a real review**,
not standalone in the main session (the bug only manifested under background
dispatch). The cleanest trigger is a `review-gh-pr` (or `pre-review`) on a repo
with **stale dependencies** so the engine has something to find — e.g. an old
`actions/checkout@v3` in a workflow, an outdated `package.json`/`Directory.Packages.props`
entry, or a behind-GA Docker base image.

1. **Happy path:** the engine runs, emits stale-version findings, AND the
   synthesiser's final report INCLUDES the housekeeper/freshness findings (the
   original failure was the synthesiser containing ZERO "housekeeper" mentions).
2. **Negative path (permission denied → FAILED, not Skipped):** temporarily make
   the engine un-invokable (e.g. remove `housekeeper-freshness` from
   `~/.claude/hooks/allow-permissions.sh` for one run) and confirm the agent emits
   `FAILED — housekeeper-freshness could not be invoked (…)` — NOT a `Skipped — …`
   line. RESTORE the allowlist entry afterwards.
3. **No-fabrication:** confirm that when the engine cannot run, the agent emits
   ONLY the FAILED line — no manual dependency list from trained knowledge.
4. **Regression:** confirm the four OTHER static specialists (ruff, eslint, trivy,
   jbinspect) still resolve their temp dir correctly under the new resolved-path
   wording (a quick review on a repo touching JS/Py/IaC/C# exercises them).

If all four pass: the fix is validated — record the result (a short memory update
on [[project_housekeeper_specialist_slice4]] or a new note) and the work is fully
closed. If any fail: capture the failing subagent transcript path and treat it as
a new debugging task against the shipped fix (do NOT silently patch — diagnose
first, per [[superpowers:systematic-debugging]]).

---

## 5. What comes after (do NOT start here — context only)

The next real project is the **code-review orchestrator → Workflow migration**,
scoped in memory [[project_orchestrator_workflow_migration]]. It is now unblocked
(its gating condition — "wait for Phase 3 static-specialist tuning to land" — is
satisfied). It is ALSO the prerequisite for a deferred idea: running the review
suite as a required PR check (a Workflow is a headless, loopable harness, which
dissolves the "interactive orchestrator can't run in CI" blocker). Both are
deferred until after this validation; start the migration via
`superpowers:brainstorming` when ready.

Process note for the next push: branch protection is now ACTIVE on both public
repos; prefer opening a PR over an admin-bypass direct push
([[feedback_prefer_prs_over_direct_push]], [[project_branch_protection_active]]).
The private `~/.claude` repo has no protection — direct commits there are fine.

---

## 6. Relevant memories

[[project_housekeeper_specialist_slice4]], [[project_code_review_suite_backlog]],
[[feedback_settings_template_workflow]], [[feedback_claudemd_compliance]],
[[project_plugin_cache_staleness]], [[feedback_plugins_update_after_push]],
[[feedback_housekeeper_diff_is_selector_not_filter]],
[[project_orchestrator_workflow_migration]],
[[feedback_prefer_prs_over_direct_push]], [[project_branch_protection_active]].
