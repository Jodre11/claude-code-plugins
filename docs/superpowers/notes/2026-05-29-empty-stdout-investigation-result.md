# Phase 3.1a — empty-stdout investigation result

**Date:** 2026-05-29
**Status:** Bug confirmed (Claude Code CLI envelope-final-text emission gap)
**Spec:** [../specs/2026-05-29-empty-stdout-investigation-design.md](../specs/2026-05-29-empty-stdout-investigation-design.md)
**Plan:** [../plans/2026-05-29-empty-stdout-investigation-plan.md](../plans/2026-05-29-empty-stdout-investigation-plan.md)
**Original anomaly:** [../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md](../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md)
**Run directory:** `tests/ab/runs/20260529T155034Z-ruff-haiku-low/` (gitignored)
**Suite SHA at sweep time:** `926e3faa8f5eb6941e1becbb750e18f30c0988ae` (`926e3fa` — "drop unneeded _AB_STREAM_JSON global, trim test docstring")

## Sweep configuration

- **Codepath:** per-agent harness (`tests/ab/run.sh` -> `agent_dispatch.sh`).
- **Specialist:** `ruff` (static analyser).
- **Fixture:** `ruff-smoke-bad-py` (one-line Python file, single canonical F401 finding expected).
- **Model / effort:** Haiku / `low`.
- **Forensic capture:** `--stream-json` enabled; per-trial `stream.jsonl` retained alongside `stdout.log`, `agent-output.md`, `findings.json`.
- **Trial count:** n=20.
- **Exit-code surface:** all rc=0, all `timed_out=false`, all `inconclusive=false`.
- **Wall-clock:** mean 22 s, range 16–32 s.
- **Sweep wall-clock:** kickoff 16:50:34 local (UTC 15:50:34), completion 16:59:21+0100 — total ~9 minutes.

## Class breakdown (n=20)

| Class  | Count | Percentage | Wilson 95% CI       |
|--------|-------|------------|---------------------|
| NORMAL |     1 |     5.00 % | [ 0.89 %, 23.61 %] |
| DRIFT  |    13 |    65.00 % | [43.29 %, 81.88 %] |
| EMPTY  |     6 |    30.00 % | [14.55 %, 51.90 %] |
| OTHER  |     0 |     0.00 % |                  — |
| **Total** | **20** | **100 %** | |

**Per-trial classification:**

| Trial | Class | rc | wall_s | findings | stdout_bytes | agent_out_bytes |
|-------|--------|----|--------|----------|--------------|-----------------|
| trial-001 | DRIFT  | 0 | 21 | 0 | 267 | 267 |
| trial-002 | EMPTY  | 0 | 25 | 0 |   1 |   0 |
| trial-003 | DRIFT  | 0 | 18 | 0 | 355 | 355 |
| trial-004 | DRIFT  | 0 | 24 | 0 | 340 | 340 |
| trial-005 | EMPTY  | 0 | 21 | 0 |   1 |   0 |
| trial-006 | EMPTY  | 0 | 27 | 0 |   1 |   0 |
| trial-007 | DRIFT  | 0 | 32 | 0 | 608 | 391 |
| trial-008 | DRIFT  | 0 | 25 | 0 | 655 | 437 |
| trial-009 | DRIFT  | 0 | 26 | 0 | 363 | 363 |
| trial-010 | DRIFT  | 0 | 23 | 0 | 461 | 461 |
| trial-011 | DRIFT  | 0 | 18 | 0 | 236 | 236 |
| trial-012 | NORMAL | 0 | 20 | 1 | 478 | 376 |
| trial-013 | DRIFT  | 0 | 16 | 0 | 251 | 251 |
| trial-014 | DRIFT  | 0 | 21 | 0 | 283 | 283 |
| trial-015 | EMPTY  | 0 | 22 | 0 |   1 |   0 |
| trial-016 | EMPTY  | 0 | 22 | 0 |   1 |   0 |
| trial-017 | DRIFT  | 0 | 23 | 0 | 423 | 423 |
| trial-018 | DRIFT  | 0 | 23 | 0 | 403 | 403 |
| trial-019 | DRIFT  | 0 | 21 | 0 | 341 | 341 |
| trial-020 | EMPTY  | 0 | 26 | 0 |   1 |   0 |

The single NORMAL trial (trial-012) produced `findings.json` containing
`[{"file":"bad.py","line":1,"rule_id":"F401","severity":"Important","confidence":100}]`,
hashing to the canonical baseline
`7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`.

## Headline result

The empty-stdout anomaly reproduces at **30.00 % incidence (6/20, Wilson 95 % CI
[14.55 %, 51.90 %])** on the per-agent codepath at Haiku/`low` against
`ruff-smoke-bad-py` with `--stream-json` enabled. This tightens the prior estimate
of 2/9 ≈ 22 % (one trial in Phase 1 end-to-end mode 2026-05-21 + one trial in
Phase 3.1 per-agent mode 2026-05-29). The 30 % point estimate from this sweep
falls inside the prior wide CI; the Phase 3.1a interval is materially narrower
and rules out the "single-digit-percent rare event" interpretation. Empty-stdout
is a frequent, reliably reproducible failure mode at this configuration — not a
once-a-week tail event.

## Per-EMPTY trace inspection

Across all 6 EMPTY trials the terminal `stream.jsonl` event was uniform:
`{type:"result", subtype:"success", is_error:false, stop_reason:"end_turn",
result:""}` with `terminal_reason="completed"` and `api_error_status=null`.
tool_use / tool_result counts balanced in every trace; no orphan tool calls. The
preceding `assistant.message.content[]` events contained between 364 and 671
chars of canonical ruff-finding prose distributed across 3–5 text blocks. All
six trials are **Category C (envelope-final-text emission gap)**.

### trial-002

- **Wall-clock:** 25 s. **JSONL lines:** 29. **num_turns:** 7.
- **Assistant text blocks:** 5 (671 chars). **tool_use / tool_result:** 6 / 6.
- **Permission denials:** 1 (Bash).
- **Trace shape:** Tool turns balanced; 5 assistant text blocks (671 chars)
  preceded the terminal envelope. One Bash permission denial mid-run did not
  derail completion. All canonical ruff prose lost to the empty `.result`.
- **Category:** **C** — content present in `assistant.message.content[]`
  (671 chars); envelope `.result` empty; success subtype; not an error or
  truncation.

### trial-005

- **Wall-clock:** 21 s. **JSONL lines:** 22. **num_turns:** 5.
- **Assistant text blocks:** 3 (554 chars). **tool_use / tool_result:** 4 / 4.
- **Permission denials:** 0.
- **Trace shape:** Shortest trace in the EMPTY cohort; 3 assistant text blocks
  (554 chars) lost to the empty envelope. Clean tool-use cycles.
- **Category:** **C** — content present (554 chars); envelope `.result` empty;
  success subtype; no error surface.

### trial-006

- **Wall-clock:** 27 s. **JSONL lines:** 25. **num_turns:** 6.
- **Assistant text blocks:** 4 (429 chars). **tool_use / tool_result:** 5 / 5.
- **Permission denials:** 0.
- **Trace shape:** Longest wall-clock in the EMPTY cohort; 4 assistant text
  blocks (429 chars) lost. Tool turns balanced.
- **Category:** **C** — content present (429 chars); envelope `.result` empty;
  success subtype.

### trial-015

- **Wall-clock:** 22 s. **JSONL lines:** 27. **num_turns:** 7.
- **Assistant text blocks:** 4 (364 chars). **tool_use / tool_result:** 6 / 6.
- **Permission denials:** 1 (Bash).
- **Trace shape:** One Bash permission denial mid-run; 4 assistant text blocks
  (364 chars) preceded the empty envelope. Smallest text payload of the cohort.
- **Category:** **C** — content present (364 chars); envelope `.result` empty;
  success subtype.

### trial-016

- **Wall-clock:** 22 s. **JSONL lines:** 27. **num_turns:** 7.
- **Assistant text blocks:** 4 (475 chars). **tool_use / tool_result:** 6 / 6.
- **Permission denials:** 0.
- **Trace shape:** Trace shape identical to trial-015 (same JSONL line count,
  same num_turns, same tool_use / tool_result balance) but no permission denial
  — 4 assistant text blocks (475 chars) lost to the empty envelope.
- **Category:** **C** — content present (475 chars); envelope `.result` empty;
  success subtype.

### trial-020

- **Wall-clock:** 26 s. **JSONL lines:** 26. **num_turns:** 6.
- **Assistant text blocks:** 4 (612 chars). **tool_use / tool_result:** 5 / 5.
- **Permission denials:** 0.
- **Trace shape:** Largest assistant-text payload in the EMPTY cohort — 612
  chars across 4 blocks — yet `.result` is still empty. Particularly clean
  counter-evidence to any "model produced no terminal text" interpretation.
- **Category:** **C** — content present (612 chars); envelope `.result` empty;
  success subtype.

**Category distribution among EMPTY trials:** A=0, B=0, **C=6**, D=0. Every EMPTY
trial in the sweep is a Category C envelope-final-text emission gap.

## Probable cause hypothesis

The empty-stdout anomaly is bounded and reliably reproducible at the SDK-envelope
layer of the Claude Code CLI. Across 6/20 trials (30 %, 95 % CI 14.55 %–51.90 %),
`claude -p --output-format stream-json` produces a `result.subtype=success`
envelope whose `.result` field is the empty string, despite the model emitting
364–671 chars of canonical text content across multiple preceding
`assistant.message.content[]` text blocks. The bug is **not** an exit-code
failure, **not** a Bedrock-error surface, **not** a partial-stream truncation,
and **not** an orphan tool-use cycle — it is an envelope-final-text emission gap
inside the CLI's stream-json pipeline.

The most plausible mechanism is a CLI-internal serialisation step that
constructs the terminal envelope's `.result` from the last assistant text block
(or some equivalent reduction over `.message.content`) and intermittently
produces an empty string. The 30 % incidence at Haiku/`low` — a tier where the
agent runs many short tool-use cycles before its closing prose — is consistent
with a race or boundary condition in envelope finalisation. Higher-tier
configurations with longer, more deliberative final turns are likely to see
lower incidence; this is testable in Phase 3.1b but not assumed.

## Recommended fix surface (for Phase 3.1c)

A combination of harness-level recovery and durable upstream filing is the
safest disposition:

1. **Harness-level fallback (primary, Phase 3.1c work).** When the harness
   detects `stdout.log` ≤ 1 byte AND `stream.jsonl` contains a terminal
   `{type:"result", subtype:"success"}` event, fall back to concatenating the
   `text` blocks from preceding `assistant.message.content[]` events. This
   recovers the model's actual output without depending on an upstream fix and
   restores the 30 % of trials currently dropped. The fallback is unconditional
   on `--stream-json` being on; the harness only has the fallback signal when
   stream-json is enabled, which becomes a default for forensic-capture-aware
   probes going forward.
2. **Validate-or-die assertion (complementary, Phase 3.1c work).** The harness
   should explicitly fail loud (non-zero rc, structured stderr) on the
   `stdout.log ≤ 1 byte AND (stream.jsonl missing OR result.subtype=error)`
   case, so end-to-end mode (which doesn't have a stream-json substrate yet) at
   minimum surfaces the anomaly rather than silently producing
   `INCONCLUSIVE` / `APPROVE`.
3. **Upstream Claude Code bug filing (durable).** The envelope-final-text
   emission gap is the durable fix and lies outside the harness — file as a
   Claude Code bug with the trial-002 / 005 / 006 / 015 / 016 / 020 stream.jsonl
   excerpts as evidence. The harness fallback insulates the programme until
   upstream lands.

The orchestrator-level safety net option originally floated in
[../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md](../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md)
is **not** recommended at this point — it would address only the end-to-end
mode variant, and the per-agent fallback above is more general (covers any
stream-json-aware codepath) and cheaper to implement.

## DRIFT observations (informational)

13/20 trials (65 %, Wilson 95 % CI [43.29 %, 81.88 %]) produced 235–655 bytes
of free-form ruff prose that the harness's findings parser could not match.
This is a distinct failure mode from EMPTY: parser-mismatch on **present
content** (the model reasoned about ruff findings in prose, but did not emit
the structured JSON the harness's contract requires) versus EMPTY's
envelope-final-text loss on a successful run. The DRIFT incidence is
independent confirmation of the Phase 3.1 "abandon-for-cause" verdict on
ruff/Haiku/`low`. Investigating and contracting this prose-vs-JSON drift is the
explicit subject of **Phase 3.1c**, not 3.1a — DRIFT is recorded here purely
for completeness.

## What this unblocks

**Phase 3.1c (cross-cutting "tighten contracts + fail-loud").** 3.1a names two
concrete fix-surface items (harness fallback + validate-or-die) that 3.1c can
brainstorm and implement as a single coherent change. The DRIFT 65 % rate
documented above is the second, larger contract problem 3.1c will inherit and
must address alongside the EMPTY recovery.

**Phase 3.1b (re-probe ruff after fixes).** Once 3.1c lands, 3.1b can re-run a
sweep of ruff/Haiku/`low` against `ruff-smoke-bad-py` with the harness
fallback in place and confirm: (a) EMPTY trials are recovered into NORMAL or
DRIFT outcomes; (b) the underlying NORMAL rate (currently 5 %) lifts to
something usable; (c) any residual EMPTY incidence is genuinely upstream and
must wait for the Claude Code CLI fix.

**Phases 3.2 / 3.3 / 3.4 (other static specialists, then non-static, then
multi-specialist).** The 30 % EMPTY noise floor inherits to every future probe
on the per-agent stream-json substrate until 3.1c is in place. **Trial-count
revision:** 30 % incidence makes 3-trial faithfulness checks statistically
uninterpretable — a 0/3 result has Wilson 95 % CI [0 %, 56 %] and a 1/3 result
has CI [6 %, 76 %], neither of which distinguishes "the bug is gone" from "the
bug is still there at 30 %." Future probes should use **≥10 trials per arm
minimum** when characterising any new failure mode against this noise floor;
3-trial smoke checks remain valid only for confirming an arm is alive at all
(rc=0, non-empty findings) and not for incidence estimates.

## Reproduction

```bash
git checkout 926e3fa
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json
```

The model and effort axes (`haiku` / `low`) flow from
`tests/ab/configs/per-agent/ruff-haiku-low.yaml` (`session.model: haiku`,
`session.effort: low`); no separate CLI flag is needed.

**Expected outcome:** ~6 of 20 trials (Wilson 95 % CI [14.55 %, 51.90 %])
classify as EMPTY (`stdout.log` ≤ 1 byte, `stream.jsonl` terminal
`result.subtype=success` with `result.result == ""`). Exit codes are uniformly
0; wall-clock 16–32 s per trial; total sweep wall-clock ~9 minutes.
