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

A pre-commit hook runs pattern-based secret scanning on staged changes. The CI gitleaks workflow
provides a second layer of protection. To manage false positives, add entries to `.gitleaks.toml`
(allowlist) rather than bypassing the hook with `SKIP_SECRET_SCAN=1`.
