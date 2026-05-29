# Handover: Phase 3.1a — empty-stdout investigation

**Author of this handover:** Christian (via session of 2026-05-29).
**Audience:** A fresh Claude Code session executing Phase 3.1a with no prior
context.
**Purpose:** Bootstrap execution of the empty-stdout reproduction probe
on the per-agent codepath, with the smallest possible context budget.

---

## TL;DR for the receiving session

Phase 3.1 of the per-agent A/B harness was abandoned-for-cause on 2026-05-29.
A 3-trial probe of `ruff-reviewer` at Haiku/low against the smoke fixture
hit two distinct apparatus problems: format drift (Haiku produces
semantically-correct findings in surface formats the parser cannot consume)
and a recurrence of the empty-stdout anomaly (1/3 trials returned rc=0
with stdout="\n", same shape as Phase 1 Trial 2 in 2026-05). Combined
incidence across both observations is now 2/9 = ~22% with wide CI.

Phase 3.1a is the cheapest possible characterisation of the empty-stdout
noise floor: a 20-trial sweep at Haiku/low against the existing
`ruff-smoke-bad-py` fixture, with `claude -p --output-format stream-json`
so the per-event tool-use trace is captured for any occurrence. No
production agent edits, no orchestrator-level fixes, no parser changes.

The Phase 3.1a spec and plan are both locked. Your job is to:

1. Read the artefacts below.
2. Execute the plan via `superpowers:subagent-driven-development`.
3. Stop at the operator review gate when the 20-trial sweep completes,
   surface the headline number + classification, and wait for adoption
   confirmation before writing the report.
4. Open the carrier PR (PR title encodes the verdict).

The session that produced this handover **does not want you to relitigate**:

- The Phase 3.1a methodology (locked in
  `docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md`).
- The decision to use per-agent / Haiku/low / `ruff-smoke-bad-py` as the
  cheap reproduction substrate (locked).
- The decision to scope 3.1a as "characterise, not fix" (locked; fix
  surface lives in Phase 3.1c, not yet brainstormed).
- Whether to run a brainstorming round (no — done in the producing session).
- Whether to run a housekeeping audit (no — Phase 3.1's housekeeping
  audit was no-op on 2026-05-29 and remains so).

---

## What you must read before responding

Read in this order. None of these will be in your context.

1. **CLAUDE.md** at `~/.claude/CLAUDE.md` (operator's global) and at
   `~/.claude/plugins/marketplaces/jodre11-plugins/CLAUDE.md` (project-local).
   Vocabulary; Bash conventions (no compound commands, no `$(...)` outside
   the HEREDOC carve-outs); agent-dispatch conventions (always
   `mode: "auto"`, always `name`); auto-memory protocol.

2. **Phase 3.1a spec** (the document you are implementing):
   `docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md`.
   Methodology, classification rules (EMPTY / DRIFT / NORMAL / OTHER),
   stream-json trace categories (A / B / C / D), outcome-table mapping.

3. **Phase 3.1a plan** (the implementation transcript):
   `docs/superpowers/plans/2026-05-29-empty-stdout-investigation-plan.md`.
   Eight tasks; explicit operator review gate after Task 4 (the
   classification + trace inspection); ~50–100k Bedrock tokens total.

4. **Original anomaly spec** (the seed observation):
   `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md`.
   Phase 1 Trial 2 forensic record; hypothesis space; "What we SHOULD do"
   §1–5 actions. 3.1a executes §1+§2 + §5 on the cheap substrate.

5. **Phase 3.1 plan** (abandoned-for-cause; informs the reframe):
   `docs/superpowers/plans/2026-05-29-static-specialist-tuning-ruff-plan.md`.
   Skim the "What you must NOT do" section in particular.

6. **Phase 3.1 abandoned-for-cause run dir** (gitignored, on local disk):
   `tests/ab/runs/20260529T144359Z-ruff-haiku-low/`. Trial-003 of that run
   is the precipitating second empty-stdout observation. Stream-json was
   NOT enabled for that run, so its trace is in category D (inconclusive).

7. **Per-agent harness usage and three load-bearing implementation notes:**
   `tests/ab/README.md` § "Per-agent mode (Phase 2)".

8. **Auto-memory entries** (loaded automatically into your session):
   - `feedback_models_overlook_tuning_hooks` — variation flows externally
     via the harness; no runtime hooks on production agents.
   - `feedback_claudemd_compliance` — read before any Bash tool call.
   - `project_orchestrator_empty_stdout_anomaly` — the issue 3.1a is
     under investigation for; status flips to "Investigated" at Task 6.
   - `project_phase_3_1_ruff_haiku_low_probe` (if present) — the
     precipitating Phase 3.1 result.

---

## What "Phase 3.1a" means specifically

Single PR. Single fixture. Single arm. Single anomaly under investigation.

**Headline question:** what is the empty-stdout incidence rate at Haiku/low
on the per-agent codepath (Wilson 95% CI), and what does the stream-json
trace at the moment of non-emission tell us about probable cause?

**Substrate is reused, not new.**
- `tests/ab/configs/per-agent/ruff-haiku-low.yaml` already exists from
  Phase 3.1's Task 2 (commit `56b94a12` on this branch).
- `tests/ab/corpus/ruff-smoke-bad-py/` already exists from Phase 2 / 2b.
- The Phase 3.1 abandoned-for-cause run dir is preserved as exhibit A.

**Cost:** ~5k tokens for empirical CLI grounding (Task 1) + ~5–8k for the
two smoke trials (Task 2 Steps 7 + 8) + ~50–100k for the 20-trial sweep
(Task 3) + ~10k for operator review across the gate. Total ~75–125k
Bedrock tokens.

**Expected outcome shapes:**
- ≥3 EMPTY in 20 (15%+ rate) → Bug confirmed reliably; named fix surface
  in the report unblocks Phase 3.1c.
- 1-2 EMPTY in 20 (5–10% rate) → Bug confirmed at low rate; trace
  inspection narrows hypothesis space; 3.1c proceeds.
- 0 EMPTY in 20 → Bug not reliably reproducible at N=20; ≤16% upper
  bound at 95% CI is documented as the noise floor; programme proceeds
  but every future probe must be ≥5 trials per arm to absorb noise.

**Phase 3.1a is forensic work, not production code work.** Apart from the
small `--stream-json` harness extension, no production behaviour changes.

---

## What the Phase 3.1a plan must cover

The spec is methodologically prescriptive. The plan is the operational
transcription. The 8 tasks are:

1. **Empirically ground `--output-format stream-json`** — capture the
   exact CLI flag spelling, the JSONL event schema, and verify whether
   final-text-only stdout still flows on the same channel when stream-json
   is on. ~5k tokens, no tracked-file changes. Per the Phase 2 plan-defect
   note (Task 6 closeout), authoring CLI plumbing against a hypothetical
   flag form silently breaks; ground first.

2. **TDD plumbing** — one structural test that `--stream-json` is recognised
   by `run.sh`'s `--help`; modify `run.sh`, `lib/launch.sh`,
   `lib/agent_dispatch.sh` so the flag opt-in propagates to `claude -p`
   and the JSONL trace lands at `trial-NNN/stream.jsonl`. Reconstruct
   `trial-NNN/stdout.log` from text deltas so existing parsers and the
   faithfulness check are bit-identical when the flag is absent.

3. **20-trial sweep** at Haiku/low against `ruff-smoke-bad-py` with
   `--stream-json`. Same cost-aware stop-and-investigate rules as Phase
   2b's Task 9 Step 6: any INCONCLUSIVE / non-zero-from-claude-itself /
   harness crash halts the run. EMPTY occurrences DO NOT halt — they are
   the SIGNAL.

4. **Per-trial classification + stream-json trace inspection.** Apply the
   four-class detection rules (EMPTY / DRIFT / NORMAL / OTHER) and the
   four-category trace rules (A / B / C / D). Compute Wilson 95% CI for
   the EMPTY incidence. Save the consolidated analysis to
   `${CLAUDE_TEMP_DIR}/analysis.md`.

5. **Stop at an operator review gate** with the trial outcomes (incidence,
   CI, category breakdown, per-EMPTY trace summary) before writing the
   committed report. The plan's Task 4 is the natural pause point; do
   NOT proceed to Task 5 (the report) without surfacing.

6. **Write the one-page report** at
   `docs/superpowers/notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md`.
   Skeleton in Task 5 Step 2 of the plan; substitute all `<placeholder>`
   strings with real values.

7. **Update the original anomaly spec** to flip status from "Open" to
   "Investigated" with a pointer to the report. Original hypothesis
   space and forensic record stay intact.

8. **Open the carrier PR** with a verdict-shaped title. Watch CI green;
   merge when operator says.

9. **Auto-memory entries** in `~/.claude/projects/.../memory/`. Out of
   scope for the marketplace PR but record the verdict so Phases 3.1b /
   3.2 / 3.3 / 3.4 inherit the noise floor.

---

## What you must NOT do

- **Do not extend Phase 3.1a to fix the bug.** Phase 3.1a is "characterise,
  not fix". The fix lives in Phase 3.1c (cross-cutting "tighten contracts
  + fail-loud") or in an upstream Claude Code / Bedrock issue. 3.1a names
  the recommended fix surface; that's it.
- **Do not extend Phase 3.1a to address the format-drift problem.** Phase
  3.1's trial-001 + trial-002 emitted F401 in two different surface formats
  the parser couldn't consume. That is the explicit subject of Phase 3.1c,
  not 3.1a. DRIFT count is INCIDENTAL data captured in Task 4 Step 1; the
  report's headline is EMPTY incidence only.
- **Do not modify the parser at `lib/agent_capture.sh`** to be more
  tolerant of format drift. Same reason: 3.1c work.
- **Do not add a structural-test-time empty-stdout-with-rc-0 assertion to
  the harness.** Same reason: 3.1c work. The `--stream-json` flag is
  forensic capture infrastructure, NOT the validate-or-die layer.
- **Do not modify production agent files.**
  `plugins/code-review-suite/agents/ruff-reviewer.md` stays at
  `model: sonnet`. Same for the other static specialists.
- **Do not extend the sweep to other specialists / fixtures / arms.** All
  20 trials are Haiku/low against `ruff-smoke-bad-py`. Cross-specialist
  / cross-arm questions are 3.1b's concern.
- **Do not run end-to-end mode reproduction.** Per-agent is the cheap
  substrate; end-to-end at ≥10 trials per arm is the original
  2026-05-21 spec's §1+§2 work and would cost ~5M tokens.
- **Do not retry empty-stdout occurrences.** They are the signal. The
  loop continues to N=20 regardless of how many EMPTY occur.
- **Do not skip the operator review gate** before writing the committed
  report. The report's recommended fix surface is load-bearing for Phase
  3.1c; the operator confirms the framing first.

---

## Plan-defect patterns from earlier phases to NOT repeat

Phase 1 + Phase 2 + Phase 3.1 surfaced eight plan-defect-correction
patterns. Phase 3.1a's surface is small but watch for:

1. **Empirically ground anything CLI-flag-shaped against a live trace
   before transcribing.** Phase 2's parser was authored against a fictional
   plain `Field: value` format; the canonical contract uses bold-markdown
   bullets; the first live trial revealed the divergence. Phase 3.1a's
   `--output-format stream-json` flag and JSONL event schema MUST be
   confirmed at Task 1 Step 1 before plumbing.

2. **`rc=$(...)` patterns under `set -euo pipefail` need `set +e` inside
   the subshell** to capture non-zero return codes without aborting. The
   canonical pattern is at `tests/lib/test_ab_harness.sh:597-603`.

3. **`pass`/`fail` calls inside `(...)` subshells lose counter mutations.**
   Hoist assertions to the outer frame; capture data into tmpfiles inside
   the subshell. Pattern at `tests/lib/test_ab_per_agent_lib.sh:457`.

4. **Bash `RETURN` traps persist across function returns.** Use explicit
   cleanup over `trap … RETURN` for scratch-file removal inside helpers.

5. **The state-dependent `bad-config rejection leaves working tree clean`
   test is NOT a real failure** — it triggers during dirty-tree windows
   mid-iteration and passes at clean HEAD. If you see it fail mid-execution,
   commit your work-in-progress and re-run; don't waste a fix-up cycle.

6. **Always flag plan-text defects to the operator before changing the
   plan.** If the spec or the plan contradicts what you observe, the
   operator decides whether the spec is wrong or the implementation is.

7. **The `--effort` flag does not accept `default` as a value.** The
   harness handles this by omitting the flag entirely when the config says
   `default` or empty. The `--stream-json` plumbing must compose with this
   conditional — Task 2 Step 5 builds a `local -a extra_flags` array to
   keep the four-way conditional manageable.

8. **Phase 3.1's lesson: a 3-trial faithfulness check cannot tell apart
   "real divergence" from "anomaly noise" when the noise floor is high.**
   Phase 3.1a's whole purpose is to characterise the noise floor so future
   probes can size their trial counts correctly.

---

## Repository state at handover time

- **Branch:** `feat/per-agent-tuning-ruff-haiku-low`. Carries:
  - `tests/ab/configs/per-agent/ruff-haiku-low.yaml` + structural test
    (commit `56b94a12`, Phase 3.1's Task 2).
  - `docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md`
    (the spec).
  - `docs/superpowers/plans/2026-05-29-empty-stdout-investigation-plan.md`
    (the plan).
  - This handover.
- **Working tree at handover:** clean apart from the docs being committed
  in this session.
- **Tests:** 298 tests, 297 passed, 1 skipped, 0 failed (after Phase 3.1
  Task 2's structural test).
- **Phase 3.1 abandoned-for-cause run dir preserved at:**
  `tests/ab/runs/20260529T144359Z-ruff-haiku-low/` (gitignored). Trial-003
  has the empty-stdout occurrence; trials-001/002 have the format-drift
  occurrences.
- **Phase 1 forensic record at:**
  `tests/ab/runs/20260521T162805Z-no-ultrathink/` (gitignored). Trial-002
  is the original empty-stdout observation. No stream-json (predates 3.1a).

---

## Cost expectations

- Plan execution: ~30 min Claude wall-clock per task, ~3 hours total
  including operator review.
- Operator review at the gate: ~10 min.
- Phase 3.1a Bedrock cost:
  - Task 1 (empirical grounding probe): ~5k tokens.
  - Task 2 Steps 7+8 (two smoke trials): ~5–8k tokens.
  - Task 3 (20-trial sweep): ~50–100k tokens.
  - Tasks 4–8 (offline analysis, report, PR): $0 additional Bedrock.
- Total: ~60–115k Bedrock tokens, ~1.5–2 hours wall-clock.

---

## What to do first

1. Greet the operator. Confirm they want to proceed with Phase 3.1a
   as scoped. Mention the housekeeping audit was no-op as of 2026-05-29.
2. Read the artefacts in the order listed above.
3. Invoke `superpowers:subagent-driven-development`.
4. Execute Tasks 1–4. Surface for operator approval after Task 4.
5. Once approved, execute Tasks 5–8.

---

## End of handover

Stop reading and start by greeting the operator. The first action after
greeting is reading the spec.
