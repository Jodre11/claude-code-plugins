# Web Search Plugin

Search the web via `ddgr-cached`, a caching wrapper around `ddgr` (DuckDuckGo CLI). No API key,
no tracking. Handles rate limits automatically with exponential backoff and local caching.

## Usage

The skill triggers automatically when Claude Code needs to search the web, or can be
invoked explicitly with `/web-search`.

## Prerequisites

- `ddgr` — `brew install ddgr`
- `jq` — `brew install jq`
- Python 3 — required by `ddgr` and the caching wrapper

## Installation

    claude plugins install web-search@jodre11-plugins

The `ddgr-cached` wrapper in `bin/` is used automatically by the skill. Ensure `ddgr` and `jq`
are on your `PATH`.

## Caching and Rate Limits

Results are cached locally in `~/.cache/ddgr-cached/cache.db` (SQLite). Identical queries within
the TTL window (default: 1 hour) return instantly without hitting DuckDuckGo.

When DuckDuckGo rate-limits a request, the wrapper retries with exponential backoff (up to 3
attempts) before returning a structured error with guidance to retry later.

### Configuration

| Environment Variable | Default | Purpose |
|---------------------|---------|---------|
| `DDGR_CACHE_TTL` | `3600` | Cache TTL in seconds |
| `DDGR_MAX_RETRIES` | `3` | Max retry attempts on rate limit |

### Maintenance

```bash
# View cache statistics
ddgr-cached --cache-stats

# Clear all cached results
ddgr-cached --clear-cache
```
