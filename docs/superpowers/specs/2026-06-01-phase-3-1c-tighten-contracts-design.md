# Phase 3.1c — tighten contracts + fail-loud

**Date:** 2026-06-01
**Status:** Approved (design); implemented (reconstructed 2026-06-02 after branch loss)
**Author:** Christian Haddrell
**Builds on:** Phase 3.1a empty-stdout investigation
([`../notes/2026-05-29-empty-stdout-investigation-result.md`](../notes/2026-05-29-empty-stdout-investigation-result.md),
PR #36, merged commit `dae8ca4`).
**Sits within:** Phase 3 static-specialist tuning sweep
([`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)).
**Unblocks:** Phase 3.1b (re-probe ruff cost-tuning).

## Context

Phase 3.1a's 20-trial Haiku/`low` sweep against `ruff-smoke-bad-py` documented two
distinct apparatus problems on the per-agent A/B harness with `--stream-json`
enabled:

1. **EMPTY incidence 30 %** (Wilson 95 % CI [14.55 %, 51.90 %]) — Category C
   envelope-final-text emission gap inside the Claude Code CLI's stream-json
   pipeline. The model emits 364–671 chars of canonical text across
   `assistant.message.content[].text` blocks, then the terminal
   `{type:"result", subtype:"success"}` envelope's `.result` field is the empty
   string. Identified as a CLI bug; tracked as a side artefact for upstream
   filing, not a PR gate.
2. **DRIFT incidence 65 %** (Wilson 95 % CI [43.29 %, 81.88 %]) — free-form
   ruff prose the harness's findings parser cannot match. The §7 markdown
   contract in `static-analysis-context.md` has already drifted in the captured
   baseline (`### Finding — title` canonical, `**Finding N**` actual; field
   names `Description` / `Suggested fix` canonical, `Message` / `Detail` actual).
   The current parser empirically retrofits to the drift.

3.1a's recommended fix surface — harness-level fallback recovery + validate-or-die
post-condition + contract pinning — is the subject of this spec. 3.1c is the
cross-cutting tightening sub-phase that lands all three changes plus a
validation sweep in a single coherent PR.

## Goals

**Primary goal.** Eliminate the apparatus-level noise floor on the per-agent
stream-json substrate so future static-specialist probes (Phase 3.1b, 3.2, 3.3,
3.4) can characterise model behaviour without 30 % silent-loss and 65 %
parser-mismatch confounders.

**Concrete deliverables.**

1. Harness fallback in `tests/ab/lib/launch.sh` — extend the existing
   stream-jsonl jq reduction so when `.result == ""` it falls back to
   concatenating `assistant.message.content[].text` blocks. Stream-json-conditional.
2. Validate-or-die assertion in `launch_run_per_agent_trial` after rc capture —
   fail loud (non-zero rc + structured stderr) when `stdout.log ≤ 1 byte AND
   (stream.jsonl missing OR no terminal result event OR result.subtype="error")`.
3. Contract pin — declare `static-analysis-context.md §7` authoritative,
   regenerate `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` to
   canonical form, drop the `**Finding N**` retrofit from
   `agent_capture_parse_ruff_trial`, add a worked §7 example block to
   `agents/ruff-reviewer.md`.
4. 20-trial Sonnet/default validation sweep against `ruff-smoke-bad-py` to
   prove DRIFT < 10 %, EMPTY = 0 (recovered into NORMAL), validate-or-die
   fires = 0.

**Success criteria.**

- Capture-side and parse-side changes ship together in one PR on branch
  `feat/phase-3-1c-tighten-contracts`.
- Tests 1, 2, 3 (see §Testing) pass in CI.
- Test 4 (baseline pre-flight) confirms the regenerated baseline parses to the
  canonical tuple hash `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`.
- Test 5 (validation sweep, ~50 k tokens) produces NORMAL ≥ 80 %, DRIFT < 10 %,
  EMPTY = 0, validate-or-die fires = 0 against `ruff-smoke-bad-py` at
  Sonnet/default.

## Non-goals

- Not a change to `agents/ruff-reviewer.md`'s `model:` field — stays at
  `sonnet` until Phase 3.1b's re-probe completes.
- Not a wiring of `--stream-json` through end-to-end mode (`tests/ab/run.sh
  --mode end-to-end`). The new helpers are shaped to accommodate it but
  3.1c is per-agent-codepath only.
- Not authoring eslint / trivy / jbinspect parsers. Those are 3.2 / 3.3 / 3.4
  work; only ruff's parser is retightened in 3.1c.
- Not filing the upstream Claude Code bug as part of this PR — tracked as a
  side artefact, gated separately.
- Not a revisit of 3.1a's verdict — that investigation is complete and
  load-bearing for everything below.

## Architecture

3.1c is a contract-tightening change to the per-agent A/B harness, not a new
module. The four deliverables compose into two architectural layers, with one
cross-cutting documentation pin and one validation activity.

### Layer 1 — Capture-side recovery (`tests/ab/lib/launch.sh`)

The harness already owns the `claude -p --output-format stream-json` invocation
and a jq reduction that materialises `stdout.log` from the terminal `result`
event. 3.1c extends that reduction (now `launch_jq_reduce_stream_jsonl`) with a
documented fallback path: when the canonical `.result` is empty but the trace
contains preceding `assistant.message.content[].text` blocks, concatenate those
blocks into `stdout.log` instead. The fallback is **stream-json-conditional** by
construction — without `stream.jsonl` there is no substrate to recover from.
Behaviour on the non-stream-json codepath is unchanged.

After the reduction, `launch_run_per_agent_trial` gains a **validate-or-die**
post-condition (`launch_assert_trial_recoverable`): if `stdout.log ≤ 1 byte` AND
(`stream.jsonl` missing OR no terminal `{type:"result"}` event OR
`result.subtype="error"`), the function returns non-zero with structured stderr.
The fallback runs first; only **unrecoverable** cases reach the assertion.

### Layer 2 — Parse-side contract enforcement (`tests/ab/lib/agent_capture.sh`)

Today's parser empirically tolerates two divergent shapes: canonical §7 and a
drifted shape (`**Finding N**` + `**Message:** / **Detail:**`). 3.1c
**retightens** the parser to canonical §7 only, removes the synonyms, and
heading-gates the emission so drifted shapes with no `### Finding` heading parse
to zero findings. To make that retightening safe, the captured baseline is
regenerated to canonical form. The agent prompt grows a fully-formed §7 example
block at the ruff-reviewer anchor so Sonnet emits the canonical shape
consistently.

### Cross-cutting pin (`plugins/code-review-suite/includes/static-analysis-context.md` §7)

The canonical §7 already exists. 3.1c declares it authoritative — no change to
§7's text; the pin is enforced through the parser tightening and the
agent-prompt example. Future static specialists inherit the contract.

### Validation activity

A 20-trial Sonnet/default sweep against `ruff-smoke-bad-py` runs after the
changes land, in the same PR. Token budget ~50 k.

## Components

### Unit A — `launch_jq_reduce_stream_jsonl` (new private helper, `tests/ab/lib/launch.sh`)

Reduce a `stream.jsonl` to a single canonical-text string. Tries `.result` from
the terminal `{type:"result", subtype:"success"}` event first; falls back to
concatenating `assistant.message.content[].text` blocks in stream order joined
by `\n` when `.result` is missing or empty. Returns 0 on any successful
reduction, non-zero only on jq invocation failure.
Interface: `launch_jq_reduce_stream_jsonl <stream_jsonl_path> <stdout_target_path>`.

### Unit B — `launch_assert_trial_recoverable` (new private helper, same file)

Validate-or-die post-condition. Unrecoverable predicate: `stdout.log ≤ 1 byte`
AND (`stream.jsonl` missing OR no terminal `{type:"result"}` event OR
`result.subtype="error"`). Structured stderr: one JSON object with stable fields
`{stage, reason, stdout_bytes, stream_jsonl_present, has_terminal_result, result_subtype}`.
Reason values (enumerated; adding one is a contract bump):
`empty_stdout_no_stream_jsonl`, `empty_stdout_no_terminal_result`,
`empty_stdout_subtype_error`, `empty_stdout_no_recovery_signal`.
Interface: `launch_assert_trial_recoverable <trial_dir>`.

### Unit C — `launch_run_per_agent_trial` (modified, same file)

Replace the inline jq reduction with `launch_jq_reduce_stream_jsonl`; add
`launch_assert_trial_recoverable "$trial_dir"` after rc capture, propagating its
rc only when the subprocess rc was 0 (a real timeout/CLI error takes precedence).

### Unit D — `agent_capture_parse_ruff_trial` (modified, `tests/ab/lib/agent_capture.sh`)

Drop the `/^\*\*Finding [0-9]+\*\*/` heading match; heading-gate the emission
(`in_finding_block`) so a tuple is emitted only after a canonical `### Finding`
heading. Update two comment blocks to drop `**Finding N**` / `Message` / `Detail`
references. No new awk logic beyond the gate.

### Unit E — Canonical baseline (`tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` + `source.yaml`)

Regenerate `findings-ruff.md` to canonical §7. The tuple
`{file: "bad.py", line: 1, rule_id: "F401", severity: "Important", confidence: 100}`
must hash to `7b003236…91c3` (direct file-shasum, matching
`_agent_capture_compute_hash`). `source.yaml`: bump `captured_at`, add
`baseline_revision: 2`, update `suite_sha` to the sweep SHA.

### Unit F — Agent-prompt example block (`plugins/code-review-suite/agents/ruff-reviewer.md`)

A worked F401 §7 example under `## Output`. Behavioural reinforcement so the
model reproduces the canonical shape. Scoped to ruff for 3.1c.

### Unit G — Validation sweep activity

Configuration: `tests/ab/run.sh --config tests/ab/configs/per-agent/ruff-baseline.yaml --corpus ruff-smoke-bad-py --trials 20 --timeout-seconds 600 --stream-json`.
Sonnet/default per the clarifying-question answer (Q5). (The config is
`ruff-baseline.yaml`, which declares `mode: per-agent`; `run.sh` derives the mode
from the YAML and has no `--mode` flag. Both corrected during execution —
Amendment 4, operator decision 2026-06-01.) Pass criteria: §Testing → Test 5.

## Error handling

### Surface 1 — Capture-side failures

| Subprocess outcome | rc | stdout.log |
|---|---|---|
| Exit non-zero (timeout/CLI error/signal) | propagated rc | usually empty |
| Exit 0, empty `stream.jsonl` | non-zero (validate-or-die) | empty |
| Exit 0, terminal `result.subtype="error"` | non-zero IF stdout empty; else 0 | tool-dependent |
| Exit 0, `subtype="success"`, `.result` empty | **0** (fallback recovers) | concatenated text blocks |
| Exit 0, `subtype="success"`, `.result` non-empty | 0 (canonical path) | `.result` verbatim |

### Surface 2 — Parse-side failures

Parse-side errors stay non-fatal (return 0 with empty findings.json). The DRIFT
class is the analysis layer's signal, not the parser's. No silent drift
retrofit: drifted shapes parse to zero findings and the sweep's <10 % gate flags
them.

### Surface 3 — Validation-sweep failure modes

| Failure | Response |
|---|---|
| EMPTY > 0 | Bug in the fallback. Fix Unit A in this PR. |
| validate-or-die fires | Bedrock instability that day OR unrecoverable upstream surface. Capture trace; if instability, rerun once. |
| DRIFT ≥ 10 % | Sonnet still drifts; escalate the example block or move it into the include. Fix in this PR. |
| NORMAL < 80 % (neither EMPTY nor DRIFT) | Unknown mode; triage as fresh investigation. |

## Testing

- **Test 1 — Unit A** against 4 fixture stream.jsonl files (canonical-success,
  empty-result-three-text-blocks, error-subtype, no-terminal-event).
- **Test 2 — Unit B** predicate cases (6: recovered-fallback, no-stream-jsonl,
  no-terminal-result, subtype-error, no-recovery-signal, non-stream-json).
- **Test 3 — parser tightening** (canonical/drifted/mixed/multi-finding).
- **Test 4 — baseline pre-flight** (manual; canonical hash `7b003236…91c3` via
  direct file-shasum — Amendment 1/3).
- **Test 5 — validation sweep** (20 trials, Sonnet/default; NORMAL ≥ 80 %,
  DRIFT < 10 %, EMPTY = 0, validate-or-die fires = 0).

Tests 1–3 are offline (CI); Test 4 is a one-shot pre-merge gate; Test 5 is the
merge gate.

## Related work

- Upstream Claude Code envelope-finalisation bug — side artefact, not a PR gate.
- Phase 3.1b (re-probe ruff cost-tuning) — blocked on 3.1c.
- Phase 3.2 / 3.3 / 3.4 — inherit the canonical §7 contract pin.

## Cross-references

- Phase 3.1a result report:
  [`../notes/2026-05-29-empty-stdout-investigation-result.md`](../notes/2026-05-29-empty-stdout-investigation-result.md)
- Phase 3 sweep spec (parent of 3.1c):
  [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)
- Static-analysis context (canonical §7 contract):
  [`../../../plugins/code-review-suite/includes/static-analysis-context.md`](../../../plugins/code-review-suite/includes/static-analysis-context.md)
- Ruff-reviewer agent (anchor for the example block):
  [`../../../plugins/code-review-suite/agents/ruff-reviewer.md`](../../../plugins/code-review-suite/agents/ruff-reviewer.md)
