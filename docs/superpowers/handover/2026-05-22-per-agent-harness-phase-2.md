# Handover: Per-agent A/B harness — Phase 2

**Author of this handover:** Christian (via session of 2026-05-21 / 2026-05-22).
**Audience:** A fresh Claude Code session starting Phase 2 with no prior context.
**Purpose:** Bootstrap brainstorming and planning for a per-agent test harness.

---

## TL;DR for the receiving session

Phase 1 of the A/B test harness shipped (PR #31, merged or about to merge from
branch `feat/ab-test-harness-spec` against `main`). It tests the code-review-suite
end-to-end. **End-to-end testing turned out to be too noisy and expensive to be a
viable tuning loop** — verdict flipped on identical input, six trials cost ~3
hours and ~5M Bedrock tokens, and one trial silently produced empty stdout.

Phase 2 pivots to **per-agent testing using fixed real captured inputs**.
Specialists, cross-reviewers, and the synthesiser get tested in isolation against
golden fixtures captured from real end-to-end runs. This unblocks all future
tuning work on the suite.

The session that produced this handover **does not want you to start coding
immediately**. The right next step is brainstorming the design with the user,
then writing a spec, then a plan, then implementing. Use the
`superpowers:brainstorming` skill before anything else.

---

## What you must read before responding

Read in this order. None of these will be in your context — open and read each
file before doing anything else.

1. **CLAUDE.md** at `~/.claude/CLAUDE.md` (operator's global) and at
   `~/.claude/plugins/marketplaces/jodre11-plugins/CLAUDE.md` (project-local).
   Vocabulary, Bash conventions, and the auto-memory protocol are all there.
   The Bash conventions (no compound commands, no `$(...)` outside HEREDOC
   carve-outs) bite if you skip them.

2. **The Phase 1 design spec:** `docs/superpowers/specs/2026-05-21-ab-test-harness-design.md`.
   This is the architectural rationale for the harness. Skim it for the
   "Phase 2/3/4 explicitly out of scope" section so you know what was deliberately
   deferred.

3. **The Phase 2 direction spec:** `docs/superpowers/specs/2026-05-21-per-agent-testing-direction.md`.
   This is the substance of what you're going to build. It lays out:
    - What problem per-agent testing solves.
    - What primitives Phase 1 already provides (mostly additive).
    - The four open design questions.

4. **Phase 1 conclusion (operator artefact, may not exist on your machine):**
   the user's session captured the experiment outcome at
   `${CLAUDE_TEMP_DIR}/ultrathink-experiment-conclusion.md`. If gone, the
   summary is: 6 trials × 2 arms × PR #29, wall-clock arm-mean delta -11.7%
   (inside the 25% noise floor), 1 trial produced empty stdout, 1 verdict-flip
   per arm. Verdict: keep `ultrathink` in production, do not act on the
   experiment, pivot to per-agent testing.

5. **Sister follow-up specs** (do not implement these — they are the questions
   per-agent testing should answer):
    - `docs/superpowers/specs/2026-05-21-rubric-row-stability-followup.md` —
      verdict-instability investigation, this is the FIRST thing per-agent
      testing should help measure.
    - `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md` —
      orchestrator concern, NOT addressed by per-agent testing. Reserve a
      small end-to-end smoke role for it.

6. **Auto-memory entries** (already loaded automatically into your session):
    - `project_rubric_row2_stability` — what verdict-instability investigation
      looks like.
    - `project_orchestrator_empty_stdout_anomaly` — known anomaly, frequency
      unknown, do not act on it.
    - `feedback_models_overlook_tuning_hooks` — the suite stays unaware it is
      being tested. Do NOT extend production agent files with env vars or
      "extension points" the suite is supposed to consult.
    - `feedback_claudemd_compliance` — read this before any Bash tool call.
      Compound commands, `$(...)`, subshells in YOUR Bash calls all bite.

---

## What Phase 1 actually built (so you know what you can reuse)

Branch `feat/ab-test-harness-spec`, hopefully merged to `main` by the time you
read this. Files of interest:

- `tests/ab/run.sh` — orchestrator. Preflight → manifest → mutate (with EXIT
  trap installed BEFORE mutations) → trial loop → capture → summary.csv →
  revert. Hard-codes corpus PR `Jodre11/claude-code-plugins#29`.
- `tests/ab/lib/config.sh` — strict-schema YAML loader. Allow-list keys.
- `tests/ab/lib/mutate.sh` — in-tree mutation primitives + EXIT/INT/TERM/HUP
  revert trap. Three sync sites for `ultrathink` strip (enforced by
  `tests/lib/test_sync_notes.sh::test_sync_synthesiser_dispatch_uses_ultrathink`).
- `tests/ab/lib/launch.sh` — `command claude -p` invocation with
  `--permission-mode bypassPermissions --model X --effort Y
  --exclude-dynamic-system-prompt-sections`. Sets
  `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` for the subprocess only because the
  hardening default silently ignores `--permission-mode bypassPermissions`.
  Spawns a 60s heartbeat to stderr while the trial runs.
- `tests/ab/lib/capture.sh` — extracts orchestrator summary from stdout.
  Multiple regex patterns to match the three observed orchestrator output
  shapes; `INCONCLUSIVE` verdict for missing/truncated. Counts findings via
  "N consensus findings" / "N findings" / `^- ` bullet-line proxy in priority
  order.
- `tests/ab/configs/{baseline,no-ultrathink}.yaml` — Phase 1 configs.
- `tests/ab/fixtures/*.log` and `*.md` — captured fixture pairs for tests.
- `tests/lib/test_ab_harness.sh` — 24+ structural assertions hooked into
  `tests/run.sh`.
- `tests/ab/runs/<timestamp>-<name>/` — gitignored output directories. The
  Phase 1 experiment runs are at `20260521T152557Z-baseline/` and
  `20260521T162805Z-no-ultrathink/` — copy out before any local cleanup.

**What Phase 1 deliberately did NOT collect** that you need to add:

- **Per-trial intermediate artefacts.** Each trial creates a `CLAUDE_TEMP_DIR`
  containing real `all-findings.md`, `all-cross-opinions.md`,
  `findings-<specialist>.md`, `cross-<reviewer>.md`, and (sometimes)
  `tokens.jsonl`. These are the gold fixtures Phase 2 will tune against. Phase
  1 left them in `/tmp/claude-<uuid>/` where OS reboots clean them. Phase 2's
  first build task is fixture preservation — copy them into the trial output
  directory.

---

## The four open design questions

From the direction spec, repeated here so you don't miss them at brainstorm
time. Resolve each with the user before writing the plan.

1. **How does a per-agent dispatch get the agent's full system prompt?** The
   agent files in `plugins/code-review-suite/agents/*.md` contain YAML
   frontmatter + body. The orchestrator currently dispatches them via
   `Agent({subagent_type: "code-review-suite:<name>"})`. A direct `claude -p`
   invocation needs to either:
    - Reconstruct the prompt by concatenating the body + an input block.
    - Use a tool dispatch path that respects the same agent definition.
   The first is simpler but couples the harness to the agent file format. The
   second is more faithful but harder to invoke from the CLI.

2. **Should we test agents individually or in pairs?** Cross-reviewers depend
   on specialist output shape. Tuning specialists in isolation may produce
   outputs cross-reviewers don't handle well. Options: lock specialists first,
   then cross-reviewers, then synthesiser; OR test specialist+cross-reviewer
   pairs as composite units.

3. **What's the corpus shape?** Phase 1 hard-coded one PR URL. Phase 2 needs
   per-agent fixtures (real captured outputs), not PR URLs. Schema sketch:
   `corpus/<id>/all-findings.md`, `corpus/<id>/all-cross-opinions.md`,
   `corpus/<id>/source-pr.txt` (the PR URL the fixtures came from). The
   harness consumes the fixtures by path, not the PR.

4. **Fixture decay.** When upstream agents change (model bump, prompt edit),
   captured fixtures may not reflect current production. Need a
   refresh-fixtures workflow that re-runs the end-to-end harness to capture
   updated fixtures.

---

## What you must NOT do

- **Do not dispatch end-to-end trials to "verify" your work.** Phase 2 should
  not need any new Bedrock spend for end-to-end testing — the existing six
  Phase 1 trial directories provide the starter fixture set (after the
  fixture-preservation work).
- **Do not modify production agent model assignments based on per-agent
  results until the rubric-row-2 question is settled.** The whole point of
  per-agent testing is cheap iteration; do not act on the first measurement.
- **Do not extend the suite with extension points the suite must consult.**
  Per `feedback_models_overlook_tuning_hooks`. The Phase 1 mutate-and-revert
  approach is the right shape — keep it.
- **Do not delete the Phase 1 end-to-end harness.** It retains a role for
  testing the orchestrator (the
  `2026-05-21-orchestrator-empty-stdout-anomaly.md` follow-up requires it),
  for collecting fresh fixtures, and as the integration smoke-test for any
  agent changes.
- **Do not investigate the rubric-row-2 question or the empty-stdout anomaly
  as part of Phase 2 implementation.** Build the harness, then use it to
  investigate. Mixing the build with the investigation will produce a
  half-built harness and no investigation outcome.

---

## What you SHOULD do (sequence)

1. Greet the user. Confirm they want to proceed and offer to summarise.
2. Read the artefacts listed in "What you must read before responding".
3. Use `superpowers:brainstorming` to walk the user through the four open
   design questions. Do not propose solutions until they have weighed in
   on each.
4. Write the per-agent harness Phase 2 spec. Filename:
   `docs/superpowers/specs/2026-05-XX-per-agent-harness-phase-2-design.md`
   (today's date). Re-use the file structure from the Phase 1 design spec
   for consistency.
5. Write the Phase 2 implementation plan. Filename:
   `docs/superpowers/plans/2026-05-XX-per-agent-harness-phase-2-plan.md`.
   Use `superpowers:writing-plans` skill.
6. Get user approval on the plan, then dispatch via
   `superpowers:subagent-driven-development` (the same execution shape Phase
   1 used).

The Phase 1 plan is at
`docs/superpowers/plans/2026-05-21-ab-test-harness-phase-1-plan.md` — a
worked example of the right level of detail.

---

## Concrete starting prompt for the user

Once you've read everything, propose this back to the user as your starting
point:

> Phase 1 of the A/B harness is shipped. Phase 2 pivots to per-agent
> testing — testing one agent at a time against fixed inputs, using real
> captured outputs from Phase 1's six trials as starter fixtures. Before
> coding, I'd like to brainstorm the four open design questions: prompt
> reconstruction vs tool dispatch, individual vs paired testing, corpus
> schema, and fixture decay. Want to start with question 1?

---

## Inheriting environment knowledge

Bedrock + AWS SSO + Claude Code stack details that Phase 1 had to discover
the hard way:

- `~/.claudeenv` exists and exports model-capabilities env vars, Bedrock
  region, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`. The harness sources it
  and overrides the env-scrub flag for the trial subprocess only.
- `~/.claude/scripts/aws-sso-preflight.sh` refreshes SSO tokens. The harness
  runs this once per run, not per trial.
- macOS host needs `gtimeout` from Homebrew `coreutils` (Linux uses
  `timeout`). Phase 1 made the user `brew install coreutils` mid-run; this
  is now in the README preconditions.
- The user's `claude()` shell function does not pass `-p` through. The
  harness invokes `command claude -p` directly to bypass it.
- The synthesiser is dispatched as a subagent. **Subagent stdout does NOT
  propagate to parent stdout under `claude -p`.** The harness captures the
  orchestrator's freeform top-level summary instead, with multiple regex
  patterns for the observed shapes. This is the empirical surprise that
  reshaped Phase 1's capture logic; expect Phase 2 to need similar shape
  flexibility for whichever agent is being tested.

---

## Cost expectations for Phase 2 build itself

Phase 1 cost ~3 hours wall-clock + ~5M tokens for the experiment, plus ~6
hours of harness construction (mostly subagent-driven). Phase 2 should be
**substantially cheaper** because it does not need to dispatch end-to-end
trials at all — the fixtures already exist. Budget:

- Brainstorming + spec + plan: ~2 hours.
- Implementation (subagent-driven): ~3-5 hours.
- Validation against existing fixtures: ~30 min.

Do not run Bedrock-touching trials as part of Phase 2 implementation.
Validation should use the captured Phase 1 fixtures.

---

## End of handover

Stop reading and start by greeting the user. The first action is
brainstorming, not coding.
