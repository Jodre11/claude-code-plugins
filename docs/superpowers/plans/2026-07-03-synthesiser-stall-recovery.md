# Synthesiser Stall Recovery Net Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the code-review-suite synthesiser when it stalls under Bedrock latency, instead of letting the lone in-sandbox synth step kill the whole review Workflow.

**Architecture:** When the in-sandbox synth `agent()` call throws the runtime stall message, `crossAndSynth` catches it and the round-1 site returns a `{ synthDeferred:true, synthPrompt }` bundle instead of dying. The pipeline caller (main agent loop) re-dispatches the synthesiser as a *standalone* Agent — which runs under the 600s async-agent watchdog, not the 180s sandbox one — has it write a structured envelope JSON to a temp file, reads it back, and re-enters `review-core` via a new `finalize` route that runs the deterministic Class D filter/render on the recovered envelope. No upstream specialist/cross work is repeated; full opus + ultrathink synthesis quality is preserved.

**Tech Stack:** JavaScript ES-module Workflow script (`review-core.mjs`) run in the Claude Code Workflow sandbox; Markdown pipeline includes; Bash + Node structural test harness (`tests/run.sh` → `tests/lib/test_*.sh`).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-03-synthesiser-stall-recovery-design.md` — read it before starting; this plan implements it verbatim.
- **Stall signature:** the ONLY throw to catch is the runtime message matching `/stalled on all \d+ attempts/`. Every other throw MUST re-propagate unchanged (user-abandon, script bugs).
- **Sandbox limits:** the Workflow script has NO filesystem access — it cannot read/write the envelope file. `Date.now()` / `Math.random()` / argless `new Date()` throw. `import()` is unavailable (schemas are inlined). Do not introduce any of these.
- **`finalizeBundle` spawns ZERO agents** — it must never call `agent()`, `dispatchSpecialists`, `crossAndSynth`, or the boundary gate. That property is what makes the `finalize` route immune to the watchdog.
- **Step 3.5 is triplicated byte-identically** across `includes/review-pipeline.md` (canonical), `skills/review-gh-pr/SKILL.md`, and `commands/pre-review.md`. `tests/lib/test_sync_notes.sh` → `test_sync_pipeline_inline_matches_canonical` asserts the canonical body (from `^Follow these instructions exactly` through `^Present the synthesiser…formatted report to the user\.$`) is identical in all three. Edit canonical first, then copy the identical text to the other two.
- **CLAUDE.md bash rules:** no compound commands (`&&`/`;`/`|`), no command substitution `$(…)`, no subshells. One simple command per Bash call. The `git commit -m "$(cat <<'EOF' … EOF)"` HEREDOC is the sole exemption.
- **Commit style:** conventional commits, `type(code-review): summary` (e.g. `feat(code-review): …`, `refactor(code-review): …`, `test(code-review): …`).
- **Run the full suite after each task:** `bash tests/run.sh` from the repo root must be green before committing.
- Work happens on the existing branch `fix/synthesiser-stall-recovery` (the spec doc is already committed there). Do not open a PR until all four tasks land — this is one cohesive PR.

---

## File Structure

- `plugins/code-review-suite/workflows/review-core.mjs` — the Workflow core. Tasks 1 & 2 add the `finalizeBundle` function, the `finalize` route, `POST_THRESHOLD` hoist, the stall try/catch in `crossAndSynth`, and the round-1 defer return.
- `plugins/code-review-suite/agents/review-synthesiser.md` — Task 3 adds a "Standalone recovery mode" note instructing the agent to `Write` the envelope JSON when an `Envelope output path:` line is present.
- `plugins/code-review-suite/includes/review-pipeline.md` — Task 4 adds the caller-side stall-recovery branch to Step 3.5 (**canonical copy**).
- `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — Task 4 copies the identical Step 3.5 recovery branch (verbatim-inlined pipeline).
- `plugins/code-review-suite/commands/pre-review.md` — Task 4 copies the identical Step 3.5 recovery branch (verbatim-inlined pipeline).
- `tests/lib/test_workflow_migration.sh` — Tasks 1, 2, 4 add test functions (auto-discovered by `tests/run.sh`; no edit to `run.sh`).

---

## Task 1: Extract `finalizeBundle` + add the `finalize` route (pure refactor)

Behaviour-preserving refactor: move the post-synth tail into a hoisted `finalizeBundle` function shared by the normal path and a new `finalize` route. No externally observable change to the normal path; the new route is exercised by the recovery branch in Task 4.

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (round-1 tail ~L204-266; `POST_THRESHOLD` ~L250)
- Test: `tests/lib/test_workflow_migration.sh` (new function `test_finalize_route_parity`)

**Interfaces:**
- Produces: `function finalizeBundle(envelope, reviewMode, phaseLog)` — hoisted function declaration returning the sealed bundle `{ verdict, bodyText, comments, log }` in PR mode, `{ verdict:'NONE', bodyText, comments:[], log }` in local mode, and `{ verdict:'NONE', bodyText:'(synthesiser produced no usable output)', comments:[] }` when `envelope` is null / missing `tiers`.
- Produces: a top-level `route === 'finalize'` early return: `finalizeBundle(resolvedArgs.envelope, reviewMode, null)`.
- Produces: module-scope `const POST_THRESHOLD = 75` (hoisted above the finalize early-return).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing test**

Add this function to `tests/lib/test_workflow_migration.sh` (append before the final blank line):

```bash
# Task 1: the finalize route re-enters review-core with a recovered envelope, runs
# finalizeBundle (Class D filter + render) with ZERO agent() calls, and produces a bundle
# identical (in verdict/comments/bodyText) to the normal path for the same non-gate-firing
# envelope. Uses an APPROVE envelope with no contested tier and no Important consensus, so
# boundaryGateFires() is false and the two paths are directly comparable.
test_finalize_route_parity() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "finalize route parity" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const ENV = {
            verdict: "APPROVE",
            rubricRowApplied: 4,
            rubricReason: "no high-confidence findings",
            tiers: {
                consensus: [{ file: "a.js", line: 10, severity: "Suggestion", confidence: 90, description: "desc one", suggested_fix: "fix one" }],
                synthesiser: [{ file: "b.js", line: 20, severity: "Suggestion", confidence: 50, description: "desc two", suggested_fix: "fix two" }],
                contested: [],
                dismissed: [],
            },
            bodyText: "## Summary\n1 file(s) changed | 1 finding(s) | 0 contested\n\n## Synthesiser Assessment\n> Looks fine.\n",
        };
        const baseArgs = {
            agentPrompt: "x", flags: {}, selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        const pick = (b) => ({ verdict: b.verdict, comments: b.comments, bodyText: b.bodyText });
        (async () => {
            // (a) finalize route: agent() must NEVER be called; envelope passed as arg.
            let called = false;
            const agentNever = async () => { called = true; return null; };
            let finalizeBundle;
            try {
                finalizeBundle = await run(agentNever, { ...baseArgs, route: "finalize", envelope: ENV });
            } catch (e) { console.log("THREW(finalize): " + e.message); return; }
            if (called) { console.log("AGENT_CALLED_ON_FINALIZE"); return; }
            if (finalizeBundle.verdict !== "APPROVE") { console.log("BADVERDICT: " + finalizeBundle.verdict); return; }
            if (!Array.isArray(finalizeBundle.comments) || finalizeBundle.comments.length !== 1) { console.log("BADCOMMENTS: " + JSON.stringify(finalizeBundle.comments)); return; }
            if (finalizeBundle.comments[0].path !== "a.js" || finalizeBundle.comments[0].line !== 10) { console.log("BADANCHOR: " + JSON.stringify(finalizeBundle.comments[0])); return; }
            if (!finalizeBundle.bodyText.includes("**APPROVE**")) { console.log("NOHEADLINE"); return; }
            // (b) normal path with a synth mock returning the SAME envelope, no gate fires.
            const agentSynth = async (prompt, opts) => {
                if (opts && opts.agentType === "code-review-suite:review-synthesiser") return ENV;
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let normal;
            try {
                normal = await run(agentSynth, { ...baseArgs, route: "full" });
            } catch (e) { console.log("THREW(normal): " + e.message); return; }
            if (JSON.stringify(pick(normal)) !== JSON.stringify(pick(finalizeBundle))) {
                console.log("PARITY_MISMATCH\nnormal=" + JSON.stringify(pick(normal)) + "\nfinalize=" + JSON.stringify(pick(finalizeBundle)));
                return;
            }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "finalize route runs finalizeBundle with zero agents and matches normal-path output"
    else
        fail "finalize route runs finalizeBundle with zero agents and matches normal-path output" \
            "$result"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 "finalize route"`
Expected: FAIL. Pre-implementation, `route:'finalize'` is not `'lightweight'`, so the script falls through to the full pipeline, calls `agentNever` (→ `AGENT_CALLED_ON_FINALIZE`) or produces a null-envelope empty bundle (→ `BADVERDICT: NONE`). Either way the assertion fails.

- [ ] **Step 3: Implement the refactor**

In `plugins/code-review-suite/workflows/review-core.mjs`:

(3a) Hoist `POST_THRESHOLD`. Delete the inline declaration + its comment currently at ~L248-250:

```js
// Shared by isPosted and the PR-mode filter. The 75 bar is deliberate (above
// the rubric's 70) — see "Posting policy" in verdict-rubric.md.
const POST_THRESHOLD = 75
```

and re-add it at module scope immediately after the `const { … } = resolvedArgs` destructure block (right after the closing `}` of the destructure at ~L127):

```js
// Shared by isPosted and the PR-mode filter. The 75 bar is deliberate (above
// the rubric's 70) — see "Posting policy" in verdict-rubric.md. Hoisted to
// module scope so the finalize-route early return can reach it via isPosted.
const POST_THRESHOLD = 75
```

(3b) Add the `finalize` route early return. Immediately below the `POST_THRESHOLD` line from 3a (still before the `phaseLog` const), add:

```js
// Finalize route (stall-recovery re-entry): run only the deterministic tail on a
// recovered envelope. Spawns ZERO agents, so the sandbox watchdog never engages.
if (route === 'finalize') return finalizeBundle(resolvedArgs.envelope, reviewMode, null)
```

(3c) Replace the current tail. Delete everything from the Category-C guard comment (~L204, `// Category C guard:`) through the final `return { verdict, bodyText, comments, log: logPayload }` (~L266), i.e. the block:

```js
// Category C guard: a null envelope, or one missing tiers (schema marks tiers required,
...
return { verdict, bodyText, comments, log: logPayload }
```

Replace that entire deleted block with a boundary-gate call (PR-mode-guarded) followed by a single `finalizeBundle` call:

```js
// Boundary gate (PR path only): if the round-1 verdict sits near the
// APPROVE/REQUEST_CHANGES boundary, take a 2nd independent draw of the stochastic
// specialists, union with agreement counts, and re-synthesise. Guarded to PR mode
// explicitly: the local-mode early return that used to shield it now lives inside
// finalizeBundle (called after the gate), so without this guard local mode would
// resample — which it never does.
if (reviewMode !== 'local' && boundaryGateFires(envelope)) {
    log('boundary gate fired — round 2 (stochastic resample)')
    const specialists2 = await dispatchSpecialists(crossDomains, 'resample')
    log(`resample: ${specialists2.filter(s => s.out.status === 'ok').length}/${crossDomains.length} specialists ok`)
    const r2ByDomain = Object.fromEntries(specialists2.map(s => [s.domain, s.out.findings ?? []]))
    for (const [domain, fs] of Object.entries(r2ByDomain)) {
      phaseLog.cogs.push({ phase: 'round2', domain, output: { findings: fs } })
    }
    const unioned = unionFindingsByDomain(findingsByDomain, r2ByDomain, crossDomains)
    phaseLog.cogs.push({ phase: 'union', output: { findingsByDomain: unioned } })
    const { envelope: envelope2, crossByDomain: crossByDomain2, synthInput: synthInput2 } = await crossAndSynth(unioned, true)
    for (const c of crossByDomain2) {
      phaseLog.cogs.push({ phase: 'cross2', domain: c.domain, input: c.input, output: c.output })
    }
    if (envelope2 && envelope2.tiers) {
      phaseLog.cogs.push({ phase: 'synth', input: synthInput2, output: { tiers: envelope2.tiers } })
      envelope = envelope2
      log('round 2 complete — adopting resampled synthesis')
    } else {
      log('round 2 synthesis unusable — retaining round-1 verdict')
    }
}

return finalizeBundle(envelope, reviewMode, phaseLog)
```

(3d) Add the `finalizeBundle` function declaration. Place it in the helper section, immediately after the `crossAndSynth` function (after its closing `}` at ~L384), so the pure helpers it calls (`isPosted`, `renderComments`, `buildBody`, `buildLogPayload`) remain defined below it (all are hoisted `function` declarations):

```js
// The deterministic tail, shared by the normal path and the `finalize` recovery route.
// Owns the Category-C guard, the local-mode branch, and the PR-mode Class D filter +
// comment renderer. Spawns NO agents by construction — that is what makes the finalize
// route immune to the sandbox watchdog. phaseLog is null on the recovery path (the
// per-cog corpus is not threaded back through the main loop); buildLogPayload tolerates
// a null phaseLog and still emits findings + bodyText.
function finalizeBundle(envelope, reviewMode, phaseLog) {
    // Category C guard: a null envelope, or one missing tiers (schema marks tiers required,
    // but sandbox enforcement is best-effort), would crash both modes below. Degrade to an
    // empty bundle instead of taking down the whole review. Also the finalize route's guard
    // against a malformed/absent recovered envelope.
    if (!envelope || !envelope.tiers) {
        log('finalize: envelope null or missing tiers — returning empty bundle')
        return { verdict: 'NONE', bodyText: '(synthesiser produced no usable output)', comments: [] }
    }

    // Local mode: no verdict, no GitHub filter — return the prose plus the durable
    // log payload. The host writes the log to disk only when orchestration.full_log
    // is on (default off); pre-review documents the log as its sole persisted artefact,
    // so it MUST be carried on this path too — not just the PR path below.
    if (reviewMode === 'local') {
        const logPayload = buildLogPayload(envelope, phaseLog)
        return { verdict: 'NONE', bodyText: envelope.bodyText, comments: [], log: logPayload }
    }

    const verdict = envelope.verdict  // APPROVE | REQUEST_CHANGES (synth never emits COMMENT)
    const consensus = envelope.tiers.consensus ?? []
    const synthFindings = envelope.tiers.synthesiser ?? []

    // Posted set = consensus + synthesiser, filtered by the verdict-driven rule.
    const candidates = [...consensus, ...synthFindings]
    const postedSet = candidates.filter(f => isPosted(f, verdict))
    const suppressedCount = candidates.length - postedSet.length

    const comments = renderComments(postedSet)
    const bodyText = buildBody(envelope, postedSet, suppressedCount)
    const logPayload = buildLogPayload(envelope, phaseLog)

    return { verdict, bodyText, comments, log: logPayload }
}
```

Note: the empty-bundle Category-C log message text changed from `synth: synthesiser returned null…` to `finalize: envelope null…` because the guard now serves both the normal and finalize paths. This is log text only — no consumer parses it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `finalize route runs finalizeBundle with zero agents and matches normal-path output`, plus the existing `review-core survives null agent() results at all dispatch sites`, `review-core accepts a JSON-string args…`, `review-core.mjs is syntactically valid…`, and all sync-note tests still green (the refactor did not touch pipeline prose).

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_workflow_migration.sh
git commit -m "$(cat <<'EOF'
refactor(code-review): extract finalizeBundle + add finalize route

Move the post-synth deterministic tail (Category-C guard, local-mode
branch, Class D filter, comment render) into a hoisted finalizeBundle
shared by the normal path and a new zero-agent finalize route. Hoist
POST_THRESHOLD to module scope and guard the boundary gate to PR mode
so the relocated local branch keeps its behaviour. Behaviour-preserving;
the finalize route is exercised by the recovery branch in a later task.
EOF
)"
```

---

## Task 2: Stall detection in `crossAndSynth` + round-1 deferred bundle

Catch the runtime stall throw inside `crossAndSynth`, surface `synthStalled` + `synthPrompt`, and have the round-1 site return a `synthDeferred` bundle. The round-2 site needs no new code — the existing "retain round-1" degrade absorbs a round-2 stall (and this also closes the latent round-2 uncaught-throw crash).

**Files:**
- Modify: `plugins/code-review-suite/workflows/review-core.mjs` (`crossAndSynth` synth dispatch ~L370-383; round-1 site ~L198)
- Test: `tests/lib/test_workflow_migration.sh` (new function `test_synth_stall_defers`)

**Interfaces:**
- Consumes: `finalizeBundle` and the round-1 tail shape from Task 1.
- Produces: `crossAndSynth` now returns `{ envelope, crossByDomain, synthInput, synthPrompt, synthStalled }` (adds `synthPrompt`, `synthStalled`).
- Produces: round-1 site returns `{ synthDeferred: true, synthPrompt }` when `synthStalled` is true.

- [ ] **Step 1: Write the failing test**

Add this function to `tests/lib/test_workflow_migration.sh`:

```bash
# Task 2: a synth agent() that throws the runtime stall message must be caught inside
# crossAndSynth; the round-1 site then returns a synthDeferred bundle (NOT a crash, NOT an
# empty Category-C bundle). A non-stall throw must re-propagate. A round-2 stall must be
# absorbed by the existing "retain round-1" degrade (no defer, no crash).
test_synth_stall_defers() {
    local cr
    cr=$(_wm_cr_dir)
    local wf="$cr/workflows/review-core.mjs"
    if [[ ! -f "$wf" ]]; then
        fail "synth stall recovery" "missing: $wf"
        return
    fi
    local result
    result=$(node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8")
            .replace(/^export\s+const\s+meta/m, "const meta");
        const STALL = "agent stalled on all 6 attempts (no progress for 180000ms each)";
        const baseArgs = {
            agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40),
            emptyTreeMode: false, pathScope: "", tempDir: "/tmp/x",
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const phase = () => {};
        const log = () => {};
        const pipeline = async () => [];
        const workflow = async () => null;
        const run = (agent, args) => {
            const fn = new Function("agent","parallel","pipeline","phase","log","args","workflow",
                "return (async()=>{" + src + "\n})()");
            return fn(agent, parallel, pipeline, phase, log, args, workflow);
        };
        const isSynth = (opts) => opts && opts.agentType === "code-review-suite:review-synthesiser";
        (async () => {
            // (a) round-1 synth stall → synthDeferred bundle carrying the prompt.
            const agentStall = async (prompt, opts) => {
                if (isSynth(opts)) throw new Error(STALL);
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let deferred;
            try { deferred = await run(agentStall, baseArgs); }
            catch (e) { console.log("THREW(stall): " + e.message); return; }
            if (deferred.synthDeferred !== true) { console.log("NO_DEFER: " + JSON.stringify(deferred).slice(0, 120)); return; }
            if (typeof deferred.synthPrompt !== "string" || !deferred.synthPrompt.includes("ultrathink")) { console.log("BAD_PROMPT"); return; }
            // (b) a non-stall throw must re-propagate.
            const agentOtherThrow = async (prompt, opts) => {
                if (isSynth(opts)) throw new Error("some other failure");
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let propagated = false;
            try { await run(agentOtherThrow, baseArgs); }
            catch (e) { propagated = /some other failure/.test(e.message); }
            if (!propagated) { console.log("NONSTALL_NOT_PROPAGATED"); return; }
            // (c) round-2 stall is absorbed: round-1 gate fires (APPROVE + contested), round-2
            // synth stalls, and the run retains the round-1 verdict without deferring/crashing.
            const ENV_GATE = {
                verdict: "APPROVE", rubricRowApplied: 4, rubricReason: "borderline",
                tiers: { consensus: [], synthesiser: [],
                         contested: [{ file: "c.js", line: 5, severity: "Suggestion", confidence: 55, description: "d", suggested_fix: "f" }],
                         dismissed: [] },
                bodyText: "## Synthesiser Assessment\n> hi\n",
            };
            let synthCalls = 0;
            const agentGateThenStall = async (prompt, opts) => {
                if (isSynth(opts)) { synthCalls++; if (synthCalls === 1) return ENV_GATE; throw new Error(STALL); }
                return { status: "ok", findings: [], opinionsMarkdown: "", escalations: [] };
            };
            let r2;
            try { r2 = await run(agentGateThenStall, baseArgs); }
            catch (e) { console.log("THREW(round2): " + e.message); return; }
            if (r2.synthDeferred) { console.log("ROUND2_WRONGLY_DEFERRED"); return; }
            if (r2.verdict !== "APPROVE") { console.log("ROUND2_LOST_R1_VERDICT: " + r2.verdict); return; }
            console.log("OK");
        })();
    ' "$wf" 2>&1)
    if [[ "$result" == "OK" ]]; then
        pass "synth stall defers (round 1), re-propagates non-stall, absorbs round-2 stall"
    else
        fail "synth stall defers (round 1), re-propagates non-stall, absorbs round-2 stall" \
            "$result"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 "synth stall"`
Expected: FAIL — pre-implementation the synth `agent()` throw is uncaught, so the workflow rejects on case (a): `THREW(stall): agent stalled on all 6 attempts…`.

- [ ] **Step 3: Implement the stall catch + defer**

In `plugins/code-review-suite/workflows/review-core.mjs`:

(3a) Wrap the synth dispatch in `crossAndSynth`. Replace the current synth call + return (~L370-383):

```js
  const envelope = await agent(synthPrompt, {
    label: 'review-synthesiser',
    phase: 'synth',
    agentType: 'code-review-suite:review-synthesiser',
    model: 'opus',
    schema: SYNTH_SCHEMA,
  })
  const synthInput = {
    findingsByDomain,
    crossOpinions,
    crossEscalations,
    intent_ledger: intentLedger || '',
  }
  return { envelope, crossByDomain, synthInput }
```

with:

```js
  // The lone in-sandbox synth turn. Under heavy Bedrock latency this can trip the
  // Workflow sandbox's fixed 180s no-progress watchdog, which throws
  // `agent stalled on all N attempts (no progress for 180000ms each)` and would
  // otherwise terminate the whole workflow uncaught. Catch ONLY that message and
  // signal a deferral; re-throw everything else (user-abandon, script bugs) so genuine
  // errors are never masked. synthStalled is the sole signal distinguishing a stall-null
  // from a benign API-error null — the round-1 caller keys the recovery on it.
  let envelope = null
  let synthStalled = false
  try {
    envelope = await agent(synthPrompt, {
      label: 'review-synthesiser',
      phase: 'synth',
      agentType: 'code-review-suite:review-synthesiser',
      model: 'opus',
      schema: SYNTH_SCHEMA,
    })
  } catch (e) {
    if (/stalled on all \d+ attempts/.test((e && e.message) || '')) {
      log('synth stalled on the sandbox watchdog — deferring to out-of-sandbox recovery')
      envelope = null
      synthStalled = true
    } else {
      throw e
    }
  }
  const synthInput = {
    findingsByDomain,
    crossOpinions,
    crossEscalations,
    intent_ledger: intentLedger || '',
  }
  return { envelope, crossByDomain, synthInput, synthPrompt, synthStalled }
```

(3b) Add the round-1 defer. At the round-1 site (~L198), change the destructure to capture the new fields and add the defer return immediately after the `crossAndSynth` call, before the `phaseLog.cogs.push` loop:

Replace:

```js
let { envelope, crossByDomain, synthInput } = await crossAndSynth(findingsByDomain, false)
for (const c of crossByDomain) {
```

with:

```js
let { envelope, crossByDomain, synthInput, synthPrompt, synthStalled } = await crossAndSynth(findingsByDomain, false)
// Round-1 stall → defer out of the sandbox. Return the exact synth prompt so the caller
// (main agent loop) can re-dispatch the synthesiser as a standalone Agent under the 600s
// async-agent watchdog, then re-enter via the finalize route. MUST precede finalizeBundle:
// a stall leaves envelope null, which finalizeBundle would otherwise swallow as a
// Category-C empty bundle, and the recovery would never fire.
if (synthStalled) return { synthDeferred: true, synthPrompt }
for (const c of crossByDomain) {
```

Leave the round-2 site (`const { envelope: envelope2, … } = await crossAndSynth(unioned, true)`) unchanged — it does not destructure `synthStalled`, so a round-2 stall yields `envelope2 === null`, and the existing `if (envelope2 && envelope2.tiers) … else 'retain round-1'` degrade absorbs it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `synth stall defers (round 1), re-propagates non-stall, absorbs round-2 stall`, and Task 1's `finalize route parity` plus all pre-existing tests still green.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/workflows/review-core.mjs tests/lib/test_workflow_migration.sh
git commit -m "$(cat <<'EOF'
feat(code-review): defer stalled synth for out-of-sandbox recovery

Catch the sandbox watchdog's stall throw inside crossAndSynth (only the
`stalled on all N attempts` message; everything else re-propagates) and
return a synthDeferred bundle carrying the synth prompt from the round-1
site. The round-2 site needs no change — the existing retain-round-1
degrade absorbs a round-2 stall, which also closes the latent round-2
uncaught-throw crash.
EOF
)"
```

---

## Task 3: Standalone recovery-mode note + `Write` tool grant in `review-synthesiser.md`

Tell the synthesiser agent that when its prompt carries an `Envelope output path:` line, it must also `Write` the structured envelope JSON to that path (in addition to its normal stdout prose). **Grant the agent the `Write` tool** — its current frontmatter is `tools: Read, Grep, Glob, Bash`, with no `Write`, so the standalone recovery dispatch inherits a toolset that physically cannot honour the contract: it would write no file, the caller's defensive read would fail, and every recovery would silently degrade to the empty bundle (the exact opposite of "full synthesis quality preserved"). No change to analysis, tiering, or verdict logic. Granting `Write` is safe for the normal in-sandbox path too — that dispatch never receives an `Envelope output path:` line, so it never writes.

**Files:**
- Modify: `plugins/code-review-suite/agents/review-synthesiser.md` — (a) add `Write` to the `tools:` frontmatter line (`tools: Read, Grep, Glob, Bash` → `tools: Read, Grep, Glob, Bash, Write`); (b) add the "Standalone recovery mode" section immediately before the `## Rules` heading (currently ~L433) — NOT after the "always present)." line at ~L421, which would orphan the "If no findings at all…" output template at ~L423-431 (still part of the `## Envelope output` section) under the new heading.
- Test: `tests/lib/test_workflow_migration.sh` (new function `test_synthesiser_documents_standalone_recovery`)

**Interfaces:**
- Consumes: the existing "Envelope output (review-core consumer)" section (the envelope shape the standalone mode reuses verbatim).
- Produces: a documented contract that the agent writes the envelope JSON to the `Envelope output path:` value — relied on by Task 4's caller branch.
- Produces: a `Write`-capable synthesiser agent (frontmatter `tools:` now includes `Write`).

- [ ] **Step 1: Write the failing test**

Add this function to `tests/lib/test_workflow_migration.sh`:

```bash
# Task 3: the synthesiser agent must document the standalone recovery mode — when an
# `Envelope output path:` line is present, Write the structured envelope JSON to that path.
# It must ALSO be granted the Write tool, or the standalone dispatch inherits a toolset that
# cannot honour the contract and every recovery silently degrades to the empty bundle.
test_synthesiser_documents_standalone_recovery() {
    local cr
    cr=$(_wm_cr_dir)
    local synth="$cr/agents/review-synthesiser.md"
    if [[ ! -f "$synth" ]]; then
        fail "synthesiser standalone recovery note" "review-synthesiser.md not found"
        return
    fi
    if grep -qF 'Envelope output path:' "$synth"; then
        pass "synthesiser documents the Envelope output path: recovery trigger"
    else
        fail "synthesiser documents the Envelope output path: recovery trigger" \
            "review-synthesiser.md must document the standalone recovery mode keyed on an 'Envelope output path:' prompt line"
    fi
    if grep -qiE 'standalone recovery' "$synth"; then
        pass "synthesiser has a Standalone recovery mode section"
    else
        fail "synthesiser has a Standalone recovery mode section" \
            "add a 'Standalone recovery mode' note instructing the agent to Write the envelope JSON"
    fi
    # The recovery contract is inert without the Write tool: the standalone dispatch inherits
    # this frontmatter, so a missing Write grant means the agent cannot write the envelope file
    # and the caller's defensive read always falls back to the empty bundle. Assert the tools:
    # frontmatter line grants Write.
    if grep -qE '^tools:.*\bWrite\b' "$synth"; then
        pass "synthesiser frontmatter grants the Write tool (recovery envelope file write)"
    else
        fail "synthesiser frontmatter grants the Write tool (recovery envelope file write)" \
            "review-synthesiser.md 'tools:' frontmatter must include Write — without it the standalone recovery dispatch cannot write the envelope JSON and every recovery degrades to the empty bundle"
    fi
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 "standalone recovery\|Write tool"`
Expected: FAIL — none of `Envelope output path:`, `Standalone recovery`, nor a `Write` grant in the `tools:` frontmatter is present in `review-synthesiser.md` yet (the frontmatter is `tools: Read, Grep, Glob, Bash`).

- [ ] **Step 3: Grant the `Write` tool + add the note**

(3a) Grant `Write`. In the frontmatter at the top of `plugins/code-review-suite/agents/review-synthesiser.md`, change the tools line:

```markdown
tools: Read, Grep, Glob, Bash
```

to:

```markdown
tools: Read, Grep, Glob, Bash, Write
```

(3b) Add the note. Insert the section immediately **before** the `## Rules` heading (currently ~L433) — i.e. after the "If no findings at all…" output template that closes the `## Envelope output` section at ~L431. Do NOT insert it after the "always present)." line at ~L421: the "If no findings at all across all specialists…" block at ~L423-431 still belongs to `## Envelope output`, and a `##` heading placed at L422 would orphan it under the new recovery section.

```markdown

## Standalone recovery mode (envelope file output)

When your prompt contains a line of the form `Envelope output path: <path>`, you are being
run as a **standalone stall-recovery** dispatch (the in-sandbox synthesis stalled on the
Workflow watchdog). In addition to your normal stdout prose report, you MUST `Write` the
structured envelope — the exact object specified in "Envelope output (review-core consumer)"
above (`verdict`, `rubricRowApplied`, `rubricReason`, `tiers.{consensus,synthesiser,contested,dismissed}`,
`bodyText`) — as JSON to `<path>`. The prose stdout is for the human; the JSON file is the
machine hand-off that review-core's `finalize` route reads to run the Class D filter and render
comments. Write valid JSON only (no markdown fences around it). Nothing else about your
analysis, reclassification, tiering, or verdict computation changes — this mode only adds the
JSON file write.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — all three: `synthesiser documents the Envelope output path: recovery trigger`, `synthesiser has a Standalone recovery mode section`, and `synthesiser frontmatter grants the Write tool (recovery envelope file write)`; pre-existing synthesiser tests (`synthesiser envelope: references finding-schema synthEnvelope def`, etc.) still green.

- [ ] **Step 5: Commit**

```bash
git add plugins/code-review-suite/agents/review-synthesiser.md tests/lib/test_workflow_migration.sh
git commit -m "$(cat <<'EOF'
feat(code-review): document synthesiser standalone recovery mode

Grant the synthesiser the Write tool and document that when the prompt
carries an `Envelope output path:` line, it now also writes the structured
envelope JSON to that path so review-core's finalize route can seal the
recovered review. Without the Write grant the standalone recovery dispatch
could not write the file and every recovery degraded to the empty bundle.
Prose to human, JSON to machine; analysis and verdict logic unchanged.
EOF
)"
```

---

## Task 4: Caller-side stall-recovery branch in Step 3.5 (all three copies)

Add the recovery branch to the canonical pipeline Step 3.5, then propagate the identical text to the two verbatim-inlined copies. When the Workflow returns `synthDeferred`, the caller dispatches the standalone synthesiser, reads the envelope file, and re-invokes the Workflow's `finalize` route.

**Files:**
- Modify: `plugins/code-review-suite/includes/review-pipeline.md` (Step 3.5, after "The Workflow returns the sealed bundle…" ~L887, **canonical**)
- Modify: `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` (same Step 3.5 block ~L993, copy verbatim)
- Modify: `plugins/code-review-suite/commands/pre-review.md` (same Step 3.5 block ~L888, copy verbatim)
- Test: `tests/lib/test_workflow_migration.sh` (new function `test_caller_wires_stall_recovery`)

**Interfaces:**
- Consumes: `synthDeferred` bundle + `synthPrompt` (Task 2), the `finalize` route (Task 1), the agent's envelope-file write (Task 3).
- Produces: no code artifact; prose instructions the main agent loop executes.

- [ ] **Step 1: Write the failing test**

Add this function to `tests/lib/test_workflow_migration.sh`:

```bash
# Task 4: all three pipeline copies must document the caller-side stall-recovery branch
# (synthDeferred → standalone dispatch → finalize re-entry). The sync test enforces the three
# are byte-identical; this test asserts the recovery tokens are present in each.
test_caller_wires_stall_recovery() {
    local cr
    cr=$(_wm_cr_dir)
    local file
    for file in includes/review-pipeline.md skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if [[ ! -f "$path" ]]; then
            fail "caller wires stall recovery: $file" "file not found"
            continue
        fi
        if grep -qF 'synthDeferred' "$path" \
            && grep -qF 'synth-standalone-recovery' "$path" \
            && grep -qF "route: 'finalize'" "$path"; then
            pass "caller wires stall recovery: $file has the synthDeferred recovery branch"
        else
            fail "caller wires stall recovery: $file has the synthDeferred recovery branch" \
                "Step 3.5 must handle a synthDeferred bundle: standalone review-synthesiser dispatch (name synth-standalone-recovery) then a workflow re-invoke with route: 'finalize'"
        fi
    done
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh 2>&1 | grep -A2 "caller wires stall recovery"`
Expected: FAIL for all three files — none contains `synthDeferred` yet.

- [ ] **Step 3: Add the recovery branch to the canonical pipeline**

In `plugins/code-review-suite/includes/review-pipeline.md`, in Step 3.5, immediately after the paragraph ending "…the script normalises a string arg before destructuring." (the `review-core tolerates both args shapes` paragraph, ~L892-894), insert:

````markdown

**Stall-recovery branch.** The returned object is normally the sealed bundle. If instead it
carries `synthDeferred: true`, the in-sandbox synthesiser stalled on the Workflow watchdog and
review-core deferred it rather than dying. Recover it out-of-sandbox — do NOT re-run the
Workflow's synth path (it would re-stall):

1. Dispatch `review-synthesiser` as a **standalone Agent** (`mode: auto`, name
   `synth-standalone-recovery`) — NOT via the Workflow, so it runs under the 600s async-agent
   watchdog instead of the 180s sandbox one. Its prompt is `bundle.synthPrompt` with a single
   line appended:

   ```
   Envelope output path: $RESOLVED_TEMP_DIR/synth-envelope-$HEAD_SHA.json
   ```

2. When it returns, `Read` that path and `JSON.parse` it into `$RECOVERED_ENVELOPE`. If the
   file is missing, empty, or does not parse, do NOT retry into the sandbox — present the empty
   bundle `{ verdict: 'NONE', bodyText: '(synthesiser produced no usable output)', comments: [] }`
   and continue to Step 4 / report rendering. The review degrades; it never hangs. (This branch
   is model-executed prose, not deterministic code, so the fallback must be explicit.)

3. Re-invoke the Workflow to seal the recovered envelope deterministically:

   ```
   workflow({scriptPath: $REVIEW_CORE_PATH}, { route: 'finalize', reviewMode: $REVIEW_MODE, envelope: $RECOVERED_ENVELOPE })
   ```

   The `finalize` route spawns zero agents (the watchdog never engages) and runs the same
   Class D filter + comment renderer as the normal path. Its return value is the sealed bundle;
   use it exactly as the normal bundle below. The launch-approval prompt for this second
   Workflow invoke is silenced under `auto` mode (already required for the first launch).
````

- [ ] **Step 4: Propagate the identical block to the two inlined copies**

The Step 3.5 block is inlined verbatim into `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`. Insert the **exact same** markdown block (from Step 3 above) at the corresponding location in each — immediately after the `review-core tolerates both args shapes…` paragraph:

- `skills/review-gh-pr/SKILL.md` — after the paragraph at ~L998-1000.
- `commands/pre-review.md` — after the corresponding paragraph at ~L892-894.

Copy byte-for-byte; the sync test compares the canonical range against each consumer and fails on any difference (even whitespace).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `caller wires stall recovery: …` for all three files, AND `pipeline inline sync: skills/review-gh-pr/SKILL.md matches canonical` + `pipeline inline sync: commands/pre-review.md matches canonical` still green (proving the three copies are byte-identical). If a sync test fails, its diff output shows exactly which line drifted — fix the copy to match canonical and re-run.

- [ ] **Step 6: Commit**

```bash
git add plugins/code-review-suite/includes/review-pipeline.md plugins/code-review-suite/skills/review-gh-pr/SKILL.md plugins/code-review-suite/commands/pre-review.md tests/lib/test_workflow_migration.sh
git commit -m "$(cat <<'EOF'
feat(code-review): wire caller-side synth stall recovery branch

Step 3.5 now handles a synthDeferred bundle: dispatch the synthesiser as
a standalone Agent (600s watchdog) that writes the envelope JSON, read it
back, and re-invoke the Workflow's finalize route to seal it. Falls back
to the empty bundle if the recovery file is missing/unparseable — the
review degrades, never hangs. Propagated byte-identically to the two
inlined pipeline copies (SKILL.md, pre-review.md).
EOF
)"
```

---

## Final verification

- [ ] **Run the full suite once more from a clean tree:** `bash tests/run.sh` — expect all green, including the four new tests and the sync-note tests.
- [ ] **Confirm the branch is coherent:** `git log --oneline main..HEAD` should show the spec commit plus the four task commits.
- [ ] **Integration (manual, opportunistic):** on the next large-diff review that stalls — or by temporarily injecting a stall throw into the synth mock in a scratch run — confirm the deferred → standalone → finalize path yields a bundle identical in shape to the normal path. This cannot be exercised in the structural suite (no live Bedrock stall), so note it as a deferred live check, per the spec's Testing section.

## Self-Review notes (author)

- **Spec coverage:** Component 1 (stall detect) → Task 2 Step 3a; Component 2 (defer) → Task 2 Step 3b; Component 3 (finalize route + `finalizeBundle` + `POST_THRESHOLD` hoist + PR-guarded gate) → Task 1; Component 4 (caller branch, unique filename, defensive read) → Task 4; Component 5 (agent contract **+ `Write` tool grant**) → Task 3. The `Write` grant is load-bearing, not cosmetic: the standalone recovery dispatch inherits the synthesiser's frontmatter tools, and the current `tools: Read, Grep, Glob, Bash` has no `Write`, so without the grant every recovery would degrade to the empty bundle. Conscious degradations (no round-2 on recovery, thinner `full_log`, no `## Cost`, scope = stall throw only) are structural consequences of the above, not separate tasks. Testing section → the four `test_*` functions (the Task 3 test now also asserts the `Write` grant) + the deferred live integration check.
- **Type consistency:** `finalizeBundle(envelope, reviewMode, phaseLog)` signature is identical at both call sites (Task 1 Step 3c normal path, Step 3b finalize route). `crossAndSynth` return keys (`envelope, crossByDomain, synthInput, synthPrompt, synthStalled`) match the round-1 destructure (Task 2 Step 3b). The `synthDeferred` bundle shape `{ synthDeferred:true, synthPrompt }` matches the caller's `bundle.synthDeferred` / `bundle.synthPrompt` reads (Task 4 Step 3).
- **Placeholder scan:** none — every code and prose step carries full content.
