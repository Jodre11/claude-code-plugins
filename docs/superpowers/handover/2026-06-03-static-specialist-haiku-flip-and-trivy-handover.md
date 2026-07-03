# Handover — static-specialist Haiku flip + trivy/jbinspect A/B baselines

**Date:** 2026-06-03
**Predecessor:** Phase 3.2b PR B (clean eslint re-probe) + PR C (tier-1 fix) —
both SHIPPED + VALIDATED this session.
**This handover:** two pieces of work, in order — (1) the HELD production
`model:` flip for eslint + ruff, then (2) the trivy and jbinspect static-
specialist A/B baselines (each needs groundwork before any sweep).

---

## REPO + house rules (read first, non-negotiable)

**REPO:** `~/.claude/plugins/marketplaces/jodre11-plugins`
(autoUpdate-managed marketplace clone; remote `Jodre11/claude-code-plugins`;
base `main`, currently at `6207689`). **PUSH after EVERY commit** — a prior
autoUpdate reclone wiped an unpushed branch. Direct-push to `main` is the
established workflow (branch-protection bypass is expected; no PR required).

**House rules (operator global CLAUDE.md — enforce on every Bash call you and
subagents issue; they do NOT govern code written into files):**
- NO compound shell (`&&`, `||`, `;`), NO `$(...)`/backticks, NO pipes/subshells
  in a single Bash call — separate calls. A single `> file 2>&1` redirect is
  allowed; a lone `grep`/`jq`/`yq`/`awk` with no pipe is allowed. Carve-out:
  `git commit` HEREDOC for literal multi-line bodies.
- 4-space shell indent, LF endings. Commit messages: no Co-Authored-By, no Claude
  advertising. `git add` specific paths only (never `-A` / `.`).
- Verify before claiming done: run `bash tests/run.sh`; **baseline is 342 passed
  / 1 skipped** (after PR C added one test). The suite has a known dirty-tree
  artifact: the test `A/B run.sh: bad-config rejection leaves working tree clean`
  runs `git diff --quiet` over the whole repo, so it FALSE-FAILS whenever you
  have uncommitted changes. Commit, then re-run clean to confirm 342/1.
- Live A/B sweeps spend real Bedrock. Per-trial costs observed: Sonnet/default
  ~$0.14, Haiku/low ~$0.06 (list price, not Bedrock — report RATIOS). A 2×20
  matched pair ≈ $4 list / ~25 min wall. **Do all offline work first, then STOP
  and ask the operator for explicit go-ahead before any live capture/sweep.**

## Start by reading (in order)

1. **Memory** (in the `~/.claude` repo, not this clone):
   `projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/project_phase_3_2b_pr_b_reprobe.md`
   — full PR B + PR C context, the validation result, and the held-flip open
   question. Plus `..._worked_example_gap.md` (why trivy/jbinspect first-capture
   parses to zero tuples) and `..._phase_3_2b_pr_a_apparatus_fix.md` (the
   `setup:` provisioning primitive, designed to pre-solve trivy/jbinspect).
2. **Result note (source of truth for PR B/C):**
   `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md`.
3. **Parent programme spec:**
   `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md` — the
   verdict framework (EQUIVALENT / INCONCLUSIVE-decision-4 / WORSE >25 %), the
   class taxonomy, and the per-specialist methodology. **This is the template
   for the trivy/jbinspect probes.**
4. **The eslint phase as a worked example of the whole loop:** the 3.2b plan
   `docs/superpowers/plans/2026-06-03-phase-3-2b-pr-b-reprobe.md` and PR A plan
   `docs/superpowers/plans/2026-06-02-phase-3-2b-pr-a-apparatus-fix.md`.

## What is ALREADY DONE (do NOT redo)

- **ruff:** Phase 3.1b verdict EQUIVALENT, Haiku/low 20/20. A/B complete; nothing
  owed beyond the production flip (below).
- **eslint:** PR B re-probe (Sonnet 20/20, Haiku 17/20, INCONCLUSIVE) + PR C
  (tier-1 resolution fix C-1 `36e304b` + parser skip-sentinel widening C-2
  `56844cd`). Post-fix validation: **Haiku/low 20/20, zero skips**. Cost ratio
  2.17×. eslint A/B is COMPLETE.
- **Cost capture infrastructure:** `summary.csv` now carries per-trial
  `output_tokens, num_turns, cache_read_input_tokens, total_cost_usd` (cols
  9–12) via `agent_capture_extract_cost_csv` in `agent_capture.sh`. Works for ALL
  per-agent runs — trivy/jbinspect get cost capture for free.
- **The `setup:` fixture primitive** (PR A): `source.yaml` `setup.command` runs
  once into a provisioned template, then each trial `cp -R`s a hermetic working
  dir. Use it for any trivy/jbinspect provisioning. ruff/eslint precedents exist.

---

## PIECE 1 — production `model:` flip for eslint + ruff (do this FIRST)

**Status:** decided by the operator (switch both to Haiku), but HELD this session
for a real reason. Resolve the blocker, then flip.

**The blocker:** the A/B validated `model: haiku` + `effort: low`. But the
production agent frontmatter (`plugins/code-review-suite/agents/*-reviewer.md`)
carries ONLY a `model:` field — **there is no `effort:` field** in that schema
(grep confirmed: all four specialists have `model: sonnet`, none has `effort`).
In the A/B, effort is set per-trial by the harness *session*, not by the agent
definition. So flipping `model: haiku` alone does NOT reproduce the validated
`haiku`/`low` config — the effort dimension would be unexpressed / defaulted.

**Your job for Piece 1:**
1. Determine how a Claude Code agent definition expresses (or inherits) reasoning
   effort. Options to investigate: is `effort:` a supported-but-undocumented
   frontmatter key? Is effort inherited from the dispatching session / the
   orchestrator? Is it set in plugin settings? Use the `claude-code-guide` agent
   or Claude Code docs — do NOT guess. The operator's global CLAUDE.md
   "Don't guess" rule applies.
2. Once you know how effort is expressed in production, flip **both eslint AND
   ruff** to the validated config (`haiku` + whatever expresses `low`), in one
   small commit per the operator's repo-housekeeping norms. If effort genuinely
   cannot be expressed per-agent, bring that finding to the operator with options
   (e.g. accept Haiku at default effort — but note that's UNTESTED; the spec
   explicitly says Haiku/default is "never a production cost-tuning candidate"
   except diagnostically) rather than flipping blind.
3. The flip is a production-behaviour change to the live review specialists —
   confirm with the operator before pushing if there's any ambiguity about the
   effort mapping.

**Do NOT flip `model:` until the effort question is resolved.** A flip that
silently runs at the wrong effort ships an unvalidated config.

---

## PIECE 2 — trivy + jbinspect A/B baselines

**Operator intent:** run the FULL matched 2×20 A/B pair (Sonnet/default baseline
vs Haiku/low) for EACH of trivy and jbinspect — NOT the Haiku-only shortcut used
for eslint's PR C validation. Reason: these have zero prior data, so you want the
matched pair to establish the baseline cleanly the first time. The operator's
hypothesis is that Haiku/low wins across all four static specialists; trivy is the
one to least assume (richer structured output).

**This is per-specialist groundwork, then a probe — closer to a phase than a
quick run. Each specialist needs, BEFORE any sweep:**

### 2a. Corpus fixture with known violations + provisioning
- `tests/fixtures/static-analysis/<tool>/` — the input the tool scans.
  - **trivy:** `tests/fixtures/static-analysis/trivy/Dockerfile` ALREADY EXISTS
    but is too trivial (`FROM alpine:latest` + `RUN echo "hello"`) to yield
    stable `trivy config` IaC findings. `trivy config` scans for IaC
    misconfigurations — beef the Dockerfile (and/or add Terraform/k8s) up to a
    known, stable finding set (e.g. missing USER, no healthcheck, latest tag).
    trivy is GLOBAL on PATH (`trivy --version`, like ruff) — so it should ESCAPE
    the node_modules resolution issue eslint had; likely no `setup:` needed, but
    confirm trivy is installed on the host first.
  - **jbinspect:** needs a C#/.NET fixture project that JetBrains InspectCode can
    scan, plus provisioning (InspectCode is heavier — confirm the tool is
    available and how it's invoked; jbinspect uses a CamelCase rule-ID tokeniser,
    different from the kebab-case ruff/eslint share).
- `tests/ab/corpus/<id>/source.yaml` — fixture metadata (copy the eslint/ruff
  shape: `id`, `agent`, `captured_under`, `working_dir_strategy`, optional
  `setup.command`, `baseline_revision`, `intent_ledger`, `depends_on`).
- `tests/ab/corpus/<id>/expected/findings-<tool>.md` — promoted baseline (see 2c).
- Add the fixture to `tests/ab/corpus/index.yaml`.

### 2b. Parser-dispatch case (NEITHER tool is in the table yet — confirmed)
`tests/ab/lib/agent_capture.sh` `_agent_capture_params()` has cases for `ruff`
and `eslint` only. Add a case for each new tool: `_AC_HEADING` (anchored findings
heading), `_AC_SKIP` (ERE, matched via `grep -qE` — make it tolerant of
phrasing paraphrases per the PR C-2 lesson), `_AC_ZERO` (zero-state line). The
rule-ID tokeniser (split on `[ \t(]`, take token 1) is currently shared and
assumes no internal spaces — **jbinspect's CamelCase IDs are fine, but VERIFY
trivy's CVE/AVD namespace IDs tokenise correctly** (e.g. `AVD-DS-0002`,
`CVE-2023-1234`); they may need a tokeniser tweak. TDD any parser change with a
captured-output fixture, per the ruff/eslint test precedents in
`tests/lib/test_ab_per_agent_lib.sh`.

### 2c. Live-captured worked example (do NOT pre-author blind)
`grep "Worked example"` matches only ruff + eslint. trivy-reviewer.md and
jbinspect-reviewer.md have NONE → **first capture will parse to zero tuples** (the
[[worked-example-gap]] failure mode). The discipline (from 3.2/3.1c): capture ONE
live Sonnet/default trial, see how the agent actually lays out §7, then pin a
worked example into the agent body matching the real shape (do not invent it).
trivy has dual CVE/AVD namespaces and jbinspect a CamelCase tokeniser, so each
needs its OWN captured example. This capture-then-pin step is itself a small
Bedrock spend — gate it.

### 2d. Configs
`tests/ab/configs/per-agent/<tool>-baseline.yaml` (sonnet/default) and
`<tool>-haiku-low.yaml` (haiku/low) — copy the eslint config shape exactly.

### 2e. Then the probe (gated)
Correct invocation (the spec / old plans had a non-existent `--mode` flag; mode is
config-derived from `mode: per-agent`):
```
bash tests/ab/run.sh --config <cfg> --corpus <id> --trials 20 --stream-json
```
Run both arms at n=20, apply the verdict framework, write a result note at
`docs/superpowers/notes/2026-..-<tool>-haiku-low-result.md`, update memory. If a
real agent-side tail survives a clean apparatus (as eslint's did), characterise
it and bring it to the operator — do NOT pre-author a fix (the tuning-to-the-test
guard: never edit the prompt then re-run the same fixture until green; a fix must
be a general correctness improvement and earn its own before/after at n=20).

**Suggested order:** trivy first (global-on-PATH, lighter setup, existing if-trivial
fixture), jbinspect second (heavier .NET provisioning). Do trivy end-to-end as a
worked example before starting jbinspect.

## Method

Use `superpowers:writing-plans` to turn Piece 2 (per specialist) into a task plan,
then `superpowers:subagent-driven-development` (fresh subagent per task, two-stage
review between). When dispatching agents set `mode:"auto"` and a unique kebab-case
name. Pass the resolved `CLAUDE_TEMP_DIR` literal into each subagent prompt (the
SessionStart hook injects it into your context; it is NOT exported into the Bash
shell). Gate every live capture/sweep on operator go-ahead.

## Larger deferred initiative (NOT this handover)

The operator is considering converting the code-review orchestrator to a
deterministic Workflow with schema-validated specialist output — which would
dissolve the entire markdown-parse apparatus (the §7 worked-example fragility AND
the skip-sentinel brittleness fixed piecemeal in PR C-2). That is a separate
future initiative; start it from `superpowers:brainstorming` if taken up. See
[[phase-3-2b-pr-a-apparatus-fix]] and [[worked-example-gap]] in memory.
