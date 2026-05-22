# Orchestrator empty-stdout anomaly under `claude -p`

> **Status:** Open — anomaly worth investigating. **Not a confirmed
> defect.** Surfaced 2026-05-21 by the A/B harness Phase 1 no-ultrathink
> arm trial 2 (run dir `tests/ab/runs/20260521T162805Z-no-ultrathink/`).
>
> **Replaces an earlier draft** that prematurely attributed this to
> `ultrathink` removal. The forensic evidence below shows the upstream
> pipeline (specialists + cross-reviewers + synthesiser) ran to completion
> — the failure is at the orchestrator's final emission step.

## The observation

`claude -p` invocation on a no-ultrathink trial:

- **Wall-clock:** 1324s (within the normal 920-1520s range observed
  across 5 sibling trials)
- **Exit code:** 0
- **Stdout:** 1 byte (a single newline)
- **Stderr:** 0 bytes

No error, no warning, no partial output. The lifecycle wrapper saw the
process complete normally.

## What ran successfully

The trial's `CLAUDE_TEMP_DIR`
(`/tmp/claude-a253eef7-1856-4d1a-b54f-0197704e1a3e/`) preserves a
complete forensic record:

- 8 specialist reports (`findings-*.md`, totalling 17 KB consolidated
  in `all-findings.md`)
- 8 cross-review opinions (`cross-*.md`, totalling 14 KB consolidated in
  `all-cross-opinions.md`)
- Synthesiser dispatch executed: token-usage log records the synthesiser
  using **158,392 tokens, 49 tool uses, 368.7s wall-clock** — the
  largest synthesiser turn of the entire 6-trial run

The synthesiser ran. The synthesiser produced output. **What we cannot
verify is what the orchestrator did with the synthesiser's output.**

## Where the failure is

The orchestrator's responsibility under
`plugins/code-review-suite/skills/review-gh-pr/SKILL.md` Step 6/7 is
to receive the synthesiser report, apply the verdict rubric, and emit a
top-level summary to its own assistant turn. `claude -p` then captures
that turn as stdout.

The empty stdout means the orchestrator's final assistant turn was
itself empty (or absent). **The synthesiser is not implicated.** The
synthesiser produced 158K tokens of output before the orchestrator
silently dropped its emission step.

## Plausible causes, rough probability order

1. **`claude -p` emission swallowed.** The CLI may exit cleanly without
   writing the orchestrator's final assistant turn under specific
   conditions (e.g. tool-use turn that returns a large response and
   then no terminating text turn before session end).
2. **Orchestrator session ending without final turn.** If the
   orchestrator's reasoning concludes inside a tool-use cycle (e.g.
   reading the synthesiser report file, running a `gh` command for
   PR-state check, then looping into another file read) without
   producing a terminating text emission, `-p` would produce empty
   output even with a clean exit.
3. **Bedrock API blip terminating the orchestrator's session.** Less
   likely given the clean exit-0 path.
4. **`ultrathink` removal indirectly causing the orchestrator to
   under-think.** If the orchestrator inherits any thinking-budget
   signal from the synthesiser dispatch, removing `ultrathink` from
   that dispatch could affect the orchestrator's downstream behaviour.
   This is speculative.

(1) and (2) are independent of `ultrathink`. They would explain the
observation without invoking the experiment's mutation. (4) is the
hypothesis that ties back to the experiment but is unsupported by the
single data point.

## What we DON'T know

- **Whether this is `ultrathink`-related or general.** A single
  no-ultrathink trial out of three is suggestive but not enough to
  attribute. Baseline trials (n=3) had no empty-stdout cases, but n=3
  is too small to claim baseline never produces empty stdout either.
- **Whether the orchestrator session actually terminated cleanly or
  the orchestrator entered a hung tool-use cycle that hit some
  internal limit.** The token-usage log records up through the
  synthesiser; we have no orchestrator-level emission log.
- **The frequency of this failure mode.** One observation. Could be
  1-in-1000, could be 1-in-3.

## Why this matters even without a causal story

A code review tool that 1-in-N times reports nothing — with exit 0
and no stderr — is silent failure. A CI gate or a reviewer that polls
for the orchestrator's verdict file would treat this as "no findings,
APPROVE" by default. The harness caught it because it materially
matters whether `summary.csv` says `INCONCLUSIVE` or `APPROVE`.

The right disposition for production is to **make the failure
observable**, regardless of cause:

- Orchestrator-level guard in the review-gh-pr skill: if the
  synthesiser report is non-empty but the orchestrator's own emission
  is empty, exit non-zero with a diagnostic.
- `claude -p`-level reporting: if the orchestrator produces no
  terminating assistant text turn, exit non-zero rather than 0.

## What we should NOT do

- **Strip `ultrathink` from production based on the (still-incomplete)
  Phase 1 wall-clock data.** The wall-clock delta is 11.7% — well
  inside the noise floor. AND we now know empty-output trials exist
  somewhere in the stack. Moving any production lever before
  understanding the failure mode is premature.
- **Conclude this trial proves anything about `ultrathink`.** It
  proves only that the failure mode exists and is silent.
- **Treat baseline's apparent reliability (3 of 3 produced output) as
  meaningful.** n=3 cannot establish a baseline rate.

## What we SHOULD do

1. **Reproduce on baseline.** Run baseline (with `ultrathink` on) for
   ≥10 trials and measure whether empty-stdout trials occur at
   non-trivial rate. If they do, the cause is independent of
   `ultrathink`. If they don't, the case for an `ultrathink` link
   strengthens.
2. **Reproduce on no-ultrathink.** Run no-ultrathink for ≥10 trials.
   Same logic.
3. **Add a harness-level "non-empty stdout" check** as a post-trial
   assertion that flags an anomaly explicitly rather than relying on
   the sentinel-row mechanism.
4. **Add an orchestrator-level safety net** in
   `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` so an
   empty-orchestrator-emission case becomes loud (exit non-zero +
   stderr message) rather than silent (exit 0 + empty stdout).
5. **Use `--output-format stream-json`** in any reproduction trials
   so the orchestrator's tool-use sequence at the moment of
   non-emission is observable.

## Where the durable record lives

- **Run dir:** `tests/ab/runs/20260521T162805Z-no-ultrathink/`
  (gitignored)
- **Trial 2 stdout:** `trial-002/stdout.log` — 1 byte (single newline)
- **Trial 2 timing:** `trial-002/timing.json` records exit 0, 1324s,
  no timeout
- **Trial 2 intermediate artefacts:**
  `/tmp/claude-a253eef7-1856-4d1a-b54f-0197704e1a3e/` — full pipeline
  ran (specialists, cross-reviewers, synthesiser), preserved until OS
  cleanup
- **Sibling trial 1 stdout:** `trial-001/stdout.log` — 17 lines of
  normal review output (proves the no-ultrathink config CAN produce
  output; the failure is intermittent)

## Filing convention

`*-anomaly` rather than `*-defect` because the cause is unknown and
this report stops short of attribution. Promote to a design doc + plan
if reproduction confirms the failure mode is a real defect requiring
fix. Until reproduction lands, the right disposition is
"investigate".

## Cross-references

- Phase 1 harness spec:
  [`2026-05-21-ab-test-harness-design.md`](2026-05-21-ab-test-harness-design.md)
- Rubric row 2 stability follow-up (separate issue, do not conflate):
  [`2026-05-21-rubric-row-stability-followup.md`](2026-05-21-rubric-row-stability-followup.md)
- Per-agent testing direction (the recommended next step instead of
  more end-to-end runs):
  [`2026-05-21-per-agent-testing-direction.md`](2026-05-21-per-agent-testing-direction.md)
