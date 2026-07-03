# Synthesiser stall recovery net — design

**Date:** 2026-07-03
**Status:** approved (design)
**Component:** `code-review-suite` plugin → `workflows/review-core.mjs`, `agents/review-synthesiser.md`, `includes/review-pipeline.md`, `tests/run.sh`

## Problem

On full-route reviews, the pipeline fans out specialists and cross-reviewers, then runs a
single serial `agent()` synthesis step (`review-core.mjs` `crossAndSynth`, the
`review-synthesiser` dispatch). Under heavy Bedrock latency that lone step stalls, retries,
and finally kills the whole workflow with:

```
agent stalled on all 6 attempts (no progress for 180000ms each)
```

All 20 upstream agents (11 specialists + 9 cross-reviewers) complete and are cached; only the
synthesiser fails, and resume re-fails identically because it re-hits the same latency wall.

## Root cause (confirmed against the runtime binary)

The Workflow sandbox has a **per-agent no-progress watchdog** compiled into the Claude Code
binary (`~/.local/share/claude/versions/2.1.199`). Deminified, the workflow-agent runner does:

```js
pt = () => { if (ie > 0) Ue = setTimeout(Ur => Ur.abort(new DOMException("stalled","AbortError")), ie, Re) }
// ie = 180000   (workflow stall timeout, 180s — matches the observed "180000ms")
// retry cap vHl = 5  →  6 total attempts   (matches "all 6 attempts")
```

The timer is reset by streaming-progress events (`onQueryProgress`, throttled to ~1/s) and
**cleared entirely while a tool call is in flight**. It fires only when the model's stream is
silent — no tokens — for a continuous 180s **inside a generation/thinking turn**. On fire it
aborts the turn (surfacing as the `[Request interrupted by user]` transcript marker), then
re-dispatches the identical agent up to 5 times; after the 6th it `throw`s the message above,
which propagates uncaught and terminates the workflow.

**Resolves the handovers' open fork:** it is a *fixed 180s no-streaming-progress watchdog*,
not an escalating per-attempt deadline. The observed "shrinking cancellation intervals" are an
emergent artefact of where in the turn the silent window lands (warmer cache → the big think
starts sooner), not a shrinking cap.

**Why the synthesiser specifically:** lone serial turn, `model:'opus'`, prompt opens with
`ultrathink` (max thinking budget), ~52 KB prompt, ~100k cache-read/turn, and it does its own
diff/file reads. That maximises turn duration and the window in which a Bedrock stream stall
(>180s with no tokens) can exceed the watchdog. The stall trigger is Bedrock; the 180s
workflow watchdog is uniquely intolerant of it.

**Key constraint:** the watchdog lives in the Claude Code binary, not the plugin. There is **no
env knob** for it. (`CLAUDE_CODE_STALL_TIMEOUT_MS_FOR_TESTING` feeds the binary *downloader's*
checksum-retry timer — default 120000 — a different timer.) The **proven recovery** — a
standalone/out-of-sandbox Agent dispatch — uses `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS || 600000`
(600s, configurable), 3.3× the sandbox watchdog. That is exactly why the manual recovery
"completed on the first try". Everything we can fix lives in the plugin.

## Approach (chosen)

**First-class recovery net.** When the in-sandbox synthesis stalls, review-core returns a
`synthDeferred` bundle instead of dying; the pipeline caller re-dispatches the synthesiser as a
standalone Agent (600s watchdog), then re-enters review-core in a new `finalize` route to run
the deterministic Class D filter/render on the recovered envelope. No upstream work is repeated;
full opus + ultrathink synthesis quality is preserved.

Two crux decisions (user-approved):
- **Standalone synth returns a structured envelope via a file.** Workflow scripts have no
  filesystem access; the standalone Agent (normal harness) *can* write, and the caller (main
  agent loop) *can* read. So the standalone synth writes the schema-shaped envelope JSON to a
  temp path; the caller reads it and hands it back to review-core.
- **Class D runs in review-core `finalize` mode** — the single source of truth in code, not
  re-derived by the model in prose. Preserves the "never re-filter the bundle" invariant.

## Data flow

```
review-core (normal route)
  crossAndSynth() → agent(synthPrompt, {model:opus, schema:SYNTH_SCHEMA})
     │  synthStalled?  ── yes ──▶ return { synthDeferred:true, synthPrompt }
     │                            (BEFORE the Category-C guard — see Component 2)
     ▼ no (envelope, possibly null on a non-stall API error)
  Category-C guard (envelope null / missing tiers) ──▶ empty bundle
     ▼
  local mode? ── yes ──▶ finalizeBundle(envelope, 'local', phaseLog) ──▶ prose bundle
     ▼ no (pr mode)
  boundary gate fires? ── yes ──▶ round 2 (dispatchSpecialists) → re-synth → maybe replace envelope
     ▼
  finalizeBundle(envelope, 'pr', phaseLog) ──▶ sealed bundle
  ────────────────────────────────────────────────────────────────────────────
caller (review-pipeline.md Step 3.5, main agent loop)
  bundle = workflow({scriptPath}, {...})
  if (bundle.synthDeferred):
     Agent(review-synthesiser, prompt = synthPrompt + "Envelope output path: <TEMP>/synth-envelope-<run>.json",
           mode:auto, name:synth-standalone-recovery)          ← 600s watchdog, writes JSON
     envelope = JSON.parse(Read(<TEMP>/synth-envelope-<run>.json))   ← defensively wrapped; on throw → empty bundle
     bundle   = workflow({scriptPath}, { route:'finalize', reviewMode, envelope })   ← 0 agents, watchdog never engages
  post (PR) / print (local) bundle as normal
```

The `finalize` route enters review-core near the top and calls **only** `finalizeBundle`
— it does NOT run the boundary gate or `dispatchSpecialists`, so it spawns zero agents and
the watchdog never engages. The boundary gate lives on the **normal** path only (PR mode),
exactly where it is today.

## Components

### 1. Stall detection — `crossAndSynth` (review-core.mjs)
Wrap the synth `await agent(...)` in try/catch. Catch **only** `/stalled on all \d+ attempts/`
(the verbatim runtime message) → set `synthStalled = true`, `envelope = null`, `log(...)`.
Re-throw everything else (user-abandon, script bugs) so genuine errors are not masked. Return
`{ envelope, crossByDomain, synthInput, synthPrompt, synthStalled }`.

`synthStalled` is the **sole** signal that distinguishes a stall-null from a benign API-error
null (both leave `envelope === null`). It MUST be surfaced on the return object — the round-1
caller keys the defer decision on it, and without it the stall would be indistinguishable from
the Category-C empty-bundle case (see Component 2, which is why the defer check must fire before
the Category-C guard).

This single guard protects **both** call sites: the round-1 site defers; the round-2 site is
already absorbed by the existing "round 2 unusable → retain round 1" degrade (review-core.mjs
~L243), which also closes a latent round-2 crash (a round-2 throw currently kills the workflow).

### 2. Deferred bundle — round-1 site (review-core.mjs)
If `synthStalled` after the round-1 `crossAndSynth`, return `{ synthDeferred:true, synthPrompt }`.

**Placement is load-bearing: the defer check MUST run before the Category-C guard (current
~L207), not merely "before the boundary gate".** A stall sets `envelope = null`, and the
Category-C guard (`if (!envelope || !envelope.tiers)`) sits *ahead* of the boundary gate and
returns an empty bundle on any null envelope. If the defer check is placed after it, the stall
is swallowed as a Category-C empty bundle and the recovery path never fires. So the order at the
round-1 site becomes:

```
1. if (synthStalled) return { synthDeferred:true, synthPrompt }   ← NEW, first
2. if (!envelope || !envelope.tiers) return <empty bundle>        ← existing Category-C guard
3. if (reviewMode === 'local') return finalizeBundle(envelope, 'local', phaseLog)
4. if (boundaryGateFires(envelope)) { …round 2… }                 ← PR path only
5. return finalizeBundle(envelope, 'pr', phaseLog)
```

The defer payload is just the exact prompt string — the leanest option available *relative to
also threading `phaseLog` back*, though not lean in absolute terms: `synthPrompt` is ~52 KB
(full findings JSON + cross opinions + escalations) and necessarily round-trips through the main
agent loop (out as the payload, back in as the standalone Agent's prompt). That round-trip is
inherent — the standalone synth needs the same input and the cached specialist outputs are
trapped in the sandbox — not avoidable padding. A `null`/missing-tiers envelope from a genuine
API error (not a stall — `synthStalled` is false) falls through to step 2 and keeps its
**existing** Category-C empty-bundle degrade (that path already does not crash — out of scope,
YAGNI).

### 3. Finalize route (review-core.mjs)

**What `finalizeBundle` contains — and, critically, what it does NOT.** The current tail spans
~L207-266, but that contiguous range physically contains the boundary gate + round-2 block
(~L221-246), which `finalizeBundle` MUST NOT absorb — the whole point is that finalize spawns
zero agents. Do not cut L207-266 wholesale. Extract exactly these pieces, in this order:

- the Category-C guard (`if (!envelope || !envelope.tiers)` → empty bundle),
- the local-mode branch (`if (reviewMode === 'local')` → prose + log payload),
- the Class D filter (`POST_THRESHOLD`, `isPosted`, `candidates`/`postedSet`/`suppressedCount`),
- `renderComments` + `buildBody` + `buildLogPayload`, and the final `return { verdict, bodyText, comments, log }`.

The **boundary gate and round-2 block stay on the normal path**, between the local-mode return
and the `finalizeBundle` call, exactly where they are today. They are NOT part of `finalizeBundle`.

**Signature and call order.** `finalizeBundle(envelope, reviewMode, phaseLog)`. On the normal
path, keep the current ordering so behaviour is byte-identical: Category-C guard and local-mode
branch move *into* `finalizeBundle`, so the normal path calls the boundary gate first (PR mode)
and then `finalizeBundle` last. Because the Category-C guard and local return now live inside
`finalizeBundle`, the boundary-gate invocation on the normal path must gain an explicit
`reviewMode !== 'local'` guard — today it is only unreachable in local mode by virtue of the
local branch returning at ~L216 *before* the gate. Once that early return moves into
`finalizeBundle` (called *after* the gate), the gate would run in local mode and trigger a
resample local never does. Guard it: `if (reviewMode !== 'local' && boundaryGateFires(envelope)) { … }`.

Hoist `POST_THRESHOLD` to top-level so `isPosted` still closes over it (it is currently declared
at ~L250, inside the tail being refactored — an early `finalize` return would otherwise hit its
temporal dead zone). Add near the top of the script:

```js
if (route === 'finalize') return finalizeBundle(resolvedArgs.envelope, reviewMode, null)
```

Finalize spawns **zero agents** → the watchdog never engages. The normal path calls the same
`finalizeBundle(envelope, reviewMode, phaseLog)`, so Class D stays single-source-of-truth.

### 4. Standalone dispatch — caller (includes/review-pipeline.md Step 3.5)
Add a branch: when `bundle.synthDeferred`, dispatch `review-synthesiser` as a standalone Agent
(`mode:auto`, name `synth-standalone-recovery`), prompt = `bundle.synthPrompt` + one appended
line `Envelope output path: <RESOLVED_TEMP_DIR>/synth-envelope-<run>.json`. Then `Read` +
`JSON.parse` the file and re-invoke `workflow({scriptPath}, { route:'finalize', reviewMode, envelope })`.
Post/print the returned bundle exactly as the normal path. The second launch-approval prompt for
the finalize re-invoke is silenced under `auto` mode (already required for the first launch).

**Unique output path.** Use a per-run filename (`synth-envelope-<run>.json`, where `<run>` is
the head SHA or an equivalent per-review discriminator) rather than a fixed name, so a second
review in the same session cannot clobber the first's envelope. The temp dir is session-scoped,
not review-scoped.

**Defensive read — this branch is prose-driven, not deterministic.** Unlike the workflow core,
this recovery lives in markdown the main model executes (dispatch → `Read` → `JSON.parse` →
re-invoke). There is no `try/catch` in code around it, so the instructions must be explicit:
if the standalone Agent fails, writes no file, or the file does not parse as JSON, do NOT retry
into the sandbox — emit the exact same empty bundle the Category-C guard produces
(`{ verdict:'NONE', bodyText:'(synthesiser produced no usable output)', comments:[] }`) and
post/print that. This keeps the failure mode a graceful degrade, never a hang. This is a
deliberate reliability asymmetry: the recovery net is inherently softer than the deterministic
core it protects, because it is model-executed — accepted, because it fires only when the
in-sandbox path has already stalled.

### 5. Agent contract (agents/review-synthesiser.md)
Add a short "Standalone recovery mode" note: when the prompt contains an
`Envelope output path: <path>` line, in addition to the stdout prose report, `Write` the
structured envelope (the object already fully specified in the existing "Envelope output
(review-core consumer)" section) as JSON to `<path>`. Prose → human; JSON file → machine
hand-off. No change to analysis, tiering, or verdict logic.

**No runtime schema enforcement on this path (accepted).** The in-sandbox synth gets
`agent(..., {schema: SYNTH_SCHEMA})` enforcement; the standalone Agent just `Write`s JSON, so
the shape is only as good as the model's adherence to the contract. `JSON.parse` catches gross
malformation and `finalizeBundle`'s Category-C `!envelope.tiers` guard catches a missing-tiers
object, but **partial tier corruption** (valid JSON, wrong internal shape) passes both and
yields wrong finalize output. This is the same risk class as the "sandbox enforcement is
best-effort" caveat already noted at review-core.mjs ~L204 — tolerable, and listed here so it
is not silent. The agent contract note should reproduce the envelope shape verbatim (it already
cites the canonical "Envelope output" section) to minimise drift.

## Conscious degradations (documented)

- **No boundary-gate / round-2 resample on the recovery path.** Re-entering the sandbox for
  round 2 would re-stall; consistent with the existing "retain round 1" philosophy.
- **Thinner `full_log` on the recovery path.** The pre-synth per-cog corpus (`phaseLog`) is not
  threaded back through the main loop (avoids round-tripping a large object). `full_log` is
  default-off; `finalizeBundle(..., null)` still emits `findings` + `bodyText`.
- **No `## Cost` section on the recovery path.** The token-usage block (`$TOKEN_USAGE_BLOCK_BODY`)
  is injected into the synth prompt by the markdown orchestrator, not by `crossAndSynth`'s
  `synthPrompt` (which carries no cost block). The reconstructed standalone prompt is
  `bundle.synthPrompt`, so the recovered `bodyText` has no `## Cost` section. Acceptable — cost
  reporting is ancillary and the recovery fires only under a stall — but noted so it is not a
  silent regression.
- **Scope limited to the stall throw.** The existing null-envelope Category-C degrade is left
  untouched — it already does not crash.

## Error handling

- Non-stall throws in `crossAndSynth` re-propagate unchanged.
- If the standalone recovery Agent itself fails or writes no/invalid envelope file, the caller
  falls back to the existing empty-bundle behaviour (`verdict:NONE`, explanatory `bodyText`,
  no comments) — the review degrades, it never hangs.
- `finalize` route with a malformed/absent `envelope` arg hits the same Category-C guard inside
  `finalizeBundle` and returns the empty bundle.

## Testing

- **Unit (finalize is pure):** a stub-globals node harness invoking `review-core.mjs` with
  `route:'finalize'` + a hand-authored envelope → assert `verdict`, `comments[]`, and `bodyText`
  match the normal-path output for the same envelope (parity between the two `finalizeBundle`
  call sites). **Parity holds only for an envelope that does not fire the boundary gate:** the
  normal PR path runs `boundaryGateFires` first and may *replace* the envelope with a round-2
  result, whereas the finalize route never resamples. Author the parity fixture so
  `boundaryGateFires(envelope)` is false (e.g. an APPROVE with no contested tier and no
  Important in the [60,80) band), or the two paths legitimately diverge and the test would
  false-fail.
- **Structural (`tests/run.sh`):** assert the stall guard, the `synthDeferred` return, the
  `finalize` route branch, and the caller's standalone-dispatch instructions are all present and
  mutually consistent (the suite already checks sync-note consistency across files).
- **Integration:** validate on the next large-diff review that stalls, or via a temporarily
  injected stall throw, that the deferred → standalone → finalize path produces a bundle
  identical in shape to the normal path.

## Files touched

- `workflows/review-core.mjs` — stall guard, deferred bundle, `finalizeBundle` extraction, `finalize` route.
- `agents/review-synthesiser.md` — standalone recovery-mode envelope-write note.
- `includes/review-pipeline.md` — Step 3.5 standalone-dispatch + finalize re-entry branch.
- `tests/run.sh` — structural assertions.
