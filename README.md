# Claude Code Plugins

Personal plugin marketplace for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Plugins

| Plugin | Description |
|---|---|
| [code-review-suite](plugins/code-review-suite/) | 13 specialist code review agents (ESLint, Ruff, Trivy IaC, JetBrains InspectCode + 9 LLM specialists), PR review skill, pre-review and address-pr-comments commands |
| [web-search](plugins/web-search/) | Web search via local SearXNG — self-hosted, no API key, no tracking |
| [playwright-cli](plugins/playwright-cli/) | Browser automation via `playwright-cli` — testing, form filling, screenshots, data extraction |
| [md-to-clipboard](plugins/md-to-clipboard/) | Convert Markdown to rich text on the macOS clipboard for pasting into Teams, Slack, Outlook |
| [pdf-reader](plugins/pdf-reader/) | Extract text from any PDF — native text via poppler, scanned/image via tesseract OCR |

## Installation

Register the marketplace in `~/.claude/settings.json`, then plugins auto-update from GitHub on
each session start:

```jsonc
// ~/.claude/settings.json
{
  "enabledPlugins": {
    "code-review-suite@jodre11-plugins": true,
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
| code-review-suite | `jb` (JetBrains CLI) — optional, only for C# projects; `eslint` or `biome` (project-local via `npm install`) — optional, only for JS/TS projects; `ruff` (`brew install ruff`) — optional, only for Python projects (`nbqa` only if Ruff < 0.6.0); `trivy` (`brew install trivy`) — optional, only for IaC repos |
| web-search | Docker Desktop + SearXNG container (`searxng-ctl.sh start`), `jq` (`brew install jq`) |
| playwright-cli | `playwright-cli` (`brew install playwright-cli` or `npx playwright-cli`) |
| md-to-clipboard | `pandoc` (`brew install pandoc`), `md2clip` (ships with plugin — see [setup](plugins/md-to-clipboard/README.md)) |

## Versioning

This marketplace does not use explicit version fields in `plugin.json`. Claude Code resolves
plugin versions from the git commit SHA, so every push to `main` is automatically a new version.
Users receive updates on their next session start without any manual version bumps.

See [Version resolution](https://code.claude.com/docs/en/plugin-marketplaces#version-resolution-and-release-channels)
in the Claude Code docs for details.

## Internal tooling

- [`tests/ab/`](tests/ab/README.md) — A/B test harness for the code review suite.
  Operator-driven; runs identical inputs through the suite under different
  agent parameter configurations and captures mechanical metrics.

## Licence

[MIT](LICENSE)
