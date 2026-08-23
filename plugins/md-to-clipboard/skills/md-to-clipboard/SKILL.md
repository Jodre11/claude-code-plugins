---
name: md-to-clipboard
description: Use when the user wants to share content via Teams, Slack, Outlook, or other rich-text apps that don't render pasted raw Markdown. Shapes the content for its recipient, then copies it to the macOS clipboard as rich text.
---

# Markdown to Rich Text Clipboard

Shapes content for the person receiving it, then copies it as rich text to the macOS
clipboard using `md2clip`.

## Prerequisites

- macOS
- `pandoc` installed (`brew install pandoc`)
- `md2clip` on PATH (ships with this plugin — run the symlink command from the README)

## Establish channel and recipient first

Two facts determine the output. Infer them silently when the user has already supplied them
("send this to my manager on Teams" needs no questions); otherwise ask before copying anything.

1. **Channel** — Teams or Outlook. Selects the `md2clip` flag. **Never guess this.** A wrong
   guess means the user pastes, finds it malformed, and has to ask again.
2. **Recipient** — which tone tier below, and what the recipient has to do with the message.

Ask with an `AskUserQuestion` picker. Both are closed, repeated choices, which is what a picker
is good at.

If the user asks for a verbatim copy, skip both gates and format the content as-is.

## Shaping the content

Keep what changes the recipient's decision. Cut what does not, however accurate or informative
it is — thorough-but-irrelevant context is the main reason recipients stop reading. Length is a
consequence of that filter, never a target.

All tiers: full sentences, first person, no dropped subject pronouns. Never headline or telegram
register ("Recommend switching X" → "I'd recommend we switch X").

Structure has to earn its place, and this cuts both ways. A table is right when several
comparable items share the same attributes; a numbered list is right when the recipient has to
do things in order; a heading is right when there are genuinely separate sections to navigate
between. A heading above a single paragraph, or bullets that are only sentences with a dot in
front, are decoration — use prose. Never discard a genuinely comparative table to hit a length.

| Tier | Shape |
|---|---|
| engineer | Every file path, identifier and code block that bears on the problem stays, verbatim. Cut surrounding context that doesn't. Structure as the content warrants. |
| manager | The recommendation first, then the minimum justification, then the ask. No code. Keep a table only if it is genuinely comparative. |
| executive | Outcome, impact, ask, in three to five sentences. No code, no file paths. A small comparative table is welcome where it replaces sentences rather than adding to them. |

Calibration sample for the manager tier — match this register:

> I'd recommend we switch Claude Code over to its built-in Concise output style. It removes the
> narration from responses, but it explicitly preserves error output, security warnings and
> review findings, so nothing that actually matters gets shorter. It's a single line of
> configuration and it takes effect from the next session. Can you give me the go-ahead to apply
> it globally, rather than one repo at a time?

These shape rules are specific instructions for this task. They take precedence over ambient
output-style formatting guidance (`Concise`, `Explanatory`) which addresses conversational replies.

## Copying

1. **Write the shaped content** to `$CLAUDE_TEMP_DIR/clipboard-export.md`, or use the user's
   existing `.md` file when copying verbatim.

2. **Run `md2clip`** with the flag for the channel established above:

       md2clip $CLAUDE_TEMP_DIR/clipboard-export.md              # Teams (default)
       md2clip --outlook $CLAUDE_TEMP_DIR/clipboard-export.md    # Outlook

   The script handles all sanitisation, HTML conversion, post-processing, and clipboard copy.
   `--debug` prints the HTML instead of writing the clipboard.

3. **Tell the user** what is on the clipboard, for which recipient, and in which format — so a
   wrong tier or channel is caught before they paste rather than after.

## What `md2clip` handles internally

- Sanitises Unicode punctuation (em dashes, smart quotes)
- Converts Markdown to HTML via pandoc (`--ascii`)
- Joins pandoc's line-wrapped paragraphs onto single lines
- Strips `<p>` tags (Teams ignores paragraph margins)
- Inserts blank lines between paragraphs for single-line-gap spacing
- Simplifies pandoc code block wrappers to plain `<code>`
- Removes excessive gaps around lists
- Copies HTML to clipboard via JXA/NSPasteboard

## Teams HTML Compatibility Reference

Teams' HTML sanitiser is aggressive. It keeps:

| Element | Renders as |
|---|---|
| `<code>` | Monospace font + grey background |
| `<ul>/<li>` | Bullet list |
| `<ol>/<li>` | Numbered list |
| `<strong>` | Bold |
| `<em>` | Italic |
| `<br>` | Line break (full line height, minimum enforced) |
| `<a href>` | Clickable link |
| `<table>` | Rendered table with borders |

Teams strips or ignores: `<p>` margins, `style` attributes, `<pre>`, `<div>`, CSS `margin`/`padding`.

## Paragraph Spacing

Blank lines in the HTML source produce single-line gaps in Teams. This is the correct approach.
Avoid `<span style="font-size:1px"><br></span>` — Teams enforces minimum line height on any
`<br>`, producing double-height gaps regardless of the font-size hack.
