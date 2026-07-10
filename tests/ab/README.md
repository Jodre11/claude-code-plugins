# A/B test harness for the code review suite

Phase 1 — minimum viable runner. See
[`docs/superpowers/specs/2026-05-21-ab-test-harness-design.md`](../../docs/superpowers/specs/2026-05-21-ab-test-harness-design.md)
for the full design.

## What it does

Runs N trials of one hard-coded corpus PR (currently
`Jodre11/claude-code-plugins#29`) through the code review suite under one
named config. Captures wall-clock, exit code, the orchestrator's top-level
summary, the verdict, and a coarse finding count per trial. Writes
everything to `tests/ab/runs/<timestamp>-<config-name>/`.

All variation is achieved by editing tracked agent and dispatch-prompt
files in the working tree. An `EXIT`/`INT`/`TERM`/`HUP` trap reverts every
mutation on every exit path. A failed revert writes `MANUAL_REVERT_REQUIRED`
into the run directory rather than continuing silently.

## What it does not do (Phase 1)

- No corpus YAML — the PR URL is hard-coded.
- No `score.sh` — comparison between two run directories is by hand.
- No seeded-bug recall.
- No `--dry-run`.
- No model-as-judge scoring (this is a permanent design constraint, not a
  Phase 1 cut — see the spec).

## Capture under `claude -p`

The synthesiser is a subagent; its `# Code Review Report` block does NOT
reach the parent stdout under `claude -p`. Only the orchestrator's
top-level freeform summary makes it through. The harness extracts the
verdict from that summary using a permissive regex (matches `[Vv]erdict`
followed within ~50 chars by `APPROVE | REQUEST_CHANGES`, optionally
wrapped in markdown emphasis). Both observed shapes are pinned by
fixtures:

- Class B.1 halt summary: `**Verdict (advisory only):** REQUEST_CHANGES`
- Freeform paragraph: `Advisory verdict: **APPROVE** (Rubric row 4).`

If a future Claude Code release makes subagent stdout propagate, the
synthesiser-raw regex (`^Verdict: (APPROVE|REQUEST_CHANGES)$`) is still
the first-pass pattern.

## Usage

```
tests/ab/run.sh --config <path> --trials <n> [--name <experiment-name>] [--timeout-seconds <n>]
```

Example — control arm of the `ultrathink` experiment:

```
tests/ab/run.sh --config tests/ab/configs/baseline.yaml --trials 3
```

Example — experiment arm:

```
tests/ab/run.sh --config tests/ab/configs/no-ultrathink.yaml --trials 3
```

## Preconditions

- Working tree clean (`git status --short` empty). The harness refuses to
  start otherwise — mutating an already-dirty tree makes revert unsafe.
- Tools on PATH: `yq` (Mike Farah Go variant), `jq`, `gh`, `git`, and
  either `timeout` (Linux) or `gtimeout` (macOS via Homebrew `coreutils`).
- AWS SSO token valid for the Bedrock account. The harness sources
  `~/.claudeenv` and runs `~/.claude/scripts/aws-sso-preflight.sh` itself —
  the dotfiles `claude()` shell function is bypassed because it does not
  pass `-p` through.
- The harness sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` for the trial
  subprocess only, so the explicit `--permission-mode bypassPermissions`
  flag is honoured. Without that override, the env-scrub hardening default
  silently downgrades to default permission mode.

## Output layout

```
tests/ab/runs/<timestamp>-<config-name>/
  manifest.yaml          # config + corpus + suite SHA + mutation summary
  summary.csv            # one row per trial
  REVERT_OK              # marker file written when revert succeeded
                         # (absent when no mutations were applied — e.g.
                         # baseline runs)
  trial-001/
    stdout.log
    stderr.log
    synthesiser-report.md   # orchestrator's freeform summary in -p mode
    verdict.txt
    timing.json
    report-stats.json
  trial-002/
  ...
```

Crashed trials write a sentinel row (`wall=-1`, `verdict=CAPTURE_FAILED`,
`findings=-1`, `chars=-1`) so the loop continues and the run still produces
a complete `summary.csv`.

## Configs

A config is a YAML file under `tests/ab/configs/`. Schema:

```yaml
name: <required>
description: <optional>
session:
  model: <opus|sonnet|haiku|...>     # passed as --model
  effort: <low|medium|high|xhigh|max> # passed as --effort
agents:
  <agent-name>:
    model: <opus|sonnet|haiku>       # rewrites frontmatter model:
    ultrathink: <true|false>         # only meaningful on review-synthesiser;
                                     # false strips the keyword from all 3 sync sites
```

Unrecognised top-level, session, or per-agent keys are a hard error — typos
must not silently fall back to production defaults.

## Per-agent mode (Phase 2)

Per-agent mode dispatches a single agent against a fixed corpus fixture
under a varied (model, effort) configuration. Two orders of magnitude
cheaper per data point than end-to-end mode.

Phase 2 is scoped to `ruff-reviewer` only. Phase 2 ships the harness
chassis with ruff-reviewer as the worked example; the per-specialist
cost-tuning sweep is captured in
[`docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`](../../docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md)
and executed in Phase 3.

### Usage

```
tests/ab/run.sh --config <path> --corpus <fixture-id> --trials <n> \
    [--name <experiment-name>] [--timeout-seconds <n>] \
    [--faithfulness-check]
```

Example — control arm:

```
tests/ab/run.sh --config tests/ab/configs/per-agent/ruff-baseline.yaml \
    --corpus ruff-smoke-bad-py --trials 3
```

Example — faithfulness check (validates within-arm determinism; used in
Phase 2b to confirm harness correctness, not to answer the tuning
question):

```
tests/ab/run.sh --config tests/ab/configs/per-agent/ruff-baseline.yaml \
    --corpus ruff-smoke-bad-py --trials 3 --faithfulness-check
```

### Output layout (per-agent mode)

```
tests/ab/runs/<timestamp>-<config-name>/
  manifest.yaml          # mode: per-agent, fixture metadata, decay_warnings
  summary.csv            # per-trial: exit, wall, findings_count, hash, ...
  trial-001/
    stdout.log
    stderr.log
    agent-output.md      # the ## Ruff Findings block
    findings.json        # sorted, normalised tuples
    findings_hash.txt    # sha256 of findings.json contents
    timing.json
    system-prompt.md     # the reconstructed agent body for this trial
    user-message.txt     # the reconstructed orchestrator-equivalent prompt
    faithfulness.diff    # only present when --faithfulness-check ran and diverged
```

### Fixture corpus

Fixtures live under `tests/ab/corpus/<id>/` and are gated by
`tests/ab/corpus/index.yaml` — no glob discovery. A fixture has:

- `source.yaml` — provenance and working-directory strategy.
- `diff/changed-lines.txt` — the orchestrator's `$CHANGED_LINES_BLOCK`.
- `diff/full-diff.patch` (worktree / patch strategy only).
- `expected/findings-ruff.md` — the captured agent output verbatim.
- `expected/findings.json` — the normalised tuple form of the above.

### Fixture refresh workflow

When the decay-warner reports a depends_on path has changed (e.g.
`ruff-reviewer.md` was edited):

1. Re-run the per-agent harness against the fixture under sonnet/default
   for one trial.
2. Hand-review the new `agent-output.md` for output-contract conformance.
3. Copy the new artefacts into `corpus/<id>/expected/`.
4. Update `source.yaml.captured_at` and `source.yaml.captured_under.suite_sha`
   to the current values.
5. Re-run with `--faithfulness-check --trials 3` to validate.

A generalised refresh subcommand is deferred — the workflow is rare and
manual review is load-bearing.

## Orchestration mode (panel-vs-classic A/B)

> **WARNING — arm-tell rules are ILLUSTRATIVE PLACEHOLDERS.**
> `tests/ab/lib/arm_tells.json` holds the regex rules that blind the ranking packets by
> normalising arm-tell phrases (words or headings that reveal whether a report came from
> the classic or panel arm). The rules shipped in this file are FORMAT EXAMPLES ONLY —
> they were not derived from real harness output. Running Phase-A ranking against these
> placeholders can let genuine arm tells survive into the packets, silently leaking arm
> identity into the human blind-ranking signal.
>
> **Before the first real Phase-A ranking, the operator MUST regenerate `arm_tells.json`
> from a live capture:**
> 1. Run the harness once per arm against a single merged PR (1 trial each) — see plan
>    Task 6 Step 1 and the Phase execution steps below.
> 2. Diff the two `durable-log.md` bodies: `diff <run-dir>/<pr-slug>/classic/trial-001/durable-log.md <run-dir>/<pr-slug>/panel/trial-001/durable-log.md`
> 3. Identify structural arm tells (panel-specific section headings, literal
>    "panel"/"panelist"/"consensus vote" wording, differing verdict-advisory phrasing).
> 4. Replace `arm_tells.json` wholesale with the confirmed tells before calling
>    `ranking_packet.py`.

Orchestration mode runs the **full** `/review-gh-pr` orchestrator against a
corpus of merged PRs, comparing the `classic` and `panel` review arms. Unlike
end-to-end mode, no tracked files are mutated: the arm is selected by a
**temporary user-level `~/.claude/code-review.toml`** `[orchestration]` block,
backed up and restored on every exit path (a failed restore writes
`MANUAL_REVERT_REQUIRED` into the run dir). Model and effort are the production
session defaults — the only difference between arms is the TOML toggle, so both
run exactly as a real review would.

### Usage

```
tests/ab/run.sh --mode orchestration --corpus <corpus.yaml> \
    --arms "classic panel:5" --trials <n> --phase <pilot|full> \
    [--panel-size <n>] [--timeout-seconds <n>]
```

Example — pilot phase, 2 trials per arm:

```
tests/ab/run.sh --mode orchestration \
    --corpus tests/ab/corpus/panel-ab-pilot/corpus.yaml \
    --arms "classic panel:5" --trials 2 --phase pilot
```

### Arm-spec syntax

`--arms` is a space-separated list of arm specs. Each is either `classic` or
`panel[:<size>]`:

- `classic` — classic single-reviewer orchestration.
- `panel` — panel review at the default panel size (`--panel-size`, default 3).
- `panel:5` — panel review with an explicit panel size of 5 (overrides
  `--panel-size` for that arm).

### corpus.yaml schema

Recorded at phase start (copied verbatim into the run dir):

```yaml
phase: pilot          # pilot | full
prs:
  - url: https://github.com/Jodre11/claude-code-plugins/pull/88
    head_sha: a757f69000000000000000000000000000000000  # 40-hex, pinned
    stratum: "large-diff/request-changes/hard"           # selection stratum label
```

Each corpus PR **must be MERGED** (preflight hard-fails otherwise) so the
§B.1 no-post safety guarantee holds. The operator must also confirm, when
selecting each SHA, that the PR's repo sets no repo-level `[orchestration]`
key — a repo-level override would win over the harness's user-level temp toggle
(recorded as a warning, not enforced).

### The TOML toggle

For each arm the harness writes `~/.claude/code-review.toml`:

```toml
[orchestration]
review_mode = "panel"   # or "classic"
panel_size  = 5
full_log    = true      # forced on — the durable log is the data source
```

Any pre-existing `code-review.toml` is backed up to `*.ab-backup` and restored
byte-for-byte after the arm's trials complete.

### Output layout (orchestration mode)

```
tests/ab/runs/<timestamp>-orchestration-<phase>/
  corpus.yaml                          # verbatim copy of the input corpus
  <owner>-<repo>-pr-<N>/               # one per corpus PR
    classic/
      trial-001/
        stdout.log                     # reconstructed from stream.jsonl
        stderr.log
        stream.jsonl                   # --output-format stream-json trace
        timing.json
        verdict.txt                    # APPROVE | REQUEST_CHANGES | INCONCLUSIVE
        durable-log.jsonl              # harvested orchestration durable log
        durable-log.md                 # harvested durable-log markdown (if present)
        HARVEST_MISS                    # sentinel when the durable log was absent
      trial-002/
      ...
    panel/
      trial-001/
      ...
```

### Per-agent configs

Schema:

```yaml
name: <required>
description: <optional>
mode: per-agent
agent: <agent name, e.g. ruff-reviewer>
session:
  model: <opus|sonnet|haiku>
  effort: <low|default|high|max>
```

The `agents:` map (from end-to-end mode) MUST NOT declare any per-agent
`model:` overrides — per-agent mode varies model via `session.model` only
and never edits tracked files. Other `agents:` entries are silently
no-op'd in per-agent mode (a known footgun deferred to Phase 3+ to
tighten).

### Implementation notes

- **Empirically ground parsers**: the per-specialist findings parser must
  be developed against a live agent trace, not a hypothetical format. The
  Phase 2 plan's original parser was authored against a fictional plain
  `Field: value` format; the canonical contract at
  `static-analysis-context.md §7` uses bold-markdown bullets. The first
  live trial revealed the divergence; the parser was corrected at Task 8
  closeout. Phase 3 specialists should expect to do a sonnet/default
  capture trial first and inspect `agent-output.md` before writing the
  parser.
- **CLI flag spellings under-documented**: `--append-system-prompt-file`
  is recognised by the CLI but only documented as a substring inside
  `--bare`'s description (`--append-system-prompt[-file]`). Confirm flag
  spellings via empirical probe (`command claude --append-system-prompt-file
  /tmp/nonexistent` produces a clear error confirming the flag is parsed).
- **`effort: default` is a sentinel, not a valid CLI value**: the harness
  omits the `--effort` flag when the config value is `default` or empty,
  leaving the CLI's built-in default in place. Phase 3 configs that want
  explicit effort levels should use `low | medium | high | xhigh | max`.
