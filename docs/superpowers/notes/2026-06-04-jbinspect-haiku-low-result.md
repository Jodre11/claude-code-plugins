# Phase 3.4 — jbinspect-reviewer Haiku/low A/B result

**Date:** 2026-06-04
**Status:** EQUIVALENT after two fixes — the initial probe was INCONCLUSIVE (2/20 Haiku temp-dir self-abort skips); a `--stdout` streaming fix removed the up-front abort and recovered the cost ratio, then an apparatus fix (harness trial dirs moved under the hook-exempt `/tmp/claude-` namespace) closed a residual non-deterministic hook-leak skip. The final validation re-sweep is a clean **20/20 on both arms**.

> **Reading order.** The body documents the **initial** probe (INCONCLUSIVE,
> tail characterised). The two fixes and the clean re-sweeps that upgrade the
> verdict to EQUIVALENT are in the final section ("Fixes SHIPPED + re-sweep
> VALIDATED") — start there for the headline.
**Spec:** ../specs/2026-05-29-static-specialist-tuning-sweep.md
**Plan:** ../plans/2026-06-04-phase-3-4-jbinspect-ab-baseline.md
**Precedent (trivy, inconclusive → fix → EQUIVALENT; the temp-dir tail):** ./2026-06-03-trivy-haiku-low-result.md
**Precedent (eslint, inconclusive + agent-side tail + fix):** ./2026-06-02-eslint-haiku-low-reprobe-result.md
**Precedent (ruff, equivalent):** ./2026-06-02-ruff-haiku-low-result.md
**Baseline run dir:** `tests/ab/runs/20260604T092057Z-jbinspect-baseline/` (gitignored)
**Sweep run dir:** `tests/ab/runs/20260604T093631Z-jbinspect-haiku-low/` (gitignored)
**Sweep SHA:** `df035e9`

This is the **4th and final** static specialist in the Phase 3 tuning sweep
(after ruff, eslint, trivy).

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `jbinspect-reviewer`. Fixture: `jbinspect-smoke-bad-cs` (a real
  compilable C# project — `JbInspectSmoke.sln` + `.csproj` net10.0/nullable-off +
  `BadCode.cs` — with three deterministic InspectCode findings on changed lines
  2/11/14, all mapped `Important`). InspectCode 2026.1.0.1, dotnet SDK 10.0.300,
  `jb inspectcode <sln> --output=… --format=Xml --severity=WARNING`.
- Arms: Sonnet/default (`jbinspect-baseline.yaml`) and Haiku/low
  (`jbinspect-haiku-low.yaml`), n=20 each.
- Apparatus: `jb` is global-on-PATH (like trivy/ruff) — NO `setup:` provisioning
  block, so there is no install race. InspectCode restores + builds the project
  internally inside each hermetic per-trial copy (empirically verified: a clean
  no-`bin/obj` copy yields the identical finding set). The fixture is copied
  per-trial into a hermetic working dir.
- The worked example was live-captured and pinned in `jbinspect-reviewer.md`
  (`df035e9`) before this sweep — the capture-then-pin discipline that closed the
  zero-tuple parse gap (per the worked-example-gap memory). The first Sonnet
  capture emitted a prose-block layout (`**[Important]** \`file\` — msg` with bare
  `Rule:`/`Confidence:` lines and `---` separators) that parsed to `[]`; the
  pinned worked example moved the agent onto canonical §7 per-finding `### Finding`
  blocks, and the re-capture parsed cleanly to the three tuples.

## Canonical hash established at n=20

The Sonnet/default arm is a perfect **20/20** on canonical hash
`bbd92cd5f8de31536ed798b0f67536f8fcc57ada9eb5ef15017b0d91facd81c2` — the
3-tuple set:

```json
[{"file":"BadCode.cs","line":2,"rule_id":"RedundantUsingDirective","severity":"Important","confidence":100},
 {"file":"BadCode.cs","line":11,"rule_id":"PossibleNullReferenceException","severity":"Important","confidence":100},
 {"file":"BadCode.cs","line":14,"rule_id":"UnusedMember.Local","severity":"Important","confidence":100}]
```

Every Sonnet trial emitted `findings_count == 3`, the canonical hash,
`first_finding_rule == RedundantUsingDirective`, `exit_code 0`,
`inconclusive false`, `timed_out false`. The canonical hash matches the Task-5
gated re-capture hash exactly — confirmed at n=20, not carried from a single
trial.

The agent emits CamelCase `TypeId`s with a spaced `(Category)` token (e.g.
`UnusedMember.Local (Redundancies in Symbol Declarations)`), as the fixture,
worked example, and the shared tokeniser agree (token 1 = the bare `TypeId`; the
`.` is internal so it never splits the ID; the spaced category is discarded
cleanly).

## Hash distribution (canonical = `bbd92cd5…`, the 3-tuple set)

| Arm | canonical | skipped (INCONCLUSIVE) | NORMAL rate |
|---|---|---|---|
| **Sonnet/default** | **20 / 20** | 0 | **100 %** |
| **Haiku/low** | 18 / 20 | 2 (trials 004, 013) | **90 %** |

The Sonnet arm is perfectly deterministic at n=20. The Haiku arm reproduces the
canonical 3-tuple set on 18 of 20 trials; the two divergences (trials 004, 013)
are self-aborted skips — both correctly classified as INCONCLUSIVE by the broad
`^Skipped — ` sentinel (NOT laundered into a false 0-findings class).

## The 2 divergent Haiku trials — agent-side, NOT apparatus

Both arms received the byte-identical prompt, whose §4 contract requires
`$CLAUDE_TEMP_DIR` to be present. The harness passes the **literal, unexpanded**
string `$CLAUDE_TEMP_DIR` (the variable is not shell-expanded in the prompt);
Bash resolves it at command time. 18/20 Haiku trials ran InspectCode and parsed
correctly. The two exceptions fixated on the unexpanded token and self-aborted:

- **trial-004** (15s, the fast-abort signature):
  ```
  ## JetBrains InspectCode Findings

  Skipped — `CLAUDE_TEMP_DIR` not present in session environment. (See `includes/static-analysis-context.md` §4.)
  ```
- **trial-013** (21s):
  ```
  ## JetBrains InspectCode Findings

  Skipped — $CLAUDE_TEMP_DIR is not set in the shell environment. Cannot write inspection output to a temporary location.
  ```

This is the **exact temp-dir over-literalism failure mode** the handover and plan
predicted, and the same mechanism that produced trivy's trial-016 (`5ccb692`).
jbinspect is MORE prone to it than trivy/ruff/eslint because it actually writes
`inspectcode-<sln>.xml` to `$CLAUDE_TEMP_DIR` and parses it (the other specialists
can stream stdout) — so the literal unexpanded token is load-bearing in the
prompt, not incidental. This is a **recall-side skip, no fabrication** —
consistent with the recall direction seen across ruff/eslint/trivy (Haiku
misses/skips, never invents findings).

The defect is model-agnostic and under-specified: the agent body's `## Tool
invocation` section (the terse `Check $CLAUDE_TEMP_DIR is present` at line 43)
plus `static-analysis-context.md` §4 read as "is the *expanded path* present?"
rather than "is the *instruction* present?", so a model can wrongly conclude the
contract is violated and abort — even though the literal token is exactly what the
contract expects. Sonnet happened not to trip it; Haiku tripped it on 2/20.

Per the tuning-to-the-test guard, no fix is patched into this result: any fix must
be a general correctness improvement (helping Sonnet too) and earns its own
before/after re-sweep at n=20 on both arms (the eslint/trivy precedent).

## Cost delta

Per-trial cost columns captured in `summary.csv` from the stream `result`
envelope (`total_cost_usd`, `num_turns`, `usage.output_tokens`,
`usage.cache_read_input_tokens`).

| Arm | n | mean cost/trial* | mean turns | mean out tok | mean cache-read tok |
|---|---|---|---|---|---|
| Sonnet/default | 20 | **$0.10203** | 5.95 | 1,207 | 151,263 |
| Haiku/low (canonical 18) | 18 | **$0.06674** | 9.83 | 1,982 | 281,279 |
| Haiku/low (all 20, incl. 2 skips) | 20 | **$0.06396** | — | — | — |

**Cost ratio Sonnet ÷ Haiku = 1.53× (canonical-only) / 1.60× (all-20).**

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative of the **ratio**, not the actual Bedrock bill. The ratio is the
> reportable figure.

This ratio is **lower** than the three-specialist precedent (ruff ~2.2×, eslint
2.17×, trivy 2.34×). The reason is visible in the columns: the jbinspect Haiku arm
does materially *more work per trial* than Sonnet — mean turns 9.83 vs 5.95, mean
cache-read 281k vs 151k — because reading and parsing the InspectCode XML file
(rather than streaming tool stdout inline) is a heavier, more multi-turn task that
Haiku takes more steps to complete. The price-tier saving is real but partly eaten
by the extra turns × cached context jbinspect's read-the-XML workflow demands.
Still net-cheaper, just less so than the stdout-streaming specialists.

## Wall-clock

Sonnet mean 41s (range 38–45s); Haiku mean 52s on the 18 canonical trials
(range 40–67s), 15s/21s on the two fast-abort skips. jbinspect is slower than
trivy/ruff/eslint because InspectCode loads a solution and runs the .NET analyser.
Neither arm timed out; wall-clock does not affect finding sets.

## Verdict (framework verbatim)

- **EQUIVALENT** — Haiku matches the canonical hash within noise (clean,
  single-hash arm).
- **INCONCLUSIVE (decision-4)** — mixed within-arm hashes default to inconclusive
  regardless of rate.
- **WORSE** — >25 % NORMAL-rate drop.

**INCONCLUSIVE by decision-4 (mixed within-arm hashes).** The Haiku arm produced
mixed outcomes (18 canonical + 2 skip); per the parent spec's decision 4 (carried
from 3.1b/eslint/trivy), mixed within-arm results default the verdict to
inconclusive regardless of rate. The 10 % NORMAL-rate movement is well below the
25 % WORSE threshold, and both divergences are **genuine, characterised,
agent-side skips** — not apparatus artefacts (baseline 20/20, worked example
parses cleanly, prompt identical across arms, 18/20 succeeded, skips classified
correctly). The recall direction is unambiguous: **Haiku skips, never fabricates.**

This probe is **informational** — it does **not** flip `jbinspect-reviewer.md`'s
`model:` field, which remains `sonnet`.

## Production-flip recommendation

**Do NOT flip to Haiku/low on this result.** The flip gate is a clean
**EQUIVALENT** verdict; jbinspect returned INCONCLUSIVE.

The tail is plausibly closable by the same fix that closed trivy's trial-016: a
temp-dir-contract clarification stating that the literal unexpanded
`$CLAUDE_TEMP_DIR` token in the prompt is delivered as-is (Bash resolves it at
command time), that seeing the unexpanded token is **expected** and **does**
satisfy the §4 contract, and that the agent must not abort on seeing it. This is a
general correctness improvement (it helps any model on the real `/code-review`
pipeline, which passes the byte-identical literal token), so it passes the
asymmetry test.

**Sync coupling (jbinspect-specific):** unlike the worked-example pin (a new
section, no mirror needed), a temp-dir-contract clarification in the jbinspect
body's `## Tool invocation` section **touches the mirrored invocation procedure**,
so it MUST propagate to `agents/code-analysis.md`'s InspectCode section (lines
13-19, 71-98). Run `bash tests/run.sh` and watch for sync-note failures.

If the operator wants to pursue Haiku/low adoption for jbinspect, the next step
mirrors trivy's `5ccb692`: ship the fix (with its sync mirror), then re-sweep both
arms at n=20 as a fix-validation pass. Until then, jbinspect stays `model: sonnet`.

## Fixes SHIPPED + re-sweep VALIDATED 2026-06-04

Operator approved pursuing the Haiku/low adoption. Two distinct root causes
surfaced — neither was a model-quality deficiency — and each earned its own fix
and re-sweep, mirroring the trivy/eslint fix-validation discipline.

### Fix 1 — `--stdout` streaming (`aef3c4f`, `jbinspect-reviewer.md`)

The file-based invocation (`--output="$CLAUDE_TEMP_DIR/inspectcode-<sln>.xml"`
then read it back) was the source of the initial tail. Switched to
`jb inspectcode <sln> --stdout --format=Xml --severity=WARNING`, parsed inline.
Verified offline that `--stdout` emits pure XML on stdout (`<?xml>` … `</Report>`)
with build/progress logging on stderr (empty for the fixture). Also added the
temp-dir-contract clarification mirroring trivy `5ccb692` (the literal unexpanded
`$CLAUDE_TEMP_DIR` token satisfies §4; do not abort on it). General correctness +
efficiency improvement (helps Sonnet too — passes the tuning-to-the-test guard).
`code-analysis.md` delegates the invocation by reference (line 15), so it inherits
the change with no mirror edit needed.

**Re-sweep #1 (both arms n=20, SHA `aef3c4f`):** run dirs
`tests/ab/runs/20260604T104855Z-jbinspect-baseline/` and
`tests/ab/runs/20260604T110312Z-jbinspect-haiku-low/`.

| Arm | canonical | skip | NORMAL rate | mean turns | mean cost |
|---|---|---|---|---|---|
| **Sonnet/default** | **20/20** | 0 | 100 % | 4.25 (was 5.95) | $0.0861 |
| **Haiku/low** | 19/20 | 1 (trial 8) | 95 % | 5.89 (was 9.83) | $0.0468 |

The efficiency thesis confirmed: turns and wall-clock collapsed (Haiku 48s→34s),
cost ratio recovered 1.53× → **1.84×**. The up-front self-abort was gone — all 20
Haiku trials actually invoked InspectCode. But one skip (trial 8) remained, from a
**different** mechanism.

### Fix 2 — apparatus hook-leak (`830905b`, `tests/ab/run.sh`)

Trial 8 was NOT an agent-quality skip. It ran the correct command but with the
**absolute** trial path (`jb inspectcode /private/tmp/per-agent-…/trial-008/JbInspectSmoke.sln`).
The per-agent harness placed trial dirs at `${CLAUDE_TEMP_DIR:-/tmp}/per-agent-…`;
`CLAUDE_TEMP_DIR` is not exported into the harness shell, so it fell back to bare
`/tmp` → macOS `/private/tmp/per-agent-…`, **outside** the operator's hook-exempt
`/tmp/claude-*` namespace. That absolute path tripped the operator's global
`bash-guard.sh` temp-path policy (`TEMP DIRECTORY VIOLATION`) — and `jb` is not on
the hook's read-only allowlist. The 19 passing trials used a **relative** path
(`./JbInspectSmoke.sln`) which never contains `/tmp/`, so whether a trial was
denied depended on the model's path choice: a non-deterministic apparatus confound
that mis-scored as an agent-side skip. Same class as the Phase 3.2b install-race
confound (the rig leaking host state into the subagent).

Fixed by basing the fallback under `/tmp/claude-ab-<ts>` when `CLAUDE_TEMP_DIR` is
unset, so the trial dir (and any absolute path referencing it) stays inside the
hook exemption — the predicate is a `/tmp/claude-` substring match, so it holds
for `/private/tmp/claude-` too. Added a grep regression test asserting `run.sh`
never reintroduces the bare-`/tmp` per-agent fallback.

**Re-sweep #2 / validation (both arms n=20, SHA `830905b`):** run dirs
`tests/ab/runs/20260604T112947Z-jbinspect-baseline/` and
`tests/ab/runs/20260604T114635Z-jbinspect-haiku-low/`.

| Arm | canonical `bbd92cd5…` | skip | NORMAL rate | mean cost | mean turns | mean cache-read |
|---|---|---|---|---|---|---|
| **Sonnet/default** | **20/20** | 0 | 100 % | $0.07530 | 3.95 | 83,990 |
| **Haiku/low** | **20/20** | 0 | 100 % | $0.03980 | 4.60 | 107,842 |

The tail is **fully closed**: 19/20 → **20/20**, zero skips, both arms single-hash
with zero divergence. **Post-fix cost ratio Sonnet ÷ Haiku = 1.89×** (list-price
caveat as above; jbinspect's ratio sits below the other specialists' ~2.2-2.3×
because even after streaming, its read-and-parse-the-XML workflow costs Haiku
slightly more cache-read than the stdout-only specialists — but the saving is
real and stable).

### Verdict (upgraded): EQUIVALENT

On the validation re-sweep, Haiku/low matches the Sonnet/default baseline exactly
— 20/20 identical canonical hash on both arms, no within-arm non-determinism, no
skips, no fabrications. This clears the EQUIVALENT bar (clean single-hash arm,
zero movement against the 25 % guard). Both fixes are genuine correctness/apparatus
improvements, not fixture-chasing: Fix 1 helps any model on the real
`/code-review` pipeline, and Fix 2 corrects a rig confound that would have
mis-scored any specialist whose agent used an absolute path.

**Production flip: RECOMMENDED — operator-gated.** jbinspect now meets the
clean-EQUIVALENT flip gate. The flip is to set BOTH `model: haiku` AND
`effort: low` in `plugins/code-review-suite/agents/jbinspect-reviewer.md`
frontmatter (currently only `model: sonnet`, no `effort:` line — ADD it),
mirroring trivy `ee23a79` / eslint+ruff `3b3a255`. Operator-gated even on clean
EQUIVALENT — it changes a dispatched-agent definition. If wanted live mid-session:
`/plugins update` then `/reload-plugins` (the A/B harness reads the working-tree
file directly, so the sweep needs no reload — only the live pipeline does).

This **closes the Phase 3 static-specialist tuning sweep** — all four specialists
(ruff, eslint, trivy, jbinspect) now reach EQUIVALENT and carry (or are cleared
to carry) `model: haiku` + `effort: low`.

## Cross-references

- Parent spec: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Phase 3.3 trivy (closest precedent — same temp-dir tail, fix-then-EQUIVALENT
  arc): ./2026-06-03-trivy-haiku-low-result.md
- Phase 3.2b eslint re-probe (agent-side tail + skip sentinel):
  ./2026-06-02-eslint-haiku-low-reprobe-result.md
- Phase 3.1b ruff (equivalent precedent): ./2026-06-02-ruff-haiku-low-result.md
- Worked-example gap (why jbinspect's first capture parsed to zero — now closed):
  see memory `project_worked_example_gap.md`
