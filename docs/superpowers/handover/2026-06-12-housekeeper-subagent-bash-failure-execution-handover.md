# Handover — execute the housekeeper subagent Bash-failure plan

**Date:** 2026-06-12
**Stage:** the spec is approved AND the implementation plan is written. Your job
is to **execute the plan** — no brainstorming, no re-planning.

**Repos:** spans **two** repos.
- Plugin fixes (A, C, D): `~/.claude/plugins/marketplaces/jodre11-plugins` (the
  personal plugin marketplace — independently versioned, own CI/CLAUDE.md/test
  suite; push to its own `origin`, NOT `claude-settings`). House rule:
  direct-push to `main`, push immediately after each commit.
- Permission/template fix (B): `~/.claude` (`claude-settings`) plus the public
  upstream seed `~/Repos/claude-settings-template/`. Two distinct git repos, two
  distinct `origin` remotes, two pushes.

---

## 1. Read these first (in order)

1. **The plan (your task list):**
   `docs/superpowers/plans/2026-06-12-housekeeper-subagent-bash-failure.md`.
   It has 12 tasks across two PRs, each with exact file paths, exact before/after
   text, and verification commands. Execute it task-by-task.
2. **The spec (source of truth for *why*):**
   `docs/superpowers/specs/2026-06-12-housekeeper-subagent-bash-failure-design.md`.
   Read it to understand the verified root cause before touching files — the plan
   is the *how*, the spec is the *why*.
3. The earlier investigation + plan handovers in the same `handover/` dir carry
   the raw transcript evidence if you need to re-verify a claim.

---

## 2. First action (mandatory)

**Status check before anything:** confirm the working tree is clean and the spec
+ plan commits are pushed:

```
git -C ~/.claude/plugins/marketplaces/jodre11-plugins status -sb
git -C ~/.claude/plugins/marketplaces/jodre11-plugins log --oneline -3
```

Expect `## main...origin/main` (no ahead/behind) and the plan commit at HEAD.
Never leave unpushed work in this dir (see
[[project_marketplace_autoupdate_wiped_branch]]).

Then invoke **`superpowers:subagent-driven-development`** — the user's standard
execution mode for this programme: a fresh implementer subagent per task, then the
two-stage review (spec-compliance, then code-quality) between tasks. Do NOT batch
all 12 tasks into one subagent.

When dispatching subagents: set `mode: "auto"` and a unique kebab-case `name`
(per `~/.claude/CLAUDE.md` Agents rules), and pass the resolved
`CLAUDE_TEMP_DIR` value (`/tmp/claude-<this-session-id>/`) in the prompt.

---

## 3. PR sequencing (confirmed with the user)

- **PR 1 (lands first) — `claude-settings` + template:** Fix B = plan Tasks 1–3.
  The allowlist + settings change is the single fix that actually unblocks the
  engine, lives in a different repo, and is the natural "housekeeping-first"
  change per the user's convention. Follow the `.tmpl` → `hydrate.sh` →
  (settings.json regenerated) workflow — **never edit `settings.json` directly**
  (see [[feedback_settings_template_workflow]]). Mirror to the template repo.
- **PR 2 (plugin) — `jodre11-plugins`:** Fixes A, C, D = plan Tasks 4–12, one
  commit. (The user was asked whether to split Fix A's five-specialist wording
  edit into its own commit — **confirm their answer before committing Task 12**;
  the plan currently bundles A+C+D as a single commit.)

Because direct-push-to-main is the house rule here, "PR" means "commit + push to
`main`". There is no GitHub PR branch unless the user asks for one.

---

## 4. The four fixes (one-line each — plan has full detail)

- **A (root, all specialists):** pipeline injects the *resolved*
  `/tmp/claude-<id>/` path into subagent prompts instead of the literal
  `$CLAUDE_TEMP_DIR` token (which never expands — the SessionStart hook only
  injects it as context text, never exports it). Edit canonical
  `includes/review-pipeline.md` first, propagate verbatim to the two synced
  consumers (`skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`), fix the
  false "Bash expands it" paragraph in all five static specialists, tighten
  `includes/static-analysis-context.md` §4.
- **B (root, housekeeper-specific):** allowlist `housekeeper-freshness` in
  `allow-permissions.sh` + `Bash(housekeeper-freshness:*)` in `permissions.allow`.
- **C (accelerant):** harden housekeeper's own Bash to single hook-safe commands
  (no `&&`, no `;`, no heredoc — use `printf … >`/`>>`).
- **D (observability):** loud `FAILED — …` status (distinct from legitimate
  `Skipped — …`), ban the trained-knowledge fabrication, and make the synthesiser
  surface a FAILED specialist instead of dropping it.

---

## 5. Things to get right (cheap to miss)

1. **Synced-copy lockstep (Fix A / Tasks 4–5).** `includes/review-pipeline.md` is
   canonical; its body is inlined verbatim into the two consumers. The test
   `test_sync_pipeline_inline_matches_canonical` checks they match byte-for-byte.
   Edit canonical first, copy the whole body to both consumers, run `tests/run.sh`.
2. **`.tmpl`, not `settings.json` (Fix B / Task 2).** Edit `settings.json.tmpl`,
   run `~/.claude/hydrate.sh --force`, then verify the regenerated `settings.json`.
   Editing the hydrated file directly gets overwritten.
3. **Two repos, two pushes (Fix B / Tasks 1–3).** `~/.claude` and
   `~/Repos/claude-settings-template/` are separate. Don't conflate "the .tmpl
   file" with "the template repo". If genuinely ambiguous, ASK.
4. **Don't widen scope.** The global `bash-guard.sh` subagent-exemption option was
   deliberately **deferred** (spec §4) — do not implement it. The Go modules
   feature slice is separate future work.
5. **`tests/run.sh` is the gate.** Run it after Task 5, Task 7, and Task 12.
   It must pass before the PR 2 commit.
6. **CLAUDE.md Bash rules apply to you too.** No `&&`/`;`/`$(...)`/heredocs in
   your own Bash calls (the carve-out for `git commit -m "$(cat <<'EOF'…)"` and
   `gh pr create` bodies stands). See [[feedback_claudemd_compliance]].

---

## 6. Validation (after both PRs land — spec §6)

Out-of-band, user-run: re-dispatch the housekeeper as a background subagent in a
real `review-gh-pr` against a stale-deps repo; confirm the engine runs and the
synthesiser includes its findings. Plus the negative path (permission-denied →
`FAILED`, not `Skipped`) and the no-fabrication check.

---

## 7. Relevant memories

[[project_code_review_suite_backlog]], [[project_housekeeper_specialist_slice4]],
[[feedback_settings_template_workflow]], [[feedback_claudemd_compliance]],
[[project_marketplace_autoupdate_wiped_branch]],
[[feedback_plugins_update_after_push]],
[[feedback_housekeeper_diff_is_selector_not_filter]].
