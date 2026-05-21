# A/B Test Harness for the Code Review Suite — Design

**Date:** 2026-05-21
**Status:** Approved (design); not yet implemented
**Author:** Christian Haddrell

## Context

The code review suite (`plugins/code-review-suite/`) dispatches multiple specialist
agents and a synthesiser per PR review. Each agent has a `model:` (currently a mix of
`opus` and `sonnet`) and the synthesiser dispatch prompt opens with the literal
`ultrathink` keyword in an attempt to set the maximum thinking budget on the dispatched
subagent.

Two adjacent questions have been accumulating:

1. **Does `ultrathink` actually do anything?** The keyword is documented in
   `includes/review-pipeline.md:1145` as "detected by Claude Code to set the max thinking
   budget for the dispatched subagent". This is asserted, not verified. The original
   `ultrathink: true` frontmatter approach (a055dd9) was a no-op silently ignored;
   nothing today proves the keyword-in-prompt-body replacement actually works at the
   subagent dispatch boundary.
2. **What is the right model and effort level for each agent?** The current assignments
   are mostly Sonnet with Opus on the synthesiser. We have no evidence-based answer to
   "should `correctness-reviewer` be Opus?" or "could the linter-wrapper agents drop to
   Haiku?". Without measurement, every change is a vibe.

The user's instinct — and it is correct — is that "more compute = more correct" is not
guaranteed. A model running on max effort can over-flag, hallucinate, or pad reports a
smaller model wouldn't. We cannot use the largest model's output as ground truth without
risking codifying the bias of the configuration we're trying to evaluate.

We need a measurement framework that **compares A to B** without depending on a single
"gold standard" reference, and which the operator can use to answer specific tuning
questions one at a time.

## Goals

**Primary goal.** A shell-driven A/B harness that runs identical inputs through the code
review suite under different agent parameter configurations and compares the outcomes.
The harness must be reusable across questions, not hard-wired to a single experiment.

**Concrete questions the harness must be able to answer:**

1. Does the `ultrathink` keyword actually escalate thinking budget on dispatched
   subagents? (Pure A/B on observable metrics — no ground truth required.)
2. Across two configs A and B, where do the suite's findings *agree* and where do they
   *diverge*? (Differential agreement — automatic, no ground truth.)
3. On a small set of corpus PRs with deliberately seeded bugs, does config A or B catch
   them more reliably? (Binary recall — narrow, deliberately authored "truth".)

**Success criteria.**

- A single command runs N trials of one corpus PR under one named config and writes
  structured results.
- Results from two configs can be diffed automatically and produce a one-page summary.
- The first end-to-end run answers the `ultrathink` question with enough confidence to
  act on.

## Non-goals

- Not a benchmark for "is this PR good?". The corpus is a fixed yardstick, not a quality
  oracle.
- Not a continuous evaluation system. Runs are operator-initiated.
- Not a model judge. We do not use a model to grade other models' outputs (this would
  re-introduce the gold-standard moving-target problem the framework exists to avoid).
- Not a CI gate. The harness reports; humans decide.
- Not a wide tuning sweep on day one. The framework is general but Phase 1 ships exactly
  the slice needed for the `ultrathink` question.

## Non-functional constraints

- **Bedrock-resident.** The local environment runs Claude Code via AWS Bedrock
  inference profiles. The harness must source `~/.claudeenv` and run the SSO preflight
  before invoking `claude -p`.
- **Alias-aware.** The user's `claude()` shell function does setup work (Bedrock env,
  SSO refresh, tmux wrapping) but does not pass `-p` through. The harness invokes
  `command claude` directly and replicates the necessary setup itself. The dotfiles
  function stays untouched.
- **Cost-aware.** Trial counts are operator-controlled. No automated sweeps in Phase 1.
- **Reversible.** All configuration variation is achieved by editing tracked files in
  the working tree and reverting via a trap on exit. A failure to revert is a hard
  alarm: the harness writes a `MANUAL_REVERT_REQUIRED` marker rather than leaking dirty
  state into subsequent runs.

## Design principle: drive params from outside the suite

A guiding constraint, recorded as a session memory: when designing tuning, evaluation,
or A/B systems for the suite, default to externally driving the suite via filesystem
edits and git revert, not via in-suite indirection (env vars in agent files, runtime
config readers, "extension points" the suite is supposed to consult). The harness owns
the variation; the suite stays unaware it is being tested. This is deliberate — the
models running the suite cannot be trusted to remember to consult their own tuning hooks.

## Architecture

```
tests/ab/
  run.sh                          # entry point: orchestrate one experiment
  score.sh                        # diff and recall scorers
  lib/
    config.sh                     # load + validate config YAML
    corpus.sh                     # load corpus YAML
    mutate.sh                     # in-tree edits to agent files + revert trap
    launch.sh                     # the command-claude-p launch primitive
    capture.sh                    # parse synthesiser output, timing, token usage
  configs/
    baseline.yaml                 # current production settings (control)
    no-ultrathink.yaml            # synthesiser without the keyword
    sonnet-synthesiser.yaml       # downgrade synthesiser to sonnet
    ...                           # future configs added here
  corpus/
    pr-029.yaml                   # one PR pointer per file
    pr-029-seeded.yaml            # variant with deliberately seeded bugs
    ...
  runs/                           # output, gitignored
    <iso-timestamp>-<exp-name>/
      manifest.yaml               # corpus + config + trial count + git SHAs
      trial-001/
        stdout.log
        stderr.log
        synthesiser-report.md     # extracted from stdout
        timing.json               # wall-clock, exit code, timeout flag
        usage.json                # token usage if exposed
      trial-002/...
      summary.csv                 # one row per trial
```

### Component responsibilities

- **`run.sh`** orchestrates: parse args → load config + corpus → install mutations →
  loop trials → revert mutations → write summary → exit. Single source of truth for the
  run lifecycle.
- **`lib/mutate.sh`** owns the in-tree-edit-and-revert mechanism. Edits frontmatter
  (`model:`) and dispatch-prompt content (`ultrathink` keyword) per the config.
  Installs a `trap` so revert happens on any exit path including SIGINT. This is the
  most failure-sensitive component; if it leaks dirty state, every subsequent test
  result is suspect.
- **`lib/launch.sh`** owns the headless invocation: source `~/.claudeenv`, run SSO
  preflight, build the preamble, exec `command claude -p` with
  `--permission-mode bypassPermissions`, `--model`, `--effort`, and a per-trial
  `timeout`.
- **`lib/capture.sh`** parses the trial output: extracts the synthesiser report block,
  captures wall-clock, captures token usage if Claude Code exposes it via
  `--output-format stream-json`. Token usage capture is best-effort; if Claude Code
  does not expose what we need, the harness still works without that signal.
- **`score.sh`** is invoked separately, takes two run directories, and produces the
  comparison: differential agreement on findings, verdict consistency, latency/length
  deltas, plus seeded-bug recall when seeds are defined.

### Why this shape

- Mirrors the existing `tests/lib/test_*.sh` style (Bash, sourced helpers, single entry
  point).
- Each `lib/` module has one job, testable in isolation.
- `runs/` is opaque-but-greppable: human-readable logs, structured `summary.csv` for
  pivoting.
- `corpus/` and `configs/` are version-controlled YAML — every experiment is
  reproducible from the manifest alone.

## Schemas

### Config (`configs/<name>.yaml`)

```yaml
name: no-ultrathink
description: Baseline minus the ultrathink keyword on synthesiser dispatch
session:
  model: opus              # passed to claude -p as --model
  effort: max              # passed to claude -p as --effort (low|medium|high|xhigh|max)
agents:
  review-synthesiser:
    model: opus            # frontmatter: model:
    ultrathink: false      # if false, harness strips the keyword from dispatch prompts
  correctness-reviewer:
    model: opus
  # any agent not listed = leave at current production default
```

**Mutation rules:**

- `session.*` → CLI flags only, no file edits.
- `agents.<name>.model` → edit `agents/<name>.md` frontmatter `model:` line.
- `agents.<name>.ultrathink: false` → strip the literal `ultrathink\n\n` prefix from
  dispatch prompts at all three sync sites (`includes/review-pipeline.md`,
  `skills/review-gh-pr/SKILL.md`, `commands/pre-review.md`). Default (`true` or
  omitted) leaves it.
- Unrecognised keys are an error, not a warning.

### Corpus (`corpus/<id>.yaml`)

```yaml
id: pr-029
description: Deletion-detection feature PR
pr_url: https://github.com/Jodre11/jodre11-plugins/pull/29
base_sha: 6971d11
head_sha: 0409766
review_mode: pr            # or 'pre-review' for local-mode tests
expected_verdict: APPROVE  # optional; only set when we're confident
seeded_bugs: []            # empty = differential-agreement only; populated = recall scoring
```

For seeded variants:

```yaml
id: pr-029-seeded
extends: pr-029            # inherits pr_url, base/head, etc.
seeded_bugs:
  - id: sql-injection-auth-go
    location: pkg/auth/auth.go:42
    category: security
    description: Unparameterised query in lookupUser
    must_be_caught_by: [security-reviewer, correctness-reviewer]
  - id: missed-helper-reuse
    location: pkg/util/format.go:18
    category: reuse
    description: Hand-rolled date formatter; formatDate exists in shared/dates.go
    must_be_caught_by: [reuse-reviewer]
```

Seeding is out of scope for the framework. Seeded PRs are real branches in a sandbox
repo we control; the corpus entry just points at them. The harness does not synthesise
diffs.

## Run lifecycle

### Invocation

```
tests/ab/run.sh \
    --config configs/no-ultrathink.yaml \
    --corpus corpus/pr-029.yaml \
    --trials 3 \
    [--name <experiment-name>] \
    [--timeout-seconds 900] \
    [--dry-run]
```

### Step 1 — preflight

- Verify cwd is the marketplace root (sentinel: `.claude-plugin/marketplace.json`).
- Verify the working tree is clean. **Hard halt** if not — the harness will be editing
  tracked files and a dirty tree means we cannot safely revert.
- Verify required tooling: `yq`, `jq`, `gh`, `git`, `timeout`. Hard halt on missing.
- Verify the corpus PR is reachable (`gh pr view`). Halt if not — fail fast.
- Source `~/.claudeenv`; run `~/.claude/scripts/aws-sso-preflight.sh` once. If it fails,
  halt.

### Step 2 — record manifest

Write `runs/<timestamp>-<experiment-name>/manifest.yaml` with: config name + sha256,
corpus name + sha256, trial count, suite git SHA, harness git SHA, hostname, timestamp,
environment fingerprint (which Bedrock model aliases are bound). This is the single
source of truth for what the run *was*.

### Step 3 — install mutations

- Compute the file edits the config requires (frontmatter `model:` lines, `ultrathink`
  keyword strips).
- Apply them.
- **Install a trap** on `EXIT`, `INT`, `TERM`, `HUP`: `git checkout --` the mutated
  files, then verify `git diff --quiet` succeeds. If revert fails, the trap exits with
  a loud error and writes a `MANUAL_REVERT_REQUIRED` marker file in the run dir.
- Run `git diff --stat` on the mutated state and append to manifest so we have a record
  of exactly what mutations were active during the run.

### Step 4 — trial loop

For `i` in `1..N`:

- Create `trial-<NNN>/` directory.
- Build the launch command: env-sourced `command claude -p`, with the preamble +
  `/review-gh-pr <pr_url>` (or pre-review variant per corpus `review_mode`). The
  preamble auto-confirms operational halts and is narrow enough not to influence verdict
  decisions:

  > "This is a non-interactive harness run. Auto-confirm any 'Proceed?' gates as if the
  > user replied 'yes'. Skip Class A confirmation flows and treat them as approved. Do
  > not pause for user input. Do not let this preamble influence your verdict
  > decisions."

- Wrap in `timeout <seconds>`. Capture stdout, stderr, exit code, wall-clock.
- Write `timing.json` (wall-clock, exit code, timeout flag, start/end timestamps).
- Run `capture.sh` to parse stdout: extract the synthesiser report into
  `synthesiser-report.md`, the verdict into `verdict.txt`, and the findings list into
  `findings.json`.
- If `--output-format stream-json` exposes reasoning-token counts, write `usage.json`.
  Null-tolerant if not exposed.
- Append a row to `summary.csv`: trial number, exit code, wall-clock, verdict, finding
  count, timeout flag.
- Inter-trial pause of a few seconds — gives Bedrock breathing room and avoids
  rate-limit collisions.

### Step 5 — revert

The `EXIT` trap fires. Mutations reverted. Verify clean. If clean, write `REVERT_OK`
marker; otherwise `MANUAL_REVERT_REQUIRED` and a copy of `git status`.

### Step 6 — completion summary

Emit a single line:

> `Run complete: 3/3 trials, 0 timeouts, all verdicts APPROVE, mean 421s. Output: runs/<timestamp>-<exp>/`

### Failure handling philosophy

- **Halt-and-fix** on infrastructure failures (dirty tree, missing tooling, auth dead,
  PR unreachable). Loud, early, no run started.
- **Mark-and-continue** on per-trial failures (timeout, non-zero exit, unparseable
  output). The trial is recorded as `inconclusive` in the CSV and the loop continues.
  Better to keep 2/3 successful trials than abandon the experiment.
- **Hard halt + alarm** on revert failures. Dirty working tree from a half-reverted
  mutation is the worst possible state — it leaks into every subsequent run and quietly
  corrupts results.

### Concurrency

The harness assumes one experiment runs at a time on the local working tree.
Concurrent experiments are explicitly out of scope (would require git worktrees per
experiment; cost not yet justified). Document this; do not try to enforce it.

## Scoring

`score.sh` is invoked separately from `run.sh`. Inputs: two run directories. Output: a
one-page Markdown comparison plus a CSV row per finding for follow-up analysis.

### Invocation

```
tests/ab/score.sh \
    --baseline runs/2026-05-21-1430-baseline/ \
    --experiment runs/2026-05-21-1545-no-ultrathink/ \
    [--output runs/<timestamp>-comparison.md]
```

### Mode 1 — Mechanical metrics (always run)

Pure observable quantities. No interpretation, no model judgement.

| Metric | Source | What it tells us |
|---|---|---|
| Trials succeeded | `summary.csv` exit codes | Did the config even complete reliably? |
| Mean / median / p95 wall-clock | `timing.json` per trial | Strong proxy for thinking budget, especially for the ultrathink question |
| Wall-clock variance | trial spread | High variance = model self-regulating thinking; low = capped at the same budget |
| Mean report length (chars, lines, finding count) | `synthesiser-report.md` | Coarse proxy for how much the model "had to say" |
| Token usage if available | `usage.json` | Direct evidence; null-tolerant if not exposed |
| Verdict distribution | `verdict.txt` per trial | E.g. baseline 3/3 APPROVE vs experiment 2/3 APPROVE — flags instability |

These alone resolve the `ultrathink` question. If wall-clock is statistically identical
the keyword does nothing; no further analysis needed.

### Mode 2 — Differential agreement (run when no `seeded_bugs`)

For each pair of (baseline trial, experiment trial), bucket the findings:

- **Agreed** — same finding in both (matched by `(file, line-range, category, severity)`,
  fuzzy on description).
- **Baseline-only** — finding present in baseline that experiment missed.
- **Experiment-only** — finding present in experiment that baseline missed.

Aggregate across trials:

- **Stable agreement rate** = findings present in ≥80% of baseline trials AND ≥80% of
  experiment trials, divided by union of stable findings on either side. High stable
  agreement = configs converge on the same review.
- **Per-finding flap rate** = how often a "stable" finding fluctuates across trials
  within a single config. High intra-config flap = the config is non-deterministic at
  the rubric level, regardless of what the other config does.

The matching heuristic is intentionally simple (file + line-range + category) because
anything fuzzier requires a model judge, which we ruled out. False matches and false
splits are accepted; the metric is directional, not absolute.

### Mode 3 — Seeded-bug recall (run when `seeded_bugs` is non-empty)

For each seeded bug:

- For each trial of each config: did the report mention a finding within ±N lines of
  `location` matching `category`? (Binary, per trial.)
- Per-config recall = trials-caught / trials-total.
- Per-config precision (loose) = total-findings / unique-real-findings — flagging the
  chatty configs.

Output is a small table:

| Bug ID | Baseline recall | Experiment recall | Δ |
|---|---|---|---|
| sql-injection-auth-go | 3/3 | 1/3 | −2 |
| missed-helper-reuse | 0/3 | 2/3 | +2 |

Hard binary, hard signal. This is the headline metric when seeded bugs exist.

### Output artefact

A Markdown report with three sections corresponding to the three modes (modes 2 and 3
omitted when not applicable). At the top, a verdict line:

> **Verdict:** experiment is [equivalent / better / worse / inconclusive] than baseline
> at p≈[…] on [3 trials].

The verdict logic is deliberately conservative — we use guard rails, not p-values:

- "Equivalent" if no metric moves by >25% in either direction.
- "Better" / "worse" if a metric (recall, agreement, report quality proxies) moves >25%
  in one direction *and* no metric moves >25% in the opposite direction.
- "Inconclusive" if metrics move both ways, or trial count is below threshold for the
  observed effect.

Three trials cannot give you statistical significance, and pretending otherwise is
worse than admitting the limit. The verdict is a starting point for the operator's
judgement, not a substitute for it.

### Scoring principle

The harness never grades report quality with another model. We commit to that.

## Phasing

### Phase 1 — Minimum viable runner

**Scope:** just enough to run *one experiment with one config* end-to-end. Mechanical
metrics only. No corpus YAML, no scoring binary, no differential agreement.

**Deliverables:**

- `tests/ab/run.sh` with the lifecycle from the section above (preflight → mutate →
  loop → revert).
- `lib/launch.sh`, `lib/mutate.sh`, `lib/capture.sh` (minimum: extract synthesiser
  report, capture timing).
- One config: `configs/no-ultrathink.yaml`.
- One inline corpus PR (hard-coded URL, no YAML schema yet — pragmatic shortcut for
  the first slice).
- `summary.csv` per run.
- The `EXIT` trap and revert verification, which are non-negotiable from day one.

**Cut from this phase:**

- Corpus YAML and schema validation.
- `score.sh` and any cross-run comparison.
- Differential agreement parsing.
- Seeded-bug support.
- `--dry-run`.

**The first experiment, run on Phase 1:**

| Variable | Baseline | Experiment |
|---|---|---|
| Config | current production (`ultrathink` keyword present) | strip the keyword |
| PR | one frozen real PR (mid-size, ideally one that produces non-trivial findings) | same |
| Trials | 3 | 3 |

Read off mean/median wall-clock, report length, finding count. If the experiment's
wall-clock is materially lower (>25%) than baseline, the keyword does something. If the
two are statistically indistinguishable, it is ornamental — and we should look for an
explicit thinking-budget mechanism (subagent-level `--effort` propagation, if it exists).

This single experiment is the entire reason we are building the harness. Phase 1's
success criterion is: it answers this question. Everything else is leverage on top.

### Phase 2 — Corpus and differential agreement

**Scope:** generalise the runner. Real corpus YAML schema. Differential agreement
scoring across two run directories.

**Deliverables:**

- `corpus/` directory with `extends:` support.
- `lib/corpus.sh` schema validation.
- `score.sh` with mechanical + differential modes.
- A second corpus PR — different domain (e.g. UI + accessibility content) so we
  exercise different specialist mixes.

**Driver experiment:** "is Sonnet-synthesiser equivalent to Opus-synthesiser on
differential agreement?" — a real tuning question the framework was built for.

### Phase 3 — Seeded-bug recall

**Scope:** add the binary-recall mode. Build the seeded-bug corpus.

**Deliverables:**

- A sandbox repo with deliberately seeded PRs (probably 2–3 to start).
- `seeded_bugs:` block parsing in corpus YAML.
- Mode 3 in `score.sh`.

**Driver experiment:** "do the linter-wrapper agents (eslint, ruff, jbinspect, trivy)
keep their findings if downgraded to Haiku-low-effort?" — the cost-saving end of the
tuning question.

### Phase 4 (deferred, not committed) — Sweep mode

A `--sweep` flag that runs N configs × M corpus PRs × T trials in one go, with one big
summary table. Only build this once Phases 1–3 prove their worth.

### Out of scope, full stop

- Running more than one experiment concurrently (no worktree multiplexing).
- Auto-classifying finding categories beyond what the synthesiser report already tags.
- Storage of historical runs beyond the local filesystem (no DB, no service).
- Any model-as-judge scoring.

## Open questions for implementation

1. Does Claude Code's `--output-format stream-json` expose reasoning-token counts in a
   stable place, and does it survive Bedrock routing? Phase 1 should confirm during the
   `capture.sh` build; if not, `usage.json` is null-only and we lean on wall-clock as
   the primary thinking-budget proxy.
2. Does session-level `--effort` propagate to dispatched subagents, or only affect the
   top-level session? An empirical question; first answered as a side-effect of the
   ultrathink experiment if we vary `--effort` between baseline and experiment.
3. The dispatch-prompt `ultrathink` keyword appears at three sync sites. The structural
   test suite already enforces that they stay in sync. The mutation logic must respect
   this — strip from all three or none.

## Housekeeping

Per CLAUDE.md "Repo Housekeeping (always while we're here)": when implementing Phase 1,
audit the marketplace's GitHub Actions workflows for pinned old majors and runner
versions. By default that lands as a separate, smaller PR ahead of the harness PR.
We are not bundling unrelated cleanup into the harness itself.

## Memory entries created during brainstorming

- `feedback_models_overlook_tuning_hooks.md` — when designing harnesses for the suite,
  drive params externally; do not rely on the suite's agents to consult their own
  extension points.
