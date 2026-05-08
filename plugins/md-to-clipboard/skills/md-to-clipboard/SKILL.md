---
name: md-to-clipboard
description: Use when the user wants to share Markdown content via Teams, Slack, Outlook, or other rich-text apps that don't render pasted raw Markdown. Converts Markdown to rich text on the macOS clipboard so it pastes as formatted text.
---

# Markdown to Rich Text Clipboard

Copies Markdown as Teams-compatible rich text to the macOS clipboard using `md2clip`.

## Prerequisites

- macOS
- `pandoc` installed (`brew install pandoc`)
- `md2clip` on PATH (ships with this plugin — run the symlink command from the README)

## Workflow

1. **Does the content contain a fenced code block?** If yes, STOP — see "Code blocks: use
   plain text + native Teams fence" below. `md2clip` cannot make multi-line code blocks render
   correctly in Teams.

2. **Get the Markdown content.** Either:
   - The user points to an existing `.md` file, OR
   - Write the content to a temp file: `$CLAUDE_TEMP_DIR/clipboard-export.md`

3. **Run `md2clip`:**

       md2clip $CLAUDE_TEMP_DIR/clipboard-export.md

   The script handles all sanitisation, HTML conversion, post-processing, and clipboard copy.

4. **Tell the user** the rich text is on their clipboard and ready to paste.

## Code blocks: use plain text + native Teams fence

Teams renders multi-line code correctly only via its own native code block (typed as ` ``` ` in
the message box, or picked from the formatting menu). HTML routes that look plausible all fail:

- `<code>` with `<br>` between lines → Teams splits each line into its own inline code chip.
- `<code>` with real newlines inside (no `<br>`) → Teams collapses the newlines, rendering
  one long line.
- `<pre><code>` is documented as stripped by Teams' sanitiser; not retested here.

**Workflow when the user wants to share code:**

1. Copy the raw code to the clipboard as **plain text** (not HTML):

       pbcopy < path/to/file

2. Tell the user: "In Teams, type ` ``` ` to open a native code block, then paste."

Do not route code through `md2clip` — the skill is for prose (bold, italic, lists, links,
tables), not code.

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

`<code>` is monospace but inline only — multi-line code does not work via HTML (see "Code
blocks: use plain text + native Teams fence" above).

## Paragraph Spacing

Blank lines in the HTML source produce single-line gaps in Teams. This is the correct approach.
Avoid `<span style="font-size:1px"><br></span>` — Teams enforces minimum line height on any
`<br>`, producing double-height gaps regardless of the font-size hack.
