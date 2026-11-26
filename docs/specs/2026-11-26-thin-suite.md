# Thin suite: Anthropic's review as the finder

Status: reviewed 2026-11-26 (three-lens spec panel), amended. Step 4b of the code-review-suite overhaul, between
the eval (step 4) and portability (step 5).

## Goal

The suite stops doing its own LLM bug finding. Anthropic's bundled `/code-review` finds the issues; the suite keeps
what the eval showed native lacks or never measured:

- the static analysers (ruff, eslint, jbinspect, trivy) and the housekeeper;
- the GitHub posting flow: one review with a verdict, inline comments, the marker, the wording pass;
- `/address-pr-comments` and self-re-review;
- `/pre-review` for local changes.

The LLM specialists, the panel and everything that only they consume are retired. The result should cost about a
third of today's review, finish in about half the time, and pick up Anthropic's improvements to how `/code-review`
finds issues without our changing any prompt. The one standing cost is native's output format: the suite binds to
its JSON array, so a format change surfaces as a failed native run (no verdict) and needs a re-mapping in
`review-core`.

## Background

- **The eval** ([`docs/evals/2026-11-26-review-eval.md`](../evals/2026-11-26-review-eval.md), PR #147), 28 PRs,
  native − suite: bug recall +4.2 pp [+1.1, +7.4], rule recall +9.0 pp [+0.8, +18.6], noise −2.4 pp
  [−17.9, +13.1], cost 0.29×, wall-clock 1.9 against 3.8 minutes. On 12 PRs the two finders caught the same issues
  (76 issues: 48 both, 25 neither, 1 suite only, 2 native only), so keeping any of our LLM specialists beside
  native adds little. The hybrid arm gained nothing at 1.71× the cost. The owner chose native plus a thin suite on
  2026-11-26.
- **What native is.** The bundled skill (CLI 2.1.332) is a forked skill. At `high` it runs four finder angles
  (line-by-line, removed behaviour, cross-file callers, CLAUDE.md conventions) in its own context, dedups without
  verifying ("dedup (no verify)"), and returns at most 10 findings as a JSON array of
  `{file, line, summary, failure_scenario, severity}`, where `severity` is `important`, `nit` or `pre_existing`
  and `summary` ends with `Fix: …` (seen in the eval's native traces). `--comment` posts the findings as inline
  PR comments; `--fix` applies them. The prompt is built into the CLI and changes between releases.
- **Native reads the user's CLAUDE.md.** Its conventions angle says the user-level `~/.claude/CLAUDE.md` governs
  too when the session has put it in context. PR #138 made the suite judge only against the plugin and the
  reviewed repo (`includes/rule-sources.md`), so a personal rule never becomes a finding on someone else's PR. The
  eval could not see this: its child sessions had a temporary home with no user CLAUDE.md.
- **Native cannot be called by the model today.** `skillOverrides.code-review` is `user-invocable-only`
  (`~/.claude` 146073a). The 2026-11-23 spike S1 showed a Workflow agent calling Skill on it gets a tool error.
- **The panel was also the static analysers' existence check.** In PR #106 jbinspect reasoned its way to a
  confidence-100 Critical ("missing global usings") that its tool never reported; the panel voted it false.
  Every static agent caps its tool's top tier at `Important` unless the rule ID is on that agent's
  `Critical-allow-list` (`includes/static-analysis-context.md` §10), and jbinspect's list is empty
  (`agents/jbinspect-reviewer.md:113`). So that Critical was invalid by construction.
- **Noise.** On the suite-tuned sanity set native reported three near-miss patterns (api-contract, reuse, silent
  failure) as must-fix. The decision-set noise interval is too wide to rule a 10-point loss in or out.

## Decisions

Those marked **assumption** are defaults to confirm in review.

1. **Native's findings reach GitHub through our renderer, not `--comment`.** One review per run with a verdict,
   the marker, co-located merging and `/address-pr-comments` all depend on it. `--comment` would post a second,
   unmarked set of comments with no verdict.
2. **Invoke the bundled skill, never a copy of it.** Copying the prompt, or reusing the hybrid adapter's
   `ANTHROPIC_REVIEWERS`, freezes a pipeline that Anthropic changes every few releases. The hybrid adapter also
   follows the old marketplace plugin, which is not what the eval measured.
3. **No LLM noise filter.** The panel did not buy lower noise (suite NP 71.4 % against native 69.0 %). The thin
   suite uses deterministic guards only (see Guards). If organic reviews show must-fix false positives, the first
   lever to try is a higher native effort level, which would be a new setting with its own check; a suite-side
   verifier comes back only with eval evidence. **Assumption.**
4. **Effort is fixed at `high`**, the level the eval measured. No setting.
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
   under the user's login and the pass shipped two days ago (PR #141). `failure_scenario` is posted verbatim and
   never sent to the editor, so the 60-word budget cannot cut the evidence. It costs one sonnet call per review.
   **Assumption.**
9. **Model invocation of `/code-review` is re-enabled** (owner's call, 2026-11-26). Every capture route needs it.
   The risks accepted: a session may start `/code-review` unprompted, including with `--fix` (edits the working
   tree) or `--comment` (unmarked comments under the user's login, which `/address-pr-comments` handles only with
   `--include-self`); and a request meant for `/review-gh-pr` may land on `/code-review`, losing the static
   analysers and the posting. Mitigations: the suite's skill descriptions lead with what distinguishes them, and
   `native-reviewer` never passes either flag. `/simplify` stays `user-invocable-only`.

## Spikes (run first, on a throwaway fixture repo, never a live PR)

Run in-session (headless child sessions are blocked by the auto-mode classifier), with `skillOverrides.code-review`
removed from `settings.json` directly for the duration. The spikes pick one capture route; only that route is
built.

| # | Question | Pass |
|---|---|---|
| S1 | Can a Workflow `agent()` of a new read-only `native-reviewer` type call Skill `code-review` with `high <target>` and return native's array, schema-bound, with nothing posted? Record: whether `~/.claude/CLAUDE.md` is in that agent's context; which model native's finders ran on; native's wall-clock. | Same findings shape as the eval's native arm; no GitHub writes |
| S2 | Which `<target>` makes native review exactly the pinned range, and read file contents from the review worktree, not the session's checkout? Cases: PR mode (`merge-base..PR head` in the Phase -0.5 worktree, including a cross-repo review from Phase -1); local `/pre-review` (HEAD in place, with working-tree changes); `EMPTY_TREE` mode; a `Path scope:`. Candidates: a base SHA, a branch name, the PR URL, a path argument. | Native's `git diff` covers exactly the range, and its cross-file reads open the worktree's files |

- **Route C (preferred, S1 and S2 pass).** `review-core` dispatches `native-reviewer` in parallel with the static
  specialists. One Workflow, one sealed bundle, the single-path guarantee kept.
- **Route F1 (S1 fails, or S2 fails only for the agent's working directory).** The main session, in the review
  worktree, calls Skill `code-review` before Step 3.5 and passes the array to `review-core` as
  `args.nativeFindings`. `review-core` validates it in code against the same schema as route C (array, keys,
  severity enum) and treats anything else, or a failed Skill call, as native not running. Native then runs before
  the static analysers instead of beside them (about a minute longer), and the user CLAUDE.md is certainly in its
  context.
- **Neither captures:** stop and re-spec. Letting native post with `--comment` beside a separate suite review is a
  different design.

## Design

### Pipeline

1. Phase -1 (target repo), Phase -0.5 (worktree), Phase 0.55 (branch freshness), Phase 0.6 (CI gate): unchanged.
2. Step 1 (base), Step 2 (diff measurement) and Step 2.5 (`$CHANGED_LINES`): unchanged. Detection keeps only the
   flags a kept specialist reads: `csharp`, `js`, `py`, `iac`, `housekeeping`. `ui`, `tests`, `production`,
   significant-deletion and security-area detection retire.
3. Step 2.9 (agent prompt) keeps only what the static specialists read.
4. Step 3 (route) retires. Step 3.5 calls `review-core` with the same args minus `route`, `intentLedger`,
   `panelSize`, `panelBrief`, `anthropicSpecialist` and `selfReReview` (its only consumer was the alignment
   filter), plus `nativeTarget` (computed and validated in prose from S2's answer, never by `review-core`'s
   agents). The bare-command guard switches from `route` to `nativeTarget`.
5. `review-core`: dispatch `native` and the conditional static specialists in parallel; normalise; guard;
   compute the verdict; wording pass; render. Phases: `dispatch`, `assemble`, `voice`.

### The native specialist (route C)

- **Agent:** `code-review-suite:native-reviewer`. Tools `Skill`, `Read`, `Grep`, `Glob`, `Bash`; no `Write`,
  `Edit` or `Agent`. A `*-reviewer` name, so reviewer-guard blocks mutating git. Its model is the one S1 records
  for the eval's native arm.
- **Dispatch:** `stallMs: 600000`. The wrapper is silent while the skill runs, and the sandbox's default watchdog
  drops a silent agent after 180 s (`review-core.js` panel comment); the eval's mean native run was 1.9 minutes.
- **Prompt:** call Skill `code-review` with the args string `review-core` built (`high ${nativeTarget}`),
  verbatim; never add `--comment` or `--fix`; return native's array unchanged. If S1 finds the user CLAUDE.md in
  the agent's context, the prompt also carries `rule-sources.md` (personal instructions never decide a finding);
  see Guards.
- **Schema:** `{status, statusReason?, findings: [{file, line, summary, failure_scenario, severity}]}`, status
  `ok | failed`, severity `important | nit | pre_existing`. `review-core` maps it in code, so no model decides
  the mapping.
- **Not running:** any non-`ok` result (skill disabled, error, timeout) is "native did not run", with
  `statusReason` shown in the body note.

### Normalisation (in code)

| Native | Finding |
|---|---|
| `severity: important` | `Important`, blocking |
| `severity: nit` | `Suggestion` |
| `severity: pre_existing` | `Suggestion`, `annotation: pre-existing`, never blocking |
| `summary` before `Fix:` | `description` |
| `summary` from `Fix:` on | `suggested_fix` (`""` when absent) |
| `failure_scenario` | rendered verbatim under the description; not editable |
| `file`, `line` | as given; the anchor routes below decide where it posts |

`confidence` leaves the finding shape, the log and the rendering; nothing reads it once the panel is gone. A
comment's first line is the severity in bold, plus `Pre-existing, not blocking` when annotated; the "fix in this
PR" and "raise as a follow-up" suffixes go with `routeFinding`.

### Guards (in code)

- **Personal rules, best effort, only if needed.** If S1 shows the user CLAUDE.md is not in native's context, this
  guard is not built and PR #138's rule holds by construction. If it is in context (always under F1), two layers
  apply, and neither is complete: the wrapper prompt carries `rule-sources.md`, and a native finding whose
  `failure_scenario` names as its rule source a CLAUDE.md path that is not repo-relative (starts with `~/` or `/`)
  is dropped and logged as `filtered: rule-source`. A finding that only mentions such a path, for example a change
  to `rule-sources.md`, is kept. A paraphrased personal rule with no citation gets through; the PR A live check
  measures how often.
- **Anchors** (existing logic, now one function for every finding): file not in the diff, so the body; line not a
  changed line, so file-level; otherwise inline. Housekeeper findings stay exempt and go to the freshness table.
  Under `/pre-review` with a `Path scope:`, a native finding outside the scope goes to an "Outside the path scope"
  section of the local report, unless S2 finds a target form that scopes native itself.
- **Static severity.** A static finding labelled `Critical` whose `rule_id` is not on its tool's
  `Critical-allow-list` is invalid: it posts as non-blocking with its label and is logged `filtered:
  severity-unreachable`. This would have caught the PR #106 case. The allow-lists are copied into `review-core.js`
  beside `STATIC`, and a structural test checks the copy against each agent file. A fabricated `Important` is not
  caught; that residual risk is accepted (one recorded case, which was a Critical).

### Verdict (PR mode, first match)

| # | Condition | Verdict |
|---|---|---|
| 1 | Native did not run | `NONE` |
| 2 | Any blocking finding (native `important`, or a static `Critical` or `Important` that passed the severity guard) | `REQUEST_CHANGES` |
| 3 | Otherwise | `APPROVE` |

`COMMENT` stays reachable only as the user's override at the Class A prompt. `verdict-rubric.md` is rewritten to
this table, and still states that `review-core.js` is the source of truth.

**Host changes (`/review-gh-pr` Stage 6).** `NONE` today means "lightweight: present and stop" (`SKILL.md:1502`).
It now means native did not run: the host shows the body and the reason and asks once, "post the static findings
as a `COMMENT` review" or "stop" (default stop); it never submits `APPROVE`. The Class A templates replace tier
counts with counts by severity and source ("native", "ruff", …) and drop "panel-proposed".

### Posting and body

- Inline comments, file-level comments, body notes and co-located merging (`groupColocated`, three lines) are
  unchanged. Native and static findings on the same lines merge into one thread.
- Body: verdict headline with the rubric reason, the finding index, body notes, the Dependency Freshness table, the
  marker. The Panel Assessment and the pruned-findings line go, with the panel writer.
- The local report keeps the same parts without the headline.
- Each finding carries its source (`native`, `ruff`, …) in the log and in the local report; posted comments do not
  name it.

### Logging

- `log.meta` drops `orchestration_mode`, `panel_size` and `anthropic_specialist` and gains `finder: "native"` and
  `cli_version`, so a later analysis can tie a finding to the native prompt that produced it.
- `log.cogs` keeps native's raw array before normalisation.
- Each record in `log.findings` drops `tier` and `confidence`, gains `source` and `blocking`, and keeps
  `verdict_relevant`, which now equals `blocking`. Findings a guard filtered or demoted get a record with
  `filtered: rule-source | severity-unreachable`. `finding-schema.json` changes to match.

### Retired config keys

`orchestration.panel_size`, `review.anthropic_specialist` and every `intent.*` key (`doc_paths`, `prompt_paths`,
`halt_action`, `skip_trivial_check`, `trivial_paths.allow_extensions`, `trivial_paths.exclude_paths`) join
`review_mode` in one retired-key notice that names whichever of them it finds, then they are ignored.

## What retires

- **Agents (17):** `alignment`, `anthropic`, `api-contract`, `archaeology`, `consistency`, `correctness`,
  `efficiency`, `latent-hazard`, `reuse`, `security`, `style`, `test-adequacy`, `test-quality` and `ui` reviewers;
  `code-analysis`; `panel-reviewer`; `panel-writer`. **Kept:** `comment-editor`, `eslint`, `housekeeper`,
  `jbinspect`, `ruff`, `trivy`; **new:** `native-reviewer`.
- **Includes:**
  - `intent-ledger.md` and `panel-concern-brief.md`.
  - `specialist-context.md` and `severity-definitions.md`, after PR A folds the parts the static path still reads
    into `static-analysis-context.md`: target repo, base and `$CHANGED_LINES` resolution (§0–§1 point at
    specialist-context today), and the severity definitions (§7). The sync tests that compare the pipeline with
    these files (`tests/lib/test_sync_notes.sh`) are re-pointed in the same PR.
  - `version-freshness-cookbook.md`: nothing reads it; the comment at `bin/housekeeper-freshness:669` that names
    it is updated.
  - `verdict-rubric.md` and `review-pipeline.md` are rewritten; the generated-region families shrink with them.
- **Agent text:** the ruff and eslint agents' references to `security-reviewer` (`ruff-reviewer.md:76`,
  `eslint-reviewer.md:76`) are reworded; `comment-editor.md` and `EDITOR_SCHEMA` lose the assessment.
- **review-core.js:** the panel (vote, tally, clustering, tiers, rubric, writer, seat names), the hybrid adapter,
  the lightweight bundle, `routeFinding` and tractability, `DISPATCH_RANK` (five fast static agents do not
  oversubscribe the pool).
- **Tests:** the panel, hybrid, lightweight and Phase 0 suites; the LLM-specialist fixtures and A/B corpus; the
  deletion-detection tests. The per-agent A/B harness stays for the static specialists. PR B lists each removal
  with the reason.
- **Prose:** Phase 0, Phase 0.7, Step 3; the Stage 2 "full agent team" text; Phase 0 and the lightweight path
  under self-re-review (`SKILL.md:106-117`); the Playwright step for UI findings (`SKILL.md:1254`,
  `pre-review.md:1128`); the README's specialist sections.

## What we lose

- **Security review of dependencies.** Two paths took a stale version with a known advisory to the verdict:
  `security-reviewer`'s version-safety check (#6a) and a panelist raising the upgrade. Both go, and native does
  not look up advisories. A follow-up can add an OSV lookup to the housekeeper engine; until then trivy covers IaC
  only.
- **UI and accessibility review** (`ui-reviewer`). The eval never measured it.
- **The near-miss tuning.** The suite was tuned not to flag the sanity set's near-misses; native flags three as
  must-fix. Watched organically (decision 3).
- **Determinism of the finder.** Native's prompt changes with the CLI. `cli_version` in the log is the audit trail.

## PR order

0. **Housekeeping: none.** Checked 2026-11-26: Actions and runners are current (housekeeper engine), and the repo
   has no package manifests.
1. **Spikes S1–S2.** Results appended to this spec; they pick route C or F1.
2. **Settings (`~/.claude`, private, direct to `main`).** Remove `code-review` from `skillOverrides` in
   `settings.json.tmpl` (via `__remove__`), apply, run the seed screen. Before PR A's live check.
3. **PR A: thin pipeline.** `review-core.js`, `native-reviewer` (route C only), the pipeline prose and both hosts,
   the Stage 6 host changes, the folded includes, the schema, the verdict rubric, the retired-key notice, the
   README's architecture section. Live checks on a pinned local diff by direct `review-core` dispatch: a
   planted-bug fixture (native and ruff findings on the same lines merge); if the personal-rule guard is built, a
   fixture with one rule only in `~/.claude/CLAUDE.md` and one paraphrased personal rule (count what gets
   through).
4. **PR B: retirement.** Delete what PR A left unreferenced. `tests/run.sh` and the cross-reference checks prove
   nothing dangles.
5. **PR C: eval check.** Depends on PR #146 (the harness) merging. A `thin` arm (`/pre-review` on the thin suite)
   on the 12-PR decision set, three runs, about $45 plus judging. The harness's `route-full` grader reads the
   retired `route` argument, so the thin arm gets its own validity graders (native ran, plugin under test).
   What it tests: whether native run inside the suite finds what native run directly found. The pass rule is
   computed on native-sourced findings only: thin − native bug and rule recall lower bounds above −5 pp. Noise is
   reported, not gated: at 12 PRs it is underpowered, and the static findings the suite adds on purpose would
   count against it. Results appended to the eval doc. **The spend needs the owner's approval.**
6. Then step 5 (portability). The read-only reviewer hook now covers six agents, and "one `PLUGIN_ROOT`
   mechanism" may have no consumer left; re-scope both then.

## Tests

- `tests/run.sh`: `native` in the dispatch list; no agent, include or test refers to a retired file; the
  remaining generated regions are current; the `Critical-allow-list` copy in `review-core.js` matches each static
  agent.
- Unit tests beside the existing `review-core.js` ones: the native-to-finding mapping (each severity, a summary
  with and without `Fix:`); the anchor routes, including path scope; the static severity guard; each verdict row,
  including native not running; a non-`ok` `native-reviewer` result; under F1, a malformed `nativeFindings`; the
  personal-rule filter if built (`~/.claude/CLAUDE.md` as rule source dropped, a repo CLAUDE.md kept, a mention
  of a user-level path kept).
- Live checks as in PR A; one `/address-pr-comments` run on a scratch PR the thin suite reviewed.

## Assumptions

- Decisions 3, 5 and 8 above.
- Native's JSON array, as seen in the eval traces, is the contract S1 captures. If native moves to the
  ReportFindings tool in this host, the agent reads that instead; the schema is the same shape.
- The 12-PR, three-run check in PR C is enough to show the wrapper does no harm. It is not a new keep-or-switch
  decision, and a one-fixture match in S1 does not replace it, since native varies from run to run.

## Out of scope

- Any LLM filter or verifier on native's output (decision 3), and any native effort setting.
- An advisory lookup in the housekeeper (follow-up).
- Incremental re-review, atomic posting, suggestion blocks and the rest of the backlog.
- `claude-security` in the pipeline (unchanged from the 2026-11-23 spec).
