---
name: web-search
description: Use when you need to search the web for URLs, documentation, error messages, or current information. Also use when the user asks for links or references you cannot confidently produce from memory.
---

# Web Search

Search the web via `ddgr-cached`, a caching wrapper around `ddgr` (DuckDuckGo CLI). No tracking,
no API key. Results are cached locally to avoid redundant requests and rate limits.

## When to Use

- User asks for URLs or links
- Need to verify a URL before giving it to the user
- Looking up error messages, library docs, or current information
- Any time you would otherwise say "I can't search the web"

## Usage

```bash
ddgr-cached -n 5 "search query"
```

Key flags: `-n N` (result count, max 25). The `--json` and `--np` flags are added automatically.

Pipe through `jq` to extract specific fields:

```bash
ddgr-cached -n 3 "EFF Cover Your Tracks" | jq '.[].url'
```

## Wrapper Flags

| Flag | Purpose |
|------|---------|
| `--cache-ttl N` | Cache TTL in seconds (default: 3600, also via `DDGR_CACHE_TTL` env var) |
| `--max-retries N` | Max retry attempts on rate limit (default: 3, also via `DDGR_MAX_RETRIES` env var) |
| `--clear-cache` | Purge all cached results and reset statistics |
| `--cache-stats` | Show cache hit/miss counts and database size |

## ddgr Passthrough Flags

| Flag | Purpose |
|------|---------|
| `-t d` | Results from past day |
| `-t w` | Results from past week |
| `-w SITE` | Restrict to a specific site |
| `-r us-en` | Region-specific results |

## Rate Limit Handling

`ddgr-cached` handles DuckDuckGo rate limits automatically:

1. On rate limit, it retries with exponential backoff (2s, 4s, 8s) plus jitter
2. Progress is reported to stderr so you can see retry attempts
3. On persistent failure after all retries, it returns a structured JSON error:
   ```json
   {
     "error": "DuckDuckGo rate limited after 3 retries for query: ...",
     "suggestion": "Try again in 2-3 minutes. ...",
     "results": []
   }
   ```

**If you receive an error response with a `suggestion` field, follow the suggestion.** Do NOT
abandon this tool after a rate limit — it is temporary. Continue with other work and retry later.

## Caching

- Results are cached in `~/.cache/ddgr-cached/cache.db` (SQLite)
- Default TTL is 1 hour — identical queries within that window return instantly
- Use `ddgr-cached --cache-stats` to inspect hit rates
- Use `ddgr-cached --clear-cache` to purge stale data

## Common Mistakes

- Guessing URLs instead of searching — always search and verify
- Abandoning the tool after a rate limit — the wrapper retries automatically, and rate limits are
  temporary
- Passing `--json` or `--np` — these are added automatically by the wrapper
