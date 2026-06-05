# Handover — housekeeper slice 2 (NuGet) EXECUTION session

**Date:** 2026-06-05
**Repo:** `~/.claude/plugins/marketplaces/jodre11-plugins` (own remote
`Jodre11/claude-code-plugins`; direct-push to `main`, push immediately; the
branch-protection-bypass notice on push is expected/benign).

**State:** Slice-2 BRAINSTORMING + DESIGN + PLANNING are DONE. The plan is
written, committed, and pushed (`715e06d`):
`docs/superpowers/plans/2026-06-05-housekeeper-slice2-nuget.md`. The operator has
SIGNED OFF on the plan. This session EXECUTES it task-by-task via
`superpowers:subagent-driven-development`.

**This is a real-code session.** Tasks 1-12 are offline (engine/agent/test/docs +
A/B apparatus). Task 13 spends real Bedrock (live capture + 2×20 sweep) and is
**GATED** — STOP for explicit operator go-ahead before the capture AND before the
sweep. "Continue" does NOT pre-authorise either.

---

## What slice 2 builds (operator-confirmed scope — do NOT re-litigate)

NuGet as a fourth source class on the same `bin/housekeeper-freshness` chassis,
PLUS a maintenance-health axis and the slice-1 npm/runner hardening. Three
deliberate scope calls made slice 2 comparable in size to slice 1:

1. **NuGet freshness** — `.csproj` / `Directory.Packages.props` (CPM) /
   `Directory.Build.props` parser, flat-container version fetch, semver compare,
   nearest-ancestor-`.csproj` scope gate, T3 targets.
2. **Maintenance-health axis (BUILT, not deferred)** — adds a `health` field to
   the engine tuple. Deterministic registry signals ONLY (`deprecated` +
   `unlisted`/yank); fuzzy signals deferred. Emit rule widens from "stale" to
   "stale OR health-flagged". **npm `deprecated` rider INCLUDED.**
3. **NuGet licence-diff (BUILT)** via the registration API (flat-container is
   version-only). One shared registration client serves licence-diff AND health.
4. **npm/runner hardening folded in** (each its own regression test): multi-section
   dep collapse `(section,name)` keying, `.json` scope narrowing, `LATEST_RUNNERS`
   180-day cadence self-check.

## Process — subagent-driven-development

1. Invoke `superpowers:subagent-driven-development`. Execute the 13 tasks IN ORDER.
2. **Per task:** dispatch a fresh implementer subagent with the task's full text
   (it has zero context — the plan steps are self-contained). Then run the
   two-stage review (spec-compliance review, then quality review) before moving
   on. Commit + push at each task's final step (the plan carries the exact
   commands).
3. Dispatch subagents with `mode: "auto"` and a kebab-case `name`
   (e.g. `implementer-task-3`, `spec-reviewer-task-3`). Pass the resolved
   `CLAUDE_TEMP_DIR` value to any subagent that needs temp files.
4. **STOP at Task 13** for explicit go-ahead before the capture and again before
   the sweep.
5. After Task 13: update memory (see below).

The plan is the contract. Each task is TDD: failing test → run-to-fail →
implement → run-to-pass → commit+push. Do not batch tasks or skip the run-to-fail
step — that step proves the test actually exercises the new behaviour.

## Context to load first (read in this order — do NOT re-derive)

1. **The approved plan** (the executable contract):
   `docs/superpowers/plans/2026-06-05-housekeeper-slice2-nuget.md`. Read it whole
   — it carries complete code, tests, exact commands, and self-review notes.
2. **The approved design spec** (the plan's source, for any "why"):
   `docs/superpowers/specs/2026-06-05-housekeeper-slice2-nuget-design.md` (`9f91f57`).
3. **The engine** (what every engine task modifies):
   `plugins/code-review-suite/bin/housekeeper-freshness`. Note the shipped slice-1
   refinements BEYOND the slice-1 plan: subpath-action owner/repo slug handling,
   `_NPM_SCOPE_SUFFIXES` + `_is_npm_scope_file`, the os.walk `node_modules` prune,
   and licence-diff-against-target (not latest). The slice-2 plan builds on the
   CURRENT engine, not the slice-1 plan's snapshot.
4. **The agent:** `plugins/code-review-suite/agents/housekeeper-reviewer.md`
   (Task 7 adds `nuget` + health rendering + extends the worked example; it
   already carries the `Changed lines:` fallback for non-git sandboxes).
5. **Tests + apparatus:** `tests/python/test_housekeeper_engine.py` (the engine
   unittest the plan extends), `tests/lib/test_ab_per_agent_lib.sh` +
   `tests/ab/lib/agent_capture.sh:65-72` (the source-agnostic housekeeper parser
   case — Task 12 confirms it needs NO change), `tests/lib/test_sync_notes.sh`
   (Task 9 confirms the detection sync test asserts flag presence only).
6. **Slice-1 result note** as the template for Task 13's note:
   `docs/superpowers/notes/2026-06-05-housekeeper-haiku-low-result.md`.
7. **Memory:** `project_housekeeper_specialist_slice2.md` +
   `project_housekeeper_specialist_slice1.md` in the `~/.claude` repo
   (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`).

## Known constraints (carried — these cost captures/time before)

- **Plugin-cache pre-flight before any A/B capture (Task 13):** the harness
  dispatches the agent BODY from the working tree but resolves the engine BINARY
  on PATH from the plugin CACHE. After the mid-session `bin/` edits in Tasks 1-6/10,
  run `/plugins update` THEN `/reload-plugins` (or start a fresh session) BEFORE
  the first capture, or the dispatched agent runs a stale engine. (Cost a capture
  in slice 1.)
- **Live registries on the sweep:** the harness scrubs the subagent env
  (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`), so `HOUSEKEEPER_REGISTRY_FIXTURES` is NOT
  injected — Task 13's live capture/sweep hit REAL nuget.org. The
  **deprecated-current health finding depends on a LIVE deprecation the harness
  cannot stub.** Task 13's pre-flight blockquote (above its Step 1) forces a
  verify-or-rescope decision: confirm the chosen package is genuinely
  live-deprecated, or pick a
  genuinely-deprecated package, or scope the live sweep to the freshness finding
  and record the health finding as fixture-verified-only. Do NOT let a fixture/live
  divergence launder into a false INCONCLUSIVE. Engine determinism under fixtures
  is independently proven by `NuGetEndToEndTest`.
- **Dirty-tree test artifact:** `bash tests/run.sh` is the safety net, but the
  `A/B run.sh: bad-config rejection leaves working tree clean` test false-fails on
  a dirty tree — commit first, then run, or expect that one red.
- **Red-test sequencing:** unlike slice 1, this plan has NO deliberately-red
  cross-task tests — every task ends green. If a task leaves a test red, that is a
  real failure to fix, not an expected transient.

## Hard house rules (global + repo CLAUDE.md)

- Bash: NO `&&`/`||`/`;`/`$(...)` except the permitted `git commit -m "$(cat
  <<'EOF' …)"` heredoc. One command per Bash call (pre-commit hook enforces).
- Temp files under the literal session `CLAUDE_TEMP_DIR` (`/tmp/claude-<id>/`),
  never bare `/tmp`. Pass the resolved value to any subagent needing temp files.
- Commits: no Co-Authored-By, no Claude advertising. Push immediately (autoUpdate
  has wiped unpushed work in this dir before).
- Plugin authoring: frontmatter `name`+`description`, blank line after `---`,
  2-space md/json indent, LF endings, `chmod +x` for `bin/` (the engine is already
  executable — preserve the bit on edits).
- 4-space indent for shell/Python; 120-col. The engine is stdlib Python (adds
  `import gzip` in Task 2 — no pip deps).

## Definition of done

- Tasks 1-12 committed + pushed; `bash tests/run.sh` green (bar the dirty-tree
  artifact); the engine unittest suite all-green.
- Task 13 (after gated go-ahead): verdict written to
  `docs/superpowers/notes/2026-06-05-housekeeper-nuget-haiku-low-result.md`;
  production-flip decision recorded (the agent already ships `haiku`/`low` — on
  EQUIVALENT no frontmatter change, just record the validation; on
  INCONCLUSIVE/WORSE flag the revert trade-off since the tier covers all four
  source classes).
- Memory: update `project_housekeeper_specialist_slice2.md` (planning →
  SHIPPED, with the verdict + cost ratio + whether haiku held) and the
  `project_housekeeper_specialist_slice1.md` "Next step" pointer, in the
  `~/.claude` repo. Commit + push that repo SEPARATELY.

## First action

Read the plan (`docs/superpowers/plans/2026-06-05-housekeeper-slice2-nuget.md`)
and the current engine, invoke `superpowers:subagent-driven-development`, then
dispatch the Task 1 implementer.
