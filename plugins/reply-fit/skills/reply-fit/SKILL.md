---
name: reply-fit
description: Fit a reply to what was actually asked, then strip AI tells. Use before posting or sending any reply another person reads in conversation (PR and review replies, issue comments, Teams or Slack messages, short emails), and on "slop check", "is this too long", "tighten this reply" or "/reply-fit". Not for documents such as PR descriptions or design docs.
argument-hint: "[thread-url | mode: embedded <work-dir>]"
---

# Reply fit

A reply fails its reader in two ways: bloat (answering what nobody asked, the answer buried) and deflection (too
short to answer the real concern). Wording tells are a third, smaller problem. This skill checks fit first with an
independent reviewer, revises, then runs `humanizer` for wording.

## Modes

- **Interactive** (default): you are fitting a reply for the user. The work directory is
  `${CLAUDE_TEMP_DIR}/reply-fit/`.
- **Embedded**: another skill or command is the caller and says `mode: embedded` with a work directory that
  already holds `brief.md` and `draft.md`. Use that directory for every file, skip step 1, never ask the user
  anything, and replace step 5 with the embedded return below. Each call gets its own directory, so consecutive
  calls never share files.

## 1. Write the brief

Write `<work-dir>/brief.md` with:

- **Question:** the asker's words, verbatim. Given a PR or issue URL, fetch the thread with `gh` and quote the
  comment being answered, plus any later comment that changes the picture (a sign-off, a second question).
- **Asker:** who they are and their role (platform reviewer, approver, HR lead).
- **Medium:** PR reply, issue comment, Teams, Slack, email.
- **Need:** what the author wants from the asker (lift a block, approve, decide between A and B), or "none".
- **Sources:** paths the reply may draw facts from (design doc, PR body, earlier thread). Save fetched text to files
  in `<work-dir>/` and list those paths.

If the question or the need is unknown and cannot be fetched, ask the user once. Write the draft to
`<work-dir>/draft.md`. With no draft yet, write one from the brief first, then continue.

## 2. Fit review

Dispatch the `reply-fit:reply-fit-reviewer` agent in the foreground with the two file paths and the source paths.
Pass nothing else: not the conversation that produced the draft, not your opinion of it. Tell it to deliver its
result via SendMessage to you.

## 3. Revise

Apply the review:

- Delete everything under CUT.
- Add everything under MISSING from its cited source. For an ASK-AUTHOR item, ask the user (embedded: record it for
  the caller); never fill it yourself.
- Put the answer in the first sentence. Fix each TONE item. State the ask once, plainly, at the end or the start.
- Meet the budget. If the review's budget looks wrong for this asker, say why and use your own.

## 4. Wording pass

Invoke the `reply-fit:humanizer` skill in embedded mode on the revised text, saying it is a reply in a thread to the
asker's question (quote it) so its §26 applies. Then check its output against the review: if it re-added cut
material, dropped a MISSING fact, or went over budget, keep the fit and take only its wording changes.

## 5. Present

Show the user:

- the final text;
- its word count against the budget;
- one line on what changed: what was cut, what was added, and the tone fixes.

Post or copy only when the user approves, unless they already said to post. For Teams or Slack, hand the approved
text to `md-to-clipboard`.

**Embedded return.** Write the final text to `<work-dir>/final.md` and return to the caller exactly:

```
FINAL: <work-dir>/final.md
WORDS: <n> / <budget>
ASK-AUTHOR:
- <the fact only the author can supply> | none
```

Post nothing. The caller decides what to post and asks the user about any ASK-AUTHOR item.

## Testing

Cases are known replies with an answer key under `## Expected`, one directory per case, kept outside the plugin
(real threads are not published with it). Given a case directory, run the reviewer on each case blind (one agent
per case, no case sees another) and compare against `## Expected`. A change that breaks a case needs a reason.
