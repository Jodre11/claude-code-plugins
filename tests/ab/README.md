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
