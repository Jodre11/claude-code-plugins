# Handover: Phase 3.1 — ruff-reviewer cost-tuning probe

**Author of this handover:** Christian (via session of 2026-05-29).
**Audience:** A fresh Claude Code session continuing Phase 3.1 with no prior
context.
**Purpose:** Bootstrap planning and execution of the first directional probe
in the static-specialist tuning sweep, with the smallest possible context
budget.

---

## TL;DR for the receiving session

Phase 2 of the per-agent A/B harness shipped (PR #33, merged 2026-05-29 at
`b214944`). The harness chassis is on `main` and reusable. Phase 3 is the
first real *use* of the harness: directional probes to answer the cost-tuning
question for each of the four static-analysis specialists, one specialist
per PR, ruff first.

The Phase 3 methodology spec is locked. The Phase 3.1 (ruff-only) plan has
NOT been written. Your job is to:

1. Write the Phase 3.1 implementation plan at
   `docs/superpowers/plans/2026-05-29-static-specialist-tuning-ruff-plan.md`.
2. Get operator approval on the plan.
3. Execute it via `superpowers:subagent-driven-development`.
4. Open the Phase 3.1 PR.

The session that produced this handover **does not want you to relitigate**:

- The Phase 3 directional-sweep methodology (locked in
  `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`).
- The decision to do per-specialist PRs starting with ruff (locked).
- Whether to run a brainstorming round (no — operator confirmed the spec is
  enough; go straight to plan).
- Whether to run a housekeeping audit first (already done in the producing
  session — confirmed no-op; both pinned action SHAs match latest tags;
  runner is `ubuntu-24.04`).

---

## What you must read before responding

Read in this order. None of these will be in your context — open and read
each before doing anything else.

1. **CLAUDE.md** at `~/.claude/CLAUDE.md` (operator's global) and at
   `~/.claude/plugins/marketplaces/jodre11-plugins/CLAUDE.md` (project-local).
   Vocabulary, Bash conventions (no compound commands, no `$(...)` outside
   HEREDOC carve-outs), agent-dispatch conventions (always `mode: "auto"`,
   always `name`), auto-memory protocol.

2. **Phase 3 methodology spec** (the document you're implementing):
   `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`.
   Read all of it. Phase 3.1 is a strict subset — only the ruff specialist —
   so the spec covers the methodology you'll use, just narrowed.

3. **Phase 2 plan** (worked example of plan structure at the right level of
   detail, plus the Phase 2c-deferred section that explains why Phase 3
   exists):
   `docs/superpowers/plans/2026-05-28-per-agent-harness-phase-2-plan.md`.

4. **The post-Phase-2 README** for harness usage docs:
   `tests/ab/README.md`. The "Per-agent mode (Phase 2)" section documents
   exactly the surface you'll be calling. The "Implementation notes"
   subsection captures three load-bearing lessons from Phase 2 that apply
   directly to Phase 3.

5. **Auto-memory entries** (loaded automatically into your session) —
   `MEMORY.md` indexes them. Particularly:
    - `feedback_models_overlook_tuning_hooks` — the suite stays unaware it is
      being tested. Don't add tuning hooks to production agents.
    - `feedback_claudemd_compliance` — read before any Bash tool call.
    - `project_per_agent_harness_phase2_planning` — Phase 2 outcome,
      including the seven plan-defect patterns to watch for.
    - `project_rubric_row2_stability` and
      `project_orchestrator_empty_stdout_anomaly` — open issues, explicitly
      out of Phase 3 scope.

---

## What "Phase 3.1" means specifically

Single PR. Single specialist. Single decision point.

**Headline question:** does `ruff-reviewer` at Haiku/low produce a finding
set byte-identical to the Sonnet/default baseline captured in Phase 2b?

**Smoke fixture is reusable.** `tests/ab/corpus/ruff-smoke-bad-py/` already
exists in tree. The canonical baseline at
`tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json` is hash
`7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3` — that's
what you'll compare every Haiku trial against.

**Cost:** ~30k Bedrock tokens for 3 trials. Plus ~10k tokens of operator
review time across the gates inside the plan.

**Expected outcome:** Haiku/low passes 3/3. Static-analysis specialists are
mechanical transmission tasks (run tool → parse JSON → emit canonical
markdown). The cognitive demand is low; Haiku/low almost certainly handles
it. If it fails, that's a real and surprising signal worth investigating.

**The first functional change to the plugin from this entire programme.**
Phase 1 + Phase 2 built measurement apparatus only — not one production
agent's behaviour was changed. Phase 3.1, if the probe passes, edits
`plugins/code-review-suite/agents/ruff-reviewer.md`'s frontmatter `model:`
field from `sonnet` to `haiku`. That edit is the actual cost optimisation
the entire programme exists to enable.

---

## What the Phase 3.1 plan must cover

The spec is already methodologically prescriptive. The plan is the
operational/file-level transcription. At minimum, the plan needs these
tasks:

1. **Pre-flight: confirm housekeeping is no-op.** Already done in the
   producing session — both pinned action SHAs (`actions/checkout v6.0.2`
   and `gitleaks/gitleaks-action v2.3.9`) match latest tags. Runner is on
   `ubuntu-24.04`. The plan's housekeeping task can be a one-paragraph
   no-op note rather than a full audit task. Confirm with `gh api repos/.../releases/latest`
   if you want to re-verify; otherwise mark and move on.

2. **Branch off `main` at `b214944`** as `feat/per-agent-tuning-ruff-haiku-low`.

3. **Author `tests/ab/configs/per-agent/ruff-haiku-low.yaml`** — one new
   YAML file mirroring `ruff-baseline.yaml` but with `model: haiku` and
   `effort: low`. Add a structural test that the file parses and exposes the
   correct model + effort fields when loaded via `config_load`. Write the
   test first; verify it fails; create the YAML; verify it passes; commit.

4. **Live-fire 3 trials at Haiku/low** with `--faithfulness-check` against
   the smoke fixture. Same cost-aware stop-and-investigate rules as Phase
   2b's Task 9 Step 6: if any trial returns INCONCLUSIVE, empty stdout,
   non-zero from anything other than the comparison, or wall-clock above
   ~60s, STOP, surface stderr to the controller, do not retry blindly.

5. **Stop at an operator review gate** with the trial outcomes (hashes,
   wall-clock per trial, summary.csv) before treating the result as
   decisive. The plan should include this gate explicitly — same shape as
   Phase 2's two operator review gates.

6. **Compute the verdict** per the spec's Step 4 outcome table:
   - 3/3 hash-match the baseline → adopt Haiku/low for production
     ruff-reviewer.
   - 0/3 hash-match → reject; ruff-reviewer stays at Sonnet/default.
   - 1-2/3 → reject as non-determinism (transmission tasks should be
     deterministic; non-determinism is itself a defect).

7. **Write a one-page comparison report** at
   `docs/superpowers/notes/2026-05-29-ruff-haiku-low-probe-result.md` with
   the actual numbers and the verdict. The plan should specify the report
   skeleton; the implementer fills it in after the trial runs.

8. **IF the probe passes**, edit
   `plugins/code-review-suite/agents/ruff-reviewer.md`'s frontmatter:
   `model: sonnet` → `model: haiku`. Document the rationale in the commit
   body referencing the report. **Run `tests/run.sh` to confirm the
   structural tests still pass after the agent file edit** — the structural
   tests check sync-note consistency and may surface drift if the agent file
   has been edited in ways that interact with other rules.

   If the probe fails or is inconclusive, do NOT edit the agent file.
   Document the failure in the report, commit only the
   `ruff-haiku-low.yaml` config + its structural test (so the result is
   reproducible), and note in the PR body that the directional answer is no.

9. **Open the PR** with the report linked from the body and the verdict
   stated in the title (e.g. `feat(code-review-suite): adopt Haiku/low for
   ruff-reviewer (Phase 3.1)` if positive, or `chore(tests/ab): record
   ruff-reviewer Haiku/low probe — verdict: <reject|inconclusive>` if
   negative).

10. **Watch CI to green and merge.**

The spec at `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`
also lists Step 5 (one-page report) and Step 6 (richer-fixture follow-up
ONLY if probe failed). Step 6 is out of scope for Phase 3.1 — defer to a
separate plan only if Step 4 surfaces a reject/inconclusive verdict.

---

## What you must NOT do

- **Do not extend Phase 3.1 to cover eslint, trivy, or jbinspect.** Those
  are separate PRs (Phase 3.2, 3.3, 3.4). Per the operator decision, each
  static specialist gets its own PR-sized probe.
- **Do not relitigate the directional-probe methodology.** It's locked in
  the spec. If you find a real defect, surface it inline and ask the
  operator before changing it.
- **Do not author a richer ruff fixture as part of Phase 3.1.** Only
  triggered if the probe fails and only after operator approval.
- **Do not skip the operator review gate before editing the production
  agent file.** Phase 1 + 2 spent ~5 months of design + ~5M+ Bedrock tokens
  building the apparatus that lets us make this edit responsibly. Don't
  bypass the gate to save 30 seconds.
- **Do not modify production agent files (`plugins/code-review-suite/...`)
  before the probe completes.** The agent file edit is the LAST step,
  gated on a positive verdict, and only that one frontmatter line.
- **Do not address the rubric-row-2 anomaly or the empty-stdout anomaly.**
  Both deferred to phases that need synthesiser-level support.
- **Do not extend the suite with extension points the suite must consult.**
  Per `feedback_models_overlook_tuning_hooks`. The harness drives variation
  externally; the agent file's `model:` field is the ONE permitted edit and
  it's a permanent change, not a runtime hook.

---

## Plan-defect patterns from Phase 2 to NOT repeat

The Phase 2 execution surfaced seven plan-defect-correction patterns. The
Phase 3.1 plan is much smaller scope so the surface is smaller, but watch
for:

1. **Empirically ground anything format-related against a live trace before
   transcribing.** Phase 2's parser was authored against a fictional plain
   `Field: value` format; the canonical contract uses bold-markdown bullets;
   the first live trial revealed the divergence. Phase 3.1 reuses Phase 2's
   parser — no new parser work needed — but if any new format work creeps
   in, ground it empirically.

2. **`rc=$(...)` patterns under `set -euo pipefail` need `set +e` inside the
   subshell** to capture non-zero return codes without aborting. The
   canonical pattern is at `tests/lib/test_ab_harness.sh:597-603` — read
   before writing similar tests.

3. **`pass`/`fail` calls inside `(...)` subshells lose counter mutations.**
   Hoist assertions to the outer frame; capture data into tmpfiles inside
   the subshell. Pattern at
   `tests/lib/test_ab_per_agent_lib.sh:457` post-Phase-2-fix-up.

4. **Bash `RETURN` traps persist across function returns**, which is almost
   never what you want. Use explicit cleanup over `trap … RETURN` for
   scratch-file removal inside helpers.

5. **The state-dependent `bad-config rejection leaves working tree clean`
   test is NOT a real failure** — it triggers during dirty-tree windows
   mid-iteration and passes at clean HEAD. If you see it fail mid-execution,
   commit your work-in-progress and re-run; don't waste a fix-up cycle on it.

6. **Always flag plan-text defects to the operator before changing the
   plan.** If the spec or the plan contradicts what you observe, the
   operator decides whether the spec is wrong or the implementation is.
   Don't silently rewrite the plan.

---

## Repository state at handover time

- **Branch:** `main` at `b214944` (the Phase 2 squash-merge commit).
- **Working tree:** Clean.
- **Tests:** 294 tests, 293 passed, 1 skipped, 0 failed.
- **No uncommitted Phase 3 work yet.** Your first action is to read the
  artefacts above, confirm with the operator that you should proceed with
  the spec as-is, then start writing the plan.
- **Phase 1 run dirs preserved at:** `tests/ab/runs/{20260521T...}` — Phase
  1 forensic context, not Phase 3 fixtures.
- **Phase 2 run dirs preserved at:** `tests/ab/runs/{20260529T060522Z-ruff-baseline,
  20260529T063358Z-ruff-baseline}` (gitignored). The latter is the Phase 2b
  3-trial faithfulness check whose hashes you'll be matching against.

---

## Cost expectations

- Plan writing: ~30 minutes of Claude wall-clock, $0 Bedrock cost beyond
  this session's overhead.
- Operator review of plan: ~10 minutes.
- Phase 3.1 execution:
  - Tasks 1-3 (config + test, no Bedrock): ~10 minutes wall-clock.
  - Task 4 (3-trial live-fire): ~3 minutes wall-clock, ~30k Bedrock tokens.
  - Tasks 5-9 (gate, verdict, report, optional agent file edit, PR): ~20
    minutes wall-clock, $0 additional Bedrock.
- Total: ~30k Bedrock tokens, ~1 hour wall-clock.

If the probe fails, no agent file edit happens; total cost is the same
(~30k tokens) but the outcome is a documented "no" rather than a production
adoption. Either result is publishable.

---

## What to do first

1. Greet the operator. Confirm they want to proceed with the directional
   probe as-is per the spec. Mention the housekeeping audit was already
   done by the producing session and surfaced no bumps — no separate
   housekeeping PR needed.
2. Read the artefacts in the order listed above.
3. Invoke `superpowers:writing-plans` and produce the plan at
   `docs/superpowers/plans/2026-05-29-static-specialist-tuning-ruff-plan.md`.
4. Surface for operator approval. Once approved, invoke
   `superpowers:subagent-driven-development` and execute.

---

## End of handover

Stop reading and start by greeting the operator. The first action after
greeting is reading the methodology spec. The plan should be tight (~10
tasks) and reuse the Phase 2 patterns wholesale.
