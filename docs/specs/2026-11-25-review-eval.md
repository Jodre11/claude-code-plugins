# Review eval: suite, native and hybrid arms

Status: reviewed 2026-11-25 (three-lens spec panel), amended. Step 4 of the code-review-suite overhaul. Steps 1 to
3b have merged; the last was PR #143 (hybrid arm).

## Goal

Decide, on evidence, whether to KEEP the suite, add Anthropic's pipeline to it (HYBRID), or SWITCH to Anthropic's
bundled review. **SWITCH means retiring the suite**: the user types `/code-review [--comment]` instead. The eval
measures detection only: planted defects found, false alarms raised, cost and wall-clock per review. What SWITCH
would give up (posting, threading, `/address-pr-comments`, the static analysers) is not measured. The results doc
names it as a cost, and SWITCH is only ever a candidate the user confirms.

## Background (established by spikes, 2026-11-24/25)

- **`claude plugin eval`** (CLI 2.1.332) runs each case in a headless child (`-p`, `dontAsk`) with a temporary
  home and no network. Its only arms are with-plugin and without-plugin, so **each arm here is a separate case**
  run with `--ablation none`. Graders are `tool_used`, `regex` and `llm` (three judge votes per grader, haiku by
  default, `--judge-model` to change it). There are no custom-code graders, and a grader's `weight` must be positive.
- **Plugins load only from under the eval target**, so the suite lives at the repo root (`evals/`, target `.`) and
  every case lists `plugins: ["../../plugins/code-review-suite", "../../plugins/reply-fit"]`; without `reply-fit`
  the suite fails to load, silently.
- **Full `/pre-review` runs in a child.** On a scaffolded two-commit fixture (security-sensitive, so full route) it
  ran 13 specialists and the panel, and caught both planted defects (3/3 votes each).
- **Route depends on size.** `/pre-review` takes the lightweight route (one `code-analysis` agent) when a diff has
  ≤ 5 files, ≤ 150 lines, no significant deletions and is not security-sensitive (`review-pipeline.md` Step 3). The
  lightweight route ignores `anthropic_specialist`, so on small diffs hybrid equals suite. Security sensitivity is
  the model's judgement, so the route can vary between runs.
- **Suite cost accounting is complete.** The reported $2.06 for that run includes the Workflow agents: its
  `modelUsage` carries sonnet and haiku usage that only the 18 Workflow agents could have spent. `subagent_stats`
  counts only Agent-tool spawns, which is why it read 0.
- **The bundled `/code-review` is a forked skill.** It runs as its own subagent, needs Bash for `git diff`, takes
  `<level> [target]`, and returns a JSON findings array to the parent. In a fresh home there is no remembered
  level, so the level must be passed.
- **Three child-side gaps** (all seen in the spike):
  1. `$PLUGIN_ROOT` resolves to the plugin cache path, which the sandbox will not read, so the panel ran without
     `includes/panel-concern-brief.md`.
  2. The hybrid arm's `ANTHROPIC_PLUGIN_FILE` (`review-core.js:73`) points into `~/.claude/plugins/marketplaces/`,
     which the temporary home lacks, so the arm reports skipped.
  3. `/tmp/claude-*` is not writable, so the review fell back to `$TMPDIR`.
- **Anthropic's `code-review` plugin is Apache-2.0**, so a pinned copy of `commands/code-review.md` may ship with
  the eval alongside its LICENSE. Current sha256: `3f02ea6e…deb3b1b2`.

## Arms

| Arm | Prompt | Config |
|---|---|---|
| suite | `/code-review-suite:pre-review main` | defaults |
| native | `/code-review high main` | defaults |
| hybrid | `/code-review-suite:pre-review main` | repo-level `.claude/code-review.toml` sets `review.anthropic_specialist = true`; the scaffold places the pinned plugin file (see Prerequisite PR) |

All arms load the same plugins, so the child's tool surface and system prompt are identical; only the prompt and
the fixture config differ. Every case sets `allowed_tools: [Read, Glob, Grep, Skill, Agent, Workflow, Bash,
Write]`. The hybrid config is untracked and listed in `.git/info/exclude`, so it never appears in the diff under
review. The child runs on the session's default model (recorded in results). Every case sets `max_turns: 200` and
`timeout_seconds: 3600` (the defaults, 10 turns and 300 s, would cut a review short) and appends the spike's
unattended-run instruction, plus: "Use a directory under `$TMPDIR` for temp files", "End with the complete list of
findings, each with its severity", for suite and hybrid only, "Before the findings, print one line per specialist:
`<name>: <status>`", and the fixture's intent (see below).

**Intent.** In local mode `/pre-review` halts before any specialist runs unless it finds a narrative description
(an in-diff doc, a `Prompt:` block, or a commit subject of more than seven words), and most fixture subjects fail
that rule. Each fixture therefore carries an `intent` paragraph, which goes into the head commit body and into the
appended prompt as the text to give if the review asks for one. All three arms get it identically. For Qodo it is
the original PR description, with the benchmark's wrapper, the Cursor Bugbot summary (another reviewer's output)
and presigned image URLs stripped; a description under eight words becomes the title plus a note that upstream gave
no more. For the corpus it is the A/B intent ledger's goal.

## Cases

**Qodo PR-Review-Bench: the decision set (12 cases, 76 issues: 39 bug, 37 rule).** MIT dataset: 100 real merged PRs from eight
repos with 580 injected issues. Each issue has `title`, `description`, `file_path`, `start_line`, `end_line`,
`problematic_code_snippet` and, for rule violations, `rule_name`; a companion `rules_for_repo.jsonl` lists each
repo's rules. Use only the four repos with permissive licences, three PRs each: Ghost (JS), aspnetcore (C#),
prefect (Python) and tauri (Rust). Take the lowest-numbered PRs whose diff exceeds the lightweight thresholds, so
every arm runs its full pipeline. cal.com (AGPL), dify (conditional licence), firefox-ios (MPL) and redis
(source-available) are excluded because their code would be committed here. The porter checks each upstream
LICENSE at port time and refuses anything that is not MIT or Apache-2.0. If the results are too wide to decide, more
PRs can be ported: the permissive pool holds 49.

Materialisation is offline, because the child has no network. A host-side porter (`evals/tools/port_qodo.py`,
stdlib only, run by me) fetches each benchmark PR from the `agentic-review-benchmarks` org and vendors into the
fixture the base and head versions of every touched file, plus the upstream LICENSE. Files the PR adds or deletes
are absent from one side, a rename is vendored as a delete plus an add, and binary files are skipped. The repo's
extracted rules become the fixture's `CLAUDE.md`, committed in the base commit so it is not in the reviewed diff;
rule violations are then checkable by all three arms. The scaffold builds a base commit on `main` and a head commit
on `feature/<id>`. **Known bias:** reviewers see only the touched files, not the whole upstream repo, which
handicaps context-heavy reviewers; it applies equally to all arms and is reported with the results.

**Corpus port: sanity set (17 cases, n = 1).** These are the judgement fixtures from `tests/ab/corpus`:
silent-failure, reuse, style, test-quality, test-adequacy, api-contract and latent-hazard, hits and near-misses.
They are **not** in the decision rule. The suite's prompts were tuned on exactly these fixtures, and their near-miss
expectations encode the suite's own policy. They are also small enough to take the lightweight route, where hybrid
equals suite. They serve as a regression and breakage check, and their suite-vs-native result is reported
separately with that bias stated. Each `source.yaml` setup moves the planted files aside, commits the rest, then
commits the planted files, all on `main`; `port_corpus.py` reads that base/head split (asserting it covers the
fixture directory) and the scaffold commits the head on a feature branch instead. The corpus READMEs name the planted
defect, so the scaffold replaces each with a neutral one built from the base commit subject. The static smoke fixtures are
cut, because their outcome is known in advance (the suite runs the linter; native does not). The housekeeper
fixtures are cut too: they need network or the A/B harness's recorded registries.

**Kodus benchmark: excluded.** It has 38 bugs, no file or line anchors, no licence and no downloadable dataset.

## Layout

```
evals/
  fixtures/<id>/fixture.json   # source of truth (schema below)
  fixtures/<id>/files/{base,head}/  # vendored Qodo files; corpus fixtures point at tests/fixtures/** instead
  vendor/anthropic-code-review/{code-review.md,LICENSE}
  tools/build_cases.py         # renders cases/ from fixtures/, checks the vendored sha256
  tools/port_qodo.py
  tools/port_corpus.py         # writes fixture.json only; files stay in tests/fixtures/**
  tools/aggregate.py           # reads --json results, writes the comparison table
  README.md
  cases/                       # GENERATED, gitignored: <id>-<arm>/{case.yaml,fixture.sh}
```

`build_cases.py` renders `cases/` immediately before each run. Each `fixture.sh` is self-contained: it embeds every
file as base64, because the scaffold runs in the eval workspace, not the case directory. `case.yaml` is written as
JSON, which YAML accepts, so every tool is stdlib-only. `cases/` and `results/` are gitignored, so there is no
committed generated tree and no `--check` hook. `evals-spike/` is deleted (it is untracked).

`fixture.json` schema (shown as YAML for brevity):

```yaml
id: qodo-ghost-1
set: decision | sanity
source: qodo | corpus
upstream: {repo: Ghost, pr: 1, licence: MIT}   # qodo only
commit_title: Removed xmlrpc/pingomatic ping service
intent: Pingomatic is a legacy blog ping service ...
issues:                                         # hits; empty for a near-miss
  - title: NPM referenced instead of Yarn
    description: ...
    file: ghost/core/core/boot.js
    lines: [313, 313]
    class: bug | rule | quality
near_miss:                                      # near-miss fixtures only
  file: lib/http_client.py
  pattern: logging the exception before returning None
```

For Qodo, `title`, `description` and `lines` come from the dataset, and `class` is `rule` when `rule_name` is set,
otherwise `bug`. Seven dataset issues carry no location; they get `file` and `lines` of `null` and are graded on
their description alone. For the corpus, the titles, descriptions and near-miss patterns are hand-written from the
`index.yaml` description (and `expected/report.md` where one exists) and kept in `port_corpus.py`, so a rerun
reproduces them. Bug class covers
silent-failure, latent-hazard, api-contract and test-adequacy; quality covers reuse, style and test-quality. A single
`planted.line` becomes `[line-3, line+3]`; `line: 0` means file-level. A near-miss fixture gets only the near-miss
grader.

## Graders

The eval schema requires a positive `weight`, so every grader keeps the default of 1. `aggregate.py` reads each
grader's pass or fail by name and never uses the tool's composite score, so no grader needs to be marked
informational. Names: `valid-*`, `route-full`, `diag-*`, `detect-<key>`, `mustfix-<key>`, `noise`, `near-miss`.

Per case:

- **Validity.**
  - suite and hybrid: `tool_used` `Workflow`, `input_match: 'review-core'`;
  - hybrid also: `regex` on the final message for `anthropic: ok` (also accepting `anthropic-reviewer`). This
    proves the arm ran rather than skipped or fell to the lightweight route;
  - native: `llm`, "the reply reports the outcome of a code review", because a typed slash command may not appear
    as a `Skill` tool call. A `regex` on the trace for a `code-review` Skill call is recorded as
    `diag-native-skill`; the pilot shows which one holds.
- **Route (suite and hybrid).** `regex` on the trace for `using full review pipeline`. It is recorded, so a Qodo run
  that fell to lightweight is visible.
- **Detection (`llm`, one per issue).** "PASS if the review's findings include this defect: <title>, in <file> near
  lines <start>–<end>: <description>. Wording, severity and format do not matter; a finding counts if a reader
  acting on it would fix this defect. FAIL otherwise."
- **Must-fix detection (`llm`, Qodo bug issues, reported only).** As above, but the finding must be presented as needing
  a fix (Important or higher in the suite, any reported bug in native). This shows severity under-calling, the
  panel's known failure mode, which plain recall cannot see.
- **Noise (`llm`, Qodo cases).** "Count the distinct issues the review says must be fixed, treating near-duplicates
  as one. PASS if at most 2 are outside this list: <issue titles>." It is a proxy, since real PRs may hold genuine
  unplanted issues. Near-duplicate merging offsets the hybrid arm's known double-reporting (plugin de-duplication
  steps 8–9 are skipped).
- **Near-miss (`llm`, corpus near-miss fixtures).** "PASS if the review does not report <pattern> in <file> as a
  defect that must be fixed. A note offered as optional or as a suggestion is not a report."

Judges: `--judge-model sonnet`, three votes per grader. `aggregate.py` reports the unanimous-vote rate per arm.
Below 85 % unanimous, I re-examine the criteria before reading the results. I also hand-check 10 randomly drawn
verdicts against the transcripts.

**Invalid runs.** `aggregate.py` marks a run invalid when any validity grader fails, and lists the invalid
`(case, arm)` pairs. I rerun each pair once with `--case <id>-<arm> --runs <missing>`. If it is still invalid, that
case is dropped from every arm's paired comparison, and the drop is reported. Pairing uses only cases that are valid
in all compared arms.

## Metrics and decision rule

Computed on the decision set (Qodo) only, per arm:

- bug recall (BR) and rule recall (RR): the mean per-issue detection rate across runs;
- noise pass rate (NP);
- mean cost per review;
- mean wall-clock and must-fix recall, reported but not in the rule.

**Uncertainty:** a cluster bootstrap over PRs (10 000 resamples) gives a 90 % CI for each between-arm difference.
All outcomes use this one bar.

Rule, evaluated in this order:

1. **HYBRID** if `hybrid − suite` BR has a CI lower bound > 0 and a point estimate ≥ 5 pp; RR and NP have CI lower
   bounds > −5 pp and > −10 pp; and the hybrid costs ≤ 1.5× the suite.
2. **SWITCH candidate** if `native − suite` is non-inferior: BR and RR have CI lower bounds > −5 pp, NP has a CI
   lower bound > −10 pp, and native costs ≤ 50 % of the suite. Compare against the hybrid instead when rule 1 held.
   The user confirms or rejects it, weighing the unmeasured lost features.
3. **KEEP** otherwise. An inconclusive result keeps the status quo.

If CIs are too wide for any rule to fire, but the point estimates differ by ≥ 5 pp, port more Qodo PRs before
deciding. RR is in the rule because CLAUDE.md compliance is much of what the suite contributes in practice.

## Prerequisite plugin PR (eval-readiness)

1. **Embed the concern brief in `review-core.js`.**
   - Extend `render-includes.py` to scan `workflows/*.js` as well as `*.md`, with a whole-file embed:
     `// BEGIN GENERATED from includes/panel-concern-brief.md: edit that file, then run
     scripts/render-includes.py` on one line, then `const PANEL_BRIEF = <json.dumps(file text)>`, then
     `// END GENERATED from includes/panel-concern-brief.md`. A whole-file source needs no SOURCE markers.
   - `panelVote` uses `PANEL_BRIEF`.
   - Drop the `panelBrief` arg and the `$PLUGIN_ROOT`/`$PANEL_BRIEF` steps from `review-pipeline.md`, and so from
     its generated copies in `pre-review.md` and `review-gh-pr/SKILL.md`. `$PLUGIN_ROOT`'s only consumer is that
     read, so it goes entirely.
   - This also removes a fragile step in which the model copies 10 KB verbatim into the Workflow args, and it
     resolves the step 5 "one PLUGIN_ROOT mechanism" item for this consumer.
   - Update every test that references the arg (`grep -rln panelBrief tests`: eight files, including
     `tests/lib/test_panel_wiring.sh`, which asserts `panelBrief: $PANEL_BRIEF` in the prompt files, and
     `tests/ab/lib/render_pr_mockup.mjs`).
   - Add a structural test that `review-core.js` declares no `panelBrief` arg. `render-includes.py --check` covers
     staleness of the JS region.
2. **Hybrid plugin file: no plugin change if the scaffold can place it.** The hybrid `fixture.sh` copies the pinned
   `code-review.md` to the path `ANTHROPIC_PLUGIN_FILE` already names, under the child's `$HOME`. The pilot's hybrid
   validity grader checks that this works. Only if the scaffold cannot reach the child's home does PR B add an
   optional `anthropicPluginFile` arg to `review-core.js`: a relative value resolves against `repoDir` inside
   review-core, and an absent value keeps the current constant. The orchestrator passes it from a
   `review.anthropic_plugin_file` key resolved from the same two layers as `anthropic_specialist`.
3. **Temp dir: no plugin change.** The eval instructs `$TMPDIR`; the proper fix is step 5's plugin-owned
   SessionStart hook.

## Running

1. **Pilot** (gates the full run): one Qodo case and one corpus hit, × 3 arms × 1 run; `--max-cost-usd 60`. It
   checks:
   - validity graders, including the hybrid's `anthropic: ok`;
   - the full route on the Qodo case;
   - judge agreement;
   - per-arm cost, including that native's cost covers its forked subagent (its `modelUsage` must show the fork's
     usage).
2. **Full run:** the decision set × 3 arms × 3 runs, plus the sanity set × 3 arms × 1 run; `-j 3`; `--max-cost-usd`
   set from the pilot's per-arm cost. **Gate:** I show the projected cost and wait for the user's go-ahead before
   launching.
3. **Results:** `docs/evals/<date>-review-eval.md`. It holds the table, judge agreement, the biases (touched-files
   context, the corpus's home-turf tuning), the lost-feature list for SWITCH, the rule's outcome and the raw
   `result.json` path. The memory plan records the decision.

Run command shape (repo root):

```
claude plugin eval . --eval-dir evals --runs <n> --ablation none --allow-tools Workflow Bash Write --scaffold
    --judge-model sonnet --max-cost-usd <usd> --no-publish --trust-plugin -j 3
    --output-dir <tmp>/run --json <tmp>/run/result.json --report <tmp>/run/report.html
```

## Order

1. PR A: eval-readiness (the brief embed). Merge, `claude plugin update`, `/reload-plugins`.
2. PR B: `evals/` (porters, builder, aggregate, README, gitignore).
3. Pilot, then the full run (gated on cost), then the results doc (PR C).

## Assumptions

- Native = the bundled `/code-review` at `high`, not the `code-review` plugin command (which stays off and is
  what the hybrid arm pins).
- The eval decides the detection engine; it does not test posting.
- 12 Qodo PRs from four permissive repos are enough for a first decision; the rule says when to port more.
- Sonnet judges with three votes satisfy "panel of judges with measured agreement".
- The decision thresholds (5 pp, 10 pp for noise, 1.5× and 50 % cost, 90 % CI) are defaults.
- Wall-clock is reported, not ruled on.

## Out of scope

- Posting, inline anchors, threads, `/address-pr-comments` and `/review-gh-pr` (the child has no network).
- Housekeeper freshness (needs network) and the static analysers.
- Severity calibration beyond must-fix recall and the near-miss threshold.
- The step 5 portability items other than the brief embedding.
