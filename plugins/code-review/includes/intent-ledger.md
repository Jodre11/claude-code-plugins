## Phase 0: Intent Ledger

<!-- CANONICAL SOURCE — do not delete.
This file is the single source of truth for the Phase 0 intent ledger logic. Its content is
inlined verbatim into both consumer files:
  - skills/review-gh-pr/SKILL.md
  - commands/pre-review.md

WHY INLINED: same rationale as review-pipeline.md — agents skip file-path references and
must see the rule in context. PR #10 incident, 2026-05-05.

MAINTENANCE: Edit this file first, then propagate changes to both consumers. The test suite
verifies the inlined copies match this canonical source. Heading levels are relative — H2
here renders as H2 in consumers; do not change without auditing both. -->

Run Phase 0 BEFORE Step 1 (Determine base branch). The pipeline must not enter Step 1
unless Phase 0 succeeds.

### 0.1 Determine mode

- If invoked via `review-gh-pr` with a `$ARGUMENTS` value that matches the PR-argument
  validation regex, set `$REVIEW_MODE = pr`.
- If invoked via `pre-review` (local diff), set `$REVIEW_MODE = local`.

### 0.2 Capture candidate intent sources

Try these sources in priority order. The **first** source that satisfies the sufficiency
rule (Step 0.3) becomes the ledger. Do not stop at the first source that exists — only at
the first that is **sufficient**.

**Source 1 — In-diff prose document.**

Run `git diff --name-only --diff-filter=AM` (using the same diff syntax as the rest of the
pipeline) and inspect added/modified files. A file is a candidate prose document if any of
these match:

- Path begins with `docs/`, `design/`, `specs/`, `rfcs/`, `proposals/`, or `adr/`.
- Path matches a repo-configured override (read `.claude/code-review.toml` if it exists; key
  `intent.doc_paths` is an array of glob patterns. Skip silently if the file is missing or
  malformed — this is optional configuration).
- Extension is `.md`, `.markdown`, `.rst`, `.txt`, or `.org`.

For each candidate, read the **added** content (lines starting with `+` in the diff,
excluding the file-header lines). Concatenate all added prose from all candidates as a
single string `$DOC_PROSE`.

The `--diff-filter=AM` here differs from Step 2.2's unfiltered `git diff --name-only` —
AM-only excludes deletions because a deleted prose document cannot be a candidate intent
source. Consolidating the two calls is cosmetic only; the semantic difference is intentional.

**Source 2 — Verbatim prompt block.**

Search the PR body (mode `pr`) and most recent commit message subject + body for a fenced
block introduced by `Prompt:` (e.g. ```` ```prompt ```` or `Prompt:` followed by a
quoted/fenced block). Also look for prompt artifacts in the diff: any added file under
`.claude/prompts/` or matching the repo-configured override
`intent.prompt_paths`. Concatenate as `$PROMPT_BLOCK`.

**Source 3 — PR body prose.**

Mode `pr` only. Run `gh pr view "$ARGUMENTS" --json body --jq .body` and store as
`$PR_BODY`. Strip HTML comments (`<!-- ... -->`) and leading/trailing whitespace.

If mode is `pr`, you may issue this `gh pr view` and Phase 0.6.2's `gh pr checks` in
parallel — they have no data dependency.

**Source 4 — Branch commit subjects.**

Mode `local` only (last-resort fallback). Run
`git log "$BASE..HEAD" --pretty=format:'%s'` and store as `$COMMIT_SUBJECTS`. (Use this only
in Step 0.3 if Sources 1–3 are all insufficient and the mode is `local`. Source 4 is never
sufficient on its own in mode `pr`.)

### 0.3 Sufficiency rule

Apply the structural sufficiency check to each candidate source in priority order. The
**first** source that passes becomes the ledger.

A source `$S` passes if **all** of these are true:

- `$S` is non-empty after stripping whitespace and HTML comments.
- `$S` contains a **narrative prose paragraph** at the top (before the first checklist item,
  table, code fence, or HTML `<details>` block).
- The narrative paragraph contains at least **two sentences** of prose, each ending in `.`,
  `!`, or `?`.
- The narrative paragraph totals **more than seven words** combined (hard floor — most
  bodies will be longer; this is the bare minimum).
- The narrative paragraph is not a verbatim quote of `.github/pull_request_template.md`
  (template detection: a paragraph is suspect if every line of the paragraph also appears
  in the template; if so, treat as if the template paragraph were absent and check the
  remaining content).

A heading-only stub, a checklist with no narrative, or a body composed entirely of code
fences fails.

For mode `local`, Source 4 (`$COMMIT_SUBJECTS`) is checked last and **passes only if at
least one commit subject is itself a sentence of more than seven words** (most commit
subjects fail this; this is intentional).

### 0.4 Halt path (insufficient)

If no source passes Step 0.3, halt **before** Step 1. Do not dispatch any specialists, do
not call the synthesiser, do not measure the diff.

**Mode `pr`:**

Compose this review body verbatim:

```
This PR has no narrative description.

Before review, please add a paragraph at the top of the PR body explaining what this change is for and why. Two or more sentences, written as you would explain it to a teammate.

(This is a structural check — no AI was used to evaluate the body's quality. Any narrative paragraph that meets the bar will let the review proceed.)
```

Before posting, fetch the most recent review by the current user:

```
gh api user --jq .login                            # capture as $CURRENT_USER
gh pr view "$ARGUMENTS" --json reviews \
  | jq --arg user "$CURRENT_USER" \
       '.reviews | map(select(.author.login == $user)) | sort_by(.submittedAt) | reverse | .[0]'
```

If the most recent review by `$CURRENT_USER` exists, has `state == "CHANGES_REQUESTED"`,
and its `body` matches the canned text above verbatim, do NOT post a duplicate. Announce
`> Phase 0 halt: existing REQUEST_CHANGES review still active — no new review posted` and
stop the pipeline cleanly. Otherwise, submit using
`gh pr review "$ARGUMENTS" --request-changes --input -` with the body above via heredoc.
Do not post any inline comments. Announce
`> Phase 0 halt: REQUEST_CHANGES posted (no narrative description)` and stop the pipeline
cleanly.

**Mode `local`:**

Print this message verbatim:

```
Phase 0 halt: no narrative description detected.

Add a paragraph (two or more sentences) describing what this change is for to one of:
  - a doc/spec file in the diff (docs/, design/, specs/, rfcs/, proposals/, or adr/)
  - the latest commit message body
  - paste it now to use as the intent for this run (anything else will halt)

Paste intent paragraph (or press Enter to halt):
```

Read one line of input. If the user pastes a string that itself passes Step 0.3 (treat the
pasted string as a fresh source), use it as the ledger. Otherwise, halt cleanly with
`> Phase 0 halt: no narrative description provided`.

### 0.5 Build the ledger

When a source passes Step 0.3, build a structured ledger string:

```
$INTENT_LEDGER = "Intent ledger:
goal: <prose>
non_goals: <prose | none>
files_in_scope: <comma-separated list | none>
source: <in_diff_doc | prompt_block | pr_body | commit_subjects | user_paste>
"
```

- `goal` — the narrative paragraph that passed sufficiency. Trim to the first 1500
  characters (truncation is rare; bodies under that threshold are common).
- `non_goals` — the prose immediately following any heading like
  `## Non-goals`, `## Out of scope`, or `## Won't do` in the same source. `none` if
  absent.
- `files_in_scope` — if the source contains a heading like `## Files`, `## Files changed`,
  or `## Scope`, extract any path-like tokens listed beneath. `none` if absent.
- `source` — the priority of the source that passed (`in_diff_doc`, `prompt_block`,
  `pr_body`, `commit_subjects`, or `user_paste`).

Announce `> Phase 0: ledger built (source: $SOURCE)` and continue to Phase 0.55.
