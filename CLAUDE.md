# Claude Code Plugin Marketplace

Personal plugin marketplace for Claude Code. Each plugin lives under `plugins/<name>/` with its
own `.claude-plugin/plugin.json` manifest, skills, agents, commands, and tools.

## Versioning

Plugin `plugin.json` files intentionally omit the `version` field. Claude Code resolves versions
from the git commit SHA for relative-path sources in git-hosted marketplaces — every push to
`main` is automatically a new version. Do not add `version` fields to `plugin.json`.

## Structure

```
.claude-plugin/marketplace.json    # marketplace catalogue
plugins/<name>/
  .claude-plugin/plugin.json       # plugin manifest (no version field)
  skills/<skill>/SKILL.md          # slash-command skills
  agents/<agent>.md                # agent definitions
  commands/<command>.md            # command definitions
  includes/                        # shared includes (not directly exposed)
  bin/                             # executables (added to PATH automatically)
  tools/                           # CLI tools
```

## Conventions

- Markdown and JSON use 2-space indentation (see `.editorconfig`)
- Shell scripts use 4-space indentation
- All text files use LF line endings (see `.gitattributes`)
- Executables in `bin/` and `tools/` must be `chmod +x`
- Plugins cannot reference files outside their directory — the plugin cache copies only the
  plugin subtree. Use symlinks for shared files if needed.

## Plugin Authoring

Every command (`commands/*.md`) and skill (`skills/<name>/SKILL.md`) file must start with YAML
frontmatter. Without it — or without a `description` — Claude Code falls back to displaying the
item as `/<plugin-name>:<command-name>` in the slash menu instead of the cleaner
`/<command-name> (<plugin-name>) <description>` form.

### Required fields

- `name` — matches the filename (for commands) or the folder name (for skills). Kebab-case.
- `description` — one short sentence. Used by the slash menu and by Claude when selecting skills.

### Optional fields

- `argument-hint` — placeholder shown in the slash menu (e.g. `"[pr-number-or-url]"`).
- `allowed-tools` — restrict which tools the skill may use (e.g. `Bash(playwright-cli:*)`).

### Required layout

Leave a **blank line between the closing `---` and the first line of body content**. Some parsers
are strict about this and the slash-menu display will fall back to the prefixed form without it.

### Template — command

```markdown
---
name: my-command
description: One short sentence describing what this command does
argument-hint: "[optional-hint]"
---

Body content starts here.
```

### Template — skill

```markdown
---
name: my-skill
description: Use when ... (describe the trigger conditions so Claude knows when to invoke)
---

# My Skill

Body content starts here.
```

### Other conventions

- One plugin per top-level folder under `plugins/`.
- Update the plugin table in `README.md` when adding a new plugin.
- Update the prerequisites table in `README.md` if the plugin depends on external tooling.

## Testing

Run `tests/run.sh` to validate plugin structure. The test suite checks:
- Manifest schema (marketplace.json + plugin.json fields, no version field)
- Conventions (LF line endings, indentation, final newlines, executable bits)
- Cross-references (include paths resolve, expected directories populated)
- Sync-note consistency (validation regexes and base-branch steps match across files)

## Secret Scanning

Two git hooks keep sensitive data out of the repository. `.githooks/pre-commit` scans every added
line for secret-shaped values and identity markers (the patterns are in
`.githooks/guard-config.sh`), then runs gitleaks over the staged changes; `.githooks/pre-push`
repeats both over every commit a push would publish, its message, author and committer included.
CI runs gitleaks, a pattern-sync check (`tests/test-pattern-sync.sh`) and the guard suites
(`tests/test-git-guards.sh`, `tests/test-pre-push.sh`, `tests/test-history-push.sh`) on every push
to `main` and every pull request into it.

- **Activation:** git does not activate the hooks on clone; run
  `git config core.hooksPath .githooks` once per clone. The hooks use gitleaks 8.25.0 or later
  (8.30.1 is tested); without it they warn and run the pattern scan alone.
- **Local pattern lists:** to screen for names that must not be published without publishing them,
  put them in the gitignored `.githooks/identity-patterns.local` and
  `.githooks/always-patterns.local`, one POSIX ERE per line; either may be a symlink to a list kept
  elsewhere. The hooks refuse to commit or push either one.
- **Ignored local patterns:** `LOCAL_IDENTITY_IGNORE` in `.githooks/guard-config.sh` names, by exact
  text, the local identity patterns this repository disregards because they are its own public
  identity: the owner's handle and the name of the S3 tool the `s3-search` plugin wraps. Every other
  local pattern still applies.
- **Bypass:** `SKIP_PATTERN_SCAN=1 git commit` (or `git push`) skips the pattern scan only, for a
  file that must carry a pattern; say so in the commit body. gitleaks, when installed, always runs
  and has no bypass: clear a false positive with a targeted `[[allowlists]]` entry in
  `.gitleaks.toml`, committed with the change.
- **Shared files:** every guard file but `guard-config.sh` and `.gitleaks.toml` is a byte-identical
  copy of the one in the public claude-settings-template and dotfiles-template repositories. Change
  it there first, then copy it here.
