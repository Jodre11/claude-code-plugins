# Web Search Plugin

Search the web via a local SearXNG instance with caching and automatic retry. No API key, no
tracking. Self-hosted metasearch aggregating results from Google, Bing, DuckDuckGo, Brave,
Wikipedia, and GitHub.

## Usage

The skill triggers automatically when Claude Code needs to search the web, or can be
invoked explicitly with `/web-search`.

## Prerequisites

- Docker Desktop running
- SearXNG container started (via LaunchAgent or `searxng-ctl.sh start`)
- Python 3 — required by the caching wrapper
- `jq` — for field extraction in the shell

## Installation

    claude plugins install web-search@jodre11-plugins

The `web-search` wrapper in `bin/` is used automatically by the skill.

## Why a CLI Wrapper Instead of an MCP Server

MCP-based search servers (e.g. `mcp-searxng`, `searxng-mcp-server`) expose SearXNG as native
tools, but the model receives the full tool result payload — engine metadata, scores, parsed URLs,
thumbnails, and often entire page bodies for "deep search" modes. This easily costs 2,000–10,000+
tokens per search.

This plugin takes a different approach: the Python wrapper queries SearXNG, strips the response
down to three fields (`url`, `title`, `abstract`), and returns a compact JSON array via `stdout`.
The model sees ~300–500 tokens per search. All filtering, caching, retries, and error handling
happen in Python before the model is involved.

| | CLI wrapper (this plugin) | MCP server |
|---|---|---|
| Tokens per search | ~300–500 | 2,000–10,000+ |
| Caching | SQLite, 1hr TTL | Varies (often none) |
| Dependencies | Python 3 (stdlib only) | Node.js runtime + MCP SDK |
| Integration | `Bash` tool call | Native tool in tool list |

The only trade-off is ergonomics — an MCP tool appears natively in the tool list, whereas this
plugin requires the `/web-search` skill or a direct `Bash` call. For the 5–10x token saving,
that's a good trade.

## Caching and Error Handling

Results are cached locally in `~/.cache/web-search/cache.db` (SQLite). Identical queries within
the TTL window (default: 1 hour) return instantly without hitting SearXNG.

When SearXNG is unreachable (Docker not running, container stopped), the wrapper retries with
exponential backoff (up to 3 attempts) before returning a structured error with guidance to start
the container.

### Configuration

| Environment Variable | Default | Purpose |
|---------------------|---------|---------|
| `WEB_SEARCH_CACHE_TTL` | `3600` | Cache TTL in seconds |
| `WEB_SEARCH_MAX_RETRIES` | `3` | Max retry attempts on error |
| `SEARXNG_URL` | `http://localhost:8888` | SearXNG base URL |

### Maintenance

```bash
# View cache statistics
web-search --cache-stats

# Clear all cached results
web-search --clear-cache
```
