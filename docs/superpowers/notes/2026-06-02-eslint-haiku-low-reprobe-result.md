# Phase 3.2b PR B — eslint-reviewer Haiku/low clean re-probe result

**Date:** 2026-06-03
**Status:** inconclusive (decision-4) — residual tail is agent-side, not apparatus
**Supersedes the framing in:** [Phase 3.2 result](./2026-06-02-eslint-haiku-low-result.md)
**Spec:** ../specs/2026-06-02-phase-3-2b-eslint-apparatus-and-reprobe-design.md
**Plan:** ../plans/2026-06-03-phase-3-2b-pr-b-reprobe.md
**Precedent (ruff, equivalent):** ./2026-06-02-ruff-haiku-low-result.md
**Apparatus baseline (3.1c):** ./2026-06-02-phase-3-1c-validation-sweep.md
**Baseline run dir:** `tests/ab/runs/20260603T112923Z-eslint-baseline/` (gitignored)
**Sweep run dir:** `tests/ab/runs/20260603T114412Z-eslint-haiku-low/` (gitignored)
**Sweep SHA:** `db0ad43` (baseline re-establishment); cost plumbing `2d1b31b`/`bc7621f`

## What changed since Phase 3.2

PR A (commits `7cb0ee6`…`fe321af`) fixed BOTH apparatus confounds that
contaminated the 3.2 result:

1. **Install race** — per-trial hermetic working dirs `cp -R`'d from a
   `npm ci`-provisioned template (no shared mutable dir, no order-dependent
   race).
2. **Terminal-`.result` capture drop** — `launch_jq_reduce_stream_jsonl` now
   reconstructs stdout from ALL assistant text blocks, not the terminal
   `.result` (which dropped reports when the agent did post-report temp-file
   cleanup).

PR B (this note) then re-established a **symmetric n=20 Sonnet/default
baseline** on the fixed harness (the 3.2 n=3 baseline and its hash are
discarded) and swept both arms at n=20, capturing per-trial **cost** for the
first time.

## Sweep configuration

- Codepath: per-agent harness, `--stream-json`.
- Specialist: `eslint-reviewer`. Fixture: `eslint-smoke-bad-js` (4-rule set on a
  single JS file: `no-var`, `prefer-const`, `no-unused-vars`, `eqeqeq` on
  `bad.js` lines 1/2/3/6).
- Arms: Sonnet/default (re-captured) and Haiku/low (config unchanged), n=20 each.
- Apparatus proof: exactly ONE `npm ci` (`added 69 packages`) per sweep into the
  template; **zero** per-trial `npm install` across all 40 trials.

## Baseline re-established (B1, n=1 capture + n=20 determinism)

Sonnet/default, hand-verified against `eslint --format=json` run independently
on a provisioned copy of the fixture: exactly four errors — `no-var` (L1),
`prefer-const` (L2), `no-unused-vars` (L3), `eqeqeq` (L6) — matching the
captured report exactly, no fabrications, §7-conformant. The captured trial
resolved the tool on **tier 1** (`./node_modules/.bin/eslint --format=json`)
with no install/`npx` improvisation. Promoted to
`expected/findings-eslint.md`, `baseline_revision: 2`,
`suite_sha: 055d3fd`. Findings tuples are unchanged from revision 1 (only the
line-1 suggested-fix prose differs), so the derived `findings.json` and the
canonical hash `8d62c08e…1148` are unchanged.

## Hash distribution (canonical = `8d62c08e…1148`, the 4-tuple set)

| Arm | canonical | zero-findings (`37517e5f…`) | skipped | NORMAL rate |
|---|---|---|---|---|
| **Sonnet/default** | **20 / 20** | 0 | 0 | **100 %** |
| **Haiku/low** | 17 / 20 | 2 (trials 003, 017) | 1 (trial 011) | **85 %** |

The Sonnet arm is now perfectly deterministic at n=20 (vs the wide n=3 CI in
3.2). The Haiku arm reproduces the **same 17/20 (85 %) NORMAL rate as 3.2** —
but now on a clean apparatus, which is the load-bearing finding (below).

## The 3 divergent Haiku trials — all agent-side, NOT apparatus

This is the key reframe. In 3.2 the tail was entangled with the install race +
capture drop. On the fixed apparatus the `node_modules` template was present and
identical for all 20 trials (proven: one `npm ci`, zero per-trial installs), so
**every divergence here is a model behaviour, not a harness artefact.** All
three failures share one mechanism: **Haiku did not use the documented tier-1
`./node_modules/.bin/eslint` path.**

| Trial | hash | INCONCLUSIVE? | What Haiku ran | Why it diverged |
|---|---|---|---|---|
| 003 | `37517e5f…` (0 findings) | no | bare `eslint`; `find . -name eslint -type f`; `which eslint` | PATH miss; `find -type f` excludes the `.bin/eslint` **symlink** → emitted a skip line |
| 017 | `37517e5f…` (0 findings) | no | `which eslint`; `eslint --version` | PATH miss; never probed `node_modules` → emitted a skip line |
| 011 | `skipped` | **yes** | bare `eslint`; `which biome eslint`; `find . -name eslint` | PATH miss → emitted a skip line |

All three are **recall-side skips, no fabrications** — consistent with 3.2's
recall-direction finding. Contrast the 17 passing trials and the Sonnet
baseline, which ran `./node_modules/.bin/eslint` directly.

### Two distinct, model-agnostic defects surfaced (PR C candidates)

1. **Tier-1 binary-resolution drift (agent body).** `eslint-reviewer.md`'s
   resolution ladder makes tier 1 `<project-root>/node_modules/.bin/eslint`
   (lines 34–39), but the **Tool-invocation example** (line 46) shows a bare
   `eslint --format=json …`. Haiku/low sometimes follows the example literally —
   runs bare `eslint`, misses PATH, and skips — instead of walking the ladder.
   This is an under-specification in the body (the example and the ladder are in
   tension), not a Haiku-only defect: it could bite any model, so the fix is
   model-agnostic (make the example resolve the binary per the ladder, or have
   the ladder emit the concrete tier-1 invocation).

2. **Parser skip-sentinel is too narrow (harness).** The eslint parser matches
   only `^Skipped — eslint/biome not available` (`agent_capture.sh:26`).
   - Trial 011 said `Skipped — eslint/biome not available …` → matched →
     correctly flagged INCONCLUSIVE (hash `skipped`).
   - Trials 003 & 017 said `Skipped — eslint not available …` (no `/biome`) →
     did **not** match → mis-classified as a genuine **0-findings** result
     (hash `37517e5f…`), NOT a skip. This silently understates the skip rate and
     pollutes the zero-findings class. The sentinel should tolerate the
     `/biome`-optional phrasing (e.g. `^Skipped — (eslint|biome|eslint/biome)`).

## Cost delta (B3 — the programme's actual deliverable)

Per-trial cost columns now captured in `summary.csv` from the stream `result`
envelope (`total_cost_usd`, `num_turns`, `usage.output_tokens`,
`usage.cache_read_input_tokens`).

| Arm | n | mean cost/trial* | mean turns | mean out tok | mean cache-read tok |
|---|---|---|---|---|---|
| Sonnet/default | 20 | **$0.13994** | 9.05 | 1,611 | 246,k |
| Haiku/low | 20 | **$0.05682** | 8.95 | 1,680 | 228,k |

**Cost ratio Sonnet ÷ Haiku = 2.46×.**

> **\* List-price caveat (load-bearing).** The CC stream's `total_cost_usd` is
> computed at **Anthropic list prices, not Bedrock**. Treat the absolute dollars
> as indicative of the **ratio**, not the actual Bedrock bill. The 2.46× ratio
> is the reportable figure; it closely matches the ~2.4× measured from the 3.2
> existing-run extraction, so the price-tier saving is stable and confirmed.

Observations consistent with the spec's earlier finding: cost is dominated by
turns × cached context, not output tokens (Haiku's mean output is actually
*higher* than Sonnet's, yet it costs 2.46× less — the lever is the price tier,
not verbosity). Within Haiku, the cheap skip trials (011/017, 6–7 turns,
$0.038–0.042) and the expensive trial-016 (17 turns, 571k cache-read, $0.097)
span a ~2.6× intra-arm swing on turn count.

## Verdict (B4 framework, verbatim)

**INCONCLUSIVE by decision-4 (mixed within-arm hashes).** The Haiku arm
produced mixed hashes (17 canonical + 2 zero-findings + 1 skipped); per the
parent spec's decision 4 (carried from 3.1b), mixed within-arm hashes default
the verdict to inconclusive regardless of rate.

Crucially, the 3.2 verdict was inconclusive for **two** reasons (asymmetric n=3
baseline AND within-arm non-determinism). PR B **eliminates the first**: the
Sonnet baseline is now a clean 20/20 at n=20, so the asymmetry is gone. What
remains is a **genuine, reproducible, agent-side Haiku tail** (15 % NORMAL-rate
movement, below the 25 % WORSE threshold), no longer maskable as apparatus. The
recall direction is unambiguous: **Haiku misses/skips, never fabricates.**

This probe is **informational** — it does **not** flip `eslint-reviewer.md`'s
`model:` field, which remains `sonnet`.

## PR C gate

A real agent-side tail survived the clean apparatus, so the PR C trigger
condition (spec §"PR C — conditional hardening") **is met** — but PR C is
**operator-gated and not authored here**. Two important corrections to the
spec's PR C assumption:

- The spec named the §7 structured-output drop (the 3.2 trial-015 mode) as the
  PR C candidate. **That mode did not recur** in this clean re-probe — all three
  3.2b divergences are the **tier-1 binary-resolution skip**, a different
  mechanism. The §7-drop was plausibly itself an apparatus/capture artefact.
- The intervention is therefore **not** a §7 self-consistency instruction. It is
  (a) the model-agnostic tier-1 resolution fix in the agent body, and
  (b) the parser skip-sentinel widening in the harness. Both help Sonnet too
  (correctness fixes, not Haiku nudges) and so pass the spec's asymmetry test.

Per the tuning-to-the-test guard, these are **characterised, not fixed**. The
numbers above go to the operator; no body or config edit is made until PR C is
approved, and any edit earns its own before/after re-measurement at n=20 on both
arms.

## PR C — SHIPPED + VALIDATED 2026-06-03

Operator approved PR C and the switch to Haiku/low. Both fixes shipped:

- **PR C-1** (`36e304b`, `eslint-reviewer.md`): the binary-resolution ladder now
  names the resolved absolute path `<bin>` and the Tool-invocation section uses
  `<bin>` instead of bare `eslint`/`biome`, explicitly forbidding the bare name,
  fixing the `find -type f` symlink trap, and requiring the skip line verbatim.
- **PR C-2** (`56844cd`, `agent_capture.sh`): the eslint skip sentinel widened to
  `^Skipped — (eslint/biome|eslint|biome) not available` with a TDD fixture.

**Validation sweep (Haiku/low n=20, post-fix, fix-validation NOT a verdict A/B):**
run dir `tests/ab/runs/20260603T121608Z-eslint-haiku-low/`.

- **20/20 canonical hash `8d62c08e…1148`** (was 17/20). The tail is fully closed.
- **Zero skips.** Every trial resolved the tier-1 `node_modules/.bin/eslint` path
  — the exact mechanism PR C-1 targeted, confirmed by the command traces.
- Post-fix cost ratio Sonnet ÷ Haiku = **2.17×** (was 2.46× pre-fix; the fix adds
  ~1.5 turns/trial doing proper resolution — 10.5 vs 8.95 — so the ratio narrows
  slightly but the saving is large and real). List-price caveat as above.

This is a genuine correctness fix, not fixture-chasing: PR C-1 helps any model
(the resolved-path invocation is unambiguously more correct), and it closed the
observed mechanism rather than being tuned to the hash.

**The production `model:` flip is decided in principle but NOT executed this
session — deliberately held.** The A/B validated `model: haiku` + `effort: low`,
but the production agent frontmatter
(`plugins/code-review-suite/agents/*-reviewer.md`) carries only a `model:` field;
there is **no `effort:` field** in that schema (effort is set per-trial by the
A/B harness session, not by the agent definition). So flipping `model: haiku`
alone would NOT reproduce the validated `haiku`/`low` config — the effort
dimension is unexpressed. ruff (3.1b EQUIVALENT) is likewise still `model:
sonnet`, so there is no existing flip precedent to copy. **Open question for the
next session:** determine how production expresses (or inherits) effort for these
agents, then flip eslint AND ruff together to the correct, validated config. Do
not flip `model:` until this is resolved. See the trivy-phase handover.

## Cross-references

- Parent spec: ../specs/2026-05-29-static-specialist-tuning-sweep.md
- Phase 3.2 result (superseded framing): ./2026-06-02-eslint-haiku-low-result.md
- Phase 3.1b (ruff, equivalent precedent): ./2026-06-02-ruff-haiku-low-result.md
- Phase 3.1c validation: ./2026-06-02-phase-3-1c-validation-sweep.md
