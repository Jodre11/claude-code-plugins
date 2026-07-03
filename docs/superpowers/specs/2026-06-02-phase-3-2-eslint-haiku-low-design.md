# Phase 3.2 — eslint-reviewer Haiku/low probe (design)

**Date:** 2026-06-02
**Status:** Approved (design); not yet implemented
**Author:** Christian Haddrell
**Builds on:**
- Parent methodology: [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md) (Steps 1–5)
- Precedent probe: [`2026-06-02-phase-3-1b-ruff-haiku-low-design.md`](2026-06-02-phase-3-1b-ruff-haiku-low-design.md) (ruff, shipped PR #40)
- Apparatus baseline: [`../notes/2026-06-02-phase-3-1c-validation-sweep.md`](../notes/2026-06-02-phase-3-1c-validation-sweep.md) (Phase 3.1c, PR #39)

## Context

Phase 3.1b answered the cost-tuning question for the first static specialist:
`ruff-reviewer` at Haiku/low is **equivalent** to the Sonnet/default baseline on
finding sets (20/20 NORMAL, identical canonical hash, Wilson 95 % CI
[83.89 %, 100.00 %]; PR #40, merge `4543564`). Per the parent spec's sequencing,
a decisive ruff pass makes the same answer "very likely" for the other three
static specialists, so the sweep continues at full scope — one specialist per
gated phase.

Phase 3.2 is the second specialist: `eslint-reviewer`. It asks the same
question and follows the same methodology, but carries a one-time structural
cost the later phases will not: the **parser-dispatch refactor**. The current
harness hardcodes the ruff parser; eslint is the first specialist to force that
to generalise. Once 3.2 lands the refactor, Phases 3.3 (trivy) and 3.4
(jbinspect) become pure "add fixture + config + dispatch-table row + report"
phases.

## The question

For `eslint-reviewer`, is Haiku/low equivalent to the Sonnet/default baseline on
finding sets? Concretely (parent spec's two questions):

1. Does Haiku/low produce a findings hash byte-equal to the freshly-captured
   Sonnet/default baseline across 20 trials?
2. If divergent, in which direction — does Haiku *miss* findings (recall loss)
   or *invent* findings (false positives)?

## Goals

- A parser-dispatch refactor that generalises the harness's hardcoded ruff
  parser into a name-dispatched, parameterised core, with the ruff path
  byte-identical (regression-guarded by the existing test suite).
- A richer eslint smoke fixture (3–5 deterministic findings) whose ground truth
  is `eslint`'s own JSON output, not human intuition.
- An `eslint-baseline.yaml` (sonnet/default) + `eslint-haiku-low.yaml`
  (haiku/low) config pair.
- A freshly-captured Sonnet/default baseline, hand-verified against `eslint`
  JSON output and promoted to the corpus fixture's `expected/`.
- A 20-trial Haiku/low sweep, classified NORMAL/DRIFT/EMPTY/OTHER with Wilson
  95 % CIs.
- A one-page result report at
  `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md`, plus a PR
  against `main`.

## Non-goals

- **Not** a production config change. The probe *informs* a later adoption
  decision; it does not flip `eslint-reviewer.md`'s `model:` field.
- **Not** trivy or jbinspect. Those are separate gated phases (3.3, 3.4) that
  consume the parser-dispatch refactor this phase lands.
- **Not** a reasoning-specialist phase (different fixture-sourcing posture; own
  spec).
- **Not** a re-litigation of 3.1c or a fresh ruff sweep. The ruff path is only
  touched insofar as the refactor must keep it byte-identical.
- **Not** a CI gate or an absolute-ground-truth recall benchmark.

## Design decisions

### 1. Trial count — n=20, Haiku/low arm; fresh Sonnet baseline

Match 3.1b: a 20-trial Haiku/low arm against a Sonnet/default baseline. Unlike
3.1b (which *cited* 3.1c's Sonnet sweep), eslint has no prior Sonnet baseline, so
this phase captures one: one baseline-capture trial promoted to the fixture,
plus a short within-arm determinism check at sonnet/default to confirm the
baseline is itself stable before it becomes the equivalence target. n=20
satisfies 3.1a's ≥10-trials/arm mandate with margin and gives clean Wilson CIs.
Cost: ~50 k tokens for the Haiku arm, plus the baseline capture + determinism
check.

### 2. Parser layer — dispatch table + parameterised core (Approach A)

The canonical `static-analysis-context.md §7` bullet shape
(`- **File:**`, `- **Rule:**`, `- **Severity:**`, `- **Confidence:**`) is
identical across all four static specialists. Only three things differ
per specialist:

1. **Block heading** — `## Ruff Findings` vs `## ESLint Findings`.
2. **Rule-ID tokenisation** — ruff splits `F401 (Pyflakes)` on `[ \t(]` and
   takes token 1; eslint's kebab-case IDs (`no-unused-vars`) are the whole
   token (identity); trivy (3.3) needs dual CVE/AVD namespaces; jbinspect (3.4)
   takes the CamelCase token.
3. **Skip / zero-state sentinels** — the `^Skipped — ` regex and the
   `0 findings …` zero-state line are per-tool prose.

The refactor extracts a new public entry point
`agent_capture_parse_trial <agent> <trial_dir>` that looks the agent up in a
dispatch table and runs the shared §7 state-machine (the existing awk +
`sort | jq` + hash logic, moved **unchanged** — it is already
specialist-agnostic) with that agent's parameters. The dispatch table supplies
the heading, a rule-ID tokeniser function name (default: identity), and the
sentinels. `agent_capture_parse_ruff_trial` is retained as a thin shim
(`agent_capture_parse_trial ruff "$trial_dir"`) so existing references keep
working. `run.sh` calls `agent_capture_parse_trial "$_AB_CONFIG_AGENT"
"$trial_dir"`, and the hardcoded `findings-ruff.md` baseline-synth path
generalises to `findings-<agent>.md`.

Rejected alternatives: **(B)** per-specialist parser functions with `case`
dispatch — the parent spec's stated plan, but ~90 lines of near-duplicated awk
across three functions, and a future §7 fix would need applying four times
(the drift the sync-check tests exist to prevent). **(C)** defer dispatch and
alias only eslint now — punts the decision and forces a rewrite at 3.3.

### 3. Fixture richness — 3–5 deterministic findings

Per the parent spec's eslint example: a JS/TS file exercising at least
`no-unused-vars` + `prefer-const` + `no-var` + `eqeqeq`. Single-finding
under-tests the multi-finding parse + the deterministic tuple sort, so the
fixture is richer than `ruff-smoke-bad-py`. Ground truth is `eslint`'s own JSON
output (`eslint --format json`), captured independently and used as the source
of truth — not the human's intuition about what eslint *should* flag. The
existing `tests/fixtures/static-analysis/eslint/` minimal fixture (1 finding,
`no-unused-vars` only) is extended in place — its `bad.js` grows to exercise the
3–5 rule target and its `eslint.config.js` is adjusted to enable the added rules.

### 4. Verdict framework — parent Step 5 + explicit recovery rule

Verdict ∈ {`equivalent` | `better` | `worse` | `inconclusive`}, with the parent
spec's >25 % movement guard, measured as the Haiku/low NORMAL (canonical-hash
match) rate versus the Sonnet baseline. Recovered-trial accounting: a
fallback-recovered trial parsing to the canonical tuple counts NORMAL; prose-only
recovery counts DRIFT. Within-arm non-determinism (mixed hashes) defaults to
`inconclusive` / "no". Residual unrecoverable EMPTY (validate-or-die fired) is
footnoted as the upstream CLI envelope-finalisation gap and does not block the
verdict; if it fires, its count is stated and those trials are excluded from the
equivalence denominator (with the adjusted n noted). All rules carry over
verbatim from 3.1b.

## Methodology

### Step 0 — Pre-flight (offline)

- Confirm the branch `feat/phase-3-2-eslint-haiku-low` is pushed to `origin`
  (autoUpdate-wipe guard; see the `marketplace-autoupdate-wiped-unpushed-branch`
  memory).
- Confirm tooling: `node`/`npx` on PATH (eslint runs via `npx eslint`). Confirmed
  present on the host as of 2026-06-02.
- Confirm the parser-dispatch refactor's offline tests pass and the existing
  `ab agent capture *` ruff tests stay green.

### Step 1 — Parser-dispatch refactor (offline, no Bedrock spend)

Extract `agent_capture_parse_trial`, add the dispatch table, keep the ruff shim,
update `run.sh`. The ruff path must be byte-identical: the existing
`ab agent capture *` tests are the regression guard and must stay green.

### Step 2 — eslint smoke fixture + Sonnet baseline capture

Author the 3–5 finding JS/TS fixture; run `eslint --format json` to capture the
tool's ground truth. Run one `eslint-reviewer` trial at sonnet/default; hand-review
the captured `agent-output.md` against §7 AND the eslint JSON (covers every
finding, fabricates none). Promote it to
`tests/ab/corpus/eslint-smoke-<slug>/expected/findings-eslint.md`. **The eslint
parser parameters (heading text, skip sentinel, rule-ID tokeniser) are confirmed
against this live trace and the offline parser tests authored from it** (see
"Guarding against parser guessing" below).

### Step 3 — Sonnet determinism check

A short within-arm faithfulness check at sonnet/default (≥3 trials), confirming
the baseline is itself deterministic before it becomes the equivalence target.
A divergence here means the specialist is non-deterministic at sonnet — note and
abort the eslint sweep (its own investigation).

### Step 4 — Haiku/low sweep (operator-gated, ~50 k tokens)

Surface the cost at an operator gate. On go-ahead, run 20 trials with the
`eslint-haiku-low.yaml` config, `--stream-json`. Mirrors the 3.1b sweep command.

### Step 5 — Classification + CIs (offline)

Re-parameterise the 3.1b `classify_trials.py` overlay with eslint's canonical
hash (a `$CLAUDE_TEMP_DIR`-resident per-run overlay, not committed). Verify it
against the eslint baseline run dir before the Haiku sweep — the same
zero-Bedrock-cost oracle pattern 3.1b used. Classify the Haiku run dir; corroborate
row-for-row against the native `summary.csv`.

### Step 6 — Operator gate (classification + verdict)

Surface the class breakdown + Wilson CIs + the equivalence verdict + any
residual-EMPTY footnote. Wait for confirmation before writing the report.

### Step 7 — Report + land

Write `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md` per the
parent spec's Step 5 structure. Commit after every step; push immediately; open
a PR against `main`. Run dirs under `tests/ab/runs/` are gitignored.

## Guarding against parser guessing

The parent spec names "transcribe a parser from spec into code without first
running a trace" as the dominant failure mode of plan-style specs, and this
programme has prior form (the `models-overlook-tuning-hooks` memory; and Phase
3.1c itself was triggered by exactly such a deviation — the ruff parser had to
be pinned to canonical §7 because the live trace had drifted from the spec'd
`### Finding —` heading to `**Finding N**`, which the determinism test
surfaced). The mitigation is structural, not an instruction to be diligent:

1. **Capture-before-parser ordering, enforced by the plan's task DAG.** The
   Sonnet baseline trace is captured *first*; the parser-test task is
   `blockedBy` it. Parser tests are authored *from* the captured
   `agent-output.md` on disk, never from this spec. There is no point in the
   timeline where the parser exists but the trace does not.
2. **The committed `expected/findings-eslint.md` IS the captured trace.** A
   reviewer and the offline tests diff the parser's output against it. A guessed
   heading or sentinel yields zero tuples → the determinism/canonical tests fail
   loudly. Guessing wrong is caught, not silently accepted.
3. **Anti-guessing assertion in the plan.** A literal verification step requires
   quoting the actual heading line and a sample finding block *from the captured
   `stdout.log`*, with the line cited — surfacing the evidence in-band, the way
   3.1b surfaced the oracle output before the sweep.
4. **The Bedrock gate is downstream of all of this.** The ~50 k-token Haiku
   sweep is gated behind a passing offline parser-test suite grounded on the
   real Sonnet trace. A guessed parser cannot reach the expensive step.

The committed-trace + offline-test-gate is treated as sufficient enforcement; no
extra CI machinery is added.

## Operational constraints

- **Push immediately.** This clone (`~/.claude/plugins/marketplaces/jodre11-plugins`)
  is an autoUpdate-managed marketplace clone; a prior reclone wiped an unpushed
  branch (2026-06-02). Push `feat/phase-3-2-eslint-haiku-low` on the first
  commit and re-push after every commit.
- **Bash hook rules.** No compound commands (`&&`, `||`, `;`), no `$(...)` or
  backticks (except the commit/PR HEREDOC carve-out), no loops/subshells in a
  single Bash call. Multi-step shell recipes go in a script file run with one
  `bash <path>` call. Temp files under `$CLAUDE_TEMP_DIR`.
- **Variation via the harness, never the agent.** Model/effort variation flows
  from the config YAML, never from editing `eslint-reviewer.md`.
- **Classifier is a per-run overlay, not committed** (matches the 3.1b / 3.1c
  precedent).

## Repo housekeeping

Per the global CLAUDE.md housekeeping directive: at plan time, surface
dependency / GitHub Actions / runner / Trivy-IaC freshness and decide whether it
ships in this PR or a separate one (default: separate first). For 3.2 the change
surface is docs + harness shell + a JS fixture, so housekeeping is likely a
no-op — but it is checked, not assumed. The JS fixture introduces an
`eslint` dev-dependency footprint; confirm the pinned eslint version is current
GA when authoring the fixture.

## Cost expectation

- Parser refactor, fixture authoring, classification, report: offline.
- Sonnet baseline capture + determinism check (≥3 trials): ~10–30 k tokens.
- Haiku/low 20-trial sweep: ~50 k tokens, ~9–10 min wall-clock.

## Cross-references

- Parent Phase 3 spec: [`2026-05-29-static-specialist-tuning-sweep.md`](2026-05-29-static-specialist-tuning-sweep.md)
- Phase 3.1b (ruff) design: [`2026-06-02-phase-3-1b-ruff-haiku-low-design.md`](2026-06-02-phase-3-1b-ruff-haiku-low-design.md)
- Phase 3.1b result: [`../notes/2026-06-02-ruff-haiku-low-result.md`](../notes/2026-06-02-ruff-haiku-low-result.md)
- Phase 3.1c validation sweep: [`../notes/2026-06-02-phase-3-1c-validation-sweep.md`](../notes/2026-06-02-phase-3-1c-validation-sweep.md)
