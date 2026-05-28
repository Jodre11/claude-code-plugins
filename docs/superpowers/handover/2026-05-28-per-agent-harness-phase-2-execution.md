# Handover: Per-agent A/B harness — Phase 2 (execution)

**Author of this handover:** Christian (via session of 2026-05-28).
**Audience:** A fresh Claude Code session executing the Phase 2 implementation
plan with no prior context.
**Purpose:** Bootstrap subagent-driven execution against the committed plan
without re-litigating any design or planning decisions.

---

## TL;DR for the receiving session

Brainstorming and planning for Phase 2 are **complete**. The artefacts are
all on the `feat/ab-test-harness-spec` branch:

- Spec: `docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md`
- Plan: `docs/superpowers/plans/2026-05-28-per-agent-harness-phase-2-plan.md`
- Prior planning handover: `docs/superpowers/handover/2026-05-25-per-agent-harness-phase-2-planning.md`

Your job is to drive the plan to completion using
`superpowers:subagent-driven-development`. Fresh subagent per task. Review
between tasks. Two explicit operator review gates inside the plan (between
Tasks 7 and 8, and between Tasks 9 and 10) — at each one, stop and surface the
state for human review before proceeding.

The session that produced this handover **does not want you to relitigate the
spec or the plan**. If you find a real defect in the plan, surface it
inline and ask the operator before changing it.

---

## What you must read before responding

Read in this order. None of these will be in your context — open and read each
before doing anything else.

1. **CLAUDE.md** at `~/.claude/CLAUDE.md` (operator's global) and at
   `~/.claude/plugins/marketplaces/jodre11-plugins/CLAUDE.md` (project-local).
   Vocabulary, Bash conventions (no compound commands, no `$(...)` outside the
   HEREDOC carve-outs), agent-dispatch conventions (always `mode: "auto"`,
   always `name`), auto-memory protocol.

2. **The Phase 2 implementation plan** (the document you are executing):
   `docs/superpowers/plans/2026-05-28-per-agent-harness-phase-2-plan.md`.

3. **The Phase 2 design spec** (architectural rationale; consult when a
   subagent asks for clarification):
   `docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md`.

4. **The prior planning handover** (decisions already locked):
   `docs/superpowers/handover/2026-05-25-per-agent-harness-phase-2-planning.md`.

5. **The Phase 1 plan** (worked example of subagent-driven execution at the
   same level of detail as the Phase 2 plan):
   `docs/superpowers/plans/2026-05-21-ab-test-harness-phase-1-plan.md`.

6. **Auto-memory entries** (loaded automatically into your session) —
   `MEMORY.md` indexes them. Particularly:
    - `feedback_models_overlook_tuning_hooks` — the suite stays unaware it is
      being tested. No env vars or extension points the suite must consult.
    - `feedback_claudemd_compliance` — read before any Bash tool call.
    - `project_rubric_row2_stability` and `project_orchestrator_empty_stdout_anomaly` —
      open issues, explicitly out of Phase 2 scope. Do not let a subagent drift
      into them.
    - `project_per_agent_harness_phase2_planning` — context for why the spec
      and plan exist. Approval gate has cleared as of 2026-05-28.

---

## Approval state

The operator approved the spec on 2026-05-28 ("Approve as-is"). The plan was
written, self-reviewed clean, and committed in this session's flow. Both are
locked unless the operator explicitly says to change them.

The plan itself contains TWO operator review gates inside the body
(`⏸ Phase 2a operator review gate` between Tasks 7 and 8, and `⏸ Phase 2a
complete — operator review gate` after Task 8 / before Task 9, plus the
`⏸ Phase 2b complete` gate after Task 9). At each ⏸ marker, stop dispatching
subagents and surface the state for the operator. Do not silently roll past
them — those gates exist because Bedrock-touching trials happen on the
*other* side of them.

---

## How to execute (subagent-driven-development)

Invoke the `superpowers:subagent-driven-development` skill. Then for each
task:

1. Dispatch a fresh subagent with `mode: "auto"` and a kebab-case `name`
   following the convention `implementer-task-N` (e.g. `implementer-task-3`).
2. Hand the subagent the plan path, the task number, and any extra context
   the plan does not already make explicit.
3. After the subagent returns, run a code-review subagent (e.g.
   `code-review-suite:code-analysis` or the appropriate specialist) named
   `reviewer-task-N`. Read the review.
4. If the review is clean, mark the task complete in your TaskList and move
   on. If not, dispatch a fix subagent named `fix-task-N` with explicit
   reference to which review findings to address.
5. At each ⏸ gate, stop and surface the run state (what's committed, what's
   pending, what trial output exists) to the operator for review.

Each subagent's brief MUST include:

- The plan path and the task number it is implementing.
- That CLAUDE.md conventions apply (no compound Bash, no `$(...)` outside
  HEREDOC carve-outs).
- The session's `CLAUDE_TEMP_DIR` value (resolve from environment at
  dispatch time).
- That it is implementing one task only — do not run ahead.

---

## What you must NOT do

- **Do not relitigate the seven brainstorming decisions** locked in the
  prior planning handover. They are operator decisions, not yours.
- **Do not skip the ⏸ operator review gates.** They exist because Bedrock
  cost is real on the other side and irreversible mistakes (mis-captured
  fixture baselines, dirty trees from broken reverts) compound across
  trials. At each gate, stop, summarise state, and ask for a "proceed".
- **Do not have subagents dispatch their own subagents.** Each task is
  one subagent's responsibility. Subagent agent-dispatch (e.g. via
  Workflow or nested Agent calls) is out of scope here.
- **Do not bypass the housekeeping PR (Task 1)** unless the audit
  legitimately surfaces nothing to bump. CLAUDE.md is explicit that
  housekeeping lands first as a separate PR; only skip it if the audit is
  empty.
- **Do not address the rubric-row-2 anomaly or the empty-stdout anomaly**
  as part of Phase 2 execution. Both require synthesiser-level support
  that's deferred to Phase 3+.
- **Do not write a refresh-fixtures subcommand.** The plan documents the
  manual workflow in Task 12; Phase 2 explicitly defers the subcommand.
- **Do not extend the suite with extension points the suite must
  consult** (per `feedback_models_overlook_tuning_hooks`). The harness
  drives all variation externally.

---

## What you SHOULD do (sequence)

1. Greet the operator. Confirm they want to proceed with subagent-driven
   execution of the plan as-is.
2. Read the artefacts in the order listed above.
3. Invoke `superpowers:subagent-driven-development` and follow its loop.
4. Drive the plan in order: Task 1 (housekeeping PR), then Tasks 2-7 (Phase
   2a non-Bedrock setup), then ⏸ gate, then Task 8 (first Bedrock trial),
   then ⏸ gate, then Task 9 (Phase 2b), then ⏸ gate, then Tasks 10-11
   (Phase 2c headline experiment), then Tasks 12-13 (README + PR).
5. At each ⏸ gate: stop, summarise (committed / pending / trial output /
   working-tree state), ask the operator for a "proceed".
6. After the PR is opened (Task 13), the path forward is operator-driven
   (CI watch, merge decision, follow-up issue triage).

---

## Repository state at handover time

- **Branch:** `feat/ab-test-harness-spec` (Phase 1's branch, where the
  spec, prior handover, and Phase 2 plan all live). Task 1 of the plan
  branches off `chore/ci-action-pin-refresh-2026-05` for housekeeping;
  Task 2 onwards lands on a new `feat/per-agent-harness-phase-2` branch
  cut from main once the housekeeping merges. Read Task 1 carefully — the
  branch dance is documented there.
- **Uncommitted files at handover time:** the prior planning handover, the
  Phase 2 spec, the Phase 2 plan. These are all uncommitted on
  `feat/ab-test-harness-spec` as of this session — your first action
  should probably be to commit and push them so the receiving session has
  a stable baseline. (Confirm with the operator before committing — they
  may have a different staging preference.)
- **No Phase 2 code changes yet.** The Phase 2 lib/, configs/per-agent/,
  corpus/ trees do not exist; they are the plan's deliverable.
- **Phase 1 run dirs preserved at:** `tests/ab/runs/{...}` (gitignored).
  Useful as forensic context, not as Phase 2 fixtures.

---

## Cost expectations for the execution thread

The plan is structured to keep Bedrock cost concentrated and review-gated.

- **Tasks 1–7 (Phase 2a setup, no Bedrock):** code only, structural tests
  only. Zero Bedrock cost.
- **Task 8 (first Bedrock trial):** ~10k tokens. One trial, sonnet/default,
  on a 3-line file.
- **Task 9 (faithfulness check):** ~30k tokens. Three trials of the smoke
  fixture under sonnet/default.
- **Task 10 (real-PR fixture capture):** ~10–30k tokens. One trial against
  a real PR.
- **Task 11 (headline experiment):** N×2×1 trials = 6 trials by default.
  Per-trial cost depends on the chosen real-PR fixture; budget ~150–300k
  tokens total for this task.

Total Phase 2 Bedrock cost: under ~400k tokens for the full headline
experiment. Two orders of magnitude cheaper than a single Phase 1
end-to-end comparison (~5M tokens for one Phase 1 verdict).

---

## End of handover

Stop reading and start by greeting the operator. The first action after
greeting is reading the plan, then asking the operator for an explicit
"proceed" to begin Task 1.
