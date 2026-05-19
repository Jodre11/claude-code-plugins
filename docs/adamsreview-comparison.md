# adamsreview vs local code-review-suite — where adamsreview is superior

Date: 2026-05-11
Subject of comparison:
- External: https://github.com/adamjgmiller/adamsreview
- Local: `plugins/code-review-suite/` (this repo; renamed from `code-review` on 2026-05-19)

This note focuses on areas where **adamsreview is materially better** than the
local plugin. It is not a balanced review — strengths of the local plugin are
omitted by design.

## 1. Walkthrough — interactive, resumable, decision-logged

adamsreview ships a dedicated `:walkthrough` command (`commands/walkthrough.md`)
that steps the user through every finding the auto-fixer would skip:

- One `AskUserQuestion` per finding with options A/B/C…, "Edit the fix hint",
  "Skip", "Stop".
- Posts a separate **decisions-log PR comment** with an HTML anchor and tallies
  (auto-accepted / promoted / skipped / stopped / pre-existing issues filed).
- Resumable across sessions — re-invoking skips already-promoted findings.
- Deliberately omits inter-iteration "continue?" prompts "to maintain rhythm".

The local plugin has **no equivalent**. After the synthesiser runs, the user
sees a single batch reconciliation table and confirms the whole comment set in
one step. There is no per-finding interactive triage, no decisions log, and no
resumability if the session is interrupted.

The synthesiser's "Synthesiser Assessment" section is a holistic narrative; it
is **not** a per-file walkthrough of what changed. adamsreview's
`artifact-render.py` produces structured per-finding blocks with
`evidence_snippet`, `line_range`, `impact_type`, `origin`,
`origin_confidence`, `score_phase4`, `disposition` and `actionability` — far
richer per-finding metadata.

## 2. Token usage — explicit, instrumented, gated at multiple stages

adamsreview treats token cost as a first-class engineering concern:

| Mechanism                 | Detail                                                                                                                                |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Trivial-mode early exit** | `bin/trivial-check.sh` skips full review when changes match an allow-list (`*.md`, `*.json`, `*.toml`, …) AND ≤3 files AND ≤30 lines. |
| **Conditional lenses**    | L2/L5/L6/L7 are gated by `trivial_mode != true`; L5 also by `user_facing == true`; L7 only under `--ensemble`.                        |
| **Cheap-then-deep gating**| Phase 3 uses Sonnet to score 0–100 with hard cutoff at ≥45; only survivors hit Opus in Phase 4.                                       |
| **Lane-aware validation** | Deep lane (Opus) per-candidate; Light lane (Sonnet) chunked **≤25 candidates per agent**.                                             |
| **Hard wave cap**         | Phase 4 caps at two waves; Phase 5.5 uses 10-finding chunks with parallel generate+verify.                                            |
| **Compact lens prompts**  | Each lens is a short bullet list, with explicit `Do not access other files or use grep` instruction.                                  |
| **125-char evidence cap** | Per `_shared-invariants.md` — a hard quote cap on every finding.                                                                      |
| **Token logging**         | `bin/log-tokens.sh` and `bin/tally-subagent-tokens.sh` separate `subagent_tokens` (precise, from `tokens.jsonl`) from `orchestrator_tokens`; both roll into the rendered artifact. |
| **Cumulative spend**      | `tokens.jsonl` is append-only; total token spend rolls forward across `:review` → `:walkthrough` → `:fix` → `:add` invocations.       |

The local plugin's token-saving techniques are coarser and unmeasured:

- Lightweight routing (one of two paths) for diffs ≤5 files / ≤150 lines.
- "Discard `$FULL_DIFF` from working memory" instruction in Step 4.
- 4000-char truncation of peer findings before cross-review.
- Skip generated/lock/vendored files.
- Confidence floors (`>= 80` for code-analysis, `>= 50` for security).

There is **no instrumentation** — the user cannot see what the review cost.
There is no cheap-then-deep gating, no per-finding scoring, and no resumable
artifact that aggregates spend across invocations.

## 3. Persistent artifact + dedup'd PR comment

adamsreview persists everything to `~/.adams-reviews/<repo-slug>/<branch>/`:

- `artifact.json` (mutated through `bin/artifact-patch.py` against
  `bin/schema-v1.json`, `additionalProperties: false`)
- `artifact.md` rendered by `bin/artifact-render.py`
- `trace.md`, `phases.jsonl`, `tokens.jsonl` — append-only audit logs

The PR comment is **upserted** by `bin/artifact-publish.sh` (POST or PATCH on
`comment_id`), with the dedup marker `<!-- adams-review-v1 -->`. Re-running
updates the same comment instead of stacking new ones.

The local plugin posts **inline review comments** plus a top-level review
verdict but does not maintain any cross-invocation artifact. Re-running creates
a fresh review.

## 4. Auto-fix loop with regression revert

adamsreview's `:fix` command:

1. Generates fix proposals, then runs an Opus post-fix verification pass.
2. If the verification finds regressions, **reverts the regression groups but
   commits the surviving fixes**.
3. Supports `--granular-commits` for per-group commits.
4. Phase 7.5 shows a batch UI offering apply-all / per-finding / skip / cancel
   before any edits.

The local plugin has **no auto-fix**. `address-pr-comments` is a separate
command that defers to the `superpowers:receiving-code-review` rubric — it
helps a human author respond to comments, but does not generate or verify
fixes itself.

## 5. Origin attribution + prior-fix reversion check

- `bin/origin-crosscheck.sh` blame-traces candidates and **downgrades**
  `pre_existing/high` if PR commits appear in blame, or **upgrades** items if
  all-ancestor blame indicates pre-existing.
- L2 (structural/blast-radius) compares the current diff against recent fix
  commits touching overlapping lines and flags reverted fixes.

The local plugin's `archaeology-reviewer` investigates deletions via
`git log -S` for magic numbers and undocumented workarounds — useful but
narrower in scope. There is no automatic blame-based origin classification and
no prior-fix reversion check.

## 6. Polyglot review (Codex peer)

`commands/codex-review.md` runs 7 parallel Codex CLI lenses with
`--effort low|medium|high|xhigh`. The ensemble adapter (Phase 1.5,
`02-ensemble-adapter.md`) dispatches Codex as a peer with no fallback —
deliberately, "to keep the Codex review honest" — and merges its findings.

The local plugin is Claude-only.

## 7. External-finding injection

`:add` lets the user paste chat-dump pastes (normalised by a Sonnet agent) or
use a structured `--file/--line/--claim` fast path that skips the LLM
round-trip. PR-bot comments from other tools are scraped and normalised in
Phase 1.5.

The local plugin has no equivalent.

## 8. Polish clusters + cross-cutting groups

- **Polish clusters**: sliding-window detection of ≥3 nits within 100 lines —
  rendered as a cluster instead of N separate findings.
- **Cross-cutting groups (Phase 5)**: groups labelled `G1`, `G2`, … with a
  minimum-2-findings constraint, rendered as callouts inside the deep-auto
  table.

The local plugin has no nit clustering. Cross-review (Agree/Disagree/Escalate)
is a different mechanism — useful for verdict consensus, not for grouping
related findings.

## 9. Schema-enforced JSON + count guards

- `bin/schema-v1.json` with `additionalProperties: false`.
- `bin/parse-with-repair.py` for one-shot light repair of malformed JSON.
- `--expected $N` count guard catching silently collapsed Opus batches.

The local plugin's only count guard is in `review-gh-pr` Step 5.5 (`R == F`,
`C == R - D - X`) and applies to the finding-to-comment reconciliation table,
not to subagent output.

## What the local plugin still does well

For balance — adamsreview does not obviously beat the local plugin on:

- **Cross-review pass**: the local plugin's Agree/Disagree/Escalate mechanism
  with self-domain exclusion (prompt-injection containment) is distinctive.
  adamsreview has nothing equivalent.
- **Synthesiser as severity gate**: Opus + `ultrathink` reclassification is a
  cleaner quality gate than adamsreview's score-band heuristics.
- **Self-re-review narrowing**: detecting prior reviews by the same author and
  switching to "verify fixes / blockers only" mode is unique to the local
  plugin and prevents demoralising re-review cycles.
- **Specialised reviewers**: `reuse-reviewer`, `consistency-reviewer`,
  `archaeology-reviewer` cover concerns not directly addressed by
  adamsreview's lenses.
- **Mandatory dispatch + no-filter rules**: explicit hardening from real
  incidents (PR #10).

## Suggested borrowable ideas (in rough priority order)

1. **Interactive walkthrough command** with per-finding triage and a
   decisions-log PR comment.
2. **Token instrumentation** — at minimum, log subagent token usage per
   specialist and surface a total in the synthesiser output.
3. **Persistent artifact + upsert PR comment** with a dedup marker, so
   re-running updates instead of stacking.
4. **Cheap-then-deep gating** — a Sonnet pre-score before invoking the Opus
   synthesiser, with a hard cutoff.
5. **Origin cross-check** via `git blame` to downgrade pre-existing findings.
6. **Trivial-mode early exit** for docs-only / config-only diffs.
7. **Schema-enforced JSON** between specialists and synthesiser, with a count
   guard.

Items 1, 2 and 3 are the ones a user would feel immediately. Item 4 has the
biggest cost-saving impact on large diffs. Items 5–7 are correctness/quality
multipliers.
