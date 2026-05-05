# Plugin Authoring Conventions

This repo publishes a personal marketplace of Claude Code plugins. Follow these conventions for every new command (`commands/*.md`) and skill (`skills/<name>/SKILL.md`).

## Frontmatter is mandatory

Every command and skill file must start with YAML frontmatter. Without it — or without a `description` — Claude Code falls back to displaying the item as `/<plugin-name>:<command-name>` in the slash menu instead of the cleaner `/<command-name> (<plugin-name>) <description>` form.

### Required fields

- `name` — matches the filename (for commands) or the folder name (for skills). Kebab-case.
- `description` — one short sentence. Used by the slash menu and by Claude when selecting skills.

### Optional fields

- `argument-hint` — placeholder shown in the slash menu (e.g. `"[pr-number-or-url]"`).
- `allowed-tools` — restrict which tools the skill may use (e.g. `Bash(playwright-cli:*)`).

### Required layout

Leave a **blank line between the closing `---` and the first line of body content**. Some parsers are strict about this and the slash-menu display will fall back to the prefixed form without it.

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

## Other conventions

- One plugin per top-level folder under `plugins/`.
- Update the plugin table in `README.md` when adding a new plugin.
- Update the prerequisites table in `README.md` if the plugin depends on external tooling.
