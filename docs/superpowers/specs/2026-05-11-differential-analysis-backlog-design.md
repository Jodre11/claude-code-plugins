# Differential-analysis backlog — design

Date: 2026-05-11
Status: design (approved)
Source: `docs/adamsreview-comparison.md` priority list (post-PR-#14)

## Context

PR #14 (`feat/agent-code-hardening`) merged the seven failure-class hardening
changes. The next workstream is the seven prioritised improvements identified
in `docs/adamsreview-comparison.md` from comparing this plugin to
`adamjgmiller/adamsreview`.

This document covers all seven items in a single brainstorming pass. Three
items are designed in detail (the ones we'll implement next, in
implementation order). Four items are explicitly deferred with the rationale
captured so a future session does not re-derive the deferral.

Each "designed" item below is suitable as input to its own
`writing-plans`-skill cycle when the user is ready to start that item. The
deferred items remain on the queue tracked in memory file
`project_differential_analysis_followup.md`.

## Designs

### 1. Trivial-mode early exit (was: comparison-doc item #6)

**Goal.** Avoid spinning up any specialist or synthesiser agent for
docs-only / config-only diffs. Save tokens *and* wall-clock time on the
high-volume tail of trivial PRs (typo fixes, version bumps, README edits).

**Mechanism.** A new tier is inserted into the routing decision *between*
Phase 0.6 and Step 1. The pipeline now has three tiers:

| Tier | Reviewer | Trigger | LLM cost |
|---|---|---|---|
| Trivial (NEW) | Orchestrator only | allow-list paths AND ≤3 files AND ≤30 lines | tiny — no agent dispatch |
| Lightweight | 1 `code-analysis` agent | ≤5 files, ≤150 lines, no security-sensitive | one Sonnet agent |
| Full | 8 specialists + cross-review + Opus synthesiser | otherwise | full cost |

**Trigger rules.** All of these must hold:

- Every changed file matches the allow-list **by extension** (default:
  `.md`, `.json`, `.toml`, `.txt`, `.gitignore`, `.gitattributes`,
  `.editorconfig`, `LICENSE` — bare-name match for `LICENSE`)
- AND no changed file is under a load-bearing-prompt path:
  `plugins/*/agents/`, `plugins/*/skills/`, `plugins/*/commands/`,
  `plugins/*/includes/`. These are `.md` files but they're code (LLM
  instructions), not docs.
- AND `$FILE_COUNT ≤ 3` AND `$LINE_COUNT ≤ 30`
- AND `$SIGNIFICANT_DELETIONS = false`
- Override: `--force` arg or `intent.skip_trivial_check = true` in
  `.claude/code-review.toml`

The allow-list and the path exclusions are configurable in
`.claude/code-review.toml` under `intent.trivial_paths.allow_extensions` and
`intent.trivial_paths.exclude_paths`.

**Action when triggered.** Orchestrator reads the diff and the changed files
and drafts a structured **mini-review** (orchestrator-only, no agent
dispatch):

- Verdict: `APPROVE` if everything looks fine, `COMMENT` if minor
  observations worth surfacing, `REQUEST_CHANGES` if anything is wrong
- Top-level review body: 2–3 sentences explaining what changed and why it
  qualified for trivial-mode
- Up to **3 inline comments** if any are warranted (hard cap)
- User confirms verdict (same gate as Step 6 of the full pipeline)
- Posts via `gh pr review` and exits

**Local-mode behaviour.** `pre-review` announces trivial-mode triggered,
prints the mini-review to terminal, does NOT post anything. Output goes to
stdout instead of GitHub.

**Why "orchestrator-only" works.** The orchestrator already has the diff in
context after Step 2, can read files, and can post via `gh pr review`. For
diffs that fit the trivial-mode bar, dispatching even one specialist is
overkill — the orchestrator can form a competent quick opinion in the same
turn. The `code-review` plugin's no-filter rule is intentionally bypassed for
this tier (it has no synthesiser report to reconcile against); the trade-off
is acceptable for diffs that fit the bar.

**Files modified.**
- `plugins/code-review/includes/review-pipeline.md` — new "Phase 0.7:
  Trivial-mode early exit" section between Phase 0.6 and Step 1
- `plugins/code-review/skills/review-gh-pr/SKILL.md` and
  `commands/pre-review.md` — re-spliced from canonical
- Optional: `.claude/code-review.toml` schema extension documenting the
  `intent.trivial_paths.*` keys

**Effort.** ~half-day. Most of the work is the orchestrator's mini-review
prompt template and the user-confirm loop.

---

### 2. Changed-line filter (was: comparison-doc item #5 "origin cross-check")

**Goal.** Findings only on lines the PR actually added or modified.
Currently every specialist's prompt enforces a *file-level* filter ("only
files in the diff"), but findings on unchanged lines within changed files
are still emitted — most visibly from `jbinspect-reviewer`, which scans the
whole solution. Tightening to *line-level* eliminates pre-existing-bug noise
and saves cost by short-circuiting at the earliest possible boundary.

**Naming note.** Comparison-doc item #5 framed this as "origin cross-check"
via `git blame`. That was wrong: blame is a posting-time check that runs
after specialists have already spent tokens. The correct framing is to filter
*at the specialist boundary* by passing each specialist the changed-line set
up front.

**Mechanism.**

1. **Step 2.5 (NEW):** orchestrator parses `$FULL_DIFF` and builds
   `$CHANGED_LINES` — a per-file map:
   - `+` lines: current line numbers in the new file
   - `-` lines: annotated as `near line N` (where N is the line in the new
     file immediately above where the deletion happened — for
     `archaeology-reviewer`)
   - Renames with no content change: empty list
2. **Step 2.8 (`$AGENT_PROMPT`):** new line `Changed lines: <serialised
   map>` propagated to all specialists. The pre-existing rule "Only report
   findings in files that appear in the diff" tightens to "Only report
   findings on lines listed in `$CHANGED_LINES` for that file. Do NOT emit
   findings on unchanged lines, even FYI."
3. **`jbinspect-reviewer` filters at parse-time.** After running
   `jb inspectcode`, intersect every `<Issue>`'s line attribute against
   `$CHANGED_LINES[file]`. Drop non-matching issues *before* composing
   findings — those issues never enter the pipeline.
4. **Archaeology-reviewer special case.** Its findings are about deletions;
   map to `near line N` so they post as inline comments on the closest
   still-present line.
5. **Posting-time safety net (Step 5 reconciliation).** Any finding whose
   `file:line` isn't in `$CHANGED_LINES` is silently dropped, logged to
   `$CLAUDE_TEMP_DIR/dropped-findings.log` with `(specialist, file:line,
   title, reason)` for debugging. User-facing summary unaffected.

**Width of the changed-line set.** Strict: only `+` and `-` lines from the
unified diff. Not padded with surrounding context. Specialists still *read*
unchanged context for understanding, but findings are emitted only on
touched lines.

**Files modified.**
- `plugins/code-review/includes/review-pipeline.md` — new Step 2.5, updated
  Step 2.8 `$AGENT_PROMPT`, posting-time safety net in Step 5
- `plugins/code-review/includes/specialist-context.md` — document
  `$CHANGED_LINES` extraction
- All specialist prompt files (`agents/*-reviewer.md`) — replace the
  file-level filter rule with the line-level filter rule
- `agents/jbinspect-reviewer.md` — additional parse-time filter
- `agents/code-analysis.md` — same line-level filter
- `agents/archaeology-reviewer.md` — `near line N` mapping for deletions
- Both consumers re-spliced from canonical
- Sync test `test_sync_notes.sh` catches drift automatically; consider a
  unit test that exercises a 3-file diff with mixed touched/untouched lines
  and asserts the orchestrator's `$CHANGED_LINES` map is correct

**Effort.** ~1 day. More than the original half-day estimate — touching
every specialist prompt and writing the diff-parsing logic in Step 2.5 is
the bulk of the work.

---

### 3. Token instrumentation (was: comparison-doc item #2)

**Goal.** Surface per-subagent token usage in the synthesiser report so the
user can see what each review costs. Makes cost a first-class part of the
review output rather than an invisible runtime concern.

**Mechanism.**

1. **Capture at agent boundaries.** When each `Agent({...})` call completes,
   the tool result includes a `<usage>total_tokens: N tool_uses: K
   duration_ms: M</usage>` block. The orchestrator captures
   `(agent_name, tokens, duration_ms)` in a list throughout the pipeline.
2. **Persist to disk per run.** Append each tuple to
   `$CLAUDE_TEMP_DIR/tokens.jsonl` so the data survives if the orchestrator
   crashes mid-run.
3. **Aggregate before synthesiser dispatch.** Step 6 builds a
   `$TOKEN_USAGE_BLOCK`:
   ```
   Token usage:
   security-reviewer: 12,400 tokens (77s)
   correctness-reviewer: 18,200 tokens (88s)
   ...
   subtotal_subagents: 140,000
   orchestrator: not measurable from within the session
   ```
4. **Pass to synthesiser.** New line in synthesiser prompt: `Token usage:`
   followed by the block. Synthesiser instruction: render verbatim as a
   `## Cost` section near the end of the report (after Dismissed).
5. **`## Cost` section in synthesiser output template.** New section in
   `agents/review-synthesiser.md`'s output format:
   ```
   ## Cost

   - **Specialists:** 80,000 tokens
   - **Cross-review:** 32,000 tokens
   - **Synthesiser:** 28,000 tokens (this report)
   - **Subtotal:** 140,000 tokens
   - **Orchestrator:** not measurable from within the session — check
     `/context` for the running total
   ```

**Orchestrator-tokens caveat.** The orchestrator (the running session)
cannot measure its own token usage from inside. The `## Cost` section
explicitly notes this rather than estimating; users can correlate with
`/context` for the running total. This blind spot is also why item #4
(cheap-then-deep gating) is deferred — without orchestrator visibility we
can't accurately measure where the cost lives.

**Files modified.**
- `plugins/code-review/includes/review-pipeline.md` — capture tokens from
  agent results in Step 4, build `$TOKEN_USAGE_BLOCK` before Step 6, pass
  in synthesiser prompt
- `plugins/code-review/agents/review-synthesiser.md` — add `## Cost` to
  output format template
- Both consumers re-spliced

**Effort.** ~half-day. The capture is mechanical; the rendering is a
synthesiser-prompt edit. Risk: the `<usage>` block format may change in
future Claude Code versions; the regex needs a graceful fallback to
"unmeasured" when parsing fails.

## Deferred

### Persistent artifact + upsert PR comment (comparison-doc item #3)

**Why deferred.** This is a 1-day project with real GitHub-API risk
(comment IDs, dismissed reviews, edge cases when comments are manually
edited). The user-felt value depends on how often reviews are re-run on the
same PR. Without observed pain ("re-running stacks duplicate comments"),
the work is speculative. Re-evaluate if and when re-running becomes a
common workflow.

### Interactive walkthrough (comparison-doc item #1)

**Why deferred.** Depends on the persistent artifact (#3) for resumability.
2-day project. The current synthesiser → reconciliation table → user-confirm
flow already provides batch user control over what gets posted; a
per-finding walkthrough trades speed for fidelity in a way that may not
match how the user actually reviews. Revisit after persistent artifact lands.

### Cheap-then-deep gating (comparison-doc item #4)

**Why deferred.** Without token instrumentation (#3 above) we cannot measure
where the actual cost lives. Implementing #4 first would be optimisation
without measurement. Implementation order is: token instrumentation →
gather data on real reviews → decide whether the gating is worthwhile.

### Schema-enforced JSON between specialists and synthesiser (comparison-doc item #7)

**Why deferred.** Preventative against a failure mode (Opus silently
collapsing batches and dropping findings) that has not been observed in
this project's reviews. The work is the largest of the seven (touching every
specialist prompt) and provides protection against a hypothetical problem.
YAGNI. Revisit if/when a real review surfaces a count mismatch between
specialist findings and synthesiser output.

## Implementation order

1. **Trivial-mode early exit** (~half-day, no dependencies)
2. **Changed-line filter** (~1 day, no dependencies)
3. **Token instrumentation** (~half-day, no dependencies; informs #4 if it
   ever happens)

These three are independent and can be sequenced in any order. The
recommended order above is by user-felt impact (trivial-mode saves the most
wall-clock time per review) then by quality-of-output (changed-line filter
removes noise) then by observability (token instrumentation enables future
optimisation).

Each item gets its own `writing-plans` cycle and PR when the user is ready.

## Self-review

**Placeholder scan:** No TBDs, no incomplete sections.

**Internal consistency:** Implementation order matches the deferral
rationale (#4 deferred *because* #3-token-instrumentation should land first
to inform it). Trivial-mode and changed-line filter are independent.

**Scope check:** Three designs, each suitable as a single
`writing-plans`-cycle input. Not too coarse (the three are independent), not
too fine (no further decomposition needed before planning).

**Ambiguity check:** The "load-bearing prompt path" exclusion in
trivial-mode is the most ambiguous bit — `plugins/*/agents/` is clear, but
`plugins/*/includes/` could include things that aren't prompts. Resolved:
the path-exclusion list is explicit, not glob-driven, so there's no
interpretive ambiguity.
