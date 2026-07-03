# Handover — execute Phase 3.3 (trivy A/B baseline), offline tasks to the gate

**Date:** 2026-06-03
**Predecessor this session:** (1) shipped + LIVE-VERIFIED the held production
Haiku flip for eslint + ruff; (2) wrote the trivy Phase 3.3 plan and did its
offline groundwork. **Your job:** execute that plan, subagent-driven, through the
three OFFLINE tasks only, then STOP at the first Bedrock gate and hand back to the
operator.

---

## The one thing to do

**Execute `docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md`,
Tasks 1–3 only, using `superpowers:subagent-driven-development` (fresh subagent
per task, two-stage review between tasks). Then STOP before Task 4 and report.**

- Tasks 1–3 are **fully offline — zero Bedrock spend** (corpus fixture, parser-
  dispatch case + TDD tests, A/B configs). Commit + push after each per the rules
  below.
- Task 4 onward is **live Bedrock spend** (worked-example capture, then the 2×20
  sweep). The operator has explicitly gated these: **do NOT run Task 4+ without a
  fresh, explicit go-ahead.** Reaching the Task 4 gate IS the end of this handover.

The plan is placeholder-free and self-contained: exact file paths, full file
contents, exact commands with expected output, and the real captured trivy
finding set already baked in. Follow it literally — do not re-derive what it
already establishes.

## Method (operator's stated choice)

- **`superpowers:subagent-driven-development`** — dispatch ONE fresh subagent per
  plan task; do the two-stage review (spec-compliance check, then code review)
  between tasks before moving on. Invoke the skill first; it tells you the loop.
- When dispatching agents: set `mode: "auto"`, give each a unique kebab-case
  `name`, and pass the resolved `CLAUDE_TEMP_DIR` literal into the prompt (the
  SessionStart hook injects it into YOUR context as `CLAUDE_TEMP_DIR=...`; it is
  NOT exported into the Bash shell, so subagents can't read it from the env).
- After all three offline tasks: run `bash tests/run.sh` once on a clean tree,
  confirm the new baseline (see below), then write a short status report and stop.

## REPO + house rules (read first, non-negotiable)

**REPO:** `~/.claude/plugins/marketplaces/jodre11-plugins`
(autoUpdate-managed marketplace clone; remote `Jodre11/claude-code-plugins`; base
`main`). **PUSH after EVERY commit** — a prior autoUpdate reclone wiped an
unpushed branch. Direct-push to `main` is the established workflow (branch-
protection bypass is expected and reported by the remote; no PR required).

**House rules (operator global CLAUDE.md — enforce on every Bash call you AND
subagents issue; they do NOT govern code written into files):**
- NO compound shell (`&&`, `||`, `;`), NO `$(...)`/backticks, NO pipes/subshells
  in a single Bash call — use separate Bash calls, capture output, pass it on. A
  single `> file 2>&1` redirect is allowed; a lone `grep`/`jq`/`yq`/`awk` with no
  pipe is allowed. Carve-out: `git commit` HEREDOC for literal multi-line bodies.
- 4-space shell indent, LF endings, 2-space for md/json/yaml (`.editorconfig`).
- Commit messages: NO Co-Authored-By, NO Claude advertising. `git add` specific
  paths only (never `-A` / `.`).
- Memory lives in the SEPARATE `~/.claude` repo (`projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/`),
  NOT this clone. Commit + push it separately when you touch it (Task 7 only —
  out of scope for this handover).

**Verify before claiming done:** run `bash tests/run.sh`. **Baseline at the start
of this handover is 342 passed / 1 skipped.** After Task 2 adds 3 trivy parser
tests, a clean-tree run should be **345 passed / 1 skipped**. KNOWN ARTIFACT: the
test `A/B run.sh: bad-config rejection leaves working tree clean` runs
`git diff --quiet` over the whole repo, so it FALSE-FAILS whenever you have
uncommitted changes. Commit, then re-run clean to confirm the real count.

## Start by reading (in order)

1. **The plan — your script:**
   `docs/superpowers/plans/2026-06-03-phase-3-3-trivy-ab-baseline.md`. Read it
   end-to-end. The "Critical offline findings" block at the top has the real
   trivy finding set and two load-bearing facts (bare `DS-NNNN` IDs; line-less
   findings designed out) — do not re-derive these with a live trivy run unless a
   step explicitly tells you to verify.
2. **Memory** (in the `~/.claude` repo): the file
   `memory/project_phase_3_2b_pr_b_reprobe.md` for the programme context and the
   now-RESOLVED effort-flip story, plus `memory/project_worked_example_gap.md`
   (why trivy's first live capture will parse to zero tuples — relevant to Task 4,
   which you are NOT running, but informs why the worked-example step exists).
3. **The parent programme spec (verdict framework, for context):**
   `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`.
4. **The eslint phase as the worked precedent for the whole loop:** the corpus at
   `tests/ab/corpus/eslint-smoke-bad-js/` and the parser case in
   `tests/ab/lib/agent_capture.sh` — the trivy versions mirror these exactly.

## What is ALREADY DONE this session (do NOT redo)

- **eslint + ruff production flip: SHIPPED + LIVE-VERIFIED.** Both agents now carry
  `model: haiku` + `effort: low` (commit `3b3a255`, pushed). The blocker (no
  `effort:` field) is resolved: `effort:` IS a documented subagent frontmatter key
  (options low/medium/high/xhigh/max, overrides session effort). Verified live by
  dispatching a real `code-review-suite:eslint-reviewer` subagent and reading
  `.message.model` from its transcript: `sonnet-4-6` before `/reload-plugins`,
  `haiku-4-5` after. **This is finished — do not touch eslint/ruff frontmatter.**
- **The trivy PLAN itself** — written, self-review-passed. You execute it; you do
  not rewrite it (fix it only if a step proves wrong in practice, and say so).
- **Offline recon baked into the plan:** trivy 0.71.0 + InspectCode 2026.1 both
  confirmed on PATH; the real `trivy config` finding set captured (DS-0001 line 1,
  DS-0004 line 7, DS-0031 line 9 — all line-bearing after the fixture's `USER`
  directive suppresses the line-less DS-0002).

## The three tasks you ARE executing (summary — full detail in the plan)

- **Task 1 — Corpus fixture (offline).** Replace the trivial
  `tests/fixtures/static-analysis/trivy/Dockerfile` with the 3-finding fixture
  (exact contents in the plan), verify `trivy config` yields exactly the three
  expected line-bearing findings, write `source.yaml` (NO `setup:` block — trivy
  is global-on-PATH like ruff, no provisioning race), the `diff/changed-lines.txt`
  scope file, and register the fixture in `tests/ab/corpus/index.yaml`. Commit +
  push.
- **Task 2 — Parser-dispatch case + TDD tests (offline).** Write the captured-
  output test fixture `tests/ab/fixtures/trivy-stdout-three-findings.log`, add the
  three failing parser tests to `tests/lib/test_ab_per_agent_lib.sh` (test
  discovery is automatic by `test_` prefix — no manual registration), watch them
  fail with "unknown agent: trivy", add the `trivy|trivy-reviewer` case to
  `tests/ab/lib/agent_capture.sh` `_agent_capture_params()`, watch them pass. The
  shared rule-ID tokeniser (split on `[ \t(]`, token 1) handles bare `DS-NNNN`
  cleanly — a test asserts this; no tokeniser change needed. Commit + push.
- **Task 3 — A/B configs (offline).** Create
  `tests/ab/configs/per-agent/trivy-baseline.yaml` (sonnet/default) and
  `trivy-haiku-low.yaml` (haiku/low), mirroring the eslint config shape exactly.
  Commit + push.

## The STOP line

After Task 3 commits + pushes and `bash tests/run.sh` shows 345/1 clean:
**stop.** Do NOT start Task 4. Report to the operator:
- confirmation the three offline tasks are committed + pushed (list the SHAs),
- the clean suite count,
- a one-line reminder that Task 4 (live worked-example capture) and Task 6 (the
  matched 2×20 sweep, ~$4 list / ~25 min) are the next steps and BOTH need
  explicit operator go-ahead before any Bedrock spend.

## After trivy (NOT this handover) — the horizon, so you keep the goal in view

- **End goal, near-term:** flip all four static specialists to Haiku/low where an
  A/B proves equivalence (~2.2× cheaper/specialist). 2 of 4 done (ruff, eslint);
  trivy is #3 (this plan); **jbinspect is #4 — a SEPARATE Phase 3.4 plan**, heavier
  because it needs .NET fixture provisioning + a CamelCase rule-ID tokeniser check.
  Do trivy end-to-end as the worked example before starting jbinspect.
- **End goal, longer-term (deferred, start from `superpowers:brainstorming` if
  taken up):** convert the code-review orchestrator to a deterministic Workflow
  with schema-validated specialist output — dissolving the whole markdown-parse
  apparatus (the §7 worked-example fragility and skip-sentinel brittleness this
  programme keeps patching). See `memory/project_worked_example_gap.md` and
  `memory/project_phase_3_2b_pr_a_apparatus_fix.md`.

## Operational note you may need

If you push a plugin change mid-session and want it live in a running session:
`/plugins update` refreshes the on-disk SHA-keyed cache from GitHub, THEN
`/reload-plugins` reloads the in-memory agent registry from that disk (a fresh
session also picks it up). Verified this session. Not needed for Tasks 1–3 (they
touch test harness + fixtures, not dispatched-agent definitions), but relevant if
you ever test a `*-reviewer.md` body change live.
