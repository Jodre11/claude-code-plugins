# Code Review Plugin

Reviews a change with Claude Code's bundled `/code-review` and a set of deterministic static
analysers, and posts the result as one marked review with a verdict. Includes a PR review
skill and commands for pre-review analysis and addressing PR comments.

### CI status

**CI status (PR mode only):** before any review runs, the pipeline fetches `gh pr checks`.
Any check that is not green and settled — a failure, a time-out, or one still pending or in
progress — halts the review, with no acknowledge-to-proceed path. `CANCELLED` counts as
settled (multi-trigger workflows legitimately cancel one trigger when another takes over).
The verdict is therefore only ever computed on green CI.

### Finders

Every review runs Claude Code's bundled `/code-review` as the `native` finder, through the
`native-reviewer` agent, at the `high` effort level on the pinned range. Beside it,
conditional static analysers run by file type: `jbinspect-reviewer` (C#), `eslint-reviewer`
(JS/TS), `ruff-reviewer` (Python incl. notebooks), `trivy-reviewer` (IaC: Terraform,
Dockerfile, Kubernetes, Helm, CFN) and `housekeeper-reviewer` (dependency/version freshness
+ maintenance-health: GitHub Actions, workflow runners, npm, NuGet, Docker base images,
PyPI).

The five static-analysis specialists share the contract in
`includes/static-analysis-context.md`: the tool's severity is locked, and a `Critical` blocks
only when its rule is on the tool's `Critical-allow-list:`.

### Version-freshness rule

The `housekeeper-reviewer` verifies against the live registry that dependencies (npm,
NuGet, PyPI), GitHub Actions, runners, and Docker base images are at their latest GA
release, and flags packages the registry marks deprecated, unlisted, or yanked
(maintenance-health). Its deterministic engine
(`bin/housekeeper-freshness`) parses in-scope sources, fetches latest-GA from the
registries, and emits stale-version findings — uniform `Suggestion` severity ("staleness is
a smell, not a defect"). They render in an informational `### Dependency Freshness` table in
the review body and never affect the verdict.

## Architecture

The review pipeline (`includes/review-pipeline.md`) does inline prep, then hands every review
to the deterministic Workflow core (`workflows/review-core.js`) — the **sole orchestration
engine**. There is no inline dispatch fallback: the pipeline's Step 3.5 calls the Workflow
unconditionally, and the orchestrator only posts the sealed bundle the Workflow returns. A
plugin-shipped `PreToolUse(Agent)` hook (`hooks/reviewer-dispatch-observe.sh`) logs any
main-session reviewer dispatch in observe mode, making the single-path guarantee measurable.

1. **Inline prep** — target repository, ephemeral worktree (PR mode), branch freshness, the
   Phase 0.6 CI status gate, base branch determination, diff measurement and file-type
   detection. Step 3.5 builds the native target (repo path and pinned range) from those
   validated values.
2. **Dispatch** — `review-core` runs `native` and the selected static analysers in parallel.
   The native result is text ending in a fenced JSON array; code parses and checks it, and
   any failure means native did not run.
3. **Assemble** — code maps native's severities (`important` → Important and blocking, `nit`
   → Suggestion, `pre_existing` → Suggestion annotated pre-existing), drops a native finding
   that cites a `CLAUDE.md` outside the reviewed repository, demotes a static `Critical` that
   is not allow-listed, anchors every finding to the diff, and computes the verdict
   (`includes/verdict-rubric.md`): `NONE` when native did not run, `REQUEST_CHANGES` on any
   blocking finding, otherwise `APPROVE`.
4. **Output** — the review body (PR mode) and the pre-review report (local mode) are
   assembled in code. Findings on the same file within three lines merge into one inline
   comment and one index line, so the author sees one thread per issue.
5. **Wording pass** — once the verdict is fixed, a `comment-editor` agent rewords native's
   surfaced findings to the rules in `includes/comment-voice.md`. Code guards keep the
   original text of any field whose rewrite drops a code span, `path:line` reference, URL,
   code block or number, grows by more than 10%, or adds a number, verdict word or severity
   word. Static-analysis findings keep the tool's text. Every comment and review body the
   suite posts ends with the hidden marker `<!-- code-review-suite -->`, which
   `/address-pr-comments` and self-re-review detection use to tell the suite's posts from the
   user's own.

`orchestration.review_mode`, `orchestration.panel_size`, `review.anthropic_specialist` and
the `intent.*` keys are retired: the pipeline prints one notice per config file that still
sets them, then ignores them.

## Agents

| Agent | Focus |
|---|---|
| `native-reviewer` | Runs Claude Code's bundled `/code-review` on the pinned range and returns its text unchanged (dispatched by `review-core` only) |
| `jbinspect-reviewer` | JetBrains InspectCode static analysis for C# (conditional — `.cs` files only) |
| `eslint-reviewer` | ESLint or Biome static analysis for JS/TS (conditional — `.js`/`.jsx`/`.mjs`/`.cjs`/`.ts`/`.tsx`/`.mts`/`.cts`/`.vue`/`.svelte` files only) |
| `ruff-reviewer` | Ruff static analysis for Python (conditional — `.py`/`.ipynb` files only; notebooks via Ruff ≥ 0.6.0 or `nbqa` fallback) |
| `trivy-reviewer` | `trivy config` IaC security analysis (conditional — Terraform / Dockerfile / Kubernetes / Helm / CFN files only) |
| `housekeeper-reviewer` | Dependency/version freshness + maintenance-health — flags GitHub Actions, workflow runners, npm, NuGet, Docker base images, and PyPI packages behind latest GA or marked deprecated/unlisted/yanked (conditional — workflows + `package.json` + `*.csproj`/`*.props` + `pyproject.toml`/`requirements*.txt` + Dockerfiles; registry-backed deterministic engine) |
| `comment-editor` | Rewords native's surfaced findings to the comment-voice rules without changing what they say; guarded in code (no tools beyond `Read`; dispatched by `review-core` only) |

## Skill

- **review-gh-pr** — Review a GitHub PR and post one marked review with inline comments.
  Usage: `/review-gh-pr <pr-number-or-url>`

## Commands

- **pre-review** — Analyse local changes before creating a PR. Usage: `/pre-review [base-branch | EMPTY_TREE] [Path scope: <pathspec>]`
- **address-pr-comments** — Fetch unresolved PR comments and address them systematically. Each
  reply is fitted with the `reply-fit` plugin before anything is posted. The suite's own
  marker-bearing comments are addressed even though they are posted under your login; add
  `--include-self` to address every comment and review body you posted.
  Usage: `/address-pr-comments <pr-number-or-url> [--include-self]`

## Known Limitations

- **Prompt injection surface:** The PR review skill and address-pr-comments command ingest PR
  titles, bodies, and review comment content from GitHub. Since this content is user-supplied, a
  malicious collaborator could craft adversarial instructions in PR descriptions or comments.
  Agent system prompts and user confirmation steps mitigate this, but treat all GitHub-sourced
  content with appropriate scepticism in multi-contributor repositories.

## Prerequisites

- Claude Code with the bundled `/code-review` skill, with model invocation enabled — no
  `user-invocable-only` override for `code-review` in your settings, or the `native-reviewer`
  agent cannot call it and every review runs on the static analysers alone
- `reply-fit` plugin (same marketplace) — declared in `plugin.json` `dependencies`, so it installs with the suite; the suite does not load while it is disabled
- `gh` (GitHub CLI) — required for PR interactions; graceful fallback for base branch if absent
- `jb` (JetBrains CLI) — optional, only needed for C# InspectCode analysis
- `eslint` or `biome` — optional, only needed for JS/TS projects. The reviewer prefers project-local binaries (`<project>/node_modules/.bin/`) over global; install via the project's own `npm install` rather than globally.
- `ruff` (`brew install ruff`) — optional, only needed for Python projects. For Jupyter notebook support on Ruff < 0.6.0, also install `nbqa` (`pip install nbqa`).
- `trivy` (`brew install trivy`) — optional, only needed for IaC security analysis. First run on a clean machine fetches the policy DB (~10s slower); subsequent runs are fast.
- `python3` (≥3.11 for PyPI `pyproject.toml` parsing via `tomllib`) — required for the `housekeeper-reviewer` dependency-freshness engine (`bin/housekeeper-freshness`). Stdlib only; no pip packages. Live runs need outbound HTTPS to npm, PyPI, container registries, and the GitHub API.
- **Background subagent dispatch:** When the housekeeper runs as a dispatched background subagent (the normal mode in `review-gh-pr`), the host machine must pre-authorise the `housekeeper-freshness` command in `hooks/allow-permissions.sh` and `permissions.allow` (pattern: `Bash(housekeeper-freshness:*)`). Without this, the subagent auto-denies the engine call. The same pattern applies to `ruff`, `trivy`, `eslint`, and `jb` — all static-analysis engine binaries require host-side permission for background dispatch.

## Installation

    claude plugins install code-review-suite@jodre11-plugins
