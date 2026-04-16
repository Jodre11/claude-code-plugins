# Claude Code Plugins

Personal plugin marketplace for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Plugins

| Plugin | Description |
|---|---|
| [code-review](plugins/code-review/) | 10 specialist code review agents, PR review skill, pre-review and address-pr-comments commands |
| [web-search](plugins/web-search/) | Web search via `ddgr` (DuckDuckGo CLI) — no API key, no tracking |
| [playwright-cli](plugins/playwright-cli/) | Browser automation via `playwright-cli` — testing, form filling, screenshots, data extraction |
| [md-to-clipboard](plugins/md-to-clipboard/) | Convert Markdown to rich text on the macOS clipboard for pasting into Teams, Slack, Outlook |

## Installation

Register the marketplace once, then install individual plugins:

    # Register (one-time)
    claude plugins marketplace add github:Jodre11/claude-code-plugins

    # Install individual plugins
    claude plugins install code-review@claude-code-plugins
    claude plugins install web-search@claude-code-plugins
    claude plugins install playwright-cli@claude-code-plugins
    claude plugins install md-to-clipboard@claude-code-plugins

## Prerequisites

| Plugin | Dependencies |
|---|---|
| code-review | `jb` (JetBrains CLI) — optional, only for C# projects |
| web-search | `ddgr` (`brew install ddgr`), `jq` (`brew install jq`) |
| playwright-cli | `playwright-cli` (`brew install playwright-cli` or `npx playwright-cli`) |
| md-to-clipboard | `pandoc` (`brew install pandoc`), `md2clip` (ships with plugin — see [setup](plugins/md-to-clipboard/README.md)) |

## Licence

[MIT](LICENSE)
