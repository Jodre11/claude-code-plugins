---
name: web-search
description: Use when you need to search the web for URLs, documentation, error messages, or current information. Also use when the user asks for links or references you cannot confidently produce from memory.
---

# Web Search

Search the web via `web-search`, a caching wrapper around a SearXNG instance at `SEARXNG_URL` (local or
remote). No tracking, no API key. Results are cached locally to avoid redundant requests.

## When to Use

- User asks for URLs or links
- Need to verify a URL before giving it to the user
- Looking up error messages, library docs, or current information
- Any time you would otherwise say "I can't search the web"

## Usage

```bash
web-search -n 5 "search query"
```

Key flag: `-n N` (result count, default 5).

## Output Format

JSON array of objects:

```json
[
  {"url": "...", "title": "...", "abstract": "..."},
  ...
]
```

Extract fields with jq:

```bash
web-search -n 3 "EFF Cover Your Tracks" | jq '.[].url'
```

## Wrapper Flags

| Flag | Purpose |
|------|---------|
| `-n N` | Number of results (default: 5) |
| `--cache-ttl N` | Cache TTL in seconds (default: 3600, also via `WEB_SEARCH_CACHE_TTL`) |
| `--max-retries N` | Max retry attempts on error (default: 3, also via `WEB_SEARCH_MAX_RETRIES`) |
| `--clear-cache` | Purge all cached results and reset statistics |
| `--cache-stats` | Show cache hit/miss counts and database size |

## Error Handling

If SearXNG is unreachable (instance down, network or VPN path unavailable), the wrapper retries with
exponential backoff (2s, 4s, 8s) then returns:

```json
{
  "error": "Search failed after 3 retries for query: ...",
  "suggestion": "Check that SearXNG is reachable at the configured SEARXNG_URL. Verify network connectivity.",
  "results": []
}
```

**Follow the suggestion.** Do NOT abandon this tool — tell the user the instance is unreachable, and retry once it
is back.

## Prerequisites

- A SearXNG instance with the JSON output format enabled
- `SEARXNG_URL` set to its base URL (default `http://localhost:8888`)

## Caching

- Results cached in `~/.cache/web-search/cache.db` (SQLite)
- Default TTL: 1 hour
- `web-search --cache-stats` to inspect hit rates
- `web-search --clear-cache` to purge stale data

## Common Mistakes

- Guessing URLs instead of searching — always search and verify
- Abandoning search when it fails — check that `SEARXNG_URL` is reachable instead
