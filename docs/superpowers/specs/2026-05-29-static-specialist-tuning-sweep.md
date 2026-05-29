# Static-analysis specialist tuning — directional sweep

**Date:** 2026-05-29
**Status:** Approved (design); not yet implemented
**Author:** Christian Haddrell
**Builds on:** Phase 2 of the per-agent A/B harness
([`2026-05-22-per-agent-harness-phase-2-design.md`](2026-05-22-per-agent-harness-phase-2-design.md)),
which shipped the harness chassis (Phase 2a + 2b) but deferred its first headline
experiment (Phase 2c).
**Supersedes:** Phase 2c framing in
[`2026-05-22-per-agent-harness-phase-2-design.md`](2026-05-22-per-agent-harness-phase-2-design.md)
§Phasing.

## Context

Phase 2 of the per-agent A/B harness shipped the chassis: a `--mode per-agent`
runner, a faithful prompt reconstruction, a deterministic findings parser, a
decay-warner, and a 3-trial faithfulness check empirically passing on the
synthetic ruff smoke fixture. The harness is reusable across all specialists —
static, reasoning, cross-review, and the synthesiser — and is intended to be
used iteratively to tune each.

Phase 2c (the originally-planned ruff-only headline experiment: haiku-low vs
sonnet-default against a real-PR ruff fixture) was deferred at the Phase 2b
operator review gate. Two reasons:

1. The marketplace's commit history contains exactly one Python-touching commit,
   and it is the smoke fixture itself (`tests/fixtures/static-analysis/ruff/`).
   No real-PR ruff fixture is available locally.
2. A bespoke ruff-only experiment is the wrong unit of investment. Static-
   analysis specialists are *transmission* tasks (run tool → parse output →
   map prefixes to severity → emit markdown). The directional answer for
   ruff-reviewer almost certainly transfers to the other three static
   specialists. Investing the same ~150k tokens to answer the question for
   *all four* static specialists at once is strictly more useful.

This spec captures the Phase 3 methodology that supersedes the deferred Phase 2c.

## The fixture-sourcing problem and why static specialists escape it

For *reasoning* specialists (correctness-reviewer, security-reviewer,
archaeology-reviewer, etc.), the harness has a deeper epistemic problem: the
same model authoring the fixture is the same model judging the agent's output
against it. If the model has a blind spot, the fixture inherits it. The agent
passes; the test was wrong. Confirmation circle by construction.

For *static-analysis* specialists, this problem is partially escapable. The
ground truth is not the harness author's judgement — it is the tool's
deterministic output. `ruff check --output-format=json` produces an exact set
of findings for a given file, and the agent's job is to faithfully transmit
those findings as canonical §7 markdown. The specialist is not making a
judgement; it is doing structured translation.

Consequence: a hand-authored synthetic Python file can serve as a credible
fixture for ruff-reviewer, because the ground truth for "what findings should
the specialist emit?" is determined by running `ruff check` on the file, not
by the human's intuition. The same logic applies to `eslint`, `trivy config`,
and JetBrains InspectCode for their respective specialists.

This spec assumes the static-specialist scope only. The reasoning-specialist
fixture-sourcing problem is genuinely hard and is deferred to a future spec
when a reasoning-specialist phase becomes the next priority.

## Goals

**Primary goal.** Answer the cost-tuning question for all four static-analysis
specialists in one deliberate sweep:

> For each of `ruff-reviewer`, `eslint-reviewer`, `trivy-reviewer`, and
> `jbinspect-reviewer`: is the agent at Haiku-low equivalent to the current
> Sonnet-default baseline on finding sets?

**Concrete questions Phase 3 must answer (one per specialist):**

1. Does Haiku-low produce a findings hash byte-equal to the Sonnet-default
   baseline across N trials?
2. If divergent, in which direction — does Haiku miss findings (recall loss)
   or invent findings (false positives)?

**Success criteria.**

- Each specialist has a smoke fixture, a captured Sonnet-default baseline,
  and a Haiku-low directional probe result.
- A single one-page report per specialist: equivalent | better | worse |
  inconclusive, with cost delta and recall delta numbers attached.
- A consolidated decision for production: which specialists adopt Haiku-low,
  which stay at Sonnet-default, which need richer-fixture follow-up.

## Non-goals

- Not a reasoning-specialist phase. The four static specialists are excluded
  from cross-review and are isolated transmission tasks; reasoning specialists
  have a fundamentally different cost-tuning posture and need their own spec.
- Not a synthesiser phase. Synthesiser cost-tuning is the prerequisite for the
  rubric-row-2 investigation and lives at the end of the programme, not here.
- Not a fixture-source decision for reasoning specialists. That gets its own
  spec when a reasoning-specialist phase approaches.
- Not a CI gate.
- Not an absolute-ground-truth recall check against an external benchmark
  (e.g. SWE-bench). The directional probe answers a relative question
  (Haiku-low vs Sonnet-default on the same fixture), not an absolute one.

## Methodology — directional probe per specialist

### Step 1 — Smoke fixture

For each specialist, author a small in-tree fixture exercising 3-5 distinct
findings under that specialist's tool. The findings should be deterministic
(running the tool produces the exact same set of findings every time) and
diverse enough to exercise the parser's full tuple shape.

Examples:

- **ruff**: a Python file with `F401 unused import` + `E501 line too long` +
  `B008 mutable default arg` + `S105 hardcoded password`. (For ruff this can
  reuse the existing `tests/fixtures/static-analysis/ruff/` directory if a
  richer fixture is later authored, or stay with the existing single-finding
  smoke fixture if the directional probe on one finding is decisive.)
- **eslint**: a JS or TS file with `no-unused-vars` + `prefer-const` +
  `no-var` + `eqeqeq`.
- **trivy**: a Dockerfile with a known-vulnerable base image + a missing
  `USER` directive + a hardcoded secret pattern, plus a Terraform file with a
  permissive S3 bucket policy.
- **jbinspect**: a small C# file with `UnusedMember.Local` +
  `RedundantUsingDirective` + a possible-NullReferenceException.

The key constraint: the fixture's ground truth is what the *tool* produces,
not what the human thinks the tool *should* produce. After authoring the
fixture, run the tool independently, capture its JSON output, and use that
JSON as the source of truth.

### Step 2 — Sonnet baseline capture (~10k tokens per specialist)

Run one trial of `<specialist>-reviewer` against its smoke fixture under
`sonnet/default`. Hand-review the captured `agent-output.md` against the
canonical `static-analysis-context.md §7` format AND against the tool's
independent JSON output. The agent's findings must:

1. Conform to the §7 markdown shape.
2. Cover every finding in the tool's JSON (no missed findings).
3. Add no findings the tool didn't surface (no fabrications).

If conditions hold, promote `agent-output.md` to
`tests/ab/corpus/<specialist>-smoke-<slug>/expected/findings-<specialist>.md`.
Update `source.yaml.captured_under.suite_sha` and `captured_at`.

If the Sonnet baseline already misses or fabricates findings, the SPECIALIST
itself has a defect — fix that before continuing the sweep. (Unlikely; the
specialists are well-tested. But the directional probe assumes the Sonnet
baseline is itself correct.)

### Step 3 — 3-trial faithfulness check at Sonnet-default (~30k tokens per specialist)

Same flow as Phase 2b for ruff. Three trials at sonnet/default with
`--faithfulness-check`. All three must produce a findings hash byte-identical
to the captured baseline. Confirms within-arm determinism for the baseline.

If a trial diverges from the baseline at sonnet/default, the SPECIALIST is
non-deterministic at sonnet — note this and abort the sweep for this
specialist. (Static specialists *should* be deterministic by design; if not,
that's its own investigation.)

### Step 4 — 3-trial directional probe at Haiku-low (~30k tokens per specialist)

Author a `<specialist>-haiku-low.yaml` config (one line different from the
baseline config: `model: haiku`, `effort: low`). Run three trials with
`--faithfulness-check` against the captured baseline.

Expected outcomes:

- **3/3 hash-match**: Haiku-low transmits faithfully on this fixture.
  Adoption candidate. Move to Step 5.
- **0/3 hash-match**: Haiku-low fundamentally fails for this specialist on
  even simple cases. Probe is decisive: do not adopt. Stay at Sonnet-default.
- **1-2/3 hash-match**: Haiku-low is non-deterministic. Inconclusive. Probe
  the failure mode (which finding fields drift?) and treat as a "no" by
  default — non-determinism in a transmission task is itself a defect.

### Step 5 — One-page comparison report per specialist

Write a one-page report at
`docs/superpowers/notes/2026-XX-XX-<specialist>-haiku-low-result.md`
capturing:

- The fixture used (path + brief description).
- Sonnet-default baseline hash + 3-trial faithfulness result.
- Haiku-low 3-trial faithfulness result.
- Wall-clock per trial per arm (cost delta number).
- Verdict (equivalent | better | worse | inconclusive) with the spec's
  conservative guard rails (>25% movement threshold for non-equivalent
  outcomes).
- Adoption recommendation with confidence level.

### Step 6 — Optional richer-fixture follow-up (only on probe failures)

If Step 4 returned anything other than 3/3, that specialist warrants the
richer-fixture investment to characterise WHAT is failing — not because the
overall directional answer is in doubt, but because understanding the failure
mode informs whether haiku-low can ever be adopted with caveats (e.g. "ok for
.py but not .ipynb"; "ok for severity Important but not Critical"; "ok for
single-finding cases but not multi-finding").

This step is gated and probably not exercised at all if the directional logic
holds. Estimated cost if needed: ~50-100k tokens per specialist.

## Cost expectations

Best case (haiku-low works for all four specialists):

| Per specialist | Tokens | Wall-clock |
|---|---|---|
| Smoke fixture authoring | 0 (offline) | ~30 min |
| Sonnet baseline capture | ~10k | ~30s |
| 3-trial faithfulness at sonnet | ~30k | ~90s |
| 3-trial directional probe at haiku-low | ~30k | ~90s |
| One-page report | 0 (offline) | ~15 min |
| **Total per specialist** | **~70k** | **~45 min** |
| **Total Phase 3 (4 specialists)** | **~280k** | **~3 hours** |

Worst case (any specialist fails the probe and triggers Step 6 richer-fixture
follow-up): add ~50-100k tokens per failing specialist. Worst-case ceiling
~700k tokens; realistic ceiling ~400k.

These numbers are still 1-2 orders of magnitude cheaper than a single Phase 1
end-to-end comparison (~5M tokens for one Phase 1 verdict).

## Sequencing within Phase 3

Specialists in cost order (cheapest tool / smallest fixture first):

1. **ruff-reviewer** first. The existing `tests/ab/corpus/ruff-smoke-bad-py/`
   smoke fixture and Phase 2b's captured baseline are reusable. Step 4 alone
   (~30k tokens) closes the ruff probe. If the answer is decisive, no further
   ruff investment.
2. **eslint-reviewer** next. Author a minimal JS fixture; same flow as ruff.
3. **trivy-reviewer** third. Slightly more involved fixture authoring (Dockerfile
   + Terraform) but still cheap.
4. **jbinspect-reviewer** last. Requires `dotnet` + InspectCode tooling on
   the host. If not installed, defer until tooling is in place.

A quick cross-specialist consistency observation: if ruff-reviewer's Haiku-low
probe passes 3/3, the same answer is *very* likely for the other three. If
ruff fails, the others probably fail too. Run ruff first, use the result to
decide whether to continue the sweep at full scope or pause and investigate.

## Per-specialist parser additions

Each new specialist needs an `agent_capture_parse_<specialist>_trial`
function in `tests/ab/lib/agent_capture.sh`, modelled on the post-Task-8
ruff parser. Differences are namespace-only:

- **eslint**: rule IDs are kebab-case (`no-unused-vars`); category is the
  plugin name (`@typescript-eslint`, `react-hooks`).
- **trivy**: rule IDs are CVE IDs (`CVE-2024-NNNNN`) for vulnerabilities and
  AVD-style IDs (`AVD-DS-NNNN`) for misconfigs. Two distinct namespaces; the
  parser must handle both.
- **jbinspect**: rule IDs are CamelCase (`UnusedMember.Local`).

Each parser handles roughly the same canonical §7 bullet shape; only the
field-content extraction differs. ~30 lines of awk per specialist, plus
~30 lines of test fixture per specialist.

## Verifications during implementation

- The agent's actual output format under each specialist's prompt may differ
  slightly from the canonical §7 form (the way ruff-reviewer's actual output
  drifted from `### Finding — title` to `**Finding N**` in Phase 2). Each
  specialist's parser must be empirically grounded against a live agent
  trace — this is the load-bearing lesson from Phase 2 and the dominant
  failure mode for plan-style specifications. Do not transcribe a parser from
  the spec into code without first running a sonnet/default trial and reading
  the actual `agent-output.md`.
- The CLI flag spellings used by the harness (`--append-system-prompt-file`
  etc.) are confirmed for sonnet and haiku as of Phase 2; assume the same for
  Phase 3 unless something breaks.

## Cross-references

- Phase 2 design (chassis): [`2026-05-22-per-agent-harness-phase-2-design.md`](2026-05-22-per-agent-harness-phase-2-design.md)
- Phase 2 plan (with deferral note for the originally-planned Phase 2c):
  [`../plans/2026-05-28-per-agent-harness-phase-2-plan.md`](../plans/2026-05-28-per-agent-harness-phase-2-plan.md)
- Static-analysis specialist policy:
  [`2026-05-13-static-analysis-severity-confidence-policy-design.md`](2026-05-13-static-analysis-severity-confidence-policy-design.md)
- Per-agent testing direction (the framing this whole programme inherits):
  [`2026-05-21-per-agent-testing-direction.md`](2026-05-21-per-agent-testing-direction.md)
- Future scope marker — reasoning-specialist fixture sourcing: not yet
  written; will need its own spec before any reasoning-specialist phase
  starts. The model-can't-grade-itself problem and contamination concerns on
  public benchmarks are the central design questions there; this spec
  deliberately does not solve them.
