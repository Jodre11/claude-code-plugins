# Panel-vs-classic orchestration A/B — design

**Date:** 2026-07-10
**Plugin:** `code-review-suite`
**Tracking:** GitHub issues **#63** (phase-efficacy analysis) and **#65** (synthesiser
model/effort validation) — this experiment closes both when it lands.
**Predecessors:** the panel-review cost-model go/no-go
(`docs/superpowers/specs/2026-07-08-panel-review-cost-model-design.md`, findings in
`docs/superpowers/analysis/2026-07-08-panel-review-cost-model-findings.md`); the panel
build (PR #88) and its durable-log follow-ups (PR #89); the per-cog instrumentation
design (`2026-06-19-phase-efficacy-instrumentation-design.md`).

## Context and motivation

The `review-gh-pr` pipeline now has two orchestration paths behind an opt-in flag
(`orchestration.review_mode`, default `classic`):

- **classic** — ~7–8 sonnet cross-reviewers + 1 opus + ultrathink synthesiser, plus a
  variance-resampling round 2 when the boundary gate fires.
- **panel** (opt-in, PR #88) — N identical opus panelists vote every finding + raise
  cross-cutting findings, followed by a cheap sonnet writer. Emits the same sealed
  `{verdict, bodyText, comments[]}` envelope, so `finalizeBundle` / Class-D / rubric are
  untouched.

The cost model already predicted (from data on disk, zero new review tokens) that **both
`panel-3` and `panel-5` SURVIVE** the kill filter: cheaper on USD and faster on wall-clock
than classic across the full resample × depth × cache bracket, `fragile_arms` empty. But
the cost model is explicit that it **filters, it does not "go"** — quality and simplicity
outrank tokens in the ranked success bar and are not cost-observable. Its findings doc lists
the residual risks the A/B must close: real synth depth under live traffic, whether
cache-warm assumptions hold at scale, the actual resample rate `p`, and above all **whether
panel holds review quality**.

This spec is that A/B. It runs classic and panel on the **same real PRs**, measures the
mechanical differential (verdict agreement, finding-set delta, cost, wall-clock), and settles
the one thing no mechanical metric can — the quality *sign* of any divergence — via a
**blind human head-to-head ranking** by the maintainer. Model-as-judge is a permanent design
ban for this harness; the human ranking is the only quality adjudicator.

## Goal

Produce the evidence and the decision to answer: **is the panel path good enough to flip the
default from `classic` to `panel`?**

The deliverable is an analysis, not a pipeline change. It touches no agent and no workflow.
It produces:

1. A mechanical differential across both arms on a real-PR corpus.
2. A blind, pre-registered maintainer ranking of the two arms' reports.
3. A flip / don't-flip recommendation against an on-record decision rule.

The flip itself (changing `review_mode`'s default) is a **separate follow-up** the maintainer
authorises after seeing the analysis — not part of this spec.

## Non-goals (scope fence)

- **No pipeline or behaviour change.** The panel path (PR #88/#89) is complete; this spec
  only *measures* it. Zero edits to `workflows/review-core.mjs`.
- **No model-as-judge, anywhere.** Permanent ban for the A/B harness. Quality sign comes only
  from the maintainer's blind ranking.
- **No default flip in this spec.** Spec #3 produces the recommendation; flipping the default
  is a later, separately-authorised change.
- **No new replayable corpus fixtures** under `tests/ab/corpus/`. Orchestration mode runs
  against live merged PRs; the durable JSONL log is the artefact, not a frozen fixture.
- **No new orchestration-level review runs beyond the corpus.** The experiment consumes only
  the runs it dispatches for the corpus; it does not add background traffic.

## The quality-adjudication problem and the decision rule

The model-as-judge ban means the mechanical metrics can prove panel *diverges* from classic
(verdict agreement %, finding-set delta) but **cannot prove the divergence is an
improvement**. The quality sign is settled by a blind maintainer ranking (see "Blind
ranking"), with the mechanical differential reported alongside to keep the ranking honest.

**Decision rule (pre-registered — flip default to panel iff ALL hold):**

1. **Blind ranking:** panel wins-or-ties **≥ ⅔** of the PRs where the two reports *materially
   differ*. PRs whose two reports are near-identical (a tie carrying no signal) are excluded
   from the denominator.
2. **No quality regression:** zero PRs where panel drops a classic **CONSENSUS-tier or
   confidence ≥ 80** finding *and* the maintainer's blind ranking did not independently prefer
   panel on that PR.
3. **Cost non-worse:** the measured cost/wall-clock confirms the cost model's SURVIVE — panel
   is no worse than classic on at least one of USD / wall-clock and not dominated on the other.

The ⅔ bar is deliberately conservative: panel must clearly win the contested PRs, not merely
break even. The maintainer may override the threshold, but **the override is logged against
this pre-registered value** — that is the "keep me honest" contract. Two divergences the
analysis must surface, never bury:

- **Contradiction flag** — any PR where the ranking preferred the arm that the finding-delta
  shows dropped a consensus / high-confidence finding.
- **Noise-dominated flag** — any PR where within-arm variance ≥ cross-arm difference (the arms
  differ by less than each differs from itself → that PR cannot discriminate).

## Harness approach — extend `tests/ab/`

The A/B extends the existing harness with a new **`--mode orchestration`**, alongside
`end-to-end` and `per-agent`. Rationale:

**Reused as-is (decisive for extend over a fresh rig):**

- `lib/launch.sh` — the `claude -p` launch primitive under `timeout`, env preflight
  (`~/.claudeenv` + `aws-sso-preflight.sh`), `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0`, and
  `--stream-json` capture. **This code is scarred by the Phase 3.1a–3.4 apparatus-confound
  history** (empty-stdout recovery, env-scrub downgrade, temp-path bash-guard). A fresh rig
  re-inherits every one of those bugs. This is the load-bearing reason to extend.
- `lib/cost_model.py` — already parses `stream.jsonl` usage and prices turns at Bedrock
  rates. The A/B feeds it *measured* tokens instead of parameterised estimates, closing the
  cost model's residual risk.
- Run-dir layout, manifest writers, completion summary, and preflight (marketplace-root,
  clean-tree, required-tools).

**Genuinely new (does not fit the existing modes):**

- **Arm toggle is config, not tracked-file mutation.** `lib/mutate.sh` edits tracked files
  (ultrathink keyword, agent frontmatter). Panel is toggled by `orchestration.review_mode` in
  a `code-review.toml` layer — orthogonal. The orchestration mode writes a temp TOML instead
  (see "Arm toggle" below); the `mutate.sh` revert trap is not the mechanism.
- **Primary artefact is the durable JSONL log, not the stdout verdict regex.** `lib/capture.sh`
  scrapes the orchestrator's freeform verdict via a permissive regex — lossy, and it never
  sees per-cog findings. The orchestration A/B instead harvests the durable log
  (`$HOME/.claude/code-review-suite/logs/<slug>/<ident>-<sha>.jsonl`) as the structured source
  of truth, with the stdout verdict as a cross-check.
- **The differential + blind-ranking tooling** is wholly new.

A third `case` arm in `run.sh`'s dispatcher plus two new libs (`lib/orchestration.sh`,
`lib/differential.py`) and the ranking tooling; the existing modes are untouched.

## No-GitHub-spam safety (free, already in the code)

Running `/review-gh-pr` end-to-end normally posts to GitHub. A multi-PR × N-run corpus must
not spam real PRs. **The corpus is merged PRs**, and `review-gh-pr/SKILL.md` §B.1 already
refuses to submit a review to a `CLOSED` or `MERGED` PR — it renders the report to stdout and
halts cleanly. So every corpus run auto-halts at the posting step with the report on stdout:
no GitHub writes, no `--dry-run` flag needed. This is the natural no-post path and it is
already enforced by the skill. The harness relies on it rather than adding a new suppression
mechanism; the plan must confirm the §B.1 halt fires under `claude -p` (the harness preamble
auto-confirms operational gates but must not push past the merged-PR refusal).

## Arm toggle — temp `code-review.toml`

`orchestration.review_mode` / `panel_size` / `full_log` resolve from two layers, first match
wins (identical to `full_log` resolution): (1) the reviewed repo's `.claude/code-review.toml`,
then (2) the user-level `~/.claude/code-review.toml`.

**Approach: write a temporary user-level `~/.claude/code-review.toml`** carrying
`[orchestration]` with `review_mode = "<arm>"`, `panel_size = <n>`, and `full_log = true`,
back up any pre-existing file, and restore it on every exit path via a trap (same discipline
as `mutate.sh`'s revert trap; a failed restore writes a `MANUAL_REVERT_REQUIRED` marker).

User-level is preferred over repo-level because it **never dirties the reviewed corpus repo's
working tree** — the corpus repos are real project clones, and a stray `.claude/code-review.toml`
there is both a revert hazard and a potential accidental commit. The plan must confirm the
reviewed repo does not already set `orchestration.*` at the repo layer (which would win over
the user-level temp); if it does, that PR is disqualified from the corpus or the repo-level key
is neutralised for the run with its own backup/restore. `full_log = true` is forced on for the
whole experiment so the durable log accrues — this is the data source.

## What the differential measures

Both arms are stochastic. Every metric is a **distribution across the N runs/arm/PR**, never a
single observation; computed per-PR, then aggregated.

1. **Verdict agreement.**
   - **Within-arm stability** — does each arm agree with itself across its N runs? This is the
     per-PR noise floor. A cross-arm disagreement only counts as a real arm-difference when it
     exceeds within-arm noise.
   - **Cross-arm agreement** — modal-verdict match plus the full N×N agreement rate.

2. **Finding-set delta.** From the durable log's per-finding
   `{tier, domain, file, line, severity, confidence, verdict_relevant}`. Findings are matched
   across arms by **`(file, line-proximity, domain)`** — **never by description text**
   (model-authored, unstable). Per PR:
   - **Retention** — of classic's CONSENSUS-tier and confidence ≥ 80 findings, how many appear
     in panel? Drops here are the regression signal (rule 2).
   - **Additions** — findings panel raised that classic did not, with their tier / confidence.
   - **Tier movement** — findings both arms caught, at different confidence / tier.

3. **Cost.** Harvested `stream.jsonl` → `cost_model.py`: USD and token split
   (input / output / cache) per arm. Replaces the cost model's *parameterised* estimates with
   *measured* values.

4. **Wall-clock.** From `timing.json` per run; distribution per arm. Retunes the four
   `wall_clock` params the cost model currently proxies (`cross_secs`,
   `opus_per_1k_output_divisor`, `writer_stage1_duration_multiple`,
   `stage1_wall_duration_multiple`).

## Blind ranking — mechanics

The reports carry arm tells: panel prose (deterministic sonnet writer) reads differently from
classic (opus synth), and the durable log names `orchestration_mode` outright. If the maintainer
can identify the arm, the ranking is worthless. The packet generator therefore:

- **Presents `bodyText` only** — the report prose a reviewee would see — never the JSONL meta.
- **Normalises arm tells** — strips / neutralises panel-vs-classic structural giveaways in the
  rendered report. The plan must nail these down against **real sample output**, not guessed
  (the same "empirically ground against a live trace" lesson as the per-agent parsers).
- **Randomises A/B assignment per PR** — the arm→label(A/B) mapping is drawn per PR from a
  recorded seed and sealed; the maintainer never sees which is which until after ranking.
- **Collapses N runs to one representative per arm** via the **modal-verdict run** (the run
  whose verdict matches the arm's majority verdict; first if several). Chosen over the medoid
  (which can surface a minority-verdict report — misleading for a verdict-driven decision) and
  over ranking all N (2× manual effort, re-introduces run-vs-run noise).

**Pre-registration (the honesty anchor).** *Before* seeing any report, the maintainer writes
down what "better review" means to them (e.g. "catches real bugs > low false-positive rate >
concise prose"). The tool stores this criteria file **timestamped ahead of unblinding**. The
per-PR ranking reasons are later checked against it; a divergence between stated criteria and
actual rankings is flagged.

**Workflow, per contested PR:** (1) reports A and B shown side by side, unlabelled; (2)
maintainer records A-better / B-better / tie plus a one-line reason; (3) only after all PRs are
ranked does the tool **unblind**, joining rankings to arm labels and the mechanical
differential, then applying the decision rule.

## Phased execution

**Phase A — pilot (2–3 PRs × 3 runs/arm, ≈ $60–110).** Purpose: measure the within-arm noise
floor and shake down the whole pipeline (harness, arm toggle, durable-log harvest, blinding,
ranking) end-to-end before committing full-sweep spend. Three exit checks:

1. **Variance floor** — is within-arm verdict/finding variance low enough that cross-arm
   differences are detectable? (Numeric; auto-checkable.)
2. **Blinding held** — can the maintainer identify the arm from the normalised report?
   (Judgement.)
3. **Harvest complete** — does the durable-log harvest capture every field the differential
   needs? (Judgement.)

**Pilot gate — auto-proceed on a clean pass, else hard-stop.** The three checks are encoded as
gates; a clean pass of all three auto-sizes the Phase B corpus and proceeds. Because checks 2
and 3 are judgement calls that do not reduce to a clean threshold, in practice only an
unambiguous low-variance + trivially-complete pilot auto-proceeds — anything borderline routes
to a hard stop for maintainer review. **The gate logs which path it took and why**, so an
auto-proceed is auditable after the fact. Phase B corpus size N is derived from the pilot's
observed variance (higher noise → more runs/arm).

**Phase B — full sweep (corpus + N sized from Phase A).** Hand-picked merged PRs spanning
small / median / large diff and a mix of known APPROVE / REQUEST_CHANGES outcomes. Run both
arms, harvest, differential, blind-rank, apply the decision rule → flip / don't-flip
recommendation, closing #63 and #65.

## Components (each independently testable)

| Unit | Responsibility | Depends on |
|---|---|---|
| `run.sh` `--mode orchestration` dispatcher | Parse `--corpus` / `--arms` / `--trials` / `--phase pilot\|full`; loop PRs × arms × trials | existing preflight, `launch.sh` |
| `lib/orchestration.sh` | Arm toggle (temp user-level `code-review.toml`: `review_mode`, `panel_size`, `full_log=true`; backup + restore trap) + durable-log harvest (locate + copy `<ident>-<sha>.jsonl` into the trial dir) | `full_log` writer, SKILL §B.1 |
| `lib/differential.py` | Verdict agreement (within / cross-arm), finding-set delta (match by file/line/domain; retention / additions / tier-move), noise-dominated + contradiction flags | harvested JSONL, `cost_model.py` |
| `lib/ranking_packet.py` | Blinded side-by-side packets: modal-verdict rep run, `bodyText`-only, arm-tell normalisation, sealed per-PR A/B randomisation, pre-registration capture | harvested JSONL |
| `lib/ranking_unblind.py` | Join recorded rankings to arm labels + differential; apply the decision rule; flag ranking-vs-criteria divergence | ranking output, `differential.py` |
| `cost_model.py` (reused) | Price harvested `stream.jsonl` at Bedrock rates; retune `wall_clock` params from measured latencies | unchanged |

## Testing

Shell suite (`tests/run.sh`) + Python (`tests/python/`):

- **`differential.py`** — synthetic JSONL pairs: verdict-agreement math; finding-matching
  including the "same bug, ±N lines" proximity case and the "must not match on description"
  guarantee; retention / regression detection; both honesty flags (contradiction,
  noise-dominated).
- **`ranking_packet.py`** — blinding invariants: no `orchestration_mode` (or other arm tell)
  leaks into a packet; A/B assignment is deterministic-given-seed but arm-hidden; the
  pre-registration criteria file is timestamped before any unblind is possible.
- **`orchestration.sh`** — arm-toggle TOML write/restore round-trip (temp fixture; assert clean
  state after, including the `MANUAL_REVERT_REQUIRED` marker path); harvest locates the correct
  log by slug / ident / sha.
- **Not automated:** the live pilot / sweep runs (organic — real Bedrock, real merged PRs) and
  the human ranking (by definition).

## Deliverables

1. Harness extension: `--mode orchestration`, `lib/orchestration.sh`, `lib/differential.py`,
   `lib/ranking_packet.py`, `lib/ranking_unblind.py`, with tests.
2. Phase A pilot findings (variance floor + harness/blinding validation) → the pilot gate.
3. Phase B differential analysis + blind rankings + the flip / don't-flip recommendation,
   closing GitHub #63 and #65.

## Housekeeping

Per the standing repo rule, the plan runs the freshness / dependency / GitHub-Actions / runner
check during planning and proposes any stale-dependency work as a **separate small PR landing
first**, kept out of this feature PR.

## Open questions deferred to planning

- **Exact arm-tell normalisation rules** — must be derived against real sample `bodyText` from
  both arms, not guessed. First planning action: capture one classic and one panel report and
  diff their structure.
- **Where the pre-registration criteria file and rankings live** — under the run dir
  (`tests/ab/runs/<ts>-orchestration-<phase>/`) vs a dedicated `rankings/` tree. Leaning run-dir
  for provenance co-location.
- **Corpus PR selection specifics** — the concrete merged-PR list (which repos, which SHAs)
  spanning the diff-size and verdict-outcome mix, chosen at Phase A / Phase B start.
