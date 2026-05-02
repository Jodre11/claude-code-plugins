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

## Secret Scanning

A pre-commit hook runs pattern-based secret scanning on staged changes. The CI gitleaks workflow
provides a second layer of protection. To manage false positives, add entries to `.gitleaks.toml`
(allowlist) rather than bypassing the hook with `SKIP_SECRET_SCAN=1`.
