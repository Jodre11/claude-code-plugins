# Reply Fit Plugin

Fits a reply that someone else will read in conversation (a PR or review reply, an issue comment, a Teams or Slack
message, a short email) to what was actually asked, then strips AI tells from its wording.

A reply fails its reader in two ways: bloat, which answers what nobody asked and buries the answer, and
deflection, which is too short to answer the real concern. An independent reviewer that never sees the
conversation which wrote the draft checks fit first. A vendored copy of
[blader/humanizer](https://github.com/blader/humanizer) then handles wording.

## Usage

    /reply-fit
    /reply-fit https://github.com/<owner>/<repo>/pull/<n>#discussion_r<id>

It also triggers on "slop check", "is this too long" and "tighten this reply". It shows the final text, its word
count against the reviewer's budget, and what changed, and posts only when you approve.

### Embedded mode

Other plugins call the skill with `mode: embedded` and a work directory holding `brief.md` and `draft.md`. In this
mode the skill asks nothing and posts nothing. It writes `final.md` and returns the word count and any facts only
the author can supply. `code-review-suite`'s `/address-pr-comments` uses this mode for its replies.

## Installation

    claude plugin install reply-fit@jodre11-plugins

No prerequisites. `gh` is used only when you pass a thread URL.

## Contents

| Component | Role |
|---|---|
| `skills/reply-fit` | Brief, fit review, revision, wording pass, presentation |
| `agents/reply-fit-reviewer` | Independent fit check: cut, missing, budget, tone, ask (sonnet, read-only) |
| `skills/humanizer` | Vendored humanizer, unmodified and pinned by commit in `VENDORED.md` |

## Testing

Cases (known replies with an answer key) are kept outside the plugin, because real threads are not published with
it. See the skill's Testing section.
