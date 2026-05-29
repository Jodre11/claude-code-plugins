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
