# Language-specific static-analysis specialists for the code-review plugin

Date: 2026-05-12
Status: design (pending review)

## Context

The code-review plugin currently has 12 specialists under `plugins/code-review/agents/`.
Eleven of them are agentic — findings come from LLM judgement, optionally informed by tool
inputs. One is a static-analysis specialist (`jbinspect-reviewer`), which dispatches a
deterministic tool, filters findings against the diff, and lets the LLM only word the
suggested fix. The static-analysis side is C#-only today.

This design adds three new static-analysis specialists — `eslint-reviewer`, `ruff-reviewer`,
`trivy-reviewer` — and retrofits `jbinspect-reviewer` plus the InspectCode block in
`code-analysis.md` onto a new shared include (`includes/static-analysis-context.md`). The
goal is to broaden the plugin's static-analysis coverage to the languages and configuration
formats actually used across an organisation's repos, without duplicating tools that are
already in the org's CI.

A separate, already-decided policy spec will follow this work: for static-analysis findings,
severity will be locked (set by the tool, not adjustable by peer review) and confidence will
be capped-delta (peers may lower it within a bounded amount). That policy is out of scope
here, but specialists in this spec are written to be compatible: each finding emits a
tool-derived severity and `Confidence: 100` literal so the future policy layer can apply
uniformly.

## Goals

- Cover the largest CI gaps observed across the org's repos with new specialists.
- Reuse the existing static-analysis pattern (jbinspect) rather than designing a new one.
- Avoid duplicating tools that are already routinely run in the org's CI.
- Extract a shared include so future static-analysis specialists need only their
  tool-specific section.
- Keep the plugin format-agnostic — specialists must skip gracefully when their tool is
  absent or no relevant files are in the diff.
- Stay compatible with the future severity-locked + capped-confidence policy.

## Non-goals

- Type-checking specialists (`tsc --noEmit`, `pyright`, `mypy`) — deferred to a follow-up.
- Tools whose findings are already produced by the org's CI on every PR (e.g. `tflint` on
  Terraform repos, `prettier` formatting) — these would duplicate, not add.
- Long-tail languages with single-team usage in the survey (`sqlfluff` for TSQL,
  `dart-analyze`) — revisit triggers logged in §10.
- Implementing the severity-locked + capped-confidence policy — separate spec.
- Auto-fixing or auto-pushing fixes.

## Survey of the repo landscape

Method: enumerate accessible orgs (`gh api user/orgs`) and personal namespace; list
non-archived non-fork repos via `gh repo list --no-archived --source`; fetch
`/repos/<owner>/<repo>/languages` per repo; aggregate bytes per language across all repos.
Source artefacts captured at survey time:
`/tmp/claude-<session>/lang-survey/totals.json` and `languages.jsonl`.

Surveyed scope: HavenEngineering (655 repos) + Jodre11 (20 repos) = 675 source repos,
1,103,902,784 bytes of code, 56 languages reported by GitHub Linguist.

Top of the ranking, descending by bytes:

| Rank | Language          | Bytes        | Share  | Notes                                                              |
|------|-------------------|--------------|--------|--------------------------------------------------------------------|
| 1    | C#                | 330,250,552  | 29.91% | Already covered by `jbinspect-reviewer`.                           |
| 2    | Jupyter Notebook  | 283,401,649  | 25.67% | Bytes inflated by base64 cell outputs; reviewable content is mostly Python. |
| 3    | TypeScript        | 172,465,661  | 15.62% | Same tooling as JS.                                                |
| 4    | JavaScript        | 113,940,724  | 10.32% | Same tooling as TS (ESLint or Biome).                              |
| 5    | Python            | 76,587,975   |  6.93% | Ruff is the canonical tool today.                                  |
| 6    | TSQL              | 36,089,749   |  3.26% | Single-team stack; deferred.                                       |
| 7    | HTML              | 28,870,572   |  2.61% | Mostly inside frontend repos; covered by ESLint/Biome plugins.     |
| 8    | Dart              | 11,941,988   |  1.08% | Single team; deferred.                                             |
| 9    | HCL (Terraform)   | 11,261,300   |  1.02% | High blast radius despite low bytes — IaC misconfigurations cost more than code defects per byte. |
| 10   | CSS               |  9,326,985   |  0.84% | Frontend; covered by Biome / stylelint plugins.                    |
| ≥11  | tail (PHP, Shell, Go, Dart, …) | each <1% | tail | Long tail of single-use stacks.                                  |

### CI-coverage probe

A second probe sampled `.github/workflows/*` and dependency manifests on the top-N repos
per language to determine whether the org's CI already runs the obvious tools. Results
captured in `/tmp/claude-<session>/lang-survey/ci-probe.tsv`. Summary:

| Tool            | Top repos with tool in CI | Top repos with tool in deps | Additive value |
|-----------------|---------------------------|-----------------------------|----------------|
| ESLint          | 0/9                       | 6/9                         | High — deps-but-no-CI is the textbook gap.        |
| Biome           | 0/9 in CI; 2/9 use it as dev tool | 2/9                  | Same gap, smaller subset.                          |
| `tsc --noEmit`  | 2/9                       | 9/9 (transitively)          | Partial; deferred.                                |
| Ruff            | 2/5 Python repos          | varies                      | High — half of the top Python repos lack lint CI. |
| `tflint`        | 4/5 Terraform repos       | n/a                         | LOW (already in CI) — would duplicate.            |
| `tfsec` / `trivy config` / `checkov` | 0/5 Terraform repos | n/a              | High — zero IaC-security CI today.                |
| `dotnet format` | varies                    | n/a                         | Out of scope (jbinspect already handles).         |

The CI-coverage probe is the load-bearing input for the shortlist. The byte-share survey
identifies *what* code exists; the probe identifies *where the org's CI is silent*. We
build only specialists that fill silent CI lanes — anything else duplicates an existing
GitHub check.

### Threshold and shortlist

Cut: any language whose tool is **(a)** in the top six by bytes (≥3% share) **and** **(b)**
not already in CI on a majority of top repos. Plus an exception for IaC: HCL is only 1% by
bytes but its blast radius justifies inclusion.

Three new specialists make the cut:

1. `eslint-reviewer` — TS+JS+JSX+TSX+Vue+Svelte (~26% bytes; CI gap).
2. `ruff-reviewer` — Python including notebooks (~33% bytes once notebooks fold into Python; CI gap).
3. `trivy-reviewer` — Terraform/Dockerfile/Kubernetes/Helm/CFN security (~1% bytes; high blast radius; zero CI today).

Deferred (with revisit triggers):

| Item                                | Revisit when |
|-------------------------------------|--------------|
| `tsc --noEmit` reviewer             | If the type-check pass becomes the dominant lint gap on TS repos. |
| `pyright` / `mypy` reviewer         | If a Python team starts requesting type-aware findings.           |
| `tflint` reviewer                   | If any team drops `tflint` from CI.                                |
| `sqlfluff` for TSQL                 | If TSQL bytes grow or a team requests it.                          |
| `dart-analyze`                      | If Dart bytes grow or a team requests it.                          |

## Architecture overview

The plugin gains one shared include and three new specialist agents. Existing agents
`jbinspect-reviewer.md` and the InspectCode block in `code-analysis.md` are retrofitted to
cite the new include, removing the existing "keep in sync" sister-comment.

```
plugins/code-review/
  agents/
    eslint-reviewer.md             NEW
    ruff-reviewer.md               NEW
    trivy-reviewer.md              NEW
    jbinspect-reviewer.md          EDIT — retrofit to cite the new include
    code-analysis.md               EDIT — InspectCode block retrofitted
  includes/
    static-analysis-context.md     NEW — canonical procedure for static-analysis specialists
    specialist-context.md          unchanged
    cross-review-mode.md           EDIT — add explicit "static-analysis specialists do not participate" note
  skills/review-gh-pr/SKILL.md     EDIT — add $JS_DETECTED, $PY_DETECTED, $IAC_DETECTED + dispatches
  commands/pre-review.md           EDIT — same dispatcher edits (the inlined pipeline duplicates SKILL.md)
.claude-plugin/marketplace.json    EDIT — plugin description updates to "13 specialist agents"
README.md                          EDIT — plugin table + prerequisites
plugins/code-review/README.md      EDIT — agents table + prerequisites + architecture paragraph
tests/lib/test_cross_references.sh EDIT — add citation-presence test for static-analysis specialists
tests/lib/test_sync_notes.sh       EDIT — add dispatcher-flag presence test + severity-mapping literal test
tests/lib/test_static_analysis_behavioural.sh   NEW (gated by CLAUDE_CODE_E2E_TESTS=1)
tests/fixtures/static-analysis/    NEW — synthetic fixture repo for behavioural test
```

## Shared include — `includes/static-analysis-context.md`

The new include codifies the parts that are 1:1 across all four static-analysis specialists.
Approximate length: 50–80 lines, similar to the "Determine base branch" section of
`specialist-context.md`. Sections, in order:

1. **Inherit base context.** Direct the specialist to follow the "Determine base branch"
   section of `specialist-context.md`, which resolves `$BASE`, `$HEAD_SHA`,
   `$EMPTY_TREE_MODE`, `$PATH_SCOPE`, and `$CHANGED_LINES`. Skip the "Gather context" pass
   (full diff, CLAUDE.md, file reads). Same pattern as jbinspect today.

2. **File-extension early exit.** Placeholder describing the shape: each specialist
   substitutes its own diff-filter spec. Canonical zero-state line:
   `## <Tool name> Findings\n\n0 findings — no <lang> files in diff.`

3. **Tool resolution.** Try `<tool> --version`. If exit non-zero or the binary is not
   resolvable on PATH, emit canonical wording:
   `## <Tool name> Findings\n\nSkipped — <tool> not available on PATH.` and stop.
   ESLint specialist further specifies project-local-binary preference; that addition
   stays in the specialist file.

4. **Temp-dir contract.** Require `$CLAUDE_TEMP_DIR` from the prompt. If absent, report
   the omission and stop — never fall back to bare `/tmp/`.

5. **`$CHANGED_LINES` filter.** At parse time, intersect each finding's `(file, line)`
   against `$CHANGED_LINES[<file>]`. Drop non-matching findings. Files marked
   `(empty — rename only)` accept zero findings. This text is canonical and reused
   verbatim across specialists.

6. **Confidence and severity contract.** Every finding includes `Confidence: 100` literal.
   Severity is tool-derived; each specialist's file declares its own mapping table.

7. **Output format.** Canonical heading shape: `## <Tool name> Findings`. Per-finding block
   shape:
   ```
   ### Finding — [short title]
   - **File:** path/to/file.ext:line
   - **Confidence:** 100
   - **Severity:** Critical | Important | Suggestion (see `includes/severity-definitions.md`)
   - **Rule:** rule-id (category/plugin)
   - **Description:** the message from the tool
   - **Suggested fix:** concrete suggestion based on rule + context
   ```
   Zero-state line: `## <Tool name> Findings\n\n0 findings.`

8. **Cross-review opt-out.** Static-analysis specialists do NOT participate in cross-review
   mode. Their findings ARE shown to the eight cross-reviewers (so e.g. `security-cross`
   can flag a Trivy finding from another angle), but the static-analysis specialist itself
   is never re-invoked with `Mode: cross-review`.

### Cite-only vs. inline — verification protocol

The repo has two precedents for shared includes:

| Include                          | Pattern              | Why                                                                            |
|----------------------------------|----------------------|--------------------------------------------------------------------------------|
| `specialist-context.md` ("Determine base branch") | **Cited**            | Skipping → visible failure (specialist reports wrong / empty base).            |
| `cross-review-mode.md`           | **Inlined** + sync test | Skipping → silent failure (specialist runs normal review instead of cross-review). |
| `review-pipeline.md`             | **Inlined** + sync test | Skipping → silent failure (specialists selectively dropped — PR #10 incident).  |

`static-analysis-context.md` mostly contains *silent*-failure contracts: `Confidence: 100`
literal, `$CHANGED_LINES` intersection, output-format wording. That is structurally closer
to `cross-review-mode.md` than to `specialist-context.md`. The risk: an LLM agent may
rationalise that it "knows what's in the file" and skip loading it.

The design accepts cite-only **provisionally**, gated by a behavioural smoke test:

1. **Static check (cheap, runs on every PR).** Each new specialist file contains the
   verbatim citation token `includes/static-analysis-context.md`. Necessary but not
   sufficient — citation present ≠ contract honoured.

2. **Behavioural smoke test (expensive, gated by `CLAUDE_CODE_E2E_TESTS=1`).** A synthetic
   fixture repo (one ESLint-flaggable file, one Ruff-flaggable file, one Trivy-flaggable
   file, one notebook). For each specialist:
   - Dispatch via direct Agent invocation with a controlled prompt of the same shape
     `SKILL.md` builds.
   - Assert canonical wording from the include appears verbatim in observable output:
     - "tool not on PATH" branch produces exactly `Skipped — <tool> not available on PATH.`
     - "no relevant files" branch produces exactly `0 findings — no <lang> files in diff.`
     - Findings include the literal token `Confidence: 100`.
     - Output begins with `## <Tool name> Findings`.
   - Three iterations per specialist, all-pass required.

3. **Decision gate.** If 0 specialists fail → cite-only accepted; close out. If ≥1
   specialist fails → convert ALL FOUR static-analysis specialists (including retrofitted
   jbinspect) to inline-with-sync-test. The convert-all-or-none rule prevents drift between
   sister specialists.

4. **Rollback shape.** Each specialist file inlines the include body verbatim between
   `<!-- STATIC-ANALYSIS CONTRACT — canonical: includes/static-analysis-context.md -->`
   markers. New sync test
   `test_sync_static_analysis_context_inline_matches_canonical` — modelled identically on
   the existing `test_sync_cross_review_mode_inline_matches_canonical` (sed-extract
   canonical body, sed-extract inlined body from each specialist, diff). The include file
   remains the canonical source.

The behavioural test runs only when `CLAUDE_CODE_E2E_TESTS=1` (it dispatches real agents,
costs tokens, takes minutes). CI runs it on a schedule, not on every PR. The structural
test (citation presence) catches accidental citation removal on every PR.

## Per-specialist designs

Each new specialist file follows the same shape: frontmatter → cite the shared include →
file-extension diff filter → tool-specific config-root + binary discovery → tool invocation
→ severity mapping → output-format example → cleanup. Bodies target 70–110 lines.

### `eslint-reviewer.md`

Frontmatter:
```yaml
name: eslint-reviewer
description: Runs ESLint (or Biome) on JS/TS files in the diff and reports findings. Standalone or dispatched by the review include.
model: sonnet
tools: Read, Grep, Glob, Bash
background: true
```

Diff filter: `*.js`, `*.jsx`, `*.mjs`, `*.cjs`, `*.ts`, `*.tsx`, `*.vue`, `*.svelte`. If
none match, emit canonical zero-state and stop.

Config-root and tool discovery (a diff may span multiple JS/TS workspaces in a monorepo):

1. For each changed JS/TS file, walk up the directory tree to find the nearest config in
   priority order:
   - `biome.json` or `biome.jsonc` → Biome project
   - `eslint.config.{js,mjs,cjs,ts}` → ESLint flat config (v9+)
   - `.eslintrc.{js,cjs,json,yml,yaml}` → ESLint legacy config
   - If none of the above are found above the file: skip the file with no finding.
2. Group changed files by their resolved config root → one or more projects to scan.
3. If a repo has both Biome and ESLint configs at the same level, use Biome and emit the
   single-line note `note: both biome and eslint configs present — using biome` in the
   findings header. Projects rarely keep both unless mid-migration; the note signals the
   situation to the reviewer.
4. Resolve the binary per project, in order:
   - Project-local: `<project-root>/node_modules/.bin/biome` or `.../eslint`
   - Repo-root local: `<repo-root>/node_modules/.bin/{biome,eslint}` (handles workspaces with hoisted deps)
   - Global on PATH: `biome` / `eslint`
   - If none resolve, emit `Skipped — eslint/biome not available on PATH or in node_modules.` for that project and continue with the next.

Tool invocation:
- **Biome:** `biome check --reporter=json --files-ignore-unknown=true <changed-files-in-project>`
  → `$CLAUDE_TEMP_DIR/biome-<sanitised-project>.json`. Pass the exact list of changed files;
  do not let Biome scan the whole tree (matches jbinspect's "scope to affected" pattern,
  controls token cost).
- **ESLint:** `eslint --format=json --no-warn-ignored <changed-files-in-project>`
  → `$CLAUDE_TEMP_DIR/eslint-<sanitised-project>.json`.

Sanitised project name = basename of the config-root directory (no path traversal, no
collisions across multiple workspaces).

Severity mapping:

| ESLint severity | Biome severity | Mapped     |
|-----------------|----------------|------------|
| `2` (error)     | `error`        | Important  |
| `1` (warn)      | `warning`      | Suggestion |
| `0` / `info`    | `info`         | omit       |

Promotion to Critical: a small enumerated set of security-coded rules. Initial list (kept
in the specialist file, easy to extend):

- `no-eval`, `no-implied-eval`, `no-new-func`, `no-script-url`
- ESLint plugin `security/*` rules (e.g. `security/detect-eval-with-expression`,
  `security/detect-non-literal-require`)
- `react/no-danger`, `react/no-danger-with-children`
- `node/no-deprecated-api` when the deprecated API is in the security category

Reasoning: most ESLint rules flag style/correctness, not data-loss/security. Critical is
reserved for cases where the rule itself codes a security defect.

`$CHANGED_LINES` filter: each ESLint/Biome finding has `line` (1-indexed). Intersect against
`$CHANGED_LINES[<file>]`. Drop non-matching. Files marked `(empty — rename only)` accept
zero findings.

Output: per the canonical shape. `Rule:` field shows `rule-id (plugin)` (e.g.
`no-eval (eslint)`, `lint/security/noEval (biome)`).

Cleanup: remove temp JSON files after parsing.

### `ruff-reviewer.md`

Frontmatter: same shape, `name: ruff-reviewer`, description references Ruff for Python
including notebooks.

Diff filter: `*.py`, `*.ipynb`. If none match, canonical zero-state.

Tool resolution:

1. `ruff --version`. If absent, emit `Skipped — ruff not available on PATH.`
2. Parse the version. If `ruff X.Y.Z` ≥ 0.6.0, ruff handles `.ipynb` natively. If older:
   - Try `nbqa --version`. If present, use `nbqa ruff <notebook>` for `.ipynb`; ruff direct for `.py`.
   - If `nbqa` is also absent, emit a partial-coverage note in the findings header:
     `## Ruff Findings\n\n0 findings on .py files. Notebook files (.ipynb) skipped — ruff < 0.6.0 and nbqa not available on PATH.`
     and only run ruff on `.py` files.

Config-root: walk up for `pyproject.toml` (with `[tool.ruff]`), `ruff.toml`, or
`.ruff.toml`. If none, ruff still runs with sensible defaults — single repo root is the
typical case.

Tool invocation:
- `.py` files: `ruff check --output-format=json <changed-py-files>`
  → `$CLAUDE_TEMP_DIR/ruff-py.json`
- `.ipynb` files (ruff ≥ 0.6.0): same command, `.ipynb` paths
  → `$CLAUDE_TEMP_DIR/ruff-ipynb.json`
- `.ipynb` files (nbqa fallback): one invocation per notebook because `nbqa` JSON paths
  refer to the temp `.py` extraction, not the source notebook. Sub-procedure:
  1. `nbqa --addopts='--output-format=json' ruff <notebook>` → JSON
  2. Parse the `.ipynb` to map cell index + within-cell line back to the notebook's
     overall line space. Each finding's `location` field references the temp file; remap
     to the `.ipynb` source line.
  3. The remap is the most fiddly part of any specialist — keep the procedure verbatim in
     the spec and the agent prompt so the implementer doesn't have to re-derive it.

Severity mapping (Ruff has no built-in severity scale; categorised by rule code prefix):
- `E*`, `F*` (broken-code rules: undefined name, syntax error) → Important
- `S*` (bandit security) → Important; promote to Critical for the enumerated list:
  `S102`, `S103`, `S104`, `S105`, `S106`, `S107`, `S301`–`S321`, `S501`–`S612`.
  (Pickle/marshal deserialisation, exec, hardcoded password, all-interfaces bind, SQL
  injection patterns.) Promotion list is small and stable; copied verbatim into the
  specialist file.
- everything else → Suggestion

`$CHANGED_LINES` filter: identical pattern. For notebooks, filter against the remapped
`.ipynb` line space.

Output: canonical shape, header `## Ruff Findings`, `Rule:` field shows
`code (category)` (e.g. `S105 (security)`, `E501 (pycodestyle)`).

### `trivy-reviewer.md`

Frontmatter: `name: trivy-reviewer`, description references `trivy config` for IaC security.

Diff filter (basename + path patterns):
- Extension: `*.tf`, `*.tfvars`, `*.dockerfile`
- Basename: `Dockerfile`, `Dockerfile.*`
- Path-prefix: any file under `k8s/`, `kubernetes/`, `helm/`, `manifests/`, `chart/`,
  `charts/`. Within those, accept `*.yaml` and `*.yml`. (Restricting YAML to those paths
  avoids noise from unrelated YAML.)
- CFN: `*.cfn.yaml`, `*.cfn.yml`, `*.template.json`, `*.template.yaml`

If no matches, canonical zero-state and stop.

Tool resolution: `trivy --version`. Skip canonical if absent.

Tool invocation:
- Single invocation:
  `trivy config --format=json --severity=MEDIUM,HIGH,CRITICAL --exit-code=0 <list-of-changed-files>`
  → `$CLAUDE_TEMP_DIR/trivy-config.json`.
- `--exit-code=0` so the agent doesn't error on findings.
- `LOW` and `UNKNOWN` are filtered at the source (not requested in `--severity`).

Severity mapping:

| Trivy severity | Mapped     |
|----------------|------------|
| `CRITICAL`     | Critical   |
| `HIGH`         | Important  |
| `MEDIUM`       | Suggestion |
| `LOW` / `UNKNOWN` | omit (already excluded by `--severity` flag — kept in mapping as a defensive default if the flag changes) |

Direct mapping — Trivy's severity is calibrated for IaC blast radius.

`$CHANGED_LINES` filter: Trivy reports line numbers in the file. Standard intersection.

Output: canonical shape, header `## Trivy IaC Findings`. `Rule:` field shows
`AVD-XX-NNNN (provider)` or the policy ID. `Reference:` field optional, set to Trivy's
emitted URL if present.

### `jbinspect-reviewer.md` — retrofit

The existing file is rewritten so the duplicated procedure (PATH check, $CHANGED_LINES
filter, output format, confidence note) collapses into a citation of
`includes/static-analysis-context.md`. C#-specific parts stay inline:

- Solution discovery: walk for `.sln`, scope to affected solutions.
- `jb inspectcode` invocation with `--output=$CLAUDE_TEMP_DIR/inspectcode-<name>.xml`.
- Severity mapping: `ERROR → Critical`, `WARNING → Important`, `SUGGESTION → Suggestion`,
  `HINT → omit`.

The "keep in sync with `agents/code-analysis.md`" comment narrows: the cross-cutting bits
are now canonical in the include; the C#-specific solution-discovery + invocation is the
only remaining sync surface.

The InspectCode block in `agents/code-analysis.md` gets the same retrofit — cite the
include for the cross-cutting parts, keep the C#-specific bits inline.

## Dispatcher wiring

The pipeline content is inlined into both `skills/review-gh-pr/SKILL.md` and
`commands/pre-review.md` (per the existing DRY-violation comment at SKILL.md line 107–112).
Both files receive identical edits; the existing sync test
`test_sync_pipeline_inline_matches_canonical` catches drift.

### Step 2.6 — detection flags

Currently sets `$CSHARP_DETECTED` and `$UI_DETECTED`. Add three flags:

```
- **JS/TS detection:** if any file ends with `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`,
  `.vue`, or `.svelte`, set `$JS_DETECTED = true`
- **Python detection:** if any file ends with `.py` or `.ipynb`, set `$PY_DETECTED = true`
- **IaC detection:** if any file ends with `.tf`, `.tfvars`, or `.dockerfile`,
  has basename `Dockerfile` or `Dockerfile.*`,
  sits under any of `k8s/`, `kubernetes/`, `helm/`, `manifests/`, `chart/`, `charts/` and
  ends in `.yaml` or `.yml`,
  or has extension `.cfn.yaml`, `.cfn.yml`, `.template.json`, or `.template.yaml`,
  set `$IAC_DETECTED = true`
```

The path-prefix tests for IaC use `git diff --name-only` output as-is (forward-slash
paths) — no platform-specific quirks expected.

### Step 4.2 — conditional dispatch

After the eight unconditional core dispatches and the existing C#/UI conditional
dispatches, add three more conditional blocks modelled identically:

```
If $JS_DETECTED, also dispatch:
    Agent({
        description: "ESLint/Biome review",
        subagent_type: "code-review:eslint-reviewer",
        name: "eslint-reviewer",
        mode: "auto",
        run_in_background: true,
        prompt: $AGENT_PROMPT
    })

If $PY_DETECTED, also dispatch:
    Agent({
        description: "Ruff review",
        subagent_type: "code-review:ruff-reviewer",
        name: "ruff-reviewer",
        mode: "auto",
        run_in_background: true,
        prompt: $AGENT_PROMPT
    })

If $IAC_DETECTED, also dispatch:
    Agent({
        description: "Trivy IaC security review",
        subagent_type: "code-review:trivy-reviewer",
        name: "trivy-reviewer",
        mode: "auto",
        run_in_background: true,
        prompt: $AGENT_PROMPT
    })
```

### Step 4.2 — batching fallback

Current 4+4 batching tunes for 8 agents. With up to 5 conditional specialists (jbinspect +
ui + eslint + ruff + trivy = 13 max), the fallback note expands. Spec recommends Batch 1
stays at 4 core specialists; Batch 2 picks up the remaining 4 core specialists plus all
conditional specialists (up to 9 total in Batch 2). If the platform's parallel-agent
ceiling is closer to 8 than 9, implementer splits Batch 2 further (e.g. 4+5) — see
"Open questions deferred to implementation". The spec preserves the existing rationale
("explicit dispatch enumeration is the safety net" — commit eb0bbda incident).

### Step 4.2 — mandatory-dispatch self-check

Updated to enumerate the conditional set:
"plus `jbinspect-reviewer` if `$CSHARP_DETECTED`, plus `ui-reviewer` if `$UI_DETECTED`,
plus `eslint-reviewer` if `$JS_DETECTED`, plus `ruff-reviewer` if `$PY_DETECTED`,
plus `trivy-reviewer` if `$IAC_DETECTED`".

`$SPECIALIST_COUNT` ranges from 8 (no conditionals) to 13 (all conditionals).

### Step 5 — cross-review exclusion

Currently excludes only `jbinspect`. Updated to exclude all four static-analysis specialists
(`jbinspect`, `eslint`, `ruff`, `trivy`). The exclusion rationale generalises:
"static-analysis tool output that doesn't benefit from cross-domain evaluation".

The cross-review opinions matrix simplifies to: `$CROSS_REVIEW_COUNT = 8` (core only) or
`9` (when `$UI_DETECTED`). Static-analysis specialists never contribute to cross-review
count regardless of how many fire.

Static-analysis findings ARE shown to the eight cross-reviewers (per Step 5.2 sub-step 3,
which currently says "include jbinspect findings (if present) for ALL cross-reviewers").
The wording generalises: "include findings from any static-analysis specialist (jbinspect,
eslint, ruff, trivy) for ALL cross-reviewers".

### `agents/review-synthesiser.md`

The synthesiser prompt template references "specialists" generically. Spot-check: the
synthesiser must render static-analysis findings under the existing tiered report
structure. No code change expected; implementer reads `review-synthesiser.md` and confirms
no specialist-specific branching exists that hardcodes the current four specialists.

### `includes/cross-review-mode.md`

Add a short HTML maintenance comment near the top: "Static-analysis specialists
(jbinspect, eslint, ruff, trivy) DO NOT inline this file and MUST NOT participate in
cross-review-mode dispatch. Their findings are visible to other cross-reviewers via Step
5.2 sub-step 3, but they are never re-invoked with `Mode: cross-review`."

Stays short; serves as a guard against future refactors that might accidentally retrofit
cross-review onto a static-analysis specialist.

## Marketplace and README updates

`.claude-plugin/marketplace.json`:
- `plugins[code-review].description`: "10 specialist code review agents…" →
  `"13 specialist code review agents (incl. ESLint, Ruff, Trivy IaC, JetBrains InspectCode), shared static-analysis include, PR review skill, pre-review and address-pr-comments commands"`
- No version field (per repo convention; resolved by git SHA).

Repo `README.md`:
- Plugins table description updated to the 13-specialists wording.
- Prerequisites table: add rows for `eslint` (or `biome`), `ruff` (or `nbqa` for older
  ruff), `trivy` — each marked "optional, only for projects in that language".

Plugin `README.md`:
- Agents table: add three rows mirroring the existing `jbinspect-reviewer` row format (the
  Focus column states the conditional trigger).
- Architecture section: updated paragraph noting "the full review path dispatches 8 core
  specialists + up to 5 conditional specialists (C#, UI, JS/TS, Python, IaC)".
- Prerequisites section: list the three new tools as optional, with install hints
  (ESLint/Biome installed via the project's `npm install` rather than globally;
  `brew install ruff`; `brew install trivy`).

## Tests

### Existing tests already cover (no edits needed)

- `test_marketplace_json_valid`, `test_marketplace_plugin_sources_exist`,
  `test_plugin_json_schema`, `test_plugin_json_no_version_field`,
  `test_plugin_name_matches_directory`, `test_plugin_name_matches_marketplace`.
- `test_lf_line_endings`, `test_md_json_indentation`, `test_final_newline`,
  `test_no_trailing_whitespace_in_structured_files` — apply to new `.md` files.
- `test_include_references_resolve` — validates the new specialists' citation of
  `includes/static-analysis-context.md` resolves to a real file.
- `test_agent_directories_have_agents` — count remains satisfied.
- `test_sync_pipeline_inline_matches_canonical` — enforces SKILL.md / pre-review.md
  parity for the dispatcher edits.
- `test_sync_cross_review_mode_inline_matches_canonical` — unaffected (new specialists
  don't participate).

### New tests

1. **`test_static_analysis_specialists_cite_include`** in `test_cross_references.sh` — for
   each of `eslint-reviewer.md`, `ruff-reviewer.md`, `trivy-reviewer.md`,
   `jbinspect-reviewer.md`, assert the file contains the literal token
   `includes/static-analysis-context.md`.

2. **`test_dispatcher_includes_new_static_analysis_flags`** in `test_sync_notes.sh` — for
   each of `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md`, assert the file
   contains `$JS_DETECTED`, `$PY_DETECTED`, `$IAC_DETECTED`. Catches the case where the
   dispatcher edit lands in only one of the two inline copies.

3. **`test_static_analysis_specialists_have_required_severity_mapping`** in
   `test_sync_notes.sh` — for each of the four static-analysis specialists, assert the
   file contains both the canonical token `Confidence: 100` and a heading line matching
   `## .* Findings$`. Lightweight; catches refactors that drop the literal.

4. **`tests/lib/test_static_analysis_behavioural.sh`** — gated by
   `CLAUDE_CODE_E2E_TESTS=1`. Synthetic fixture repo at
   `tests/fixtures/static-analysis/` containing:
   - One ESLint-flaggable file (e.g. `no-unused-vars` violation)
   - One Ruff-flaggable file (e.g. `F401` unused import)
   - One Trivy-flaggable file (e.g. Dockerfile with `:latest` tag)
   - One Jupyter notebook with a Ruff-flaggable cell
   The test:
   - Dispatches each specialist via direct Agent invocation with a controlled prompt of
     the same shape `SKILL.md` builds.
   - Asserts canonical wording from the include appears verbatim in observable output
     (Confidence: 100, `## <Tool name> Findings`, `Skipped — <tool> not available on
     PATH.`, `0 findings — no <lang> files in diff.`).
   - Three iterations per specialist, all-pass required.
   - Persistent failure → switch to inline+sync-test rollback (see "Cite-only vs inline").

`tests/run.sh` calls the behavioural test conditionally. CI runs it on a schedule, not on
every PR.

## Risks and mitigations

| # | Risk | Likelihood | Mitigation |
|---|------|------------|------------|
| 1 | Cite-only design defeated by LLM "I know what's in that file" rationalisation | Medium-High | Behavioural smoke test gates the design; convert to inlined + sync test if it triggers |
| 2 | `nbqa` line-remap math is fiddly and could silently misreport notebook line numbers | Medium | Spec includes the remap procedure verbatim; behavioural fixture includes one notebook; if remap is wrong, the `$CHANGED_LINES` filter drops the misreported finding (visible regression) |
| 3 | Trivy IaC file-detection regex misses some path conventions used by individual teams | Low-Medium | Detection heuristic is conservative (skip ambiguous files); revisit triggers logged: if Trivy reports zero on an IaC-heavy PR, expand the detection list |
| 4 | Project-local ESLint v8 vs flat-config v9 version skew produces unparseable output | Low-Medium | ESLint specialist resolves the project-local binary; finding parsing handles both formats (the JSON output is stable across major versions); spec lists this as a verified assumption |
| 5 | `trivy config` policy database fetch on first run exceeds review wall-clock | Low | Trivy caches DB at `~/.cache/trivy`; specialist does not pre-warm. First run on a clean machine is ~10s slower; documented in plugin README prerequisites. |
| 6 | Future severity-locked policy collides with per-specialist severity mappings | Low (by design) | Each specialist's severity is tool-derived; the future policy will state explicitly that the specialist's mapping IS the locked severity. |
| 7 | `$SPECIALIST_COUNT` arithmetic up to 13 trips the platform's parallel-agent ceiling | Low | Existing 4+4 batching note already exists; updated to "Batch 1: 4 core; Batch 2: 4 core + all conditionals". If the platform later imposes a stricter limit, batching size is one config value to tune. |
| 8 | Behavioural smoke test flakes on temperature variance and produces false-positive "rollback to inline" decisions | Medium | All-pass-of-3 iterations rule; canonical wording targets are short literal strings unambiguous to reproduce; spec records the iteration count can be raised to 5 before invoking rollback |

## Open questions deferred to implementation

- **Helm-chart YAML detection.** IaC detection regex matches `chart/`, `charts/`. Some
  teams nest under `deploy/helm/`. Decision rule: if Stage 2 testing flags a real PR where
  Trivy fires zero on a Helm-only diff, expand the regex.
- **Biome auto-detect priority.** If a repo has both `biome.json` AND `eslint.config.js`,
  use Biome and emit the single-line note in the findings header. Projects rarely keep
  both unless mid-migration.
- **Ruff version detection.** Spec assumes `ruff --version` outputs `ruff X.Y.Z` parseable
  by a simple regex; verified true for v0.4+. If older versions ship to users, version
  parsing falls back to "treat as < 0.6 and require nbqa".
- **Batching fallback granularity.** If the platform's parallel-agent ceiling is closer
  to 8 than 9, implementer splits Batch 2 further (e.g. 4+5). Decision rule: only split if
  a real review hits the ceiling; otherwise the 4+9 shape is the default.

## Implementation plan outline

The implementation plan is built by `writing-plans` next. The spec sketches the suggested
stage breakdown so `writing-plans` has a starting frame:

**Stage 1 — Static-analysis foundation (single PR):**

1. Create `includes/static-analysis-context.md`.
2. Create `eslint-reviewer.md`, `ruff-reviewer.md`, `trivy-reviewer.md`.
3. Retrofit `jbinspect-reviewer.md` and the `code-analysis.md` InspectCode block to cite
   the new include.
4. Edit `includes/cross-review-mode.md` to add the static-analysis exclusion comment.
5. Update `skills/review-gh-pr/SKILL.md` and `commands/pre-review.md` (Steps 2.6, 4.2, 5).
6. Update `.claude-plugin/marketplace.json` and both READMEs.
7. Add structural tests (cite include, dispatcher flag presence, severity-mapping
   literals).
8. Add behavioural smoke test scaffold (off by default).
9. `tests/run.sh` passes.
10. Open PR, run plugin's own code-review against itself (dogfood).

**Stage 2 — Verification (separate work, conditional on Stage 1 merge):**

1. Run behavioural smoke test against the synthetic fixture repo.
2. If passing → record results in spec as "verified", close.
3. If failing → execute rollback: inline the include body into each of the four
   static-analysis specialists, add
   `test_sync_static_analysis_context_inline_matches_canonical`. Single PR. Re-run
   behavioural test post-rollback to confirm.

**Stage 3 — Backlog (separate spec(s), future):**

- Severity-locked + capped-confidence policy layer (already-decided spec follow-up).
- `tsc --noEmit` reviewer.
- `pyright` / `mypy` reviewer.
- Re-evaluate `tflint` reviewer if any team drops it from CI.
- Re-evaluate `sqlfluff` / `dart-analyze` if usage grows.
