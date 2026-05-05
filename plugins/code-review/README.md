# Code Review Plugin

Deep code review using specialist agents, cross-review agents, and a frontier-model
synthesiser. Includes a PR review skill and commands for pre-review analysis and
addressing PR comments.

## Architecture

The review pipeline (`includes/review-pipeline.md`) handles all routing:

1. **Inline prep** — base branch determination, diff measurement, C#/UI/deletion/security detection
2. **Lightweight path** — small diffs (≤5 files, ≤150 lines, no significant deletions, no security-sensitive areas) route to the `code-analysis` agent
3. **Full review pipeline** — larger diffs dispatch 7-9 specialist agents in parallel, then fresh cross-review agents evaluate peer findings, then a synthesiser produces a tiered report

## Agents

| Agent | Focus |
|---|---|
| `code-analysis` | Lightweight single-agent review (small diffs) |
| `security-reviewer` | Injection, auth bypass, secrets, OWASP top 10, supply-chain risks, SSRF, path traversal |
| `correctness-reviewer` | Logic errors, off-by-one, null derefs, race conditions, async/await pitfalls |
| `consistency-reviewer` | Violations of project conventions (CLAUDE.md, .editorconfig, linting configs) |
| `style-reviewer` | Readability, unnecessary complexity, dead code, naming clarity |
| `archaeology-reviewer` | Investigates deleted/modified code for hidden historical intent |
| `reuse-reviewer` | Missed reuse of existing utilities, helpers, and patterns |
| `efficiency-reviewer` | Performance issues, N+1 patterns, missed concurrency, resource leaks |
| `jbinspect-reviewer` | JetBrains InspectCode static analysis for C# (conditional — `.cs` files only) |
| `ui-reviewer` | UI/UX quality, accessibility, usability (conditional — visual component files only) |
| `cross-reviewer` | Domain-focused cross-review — evaluates peer findings through a single domain lens |
| `review-synthesiser` | Frontier-model synthesis — independent deep analysis, tiered report with cross-review integration |

## Skill

- **review-gh-pr** — Review a GitHub PR with inline comments. Automatically routes to lightweight
  or full pipeline review based on diff size. Usage: `/review-gh-pr <pr-number-or-url>`

## Commands

- **pre-review** — Analyse local changes before creating a PR. Usage: `/pre-review [base-branch | EMPTY_TREE] [Path scope: <pathspec>]`
- **address-pr-comments** — Fetch unresolved PR comments and address them systematically.
  Usage: `/address-pr-comments <pr-number-or-url>`

## Known Limitations

- **Prompt injection surface:** The PR review skill and address-pr-comments command ingest PR
  titles, bodies, and review comment content from GitHub. Since this content is user-supplied, a
  malicious collaborator could craft adversarial instructions in PR descriptions or comments.
  Agent system prompts and user confirmation steps mitigate this, but treat all GitHub-sourced
  content with appropriate scepticism in multi-contributor repositories.

## Prerequisites

- `gh` (GitHub CLI) — required for PR interactions; graceful fallback for base branch if absent
- `jb` (JetBrains CLI) — optional, only needed for C# InspectCode analysis
- `playwright-cli` skill — optional, enables visual verification of UI reviewer findings

## Installation

    claude plugins install code-review@jodre11-plugins
