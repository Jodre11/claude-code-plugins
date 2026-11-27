# Review eval

Decides, on evidence, whether to keep the code-review suite, add Anthropic's review pipeline to it (hybrid), or
switch to Anthropic's bundled `/code-review`. The design, the decision rule and its thresholds are in
[`docs/specs/2026-11-25-review-eval.md`](../docs/specs/2026-11-25-review-eval.md).

## Arms

| Arm | Prompt | Config |
|---|---|---|
| suite | `/code-review-suite:pre-review main` | defaults |
| native | `/code-review high main` | defaults |
| hybrid | `/code-review-suite:pre-review main` | untracked `.claude/code-review.toml` sets `[review] anthropic_specialist = true`; the scaffold places the pinned Anthropic command under the child's `$HOME` |

## Cases

- **Decision set**: 28 PRs from [Qodo PR-Review-Bench](https://huggingface.co/datasets/Qodo/PR-Review-Bench)
  (MIT), seven each from Ghost (MIT), aspnetcore (MIT), prefect (Apache-2.0) and tauri (Apache-2.0): the
  lowest-numbered PRs large enough for the suite's full route. The first 12 (three per repo) ran in all three
  arms; the 16 added to narrow the suite-versus-native interval ran in those two arms only. Each fixture vendors the base and head versions of
  the touched files, the upstream licence (`UPSTREAM-LICENSE`) and the repo's extracted rules as `CLAUDE.md`.
- **Sanity set**: the 17 judgement fixtures from `tests/ab/corpus`, read from `tests/fixtures/**`. They are not in
  the decision rule: the suite was tuned on them.

`fixtures/<id>/fixture.json` is the source of truth for each case: the issues to detect (`class` is `bug`, `rule`
or `quality`; `lines: null` means no location), or a `near_miss` pattern that must not be reported as must-fix,
plus the commit title and the change's `intent`. The intent goes into the head commit body and the appended
prompt, because `/pre-review` halts in local mode without a narrative description.

## Layout

```
fixtures/<id>/fixture.json       source of truth
fixtures/<id>/files/{base,head}/ vendored Qodo files (corpus fixtures point at tests/fixtures/** instead)
vendor/anthropic-code-review/    pinned code-review.md (Apache-2.0) and its LICENSE
tools/port_qodo.py               host-side porter; needs gh and network
tools/port_corpus.py             corpus porter; needs yq
tools/build_cases.py             renders cases/ (gitignored) and checks the vendored sha256
tools/aggregate.py               metrics, cluster bootstrap and the decision
```

## Running

Render the cases, then run from the repo root. Each case is one arm, so `--ablation none`. The eval child
inherits `PATH`, and a Claude Code session puts its installed plugins' `bin/` directories on it, which would
let the child call the installed suite's tools instead of this tree's; the `PATH=` prefix drops them, and the
`valid-plugin-under-test` grader rejects any run that still reaches one.

```bash
python3 -I evals/tools/build_cases.py
PATH=$(printf %s "$PATH" | tr ':' '\n' | grep -v '/\.claude/plugins/cache/' | paste -sd: -) \
claude plugin eval . --eval-dir evals --runs 3 --ablation none --allow-tools Workflow Bash Write --scaffold \
    --judge-model sonnet --max-cost-usd <usd> --no-publish --trust-plugin -j 3 \
    --output-dir "$CLAUDE_TEMP_DIR/run" --json "$CLAUDE_TEMP_DIR/run/result.json" \
    --report "$CLAUDE_TEMP_DIR/run/report.html"
python3 -I evals/tools/aggregate.py "$CLAUDE_TEMP_DIR/run/result.json"
```

Filter with `--tag suite|native|hybrid|decision|sanity` (a case runs if any tag matches) or `--case <glob>` (it
rejects `[...]` classes), or render a subset with `build_cases.py --fixture <id>... --arm <arm>...`. Rerun an
invalid `(case, arm)` pair once with `--case <id>-<arm>`, then pass both result files to `aggregate.py`; a pair
still invalid is dropped from every arm's comparison. When a fixture's prompt or a last-message regex grader is
fixed after a run, `tools/curate.py <result.json>... --drop <fixture>... --regrade <grader>...` writes
`*.curated.json` copies with the stale fixtures' runs removed and the grader re-applied; record its use in the
results doc. A PR pairs only if every arm compared has a valid run, so to compare arms over PRs not run in all
three, pass `aggregate.py --arms suite native`.

Every grader is scored by the eval tool, but `aggregate.py` reads each one by name, so the tool's composite score
is not used: `valid-*` decides whether a run counts, `route-full` and `diag-*` are recorded, `detect-*`,
`mustfix-*`, `noise` and `near-miss` feed the metrics.

## Re-porting

```bash
python3 -I evals/tools/port_qodo.py --cache-dir "$CLAUDE_TEMP_DIR/qodo-data"
python3 -I evals/tools/port_corpus.py
```

`port_qodo.py` keeps fixtures already ported; `--refresh-intent` re-derives only their title and intent.
