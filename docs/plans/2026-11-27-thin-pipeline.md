# Plan: PR A — thin pipeline

Implements step 3 of [the thin-suite spec](../specs/2026-11-26-thin-suite.md) (PR #148): `review-core` stops running
LLM specialists and the panel, and runs Anthropic's bundled `/code-review` (route C, text capture) beside the static
analysers. PR B deletes what this PR leaves unreferenced; PR C is the eval check.

Branch `feat/thin-pipeline`, stacked on `feat/embed-panel-brief` (#145); rebase onto `main` once #145 merges, then
retarget the PR. `tests/run.sh` stays green at every commit.

## Assumptions

Defaults chosen where the spec is silent; each is listed in the PR body.

- **A1. Tests in PR A vs PR B.** PR A rewrites or deletes every test that asserts on behaviour PR A changes: the
  panel, hybrid and lightweight paths of `review-core.js`, Phase 0 and 0.7 text in the pipeline. Agent, include,
  fixture and A/B-corpus files left unreferenced stay on disk with their file-only structural tests, and PR B
  deletes them. Without this split, PR A cannot keep `tests/run.sh` green.
- **A2. Local-mode base.** In `/pre-review`, `$BASE` can be a branch name. Step 3.5 resolves it to a commit with
  `git -C "$REPO_DIR" rev-parse --verify "$BASE^{commit}"` (validated 40-hex) for `nativeTarget` only. The spec's
  shape check requires SHAs.
- **A3. `nativeTarget` consistency.** Besides the shape, `review-core` checks that the path equals `repoDir` and the
  head SHA equals `headSha`. A mismatch means native did not run.
- **A4. Path and scope tokens.** The worktree path must be absolute with no whitespace and no `..`. Scope tokens
  after ` -- ` use the pipeline's `$PATH_SCOPE` regex (`^[a-zA-Z0-9/_.\-*]+$`, no `..`, no leading `-`).
- **A5. Splitting `Fix:`.** `description` = `summary` before the first `Fix:`, trimmed. `suggested_fix` = the text
  after it, trimmed and without the `Fix:` label, because the renderer adds `**Suggested fix:**`.
- **A6. Citation versus mention** (personal-rule guard). The S1 traces cite a rule as `breaks the rule in <path>:`
  or `Breaks <path>:`. A finding is dropped only when the guard finds a CLAUDE.md path outside the repo (starting
  `~/`, or absolute and not under `repoDir`) followed by a colon. When the path is not followed by a colon, it
  counts as a citation only if preceded in the same sentence by `break`, `violat`, `rule`, `per ` or `against`.
  Every other occurrence is a mention and is kept.
- **A7. Trivy allow-list in code.** A rule-ID glob (`AVD-*-SECRET-*`), explicit IDs (`AVD-AWS-0017`,
  `AVD-GCP-0001`) and the title patterns. The finding shape has no title, so the title patterns are matched against
  `description`.
- **A8. Demoted static `Critical`.** It renders `**Critical** — not blocking (rule not on the tool's Critical
  allow-list)`.
- **A9. `NONE` in PR mode.** The bundle still carries the static comments. Its body headline reads `**COMMENT** —
  native review did not run (<reason>); static-analysis findings only`, because `COMMENT` is the only way it can
  be submitted. The bundle gains `native: { ran, reason }` and `counts` (by severity, by source, files). The host
  needs both for the Stage 6 note and the Class A templates without parsing the body.
- **A10. `cli_version`.** The sandbox cannot run commands, so Step 3.5 resolves it in prose (the first
  version-shaped token of `claude --version`, or `unknown`) and passes it as `cliVersion`.
- **A11. Static `confidence`.** `confidence` leaves the JSON `FINDING_SHAPE` (the spec). The §7 markdown format
  for standalone static runs keeps `Confidence: 100`, because the per-agent A/B parser is pinned to it.
- **A12. Folded text is plain text.** Base resolution, the `Changed lines:` grammar and the severity definitions
  are copied into `static-analysis-context.md` as plain text, kept in step by the existing sync tests (re-pointed),
  not as a generated region.
- **A13. Plan location.** Plans now live in `docs/plans/`, because the superpowers tree was dropped in #132.

## Live-check precondition

The installed plugin comes from GitHub `main`. Neither `code-review-suite:native-reviewer` nor this branch's
`review-core` resolves until the session loads the dev clone. Run the implementation session as
`claude --plugin-dir ~/Repos/claude-code-plugins/plugins/code-review-suite`. First check which copy loaded: the
agent list includes `native-reviewer`. If the installed copy shadows the dev one, stop and ask; don't edit
settings to work around it. Dispatch `review-core` by `scriptPath` from the dev clone (it is inside the working
directory), never by name, so the branch's script runs (memory: pre-fix verification needs direct dispatch).

## Tasks

### 1. `native-reviewer` agent, then smoke it (risk first)

The spike's wrappers were `general-purpose` (all tools). Nothing yet shows that a fork from a wrapper restricted to
`Skill, Read, Grep, Glob, Bash` still runs native's finders.

- New `plugins/code-review-suite/agents/native-reviewer.md`: frontmatter `name`, `description` (dispatched by
  review-core only), `tools: Skill, Read, Grep, Glob, Bash`, `background: true`, no `model`. Body:
  - The rule-sources block: paste the `BEGIN/END GENERATED from includes/rule-sources.md` markers and run
    `scripts/render-includes.py`.
  - Call Skill `code-review` exactly once, with the `Skill args:` line from the prompt, verbatim.
  - Never add `--comment`, `--fix` or `--max-findings`, and use no other tool.
  - The final message is the Skill result verbatim, or `SKILL_ERROR: <text>`.
  - Plain-text output is the result (no schema), so nothing may be added before or after it.
- `tests/lib/test_render_includes.sh`: add `agents/native-reviewer.md includes/rule-sources.md` to the expected
  copies.
- **Smoke (live):** a scratch Workflow (session temp dir) with one `agent()` of `agentType:
  'code-review-suite:native-reviewer'` and `stallMs: 600000`. It runs on a throwaway fixture repo under the session
  temp dir, with an off-by-one bug, and the args `high <fixture> <base>...<head>`. Pass: the result text ends in a
  fenced `json` array of the five keys, and nothing is written. Fail: stop and report. The fallback is spec route
  F1, which is a re-spec decision for the owner.
- Commit: `feat(code-review-suite): native-reviewer agent wrapping the bundled /code-review`.

### 2. `review-core.js`: the native capture, pure functions first

Add these as hoisted `function` declarations (TDZ: anything that runs before its definition must be a function,
not a `const`):

- `checkNativeTarget(target, repoDir, headSha)` returns `{ ok, reason }`. It accepts `<abs> <sha40>...<sha40>`,
  `<abs> <emptytree> <sha40>`, and either form followed by ` -- <scope>…` (A3, A4). The empty-tree SHA is
  `4b825dc642cb6eb9a060e54bf8d69288fbee4904`.
- `parseNativeText(text)` returns `{ ok, findings | reason }`.
  - `SKILL_ERROR:` anywhere at line start fails with its text.
  - Otherwise take every fenced `json` block and use the last one that `JSON.parse`s to an array.
  - Every element must have the five keys, a string `file`, a positive integer `line`, a string `summary` and
    `failure_scenario`, and a severity in `important | nit | pre_existing`.
  - Drop extra keys. One bad element rejects the whole array. `[]` is ok.
  - The parse never depends on a `Skill … completed` header.
- `normaliseNative(raw)` maps to findings `{ source: 'native', file, line, severity, description, suggested_fix,
  failure_scenario, blocking, annotation? }` per the spec's normalisation table (A5).
- `citesOutsideRule(scenario, repoDir)` implements A6. Fixtures: the S1 strings in
  `~/.claude/projects/-Users-jodre11-Repos-claude-code-plugins/175f9233-*/workflows/wf_4f8f04f4-155.json`,
  with the session path replaced by a neutral `/tmp/fx-repo`.
- `STATIC_CRITICAL_ALLOW` holds the per-tool allow-list copy beside `STATIC`. `staticCriticalAllowed(domain, f)`
  implements A7.

Unit tests: new `tests/lib/test_thin_core.sh`, and `tests/lib/_tc_runner.js` modelled on `_cv_runner.js`. The mock
`agent()` returns raw text for label `native`. Cases, all from the spec's Tests section:

- `parseNativeText`: the array with and without the header and with prose before it, `SKILL_ERROR`, no array, an
  element with a bad severity, an element with a missing key, and an empty array.
- `checkNativeTarget`: each of the three forms, a rejected `--flag`, and a path ≠ `repoDir`.
- `normaliseNative`: each severity, and a summary with and without `Fix:`.
- The personal-rule filter: `~/.claude/CLAUDE.md` as the rule source is dropped. A repo `CLAUDE.md` cited by
  repo-relative path and by an absolute `repoDir` path is kept. An absolute path outside `repoDir` is dropped. A
  mention of a user-level path is kept.

This commit adds the functions and tests only; nothing calls them yet.

### 3. `review-core.js`: the thin flow

Rewrite the top level and delete the retired machinery in the same commit:

- `meta.phases`: `dispatch`, `assemble`, `voice`. `description` and `whenToUse` describe native plus static.
- **Remove:**
  - `PANEL_BRIEF` (both generated-region markers);
  - `ANTHROPIC_*`, `RAISED_SHAPE`, `PANEL_SCHEMA` and `WRITER_SCHEMA`;
  - the lightweight branch, `CORE`, `DISPATCH_RANK` and the seat helpers;
  - `flattenFindings`, `checkQuorum`, `tallyVotes`, `clusterRaised`, `majorityOf`, `resolveTractability`,
    `routeFinding`, `mapSpreadToTierConfidence`, `applyRubric`, `panelVote`, `writerView` and `panelWrite`;
  - `runAnthropicPipeline`, `normalizeAnthropic`, `parseIssueLink`, `buildLightweightBundle`, `prunedLine` and
    `isVerdictRelevant`;
  - the `<n/a>` sentinel in `isFileless` (its only producer was alignment).
- Bare-command guard: `typeof nativeTarget !== 'string'`.
- Args: `agentPrompt, flags{csharp,js,py,iac,housekeeping}, reviewMode, base, headSha, emptyTreeMode, pathScope,
  tempDir, repoDir, changedLinesBlock, nativeTarget, cliVersion`.
- **Dispatch:** one `parallel()` over `native` (when `checkNativeTarget` passes) and the conditional static
  specialists.
  - Native: `agent(prompt, { label: 'native', phase: 'dispatch', agentType:
    'code-review-suite:native-reviewer', stallMs: 600000 })` with no schema, `.catch(() => null)`. The prompt is
    `Skill args: high ${nativeTarget}`, plus the trust-boundary line.
  - Static: unchanged, with `SPECIALIST_SCHEMA`.
- **Assemble (pure, in code):**
  1. Normalise native. Drop findings that cite a personal rule (`filtered: 'rule-source'`).
  2. Map static findings to `source: domain`. `blocking` is true for `Critical` or `Important`, except a
     non-allow-listed `Critical`, which becomes `blocking: false`, `filtered: 'severity-unreachable'` and still
     posts (A8).
  3. Housekeeper findings take `posting: 'table'`; everything else takes `posting: 'inline'`.
  4. Run one `anchorFinding(f, changedLines)` for every non-housekeeper finding. It is the old voted-path guard,
     lifted: a file not in the diff goes to the body (`file = ''`); a line not changed goes file-level
     (`line = 0`).
- **Verdict (PR mode):** native did not run → `NONE`; any `blocking` → `REQUEST_CHANGES`; otherwise `APPROVE`.
  Reasons: `native review did not run: <reason>` / `<n> blocking finding(s)` / `no blocking findings`.
- **Voice:** `voicePass` over native findings only, on `description` and `suggested_fix`. `failure_scenario` is
  never sent. Remove the assessment parameter and the `isAssessment` branch.
- **Render:**
  - `renderCommentBody`:
    - first line: the severity in bold, plus ` — Pre-existing, not blocking` or the A8 note;
    - then the description;
    - then `failure_scenario` verbatim;
    - then `**Suggested fix:**`;
    - then `reference`.
  - Unchanged: `groupColocated`, `renderComments`, `renderFindingIndex` (pointer always `↳ inline`),
    `renderBodyNotes` and `buildFreshnessSection`.
  - `buildBody`: the headline (A9 for `NONE`), the index, body notes, a native-not-run note when applicable,
    freshness, and the marker.
  - `buildLocalReport`: the same parts without the headline.
- **Bundle:** `{ verdict, bodyText, comments, native: { ran, reason }, counts, log }` (A9).
- **Log:**
  - `meta`: `{ base, head_sha, empty_tree_mode, path_scope, finder: 'native', cli_version }`;
  - `cogs`: `{ phase: 'round1', domain, output }` per static specialist, plus `{ phase: 'native', status, reason?,
    raw }`, where `raw` is native's array before normalisation;
  - `findings`: one record per finding, filtered ones included, `{ source, severity, blocking, verdict_relevant
    (= blocking), posting, annotation, filtered?, file, line, description, suggested_fix, failure_scenario? }`;
  - `voice`: as before.

Tests in `test_thin_core.sh`, end to end through `_tc_runner.js`:

- each verdict row, including each native-not-run cause (`SKILL_ERROR`, no array, bad element, null result, bad
  `nativeTarget`);
- the anchor routes, including path scope and a native finding on an uncommitted (unchanged) line;
- the static severity guard (allow-listed Critical blocks; non-listed posts non-blocking, logged);
- native and ruff on the same lines merge into one comment;
- the pre-existing annotation renders and never blocks;
- `NONE` still carries the static comments with the A9 headline;
- local mode has no headline and no marker;
- the log conforms to the updated schema.

### 4. Schema, editor and allow-list parity

- `includes/finding-schema.json`:
  - `finding` loses `confidence`;
  - the log record becomes the task 3 shape;
  - `cogs[].phase` becomes `round1 | native`;
  - `meta` drops `orchestration_mode`, `panel_size` and `anthropic_specialist`, and gains `finder` and
    `cli_version`;
  - `sealedBundle` gains `native` and `counts`.
- `FINDING_SHAPE` matches (parity test `test_inlined_schema_matches_canonical`).
- `EDITOR_SCHEMA` and `agents/comment-editor.md` lose the assessment.
- New structural test: each `STATIC_CRITICAL_ALLOW` entry equals the bullets under `## Critical-allow-list:` in its
  agent file. jbinspect's list is empty.

### 5. Rewrite or delete the `review-core` suites (A1)

Before deleting a test, check whether it asserts anything besides the retired path; move any such assertion to
`test_thin_core.sh`.

- **Rewrite against the new core:**
  - `test_output_presentation.sh`: the anchor ladder, body, freshness, local mode, co-located merging and log
    conformance. Drop the pruned-line, tier and assessment cases.
  - `test_comment_voice.sh`: keep the guard cases and the marker cases (PR, degraded → native-not-run, local);
    drop the assessment cases, the lightweight marker case and the assessment half of the editor-contract test.
  - `test_workflow_migration.sh`: keep schema validity, the workflow presence and extension, the host
    pre-approval, the bare invocation being inert, string args and null agent results. Drop the classic,
    intent-ledger-to-panel, panel stall budget and panel repo-dir/diff-file cases; add `native` `stallMs` and the
    absence of any schema on the native call.
  - `test_phase_efficacy.sh`: meta and cogs per the new phases; the reconstruction recipe re-pointed (task 6).
- **Delete:** `test_panel_review.sh`, `test_anthropic_hybrid.sh` and `test_panel_wiring.sh`, together with any
  runner helpers only they use.

Commit tasks 3–5 together if splitting would leave `tests/run.sh` red in between.

### 6. Fold the static path's includes

- `includes/static-analysis-context.md`:
  - §0 stops pointing at specialist-context (the mandate is already restated).
  - §1 gains the text it read from `specialist-context.md`: determine the target repository; determine the base
    (items 1–5, the read-only origin pin, `Head SHA:`); the `Changed lines:` grammar.
  - A new short severity section carries the Critical / Important / Suggestion definitions the static mappings
    use, with no panel references, and §7 points at it.
  - §8 and §10 lose the panel text: the severity lock is now enforced by `review-core`'s allow-list guard;
    housekeeper findings are a table, never the verdict.
- Agents: `ruff-reviewer.md:76` and `eslint-reviewer.md:76` stop naming `security-reviewer` ("are not escalated"
  wording). Check the jbinspect, trivy and housekeeper agents for panel or specialist-context references.
- `bin/housekeeper-freshness:669`: the comment no longer names `version-freshness-cookbook.md`.
- Re-point to `static-analysis-context.md`:
  - `tests/lib/test_sync_notes.sh`: the BASE, HEAD_SHA and PATH_SCOPE regexes and the base-branch steps. The
    agent-hazard severity test goes with the folded severity text: keep the Critical-untouched literals that
    survive, drop the panel ones.
  - `tests/lib/test_base_pin.sh` and `tests/lib/test_phase_efficacy.sh`.
- `specialist-context.md` and `severity-definitions.md` stay for the LLM agents until PR B.

### 7. Pipeline prose (`includes/review-pipeline.md`)

- **Remove:**
  - Phase 0 (its generated region and heading) and Phase 0.7;
  - Steps 2.7 and 2.8;
  - the `ui`, `tests` and `production` detections (2.6 keeps `csharp`, `js`, `py`, `iac` and `housekeeping`);
  - Step 3, the 2.9 ledger line and its defensive check, and the self-re-review carve-out line.
- Step 1's sync note names `static-analysis-context.md`. Step 2.45's "Phase 0's description fetch" wording drops
  Phase 0.
- **Step 3.5:**
  - Build `$NATIVE_TARGET` (A2) as `"$REPO_DIR" "$NATIVE_BASE"..."$HEAD_SHA"`, or `"$REPO_DIR" "$BASE"
    "$HEAD_SHA"` under `EMPTY_TREE_MODE`, plus ` -- "$PATH_SCOPE"` when scoped. Values are unquoted in the
    string itself (A4).
  - Resolve `$CLI_VERSION` (A10).
  - Pass one retired-key notice naming every retired key found per file. The keys are `orchestration.review_mode`,
    `orchestration.panel_size`, `review.anthropic_specialist` and every `intent.*` key the spec lists.
  - The new args object.
  - Remove the panel size and hybrid sections.
- Header comment: Phase 0 is no longer generated in; only Phase 0.6 is.
- Run `scripts/render-includes.py`, then fix the tests that assert on removed pipeline text (`grep -l 'Phase 0'
  tests/lib`, the route and lightweight asserts) under A1.

### 8. Hosts and rubric

- **`skills/review-gh-pr/SKILL.md`:**
  - `description` leads with what distinguishes it from `/code-review`: the PR is reviewed with Anthropic's
    `/code-review` plus the static analysers and posted as one marked review with a verdict.
  - Analysis-only drops its Phase 0.4 references.
  - Self-re-review detection keeps the halt-placeholder discard, with the halt body's first sentence quoted
    inline, since Phase 0.4 is gone.
  - Remove the Phase 0 and lightweight paragraphs under self-re-review (`SKILL.md:106-117`).
  - Stage 2 wording becomes "do not run the review pipeline".
  - Remove the Playwright step.
  - Step 3.6 drops the `intent.doc_paths` reference.
  - The "lightweight or full path" sentence goes.
  - Stage 6: `NONE` means native did not run. Show `bundle.bodyText` and `bundle.native.reason`, then ask once:
    post the static findings as a `COMMENT` review, or stop (the default). Never `APPROVE`. Under analysis-only,
    render as now.
  - The Class A templates read `Proposes: …`, with counts by severity and source from `bundle.counts`, and no
    rubric-row line. The provenance strings become `as proposed` / `user override of proposed <X>`, with no
    "panel".
- **`commands/pre-review.md`:**
  - `description`;
  - remove the Playwright step;
  - Step 3.6 wording;
  - presenting the bundle includes the native-not-run note.
- **`includes/verdict-rubric.md`:** rewritten to the spec's verdict table, normalisation, anchors and posting. It
  still states that `review-core.js` is the source of truth.

### 9. README and manifests

- `plugins/code-review-suite/README.md`:
  - the Architecture section is rewritten to the thin flow;
  - the Agents table adds `native-reviewer` and marks the LLM agents "unused, removed in PR B" (or omits them);
  - the Phase 0 section goes;
  - a prerequisite is added: Claude Code with the bundled `/code-review`, with the model invocation enabled (no
    `user-invocable-only` override for `code-review`).
- `plugin.json` and the `marketplace.json` description: native plus static, one marked review. Drop the panel
  keywords (`panel-review`, `trivial-mode`, `alignment`, `ui`, `accessibility` and the LLM-domain words).
- Root `README.md` plugin table row.

### 10. Verify

- `tests/run.sh`: all pass, and `scripts/render-includes.py --check` is clean.
- **Live L1 (merge):** a pinned local fixture under the session temp dir, with a Python off-by-one on a line ruff
  also flags (for example an unused import on the same line window). Dispatch `review-core` by `scriptPath`, PR
  mode, with a fake `changedLinesBlock` and `nativeTarget`, and `ruff` on. Pass: one inline comment carries both
  findings; the bundle log has `finder: native` and a `native` cog; no GitHub writes.
- **Live L2 (personal rules):**
  - Fixture: one rule only in `~/.claude/CLAUDE.md` (four parameters on one line), one paraphrased personal rule
    the guard cannot see (a public function with no doc comment), and one repo-`CLAUDE.md` rule.
  - Pass: the repo-rule finding is kept. Record the numbers of personal-rule findings dropped and passed.
  - Not a pass/fail gate on the paraphrase (the spec accepts it); the counts go into the PR body.
- `/address-pr-comments` on a scratch PR is deferred to after merge (it needs a posted review); note it in the PR
  body.

### 11. PR

- Push `feat/thin-pipeline` and open the PR against `feat/embed-panel-brief`. Retarget it to `main` after #145
  merges.
- Body (via `--body-file`): a non-technical opening (step 3 of the thin-suite plan: Anthropic's review becomes the
  finder; about a third of the cost, half the time), then the technical change list, assumptions A1–A13, the
  live-check results, and links to the spec (#148), the eval (#147) and #145.
- Run `/pre-review` on the branch before opening the PR. It is the thin suite reviewing itself, so this is also a
  live check.

## Not in this PR

Deleting agents, includes, fixtures and the A/B corpus (PR B); the eval arm (PR C); an OSV lookup; any native
effort setting or LLM filter.
