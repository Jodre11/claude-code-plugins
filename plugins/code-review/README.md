# Code Review Plugin

Deep code review using specialist agents, cross-review agents, and a frontier-model
synthesiser. Includes a PR review skill and commands for pre-review analysis and
addressing PR comments.

### Phase 0: intent ledger and CI status

Before any specialists run, the pipeline captures the change's intent and CI status.

**Intent ledger:** the pipeline reads (in priority order) any in-diff prose document
(`docs/`, `design/`, `specs/`, `rfcs/`, `proposals/`, `adr/`, or repo-configured paths via
`.claude/code-review.toml`), a verbatim prompt block (`Prompt:` section in the PR body or
commit message), the PR body itself, and (for local pre-review only) the branch commit
subjects. The first source containing a narrative paragraph (≥ 2 sentences, > 7 words,
not a verbatim PR template) becomes the ledger. Without a sufficient source, the pipeline
halts with `REQUEST_CHANGES` (PR mode) or an inline prompt (local mode) — no specialists
fan out, no synthesiser is dispatched.

**CI status (PR mode only):** after the body check, the pipeline fetches `gh pr checks`.
Definitive failures (`FAILURE`, `ERROR`, `ACTION_REQUIRED`) and transient failures
(`TIMED_OUT`) prompt for explicit reviewer acknowledgement before fan-out. `CANCELLED` is
not treated as a failure (multi-trigger workflows legitimately cancel one trigger when
another takes over). The synthesiser constrains the verdict to `REQUEST_CHANGES` or
`COMMENT` whenever definitive failures are present — it never recommends `APPROVE`.

### Specialists

The full review path dispatches 8 core specialists (up to 13 with all conditionals):
`security-reviewer`, `correctness-reviewer`, `consistency-reviewer`, `style-reviewer`,
`archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer`, plus
conditional specialists by file type: `jbinspect-reviewer` (C#), `ui-reviewer` (visual
components), `eslint-reviewer` (JS/TS), `ruff-reviewer` (Python incl. notebooks), and
`trivy-reviewer` (IaC: Terraform, Dockerfile, Kubernetes, Helm, CFN). The four
static-analysis specialists (`jbinspect`, `eslint`, `ruff`, `trivy`) share the
cross-cutting contract in `includes/static-analysis-context.md` and are excluded from
cross-review (their tool output does not benefit from cross-domain evaluation).

### Version-freshness rule

For dependencies and GitHub Actions newly introduced or modified by the diff, the
`security-reviewer` verifies against the live registry that the chosen version is current.
Older versions always produce a Suggestion finding. With clear justification (inline
comment, commit message, or PR body explaining *why* this version is required), the finding
is framed as "noted, no action required" — the version is still recorded so the reasoning
appears in the review trail. Without justification, the framing is "consider upgrading or
document the constraint". When a stale version also has a known advisory, the
version-safety check escalates it to Important or Critical via the security path.

## Architecture

The review pipeline (`includes/review-pipeline.md`) handles all routing:

1. **Inline prep** — Phase 0 intent ledger, Phase 0.6 CI status gate, base branch determination, diff measurement, C#/UI/deletion/security detection
2. **Trivial-mode (Phase 0.7)** — orchestrator-only mini-review for docs/config-only diffs (≤3 files, ≤30 lines, allow-listed extensions, excluding load-bearing prompt paths under `plugins/*/agents|skills|commands|includes/`). Hard cap of 3 inline comments and a user-confirm gate before posting. Override with the `--force` argument or `intent.skip_trivial_check = true` in `.claude/code-review.toml`. Falls through to the lightweight or full path when the bar is not met.
3. **Lightweight path** — small diffs (≤5 files, ≤150 lines, no significant deletions, no security-sensitive areas) route to the `code-analysis` agent
4. **Full review pipeline** — larger diffs dispatch 8 core specialists plus up to 5 conditional specialists (C#, UI, JS/TS, Python, IaC) in parallel, then fresh cross-review agents evaluate peer findings (excluding the four static-analysis specialists — see `includes/static-analysis-context.md`), then a synthesiser produces a tiered report

## Agents

| Agent | Focus |
|---|---|
| `code-analysis` | Lightweight single-agent review (small diffs) |
| `security-reviewer` | Injection, auth bypass, secrets, OWASP top 10, version safety/pinning/freshness, SSRF, path traversal |
| `correctness-reviewer` | Logic errors, off-by-one, null derefs, race conditions, async/await pitfalls |
| `consistency-reviewer` | Violations of project conventions (CLAUDE.md, .editorconfig, linting configs) |
| `style-reviewer` | Readability, unnecessary complexity, dead code, naming clarity |
| `archaeology-reviewer` | Investigates deleted/modified code for hidden historical intent |
| `reuse-reviewer` | Missed reuse of existing utilities, helpers, and patterns |
| `efficiency-reviewer` | Performance issues, N+1 patterns, missed concurrency, resource leaks |
| `alignment-reviewer` | Intent drift and scope creep against the captured intent ledger |
| `jbinspect-reviewer` | JetBrains InspectCode static analysis for C# (conditional — `.cs` files only) |
| `eslint-reviewer` | ESLint or Biome static analysis for JS/TS (conditional — `.js`/`.jsx`/`.mjs`/`.cjs`/`.ts`/`.tsx`/`.mts`/`.cts`/`.vue`/`.svelte` files only) |
| `ruff-reviewer` | Ruff static analysis for Python (conditional — `.py`/`.ipynb` files only; notebooks via Ruff ≥ 0.6.0 or `nbqa` fallback) |
| `trivy-reviewer` | `trivy config` IaC security analysis (conditional — Terraform / Dockerfile / Kubernetes / Helm / CFN files only) |
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
- `eslint` or `biome` — optional, only needed for JS/TS projects. The reviewer prefers project-local binaries (`<project>/node_modules/.bin/`) over global; install via the project's own `npm install` rather than globally.
- `ruff` (`brew install ruff`) — optional, only needed for Python projects. For Jupyter notebook support on Ruff < 0.6.0, also install `nbqa` (`pip install nbqa`).
- `trivy` (`brew install trivy`) — optional, only needed for IaC security analysis. First run on a clean machine fetches the policy DB (~10s slower); subsequent runs are fast.
- `playwright-cli` skill — optional, enables visual verification of UI reviewer findings

## Installation

    claude plugins install code-review@jodre11-plugins
