# Phase 3.2b — eslint-reviewer apparatus fix + clean re-probe

**Date:** 2026-06-02
**Status:** Approved (design); not yet implemented
**Author:** Christian Haddrell
**Supersedes the "harden first" framing in:** Phase 3.2 result note
([`../notes/2026-06-02-eslint-haiku-low-result.md`](../notes/2026-06-02-eslint-haiku-low-result.md))
**Parent programme:**
[`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)
**Precedent (ruff, equivalent):**
[`../notes/2026-06-02-ruff-haiku-low-result.md`](../notes/2026-06-02-ruff-haiku-low-result.md)

## Context

Phase 3.2 (PR #41, `bee75c9`) probed `eslint-reviewer` at Haiku/low against a
Sonnet/default baseline and returned **inconclusive**: Haiku/low 17/20 NORMAL,
3 divergent trials (2 "spurious eslint-not-available" skips + 1 §7
structured-output drop), against an asymmetric n=3 Sonnet baseline. The result
note diagnosed two failure modes — "spurious tool-skip" and "prose/structured
recall loss" — and the operator directed prompt-hardening *before* any further
baselining.

Forensic analysis of the gitignored run dirs reframes that diagnosis. The
"spurious tool-skip" is **not** a Haiku reliability defect; it is an apparatus
confound. The design below removes the confound first, re-measures under
symmetric power, and hardens the prompt **only if** a genuine agent-side tail
survives. This deliberately inverts the original "harden first" instruction
because its premise (a Haiku skip defect) is now shown to be mostly apparatus.

## The apparatus confound (forensic findings)

Three facts combine to produce the observed "skip" tail:

1. **The fixture ships no `node_modules`.**
   `tests/fixtures/static-analysis/eslint/package.json` declares `eslint`
   `^10.4.1` as a devDependency, but the `copy` working-dir strategy
   (`tests/ab/lib/fixture.sh:89`, `cp -R "$src/." "$out_dir/"`) materialises
   only the three committed source files. No install step runs.

2. **No eslint exists on the host outside a project install.** Verified
   2026-06-02: `which eslint` → not found; no repo-root
   `node_modules/.bin/eslint`. Only `npx` (`/opt/homebrew/bin/npx`) is present.
   So `eslint-reviewer.md`'s documented binary-resolution ladder
   (project-local → repo-root → global PATH → **skip**, lines 34–39)
   legitimately bottoms out at "skip" unless the agent self-provisions.

3. **The working dir is materialised once per run, shared across all 20
   trials** (`tests/ab/run.sh:249`, `working_dir="${CLAUDE_TEMP_DIR:-/tmp}/per-agent-${timestamp}"`,
   then `fixture_materialise` on line 250 — outside the trial loop).

The trace confirms the mechanism is an **order-dependent race on shared mutable
state**:

- Only **3/20** Haiku/low trials (001, 010, 017) ran `npm install` to
  self-provision eslint; they succeeded.
- **trial-015** (the §7-drop) *found* `node_modules/.bin/eslint` already present
  — a prior trial's install had populated the shared dir — ran it fine, then
  dropped the §7 blocks. Even this trial ran the tool successfully; its failure
  is output-only.
- The **2 pure skips** (016, 019) ran only `which eslint` / `eslint --version`,
  found nothing, and correctly emitted the documented skip sentinel. They ran
  before any install had populated the shared dir.

So Phase 3.2 measured a race, not a Haiku property. The Sonnet n=3 baseline
looked clean only because at least one of its trials installed early and the
others inherited the populated dir. Ruff escaped this entirely because `ruff`
is global on PATH (`/opt/homebrew/bin/ruff`), so its trials never raced — which
is why 3.1b was cleanly 20/20 equivalent.

**Conclusion:** of the 3.2 tail, the 2 skips are pure apparatus; the 1 §7-drop
is the only plausibly-real agent-side mode, and it too is entangled with the
contaminated apparatus. The headline "Haiku misses/skips" framing is largely an
artefact.

## Measured token cost (from existing runs, zero new spend)

Extracted from the `result` envelope (`total_cost_usd`, `output_tokens`,
`num_turns`, `cache_read_input_tokens`) of every trial's `stream.jsonl`:

| Arm | n | mean out tok | mean turns | mean cost/trial* |
|---|---|---|---|---|
| Sonnet/default | 3 | 1,733 | 11 | $0.161 |
| Haiku/low | 20 | 2,031 | ~10 | $0.066 |

\* The CC stream's `total_cost_usd` is computed at **Anthropic list prices, not
Bedrock**. Treat the absolute dollars as indicative of the *ratio*, not the
actual Bedrock bill.

Three observations, load-bearing for the arm matrix:

1. **The price-tier saving is real and large.** Haiku/low is ~2.4× cheaper than
   Sonnet/default per trial — the lever the whole Phase 3 programme chases,
   now confirmed rather than assumed.

2. **Cost is dominated by turns × cached context, not output tokens.** Within
   Haiku/low, the cheap trials (016/019, 4–6 turns) cost ~$0.039; the expensive
   ones (008 at 25 turns, 018 at 20 turns) cost $0.116–$0.133 — a **3.4× swing
   on the same model/effort**, driven by tool-use turn count and per-turn
   `cache_read` (115k–800k tokens). Output tokens (966–4,483) barely move the
   needle.

3. **This bounds the effort question by inference.** No Haiku/default data
   exists, so no magnitude is claimed. But the cost structure implies that
   raising effort → more thinking tokens *and* typically more tool-use turns →
   more `cache_read` context re-billed per turn. On a transmission task with no
   real judgement to deliberate, higher effort spends more on **both** time and
   cost for, at best, a marginal reliability gain. Haiku/default is therefore
   **never a production cost-tuning candidate** — its only possible value is
   diagnostic (does more effort close a reliability tail?).

## Goals

1. Remove the apparatus confound so trials are hermetic and order-independent.
2. Re-measure Haiku/low vs Sonnet/default under symmetric power (matched n),
   fixing the n=3 asymmetry that made 3.2 inconclusive.
3. Capture the per-trial **cost delta** (the programme's actual deliverable),
   which 3.2 omitted in favour of wall-clock only.
4. Harden the agent body **only if** a genuine, reproducible agent-side failure
   mode survives the clean apparatus — and only via a model-agnostic fix.

## Non-goals

- Not a Haiku-specific prompt nudge. Any body edit must be a general
  under-specification fix that helps Sonnet too (cf. the §7 worked-example fix
  in 3.2).
- Not a change to any `*-reviewer.md` `model:` field. Probes are informational;
  production config is operator-gated.
- Not a fixture-diversity expansion in the primary path (gated follow-up only).
- Not a trivy/jbinspect phase, though the apparatus generalisation (the
  `setup` key, below) is designed to pre-solve their provisioning needs.

## Arm matrix

- **Primary: 2 arms × n=20**, on the apparatus-fixed harness:
  - `eslint-baseline.yaml` — Sonnet/default — **re-captured from scratch**
    (the 3.2 n=3 baseline and its hash are discarded as captured on the
    contaminated apparatus).
  - `eslint-haiku-low.yaml` — Haiku/low — config unchanged.
- **Gated diagnostic: Haiku/default × n=20** — `eslint-haiku-default.yaml`
  (one line different: `effort: default`). Created and run **only if** the
  clean Haiku/low arm shows a residual tail, purely to attribute that tail to
  the effort axis vs the model axis. If Haiku/low is 20/20 equivalent, this arm
  is never created.

Rationale for gating rather than running upfront: the effort arm's original
motivation ("the skip mode smells effort-driven") is dissolved by the forensic
finding that the skips were the provisioning race, not effort. The arm now only
earns its Bedrock spend if a real tail survives.

## Methodology

### PR A — apparatus fix (lands first, independently)

Harness + fixture metadata only. No `*-reviewer.md` body edit, no config
change. Three coupled changes:

**A1 — Deterministic tool provisioning.** Commit a `package-lock.json` to
`tests/fixtures/static-analysis/eslint/` pinning eslint 10.x (matching the
existing `package.json`). The installed `node_modules` stays gitignored; only
the lockfile is committed.

**A2 — Per-trial working-dir isolation.** Replace the shared-dir-per-run
(`run.sh:249–250`) with: materialise + provision once into a **template** dir,
then `cp -R` that populated template (`node_modules` included) into a fresh
per-trial working dir inside the trial loop. Each trial becomes hermetic and
order-independent; the agent hits its documented tier-1
`node_modules/.bin/eslint` path every time — no race, no `npx` improvisation.

**A3 — Generalise via a fixture `setup` key.** Add an optional `setup` block to
`source.yaml` (e.g. `setup: { command: "npm ci" }`). The harness runs it once
into the template dir if present, after `fixture_materialise`. ruff's fixture
omits it (ruff is global) → ruff's path is byte-unchanged, which is the
regression guard. This pre-solves trivy/jbinspect provisioning in 3.3/3.4
rather than special-casing eslint.

**PR A success criterion (mechanical):** re-run the *existing*
`eslint-haiku-low.yaml` and confirm **zero** skips attributable to a missing
binary. This is a confound-removal check, not a verdict.

Push immediately after merge (autoUpdate has previously re-cloned this dir on
startup and wiped an unpushed branch — never leave work unpushed here).

### PR B — clean re-probe + result note

Runs only after PR A merges and is verified.

**B1 — Re-establish the Sonnet baseline** (parent methodology Step 2). One
Sonnet/default capture on the fixed harness, hand-verified against
`eslint --format=json`: conforms to §7, covers all 4 rules, fabricates none.
Promote to `tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md`.
Bump `source.yaml` `baseline_revision` and `captured_under.suite_sha`.

**B2 — Run both arms at n=20** on the fixed harness.

**B3 — Capture cost metrics.** Extend `summary.csv` with per-trial
`output_tokens`, `num_turns`, `cache_read_input_tokens`, and `total_cost_usd`
pulled from the `result` envelope. (3.2 reported only wall-clock; the cost
delta is the programme's deliverable.)

**B4 — Verdict** (parent spec framework, carried verbatim):
- Both arms 20/20 identical canonical hash → **equivalent** (likely if the
  tail was purely apparatus).
- Mixed within-arm hashes → **inconclusive** by decision-4, then characterise
  the residual.
- >25% NORMAL-rate movement → **worse**, with recall-direction analysis
  (misses vs fabrications).

**B5 — Result note** at
`docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md`,
superseding (cross-linked, not deleting) the 3.2 note. Reports the verdict and
the **measured Bedrock cost delta** (caveated: stream cost is list-price —
report the ratio).

### PR C — conditional hardening (gated; may not exist)

Created **only if** PR B shows a surviving, reproducible agent-side tail (the
candidate is the §7 structured-output drop) **and** the operator approves.

If triggered, the intervention is a narrow, **model-agnostic** self-consistency
instruction in the agent body: the prose finding-count must equal the number of
emitted §7 blocks; if they disagree, emit the blocks. This is a general
correctness fix (helps Sonnet too), not a Haiku nudge.

**Tuning-to-the-test guard (structural):**
1. **No fixture-chasing.** Never edit the prompt then re-run the same fixture
   until green. A surviving tail is characterised first (what drifted, why);
   the fix targets the mechanism, not the hash.
2. **Hardening earns its own before/after.** Any body edit is measured by
   re-running *both* arms at n=20 again. The edit must not regress Sonnet and
   must measurably reduce the Haiku tail. One intervention, one matched
   re-measurement.
3. **Asymmetry test.** An edit that helps only Haiku and is inert/harmful for
   Sonnet is a nudge, not a fix — rejected.

**Decision authority:** harden-or-not is a gated operator call. The residual-
tail numbers are brought to the operator; no intervention is authored before
approval.

## Deliverables

- `package-lock.json` committed to the eslint fixture (PR A).
- `setup` key support in `source.yaml` + harness (PR A).
- Per-trial working-dir isolation in `run.sh` (PR A).
- Per-trial token/turn/cost columns in `summary.csv` (PR B).
- Re-established Sonnet baseline, new `baseline_revision` (PR B).
- Re-probe result note with verdict + measured Bedrock cost-delta ratio (PR B).
- Memory update recording the apparatus confound as the root cause of 3.2's
  inconclusive verdict.
- (Conditional) agent-body self-consistency fix + before/after note (PR C).

## Cost expectations

| Item | Bedrock cost |
|---|---|
| Token-cost extraction from existing 3.2 runs | $0 (done) |
| PR A verification sweep (~20 Haiku/low trials) | ≈ the 3.2 probe spend |
| PR B (baseline capture + 2×20 sweeps) | ≈ 3× a single-arm sweep |
| PR C (gated; +2×20 if triggered) | only if a tail survives |

## Verifications during implementation

- **Empirically ground the apparatus fix against a live trace.** After A1–A3,
  read a fresh trial's `stream.jsonl` and confirm the agent resolved
  `node_modules/.bin/eslint` on tier 1 with no `npm install` / `npx` turns —
  this is the proof the race is gone, not merely that skips dropped.
- **Confirm ruff is byte-unchanged** by the `setup`-key generalisation (its
  fixture omits `setup`); the existing ruff parser/faithfulness tests are the
  regression guard.
- **Do not transcribe cost-column extraction blind.** Verify the `result`
  envelope field names against an actual `stream.jsonl` (confirmed 2026-06-02:
  `total_cost_usd`, `usage.output_tokens`, `num_turns`,
  `usage.cache_read_input_tokens`).

## Cross-references

- Parent programme:
  [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)
- Phase 3.2 result (superseded framing):
  [`../notes/2026-06-02-eslint-haiku-low-result.md`](../notes/2026-06-02-eslint-haiku-low-result.md)
- Phase 3.1b (ruff, equivalent precedent):
  [`../notes/2026-06-02-ruff-haiku-low-result.md`](../notes/2026-06-02-ruff-haiku-low-result.md)
- Phase 3.1c (apparatus baseline):
  [`../notes/2026-06-02-phase-3-1c-validation-sweep.md`](../notes/2026-06-02-phase-3-1c-validation-sweep.md)
