# Correctness / API-Contract Split — Design

**Date:** 2026-07-20
**Status:** Approved (brainstorming), pending spec review → writing-plans
**Plugin:** `code-review-suite` (marketplace repo `Jodre11/claude-code-plugins`)

## Problem

`correctness-reviewer` is frequently the wall-clock long pole among Stage-1
specialists on large PRs (user-observed, PR-type dependent — pronounced on PRs
heavy with new library calls / version bumps, not on pure logic-refactor PRs).

Specialists fan out in parallel (`review-core.mjs::dispatchSpecialists`), so the
slowest single agent sets the stage's wall-clock. `correctness-reviewer` carries
an API/contract-truth lens (`agents/correctness-reviewer.md:84-97`: hallucinated
APIs, wrong signatures/versions, comment-truth) that reads lockfiles/manifests and
can web-fetch docs — strictly more serial work than a peer that only reasons over
the diff. That sub-task is both the slowest and the most self-contained part of
correctness.

## Goal

Extract the API/contract-truth lens into a new parallel Stage-1 specialist,
`api-contract-reviewer`, so on code-heavy PRs the two halves run side-by-side
instead of one correctness agent grinding through everything serially.

**Success criteria (latency-led, but depth-gated):**
- **Latency:** on a code-heavy PR, the parallel pair (correctness + api-contract)
  finishes sooner than the pre-split serial correctness agent.
- **Depth:** the split arms catch *everything* the single correctness agent
  caught — zero net finding loss — and the near-miss inflation guards stay silent.
- Ship only if BOTH hold. If latency does not actually improve, the split is not
  worth its extra dispatch cost and we hold.

## Non-goals

- No change to the lightweight route (single `code-analysis` pass — the split
  only affects the full route's fan-out).
- No unrelated correctness rewording beyond removing the moved lens.
- Not bundled with the test-adequacy specialist work — this is a separate PR.
- No production model flip (haiku/low) in this change; that is a later probe,
  same as the other specialists.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Primary goal | Both, latency-led — faster AND at least as good; measure both |
| Measure timing first? | Build, then A/B validate (trust the observation; confirm at the end) |
| Split boundary | API/contract-truth only moves; silent-failure STAYS in correctness |
| Dispatch | Conditional on a changed source file (not always-on) |
| Cross-review | NOT a cross-reviewer (Stage-1 only; panel votes; consistent with retiring classic) |
| Agent name | `api-contract-reviewer` |

## Architecture

### What moves into `api-contract-reviewer`
The API/contract-truth lens, lifted verbatim where possible from
`correctness-reviewer.md:84-97`:
- **Hallucinated APIs / wrong signatures / wrong API versions** — verify library/
  framework calls against the version pinned in the project's lockfile/manifest
  (`package-lock.json`, `*.csproj`, `requirements.txt`, `go.sum`); web-fetch
  current docs when in doubt.
- **Comment-truth verification** — read each new/modified comment, docstring, or
  `///` summary against the code it describes; flag claims that don't match actual
  behaviour. Reaches Important via the **agent-hazard basis** when it would mislead
  a caller into writing wrong code.

### What stays in `correctness-reviewer`
Logic errors, off-by-one, null/undefined dereferences, race conditions, resource
leaks, error-handling gaps **including the silent-failure lens**
(`correctness-reviewer.md:79`), boundary conditions, type mismatches, async/await
pitfalls. Silent-failure stays because it is entangled with error-path reasoning;
splitting it would create a seam without independence gain.

### Why the boundary is clean
Logic/null/boundary/concurrency and silent-failure reason over the diff's
*behaviour*. API/contract-truth reasons over *external contracts* — signatures,
pinned versions, comments-vs-code. These are genuinely different modes of
reasoning, so the cut does not orphan a shared sub-concern.

### Dispatch model
- `api-contract` is a **conditional** specialist gated on a changed source file.
  Reuse `$PRODUCTION_SOURCE_DETECTED` if the test-adequacy work has landed;
  otherwise define the flag. Skips pure-docs/config PRs; the lens applies whenever
  code changes anyway, so miss-risk is low.
- `correctness` stays a **core** (always-on) domain.
- Only the **full route** fans out specialists; the lightweight route is untouched.

### Cross-review
`api-contract` is **not** a cross-reviewer: Stage-1 only, the panel votes on its
findings. It inlines the CHANGED_LINES filter block (byte-identical to canonical)
but NOT the cross-review-mode block, and is excluded from `crossDomains` via the
`NON_CROSS` set. `correctness` keeps its own cross-reviewer seat for the logic lens.

## Components / files touched

- **CREATE `agents/api-contract-reviewer.md`** — frontmatter (`model: sonnet`,
  `tools: Read, Grep, Glob, Bash`, `background: true`); API/contract-truth Focus
  Areas lifted verbatim where possible; standalone framing sentences added so it
  operates alone; inlines the CHANGED_LINES filter (byte-identical to
  `includes/specialist-context.md` canonical); cites `agent-hazard basis` for
  comment-truth severity. NO cross-review-mode block.
- **MODIFY `agents/correctness-reviewer.md`** — delete the API/contract-truth
  bullets (`:84-97`); leave logic/null/boundary/concurrency/resource-leak/
  silent-failure. Cross-review-mode and CHANGED_LINES blocks untouched.
- **MODIFY the three byte-identical pipeline copies** (`includes/review-pipeline.md`,
  `skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`) — detection flag +
  args key threading. Byte-identity enforced by
  `test_sync_pipeline_inline_matches_canonical`.
- **MODIFY `workflows/review-core.mjs`** — add `['api-contract', flags.<flag>]` to
  `CONDITIONAL`; add `api-contract` to `NON_CROSS`.
- **MODIFY `README.md`** — roster prose + domain-table row.
- **MODIFY `tests/lib/test_sync_notes.sh`** — enroll `api-contract-reviewer.md` in
  `test_sync_changed_lines_rule_matches_canonical`; update
  `test_sync_agent_hazard_severity_basis` (the `agent-hazard basis` citation moves
  out of correctness with the comment-truth lens — assert it in the new agent, and
  adjust the correctness assertion accordingly); extend the dispatcher-flags test if
  a new flag is introduced.
- **CREATE A/B corpus fixtures** — a hallucinated-API/wrong-signature hit, a
  comment-truth hit, and a near-miss inflation guard, at
  `agent: api-contract-reviewer`; plus `tests/ab/configs/per-agent/api-contract-baseline.yaml`.

## Findings-loss risk & mitigations

The real hazard of any split is a finding that used to be caught now falling
between two agents, or the extracted lens weakening for loss of context.

1. **Verbatim lift, not rewrite.** Move the Focus Areas byte-for-byte where
   possible. A rephrase risks silent behaviour drift (prose changes around an
   instruction shift small-model behaviour). Only add the standalone framing the
   agent needs to run alone.
2. **Comment-truth needs code context.** Comment-truth reads the implementation,
   not just the signature. The new agent keeps the full `Read/Grep` grant and the
   changed-lines diff — same context correctness had. The A/B must confirm no
   degradation.
3. **Clean boundary (see Architecture).** Behaviour-reasoning vs contract-reasoning
   don't share a sub-concern; silent-failure stays with error-path reasoning.

## Testing / validation

Structural (every task): `bash tests/run.sh` from repo root — all sync-note,
roster, enumeration, and agent-hazard-basis tests green.

Behavioural A/B (ship-gate, at the end, operator-run):
- **Depth:** corpus with planted API-truth / comment-truth / silent-failure /
  logic findings — the split arms must catch everything the single correctness
  agent caught (zero net loss); near-miss guards stay silent.
- **Latency:** per-trial `timing.json` on a code-heavy PR — the parallel pair
  finishes sooner than pre-split serial correctness. No improvement → hold.
- **haiku/low equivalence** probe later, before any production model flip.

## Dependencies / sequencing

- Shares `$PRODUCTION_SOURCE_DETECTED` and the `NON_CROSS` set with the
  test-adequacy specialist work (`docs/superpowers/plans/2026-07-20-test-adequacy-specialist.md`).
  Whichever lands second reuses what the first built; if this lands first, it
  defines both.
- Separate PR from test-adequacy. Per branch-protection, land via PR (no
  admin-bypass push to `main`).
