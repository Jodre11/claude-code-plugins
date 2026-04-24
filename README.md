# Claude Code Plugins

Personal plugin marketplace for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Plugins

| Plugin | Description |
|---|---|
| [code-review](plugins/code-review/) | 10 specialist code review agents, PR review skill, pre-review and address-pr-comments commands |
| [web-search](plugins/web-search/) | Web search via local SearXNG — self-hosted, no API key, no tracking |
| [playwright-cli](plugins/playwright-cli/) | Browser automation via `playwright-cli` — testing, form filling, screenshots, data extraction |
| [md-to-clipboard](plugins/md-to-clipboard/) | Convert Markdown to rich text on the macOS clipboard for pasting into Teams, Slack, Outlook |

## Installation

Register the marketplace in `~/.claude/settings.json`, then plugins auto-update from GitHub on
each session start:

```jsonc
// ~/.claude/settings.json
{
  "enabledPlugins": {
    "code-review@jodre11-plugins": true,
    "web-search@jodre11-plugins": true,
    "playwright-cli@jodre11-plugins": true,
    "md-to-clipboard@jodre11-plugins": true
  },
  "extraKnownMarketplaces": {
    "jodre11-plugins": {
      "source": {
        "source": "github",
        "repo": "Jodre11/claude-code-plugins"
      }
    }
  }
}
```

Plugins are cloned from the repo to `~/.claude/plugins/marketplaces/jodre11-plugins/`. When
commits are pushed to `main`, Claude Code pulls the changes on the next session start — no
manual reinstall required. Each plugin's `bin/` directory is added to PATH automatically.

## Prerequisites

| Plugin | Dependencies |
|---|---|
| code-review | `jb` (JetBrains CLI) — optional, only for C# projects |
| web-search | Docker Desktop + SearXNG container (`searxng-ctl.sh start`), `jq` (`brew install jq`) |
| playwright-cli | `playwright-cli` (`brew install playwright-cli` or `npx playwright-cli`) |
| md-to-clipboard | `pandoc` (`brew install pandoc`), `md2clip` (ships with plugin — see [setup](plugins/md-to-clipboard/README.md)) |

## Licence

[MIT](LICENSE)
