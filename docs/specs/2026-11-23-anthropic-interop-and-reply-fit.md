# Anthropic review interop and fitted review prose

Status: draft, 2026-11-23. Inserts before step 4 (eval) of the code-review-suite overhaul.

## Goal

Two outcomes:

1. Anthropic's shipped review tools (the bundled `/code-review`, `/simplify` and `/security-review`, and the
   `code-review` and `claude-security` plugins from `claude-plugins-official`) are enabled alongside
   code-review-suite without stealing its invocations. Either engine can run behind `/review-gh-pr` and
   `/pre-review` and post through the same renderer, and each consumes the other's output.
2. Every piece of prose the suite posts for other people to read (inline finding comments, the panel assessment,
   and `/address-pr-comments` replies) is fitted and terse, with no AI tells. It is held to the standard of the
   personal `reply-fit` skill.

The step-4 eval then compares `engine = suite | anthropic | hybrid` on the same fixtures, which is the
keep/hybrid/switch question it was always meant to answer.

## Background

- The Anthropic tools were turned off on 2026-10-27 (`~/.claude` 32f555d) for duplication, not conflict.
- Interference found:
  - the model may route "review this PR" to the wrong tool;
  - `claude-security` posts a scan tip after every `git push` and `gh pr create`;
  - its 60-second `AskUserQuestion` auto-deny is scoped to its own start confirmation, so it does not touch the
    suite's Phase 0 prompt.
- The bundled `/code-review` (alias `/review`) takes
  `[low|medium|high|xhigh|max|ultra] [--fix] [--comment] [--max-findings n] [target]`. It posts only with
  `--comment`.
- The plugin's command is namespaced `/code-review:code-review`, so the bare `/code-review` stays the bundled one.
- `skillOverrides` accepts `user-invocable-only`, which stops the model starting a bundled skill on its own.
  Plugin skills ignore `skillOverrides`.
- `plugin.json` supports `dependencies` (bare name means the same marketplace, and needs no `version` field). A
  disabled dependency stops the dependent plugin loading.
- `/address-pr-comments` drops every thread whose root author is `$CURRENT_USER`. Both engines post under the
  user's login, so a self-review followed by `/address-pr-comments` finds nothing to act on. This is the interop
  gap on the consuming side.
- `reply-fit`, `reply-fit-reviewer` and the vendored `humanizer` (blader/humanizer, MIT) live in `~/.claude`. Their
  `cases/` come from internal PR threads and must never be published (template-drift pin).

## Spikes (gate the dependent work, run first)

| # | Question | Pass | Fallback |
|---|---|---|---|
| S1 | Can an `agent()` worker in `review-core.js` call the Skill tool on a dependency plugin's skill (`reply-fit:humanizer`)? | Worker output shows the skill loaded | The editor agent carries a condensed rule list, copied from humanizer in a generated region of the reply-fit plugin |
| S2 | Can an `agent()` worker invoke the bundled `code-review` skill on a PR or range without `--comment`, and return its findings? | Findings returned, nothing posted | The adapter follows the official plugin's `commands/code-review.md`, read at runtime from the plugin cache |
| S3 | Can an `agent()` worker run `claude-security`'s scan-changes (itself a Workflow) and leave `CLAUDE-SECURITY-RESULTS.jsonl`? | JSONL written | `claude-security` stays a standalone tool; `hybrid` omits it |

S1 and S2 run on a throwaway fixture repo, never a live PR.

## PR 1: `reply-fit` plugin

New marketplace plugin `plugins/reply-fit/`:

- `skills/reply-fit/SKILL.md`, moved from `~/.claude`. The reviewer dispatch is qualified as
  `reply-fit:reply-fit-reviewer`, and the wording pass invokes `reply-fit:humanizer`.
- `skills/humanizer/` with `SKILL.md`, `LICENSE` and `VENDORED.md`, unmodified and pinned to the same commit.
- `agents/reply-fit-reviewer.md`, moved unchanged.
- A **non-interactive mode** for callers:
  - The caller passes the brief and draft paths plus `mode: embedded`.
  - The skill returns the final text, the word count against the budget, and any ASK-AUTHOR items, without
    presenting or asking anything.
  - Posting stays the caller's job.
- `cases/`: new generic cases covering the same eight shapes (authority, bloat, confirm, deflection, misplaced,
  nit, per-item, sources), written from scratch. The private cases move to `~/.claude/reply-fit-cases/`. The
  Testing section accepts an extra case directory, so both sets still run.
- README plugin table row. No prerequisites.

Out-of-repo, after merge:

- `~/.claude`:
  - enable `reply-fit@jodre11-plugins`;
  - delete `skills/reply-fit/SKILL.md`, `skills/humanizer/` and `agents/reply-fit-reviewer.md`;
  - move the cases;
  - update the template-drift pins;
  - push.
- `CLAUDE.md`'s "run the `reply-fit` skill" still resolves.

## PR 2: fitted prose in code-review-suite

`plugin.json` gains `"dependencies": ["reply-fit"]`.

### Authoring rules

New source include `includes/comment-voice.md`, generated into every LLM specialist, `panel-reviewer` (raised
findings) and `panel-writer`:

- `description`: the first sentence names the defect and its consequence. After that, only what the author needs
  to act on. No more than 60 words.
- `suggested_fix`: the change itself, either a code block or one or two sentences. No more than 40 words of prose.
- Banned:
  - openers ("I noticed", "It appears that");
  - stacked hedges;
  - restating the quoted code;
  - bold labels;
  - closers;
  - not-X-but-Y framing;
  - forced triads.
- Identifiers, paths and line references go in backticks, exactly as in the code.

The rules shape wording only. They never change what is flagged, so `rule-sources.md` precedence is unchanged.

### Wording pass (`voice` phase)

A new `review-core.js` phase runs after tiers and the verdict are fixed and before `renderComments` and
`buildBody`:

- **One agent**, `code-review-suite:comment-editor` (sonnet, Read only, `stallMs: 600000`). Its input is
  `{id, description, suggested_fix}` for each posted, non-static finding, plus the assessment. Its job is the
  humanizer pass, through Skill if S1 passes, otherwise the condensed rules. Output is schema-bound
  `{edits: [{id, description, suggested_fix}], assessment}`.
- **Guards, in code.** For each edit, keep the original if any of these fails:
  - the id is known;
  - every backticked token and every `path:line` in the original appears in the rewrite;
  - the rewrite is no longer than the original plus 10%;
  - the fields are non-empty.
  
  A missing or failed editor result leaves every finding unchanged. The pass can only shorten or reword text,
  never drop it.
- **Static findings are skipped.** Findings with a `rule_id` keep the tool's text.
- **Logging.** With `full_log` on, the log records each finding's original and edited text side by side for later
  comparison.

### `/address-pr-comments` replies

Step 8 changes. For each reply:

1. Write a reply-fit brief:
   - Question: the root comment, verbatim.
   - Asker: the comment author's login.
   - Medium: PR review reply.
   - Need: re-review, or none.
   - Sources: the commit diff and the thread.
2. Write the draft, run `reply-fit:reply-fit` in embedded mode, and post the returned text.
3. An ASK-AUTHOR item stops that reply and is listed in the step-9 table, so nothing is posted with a gap.

Replies run in parallel, with a cap of 8.

### Self-authored review comments

- The renderer appends `<!-- code-review-suite -->` to every comment and to the review body.
- Step 2.1 keeps a root comment authored by `$CURRENT_USER` when it carries that marker or matches the
  Anthropic `/code-review` comment shape: a review whose body starts `## Code review`, or an inline comment
  posted in the same review.
- `--include-self` widens this to every self-authored root comment.

## PR 3: engine setting and re-enablement

### Config

```toml
[review]
engine = "suite"        # suite | anthropic | hybrid
anthropic_effort = "high"
```

These resolve in the same order as `full_log`: the reviewed repo's file, then `~/.claude/code-review.toml`, then
the default `suite`. An unknown value prints a notice and falls back to `suite`.

### Engines

- **`suite`**: unchanged.
- **`anthropic`**:
  - Stage 1 is a single `anthropic-adapter` agent. It runs Anthropic's review through the S2 route, without
    `--comment`, and normalises each issue into the finding schema:
    - `severity`: Important, because Anthropic's review posts only issues it has validated as high-signal;
    - `confidence`: 90;
    - `domain`: `anthropic-review`;
    - CLAUDE.md citations kept in `reference`.
  - The panel vote is skipped, because Anthropic's pipeline already validates each finding. Findings enter the
    consensus tier.
  - The rubric, the voice pass, the renderer and posting are shared. This is what makes the engines
    interchangeable: same verdict ladder, same comment format, same `/address-pr-comments` path.
- **`hybrid`**:
  - The adapter runs as one more Stage-1 specialist in the same `parallel()` (ranked slowest-first), and its
    findings take the normal panel vote.
  - If S3 passes and `[review] claude_security = true`, a second adapter imports scan-changes JSONL:
    CRITICAL/HIGH map to Important, MEDIUM/LOW to Suggestion, and `claudeSecurityPluginFindingId` is kept in
    `reference`.
- **Local mode** (`/pre-review`) honours the engine the same way.

### Settings (`~/.claude/settings.json.tmpl`, private, direct to `main`)

- Enable `code-review@claude-plugins-official` and `claude-security@claude-plugins-official`.
- `skillOverrides`: `code-review` and `simplify` move from `off` to `user-invocable-only`, so they stay available
  by name but the model never starts them on its own. `security-review` is a built-in command and the docs don't
  say whether `skillOverrides` covers it, so its entry is removed.
- `/review-gh-pr` and `/pre-review` descriptions lead with "Default PR review (multi-agent panel)" so routing
  prefers them.
- The `claude-security` push tip stays on (the user asked for the plugins back). `CLAUDE_SECURITY_SCAN_TIP=off`
  silences it.
- Seed screen afterwards. The template seed's plugin list is genericised, so this probably ships no hunk.

### Tests

- `tests/run.sh`: the dependency resolves within the marketplace.
- `comment-voice` generated regions are current.
- Unit tests for the voice guards and the adapter normalisers, written against the existing `review-core.js`
  unit tests.
- One live check per engine on a planted-bug fixture, run by direct `review-core` dispatch on a pinned local diff.

## Order

S1–S3, then PR 1, then PR 2, then PR 3, then step 4. Step 4's fixtures run all three engines, with LLM graders
as a panel, agreement measured. Housekeeping: none expected (everything was current on
2026-10-28). It is re-checked at PR 1.

## Assumptions

- Plugin `dependencies` replaces vendoring a copy into the suite. The behaviour is the same (it auto-installs with
  the suite), with no second copy to drift.
- `anthropic` findings all map to Important and skip the panel. Anthropic's own filter is the quality gate; the
  eval tests this.
- Anthropic's comments are recognised by shape. If it proves brittle, `--include-self` is the escape hatch.
- The authoring rules impose no language variant. Spelling preference belongs to whoever runs the review
  (`rule-sources.md`).
- No fit review (as opposed to a wording pass) for finding comments. There is no question to fit them to, so the
  60/40-word budgets stand in for one.

## Out of scope

`/simplify` integration with `/address-pr-comments` or the suite; atomic posting; incremental re-review.
