# Housekeeper subagent Bash-failure remediation — design

**Date:** 2026-06-12
**Repos:** spans **two** repos.
- Plugin fixes (A, C, D): `~/.claude/plugins/marketplaces/jodre11-plugins` (the
  personal plugin marketplace — independently versioned, own CI/CLAUDE.md/test
  suite; push to its own `origin`, NOT the `claude-settings` repo).
- Permission/template fix (B): `~/.claude` (`claude-settings`) plus the public
  upstream seed at `~/Repos/claude-settings-template/`. A plugin cannot grant
  itself host Bash permission, so B cannot live in the marketplace repo.

**Status:** design approved; pending spec review before writing-plans.

---

## 1. Goal

When `housekeeper-reviewer` runs **as a dispatched background subagent** inside a
real `review-gh-pr` / `pre-review` pipeline, its Bash calls fail and the
`housekeeper-freshness` engine never runs. The specialist then emits a silent
`Skipped — …`, fabricates a manual dependency analysis from trained knowledge
(which its own spec forbids), and the synthesiser drops the freshness view
entirely from the final report. The user must notice this by hand and re-run the
housekeeper in the main session.

This design removes that failure at its roots and makes any residual failure
loud. It does **not** add a new feature — the next feature slice (Go modules)
is explicitly out of scope.

---

## 2. Verified root cause

Two independent failures, both observed in two real review transcripts
(`…-Repos-haven-finance-erp/67ec783b…/subagents/agent-a7f35b45ffb3fecce.jsonl`
and `…/7ac503dd…/subagents/agent-ae9b69009e40aff2e.jsonl`). A third is an
accelerant; a fourth makes the result invisible.

### A — `$CLAUDE_TEMP_DIR` is never resolved for the subagent (root, all specialists)

The SessionStart hook (`~/.claude/hooks/session-init.sh`) injects
`CLAUDE_TEMP_DIR=<path>` as `additionalContext` **text only** — it does NOT
export an environment variable. Confirmed: `printenv CLAUDE_TEMP_DIR` exits 1
even in the main session. The main session "works" only because the orchestrator
model reads the context text and textually substitutes the path.

The review pipeline builds `$AGENT_PROMPT` with the **literal, unexpanded** line
`Use $CLAUDE_TEMP_DIR for temporary files.` (`includes/review-pipeline.md`
Step 2.9, line ~715). The subagent therefore emits the literal token to Bash,
which expands to empty, so `git diff … > $CLAUDE_TEMP_DIR/housekeeper-files.txt`
becomes `> /housekeeper-files.txt` → `read-only file system: /housekeeper-files.txt`
(session 1 record [16], session 2 [13]).

This is latent for **all** static specialists, not just the housekeeper. It
manifests only for the housekeeper because the housekeeper's `tools:` are
`Read, Grep, Glob, Bash` — **no `Write`** — and its engine reads its inputs from
files, so it is the only specialist forced to write a temp file via Bash *before*
its tool runs. The other specialists (ruff/eslint/trivy/jbinspect) let their tool
create its own output and rarely pre-write.

It also violates the user's own `~/.claude/CLAUDE.md` rule: *"When spawning
subagents, pass the resolved CLAUDE_TEMP_DIR value in the prompt."* The pipeline
does not.

The false reassurance paragraph *"That line carries `$CLAUDE_TEMP_DIR`
**unexpanded** — Bash expands it from your environment when a command runs … do
not treat it as a missing temp dir and abort"* is present in **all five** static
specialists (`housekeeper-reviewer.md:30`, `jbinspect-reviewer.md:44`,
`eslint-reviewer.md:46`, `trivy-reviewer.md:37`, `ruff-reviewer.md:47`). It is
factually wrong and actively instructs agents not to abort on the empty token.

### B — the engine binary is not allowlisted (root, housekeeper-specific)

`~/.claude/hooks/allow-permissions.sh` exists precisely so dispatched subagents —
which inherit hooks but NOT `permissions.allow` patterns (Claude Code issue
#18950) — auto-approve known commands. It allowlists by base command and already
covers every *other* static specialist's tool: `git`, `python3`, `ruff`, `nbqa`,
`trivy`, `eslint`, `biome`, `jb`. **`housekeeper-freshness` is absent** (so is
`touch`). When the housekeeper finally issues the engine call, the hook falls
through; a background subagent has no interactive approver, so Claude Code
auto-denies: `Permission to use Bash has been denied` (session 1 [35],[38];
session 2 [26]).

This is exactly why the handover's scope-check found that **only** the
housekeeper hit a denial: it is the one specialist whose tool is not on the
allowlist.

### C — the global bash-guard hook fires inside the subagent (accelerant)

`~/.claude/hooks/bash-guard.sh` enforces the CLAUDE.md authoring rules (no `&&`,
no `;`, no newline separators, no heredoc, …) and fires inside dispatched
subagents. The housekeeper agent doc tells the agent to run
`git diff … > file && cat …` and `cat > file << 'EOF'` heredocs — both denied
(session 1 [13]; session 2 [8],[10],[21]). Each rejection burns a turn and pushes
the agent toward giving up. Note: once a *resolved literal path* is used, the
agent's `printf … > /tmp/claude-<id>/…` calls succeed (session 2 [17],[22]) — so
A and C are coupled: fixing A removes most of C's bite, and hardening the
commands removes the rest.

### D — failure is silent and the synthesiser drops it (observability)

The housekeeper returned `Skipped — housekeeper-freshness engine could not
execute…` — indistinguishable from the legitimate `Skipped — python3 not
available` — **plus** a fabricated manual dependency analysis from trained
knowledge ("current GA is 33.0.0 or later", etc.), which directly violates the
"engine is the sole source of truth … do NOT add tuples from trained knowledge"
contract. The synthesiser transcript (`agent-a490f09578bd7f89f.jsonl`) contains
**zero** occurrences of "housekeeper" — the freshness view was entirely absent
from the synthesised report. This confirms the handover's inferred
synthesiser-consequence reading.

---

## 3. Remediation

Four fixes. B lands in `claude-settings` (+ template); A, C, D land in the
plugin. Per the user's housekeeping convention, the permission change (B) is the
natural "lands-first, separate" change because it is the single fix that actually
unblocks the engine; A/C/D can ride together in the plugin PR.

### Fix A — pipeline injects the resolved temp-dir path (root; benefits all specialists)

- **`includes/review-pipeline.md` Step 2.9:** the orchestrator substitutes the
  real `/tmp/claude-<session-id>/` path into `$AGENT_PROMPT` in place of the
  literal `Use $CLAUDE_TEMP_DIR for temporary files.` line. The orchestrator
  knows the session id (it is in the SessionStart context that the orchestrator
  itself received), so it can resolve the absolute path deterministically. The
  rendered prompt line becomes e.g.
  `Use /tmp/claude-<session-id>/ for temporary files.` with a concrete path.
- **Synced consumers:** propagate the identical change to the two inlined copies
  (`skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`). The test suite
  verifies the inlined copies match the canonical source — update all three in
  lockstep.
- **Five static specialists:** replace the false "Bash expands it / unexpanded
  token is expected — do not abort" paragraph in `housekeeper-reviewer.md`,
  `jbinspect-reviewer.md`, `eslint-reviewer.md`, `trivy-reviewer.md`,
  `ruff-reviewer.md`. New wording: *the prompt carries a resolved absolute path;
  read it from the `Use <path> for temporary files.` line and use it directly.*
  Update the shared contract wording in `includes/static-analysis-context.md` §4
  to match (it currently says "the path from `Use <path> for temporary files`",
  which is already compatible — confirm and tighten if needed).

### Fix B — allowlist the engine binary (root; housekeeper-specific) — `claude-settings` + template

- Add `housekeeper-freshness` to the base-command allowlist in
  `~/.claude/hooks/allow-permissions.sh` (alongside `ruff|nbqa|trivy|eslint|biome`),
  and add `Bash(housekeeper-freshness *)` (or the project's pattern style) to
  `permissions.allow` in `settings.json`. Edit the `.tmpl` source and re-hydrate
  per [[feedback_settings_template_workflow]] — never edit `settings.json`
  directly.
- Propagate the mechanism to the public seed at `~/Repos/claude-settings-template/`
  so other machines/clones get it. This is a generic mechanism change (not a
  personal/identifying entry), so per the CRITICAL VOCABULARY rule in
  `~/.claude/CLAUDE.md` it belongs in **both** the local `.tmpl` and the template
  repo.
- The plugin's `housekeeper-freshness` engine ships in `bin/` and is added to
  PATH automatically by Claude Code; the allowlist entry only governs the
  permission gate.
- **Plugin documentation:** note in the code-review-suite README prerequisites
  that an end-user machine dispatching the housekeeper as a background subagent
  must pre-authorise the `housekeeper-freshness` command (analogous to the
  ruff/trivy/eslint requirement that already exists implicitly). This documents
  the host-side dependency a plugin cannot satisfy itself.

### Fix C — harden the agent's own commands (accelerant) — plugin only

- Rewrite the "Tool invocation" section of `housekeeper-reviewer.md` so every
  command is a single hook-safe Bash call: no `&&`, no `;`, no heredoc.
  - The `git diff --name-only … > <path>` write is a single redirection (allowed:
    one command, one redirect) to the now-resolved literal path.
  - The empty-fallback file-list write uses repeated `printf '%s\n' …
    > <path>` (already used successfully in the transcripts) rather than a
    heredoc.
  - The `Changed lines:` block write likewise uses `printf` rather than a heredoc.
- This is self-contained in the plugin and leaves the global `bash-guard.sh`
  firing in subagents (the user chose "harden agent commands only", not the hook
  exemption — see §4).

### Fix D — loud failure + ban the fabrication (observability) — plugin only

- **`housekeeper-reviewer.md`:** on a Bash-denied or permission-exhausted state,
  emit a **distinct** terminal status — `FAILED — housekeeper-freshness could not
  be invoked (Bash permission denied).` — explicitly separate from the legitimate
  `Skipped — python3 not available` / `Skipped — housekeeper-freshness not
  available on PATH` lines (which are genuine, expected skips). Add an explicit
  prohibition: the agent MUST NOT substitute a manual dependency analysis from
  trained knowledge under any circumstance; if the engine cannot run, the only
  permitted output is the FAILED status.
- **`agents/review-synthesiser.md`:** when a specialist's report is a `FAILED —
  …` status, the synthesiser must surface it visibly (e.g. a one-line note in the
  Synthesiser Assessment or a dedicated "Specialist failures" note) rather than
  silently omitting the specialist. A genuine `Skipped — …` (tool legitimately
  absent) need not be surfaced as a failure.

---

## 4. Out of scope (raised, deliberately not selected)

- **Exempting dispatched subagents from `bash-guard.sh` globally.** This was
  re-litigated. The tradeoff: it would let *every* plugin agent write natural
  Bash without hook-safe contortions, and the hook is a
  `claude-settings`/`dotfiles`-level concern rather than a plugin concern — but it
  requires the hook input JSON to carry a reliable subagent signal (unverified),
  and it widens blast radius. With A + B + C the failure is resolved without it,
  so it is **deferred**. Revisit only if hook-safe authoring proves an ongoing
  burden across plugin agents, and only after verifying a subagent signal exists
  in the PreToolUse hook payload.
- **The Go modules feature slice.** Separate, future work; not touched here.

---

## 5. Affected files

**Plugin (`jodre11-plugins`):**
- `plugins/code-review-suite/includes/review-pipeline.md` (Step 2.9 — Fix A)
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (synced copy — Fix A)
- `plugins/code-review-suite/commands/pre-review.md` (synced copy — Fix A)
- `plugins/code-review-suite/includes/static-analysis-context.md` (§4 wording — Fix A)
- `plugins/code-review-suite/agents/housekeeper-reviewer.md` (Fixes A, C, D)
- `plugins/code-review-suite/agents/jbinspect-reviewer.md` (Fix A wording)
- `plugins/code-review-suite/agents/eslint-reviewer.md` (Fix A wording)
- `plugins/code-review-suite/agents/trivy-reviewer.md` (Fix A wording)
- `plugins/code-review-suite/agents/ruff-reviewer.md` (Fix A wording)
- `plugins/code-review-suite/agents/review-synthesiser.md` (Fix D)
- `plugins/code-review-suite/README.md` (prerequisite note — Fix B doc side)
- `tests/` — extend structural/sync checks so the resolved-temp-dir line stays in
  lockstep across the three pipeline copies, and (if feasible) a behavioural
  smoke that a dispatched housekeeper writes to a resolved path.

**Settings (`claude-settings` + public template):**
- `~/.claude/hooks/allow-permissions.sh` (add `housekeeper-freshness`)
- `~/.claude/settings.json.tmpl` → re-hydrate (add `Bash(housekeeper-freshness *)`)
- `~/Repos/claude-settings-template/` equivalents (generic mechanism propagation)

---

## 6. Validation

- **Re-run the failing scenario:** dispatch the housekeeper as a background
  subagent in a real review on a repo with stale deps; confirm the engine runs,
  emits findings, and the synthesiser includes them.
- **Negative path:** simulate a permission-denied state and confirm the agent
  emits `FAILED — …` (not `Skipped`) and the synthesiser surfaces it.
- **No-fabrication check:** confirm the agent never emits a manual dependency
  list when the engine cannot run.
- **Sync test:** the test suite confirms the three pipeline copies match after
  the Step 2.9 edit.
- **Regression:** the four other static specialists still resolve their temp dir
  correctly with the new resolved-path wording.

---

## 7. References

- Handover:
  `docs/superpowers/handover/2026-06-12-housekeeper-subagent-bash-failure-investigation-handover.md`
- Memories: [[project_housekeeper_specialist_slice4]],
  [[project_code_review_suite_backlog]], [[feedback_settings_template_workflow]],
  [[project_security_reviewer_live_data]],
  [[feedback_housekeeper_diff_is_selector_not_filter]].
