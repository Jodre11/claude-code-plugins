# A/B test harness for the code review suite

See
[`docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md`](../../docs/superpowers/specs/2026-05-22-per-agent-harness-phase-2-design.md)
for the design.

## What it does

Dispatches a single review agent against a fixed corpus fixture under a
named (model, effort) configuration, N times. Captures wall-clock, exit
code, token and cost figures, and — for the static-analysis specialists —
a normalised findings set and its hash per trial. Writes everything to
`tests/ab/runs/<timestamp>-<config-name>/` (gitignored).

The harness never edits tracked files: the agent body is read from
`plugins/code-review-suite/agents/<agent>.md` and passed as an appended
system prompt, and each trial runs in a fresh copy of the materialised
fixture.

Two entry points:

- `tests/ab/run.sh` — one config, one fixture, N trials.
- `tests/ab/run-specialist-ablation.sh` — a two-arm ablation of one
  reviewer file (see [Specialist ablation](#specialist-ablation)).

No model-as-judge scoring — this is a permanent design constraint.

## Preconditions

- Tools on PATH: `yq` (Mike Farah Go variant), `jq`, `git`, and either
  `timeout` (Linux) or `gtimeout` (macOS via Homebrew `coreutils`).
- AWS SSO token valid for the Bedrock account. The harness sources
  `~/.claudeenv` and runs `~/.claude/scripts/aws-sso-preflight.sh` itself —
  the dotfiles `claude()` shell function is bypassed because it does not
  pass `-p` through.
- The harness sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0` for the trial
  subprocess only, so the explicit `--permission-mode bypassPermissions`
  flag is honoured. Without that override, the env-scrub hardening default
  silently downgrades to default permission mode.

## Usage

```
tests/ab/run.sh --config <path> --corpus <fixture-id> --trials <n> \
    [--name <experiment-name>] [--timeout-seconds <n>] \
    [--faithfulness-check] [--stream-json]
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

`--stream-json` captures the `--output-format stream-json` trace per trial
and reconstructs `stdout.log` from its assistant text blocks; the token and
cost columns of `summary.csv` are populated only in this mode.

## Output layout

```
tests/ab/runs/<timestamp>-<config-name>/
  manifest.yaml          # mode: per-agent, fixture metadata, decay_warnings
  summary.csv            # per-trial: exit, wall, findings_count, hash, cost, ...
  trial-001/
    stdout.log
    stderr.log
    stream.jsonl         # only with --stream-json
    agent-output.md      # the ## <Tool> Findings block (static specialists)
    findings.json        # sorted, normalised tuples ([] for judgement specialists)
    findings_hash.txt    # sha256 of findings.json contents
    timing.json
    system-prompt.md     # the reconstructed agent body for this trial
    user-message.txt     # the reconstructed orchestrator-equivalent prompt
    faithfulness.diff    # only present when --faithfulness-check ran and diverged
```

Judgement specialists (correctness, reuse, style and the like) emit no
`rule_id`, so the static parser is skipped for them; score their
`stdout.log` post-hoc with `tests/ab/lib/specialist_score.sh`.

## Configs

A config is a YAML file under `tests/ab/configs/per-agent/`. Schema:

```yaml
name: <required>
description: <optional>
mode: per-agent                       # the only mode; may be omitted
agent: <agent name, e.g. ruff-reviewer>
session:
  model: <opus|sonnet|haiku>          # passed as --model
  effort: <low|default|high|max>      # passed as --effort
```

Unrecognised top-level or session keys are a hard error — typos must not
silently fall back to production defaults.

## Fixture corpus

Fixtures live under `tests/ab/corpus/<id>/` and are gated by
`tests/ab/corpus/index.yaml` — no glob discovery. A fixture has:

- `source.yaml` — provenance and working-directory strategy. Optional
  `review_mode: pr` emits the `Review mode:` line in the reconstructed
  prompt (PR review versus local pre-review).
- `diff/changed-lines.txt` — the orchestrator's `$CHANGED_LINES_BLOCK`.
- `diff/full-diff.patch` (worktree / patch strategy only).
- `expected/findings-<tool>.md` — the captured agent output verbatim.
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

## Specialist ablation

```
tests/ab/run-specialist-ablation.sh --agent <name> --fixture <id> \
    --file <repo-relative-path> [--ref <git-ref>] [--trials <n>]
```

Arm B runs the working tree as-is; arm A swaps the named file to its blob at
`--ref` (default `HEAD`). Both arms use
`tests/ab/configs/per-agent/<agent>-baseline.yaml`. The file is restored on
every exit path; a failed restore writes `tests/ab/MANUAL_REVERT_REQUIRED`.
Score each arm's `trial-NNN/stdout.log` with
`tests/ab/lib/specialist_score.sh` and feed the counts to
`tests/ab/lib/ab_stats.py`.

## PR mockup renderer

`tests/ab/lib/render_pr_mockup.mjs <fixture-dir>` replays captured panel
output (`flat_findings.json`, `panelists.json`, `writer_body.md`) through
the real `review-core.js` with model calls stubbed, and prints the review
body and inline comments a PR would show. It re-runs no model, so it is for
tuning presentation, not model prose.

## Implementation notes

- **Empirically ground parsers**: the per-specialist findings parser must
  be developed against a live agent trace, not a hypothetical format. The
  Phase 2 plan's original parser was authored against a fictional plain
  `Field: value` format; the canonical contract at
  `static-analysis-context.md §7` uses bold-markdown bullets. The first
  live trial revealed the divergence; the parser was corrected at Task 8
  closeout. New specialists should expect to do a sonnet/default capture
  trial first and inspect `agent-output.md` before writing the parser.
- **CLI flag spellings under-documented**: `--append-system-prompt-file`
  is recognised by the CLI but only documented as a substring inside
  `--bare`'s description (`--append-system-prompt[-file]`). Confirm flag
  spellings via empirical probe (`command claude --append-system-prompt-file
  /tmp/nonexistent` produces a clear error confirming the flag is parsed).
- **`effort: default` is a sentinel, not a valid CLI value**: the harness
  omits the `--effort` flag when the config value is `default` or empty,
  leaving the CLI's built-in default in place. Configs that want explicit
  effort levels should use `low | medium | high | xhigh | max`.
