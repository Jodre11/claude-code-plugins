# Anthropic review interop and fitted review prose

Status: reviewed 2026-11-23 (three-lens spec panel), amended. This work comes before step 4 (eval) of the
code-review-suite overhaul.

## Goal

Two outcomes:

1. **Anthropic's review tools run alongside the suite.** These are the bundled `/code-review` and `/simplify` and
   the `claude-security` plugin. They must not take over the suite's invocations. Each side must also handle the
   other's posted comments correctly.
2. **Posted prose is fitted and terse.** Everything the suite posts for other people to read must have no AI
   tells: inline finding comments, the panel assessment, the review body, and replies. The standard is the
   personal `reply-fit` skill.

A pluggable engine (`suite | anthropic | hybrid` behind `/review-gh-pr`) is **deferred**. The step-4 eval compares
the suite, Anthropic's review run as shipped, and a hybrid arm. The engine setting is built only once the eval
picks a winner. This PR set adds only the hybrid arm's adapter.

## Background

- The Anthropic tools were turned off on 2026-10-27 (`~/.claude` 32f555d) for duplication, not conflict.
- **The bundled `/code-review`** (alias `/review`) takes
  `[low|medium|high|xhigh|max|ultra] [--fix] [--comment] [--max-findings n] [target]`. It posts only with
  `--comment`.
  - `skillOverrides: "user-invocable-only"` stops the model starting it on its own.
  - Plugin skills ignore `skillOverrides`.
- **The `code-review` plugin stays off.** Its command (`/code-review:code-review`) is model-invocable and cannot be
  gated by `skillOverrides`. The bundled skill covers what it does.
- **`claude-security` side effects:**
  - It posts a scan tip after every `git push` and `gh pr create`.
  - Its 60-second `AskUserQuestion` auto-deny is scoped to its own start confirmation, so the suite's prompts are
    unaffected.
- **`plugin.json` supports `dependencies`.** A bare name resolves in the same marketplace and needs no `version`
  field. A disabled dependency stops the dependent plugin loading.
- **Subagent nesting** defaults to three levels below the main conversation.
- **Comments you post yourself are misread in two places.** Both engines post under the user's login:
  - `/address-pr-comments` drops a thread whose root is by `$CURRENT_USER` (`address-pr-comments.md:66`). It also
    drops a thread `$CURRENT_USER` has replied to (`:68`; the root counts). And it drops any review body by
    `$CURRENT_USER` (`:84`).
  - `/review-gh-pr` treats any earlier review by `$CURRENT_USER` as its own and enters self-re-review mode
    (`SKILL.md:86`). So a run after a standalone `/code-review --comment` "verifies fixes" against a review it
    never wrote.
- **`reply-fit`'s current location.** `reply-fit`, `reply-fit-reviewer` and the vendored `humanizer`
  (blader/humanizer, MIT) live in `~/.claude`. Their `cases/` come from internal PR threads and must never be
  published (template-drift pin).
- **`scripts/render-includes.py:88` refuses cross-plugin sources.** A suite agent cannot carry text from the
  reply-fit plugin inline.

## Spike (gates PR 3, run first)

| # | Question | Pass | Fallback |
|---|---|---|---|
| S1 | Can an `agent()` worker in `review-core.js` invoke the bundled `code-review` skill on a commit range, without `--comment`, and return its findings? | Findings returned, nothing posted | The adapter follows the official plugin's `commands/code-review.md`, read at runtime from the marketplace clone, minus steps 1 and 7–9. The hybrid arm's results are then labelled as coming from that pipeline. |

S1 runs on a throwaway fixture repo, never a live PR.

## PR 1: `reply-fit` plugin

The new marketplace plugin `plugins/reply-fit/` contains:

- **`skills/reply-fit/SKILL.md`**, moved from `~/.claude`. The reviewer dispatch is qualified as
  `reply-fit:reply-fit-reviewer`, and the wording pass invokes `reply-fit:humanizer`.
- **`skills/humanizer/`** (`SKILL.md`, `LICENSE`, `VENDORED.md`), unmodified and pinned to the same commit.
- **`agents/reply-fit-reviewer.md`**, moved unchanged.
- **An embedded mode for callers.**
  - The caller passes the brief and draft paths, a work directory, and `mode: embedded`.
  - The skill returns the final text, the word count against the budget, and any ASK-AUTHOR items. It does not
    present or post anything; posting stays with the caller.
  - The work directory replaces the fixed `${CLAUDE_TEMP_DIR}/reply-fit/`, so calls in a row never share files.
- **No `cases/` in the plugin.** The Testing section takes a case directory argument. The private cases move to
  `~/.claude/reply-fit-cases/` and are run from there.
- **A README plugin table row.** No prerequisites.

Out-of-repo, after merge, in this order:

1. Enable `reply-fit@jodre11-plugins` in `~/.claude/settings.json.tmpl` and apply.
2. Run `/plugins update`, then `/reload-plugins`, and confirm `reply-fit:reply-fit` resolves.
3. Only then delete `skills/reply-fit/SKILL.md`, `skills/humanizer/` and `agents/reply-fit-reviewer.md`, move the
   cases, and update the template-drift pins. Push.

Deleting first would leave a window where CLAUDE.md's "run the `reply-fit` skill" resolves to nothing.

## PR 2: fitted prose in code-review-suite

`plugin.json` gains `"dependencies": ["reply-fit"]`, which `/address-pr-comments` needs. The wording pass uses only
suite-owned text, so a failure inside reply-fit cannot break a review. The only shared failure is reply-fit being
disabled, which stops the suite loading.

### Voice rules (`includes/comment-voice.md`)

A suite-owned source, condensed from humanizer and attributed to it (MIT):

- **`description`:** the first sentence names the defect and its consequence. After that, only what the author
  needs to act on. No more than 60 words.
- **`suggested_fix`:** the change itself, either a code block or one or two sentences. No more than 40 words of
  prose.
- **Banned:**
  - openers ("I noticed", "It appears that");
  - stacked hedges;
  - restating the quoted code;
  - bold labels;
  - thanks and closers;
  - not-X-but-Y framing;
  - forced triads;
  - chains of dashes;
  - "Consider…" and "Would it be worth…" framing of a defect.
- **Code references:** identifiers, paths and line references go in backticks, exactly as in the code.
- **No language variant is imposed.** Spelling preference belongs to whoever runs the review (`rule-sources.md`).

It is carried inline, through a generated region, by `comment-editor` only. **Detection prompts are unchanged.**
No specialist or panelist prompt gains these rules.

### Wording pass (`voice` phase)

This is a new `review-core.js` phase. It runs after tiers and the verdict are fixed, and before
`renderComments`/`buildBody`, `buildLocalReport` and `buildLightweightBundle`.

- **Input:** one agent, `code-review-suite:comment-editor` (sonnet, no tools, `stallMs: 600000`), receives
  `{index, description, suggested_fix}`. `index` is the position in the input list. The list holds:
  - every surfaced finding: inline, body-routed and fileless body notes, or all lightweight findings;
  - the assessment.
  
  Findings from `STATIC` domains (`review-core.js:226`) are left out and keep the tool's text.
- **Output** (schema-bound): `{edits: [{index, description, suggested_fix}], assessment}`.
- **Guards, in code.** For each field, the original is kept if any check fails:
  - the index is known, and the field is non-empty when the original was;
  - every backticked token, `path:line` reference and URL in the original appears in the rewrite;
  - fenced code blocks are byte-identical;
  - the word count is no higher than the original's plus 10%;
  - for the assessment, the rewrite introduces no digit, no verdict word (`APPROVE`, `REQUEST_CHANGES`, `COMMENT`)
    and no severity word that the original lacked.
  
  A missing or failed editor result leaves everything unchanged.
- **Logging:** the log gains `log.voice: [{index, field, original, edited, accepted}]` with `full_log` on.
  `finding-schema.json` gains that property (`log` sets `additionalProperties: false`).

### Main-session prose

These are the parts the main session writes, which the wording pass cannot reach:

- **`/review-gh-pr` Stage 5 "Tone":** rewritten. The "Consider…/Would it be worth…" framing, the thanks and the
  `(optional)` prefix are replaced by a pointer to `comment-voice.md`'s rules. The plugin skill reads them at
  run time.
- **Stage 3 replies on other reviewers' threads and trivial-mode comments:** the same pointer.
- **`/address-pr-comments` step 8**, run sequentially, one reply at a time:
  1. Write a reply-fit brief in a per-reply work directory:
     - Question: the root comment, verbatim.
     - Asker: the author's login.
     - Medium: PR review reply.
     - Need: re-review, or none.
     - Sources: the pushed commit's diff and the thread.
  2. Write the draft and run `reply-fit:reply-fit` in embedded mode.
  3. Collect ASK-AUTHOR items across all replies and ask the user once, in one batch, before posting anything.
  4. Post the returned texts.

### Comments you post yourself

- **Marker:** the renderer appends `<!-- code-review-suite -->` to every comment body and to the review body (PR,
  lightweight and halt bodies).
- **`/address-pr-comments`:**
  - 2.1 keeps a thread whose root is by `$CURRENT_USER` when the root carries the marker. Its "already replied"
    check counts only `$CURRENT_USER` comments after the root.
  - 2.3 keeps a marker-bearing review body by `$CURRENT_USER`.
  - `--include-self` widens both rules to every self-authored root and body. That covers standalone Anthropic
    `--comment` runs, whose comments carry no marker.
- **`/review-gh-pr` self-re-review detection** (`SKILL.md:86`) counts only `$CURRENT_USER` reviews whose body
  carries the marker. During the transition it also counts a body that starts with the suite's verdict headline
  (`^\*\*(APPROVE|REQUEST_CHANGES|COMMENT)\*\*`). Any other self-review falls through to a full review.

## PR 3: re-enablement and hybrid adapter

### Settings (`~/.claude/settings.json.tmpl`, private, direct to `main`)

- Enable `claude-security@claude-plugins-official`. `code-review@claude-plugins-official` stays off.
- `skillOverrides`: `code-review` and `simplify` move from `off` to `user-invocable-only`. The docs don't say
  whether `skillOverrides` covers the built-in `security-review` command, so its entry is removed.
- The `claude-security` push tip stays on; `CLAUDE_SECURITY_SCAN_TIP=off` silences it.
- Run the seed screen afterwards. The template seed's plugin list is genericised, so this probably ships no hunk.

### Hybrid adapter (this repo)

- **The agent.** A new specialist, `code-review-suite:anthropic-reviewer` (domain `anthropic`), runs Anthropic's
  review through the S1 route at a fixed `high` effort, without `--comment`. It is a `*-reviewer`, so
  reviewer-guard covers it. It gets a `DISPATCH_RANK` entry from its measured duration (provisionally 0, the
  slowest).
- **Status.** The agent returns `status: skipped` when the review declines (draft, closed, trivial, or "already
  commented"), and `failed` on error. It never returns an empty `ok`.
- **Normalisation:**
  - `file` and `line` are parsed from the `#L<start>-L<end>` link: start for single-line issues, end for ranges.
    An unparsable link gives a file-level anchor.
  - `severity` is Important for bugs and CLAUDE.md citations. Anthropic posts only issues it has validated as
    high-signal; the panel can still vote them down.
  - `confidence` is 90.
  - `suggested_fix` is the suggestion block or fix text, or `""`.
  - CLAUDE.md links go in `reference`.
- **Everything after normalisation is shared.** The findings take the normal panel vote: `routeFinding`, the voted
  line guard and the changed-lines filter. They are then rubric-scored and rendered like any other specialist's.
- **Opt-in.** `[review] anthropic_specialist = true` in `code-review.toml`, resolved in the same order as
  `full_log`. The prose lives in `review-pipeline.md` (generated into both hosts) and is passed to review-core as
  `args.anthropicSpecialist`. It defaults to off. The flag sits in the suite's own section and creates no engine
  setting.
- **Logging.** `log.meta` gains `anthropic_specialist: boolean` (schema change), so the eval can tell arms apart.

### Routing (this repo)

`/review-gh-pr` and `/pre-review` descriptions lead with their distinguishing use ("Multi-agent panel review…").
The bundled `/code-review` is no longer model-invocable, so this is belt and braces.

## Tests

- `tests/run.sh`:
  - the `reply-fit` dependency resolves within the marketplace;
  - the `comment-voice` generated region is current;
  - `anthropic` is in `DISPATCH_RANK`.
- Unit tests, alongside the existing `review-core.js` unit tests:
  - each voice guard;
  - the link-to-anchor parser;
  - the marker on every bundle shape;
  - `skipped` and `failed` statuses from the adapter.
- Live checks, each on a pinned local diff by direct review-core dispatch:
  - the voice pass on a planted-bug fixture, with the before and after compared in `log.voice`;
  - one hybrid run.
- `/address-pr-comments`: one live run on a scratch PR self-reviewed by the suite.

## Order

S1, then PR 1, then PR 2, then PR 3, then step 4.

Step 4's arms:

- **suite.**
- **Anthropic as shipped:** the bundled `/code-review high` on the same commit range, run natively. Its terminal
  findings are the comparator, whatever S1 returns.
- **hybrid:** `anthropic_specialist = true`.

The graders are a panel of LLM judges, with agreement measured. Fixtures are fresh PRs or ranges, so Anthropic's
"already commented" stop never fires.

Housekeeping: none expected (everything was current on 2026-10-28). It is re-checked at PR 1.

## Assumptions

- **Plugin `dependencies` instead of a vendored copy.** The behaviour is the same (it auto-installs with the
  suite), with no second copy to drift.
- **ASK-AUTHOR in `/address-pr-comments`** asks the user once, in one batch, before posting. The user is in the
  session, and reply-fit already asks.
- **No fit review** (as opposed to a wording pass) for finding comments. There is no question to fit them to, so
  the 60/40-word budgets stand in for one.
- **Legacy self-reviews** with neither the marker nor the verdict headline fall through to a full review. This is
  the safe direction.

## Out of scope

- The `engine` setting, pending the eval.
- claude-security inside the review pipeline. Its scan needs the user's interactive cost confirmation and writes a
  report directory into the reviewed repo, so it stays standalone.
- `/simplify` integration; atomic posting; incremental re-review.
