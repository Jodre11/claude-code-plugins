# Agent-Hazard Basis — Behavioural A/B Trial Design

**Status:** RESOLVED (design approved 2026-06-16; ready for `writing-plans`).

**Context.** PR #52 added an "agent-hazard" basis at the Important severity tier
(`includes/severity-definitions.md`), taught the review-synthesiser to recognise it as a
second Important bar (`agents/review-synthesiser.md`), and additively re-pointed
correctness-reviewer's comment-truth clause to cite it. PR #52 shipped with **structural
tests only** — they prove sync and schema, not behaviour. This spec designs the deferred
behavioural trial named in that PR's "Validation status" section: a minimal, statistically
honest A/B ablation that earns test-data support before the basis is relied upon in
production reviews.

---

## Goal

Establish, with objective test data, that the agent-hazard basis **fires** (a genuinely
misleading artefact reaches and survives at Important) **without inflating** (a merely
vague-but-not-misleading artefact does not get pushed to Important). Both directions matter;
the inflation direction is the higher-value, higher-risk one.

## Non-goals (explicit scope boundary)

- **Not** a per-specialist model/effort tuning sweep. Honing each specialist to its cheapest
  adequate (model, effort) is a SEPARATE future programme — one slice per specialist, on the
  existing `configs/per-agent/*-haiku-low.yaml` chassis, run only AFTER each specialist's
  behaviour is known-correct. Recorded here as out-of-scope follow-up so it is not lost.
- **Not** a model-as-judge scorer. The A/B harness carries a permanent design constraint
  (`tests/ab/README.md`, `2026-05-21-ab-test-harness-design.md`): no LLM grades another
  LLM's output. This trial honours that — all human judgment goes into fixture design; scoring
  is a mechanical string/severity match.
- **Not** a change to the basis, the rubric, or any shipped PR #52 file. If the trial reveals
  a weakness, that becomes a follow-up spec, not an edit folded into this work.

---

## What the trial proves, and its one objective bit

Each fixture collapses to a single objective observation: **did a finding on the planted line
get assigned `severity: Important` in the synthesiser's output?** This is a string/severity
match (`jq`/grep), not a judgment. The judgment is entirely in *authoring* the fixture; none
is in *scoring* it.

### Unit under test: the review-synthesiser

The synthesiser is the correct and only altitude for this trial, because it carries the
load-bearing change:

- Pre-PR, the synthesiser's Severity Reclassification step quoted only the runtime-defect bar.
  An agent-hazard Important raised by a specialist would have been **silently downgraded** to
  Suggestion. (This is the Task 2 ripple in PR #52.)
- Post-PR, the synthesiser recognises the second bar and keeps it — subject to the inflation
  guardrails, which also live in the synthesiser's instruction.

A per-agent ablation on correctness-reviewer alone would show ≈ no difference: its inline
"mislead a caller → Important, else Suggestion" litmus pre-existed PR #52; only a basis
citation was added. The behaviour PR #52 changes is at the synthesiser, so that is the unit.

---

## Fixtures: a matched hit / near-miss pair

The PR's risk is asymmetric, so one fixture cannot cover it. Two synthetic fixtures (the
same `type: synthetic` class as every existing corpus entry), both fed to the synthesiser:

| Fixture | Planted artefact | Specialist-supplied severity | Pass condition (arm B) |
|---|---|---|---|
| `synth-hazard-hit` | A docstring/comment that **actively contradicts** the code it documents (a genuinely lying comment) | Important | Synthesiser **keeps** Important (firing) |
| `synth-hazard-nearmiss` | A comment that is **vague / incomplete but does not actively mislead** (an over-classification by the specialist) | Important | Synthesiser **downgrades** to Suggestion (guardrail holds) |

The pair is what makes a result meaningful: a basis that fires AND a guardrail that does not
over-fire. A hit-only fixture would tell us nothing about the inflation risk that is the whole
reason for the guardrails.

Both fixtures are hand-authored, registered in `tests/ab/corpus/index.yaml` (no glob
discovery — gated, per existing convention), and provenance-stamped in `source.yaml`.

---

## New plumbing (the only material build cost)

Every existing fixture feeds a *specialist* whose input is a diff
(`source.yaml` + `diff/changed-lines.txt`), reconstructed by
`agent_dispatch_build_user_message` (`tests/ab/lib/agent_dispatch.sh:56`). The
**synthesiser's** input is different: a **bundle of specialist findings + diff context**, as
the orchestrator would hand it.

Extension (additive, guarded):

- A fixture may carry a new `specialist_findings:` block in its `source.yaml`.
- When present, the user-message reconstructor appends that block in the shape the synthesiser
  expects to receive from the orchestrator.
- When absent (every current fixture), behaviour is byte-for-byte unchanged. A structural test
  locks both the absent-key passthrough and the present-key shape.

This path is reusable infrastructure for any future synthesiser-level trial, not throwaway.

### Faithfulness risk (the main thing the implementation plan must de-risk)

Reconstructing the synthesiser's input faithfully is the genuine implementation risk. If the
reconstruction diverges from what the real orchestrator hands the synthesiser, the trial
measures an artefact. Per the README's "empirically ground parsers" lesson
(`tests/ab/README.md`), the plan MUST first capture a real orchestrator→synthesiser hand-off
from a live review run and author the reconstruction against that trace — not against a
hypothesised shape — before any trial numbers are trusted.

---

## Arms, trials, decision rule

The ablation reuses the harness's existing mutate-then-revert mechanism
(`tests/ab/lib/mutate.sh`): arm A reverts the three PR #52 severity files to their pre-PR
text; arm B leaves PR #52's version in place. The same two fixtures run through both arms.

| | `synth-hazard-hit` | `synth-hazard-nearmiss` |
|---|---|---|
| **Arm A** (basis absent) | expect downgrade → Suggestion | expect Suggestion |
| **Arm B** (basis present) | expect **Important kept** | expect **downgrade → Suggestion** |

- **Trials:** 5 per cell (20 runs total). Coarser than the Phase 3 tuning sweeps (which used
  20/arm to prove *equivalence*); this is a go/no-go that detects a *difference*, which needs
  far fewer runs.
- **Firing signal:** the hit-fixture arm-A-vs-arm-B contrast. A working basis flips the hit
  fixture from mostly-Suggestion (A) to mostly-Important (B). A ≈ B means the basis does
  nothing.
- **Guardrail signal:** `synth-hazard-nearmiss` arm B staying Suggestion. Arm B inflating the
  near-miss to Important means the guardrail is too weak — an actionable finding (a follow-up
  spec, possibly a guardrail wording tweak), not a merge-blocker for this trial.
- **Scoring:** mechanical — `jq`/grep over the synthesiser's output for the planted line's
  severity. No judge.

**Decision rule:** the basis is validated iff (a) the hit cell shows a clear A→B shift toward
Important AND (b) the near-miss arm B stays predominantly Suggestion. Anything else: report
the numbers, do not claim behavioural validation.

---

## Statistical treatment

We are detecting a **difference**, not proving **equivalence** — which is why this trial is
cheap where the Phase 3 sweeps were expensive.

- **Firing claim — Fisher's exact test** on the hit-fixture 2×2 (arm A Important-count vs
  arm B Important-count). Binary per-trial outcome (Important / not), small n → Fisher is the
  correct exact test; no normal approximation. A clean 0/5-vs-5/5 split gives two-tailed
  p ≈ 0.008, comfortably below 0.05, so a real effect is detectable at 5/cell.
- **Inflation claim — Wilson 95% confidence interval** on the near-miss arm-B inflation
  proportion. No contrast there; we want "is the inflation rate acceptably low," reported as a
  proportion with its interval, not a significance test.
- **Escalation rule:** if the hit split is borderline (e.g. 2/5 vs 4/5, p not significant),
  that ambiguity is informative — but top up that cell to 10 trials before concluding, to rule
  out small-sample bad luck. Clean result → stop at 5; messy → top up to 10 and report the
  wider picture.

---

## Components (units and responsibilities)

| Unit | Responsibility | Change |
|---|---|---|
| `tests/ab/lib/agent_dispatch.sh` | Per-agent user-message reconstruction | Additive `specialist_findings:` path; absent-key passthrough preserved |
| `tests/ab/corpus/synth-hazard-hit/` | Lying-comment fixture (findings bundle + diff + provenance) | NEW |
| `tests/ab/corpus/synth-hazard-nearmiss/` | Vague-but-not-misleading fixture | NEW |
| `tests/ab/corpus/index.yaml` | Gated fixture registry | Register both fixtures |
| `tests/ab/configs/per-agent/` | Synthesiser arm configs (model/effort fixed; ablation via file mutation) | NEW arm configs as needed |
| Scoring step | Extract planted-line severity → Fisher + Wilson | NEW small script or documented `jq` recipe |
| `tests/lib/test_*.sh` | Structural lock on the new reconstruction path | NEW assertions |

## Testing

- Structural test: `specialist_findings:` absent → reconstruction byte-identical to today;
  present → expected synthesiser-shaped block. Auto-discovered `test_*` function.
- Faithfulness capture: one live orchestrator→synthesiser trace inspected before trial numbers
  are trusted (de-risks the reconstruction).
- The trial itself is run manually (it dispatches real models, costs tokens, needs a valid
  Bedrock SSO token) — it is not part of `tests/run.sh`.

## Out-of-scope follow-ups (recorded, not actioned here)

1. **Per-specialist model/effort honing** — one tuning slice per specialist on the existing
   per-agent chassis, after behaviour-correctness is established. The natural home for the
   agent-hazard basis's own cheap-model validation.
2. **False-green / tautological-test fixture variant** — a second hit-direction fixture kind
   if the comment-truth pair proves insufficient coverage.
3. **Guardrail wording iteration** — only if the near-miss cell shows inflation.
