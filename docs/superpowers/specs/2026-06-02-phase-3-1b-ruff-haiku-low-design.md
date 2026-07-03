# Phase 3.1b — ruff-reviewer Haiku/low re-probe (design)

**Date:** 2026-06-02
**Status:** Approved (design); not yet implemented
**Author:** Christian Haddrell
**Builds on:**
- Parent methodology: [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md) (Steps 4–5)
- Precedent sweep: [`../notes/2026-05-29-empty-stdout-investigation-result.md`](../notes/2026-05-29-empty-stdout-investigation-result.md) (Phase 3.1a)
- Apparatus fix that unblocks this phase: [`../notes/2026-06-02-phase-3-1c-validation-sweep.md`](../notes/2026-06-02-phase-3-1c-validation-sweep.md) (Phase 3.1c, PR #39, merge `a01c876`)

## Context

Phase 3.1a ran a 20-trial Haiku/low sweep of `ruff-reviewer` against the
`ruff-smoke-bad-py` smoke fixture and found the arm uninterpretable: 30 % EMPTY
(6/20, Wilson 95 % CI [14.55 %, 51.90 %]), 65 % DRIFT (13/20), and only 5 %
NORMAL (1/20). The EMPTY pathology was diagnosed as a Claude Code CLI
envelope-final-text emission gap (Category C): the model emitted 364–671 chars
of canonical ruff prose across preceding `assistant.message.content[]` text
blocks, but the terminal `{type:"result", subtype:"success"}` envelope carried
an empty `.result` string. The DRIFT pathology was prose-vs-JSON
parser-mismatch on present content.

Phase 3.1c (merged, PR #39, squash commit `a01c876`) eliminated the
apparatus-level noise floor with four changes:

1. **Harness fallback** (`launch_jq_reduce_stream_jsonl` in `tests/ab/lib/launch.sh`):
   when the terminal `.result` is empty, recover stdout by concatenating
   `.text` blocks from preceding `assistant` events in stream order.
2. **Validate-or-die** (`launch_assert_trial_recoverable`): fail loud (non-zero
   rc, structured stderr JSON) on a genuinely unrecoverable trial
   (`stdout.log ≤ 1 byte` AND no recovery signal in `stream.jsonl`).
3. **Parser pinned to canonical §7** (tightened `agent_capture` parser).
4. **§7 example block** added to the captured baseline.

3.1c's own validation sweep (Sonnet/default, n=20) returned a clean 20/20
NORMAL with zero DRIFT, zero EMPTY, and zero validate-or-die fires. The
apparatus noise floor is gone on the per-agent stream-json substrate.

With that in place, 3.1b can finally ask its real (cost-tuning) question, which
3.1a could not answer against the noise floor.

## The question

For `ruff-reviewer`, is Haiku/low equivalent to the Sonnet/default baseline on
finding sets, now that the apparatus noise floor is eliminated? Specifically:

- **(a)** Are the EMPTY trials (30 % incidence at Haiku/low in 3.1a) now
  recovered into NORMAL or DRIFT outcomes by the 3.1c fallback?
- **(b)** Does the underlying NORMAL rate (5 % = 1/20 in 3.1a, pre-fix) lift to
  something usable now that EMPTY is recovered and the parser is pinned?
- **(c)** Is any residual unrecoverable EMPTY genuinely upstream (the CLI
  envelope-finalisation bug) and therefore not fixable in the harness?

## Goals

- A 20-trial Haiku/low sweep of `ruff-reviewer` against `ruff-smoke-bad-py` on
  the merged (post-3.1c) harness, classified NORMAL/DRIFT/EMPTY/OTHER with
  Wilson 95 % CIs.
- A before/after comparison against the 3.1a Haiku/low sweep (same arm, same
  fixture, same trial count) showing whether the EMPTY and DRIFT pathologies
  cleared.
- An equivalence verdict against the Sonnet/default baseline per the parent
  spec's Step 5 framework.
- A one-page report at
  `docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md`.

## Non-goals

- **Not** a production config change. This probe *informs* a later adoption
  decision; it does not itself flip any `*-reviewer.md` `model:` field.
- **Not** a re-litigation of 3.1c. The harness fix is merged and validated; this
  phase consumes it, it does not revisit it.
- **Not** an upstream CLI bug filing. The envelope-finalisation gap is a durable
  upstream fix tracked separately; the harness fallback insulates the programme
  in the meantime.
- **Not** the other three static specialists (eslint, trivy, jbinspect). Per the
  parent spec's sequencing, ruff runs first; its result decides whether the
  sweep continues at full scope. Those are out of scope for 3.1b.

## Design decisions

Four decisions were settled at the operator gate before any Bedrock spend:

### 1. Trial count — n=20

Matches 3.1a's 20-trial Haiku/low sweep *and* 3.1c's 20-trial Sonnet baseline,
giving a clean like-for-like before/after on the same arm and the same
equivalence target. Satisfies 3.1a's `≥10 trials/arm` mandate with margin
(3.1a established that the parent spec's original 3-trial Step 4 is
statistically uninterpretable against a 30 % noise floor, and is superseded).
Cost: ~50 k Bedrock tokens, ~9–10 min wall-clock.

### 2. Arms — Haiku/low only; cite 3.1c Sonnet baseline

Run only the Haiku/low arm this session. Reuse 3.1c's validation sweep
(2026-06-02, 20/20 NORMAL, canonical tuple hash `7b003236…91c3`) as the
Sonnet/default equivalence target rather than re-running a fresh Sonnet arm
(saves ~50 k tokens).

**Provenance.** 3.1c's validation swept `ed437cb` (head of
`feat/phase-3-1c-tighten-contracts` at sweep time); `main` is the squash-merge
`a01c876`. The functional harness is byte-identical across the two SHAs —
verified: `git diff ed437cb a01c876 -- tests/ab/lib/ tests/ab/run.sh
tests/ab/corpus/ruff-smoke-bad-py/expected/ tests/ab/configs/` is empty. The
only delta in the whole `tests/ab/` tree is the `captured_under.suite_sha`
provenance string in `ruff-smoke-bad-py/source.yaml` (`<sweep-sha-tbd>` →
`ed437cb…`), which does not affect sweep behaviour. The baseline citation is
therefore sound. The 3.1b sweep itself runs on `a01c876` (current `main`,
the base of this branch).

### 3. Verdict framework — parent Step 5 + explicit recovery rule

Verdict ∈ {`equivalent` | `better` | `worse` | `inconclusive`}, with the parent
spec's >25 % movement guard for any non-equivalent outcome, measured as the
Haiku/low NORMAL (canonical-hash match) rate versus the Sonnet baseline's
100 %. On any divergence, report cost delta (wall-clock per trial per arm) and
recall direction (does Haiku/low *miss* findings or *fabricate* them).

**Recovered-trial accounting.** A fallback-recovered trial that parses to the
canonical tuple counts as **NORMAL**; one that recovers to prose-only counts as
**DRIFT**. Within-arm non-determinism (a mix of canonical and non-canonical
hashes across trials) defaults to `inconclusive` / "no" — non-determinism in a
transmission task is itself a defect.

### 4. Residual EMPTY — footnote as upstream; do not block verdict

A fallback-recovered EMPTY is counted as its recovered class (NORMAL or DRIFT),
not as EMPTY. A genuinely unrecoverable EMPTY (validate-or-die fires) is
reported explicitly and attributed to the upstream CLI envelope-finalisation
gap, but does **not** block the adoption verdict. If it fires, its count is
stated and those trials are excluded from the equivalence denominator (with the
adjusted n noted).

## Methodology

### Step 0 — Pre-flight (offline)

- Confirm the branch `feat/phase-3-1b-ruff-reprobe` is pushed to `origin`
  (autoUpdate-wipe guard; see the
  `marketplace-autoupdate-wiped-unpushed-branch` memory).
- Confirm the configs and fixture are present and unchanged:
  `tests/ab/configs/per-agent/ruff-haiku-low.yaml` (`model: haiku`,
  `effort: low`), `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md`,
  canonical tuple hash `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`.
- Reconstruct the classification + Wilson-CI tooling (see Step 2). This is the
  same logic 3.1c used; it is a per-run analysis overlay and is not committed to
  the harness.

### Step 1 — Bedrock sweep (operator-gated)

Surface the cost (~50 k tokens, ~9–10 min) and stop at an operator gate before
spending. On go-ahead, run:

```bash
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json \
    --name ruff-haiku-low-reprobe
```

The model/effort axes flow from the config YAML (`session.model: haiku`,
`session.effort: low`); the run mode is config-derived (`mode: per-agent`);
there is no `--mode` flag. Per-trial `stream.jsonl`, `stdout.log`,
`agent-output.md`, and `findings.json` are retained for forensic classification.

### Step 2 — Classification + CIs (offline)

Reconstruct the per-run `classification.csv` overlay from the run dir,
classifying each trial:

- **NORMAL** — `findings_count == 1` AND findings hash == canonical
  `7b003236…91c3` (rule F401). Includes fallback-recovered trials whose
  recovered stdout parses to the canonical tuple.
- **DRIFT** — present content (recovered or direct) that the parser cannot match
  to the canonical tuple (e.g. prose-only recovery, wrong findings count, wrong
  fields).
- **EMPTY** — genuinely unrecoverable (validate-or-die fired). Distinct from
  3.1a's EMPTY, which the 3.1c fallback now recovers.
- **OTHER** — anything else (timeout, rc≠0, inconclusive).

Corroborate row-for-row against the harness's native `summary.csv`. Compute
Wilson 95 % CIs per class. Record any validate-or-die fires with their
structured-stderr reason
(`empty_stdout_no_stream_jsonl` | `empty_stdout_subtype_error` |
`empty_stdout_no_recovery_signal`).

### Step 3 — Operator gate (classification + verdict)

Surface to the operator: the class breakdown with Wilson CIs, the before/after
delta versus 3.1a (EMPTY 30 %→?, DRIFT 65 %→?, NORMAL 5 %→?), the equivalence
verdict against the Sonnet/default 100 % baseline, and any residual
unrecoverable-EMPTY footnote. Wait for confirmation before writing the report.

### Step 4 — One-page report

Write `docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md` per the
parent spec's Step 5:

- Fixture (path + brief description).
- Sonnet/default baseline (cited 3.1c result: hash + 20/20 NORMAL), with the
  `ed437cb`↔`a01c876` provenance footnote.
- Haiku/low 20-trial class breakdown + Wilson CIs + per-trial table.
- Before/after comparison versus 3.1a (EMPTY/DRIFT/NORMAL deltas).
- Wall-clock per trial (cost delta number).
- Verdict (`equivalent` | `better` | `worse` | `inconclusive`) with the >25 %
  movement guard and recall direction on any divergence.
- Adoption recommendation with confidence level (informational; does not flip
  production config).
- Residual unrecoverable-EMPTY footnote, if any, attributed upstream.

### Step 5 — Land

Commit the spec, plan, report, and any classification tooling on
`feat/phase-3-1b-ruff-reprobe`; push after every commit; open a PR against
`main`. The run dir under `tests/ab/runs/` is gitignored (local only).

## Operational constraints

- **Push immediately.** This clone (`~/.claude/plugins/marketplaces/jodre11-plugins`)
  is an autoUpdate-managed marketplace clone. A prior autoUpdate reclone wiped
  an unpushed branch (2026-06-02). Push `feat/phase-3-1b-ruff-reprobe` to
  `origin` on the first commit and re-push after every commit. Never leave work
  unpushed here.
- **Bash hook rules.** No compound commands (`&&`, `||`, `;`), no `$(...)` or
  backticks (except the commit/PR HEREDOC carve-out), no loops/subshells in a
  single Bash call. Any multi-step shell recipe goes in a script file run with
  one `bash <path>` call. Temp files under `$CLAUDE_TEMP_DIR`.
- **Variation via the harness, never the agent.** Model/effort variation flows
  from the config YAML and external mutation, never from editing
  `ruff-reviewer.md`.

## Cost expectation

One 20-trial Haiku/low sweep: ~50 k Bedrock tokens, ~9–10 min wall-clock. All
other work (spec, plan, classification, report) is offline.

## Cross-references

- Parent Phase 3 spec: [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)
- Phase 3.1a result: [`../notes/2026-05-29-empty-stdout-investigation-result.md`](../notes/2026-05-29-empty-stdout-investigation-result.md)
- Phase 3.1c validation sweep: [`../notes/2026-06-02-phase-3-1c-validation-sweep.md`](../notes/2026-06-02-phase-3-1c-validation-sweep.md)
- Phase 3.1c PR: https://github.com/Jodre11/claude-code-plugins/pull/39
