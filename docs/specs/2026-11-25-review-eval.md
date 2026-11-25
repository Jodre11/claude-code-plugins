# Review eval: suite, native and hybrid arms

Status: draft 2026-11-25. Step 4 of the code-review-suite overhaul. Steps 1 to 3b have merged; the last was
PR #143 (hybrid arm).

## Goal

Decide, on evidence, whether to KEEP the suite, add Anthropic's pipeline to it (HYBRID), or SWITCH to Anthropic's
bundled review. The eval measures detection only: planted defects found, false alarms raised, cost and wall-clock
per review. Posting, threading and `/address-pr-comments` behaviour are out of scope (see Out of scope).

## Background (established by spikes, 2026-11-24/25)

- **`claude plugin eval`** (CLI 2.1.332) runs each case in a headless child (`-p`, `dontAsk`) with a temporary
  home and no network. Its only arms are with-plugin and without-plugin, so **each arm here is a separate case**
  run with `--ablation none`. Graders are `tool_used`, `regex` and `llm` (three judge votes per grader, haiku by
  default, `--judge-model` to change it). There are no custom-code graders; a grader's `weight` may be 0.
- **Plugins load only from under the eval target**, so the suite lives at the repo root (`evals/`, target `.`) and
  every case lists `plugins: ["../../plugins/code-review-suite", "../../plugins/reply-fit"]`; without `reply-fit`
  the suite fails to load, silently.
- **Full `/pre-review` runs in a child.** On a scaffolded two-commit fixture it took the full route, ran 13
  specialists and the panel, and caught both planted defects (3/3 votes each).
- **Cost accounting is complete.** The reported $2.06 for that run includes the Workflow agents: its `modelUsage`
  carries sonnet and haiku usage that only the 18 Workflow agents could have spent. `subagent_stats` counts only
  Agent-tool spawns, which is why it read 0.
- **The bundled `/code-review` is a forked skill.** It runs as its own subagent, needs Bash for `git diff`, takes
  `<level> [target]`, and returns a JSON findings array to the parent. In a fresh home there is no remembered
  level, so the level must be passed.
- **Three child-side gaps** (all seen in the spike):
  1. `$PLUGIN_ROOT` resolves to the plugin cache path, which the sandbox will not read, so the panel ran without
     `includes/panel-concern-brief.md`.
  2. The hybrid arm's `ANTHROPIC_PLUGIN_FILE` (`review-core.js:73`) points into `~/.claude/plugins/marketplaces/`,
     which the temporary home lacks, so the arm would report skipped.
  3. `/tmp/claude-*` is not writable, so the review fell back to `$TMPDIR`.
- **Anthropic's `code-review` plugin is Apache-2.0**, so a pinned copy of `commands/code-review.md` may ship with
  the eval alongside its LICENSE. Current sha256: `3f02ea6e…deb3b1b2`.

## Arms

| Arm | Prompt | Config |
|---|---|---|
| suite | `/code-review-suite:pre-review main` | defaults |
| native | `/code-review high main` | defaults |
| hybrid | `/code-review-suite:pre-review main` | repo-level `.claude/code-review.toml` sets `review.anthropic_specialist = true` and `review.anthropic_plugin_file` to the pinned copy |

All arms load the same plugins, so the child's tool surface and system prompt are identical; only the prompt and
the fixture config differ. The hybrid config and pinned copy are untracked and listed in `.git/info/exclude`, so
they never appear in the diff under review. The child runs on the session's default model (recorded in results).
Every case appends the same unattended-run instruction the spike used, plus: "Use a directory under `$TMPDIR` for
temp files" and "End with the complete list of findings."

## Cases

**Corpus port (up to 21 cases).** From `tests/ab/corpus` (25 fixtures; the handover's "27" was wrong):

- the 17 judgement fixtures (silent-failure, reuse, style, test-quality, test-adequacy, api-contract,
  latent-hazard; hits and near-misses);
- the 4 static smoke fixtures (ruff, eslint, trivy, jbinspect), each kept only if its tool runs inside the child
  (checked in the pilot);
- not the 4 housekeeper fixtures: the child has no network, and their recorded registry responses are wired
  through the A/B harness, not the plugin.

Each `source.yaml` `setup.command` becomes the case's `fixture.sh`; `planted` becomes its graders.

**Qodo PR-Review-Bench (12 cases, about 70 issues).** MIT dataset: 100 real merged PRs from eight repos with 580
injected issues, each with `file_path`, `start_line`, `end_line`, `problematic_code_snippet` and, for rule
violations, `rule_name`; a companion `rules_for_repo.jsonl` lists each repo's rules. Use only the four repos with
permissive licences, three PRs each, taking the lowest PR numbers: Ghost (JS), aspnetcore (C#), prefect (Python)
and tauri (Rust). cal.com (AGPL), dify (conditional licence), firefox-ios (MPL) and redis (source-available) are
excluded because their code would be committed here. The porter checks each upstream LICENSE at port time and
refuses anything that is not MIT or Apache-2.0.

Materialisation is offline, because the child and possibly the scaffold have no network. A host-side porter
(`evals/tools/port_qodo.py`, stdlib only, run by me) fetches each benchmark PR from the
`agentic-review-benchmarks` org and vendors the base and head versions of every touched file, plus the upstream
LICENSE, into the case directory. The repo's extracted rules become the fixture's `CLAUDE.md`, so rule violations
are checkable by all three arms. The scaffold builds a two-commit repo from the vendored files. **Known bias:**
reviewers see only the touched files, not the whole upstream repo, which handicaps context-heavy reviewers; it
applies equally to all arms and is reported with the results.

**Kodus benchmark: excluded.** It has 38 bugs, no file or line anchors, no licence and no downloadable dataset.

## Layout

```
evals/
  fixtures/<id>/fixture.yaml   # source of truth: scaffold, planted issues, class, near-miss expectations
  fixtures/<id>/files/         # vendored files (Qodo) or fixture sources (corpus)
  vendor/anthropic-code-review/{code-review.md,LICENSE}
  cases/<id>-<arm>/            # GENERATED: case.yaml + fixture.sh per arm
  tools/build_cases.py         # renders cases/ from fixtures/; --check for tests/run.sh
  tools/port_qodo.py
  tools/port_corpus.py
  tools/aggregate.py           # reads --json results, writes the comparison table
  README.md
```

Generated cases are committed, and `tests/run.sh` runs `build_cases.py --check`, mirroring
`render-includes.py --check`. `evals/results/` is gitignored. `evals-spike/` is deleted (it is untracked).

## Graders

Per case:

- **Validity (`tool_used`, weight 0).** suite and hybrid: `Workflow` with `input_match: 'review-core'`; hybrid also
  needs `input_match: '"anthropicSpecialist":\s*true'`; native: `Skill` with `input_match: 'code-review'`. A run
  failing validity is invalid: it is rerun, not scored as a miss.
- **Detection (`llm`, one per planted issue).** "PASS if the review's findings include this defect: <title>, in
  <file> near lines <start>–<end>: <description>. Wording, severity and format do not matter; a finding counts if
  a reader acting on it would fix this defect. FAIL otherwise."
- **Near-miss (`llm`, corpus near-miss fixtures).** "PASS if the review does not report <pattern> as a defect that
  must be fixed. A note offered as optional or as a suggestion is not a report." This is the clean false-alarm
  measure.
- **Noise (`llm`, weight 0, Qodo cases).** "Count the distinct issues the review says must be fixed, treating
  near-duplicates as one. PASS if at most 2 are outside this list: <planted titles>." It is a proxy: real PRs may
  hold genuine unplanted issues. Near-duplicate merging offsets the hybrid arm's known double-reporting (plugin
  de-duplication steps 8–9 are skipped).

Judges: `--judge-model sonnet`, three votes per grader. `aggregate.py` reports the unanimous-vote rate per arm.
Below 85 % unanimous, I re-examine the criteria before reading results. I also hand-check 10 randomly drawn
verdicts against the transcripts.

## Metrics and decision rule

Each planted issue carries a class: **bug** (corpus correctness, silent-failure, latent-hazard, api-contract and
test-adequacy hits; Qodo issues without `rule_name`) or **quality** (reuse, style, test-quality, static smoke; Qodo
`rule_name` issues). Per arm, `aggregate.py` reports bug recall, quality recall, near-miss pass rate, noise pass
rate, mean cost per review, mean wall-clock, and a paired sign test per issue between arms (per-issue detection
rate across runs).

Default rule (assumption, open to change before the full run):

- **SWITCH** if native bug recall ≥ suite bug recall − 5 pp, its near-miss pass rate ≥ the suite's, and its cost is
  ≤ 50 % of the suite's.
- **HYBRID** if hybrid bug recall ≥ suite bug recall + 5 pp, its near-miss pass rate is no worse, and the sign test
  gives p < 0.1.
- **KEEP** otherwise.
- A result within noise (p ≥ 0.1 in both directions) is reported as a tie, and the decision goes to the user, with
  the cost figures.

## Prerequisite plugin PR (eval-readiness)

1. **Embed the concern brief in `review-core.js`.** Extend `render-includes.py` with a JS target: a
   `// BEGIN GENERATED from includes/panel-concern-brief.md` region holding `const PANEL_BRIEF = <JSON string>`.
   Drop the `panelBrief` arg and the `$PLUGIN_ROOT` resolution from `review-pipeline.md` (and so from its generated
   copies in `pre-review.md` and `review-gh-pr/SKILL.md`). `$PLUGIN_ROOT`'s only consumer is that read, so it goes
   entirely. This also removes a fragile step in which the model copies 10 KB verbatim into the Workflow args. It
   resolves the step 5 "one PLUGIN_ROOT mechanism" item for this consumer.
2. **`review.anthropic_plugin_file`.** A new key resolved from the same two config layers as
   `anthropic_specialist`, passed as the `anthropicPluginFile` arg. A relative path resolves against `repoDir`; the
   default stays the current marketplace path. A missing file still means skipped.
3. **Temp dir: no plugin change.** The eval instructs `$TMPDIR`; the proper fix is step 5's plugin-owned
   SessionStart hook.

Tests: `render-includes.py --check` covers the JS region; a structural test asserts that `review-core.js` declares
no `panelBrief` arg and that no prompt file mentions `$PLUGIN_ROOT`; config-resolution prose checks match across
the generated copies as they do today.

## Running

1. **Pilot** (gate for the full run): one corpus hit, one near-miss, one Qodo case, one static smoke case; × 3
   arms × 1 run; `--max-cost-usd 60`. It checks validity graders, static-tool availability, judge agreement, and
   per-arm cost.
2. **Full run:** all cases × 3 arms × n runs, `-j 3`, `--max-cost-usd` set from the pilot's per-arm cost. Default
   n = 3; reduce corpus cases to n = 2 if the projected cost exceeds $500. **Gate:** I show the projected cost and
   wait for the user's go-ahead before launching.
3. **Results:** `docs/evals/<date>-review-eval.md` with the table, judge agreement, biases, the decision rule's
   outcome and the raw `result.json` path. The memory plan records the decision.

Run command shape (repo root):

```
claude plugin eval . --eval-dir evals --runs <n> --ablation none --allow-tools Workflow Bash Write --scaffold
    --judge-model sonnet --max-cost-usd <usd> --no-publish --trust-plugin -j 3
    --output-dir <tmp>/run --json <tmp>/run/result.json --report <tmp>/run/report.html
```

## Order

1. PR A: eval-readiness (plugin changes above). Merge, `claude plugin update`, `/reload-plugins`.
2. PR B: `evals/` (porters, generated cases, aggregate, README, `tests/run.sh` hook).
3. Pilot, then the full run (gated on cost), then the results doc (PR C).

## Assumptions

- Native = the bundled `/code-review` at `high`, not the `code-review` plugin command (which stays off and is
  what the hybrid arm pins).
- The eval decides the detection engine; it does not test posting.
- 12 Qodo PRs from four permissive repos are enough for a first decision; more can be ported if results are close.
- Sonnet judges with three votes satisfy "panel of judges with measured agreement".
- The decision thresholds above (5 pp, 50 % cost, p < 0.1) are defaults.

## Out of scope

- Posting, inline anchors, threads, `/address-pr-comments` and `/review-gh-pr` (the child has no network).
- Housekeeper freshness (needs network).
- Severity calibration beyond the near-miss "must be fixed" threshold.
- The step 5 portability items other than the brief embedding.
