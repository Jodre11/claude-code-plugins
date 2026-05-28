# Handover: Per-agent A/B harness — Phase 2 (planning continuation)

**Author of this handover:** Christian (via session of 2026-05-22 / 2026-05-25).
**Audience:** A fresh Claude Code session continuing Phase 2 planning with no prior context.
**Purpose:** Bootstrap the user-review-gate → writing-plans → implementation handoff
without re-litigating brainstorming decisions already locked.

---

## TL;DR for the receiving session

Brainstorming for Phase 2 is **complete**. The Phase 2 design spec is written and saved
to `docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md`. Seven design
questions were resolved with the operator and are recorded below — **do not re-open
them.** If you find yourself wanting to relitigate one of them, ask the operator first.

The session that produced this handover stopped at the **user-review gate** of the
brainstorming workflow. The immediate next steps are:

1. Read the spec (and the prior handover, the Phase 1 spec, and the Phase 2 direction
   spec).
2. Ask the operator if the spec is approved as-is or needs changes.
3. If approved, invoke the `superpowers:writing-plans` skill to produce the Phase 2
   implementation plan at
   `docs/superpowers/plans/YYYY-MM-DD-per-agent-harness-phase-2-plan.md`.
4. After the plan is approved, the operator will dispatch via
   `superpowers:subagent-driven-development` (same execution shape Phase 1 used).

The session that produced this handover **does not want you to start coding** and
**does not want you to dispatch any Bedrock-touching trials**.

---

## What you must read before responding

Read in this order. None of these will be in your context — open and read each file
before doing anything else.

1. **CLAUDE.md** at `~/.claude/CLAUDE.md` (operator's global) and at
   `~/.claude/plugins/marketplaces/jodre11-plugins/CLAUDE.md` (project-local). Vocabulary,
   Bash conventions (no compound commands, no `$(...)` outside HEREDOC carve-outs), and
   the auto-memory protocol live there.

2. **The Phase 2 design spec** (the document you're going to walk through with the
   operator):
   `docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md`.

3. **The prior handover** (architectural context that prompted Phase 2):
   `docs/superpowers/handover/2026-05-22-per-agent-harness-phase-2.md`.

4. **Phase 1 design spec** (architectural baseline; the Phase 2 spec extends rather than
   replaces it):
   `docs/superpowers/specs/2026-05-21-ab-test-harness-design.md`.

5. **Phase 2 direction spec** (the framing that motivated the per-agent pivot):
   `docs/superpowers/specs/2026-05-21-per-agent-testing-direction.md`.

6. **Phase 1 plan** (worked example of the right level of detail for the upcoming
   Phase 2 plan):
   `docs/superpowers/plans/2026-05-21-ab-test-harness-phase-1-plan.md`.

7. **Sister follow-up specs** (do not implement these — they are the questions per-agent
   testing eventually answers, but they're explicitly out of Phase 2 scope as defined in
   this slice):
    - `docs/superpowers/specs/2026-05-21-rubric-row-stability-followup.md`
    - `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md`

8. **Auto-memory entries** (loaded automatically into your session) — `MEMORY.md` indexes
   them, but particularly:
    - `feedback_models_overlook_tuning_hooks` — the suite stays unaware it is being
      tested. No env vars or extension points the suite must consult.
    - `feedback_claudemd_compliance` — read this before any Bash tool call.
    - `project_rubric_row2_stability` and `project_orchestrator_empty_stdout_anomaly` —
      open issues; do not address them inside Phase 2.

---

## Brainstorming decisions already locked — do NOT re-open

These were resolved with the operator on 2026-05-22 via the
`superpowers:brainstorming` skill. They are baked into the spec. If you want to change
one, ask the operator explicitly first.

| # | Question | Decision |
|---|---|---|
| 1 | How does a per-agent dispatch get the agent's full system prompt? | **Reconstruct.** Strip frontmatter from the agent file, use the body as `--append-system-prompt`. Validate with a faithfulness check against captured fixtures. |
| 2 | Test agents individually or in pairs? | **Layered freeze + drift detector.** Tune one agent against fixed fixtures; fingerprint output and warn if it drifts from fixtures. (Drift detector is deferred for the narrowed slice — no downstream agents in scope.) |
| 3 | Corpus shape? | **Dir-per-fixture + index.yaml + provenance + Phase-3 hole for seeded bugs.** |
| 4 | Fixture decay handling? | **Detect (warn-only) + manual refresh workflow.** No refresh subcommand in Phase 2. |
| 5 | Seed initial corpus? | **Scavenge surviving Phase 1 `/tmp/claude-*` dirs first, then assess.** (Note: deferred for the narrowed slice — Phase 1's corpus PR #29 produced no static-analysis findings, so nothing to scavenge for ruff.) |
| 6 | Build order? | **Specialist → cross-reviewer → synthesiser.** (Narrowed further to *only the static-analysis specialist `ruff-reviewer`* — see below.) |
| 7 | Mutation primitives? | **CLI/prompt only — no in-tree mutation.** Per-agent mode never edits tracked files; Phase 1's mutate-and-revert is preserved for end-to-end mode. |

### The major narrowing the operator requested mid-brainstorming

The original Phase 2 scope (specialists → cross-reviewers → synthesiser) is **too broad**.
The operator narrowed Phase 2 to **`ruff-reviewer` only**, with this rationale:

- The four static-analysis specialists (`jbinspect`, `eslint`, `ruff`, `trivy`) are
  excluded from cross-review — they have no specialist upstream and no cross-reviewer
  downstream. Most testable-in-isolation slice in the suite.
- `ruff-reviewer` is the cheapest to fixture: there is already an in-tree synthetic smoke
  fixture at `tests/fixtures/static-analysis/ruff/`.
- `jbinspect` was considered first by the operator but rejected because: no in-tree smoke
  fixture exists, and real fixtures would need to come from work repos
  (Haven Engineering) which would import org-specific IP into the marketplace.

The headline experiment for Phase 2 is therefore: **is `ruff-reviewer` on Haiku at low
effort equivalent to the current Sonnet baseline on finding sets?** Real cost-saving
question, binary recall answer.

### Architecture choice

**Approach A** from the brainstorm: mode flag on existing `tests/ab/run.sh`
(`--mode end-to-end` default | `--mode per-agent`). Per-agent code paths live in new lib
helpers (`agent_dispatch.sh`, `fixture.sh`, `agent_capture.sh`), not inline in `run.sh`.
Approaches B (sibling script) and C (dispatcher pattern) were rejected as duplication or
premature abstraction.

---

## Build phasing inside Phase 2 (as written into the spec)

- **Phase 2a** — reconstruction loop on the smoke fixture. Minimum viable. No
  faithfulness gate yet, no real fixture, no scoring delta. Cost: <30k tokens.
- **Phase 2b** — `--faithfulness-check` mode + decay-warner. Cost: same scale as 2a.
- **Phase 2c** — corpus extension (1-2 real ruff fixtures) + headline haiku-low vs sonnet
  experiment. Cost: small per trial; total scales with N×M.

Each sub-phase ends in a commit on a feature branch and an operator review.

---

## What you must NOT do

- **Do not relitigate the seven brainstorming decisions** above. They are the operator's
  decisions, not yours. If circumstances genuinely changed (e.g. a flag the spec assumes
  exists turns out not to), surface that explicitly and ask — don't quietly redesign.
- **Do not dispatch any Bedrock-touching trials** as part of planning or spec review. The
  spec calls out the verifications that need empirical answers during *implementation*;
  the plan should record them, not perform them.
- **Do not start coding.** The plan comes before the code; subagent-driven implementation
  comes after the plan.
- **Do not write a refresh-fixtures subcommand.** Phase 2 explicitly defers it.
- **Do not extend the suite with extension points the suite must consult** (per
  `feedback_models_overlook_tuning_hooks`).
- **Do not attempt to address the rubric-row-2 question or the empty-stdout anomaly** as
  part of Phase 2. Both require synthesiser-level support that's deferred to Phase 3+.

---

## What you SHOULD do (sequence)

1. Greet the operator. Confirm they want to proceed with the user-review gate on the
   spec.
2. Read the artefacts in the order listed above.
3. Confirm with the operator: "Spec at `docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md` — approved as-is, or changes requested?" Wait for response.
4. If changes: make them inline, re-run the spec self-review (placeholders, internal
   consistency, scope, ambiguity), surface for re-approval.
5. If approved: invoke the `superpowers:writing-plans` skill to produce
   `docs/superpowers/plans/YYYY-MM-DD-per-agent-harness-phase-2-plan.md` (use today's
   date). Use the Phase 1 plan as a template for the level of detail.
6. After the plan is approved by the operator, the path forward is
   `superpowers:subagent-driven-development`.

---

## Repository state at handover time

- **Branch:** `feat/ab-test-harness-spec` (Phase 1's branch). Operator may want a new
  feature branch (`feat/per-agent-harness-phase-2`) once the plan lands.
- **Uncommitted file at handover time:**
  `docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md` (the new spec).
  Operator may have committed it already by the time you read this — check `git status`.
- **No code changes yet.** Phase 2's lib/, configs/per-agent/, corpus/ trees do not
  exist — they're the spec's deliverable shape.
- **Phase 1 run dirs preserved at:**
  `tests/ab/runs/{20260521T134652Z-baseline, 20260521T140923Z-baseline-smoke-2,
  20260521T152557Z-baseline, 20260521T162805Z-no-ultrathink}` (gitignored). Useful as
  forensic context, not as Phase 2 fixtures (no static-analysis findings on the corpus
  PR).
- **The empty-stdout trial's `CLAUDE_TEMP_DIR`** is at
  `/tmp/claude-a253eef7-1856-4d1a-b54f-0197704e1a3e/` and may still be alive — same
  caveat: not relevant to Phase 2's narrowed slice.

---

## Cost expectations for the planning session

Brainstorming is done. The remaining work in this planning thread is:

- Spec user-review (~10 min, inline edits if any).
- Plan writing (writing-plans skill, ~30-60 min depending on detail).
- Operator review of plan (~10 min, inline edits if any).

No Bedrock-touching subagent trials should be required for any of this. Plan generation
itself uses the writing-plans skill which is process-driven, not experiment-driven.

---

## End of handover

Stop reading and start by greeting the operator. The first action is reading the spec,
then asking the user-review-gate question.
