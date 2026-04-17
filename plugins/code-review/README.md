# Code Review Plugin

Deep code review using a team of 10 specialist agents, a PR review skill, and two commands
for pre-review analysis and addressing PR comments.

## Contents

### Agents

| Agent | Focus |
|---|---|
| `code-review-team` | Orchestrator — dispatches specialists, conducts independent analysis, synthesises findings |
| `code-analysis` | Lightweight single-agent review (used for small diffs) |
| `security-reviewer` | Injection, auth bypass, secrets, OWASP top 10, cryptographic misuse, SSRF, path traversal |
| `correctness-reviewer` | Logic errors, off-by-one, null derefs, race conditions, resource leaks |
| `consistency-reviewer` | Violations of project conventions (CLAUDE.md, .editorconfig, linting configs) |
| `style-reviewer` | Readability, unnecessary complexity, dead code, naming clarity |
| `archaeology-reviewer` | Investigates deleted/modified code for hidden historical intent |
| `reuse-reviewer` | Missed reuse of existing utilities, helpers, and patterns |
| `efficiency-reviewer` | Performance issues, N+1 patterns, missed concurrency, resource leaks |
| `jbinspect-reviewer` | JetBrains InspectCode static analysis for C# (conditional — only dispatched for .cs files) |

### Skill

- **review-pr** — Review a GitHub PR with inline comments. Automatically routes to lightweight
  or full team review based on diff size. Usage: `/review-pr <pr-number-or-url>`

### Commands

- **pre-review** — Analyse local changes before creating a PR. Usage: `/pre-review [base-branch]`
- **address-pr-comments** — Fetch unresolved PR comments and address them systematically.
  Usage: `/address-pr-comments <pr-number-or-url>`

## Prerequisites

- `gh` (GitHub CLI) — required for PR interactions
- `jb` (JetBrains CLI) — optional, only needed for C# InspectCode analysis

## Installation

    claude plugins install code-review@jodre11-plugins
