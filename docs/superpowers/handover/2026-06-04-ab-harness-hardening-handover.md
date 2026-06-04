# Handover — A/B harness hardening + static-specialist hygiene (backlog #2 / #3 / #4)

**Date:** 2026-06-04
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (personal plugin
marketplace; own git remote `Jodre11/claude-code-plugins`; **direct-push to
`main`, no PRs** — git-SHA versioning, every push to `main` is a new version; the
branch-protection-bypass notice on each push is expected and benign).
**State at handover:** both this repo and `~/.claude` are clean and 0 commits
ahead of origin — everything from the Phase 3.4 + security-reviewer session is
committed, pushed, and released to `main`. The repo is in a known-good state to
start fresh work.

**Your job:** three independent code-review-suite improvements, parked while the
Phase 3 sweep closed. Do them **in this order** — #2 first (it's a correctness
bug in the measurement rig that #3 depends on), then #3, then #4. Each STARTS as
**offline investigation** (no Bedrock spend); only #3, and the validation of #4,
need gated sweeps. Full backlog context lives in memory
`project_code_review_suite_backlog.md`.

---

## House rules (carried from the programme — non-negotiable)

- **Bash (operator global CLAUDE.md, hook-enforced):** NO compound operators
  (`&&` / `||` / `;`), NO command substitution `$(...)` except the permitted
  `git commit -m "$(cat <<'EOF' …)"` heredoc. Each command its own Bash call.
  Prefer dedicated tools over pipes/redirects.
- **TDD** for any parser/path logic (`superpowers:test-driven-development`); the
  structural suite is `bash tests/run.sh` (~370 tests). The test
  `A/B run.sh: bad-config rejection leaves working tree clean` **false-fails on a
  DIRTY tree** — that is the known artifact, NOT a regression; it passes once you
  commit clean. Everything else must stay green.
- **Temp files:** literal session `CLAUDE_TEMP_DIR` (`/tmp/claude-<id>/`), never
  bare `/tmp` or `/var/folders/`. (This IS the subject of #2.)
- **Commits:** no Co-Authored-By, no Claude advertising. **Push immediately after
  committing** — `autoUpdate` has wiped unpushed work in this dir before
  ([[project-marketplace-autoupdate-wiped-branch]]).
- **Memory:** when each item lands, update
  `project_code_review_suite_backlog.md` (mark done) in the SEPARATE `~/.claude`
  git repo memory dir
  (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`),
  commit + push it separately.
- **Gated sweeps:** any `bash tests/ab/run.sh … --trials N` against live agents is
  real Bedrock spend. Get a FRESH explicit go-ahead per spend — "continue" does
  NOT authorise it. Run sweeps directly in the main loop (operator preference),
  `run_in_background: true` per arm, wait for the completion notification (don't
  poll).

---

## Background: how #2 was discovered (the mechanism you're generalising)

During the Phase 3.4 jbinspect fix-validation sweep, 1/20 Haiku trials skipped
non-deterministically. Root cause was NOT the model: the A/B harness placed trial
working dirs at `${CLAUDE_TEMP_DIR:-/tmp}/per-agent-…`. **`CLAUDE_TEMP_DIR` is not
exported into the harness shell**, so it fell back to bare `/tmp` → macOS
`/private/tmp/per-agent-…`, OUTSIDE the operator's hook-exempt `/tmp/claude-*`
namespace. A dispatched agent that referenced the ABSOLUTE trial path in a tool
command (`jb inspectcode /private/tmp/.../foo.sln`) then tripped the operator's
global `~/.claude/hooks/bash-guard.sh` TEMP-DIRECTORY-VIOLATION policy and was
denied; trials using a RELATIVE path (`./foo.sln`) were fine. Path-choice-dependent
→ non-deterministic confound mis-scored as an agent skip.

Fixed (commit `830905b`) for the per-agent path only: `tests/ab/run.sh:264` now
falls back to `/tmp/claude-ab-<ts>` (the `/tmp/claude-` substring keeps the hook
exemption, even for the resolved `/private/tmp/claude-` form), with a grep
regression test in `tests/lib/test_ab_harness.sh`
(`test_ab_run_sh_per_agent_tmp_base_is_hook_exempt`).

**The deeper lesson (memory `project_code_review_suite_backlog.md`):** the A/B
harness leaks the operator's personal hooks (`bash-guard.sh` et al. in
`~/.claude/hooks/`) into every dispatched subagent. Any rig-created path outside
`/tmp/claude-*` can trip them.

---

## #2 — Generalise the harness hook-leak fix (DO FIRST; offline)

**Why first:** it's a correctness bug in the very rig #3 uses to re-validate. Don't
re-measure specialists on a rig that can still non-deterministically deny trials.

**The audit (already started this session — findings to verify, not take on faith):**
`grep -rn ':-/tmp\|mktemp\|CLAUDE_TEMP_DIR\|/private/tmp' tests/ab/run.sh tests/ab/lib/*.sh`
surfaced these sites beyond the one already fixed:
- `tests/ab/run.sh:337` — `synth_dir=$(mktemp -d)` (the orchestrator/faithfulness
  path). `mktemp` with no `TMPDIR` → `/var/folders/…` on macOS, which the hook
  ALSO blocks.
- `tests/ab/lib/agent_dispatch.sh:120-121` — `body_tmp`/`user_msg_tmp` via
  `mktemp` (writes the system-prompt + user-message scratch files).
- `tests/ab/lib/mutate.sh:45,70` — `mktemp` in the mutation helpers.

**The KEY question to settle before fixing (don't pre-judge):** which of these
paths are touched by the HARNESS SHELL vs by the DISPATCHED SUBAGENT? The hook
only fires on the *subagent's* Bash tool calls. The `mktemp` sites above run in
the harness's own shell (writing scratch files the harness then `cp`s into the
trial dir), so they are probably NOT hook-gated and probably benign — but CONFIRM
that by tracing whether any of these absolute paths can end up in a command the
subagent runs (the way the trial working-dir path did). Two candidate fixes,
choose per the evidence:
  - **(a) Narrow:** route every harness `mktemp`/temp path under `/tmp/claude-`
    (mirror the `830905b` pattern), so even if a path leaks to a subagent it stays
    hook-exempt. Add a grep regression test per site, mirroring the existing one.
  - **(b) Broad/root-cause:** make A/B subagents run ISOLATED from the operator's
    global hooks (so the rig never inherits personal `bash-guard.sh` at all). This
    is cleaner but bigger — depends on whether the dispatch path
    (`agent_dispatch.sh` → `launch.sh`) can pass a hooks-override / settings dir to
    the `claude` invocation. Investigate `launch.sh`'s argv construction
    (`launch_run_per_agent_trial`, ~line 301) for a `--settings` / hooks knob.

Recommend (a) for the known `mktemp` sites as a cheap belt-and-braces, and
investigate (b) as the durable fix — but let the trace decide. Whatever you ship,
add regression tests and run `bash tests/run.sh`. Offline throughout — no Bedrock.

---

## #3 — Re-validate ruff / eslint / trivy against the apparatus fix (gated sweeps)

All three were flipped to `model: haiku` + `effort: low` under the OLD harness
(pre-`830905b`, pre-hook-leak understanding). Their EQUIVALENT verdicts predate
the `/tmp/claude-` fix. **Low priority / likely fine** — the confound only bit
ABSOLUTE-path tool commands, and these three stream stdout (ruff/eslint redirect
to `$CLAUDE_TEMP_DIR`, trivy streams inline) rather than passing an absolute
solution path the way jbinspect did. But their historical cost-ratio numbers
(ruff ~2.2× / eslint 2.17× / trivy 2.34×) carry latent noise if any trial tripped
the old confound.

**Cheap first step (offline):** before spending, grep the EXISTING run dirs for
the confound signature — `grep -rl 'TEMP DIRECTORY VIOLATION' tests/ab/runs/` (the
session already saw many such hits in `~/.claude/projects/-private-tmp-per-agent-*`
transcripts). If the old ruff/eslint/trivy runs show no violations, #3 may need no
re-sweep at all — just a note. If they DO, re-sweep the affected arm(s) at n=20 on
the FIXED harness (gated) and confirm the verdict holds. Configs already exist:
`tests/ab/configs/per-agent/{ruff,eslint,trivy}-{baseline,haiku-low}.yaml`.

---

## #4 — Port ruff / eslint to `--stdout`-style inline streaming (offline + gated validation)

jbinspect's `--stdout` switch (commit `aef3c4f`) removed a write-then-read
round-trip and cut Haiku turns ~40%. Confirmed this session that **both ruff and
eslint still do the temp-file round-trip** and are candidates:
- `ruff-reviewer.md:47-48` — `ruff check --output-format=json … → $CLAUDE_TEMP_DIR/ruff-*.json`.
  Ruff can write JSON to stdout (no `-o`), so inline parsing is straightforward.
  Watch the `.ipynb`/nbqa path (lines 50-51) — that one genuinely remaps via a
  temp file and may need to stay.
- `eslint-reviewer.md:49` — `<bin> --format=json … → $CLAUDE_TEMP_DIR/eslint-*.json`.
  ESLint `--format=json` goes to stdout by default; inline-parseable.
- **trivy already streams inline** (`trivy-reviewer.md:39,80`) — it's the TEMPLATE,
  no change needed. jbinspect (`aef3c4f`) is the worked precedent for the edit.

**Template wording** for the temp-dir-contract clarification + inline-stream
guidance: copy `trivy-reviewer.md:37-39` and `:80` (and see jbinspect's
`## Tool invocation` post-`aef3c4f`). The parser in `tests/ab/lib/agent_capture.sh`
reads the §7 markdown, NOT the JSON, so switching to stdout does NOT change the
parser — but VERIFY the agent still emits the same canonical §7 finding shape
after the change (a captured trial, then the hash must match the existing
`expected/findings.json`).

**This is efficiency + consistency, NOT a fragility fix** — so it's optional/nice.
If you do it: edit offline, then a gated 2×20 re-sweep per specialist to confirm
the verdict + canonical hash hold (mirror the jbinspect fix-validation arc). Don't
flip anything — they're already haiku+effort:low; this only changes invocation.

---

## Out of scope here (parked separately — don't start)

- **Housekeeper specialist** — DEFERRED (`docs/superpowers/handover/2026-06-04-housekeeper-specialist-handover.md`).
  Was justified by security-reviewer's dead live-fetch path; that path was fixed
  directly (`4a847e9`, WebFetch+WebSearch grant). Revisit only on evidence the
  tweaked security-reviewer's freshness coverage is insufficient
  ([[project-security-reviewer-live-data]]).
- **Orchestrator → Workflow migration** — the big horizon item
  ([[project-orchestrator-workflow-migration]]). **Do #2 before ever starting it**
  (same rig-correctness reason).

---

## Start by reading (in order)

1. **This handover.**
2. **Memory:** `project_code_review_suite_backlog.md` (the parked #2/#3/#4 with
   context), `project_phase_3_4_jbinspect_shipped.md` (the hook-leak discovery +
   the `--stdout` precedent), `project_security_reviewer_live_data.md` (why the
   housekeeper is parked).
3. **`tests/ab/run.sh`** lines ~248-280 (the fixed per-agent path + its comment
   explaining the confound) and ~330-342 (the unaudited `synth_dir` mktemp).
4. **`tests/ab/lib/agent_dispatch.sh`** + **`tests/ab/lib/launch.sh`** (dispatch +
   argv construction — for the #2 broad-fix investigation).
5. **`~/.claude/hooks/bash-guard.sh`** + **`~/.claude/hooks/_lib.sh`** (the
   `mentions_temp_path` / `cmd_mentions_session_temp` predicates — the exemption is
   a `/tmp/claude-` substring match).
6. **`tests/lib/test_ab_harness.sh`** `test_ab_run_sh_per_agent_tmp_base_is_hook_exempt`
   (the regression-test pattern to mirror for new #2 sites).
7. **`plugins/code-review-suite/agents/{ruff,eslint,trivy}-reviewer.md`** (the #4
   invocation styles; trivy is the inline-stream template).
