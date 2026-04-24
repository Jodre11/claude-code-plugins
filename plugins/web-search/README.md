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
