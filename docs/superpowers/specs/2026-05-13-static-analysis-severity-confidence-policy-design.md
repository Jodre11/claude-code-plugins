# Static-analysis severity-locked + capped-confidence policy

**Status:** design (pre-implementation)
**Date:** 2026-05-13
**Predecessors:** [2026-05-12 static-analysis specialists design](2026-05-12-static-analysis-specialists-design.md), Stage 1 (PR #20) and Stage 2 (PR #22) shipped.

## Context

The static-analysis specialists (`eslint-reviewer`, `ruff-reviewer`, `trivy-reviewer`,
`jbinspect-reviewer`) emit deterministic, tool-derived findings. Today their findings flow
through the same synthesis path as LLM-judged specialists: the `review-synthesiser` runs a
"Severity Reclassification" step against `includes/severity-definitions.md` on every finding,
and may place any finding into Dismissed if it judges the finding a false positive.

This is the wrong shape for tool-derived data. The synthesiser is stochastic; the tools are
not. When a static-analysis finding is silently downgraded or dismissed because the
synthesiser disagrees, the deterministic verdict is lost without trace. Stage 1 of the
static-analysis specialists work anticipated this — every static-analysis finding emits the
literal `Confidence: 100` and a tool-derived severity precisely so a future policy can lock
those values against stochastic adjustment.

This spec defines that policy.

## Goals

1. Make tool-derived severity authoritative for static-analysis findings — the synthesiser
   cannot reclassify.
2. Bound stochastic interference in confidence — the synthesiser may nudge but only within a
   hard envelope (per-source 5-point dissent budget, floor 50).
3. Prevent silent suppression — Dismissed tier is unavailable for static-analysis findings.
4. Encode the project-aware Critical carve-out as an auditable per-specialist rule-ID
   allow-list.

## Non-goals

- Changing LLM-specialist confidence semantics (the eight cross-cutting reviewers) or
  severity reclassification rules. Their `Confidence: 0-100` ranges and severity
  reclassification continue as today.
- Changing the cross-reviewer emission contract. Cross-reviewers continue to emit
  qualitative `agree/disagree/supplement` text on findings; the synthesiser interprets that
  text for static-analysis findings under the new rules.
- Building a quantitative voting system inside the cross-reviewers themselves.
- Adding new severity tiers. The three-tier `Critical | Important | Suggestion` scale
  stands.
- Per-rule confidence tuning. Every static-analysis finding starts at 100, full stop.
- Severity-locking the eight LLM specialists.

## Design

### Mechanism (synthesiser side)

When the synthesiser receives a finding tagged `[eslint] | [ruff] | [trivy] | [jbinspect]`,
it follows a different code path from LLM-specialist findings:

**1. Severity passthrough.** Copy the specialist's severity verbatim. The "Severity
Reclassification" step in `agents/review-synthesiser.md` skips static-analysis findings.

**2. Per-source dissent count.** For each of the 8 cross-reviewers, examine its qualitative
response to the finding. Decide: did this cross-reviewer dissent? If yes, allocate up to 5
points of confidence drop, weighted by how strong the dissent reads. If no (or silent),
allocate 0. Silence is not agreement — silence is non-opinion.

**3. Synthesiser's own dissent.** As one of the 9 sources, the synthesiser may register up
to 5 points of its own dissent based on independent analysis.

**4. Sum, clamp, render.** Confidence = `max(50, 100 - Σ dissent)`. With 9 sources × 5
points each, the maximum drop is 45, giving a floor of 50.

**5. Tier placement.** Static-analysis findings go into Consensus or Contested only — never
Dismissed. A finding at floor 50 with substantial cross-review pushback lands in Contested
with the synthesiser's reasoning; otherwise Consensus.

**6. Output literal.** Per-finding output stays terse. Let `C` be the final confidence
(50–100) and `D` be the number of dissenting sources (0–9):

```
- **Confidence:** <C>  *(adjusted from 100 — <D> of 9 sources dissented)*
```

When `C == 100` (no adjustment), the parenthetical is omitted entirely. Most findings will
not be adjusted, so the noise stays low.

### Per-specialist severity mapping + Critical-allow-list

Each specialist file gets a "Severity mapping" subsection and a "Critical-allow-list"
subsection. The include's §10 contract is stable; per-tool tables live in the per-tool file.

#### eslint-reviewer

ESLint emits `severity: 1 | 2` per rule (1 = warning, 2 = error). Native severity is
rule-config-derived, not rule-intrinsic.

| ESLint config | Mapped |
|---|---|
| `error` (severity 2) | Important |
| `warn` (severity 1) | Suggestion |
| `off` (severity 0) | omit |

**Critical-allow-list (override to Critical):**

- `no-eval` — runtime code execution from string
- `no-implied-eval` — `setTimeout("...")`, `setInterval("...")`
- `eslint-plugin-security/detect-eval-with-expression`
- `eslint-plugin-security/detect-non-literal-require`
- `eslint-plugin-security/detect-child-process`

#### ruff-reviewer

Ruff has no native severity; categorise by code prefix.

| Code prefix | Mapped |
|---|---|
| `F` (Pyflakes), `E` (pycodestyle errors) | Important |
| `W` (pycodestyle warnings) | Suggestion |
| `B` (bugbear) | Important |
| `S` (bandit) | Important *(see allow-list)* |
| `PL*`, `SIM*`, `UP*`, `RUF*` | Suggestion |
| Everything else | Suggestion |

**Critical-allow-list:**

- `S105`, `S106`, `S107`, `S108` — hardcoded password / temp-file leak rules
- `S301`, `S302`, `S307` — unsafe deserialisation / dynamic-eval rules

#### trivy-reviewer

Trivy's native severity scale maps directly except CRITICAL is capped:

| Trivy native | Mapped |
|---|---|
| `CRITICAL` | Important *(see allow-list)* |
| `HIGH` | Important |
| `MEDIUM` | Suggestion |
| `LOW`, `UNKNOWN` | omit *(already filtered at `--severity` flag)* |

**Critical-allow-list:**

- Any rule whose ID matches `AVD-*-SECRET-*` or whose Title contains "secret",
  "credential", or "private key"
- Specific: `AVD-AWS-0017` (plaintext secret), `AVD-GCP-0001` (plaintext credential)

The allow-list uses pattern + explicit IDs because the secret-finding family is wide. The
spec records the pattern; the specialist enumerates the explicit IDs; a sync test ensures
both stay aligned.

#### jbinspect-reviewer

JetBrains InspectCode emits `Severity` as `ERROR | WARNING | SUGGESTION | HINT`.

| InspectCode | Mapped |
|---|---|
| `ERROR` | Important |
| `WARNING` | Important |
| `SUGGESTION` | Suggestion |
| `HINT` | Suggestion |

**Critical-allow-list:** none. C# nullable / async / disposable issues are well-covered as
Important. If a future rule warrants Critical, add it then.

### Interaction with `$CHANGED_LINES` filter

The policy applies *after* `includes/static-analysis-context.md` §5 has filtered findings
against `$CHANGED_LINES`. Findings whose `(file, line)` does not intersect a changed-line
hunk in the diff are dropped at parse time, before the synthesiser sees them. The
posting-time safety net in `review-gh-pr` Step 5 catches any escapees and silently routes
them to `$CLAUDE_TEMP_DIR/dropped-findings.log`. Every reported finding is therefore
anchored to a specific hunk visible on the PR.

### File changes

1. **`includes/static-analysis-context.md`** — add §10 "Severity-locked + capped-confidence
   policy". Defines the contract: severity is locked, confidence starts at 100, per-source
   5-point dissent budget, floor 50, Dismissed-tier forbidden, Critical-allow-list
   mechanism. Cited by all four specialists and by the synthesiser carve-out.

2. **`agents/eslint-reviewer.md`, `ruff-reviewer.md`, `trivy-reviewer.md`,
   `jbinspect-reviewer.md`** — each gets a "Severity mapping" subsection (the table from
   above) and a "Critical-allow-list" subsection. Both cite §10. Existing `Confidence: 100`
   and `## <Tool> Findings` literals stay verbatim.

3. **`agents/review-synthesiser.md`** — small carve-out under the existing "Severity
   Reclassification" section:

   > Findings tagged `[eslint] | [ruff] | [trivy] | [jbinspect]` are exempt from
   > reclassification. Their severity is the specialist's mapped value (per
   > `static-analysis-context.md` §10). Confidence on these findings starts at 100 and may
   > be adjusted per the per-source dissent budget defined in §10. They are never placed
   > in Dismissed.

   Plus the rendered output literal (using the variable names from "Mechanism" §6 above —
   `C` is the final confidence 50–100, `D` is the number of dissenting sources 0–9):

   ```
   - **Confidence:** <C>  *(adjusted from 100 — <D> of 9 sources dissented)*
   ```

4. **No changes to** the eight LLM specialists, `includes/cross-review-mode.md`, or the
   orchestrator pipeline. Cross-reviewers continue to emit qualitative text — the
   synthesiser does the math.

### Sync tests

New tests, modelled on existing `tests/lib/test_sync_*.sh` patterns:

- **`test_sync_static_analysis_policy_literals`** — assert each of the four specialist
  files contains the literal `Confidence: 100` and the literal `Critical-allow-list:`
  heading. Two specific phrases must appear byte-identical in **both**
  `includes/static-analysis-context.md` §10 **and** `agents/review-synthesiser.md`'s
  carve-out:
  - `up to 5 points of confidence drop` (the per-source budget literal)
  - `Confidence = max(50, 100 - Σ dissent)` (the floor + sum formula literal)
- **`test_sync_static_analysis_severity_lock`** — assert `agents/review-synthesiser.md`
  contains the carve-out sentence "Findings tagged `[eslint]` … are exempt from
  reclassification" verbatim, and that all four specialist tags appear in the list.
- **`test_sync_static_analysis_critical_allowlist_present`** — assert each of the four
  specialist files has a "Critical-allow-list:" subsection (jbinspect's says "none" —
  still a valid match).

### Behavioural smoke (extends existing scaffold)

A new sub-check `synthesiser_severity_lock` in `tests/fixtures/static-analysis/driver-prompt.md`:

- Synthetic prompt with one trivy finding at `Severity: Important` and 9 cross-reviewer
  "dissent" entries (synthesised text saying "irrelevant for this PR").
- Dispatch the **synthesiser** with that prompt.
- Assert: severity unchanged, confidence ≥ 50, parenthetical present, finding NOT in
  Dismissed.

This is a synthesiser dispatch, not a specialist dispatch — so it adds a new column to the
results-file schema. The existing 4 × 3 × 3 specialist grid is unchanged.

## Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | Cross-reviewer is silent on a finding | Default = 0 dissent. Silence is not agreement. |
| E2 | Cross-reviewer expresses *agreement* | Still 0 dissent. No "credit" mechanism — confidence cannot exceed 100. |
| E3 | Same finding raised independently by an LLM specialist | Static-analysis finding is the canonical record; the LLM duplicate folds into the synthesiser's prose. Existing dedup behaviour. |
| E4 | Synthesiser tries to dismiss anyway | Hard contract: static-analysis findings cannot enter Dismissed. Sync test + behavioural smoke. |
| E5 | New tool rule lands that should be Critical but is not on the allow-list | Fails *safe*: rule maps to default cap (Important for HIGH/CRITICAL native). LLM security-reviewer can still flag separately. |
| E6 | Synthesiser miscounts dissent | Floor 50 is the bound. Even if every cross-reviewer is misjudged at full 5-point dissent, the finding stays visible at 50% with explicit "adjusted from 100" framing. |
| E7 | Severity-mapping change downstream (e.g. promote a ruff prefix) | Specialist file changes; include §10 contract is stable. Sync test not useful — these are deliberate edits. |

## Risk register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| 1 | Synthesiser silently keeps reclassifying static-analysis severity despite carve-out | Medium | Sync test asserts carve-out sentence verbatim; behavioural smoke verifies in practice |
| 2 | LLM rationalises around the floor ("this is a special case, dropping to 30") | Medium | Floor stated as a hard constraint, not a guideline. Smoke test repeats with strong-dissent prompts; if floor breaches, fail loud. |
| 3 | Critical-allow-list goes stale as tool rules evolve | Low-Medium | Allow-list is short and explicit; failures are safe (rule maps to cap). Periodic review at most. |
| 4 | Per-source budget is too tight or too loose in practice | Medium | The 5-point literal is a calibration knob. If real PRs show floor-50 hits regularly, lower the per-source max to 3 or raise the floor to 60. Single-literal change, sync test catches drift. |
| 5 | Output literal `(adjusted from 100 — N of 9 sources dissented)` confuses readers | Low | Terse by design; parenthetical omitted when N = 100. |

## Out of scope / future work

1. **Conditional filtering of static-analysis findings.** Will be its own brainstorm and
   spec, with this spec's output shape as its stable input.
2. **Quantitative cross-reviewer voting protocol** — having cross-reviewers emit numeric
   dissent directly. Rejected for now; the synthesiser-as-arbiter model is simpler.
3. **Per-rule confidence tuning** (e.g. "ruff F401 starts at 95"). Out of scope. All
   static-analysis findings start at 100.
4. **New severity tiers** (e.g. "Blocker"). Out of scope. The three-tier scale stands.
5. **Severity-locking the eight LLM specialists.** Out of scope. Their LLM judgement *is*
   their value.

## Implementation phasing

The work decomposes into two phases, each its own PR.

### Phase 1 — Policy text + sync tests

1. Add §10 to `includes/static-analysis-context.md`.
2. Add severity-mapping table + Critical-allow-list to each of the four specialist files.
3. Add the carve-out paragraph and output literal to `agents/review-synthesiser.md`.
4. Add the three new sync tests.

Verification:
- `bash tests/run.sh` passes (gated tests skip cleanly).
- `CLAUDE_CODE_E2E_TESTS=1 bash tests/run.sh` still passes against the existing Stage 2
  results-file — Phase 1 must not regress the specialist-side smoke gate.

### Phase 2 — Synthesiser behavioural smoke (separate PR, conditional on Phase 1 merge)

1. Add `synthesiser_severity_lock` sub-check to the driver-prompt.
2. Extend the results-file schema to include a `synthesiser` block alongside `specialists`.
3. Run the driver from a Claude Code session, capture results, assert via the existing
   `tests/lib/test_static_analysis_behavioural.sh` consumer (extended).

If Phase 2 finds the policy is violated under stochastic load (e.g. floor breach in ≥ 1 of
3 iterations), the rollback is to inline the policy text into the synthesiser file
verbatim with a sync test, mirroring the Stage 2 rollback shape from the predecessor spec.
The cite-only design is empirically validated (Stage 2 of the predecessor) so this rollback
is unlikely; it is recorded for completeness.
