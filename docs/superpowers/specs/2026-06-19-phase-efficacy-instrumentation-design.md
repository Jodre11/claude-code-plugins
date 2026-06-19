# Per-cog I/O instrumentation for phase-efficacy analysis — design

**Date:** 2026-06-19
**Plugin:** `code-review-suite`
**Tracking:** GitHub issue #63 (forward programme, thread 2 — phase-efficacy analysis).
Also seeds #64 (per-specialist model/effort sweep) and #65 (synthesiser model/effort
validation).

## Problem

Thread 2 (#63) asks whether each pipeline phase earns its keep:

- What do specialists produce in the first pass (the baseline finding set)?
- Does **cross-review** net ADD findings or net REMOVE/suppress them — and are the
  additions high-quality or noise?
- Does the **synthesiser**, after cross-review, surface MORE findings or consolidate
  DOWN — what does it add vs. filter?

The thread was scoped as observational: it consumes "the full unfiltered logs from real
reviews" — the log-everything layer built by the output-presentation work (#58/#59).

**The gap:** that layer does not capture what #63 needs. `buildLogPayload`
(`workflows/review-core.mjs:584`) reads only the *final* `envelope.tiers` (consensus /
synthesiser / contested / dismissed). The per-phase journey is discarded:

- Round-1 per-specialist findings (`findingsByDomain`, `review-core.mjs:177`) — not captured.
- Cross-review output (`crossOpinions` + `crossEscalations`, `:291–297`) — local to
  `crossAndSynth`, never returned.
- The synth's *input* (the specialist set it worked from) — not captured, only its output.

The token rows in `$CLAUDE_TEMP_DIR/tokens.jsonl` carry per-phase *cost* but not per-phase
*findings*. So today's log shows the destination, not the route — it cannot answer any of
#63's three questions.

A second gap: `orchestration.full_log` defaults OFF (`SKILL.md:1366`), so without enabling
it no durable log accrues at all.

## Goal

Reframed during brainstorming from "log per-phase deltas" to the stronger, better
requirement: **capture enough to replay each cog against recorded input.** The unit of
capture is the **cog** (each specialist, each cross-reviewer, the synthesiser), not the
phase. The durable log becomes a **fixture corpus**: every cog independently re-runnable
from its own recorded (or reconstructable) input.

This serves three threads from one instrument:

- **#63** — per-cog I/O gives both the volume delta (net add/remove across phases) and the
  quality read (which reviewer added what, reacting to what).
- **#64/#65** — a recorded cog input lets you A/B a specialist or the synth on a *different
  model* against the *same frozen input*, instead of re-running the whole live pipeline.

## Non-goals

- **No behaviour change to the review itself.** Capture is write-only during the run; the
  verdict, posting, and gate logic never read the accumulator.
- **No change to the default.** Capture stays behind the existing `full_log` flag — off by
  default, local-only (`$HOME/.claude/code-review-suite/logs/`), never committed, never
  posted. There is no installed base relying on the current synth-only shape (`full_log`
  shipped with #58/#59 and defaults off), so the richer payload folds into the same flag
  rather than adding a second knob.
- **No diff storage.** The raw diff is the bulky, sensitive part; it is reconstructed on
  demand, not stored (see "Inputs").
- **No live-capture automated test.** Shape + replayability are unit-tested; live volume is
  the separate "turn it on and accumulate" step.

## Inputs: stored vs. reconstructed

Each cog's input differs, and two of them are deterministically reconstructable:

| Cog | Input | Decision |
|-----|-------|----------|
| Round-1 specialist | the resolved diff (each fetches its own via `git diff`) | **Reconstruct.** The diff is fully determined by four values the orchestrator holds (`review-core.mjs:124–127`): `base` (or `EMPTY_TREE`), `headSha`, `emptyTreeMode` (two-arg vs three-dot syntax), `pathScope` (`-- <pathspec>`). Store these four keys in the `meta` record; regenerate the diff from the local clone on demand. Keeps raw private-repo diff out of the log. |
| Cross-reviewer | its peer-findings JSON (round-1 minus self, `:270–275`) | **Store.** Reconstructable (round-1 minus self) but small JSON, and the per-cog keying is the whole point — store explicitly to make each cog self-contained and avoid replay-tool drift. |
| Synthesiser | `findingsByDomain` + per-domain opinions + escalations + intent ledger + base/headSha | **Store.** Assembled at `:313–326`; its constituents are in scope at the call site. |

Reconstruction caveat: round-1 replay needs the local clone present and the SHA un-GC'd.
For a personal fixture corpus on the maintainer's own machine, that holds; a force-push or
pruned commit loses round-1 replayability, which is acceptable.

## Architecture (data flow)

Approach A — a `phaseLog` accumulator threaded through `run()`, with **per-cog**
granularity. Chosen over (B) returning rich results and composing at call sites — which
duplicates assembly across the round-1 and round-2 `crossAndSynth` calls and invites
drift — and over (C) a free-form event sink, which is over-engineered for a fixed
five-phase pipeline and makes the JSONL contract implicit.

A mutable `phaseLog = {}` is declared at the top of `run()` and written at each cog's
natural completion site:

- After round-1 dispatch (`review-core.mjs:164`) → `phaseLog.round1 = findingsByDomain`
  (already keyed by domain).
- Inside `crossAndSynth` (`:267`) → instead of flattening opinions/escalations into two
  aggregate lists (`:291–297`), build a **per-domain** map keyed by reviewer, each entry
  carrying that reviewer's peer-set `input` and its `{ opinionsMarkdown, escalations }`
  `output`. Return `{ envelope, crossByDomain }` alongside the envelope.
- The gate block (`:204–217`) → when it fires, record `phaseLog.round2` (resampled
  per-domain output) and `phaseLog.union` (unioned set with agreement counts).
- The synth input assembly (`:313–326`) → its constituent parts, recorded as the synth
  cog's `input`.

`crossAndSynth` is called twice (round 1, round 2). Each call returns its `crossByDomain`;
the call sites write into `phaseLog.round1cross` / `phaseLog.round2cross` namespaces so the
two draws never collide.

At the end, `buildLogPayload(envelope, phaseLog)` folds the accumulator into the serialised
record. The hot path is untouched: `phaseLog` is write-only during the run and read once at
the end. When `full_log` is off, nothing is serialised or written.

## Record schema (JSONL)

Extends the existing line-typed sibling `.jsonl` (`SKILL.md:1401–1407`). Each line is a
self-describing record with a `type` discriminator; the format stays append-only and
forward-compatible. The human-readable `.md` sibling is unchanged (verbatim synth prose).

```jsonl
{"type":"meta","plugin_sha":"abc123","ts":"2026-06-19T...","base":"main","head_sha":"063d5be...","empty_tree_mode":false,"path_scope":""}
{"type":"cog","phase":"round1","domain":"correctness","output":{"findings":[ ... ]}}
{"type":"cog","phase":"round1","domain":"security","output":{"findings":[ ... ]}}
{"type":"cog","phase":"cross","domain":"correctness","input":{"peer":{ ...round1 minus self... }},"output":{"opinionsMarkdown":"...","escalations":[ ... ]}}
{"type":"cog","phase":"round2","domain":"correctness","output":{"findings":[ ... ]}}
{"type":"union","output":{"findingsByDomain":{ ... agreement counts ... }}}
{"type":"cog","phase":"synth","input":{"findingsByDomain":{...},"crossByDomain":{...},"intent_ledger":"..."},"output":{"tiers":{ ... }}}
{"type":"finding", ... }
{"type":"phase", ... }
```

Design points:

- **`meta` carries the four reconstruction keys** — `base` + `head_sha` + `empty_tree_mode`
  + `path_scope` = the exact `git diff` invocation.
- **`cog` is the workhorse type:** `{type, phase, domain, input?, output}`. `phase ∈
  {round1, cross, round2, synth}`. Round-1 omits `input` (reconstructable from `meta`).
  Synth uses `domain:"synthesiser"`.
- **`round2`/`union` lines appear only when the gate fired.** Their absence is the signal
  that round 2 did not run — which #63 wants to measure (gate fire rate).
- **Existing `finding` and `phase` (token) rows are unchanged** — additive; no migration of
  lines already written.

Replay contract: read `meta` → reconstruct the diff; read `round1` cogs → every
specialist's output; read a `cross` line's `input.peer` → re-run that one cross-reviewer;
read the `synth` line's `input` → re-run synth on a different model. Each cog is
independently re-runnable.

## Testing

Shell-based suite (`tests/run.sh`); the workflow `.mjs` runs under a strip-export +
async-wrap transform (no raw `node --check`).

Pure-function tests (`tests/lib/`):

- **`buildLogPayload` shape** — given a synthetic `envelope` + `phaseLog`, assert one `cog`
  per round-1 domain, one `cog` per cross domain carrying its peer `input`, a `synth` cog
  with full input, and `meta` with all four reconstruction keys.
- **Gate-fired vs not** — with `phaseLog.round2`/`union` populated, assert `round2`+`union`
  lines present; absent, assert they are *omitted* (not emitted empty). Pins the
  "absence = gate didn't fire" signal.
- **Round-1/round-2 namespace isolation** — feed both `round1cross` and `round2cross`,
  assert no collision (the drift risk that ruled out approach B).
- **Flag-off inertness** — with `full_log` off, assert no payload is produced / nothing
  written.

Reconstruction round-trip test (the replay contract, highest value): build a `meta` record
from a known small fixture commit in this repo, run the documented `git diff` reconstruction
from the four keys, assert it reproduces the expected diff. Catches drift between the replay
reconstruction and what specialists actually do.

Writer-layer (SKILL prose): the JSONL writer is host instructions in `SKILL.md` Step 7a,
duplicated across `review-gh-pr/SKILL.md`, `commands/pre-review.md`, and
`includes/review-pipeline.md`. The existing sync-note consistency test enforces byte-parity;
extend the synced block and let that test guard it.

Not automated: end-to-end live capture (organic — run a real review with `full_log` on and
eyeball the JSONL).

## Open knobs / deferred

- **Diff reconstruction tool** — the replay-side tool that reads `meta` and regenerates the
  diff is out of scope here; this spec only guarantees the keys are captured and the
  round-trip is sound. Building the replay/analysis tooling is downstream (#63 analysis,
  #64/#65 sweeps).
- **`full_log` default** — stays OFF. Turning it on is a per-machine, per-repo
  (`.claude/code-review.toml`) opt-in, done only on the maintainer's machine.
