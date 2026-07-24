# Adoption Glance — Design

**Date:** 2026-07-24
**Status:** Approved (design), pending implementation plan

## Problem

The marketplace author wants "some indication that it's actually shared" — a rough,
on-demand sense of how many different people pull the plugin marketplace and how often
they re-pull it. This is an adoption *pulse check*, not a monitoring system and not a
named-user roster.

## Hard constraints (why the shape is what it is)

- The plugin is distributed as files cloned to each user's machine via a git-hosted
  marketplace. It runs entirely locally; there is **no server** and therefore **no
  built-in channel** that reports installs or review runs back to the author.
- The only passive signal that reflects real install/pull activity is **GitHub clone
  traffic**, which is **anonymous by design** — GitHub exposes counts, never usernames.
  Therefore a list of *names* of users is impossible via this approach and is explicitly
  out of scope.
- Clone traffic is a **14-day rolling window**; GitHub does not retain history. A
  single fetch is a point-in-time glance, which is exactly what is wanted here.
- Claude Code marketplace `autoUpdate` re-clones the repo on startup and on every push,
  so total clones inflate relative to unique cloners. This confound is a *feature* for
  the "how often do they update" proxy but must be disclosed so counts are not
  over-read. Counts also include the author's own machines and CI, so they are an
  **upper bound**.

## Solution

A single, manually-run script that queries the GitHub traffic API for the marketplace
repo and prints a one-screen human-readable summary. No storage, no scheduling, no
history, no trend.

### Location

`scripts/adoption-glance.sh` at the repo root (the `scripts/` directory does not yet
exist and will be created). This is a repo-maintenance tool for the author, not a plugin
feature shipped to users, so it lives at the repo level rather than inside a plugin's
`bin/`.

### Dependencies

- `gh` CLI, already authenticated (owner token — the traffic endpoints are owner-only).
- `jq` for JSON extraction.
- Bash. Shell scripts in this repo use 4-space indentation, LF line endings, and must be
  `chmod +x` (see CLAUDE.md / .editorconfig / .gitattributes).

### Data fetched

Target repo: `Jodre11/claude-code-plugins`.

- `GET repos/{owner}/{repo}/traffic/clones` → `count` (total), `uniques` (unique cloners)
- `GET repos/{owner}/{repo}/traffic/views` → `count` (total), `uniques` (unique viewers)
- `GET repos/{owner}/{repo}` → `stargazers_count`, `forks_count`, `subscribers_count`

### Output (illustrative)

```
claude-code-plugins — adoption glance (14-day window)
  Unique cloners : 128        ~how many different people
  Total clones   : 416        pull volume
  Clones/person  : 3.3        ~how often each re-pulls (autoUpdate-driven)
  Unique viewers : 3
  Stars / Forks  : 0 / 0
Caveat: anonymous; includes your own machines + CI; 14-day rolling; upper bound.
```

- Clones/person is `total ÷ unique`, guarded against divide-by-zero (print `n/a` when
  unique cloners is 0).
- Output is plain text to stdout.

## Explicitly out of scope (YAGNI)

- **Named users** — impossible passively; clone traffic is anonymous.
- **Trend / history / snapshotting** — no cron, no committed data file. Deferred; the
  natural upgrade if the author later wants growth-vs-decline direction.
- **Referrers and popular paths** — noisy for a marketplace repo, low signal.
- **Per-plugin breakdown** — GitHub traffic is repo-level only; cannot be split.
- **`--json` output mode** — add later only if piping is ever needed.
- **Active telemetry / phone-home** — a separate, heavier decision with real privacy
  implications; not part of this passive approach.

## Testing

- Manual: run the script, confirm it prints the summary against the live repo.
- The repo's `tests/run.sh` validates plugin structure; a repo-level maintenance script
  is outside that suite. If a lightweight check is warranted, assert the script is
  executable and passes `bash -n` syntax validation — to be decided in the plan.

## Error handling

- If `gh` is not authenticated or lacks owner scope, the traffic endpoints return 403;
  surface a clear message rather than a raw API error.
- If `gh` or `jq` is missing, fail fast with an install hint.
