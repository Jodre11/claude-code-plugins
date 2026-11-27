# Thin suite: Anthropic's review as the finder

Status: reviewed 2026-11-26 (three-lens spec panel), amended; spikes run 2026-11-27 (route C). Step 4b of the
code-review-suite overhaul, between the eval (step 4) and portability (step 5).

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
  (`~/.claude` 146073a). The 2026-11-23 spike S1 showed a Workflow agent calling Skill on it gets a tool error;
  with the override lifted, this spec's S1 succeeds (see Spike results).
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

### Spike results (2026-11-27, CLI 2.1.332): route C, with text capture

Run in-session on a throwaway fixture with no remote (base `main`, a `feature` branch with an off-by-one, a
project-rule `print` and a rule only in `~/.claude/CLAUDE.md`; a `feature2` branch on top of it; detached
worktrees at both heads, the session checkout left on `main`). Workflows `wf_0eeb9f7f-c3e`, `wf_cf06f406-80d` and
`wf_4f8f04f4-155`, eight native runs, all with `agentType: general-purpose` wrappers.

**S1: passes, but not with a schema.**

- With the override lifted (it applies live, without a restart), a Workflow agent's Skill call to `code-review`
  succeeds. Native forks as a `general-purpose` subagent at spawn depth 2; the depth-1 limit on `Agent` does not
  apply to a forked skill.
- **A schema on the wrapper swallows the result.** The fork inherits the wrapper's `StructuredOutput` tool and
  schema, fills it in itself, and the wrapper's Skill call returns only `Skill execution completed`. With no
  schema, the Skill result is native's text, ending in a fenced `json` array of exactly the eval's shape
  (`file, line, summary, failure_scenario, severity`, `summary` ending `Fix: …`). One wrapper dropped the
  `Skill "code-review" completed` header and kept the rest, so the parse must not depend on the header.
- **The user CLAUDE.md is in native's context**, so the personal-rule guard is built. Native flagged both planted
  personal rules (four parameters on one line; a public function with no doc comment) as `nit`s whose
  `failure_scenario` names `~/.claude/CLAUDE.md`. It also cited the project rule by the worktree's **absolute**
  path (`/tmp/…/fx-wt/CLAUDE.md`), which the guard as first written would have dropped.
- **Model:** native ran on the wrapper's model (the session model, `claude-opus-5-5`, the same as the eval's native
  arm); the fork is spawned unnamed and inherits. So `native-reviewer` must not pin a smaller model.
- **Wall-clock:** 30–55 s per native run on the two-file fixture; the eval's mean on real PRs was 1.9 minutes.
- No GitHub writes (no remote), no file edits.

**S2: passes with `<worktree path> <range>`.** Native's own target rule is "a PR number, branch name, or file path";
a path plus a git range is honoured as written.

| Target args | Native ran | Result |
|---|---|---|
| `high <base SHA>` (cwd = session repo) | `git -C <session repo> show <sha>` | failed: the SHA is not in the session's repo |
| `high` (cwd = session repo) | `git diff origin/HEAD...HEAD` | reviewed the session's own branch, not the worktree |
| `high <worktree>` | `git -C <worktree> diff main...HEAD` | right files, but the base is guessed (`origin/HEAD`, then `main`) |
| `high <worktree> <feature>...HEAD` (base not `main`) | `git -C <worktree> diff <feature>...HEAD` | exactly the pinned range |
| `high <worktree> <base>...HEAD -- lib/other.py` | `git -C <worktree> diff <base>...HEAD -- lib/other.py` | range and path scope honoured |
| `high <worktree> <empty tree> HEAD` | `git -C <worktree> diff <empty tree> HEAD` | whole tree, two-dot form honoured |
| `high <worktree> <feature>...HEAD`, tree dirty | the range, then the working tree | **also reviewed the uncommitted change** ("in scope under Phase 0") |

Every cross-file read opened the worktree's files by absolute path, whatever the agent's cwd; a `cd` in the
wrapper does not persist (the path is outside the session's working directories) and is not needed. A cross-repo
review is the same mechanism (a worktree of another repo), so it was not run against a live PR.

Two native behaviours to carry into the design: an explicit range does not exclude uncommitted changes (see
Guards), and native keeps two pieces of state between runs, "with no level given, it reuses the level you typed
last" and a sticky `--max-findings` choice. The suite always passes `high`; it does not pass `--max-findings`, so a
user's sticky choice applies (**assumption**: resetting it with `--max-findings default` would change the user's
own setting).

## Design

### Pipeline

1. Phase -1 (target repo), Phase -0.5 (worktree), Phase 0.55 (branch freshness), Phase 0.6 (CI gate): unchanged.
2. Step 1 (base), Step 2 (diff measurement) and Step 2.5 (`$CHANGED_LINES`): unchanged. Detection keeps only the
   flags a kept specialist reads: `csharp`, `js`, `py`, `iac`, `housekeeping`. `ui`, `tests`, `production`,
   significant-deletion and security-area detection retire.
3. Step 2.9 (agent prompt) keeps only what the static specialists read.
4. Step 3 (route) retires. Step 3.5 calls `review-core` with the same args minus `route`, `intentLedger`,
   `panelSize`, `panelBrief`, `anthropicSpecialist` and `selfReReview` (its only consumer was the alignment
   filter), plus `nativeTarget`, built in prose from values the pipeline already validated, never by
   `review-core`'s agents: `"$REPO_DIR" "$BASE"..."$HEAD_SHA"`, or `"$REPO_DIR" "$BASE" "$HEAD_SHA"` under
   `EMPTY_TREE_MODE`, with ` -- <path>…` appended for a `Path scope:` (S2). `review-core` re-checks the shape in
   code (an absolute path, two 40-hex SHAs or the empty-tree SHA, no `--` flag before the scope) and treats a
   mismatch as native not running. The bare-command guard switches from `route` to `nativeTarget`.
5. `review-core`: dispatch `native` and the conditional static specialists in parallel; normalise; guard;
   compute the verdict; wording pass; render. Phases: `dispatch`, `assemble`, `voice`.

### The native specialist (route C)

- **Agent:** `code-review-suite:native-reviewer`. Tools `Skill`, `Read`, `Grep`, `Glob`, `Bash`; no `Write`,
  `Edit` or `Agent`. A `*-reviewer` name, so reviewer-guard blocks mutating git. No `model` in its frontmatter:
  native's fork runs on the wrapper's model (S1), so the agent inherits the session model, as the eval's native
  arm did.
- **Dispatch:** `stallMs: 600000`. The wrapper is silent while the skill runs, and the sandbox's default watchdog
  drops a silent agent after 180 s (`review-core.js` panel comment); the eval's mean native run was 1.9 minutes.
- **Prompt:** call Skill `code-review` once with the args string `review-core` built (`high ${nativeTarget}`),
  verbatim; never add `--comment`, `--fix` or `--max-findings`; no other tool; the final message is the Skill
  result verbatim, or `SKILL_ERROR: <text>`. The prompt also carries `rule-sources.md` (personal instructions
  never decide a finding), since S1 found the user CLAUDE.md in native's context; see Guards.
- **No agent schema** (S1: a schema leaks into the fork and the result is lost). `review-core` parses the text in
  code: the last fenced `json` block that parses as an array, each element checked for the five keys, string
  `file`, positive integer `line` and severity `important | nit | pre_existing`; extra keys are dropped. An empty
  array is a valid result. The mapping is in code, so no model decides it.
- **Not running:** `SKILL_ERROR`, no parseable array, a failed element check, a null agent result (timeout) or a
  bad `nativeTarget` is "native did not run", with the reason shown in the body note. A partly valid array is
  rejected whole rather than trimmed, so a format change is never half-read.

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

- **Personal rules, best effort** (built: S1 found the user CLAUDE.md in native's context). Two layers, neither
  complete: the wrapper prompt carries `rule-sources.md`, and a native finding whose `failure_scenario` cites as
  its rule source a CLAUDE.md outside the reviewed repo is dropped and logged as `filtered: rule-source`. Outside
  means a path starting `~/`, or an absolute path not under `$REPO_DIR` (S1: native cites the project's own
  CLAUDE.md by the worktree's absolute path, which must be kept). A finding that only mentions such a path, for
  example a change to `rule-sources.md`, is kept. A paraphrased personal rule with no citation gets through; the
  PR A live check measures how often. In S1 native cited `~/.claude/CLAUDE.md` every time it used a personal rule.
- **Anchors** (existing logic, now one function for every finding): file not in the diff, so the body; line not a
  changed line, so file-level; otherwise inline. Housekeeper findings stay exempt and go to the freshness table.
  Native honours a `Path scope:` itself (S2), and a stray finding outside the scope lands in the body by the
  file-not-in-diff rule, so no separate section is needed.
- **Uncommitted changes.** Native adds the working tree to any range (S2). PR mode reviews in the Phase -0.5
  worktree, which is clean, so nothing changes there. In `/pre-review` (in place) and when Phase -0.5 is skipped,
  a native finding on an uncommitted line is outside `$CHANGED_LINES` and goes file-level or to the body by the
  anchor rules. **Assumption:** that is wanted for a pre-commit review, and needs no handling of its own.
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
1. **Spikes S1–S2. Done 2026-11-27:** route C, text capture (see Spike results).
2. **Settings (`~/.claude`, private, direct to `main`).** Remove `code-review` from `skillOverrides` in
   `settings.json.tmpl` (via `__remove__`), apply, run the seed screen. Before PR A's live check.
3. **PR A: thin pipeline.** `review-core.js`, `native-reviewer` (route C), the pipeline prose and both hosts,
   the Stage 6 host changes, the folded includes, the schema, the verdict rubric, the retired-key notice, the
   README's architecture section. Live checks on a pinned local diff by direct `review-core` dispatch: a
   planted-bug fixture (native and ruff findings on the same lines merge); a fixture with one rule only in
   `~/.claude/CLAUDE.md` and one paraphrased personal rule (count what gets through the personal-rule guard).
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
  including native not running; the text parse (the array with and without the `Skill … completed` header and
  with prose before it, `SKILL_ERROR`, no array, an element with a bad severity or a missing key, an empty array);
  the `nativeTarget` shape check (each of the three forms, and a rejected flag); the personal-rule filter
  (`~/.claude/CLAUDE.md` as rule source dropped, a repo CLAUDE.md cited by repo-relative and by absolute
  `$REPO_DIR` path kept, an absolute path outside `$REPO_DIR` dropped, a mention of a user-level path kept).
- Live checks as in PR A; one `/address-pr-comments` run on a scratch PR the thin suite reviewed.

## Assumptions

- Decisions 3, 5 and 8 above.
- Native's fenced JSON array, as seen in the eval traces and S1, is the contract. If native moves to a findings
  tool (the main session here offers `ReportFindings`; a schema-bound wrapper exposes `StructuredOutput`, which
  native then fills instead of answering), the capture breaks loudly as "native did not run" and is re-mapped.
- The 12-PR, three-run check in PR C is enough to show the wrapper does no harm. It is not a new keep-or-switch
  decision, and a one-fixture match in S1 does not replace it, since native varies from run to run.

## Out of scope

- Any LLM filter or verifier on native's output (decision 3), and any native effort setting.
- An advisory lookup in the housekeeper (follow-up).
- Incremental re-review, atomic posting, suggestion blocks and the rest of the backlog.
- `claude-security` in the pipeline (unchanged from the 2026-11-23 spec).
