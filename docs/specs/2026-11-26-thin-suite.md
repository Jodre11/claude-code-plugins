# Thin suite: Anthropic's review as the finder

Status: draft 2026-11-26, not yet panel-reviewed. Step 4b of the code-review-suite overhaul, between the eval
(step 4) and portability (step 5).

## Goal

The suite stops doing its own LLM bug finding. Anthropic's bundled `/code-review` finds the issues; the suite keeps
what the eval showed native lacks or never measured:

- the static analysers (ruff, eslint, jbinspect, trivy) and the housekeeper;
- the GitHub posting flow: one review with a verdict, inline comments, the marker, the wording pass;
- `/address-pr-comments` and self-re-review;
- `/pre-review` for local changes.

The LLM specialists, the panel and everything that only they consume are retired. The result should cost about a
third of today's review, finish in about half the time, and pick up Anthropic's improvements to `/code-review` with
no work on our side.

## Background

- **The eval** ([`docs/evals/2026-11-26-review-eval.md`](../evals/2026-11-26-review-eval.md), PR #147), 28 PRs,
  native − suite: bug recall +4.2 pp [+1.1, +7.4], rule recall +9.0 pp [+0.8, +18.6], noise −2.4 pp
  [−17.9, +13.1], cost 0.29×, wall-clock 1.9 against 3.8 minutes. On 12 PRs the two finders caught the same issues
  (76 issues: 48 both, 25 neither, 1 suite only, 2 native only), so keeping any of our LLM specialists beside
  native adds little. The hybrid arm gained nothing at 1.71× the cost. The owner chose native plus a thin suite on
  2026-11-26.
- **What native is.** The bundled skill (CLI 2.1.332) is a forked skill. At `high` it runs four finder angles
  (line-by-line, removed behaviour, cross-file callers, CLAUDE.md conventions) in its own context, dedups without
  verifying, and returns at most 10 findings as a JSON array of
  `{file, line, summary, failure_scenario, severity}`, where `severity` is `important`, `nit` or `pre_existing`
  and `summary` ends with `Fix: …`. Other effort levels change the shape: the CLI's strings show some spawning 2–8
  finder subagents when an Agent tool is available, and `ultra` runs in the cloud. `--comment` posts the findings
  as inline PR comments; `--fix` applies them. The prompt is built into the CLI and changes between releases.
- **Native reads the user's CLAUDE.md.** Its conventions angle says the user-level `~/.claude/CLAUDE.md` "governs
  too" when it is in context. PR #138 made the suite judge only against the plugin and the reviewed repo
  (`includes/rule-sources.md`), so a personal rule never becomes a finding on someone else's PR. The eval could not
  see this: its child sessions had a temporary home with no user CLAUDE.md.
- **Native cannot be called by the model today.** `skillOverrides.code-review` is `user-invocable-only`
  (`~/.claude` 146073a). The 2026-11-23 spike S1 showed a Workflow agent calling Skill on it gets a tool error.
- **The panel was also the static analysers' existence check.** A static specialist once returned a confidence-100
  Critical that its tool never reported; the panel voted it false (PR #106). Without the panel, something
  deterministic must stand in.
- **Noise.** On the suite-tuned sanity set native reported three near-miss patterns (api-contract, reuse, silent
  failure) as must-fix. The decision-set noise interval is too wide to rule a 10-point loss in or out.

## Decisions

Each answers one of the handover's open questions. Those marked **assumption** are defaults to confirm in review.

1. **Native's findings reach GitHub through our renderer, not `--comment`.** One review per run with a verdict,
   the marker, co-located merging and `/address-pr-comments` all depend on it. `--comment` would post a second,
   unmarked set of comments with no verdict. It stays the fallback if no spike can capture native's output (F2).
2. **Invoke the bundled skill, never a copy of it.** Copying the prompt, or reusing the hybrid adapter's
   `ANTHROPIC_REVIEWERS`, freezes a pipeline that Anthropic changes every few releases; riding those changes is the
   point. The hybrid adapter also follows the old marketplace plugin, which is not what the eval measured.
3. **No LLM noise filter.** The panel did not buy lower noise (suite NP 71.4 % against native 69.0 %). The thin
   suite uses deterministic guards only (see Guards). If organic reviews show must-fix false positives, the first
   lever is native's own effort level (the `high` prompt says "dedup (no verify)", which suggests higher levels
   verify; S3 confirms); a suite-side verifier comes
   back only with eval evidence. **Assumption.**
4. **Effort `high`, configurable.** `[review] native_effort` in `code-review.toml` (repo, then user), default
   `high`, the level the eval measured. Accepted: `low`, `medium`, `high`, `xhigh`, `max`. `ultra` is refused
   because Claude cannot launch it.
5. **The intent ledger (Phase 0) retires, halt included.** Its consumers were the alignment reviewer and the
   panel's `blocks_goal` vote; native takes no intent. The halt cost reviews in the eval (descriptions halted at
   random until the porter rewrote them) and asked authors for prose nothing would read. This also retires the
   known bug where the halt offers a commit-body source that no step reads. **Assumption:** the "please describe
   this PR" request is not wanted as a hygiene gate on its own.
6. **One route.** Trivial mode (Phase 0.7) and the lightweight route are LLM reviews by another name and retire.
   Native scales to small diffs by itself, at about $0.80 a review. The static analysers stay conditional on file
   type, as now.
7. **The CI gate, the worktree, the branch freshness check, analysis-only mode, self-re-review and the durable log
   stay**, trimmed of panel fields. Self-re-review keeps its current narrow main-session pass; an incremental
   native re-review stays on the backlog.
8. **The wording pass stays, on native's summary and fix only.** Native's prose is already terse, but it is posted
   under the user's login and the user shipped the pass two days ago. `failure_scenario` is posted verbatim and
   never sent to the editor, so the 60-word budget cannot cut the evidence. **Assumption.**
9. **Re-enable model invocation of `/code-review`.** Every capture route needs it. The routing risk the
   `user-invocable-only` setting guarded against shrinks: if the model picks `/code-review` when the user meant
   `/review-gh-pr`, the user still gets native's findings and loses only the static analysers and the posting.
   `/simplify` stays `user-invocable-only`. **Assumption.**

## Spikes (run first, on a throwaway fixture repo, never a live PR)

Run in-session (headless child sessions are blocked by the auto-mode classifier), with `skillOverrides.code-review`
removed from `settings.json` directly for the duration.

| # | Question | Pass | Fallback |
|---|---|---|---|
| S1 | Can a Workflow `agent()` of a new read-only `native-reviewer` type call Skill `code-review` with `high <target>` and return native's array, schema-bound, with nothing posted? Record whether the user CLAUDE.md is in that agent's context. | Same findings shape as the eval's native arm; no GitHub writes | F1 |
| S2 | Which `<target>` makes native review exactly `merge-base..PR head` inside the ephemeral worktree, including a cross-repo review (Phase -1), when the session's working directory is another repo? Candidates: a base SHA, a branch name, the PR URL. | Native's `git diff` covers exactly the pinned range | Run native with the worktree as the working directory, if `agent()` or Skill allows it; otherwise cross-repo reviews fall back to F2 |
| S3 | At `xhigh` and `max`, which may need an Agent tool the Workflow agent lacks, does native degrade cleanly (fewer finders) or fail? Does either level verify its candidates? | Findings returned | Cap `native_effort` at `high` under route C and say so in the README |

- **Route C (preferred, S1 passes).** `review-core` dispatches `native-reviewer` in parallel with the static
  specialists. One Workflow, one sealed bundle, the single-path guarantee kept.
- **F1 (S1 fails).** The main session calls Skill `code-review` before Step 3.5 and passes the array to
  `review-core` as `args.nativeFindings`; `review-core` skips the native dispatch. Native then runs before the
  static analysers instead of beside them (about a minute longer).
- **F2 (neither captures).** Native posts with `--comment` itself; the suite posts the static and housekeeper
  findings as its own marked review, with a verdict from those alone. `/address-pr-comments` needs
  `--include-self` for native's comments. Worst case; it is described so the spikes have somewhere to land.

## Design

### Pipeline

1. Phase -1 (target repo), Phase -0.5 (worktree), Phase 0.55 (branch freshness), Phase 0.6 (CI gate): unchanged.
2. Step 1 (base), Step 2 (diff measurement) and Step 2.5 (`$CHANGED_LINES`): unchanged. Detection keeps only the
   flags a kept specialist reads: `csharp`, `js`, `py`, `iac`, `housekeeping`. `ui`, `tests`, `production`,
   significant-deletion and security-area detection retire.
3. Step 2.9 (agent prompt) keeps only what the static specialists read.
4. Step 3 (route) retires. Step 3.5 calls `review-core` with the same args minus `route`, `intentLedger`,
   `panelSize`, `panelBrief` and `anthropicSpecialist`, plus `nativeEffort` and `nativeTarget` (both computed and
   validated in prose, never by `review-core`'s agents). The bare-command guard switches from `route` to
   `nativeTarget`.
5. `review-core`: dispatch `native` and the conditional static specialists in parallel; normalise; guard;
   compute the verdict; wording pass; render. Phases: `dispatch`, `assemble`, `voice`.

### The native specialist (route C)

- **Agent:** `code-review-suite:native-reviewer`. Tools `Skill`, `Read`, `Grep`, `Glob`, `Bash`; no `Write`,
  `Edit` or `Agent`. A `*-reviewer` name, so reviewer-guard blocks mutating git.
- **Prompt:** call Skill `code-review` with the args string `review-core` built, verbatim; never add `--comment` or
  `--fix`; return native's array unchanged. The args string is `${nativeEffort} ${nativeTarget}`, both values
  already validated.
- **Schema:** `{status, statusReason?, findings: [{file, line, summary, failure_scenario, severity}]}`, severity
  `important | nit | pre_existing`. `review-core` maps it in code, so no model decides the mapping.
- **Status:** `skipped` when the skill is missing or disabled (the error text names `skillOverrides`), `failed` on
  any other error. A run without native's findings still posts the static findings, with a one-line note in the
  body that native did not run, and never computes `APPROVE` from them alone.

### Normalisation (in code)

| Native | Finding |
|---|---|
| `severity: important` | `Important`, blocking |
| `severity: nit` | `Suggestion` |
| `severity: pre_existing` | `Suggestion`, `annotation: pre-existing`, never blocking |
| `summary` before `Fix:` | `description` |
| `summary` from `Fix:` on | `suggested_fix` (`""` when absent) |
| `failure_scenario` | rendered verbatim under the description; not editable |
| `file`, `line` | as given; the anchor guards below decide the route |

`confidence` no longer drives anything and is fixed per source (native 80, static 100) so the log stays readable.

### Guards (in code)

- **Personal rules.** A native finding whose text cites a CLAUDE.md that is not a repo-relative path inside the
  reviewed repo (`~/`, an absolute path, "user-level") is dropped and logged as `filtered: rule-source`. This
  restores PR #138's rule for native.
- **Anchors** (existing logic, now one function for every finding): file not in the diff, so the body; line not a
  changed line, so file-level; otherwise inline. Housekeeper findings stay exempt and go to the freshness table.
- **Static existence.** A static finding blocks only if its `rule_id` matches its tool's ID pattern (one regex per
  tool, kept beside `STATIC`) and it is anchored to a changed line. Otherwise it posts, keeps its locked severity
  label, and does not block. This replaces the panel's existence vote with the two facts a hallucinated tool
  result most often gets wrong.

### Verdict (PR mode, first match)

| # | Condition | Verdict |
|---|---|---|
| 1 | Native did not run | none; the body says so and Class A asks the user |
| 2 | Any blocking finding (native `important`, or a guarded static Critical or Important) | `REQUEST_CHANGES` |
| 3 | Otherwise | `APPROVE` |

`COMMENT` stays reachable only as the user's override at the Class A prompt. `verdict-rubric.md` is rewritten to
this table, and still states that `review-core.js` is the source of truth.

### Posting and body

- Inline comments, file-level comments, body notes and co-located merging (`groupColocated`, three lines) are
  unchanged. Native and static findings on the same lines merge into one thread.
- Body: verdict headline with the rubric reason, the finding index, body notes, the Dependency Freshness table, the
  marker. The Panel Assessment and the pruned-findings line go, with the panel writer.
- The local report keeps the same parts without the headline.
- Each finding carries its source (`native`, `ruff`, …) in the log and in the local report; posted comments do not
  name it.

### Logging

`log.meta` drops `orchestration_mode`, `panel_size` and `anthropic_specialist` and gains `finder: "native"`,
`native_effort`, `native_route` (`C`, `F1` or `F2`) and `cli_version`, so a later analysis can tie a finding to the
native prompt that produced it. `log.cogs` keeps native's raw array before normalisation. `finding-schema.json`
changes with it.

### Retired config keys

`orchestration.panel_size`, `review.anthropic_specialist`, `intent.halt_action`, `intent.doc_paths` and
`intent.skip_trivial_check` print the one-line retired-key notice `review_mode` uses, then are ignored.

## What retires

- **Agents (17):** `alignment`, `anthropic`, `api-contract`, `archaeology`, `consistency`, `correctness`,
  `efficiency`, `latent-hazard`, `reuse`, `security`, `style`, `test-adequacy`, `test-quality` and `ui` reviewers;
  `code-analysis`; `panel-reviewer`; `panel-writer`. **Kept:** `comment-editor`, `eslint`, `housekeeper`,
  `jbinspect`, `ruff`, `trivy`; **new:** `native-reviewer`.
- **Includes:** `intent-ledger.md`, `panel-concern-brief.md`, `specialist-context.md`, `severity-definitions.md`
  (only retired agents read them), and `version-freshness-cookbook.md` if PR B finds no reader. `verdict-rubric.md`
  and `review-pipeline.md` are rewritten; the generated-region families shrink with them.
- **review-core.js:** the panel (vote, tally, clustering, tiers, rubric, writer, seat names), the hybrid adapter,
  the lightweight bundle, `routeFinding` and tractability, `DISPATCH_RANK` (five fast static agents do not
  oversubscribe the pool).
- **Tests:** the panel, hybrid, lightweight and Phase 0 suites; the LLM-specialist fixtures and A/B corpus; the
  deletion-detection tests. The per-agent A/B harness stays for the static specialists. PR B lists each removal
  with the reason.
- **Prose:** Phase 0, Phase 0.7, Step 3, the Stage 2 "full agent team" text, the README's specialist sections.

## What we lose

- **Security review of dependencies.** `security-reviewer`'s version-safety check (#6a) was the path from a stale
  version with a known advisory to the verdict. Native does not look up advisories. A follow-up can add an OSV
  lookup to the housekeeper engine; until then trivy covers IaC only.
- **UI and accessibility review** (`ui-reviewer`). The eval never measured it.
- **The near-miss tuning.** The suite was tuned not to flag the sanity set's near-misses; native flags three as
  must-fix. Watched organically (decision 3).
- **Determinism of the finder.** Native's prompt changes with the CLI. `cli_version` in the log is the audit trail.

## PR order

0. **Housekeeping: none.** Checked 2026-11-26: Actions and runners are current (housekeeper engine), and the repo
   has no package manifests.
1. **Spikes S1–S3.** Results appended to this spec; they pick route C, F1 or F2.
2. **Settings (`~/.claude`, private, direct to `main`).** Remove `code-review` from `skillOverrides` in
   `settings.json.tmpl` (via `__remove__`), apply, run the seed screen. Before PR A's live check.
3. **PR A: thin pipeline.** `review-core.js`, `native-reviewer`, the pipeline prose and both hosts, the schema,
   the verdict rubric, the retired-key notices, the README's architecture section. Unit tests for the normaliser,
   the guards and the verdict; live checks on a pinned local diff by direct `review-core` dispatch: a planted-bug
   fixture (native and ruff findings on the same lines merge) and one fixture whose CLAUDE.md rule exists only in
   `~/.claude/CLAUDE.md` (dropped, logged).
4. **PR B: retirement.** Delete what PR A left unreferenced. `tests/run.sh` and the cross-reference checks prove
   nothing dangles.
5. **PR C: eval check.** A `thin` arm (`/pre-review` on the thin suite) on the 12-PR decision set, three runs, about
   $45 plus judging. Pass: thin − native bug and rule recall lower bounds above −5 pp and noise within ±5 pp at the
   point estimate, i.e. wrapping native costs it nothing. Results appended to the eval doc. **The spend needs the
   user's approval.**
6. Then step 5 (portability). The read-only reviewer hook now covers six agents, and "one `PLUGIN_ROOT`
   mechanism" may have no consumer left; re-scope both then.

## Tests

- `tests/run.sh`: `native` in the dispatch list; no agent, include or test refers to a retired file; the
  remaining generated regions are current.
- Unit tests beside the existing `review-core.js` ones: the native-to-finding mapping (each severity, a summary
  with and without `Fix:`); the personal-rule filter (`~/.claude/CLAUDE.md`, an absolute path, a repo CLAUDE.md
  kept); the anchor routes; the static existence guard per tool; each verdict row, including native not running;
  `skipped` and `failed` from `native-reviewer`; the retired-key notices.
- Live checks as in PR A; one `/address-pr-comments` run on a scratch PR the thin suite reviewed.

## Assumptions

- Decisions 3, 5, 8 and 9 above.
- Native's JSON array, as seen in the eval traces, is the contract S1 captures. If native moves to the
  ReportFindings tool in this host, the agent reads that instead; the schema is the same shape.
- The 12-PR, three-run check in PR C is enough to show the wrapper does no harm. It is not a new keep-or-switch
  decision.

## Out of scope

- Any LLM filter or verifier on native's output (decision 3).
- An advisory lookup in the housekeeper (follow-up).
- Incremental re-review, atomic posting, suggestion blocks and the rest of the backlog.
- `claude-security` in the pipeline (unchanged from the 2026-11-23 spec).
