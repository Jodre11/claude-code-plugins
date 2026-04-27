---
name: s3-search
description: Use when the user asks about S3 bucket contents, file deliveries, data gaps, or needs to list or search files in S3. Also use when the user references zonal files, bank statements, or source data in S3.
---

# S3 Search

Search and list files in Amazon S3 buckets via `internal-project-5`, a global .NET CLI tool with
grep-like features.

## Defaults

Always apply these unless the user specifies otherwise:

| Setting | Default |
|---------|---------|
| Profile | `--profile your-aws-profile` |
| Bucket | `your-bucket-name` |
| Region | None (inherited from profile) |

## Commands

### List files

```bash
internal-project-5 ls <bucket> --profile your-aws-profile [options]
```

| Flag | Purpose |
|------|---------|
| `--prefix/-x <path>` | Filter by key prefix |
| `--include <glob>` | Glob pattern (e.g. `"*.csv"`, `"**/*.txt"`) |
| `--tree` | Show prefix/directory structure as a tree (ignores `--include`) |

### Search file contents

```bash
internal-project-5 grep <bucket> <regex> --profile your-aws-profile [options]
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
internal-project-5 auth status
```

## Command Selection Guide

| Need | Command |
|------|---------|
| What files are in a prefix? | `internal-project-5 ls` with `--prefix` |
| How is the bucket organised? | `internal-project-5 ls --tree` |
| How many files match a pattern? | `internal-project-5 ls` with `--include`, count in summary |
| Find specific content in files | `internal-project-5 grep` |
| Which files contain a value? | `internal-project-5 grep -l` |
| Which files are missing a value? | `internal-project-5 grep -L` |

## Output Handling

- **Never** dump raw CLI output to the user
- Interpret results and answer the original question directly
- Summarise: file counts, date ranges, patterns, gaps, sizes
- For large result sets (50+ lines), write raw output to `CLAUDE_TEMP_DIR` and present a
  summary to the user

## Error Handling

If authentication fails, tell the user to run:

```bash
aws sso login --profile your-aws-profile
```

Do not attempt automatic SSO login.

## Prerequisites

- `internal-project-5` global .NET tool (v1.1.0+): `dotnet tool list -g | grep internal-project-5`
- AWS SSO session authenticated for `your-aws-profile`
