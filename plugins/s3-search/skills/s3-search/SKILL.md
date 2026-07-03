---
name: s3-search
description: Use when the user asks about S3 bucket contents, file deliveries, data gaps, or needs to list or search files in S3. Also use when the user references zonal files, bank statements, or source data in S3.
---

# S3 Search

Search and list files in Amazon S3 buckets via `s3search`, a global .NET CLI tool with
grep-like features.

## Defaults

Check auto-memory for default profile, bucket, and region. Always apply stored defaults
unless the user specifies otherwise. If no defaults are found in memory, ask the user for
the bucket name and AWS profile.

## Commands

### List files

```bash
s3search ls <bucket> [--profile <profile>] [options]
```

| Flag | Purpose |
|------|---------|
| `--prefix/-x <path>` | Filter by key prefix |
| `--include <glob>` | Glob pattern (e.g. `"*.csv"`, `"**/*.txt"`) |
| `--tree` | Show prefix/directory structure as a tree (ignores `--include`) |

### Search file contents

```bash
s3search grep <bucket> <regex> [--profile <profile>] [options]
```

| Flag | Purpose |
|------|---------|
| `--prefix/-x <path>` | Filter by key prefix |
| `--name/-n <glob>` | Glob pattern to filter files |
| `-i` | Case-insensitive search |
| `-c` | Count of matching lines per file |
| `-l` | Print only filenames with matches |
| `-L` | Print only filenames without matches |
| `-A/-B/-C <n>` | Context lines after/before/both |
| `-v` | Invert match (non-matching lines) |
| `-j <n>` | Parallel downloads (default: 4) |

### Check authentication

```bash
s3search auth status
```

## Command Selection Guide

| Need | Command |
|------|---------|
| What files are in a prefix? | `s3search ls` with `--prefix` |
| How is the bucket organised? | `s3search ls --tree` |
| How many files match a pattern? | `s3search ls` with `--include`, count in summary |
| Find specific content in files | `s3search grep` |
| Which files contain a value? | `s3search grep -l` |
| Which files are missing a value? | `s3search grep -L` |

## Output Handling

- **Never** dump raw CLI output to the user
- Interpret results and answer the original question directly
- Summarise: file counts, date ranges, patterns, gaps, sizes
- For large result sets (50+ lines), write raw output to `CLAUDE_TEMP_DIR` and present a
  summary to the user

## Error Handling

If authentication fails, tell the user to run `aws sso login` with the appropriate profile
(check auto-memory for the default profile). Do not attempt automatic SSO login.

## Prerequisites

- `s3search` global .NET tool (v1.1.0+): `dotnet tool list -g | grep s3search`
- AWS SSO session authenticated for the target profile
