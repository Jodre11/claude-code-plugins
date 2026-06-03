# Handover — Phase 3.2b PR B: clean eslint cost-tuning re-probe

**Date:** 2026-06-03
**Predecessor:** Phase 3.2b PR A (apparatus fixes) — SHIPPED + verified this session.
**This handover:** execute PR B (the clean re-probe + result note). No PR B plan exists
yet — only the spec. Build the plan, then execute.

---

## Task

Execute Phase 3.2b PR B — the clean eslint cost-tuning re-probe — for the per-agent
A/B harness.

**REPO:** `~/.claude/plugins/marketplaces/jodre11-plugins`
(autoUpdate-managed marketplace clone; remote `Jodre11/claude-code-plugins`; base
`main`, currently at `fe321af`). PUSH after EVERY commit — a prior autoUpdate reclone
wiped an unpushed branch. Never leave work unpushed here. Direct-push to `main` is the
established workflow (branch-protection bypass is expected; no PR required).

## Start by reading (in order)

1. **Memory:**
   `projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/project_phase_3_2b_pr_a_apparatus_fix.md`
   — full context for why PR A happened and what the two now-fixed apparatus confounds
   were. (This memory lives in the `~/.claude` repo, not the marketplace clone.)
2. **Spec (source of truth):**
   `docs/superpowers/specs/2026-06-02-phase-3-2b-eslint-apparatus-and-reprobe-design.md`
   — read the whole "PR B — clean re-probe + result note" section (B1–B5) and
   "Verifications".
3. **The PR A plan** (for harness mechanics + house-rule precedents):
   `docs/superpowers/plans/2026-06-02-phase-3-2b-pr-a-apparatus-fix.md`

## What is ALREADY DONE (do NOT redo)

PR A shipped both apparatus fixes and they are verified:

- **Install-race fix** (commits `7cb0ee6`, `e90d213`, `d96ce64`, `20f163b`): per-trial
  hermetic working dirs via a `setup: { command: npm ci }` fixture key + template /
  `cp -R` isolation in `run.sh`. Live-verified 20/20, zero npm installs.
- **Capture fix** (commit `fe321af`): `launch_jq_reduce_stream_jsonl` now reconstructs
  stdout by concatenating ALL assistant text blocks and no longer trusts terminal
  `.result` (which dropped reports when the agent did post-report temp-file cleanup —
  the trial-8/10 false-zeros). Unit-tested.

The harness is therefore CLEAN for a re-probe — neither the install race nor the
capture drop will recur. **Test suite baseline: 339 passed / 1 skipped.**

## PR B deliverables (from the spec, B1–B5)

- **B1. Re-establish the Sonnet/default baseline ON THE FIXED HARNESS.** The Phase 3.2
  n=3 baseline and its canonical hash are DISCARDED (captured on the contaminated
  apparatus). Do ONE Sonnet/default capture, hand-verify against `eslint --format=json`
  (conforms to §7; covers all 4 rules — no-var, prefer-const, no-unused-vars, eqeqeq on
  `bad.js` lines 1/2/3/6; fabricates none), then promote it to
  `tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md`. Bump `source.yaml`
  `baseline_revision` and `captured_under.suite_sha`.
- **B2. Run BOTH arms at n=20** on the fixed harness:
  - `eslint-baseline.yaml` (Sonnet/default) — re-captured.
  - `eslint-haiku-low.yaml` (Haiku/low) — config unchanged.
- **B3. Capture per-trial COST metrics** (the programme's actual deliverable, which 3.2
  omitted). Extend `summary.csv` with per-trial `output_tokens`, `num_turns`,
  `cache_read_input_tokens`, `total_cost_usd`. Field names VERIFIED against a real
  stream.jsonl result envelope: `total_cost_usd`, `usage.output_tokens`, `num_turns`,
  `usage.cache_read_input_tokens`. Do NOT transcribe blind — confirm against an actual
  trial's stream.jsonl first. **Caveat to record:** the CC stream's `total_cost_usd` is
  Anthropic LIST price, not Bedrock — report the RATIO, not the absolute dollars.
- **B4. Verdict** (parent-spec framework, verbatim):
  - Both arms 20/20 identical canonical hash → **EQUIVALENT**.
  - Mixed within-arm hashes → **INCONCLUSIVE** (decision-4), then characterise the
    residual.
  - >25% NORMAL-rate movement → **WORSE**, with recall-direction analysis (misses vs
    fabrications).
- **B5. Result note** at
  `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md`, superseding
  (cross-linked, not deleting) the 3.2 note. Report the verdict AND the measured
  Bedrock cost-delta ratio. Then update memory.

## CRITICAL GATE — PR B SPENDS REAL BEDROCK

B1 capture + 2×20 sweeps ≈ 3× a single-arm sweep. Do all OFFLINE work first:
- Write the plan.
- Implement the `summary.csv` cost-column extension (in `agent_capture.sh` /
  `run.sh`'s `_ab_append_per_agent_summary_row`) with TDD, verifying against EXISTING
  trial `stream.jsonl` files under `tests/ab/runs/` WITHOUT new spend.

Then **STOP and ask the operator for explicit go-ahead before running ANY live capture
or sweep (B1, B2)**. Present the estimated trial count before each live step.

## Correct harness invocation

The spec / PR-A-plan command had a non-existent `--mode` flag; mode is config-derived
from the config's `mode: per-agent`. Correct form:
```
bash tests/ab/run.sh --config <cfg> --corpus eslint-smoke-bad-js --trials 20 --stream-json
```
Existing per-agent run dirs live under `tests/ab/runs/` (gitignored) — e.g.
`20260603T061349Z-eslint-haiku-low` is the PR A verification sweep you can mine for
cost-field shapes and as a Haiku/low data point (but the spec wants a fresh matched
pair, so re-run both arms).

## Method

There is NO PR B implementation plan yet — only the spec. FIRST use the
`superpowers:writing-plans` skill to turn B1–B5 into a task plan, then execute it with
`superpowers:subagent-driven-development` (fresh subagent per task, review between).
When dispatching agents set `mode:"auto"` and a unique kebab-case name. Pass the
resolved `CLAUDE_TEMP_DIR` literal into each subagent prompt (the SessionStart hook
injects it into your context; it is NOT exported into the Bash shell).

## House rules (operator global CLAUDE.md — enforce on every Bash call you and subagents issue; they do NOT govern code written into files)

- NO compound shell (`&&`, `||`, `;`), NO `$(...)`/backticks, NO pipes/subshells in a
  single Bash call — separate calls. A single `> file 2>&1` redirect is allowed; a lone
  `grep` with no pipe is allowed. Carve-out: `git commit` / `gh` HEREDOC for literal
  multi-line bodies.
- 4-space shell indent, LF endings. Commit messages: no Co-Authored-By, no Claude
  advertising. `git add` specific paths only (never `-A` / `.`).
- Verify before claiming done: run `bash tests/run.sh`; baseline is 339 passed /
  1 skipped — expect that plus any new cost-column test assertions.

## Tuning-to-the-test guard

This is a MEASUREMENT, not a tuning exercise. Do NOT edit any `*-reviewer.md` body or
any config `model`/`effort` field in PR B. If a genuine agent-side tail survives the
clean apparatus (the candidate is the §7 structured-output drop), that is **PR C** —
gated on operator approval, authored only after PR B's numbers are in. Bring the
residual-tail numbers to the operator; do not pre-author a fix.

## Larger deferred initiative (NOT PR B, NOT PR C)

The operator is considering converting the code-review orchestrator to a deterministic
Workflow with schema-validated specialist output (which would dissolve the whole
markdown-parse apparatus, including the §7 worked-example fragility). That is a separate
future initiative — do not fold it into PR B. When it is taken up, start from the
`superpowers:brainstorming` skill. See memory `project_phase_3_2b_pr_a_apparatus_fix.md`
and `project_worked_example_gap.md` for context.
