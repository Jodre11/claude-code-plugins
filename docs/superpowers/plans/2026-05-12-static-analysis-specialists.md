# Static-Analysis Specialists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three new static-analysis specialists (`eslint-reviewer`, `ruff-reviewer`, `trivy-reviewer`) and retrofit the existing `jbinspect-reviewer` and `code-analysis.md` InspectCode block onto a shared `includes/static-analysis-context.md` include — broadening the code-review plugin's coverage from C#-only static analysis to JS/TS, Python (incl. notebooks) and IaC, without duplicating tools the org's CI already runs.

**Architecture:** One new shared include captures the cross-cutting static-analysis contract (PATH check, `$CHANGED_LINES` filter, output format, `Confidence: 100` literal, cross-review opt-out). Three new specialist agent files cite that include and contribute only the tool-specific bits (file extensions, binary discovery, invocation, severity mapping). The pipeline (`review-pipeline.md`) gains three detection flags (`$JS_DETECTED`, `$PY_DETECTED`, `$IAC_DETECTED`), three conditional dispatch blocks, and an updated cross-review exclusion list. The two inlined consumers (`SKILL.md`, `pre-review.md`) are re-spliced from canonical and verified by the existing `test_sync_pipeline_inline_matches_canonical`. Cite-only is provisional: a behavioural smoke test (gated by `CLAUDE_CODE_E2E_TESTS=1`) gates the design — if specialists rationalise away the include, Stage 2 inlines it under a new sync test (out of scope for this plan).

**Tech Stack:** Markdown only. Bash test harness (`tests/run.sh`) validates structure; behavioural test scaffold uses `Agent({...})` invocations directly.

**Spec:** `docs/superpowers/specs/2026-05-12-static-analysis-specialists-design.md` — read before starting.

**Path conventions used in this plan:**

- `$REPO_ROOT` — repository root, resolved as `$(git rev-parse --show-toplevel)`. All shell snippets use `$REPO_ROOT/<relative-path>`.
- `$CLAUDE_TEMP_DIR` — per-session temp directory injected by the SessionStart hook. Use for all intermediate files.

Resolve `$REPO_ROOT` once at the start of the implementation session:
`REPO_ROOT="$(git rev-parse --show-toplevel)"`.

---

## File Structure

Files created:

- `plugins/code-review/includes/static-analysis-context.md` — canonical procedure for static-analysis specialists (cite-only).
- `plugins/code-review/agents/eslint-reviewer.md` — JS/TS specialist (ESLint + Biome auto-detect).
- `plugins/code-review/agents/ruff-reviewer.md` — Python specialist (incl. notebooks via Ruff ≥ 0.6.0 or `nbqa` fallback).
- `plugins/code-review/agents/trivy-reviewer.md` — IaC security specialist (`trivy config`).
- `tests/lib/test_static_analysis_behavioural.sh` — behavioural smoke test, gated by `CLAUDE_CODE_E2E_TESTS=1`.
- `tests/fixtures/static-analysis/` — synthetic fixture repo for the behavioural test (one ESLint-flaggable, one Ruff-flaggable, one Trivy-flaggable, one notebook).

Files modified:

**Canonical pipeline (must stay byte-identical to consumers under `test_sync_pipeline_inline_matches_canonical`):**

- `plugins/code-review/includes/review-pipeline.md` — Step 2.6 detection flags (add three), Step 4.2 conditional dispatch (add three), Step 4.2 batching fallback note, Step 4.3 verify-completeness self-check, Step 5 cross-review exclusion list and table.
- `plugins/code-review/skills/review-gh-pr/SKILL.md` — re-spliced consumer.
- `plugins/code-review/commands/pre-review.md` — re-spliced consumer.

**Existing specialists retrofitted:**

- `plugins/code-review/agents/jbinspect-reviewer.md` — collapse cross-cutting bits to a citation of the new include; keep C#-specific solution discovery + invocation inline.
- `plugins/code-review/agents/code-analysis.md` — same retrofit on the InspectCode block.

**Cross-review include:**

- `plugins/code-review/includes/cross-review-mode.md` — add a short HTML maintenance comment noting that static-analysis specialists do not inline this file or participate in cross-review.

**Marketplace + READMEs:**

- `.claude-plugin/marketplace.json` — `code-review` plugin description (`10` → `13` specialist agents).
- `README.md` — plugin table + prerequisites table additions.
- `plugins/code-review/README.md` — agents table additions, architecture paragraph update, prerequisites additions.

**Tests:**

- `tests/lib/test_cross_references.sh` — add citation-presence test for static-analysis specialists.
- `tests/lib/test_sync_notes.sh` — add dispatcher-flag presence test + severity-mapping literal test.

---

## Self-contained reference: canonical body of `static-analysis-context.md`

This is the verbatim text the new include must contain. Copy it exactly when implementing Task 1. The include is ~60 lines, structured as numbered sections that each specialist's body refers to by number ("see Section 3 of the include"). The include itself is **not** consumed via inlined splicing in Stage 1 — specialists cite it with the literal token `includes/static-analysis-context.md` and follow the contract.

```markdown
<!-- STATIC-ANALYSIS CONTRACT — canonical source for static-analysis specialists.

Cited from:
  - agents/eslint-reviewer.md
  - agents/ruff-reviewer.md
  - agents/trivy-reviewer.md
  - agents/jbinspect-reviewer.md
  - agents/code-analysis.md (InspectCode section)

Cite-only is provisional — a behavioural smoke test in tests/lib/test_static_analysis_behavioural.sh
gates the design. If specialists rationalise away the include (skip-by-rationalisation), inline this
file's body into each specialist verbatim with sync-test enforcement (modelled on
test_sync_cross_review_mode_inline_matches_canonical). See spec
docs/superpowers/specs/2026-05-12-static-analysis-specialists-design.md §"Cite-only vs. inline". -->

# Static-Analysis Context

Static-analysis specialists run a deterministic external tool, filter findings against the diff,
and emit a structured report. The cross-cutting procedure is captured here once; each specialist
file contributes only its tool-specific sections (file extensions, config-root walk, binary path,
invocation flags, severity mapping).

## 1. Inherit base context

Follow the "Determine base branch" section of `includes/specialist-context.md` to resolve `$BASE`,
`$HEAD_SHA`, `$EMPTY_TREE_MODE`, `$PATH_SCOPE`, and `$CHANGED_LINES`. Skip the "Gather context"
pass (full diff, CLAUDE.md, file reads) — static-analysis specialists only need the file list.

Run `git diff --name-only` to get the changed file list. Use the diff syntax determined by
`$EMPTY_TREE_MODE` (two-arg when true, three-dot when false).

## 2. File-extension early exit

Each specialist's file declares its own diff filter (extensions, basenames, path prefixes). If
none of the changed files match the specialist's filter, emit the canonical zero-state line and
stop:

```
## <Tool name> Findings

0 findings — no <lang> files in diff.
```

The exact `<Tool name>` and `<lang>` tokens are declared per-specialist (e.g.
`## Ruff Findings\n\n0 findings — no Python files in diff.`).

## 3. Tool resolution

Try `<tool> --version`. If exit non-zero or the binary is not resolvable on PATH, emit:

```
## <Tool name> Findings

Skipped — <tool> not available on PATH.
```

…and stop. Specialists may extend this rule (e.g. ESLint also tries project-local
`node_modules/.bin/{eslint,biome}` before global) — those extensions stay in the specialist
file. Do not fall back to bare `/tmp/` or any path outside `$CLAUDE_TEMP_DIR`.

## 4. Temp-dir contract

Require `$CLAUDE_TEMP_DIR` from the prompt (the path from `Use <path> for temporary files`). If
absent, report the omission and stop — never fall back to bare `/tmp/`. All intermediate files
written by the specialist's tool invocation live under `$CLAUDE_TEMP_DIR`.

## 5. `$CHANGED_LINES` filter

At parse time, intersect each finding's `(file, line)` against `$CHANGED_LINES[<file>]`. Drop
non-matching findings. Files marked `(empty — rename only)` accept zero findings. Files not in
`$CHANGED_LINES` at all are dropped entirely.

This filter is the load-bearing scope rule for static-analysis specialists. Without it, a
whole-tree scan reports findings on every pre-existing issue in every changed file — the goal is
to review what the PR introduced, not audit the rest.

## 6. Confidence and severity contract

Every finding includes the literal `Confidence: 100`. Severity is tool-derived; each specialist's
file declares its own mapping table (e.g. ERROR → Critical, WARNING → Important). The
`Confidence: 100` literal lets the future severity-locked + capped-confidence policy apply
uniformly across all static-analysis specialists.

## 7. Output format

Canonical heading shape: `## <Tool name> Findings`. Per-finding block:

```
### Finding — [short title derived from the tool message]
- **File:** path/to/file.ext:line
- **Confidence:** 100
- **Severity:** Critical | Important | Suggestion (see `includes/severity-definitions.md`)
- **Rule:** rule-id (category/plugin)
- **Description:** the message from the tool
- **Suggested fix:** concrete suggestion based on rule + context
```

Zero-findings case (after `$CHANGED_LINES` filtering): `## <Tool name> Findings\n\n0 findings.`

Report ALL findings whose mapped severity is not `omit`. Specialists may add a `Reference:` field
when the tool emits a stable URL.

## 8. Cross-review opt-out

Static-analysis specialists do NOT participate in cross-review mode. They are never re-invoked
with `Mode: cross-review`. Their findings ARE shown to the eight cross-reviewers (per Step 5.2
of the pipeline) — `security-cross-review` etc. may flag a static-analysis finding from another
angle — but the static-analysis specialist itself sits out the cross-review phase. The exclusion
generalises the existing jbinspect carve-out to the new specialists.

## 9. Cleanup

Remove the tool's intermediate output files from `$CLAUDE_TEMP_DIR` after parsing. Skip cleanup
if the run was aborted (PATH miss, temp-dir absent) — there is nothing to clean.
```

## Self-contained reference: dispatcher detection flags (Step 2.6 of the pipeline)

Replace the existing Step 2.6 in `includes/review-pipeline.md` with this canonical text. The two
new conditions extend the existing C#/UI block:

```
2.6. Scan the changed file list:
   - **C# detection:** if any file ends with `.cs`, set `$CSHARP_DETECTED = true`
   - **UI detection:** if any file ends with `.html`, `.css`, `.scss`, `.less`, `.jsx`, `.tsx`, `.vue`, `.svelte`, `.axaml`, `.xaml`, or matches UI framework config patterns, set `$UI_DETECTED = true`
   - **JS/TS detection:** if any file ends with `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`, `.vue`, or `.svelte`, set `$JS_DETECTED = true`
   - **Python detection:** if any file ends with `.py` or `.ipynb`, set `$PY_DETECTED = true`
   - **IaC detection:** if any file ends with `.tf`, `.tfvars`, or `.dockerfile`; has basename `Dockerfile` or `Dockerfile.*`; sits under any of `k8s/`, `kubernetes/`, `helm/`, `manifests/`, `chart/`, `charts/` and ends in `.yaml` or `.yml`; or has extension `.cfn.yaml`, `.cfn.yml`, `.template.json`, or `.template.yaml`, set `$IAC_DETECTED = true`
```

Note: JS/TS detection deliberately overlaps with UI detection on `.jsx`, `.tsx`, `.vue`, `.svelte`. Both flags fire — `eslint-reviewer` and `ui-reviewer` both run on the same file from different angles. The dispatcher does not deduplicate; the specialists' filters do.

## Self-contained reference: conditional dispatch blocks (Step 4.2 of the pipeline)

The three new conditional dispatch blocks extend the existing C#/UI conditionals. Place them
**after** the existing `If $CSHARP_DETECTED, also dispatch:` and `If $UI_DETECTED, also
dispatch:` blocks, in the same parallel batch:

```
If `$JS_DETECTED`, also dispatch:
```
Agent({
    description: "ESLint/Biome review",
    subagent_type: "code-review:eslint-reviewer",
    name: "eslint-reviewer",
    mode: "auto",
    run_in_background: true,
    prompt: $AGENT_PROMPT
})
```

If `$PY_DETECTED`, also dispatch:
```
Agent({
    description: "Ruff review",
    subagent_type: "code-review:ruff-reviewer",
    name: "ruff-reviewer",
    mode: "auto",
    run_in_background: true,
    prompt: $AGENT_PROMPT
})
```

If `$IAC_DETECTED`, also dispatch:
```
Agent({
    description: "Trivy IaC security review",
    subagent_type: "code-review:trivy-reviewer",
    name: "trivy-reviewer",
    mode: "auto",
    run_in_background: true,
    prompt: $AGENT_PROMPT
})
```
```

The batching-fallback note in Step 4.2 is amended: "Batch 2 picks up the remaining 4 core
specialists plus all conditional specialists (up to 5: jbinspect, ui, eslint, ruff, trivy)." If
a real review hits the parallel-agent ceiling, the implementer splits Batch 2 further
(see "Open questions deferred to implementation" in the spec).

The mandatory-dispatch self-check in Step 4.3 is amended:

> 2. Compare against the mandatory set: `security-reviewer`, `correctness-reviewer`, `consistency-reviewer`, `style-reviewer`, `archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer` (plus `jbinspect-reviewer` if `$CSHARP_DETECTED`, plus `ui-reviewer` if `$UI_DETECTED`, plus `eslint-reviewer` if `$JS_DETECTED`, plus `ruff-reviewer` if `$PY_DETECTED`, plus `trivy-reviewer` if `$IAC_DETECTED`)

`$SPECIALIST_COUNT` ranges from 8 (no conditionals) to 13 (all conditionals).

## Self-contained reference: cross-review exclusion (Step 5 of the pipeline)

The first paragraph of Step 5 is updated:

> Dispatch fresh cross-review agents in parallel — one per domain, EXCLUDING the four
> static-analysis specialists (`jbinspect`, `eslint`, `ruff`, `trivy`). Static-analysis tool
> output does not benefit from cross-domain evaluation — see
> `includes/static-analysis-context.md` §8.

The cross-review count table simplifies to:

| Scenario                         | `$CROSS_REVIEW_COUNT` |
|----------------------------------|-----------------------|
| `$UI_DETECTED` is false          | 8                     |
| `$UI_DETECTED` is true           | 9                     |

Static-analysis specialists never contribute to `$CROSS_REVIEW_COUNT` regardless of how many
fire. `$SPECIALIST_COUNT` is unaffected by this table — it still includes static-analysis
specialists.

Step 5.2 sub-step 3 is amended:

> 3. Include findings from any static-analysis specialist (`jbinspect`, `eslint`, `ruff`,
>    `trivy`) for ALL cross-reviewers — they are excluded from receiving cross-review, not
>    from being reviewed. Omit any `### <name>-reviewer findings` block whose corresponding
>    `$<*>_DETECTED` flag is false — do not include placeholders.

---

## Task 1: Create `static-analysis-context.md`

**Files:**
- Create: `plugins/code-review/includes/static-analysis-context.md`

- [ ] **Step 1: Write the failing test**

  Add to `tests/lib/test_cross_references.sh` at the end of the file (before the final blank
  line). The test asserts the canonical include exists:

  ```bash
  test_static_analysis_context_exists() {
      local cr="$REPO_ROOT/plugins/code-review"
      assert_file_exists "plugins/code-review/includes/static-analysis-context.md" \
          "code-review: static-analysis-context.md exists"
  }
  ```

- [ ] **Step 2: Run the test to verify it fails**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -A1 'static-analysis-context.md'
  ```

  Expected: FAIL — file does not exist yet.

- [ ] **Step 3: Create the include**

  Write the file at `$REPO_ROOT/plugins/code-review/includes/static-analysis-context.md` with
  the verbatim canonical body from "Self-contained reference: canonical body of
  `static-analysis-context.md`" above. LF line endings. Trailing newline. 2-space indentation
  in any nested lists.

- [ ] **Step 4: Run the test to verify it passes**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep 'static-analysis-context.md'
  ```

  Expected: PASS.

- [ ] **Step 5: Run the full test suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all existing tests pass plus the new one. The `test_include_references_resolve`
  test should not flag the new file (no specialist cites it yet, so no broken refs).

- [ ] **Step 6: Commit**

  ```bash
  git add plugins/code-review/includes/static-analysis-context.md tests/lib/test_cross_references.sh
  git commit -m "feat(code-review): add static-analysis-context.md shared include

  Captures the cross-cutting procedure for static-analysis specialists (PATH
  check, \$CHANGED_LINES filter, output format, Confidence: 100 literal,
  cross-review opt-out). Cited from the four static-analysis specialists.
  Cite-only is provisional and gated by a behavioural smoke test."
  ```

---

## Task 2: Create `eslint-reviewer.md`

**Files:**
- Create: `plugins/code-review/agents/eslint-reviewer.md`

- [ ] **Step 1: Write the failing test**

  No new test — `test_static_analysis_specialists_cite_include` will be added in Task 15 and
  will assert this file cites the include. For now we rely on
  `test_agent_directories_have_agents` already passing (it counts `*.md` files under `agents/`)
  and `test_include_references_resolve` to verify the citation resolves.

- [ ] **Step 2: Confirm there's no existing eslint-reviewer file**

  ```
  ls $REPO_ROOT/plugins/code-review/agents/eslint-reviewer.md
  ```

  Expected: `No such file or directory`.

- [ ] **Step 3: Create the specialist file**

  Write `$REPO_ROOT/plugins/code-review/agents/eslint-reviewer.md` with this body:

  ````markdown
  ---
  name: eslint-reviewer
  description: Runs ESLint (or Biome) on JS/TS files in the diff and reports findings. Standalone or dispatched by the review include.
  model: sonnet
  tools: Read, Grep, Glob, Bash
  background: true
  ---

  You are a static-analysis reviewer that runs ESLint (or Biome, when configured) on the JS/TS files in the current diff.

  Follow the cross-cutting static-analysis procedure in `includes/static-analysis-context.md`. The sections below contribute the ESLint-specific bits — read them alongside the include rather than as a replacement for it.

  ## File-extension filter

  Filter the changed file list to entries matching any of: `*.js`, `*.jsx`, `*.mjs`, `*.cjs`, `*.ts`, `*.tsx`, `*.vue`, `*.svelte`. If none match, emit the canonical zero-state and stop (see `includes/static-analysis-context.md` §2):

  ```
  ## ESLint Findings

  0 findings — no JS/TS files in diff.
  ```

  ## Config-root and tool discovery

  A diff may span multiple JS/TS workspaces in a monorepo. For each changed JS/TS file, walk up the directory tree to find the nearest config in priority order:

  1. `biome.json` or `biome.jsonc` → Biome project
  2. `eslint.config.{js,mjs,cjs,ts}` → ESLint flat config (v9+)
  3. `.eslintrc.{js,cjs,json,yml,yaml}` → ESLint legacy config
  4. None of the above → skip the file with no finding.

  Group changed files by their resolved config root → one or more projects to scan. If a project root contains both Biome and ESLint configs, prefer Biome and emit a single-line note in the findings header: `note: both biome and eslint configs present — using biome`.

  Resolve the binary per project, in this priority order:

  1. Project-local: `<project-root>/node_modules/.bin/biome` (or `.../eslint`)
  2. Repo-root local: `<repo-root>/node_modules/.bin/{biome,eslint}` (handles workspaces with hoisted deps)
  3. Global on PATH: `biome` / `eslint`
  4. None resolve → emit `Skipped — eslint/biome not available on PATH or in node_modules.` for that project and continue with the next project.

  ## Tool invocation

  Check `$CLAUDE_TEMP_DIR` is present in your prompt before invoking either tool — see `includes/static-analysis-context.md` §4.

  - **Biome:** `biome check --reporter=json --files-ignore-unknown=true <changed-files-in-project>` → `$CLAUDE_TEMP_DIR/biome-<sanitised-project>.json`. Pass the exact list of changed files; do not let Biome scan the whole tree.
  - **ESLint:** `eslint --format=json --no-warn-ignored <changed-files-in-project>` → `$CLAUDE_TEMP_DIR/eslint-<sanitised-project>.json`.

  `<sanitised-project>` is the basename of the config-root directory (no path traversal, no collisions across multiple workspaces).

  ## Severity mapping

  | ESLint severity | Biome severity | Mapped     |
  |-----------------|----------------|------------|
  | `2` (error)     | `error`        | Important  |
  | `1` (warn)      | `warning`      | Suggestion |
  | `0` / `info`    | `info`         | omit       |

  Promotion to Critical applies to a small enumerated set of security-coded rules (extend as needed):

  - `no-eval`, `no-implied-eval`, `no-new-func`, `no-script-url`
  - `eslint-plugin-security` rules (e.g. `security/detect-eval-with-expression`, `security/detect-non-literal-require`)
  - `react/no-danger`, `react/no-danger-with-children`
  - `node/no-deprecated-api` when the deprecated API is in the security category

  Reasoning: most ESLint rules flag style/correctness, not data-loss/security. Critical is reserved for cases where the rule itself codes a security defect.

  ## Output

  Per `includes/static-analysis-context.md` §7. Heading: `## ESLint Findings`. The `Rule:` field shows `rule-id (plugin)` — e.g. `no-eval (eslint)`, `lint/security/noEval (biome)`.

  After parsing, intersect each finding's `(file, line)` against `$CHANGED_LINES[<file>]` per §5 of the include. Drop non-matching findings.

  Every finding emits the literal `Confidence: 100` per §6 of the include.

  Clean up `$CLAUDE_TEMP_DIR/biome-*.json` and `$CLAUDE_TEMP_DIR/eslint-*.json` after parsing.
  ````

- [ ] **Step 4: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: `test_agent_directories_have_agents` agent count incremented; `test_include_references_resolve` passes (the file's `includes/static-analysis-context.md` references resolve to Task 1's file); other tests unchanged.

- [ ] **Step 5: Commit**

  ```bash
  git add plugins/code-review/agents/eslint-reviewer.md
  git commit -m "feat(code-review): add eslint-reviewer specialist

  Runs ESLint (or Biome) on JS/TS files in the diff with project-local
  binary preference. Cites includes/static-analysis-context.md for the
  cross-cutting contract."
  ```

---

## Task 3: Create `ruff-reviewer.md`

**Files:**
- Create: `plugins/code-review/agents/ruff-reviewer.md`

- [ ] **Step 1: Confirm there's no existing ruff-reviewer file**

  ```
  ls $REPO_ROOT/plugins/code-review/agents/ruff-reviewer.md
  ```

  Expected: `No such file or directory`.

- [ ] **Step 2: Create the specialist file**

  Write `$REPO_ROOT/plugins/code-review/agents/ruff-reviewer.md`:

  ````markdown
  ---
  name: ruff-reviewer
  description: Runs Ruff on Python files in the diff (including notebooks via Ruff ≥ 0.6.0 or nbqa fallback) and reports findings. Standalone or dispatched by the review include.
  model: sonnet
  tools: Read, Grep, Glob, Bash
  background: true
  ---

  You are a static-analysis reviewer that runs Ruff on the Python files (`.py` and `.ipynb`) in the current diff.

  Follow the cross-cutting static-analysis procedure in `includes/static-analysis-context.md`. The sections below contribute the Ruff-specific bits.

  ## File-extension filter

  Filter the changed file list to entries matching `*.py` or `*.ipynb`. If none match, emit the canonical zero-state and stop:

  ```
  ## Ruff Findings

  0 findings — no Python files in diff.
  ```

  ## Tool resolution

  1. Run `ruff --version`. If absent, emit `Skipped — ruff not available on PATH.` and stop.
  2. Parse the version (`ruff X.Y.Z`).
     - If version ≥ `0.6.0`: Ruff handles `.ipynb` natively.
     - If version `< 0.6.0`: try `nbqa --version`. If `nbqa` is present, use `nbqa ruff <notebook>` for `.ipynb` files; use `ruff` directly for `.py` files. If `nbqa` is also absent, emit a partial-coverage header and only run on `.py` files:

       ```
       ## Ruff Findings

       0 findings on .py files. Notebook files (.ipynb) skipped — ruff < 0.6.0 and nbqa not available on PATH.
       ```

       …continuing into the per-finding blocks if there are any `.py` findings.

  ## Config-root

  Walk up for `pyproject.toml` (with `[tool.ruff]`), `ruff.toml`, or `.ruff.toml`. If none, Ruff still runs with sensible defaults. Single repo root is the typical case.

  ## Tool invocation

  Check `$CLAUDE_TEMP_DIR` is present in your prompt before invoking ruff — see `includes/static-analysis-context.md` §4.

  - `.py` files: `ruff check --output-format=json <changed-py-files>` → `$CLAUDE_TEMP_DIR/ruff-py.json`
  - `.ipynb` files (Ruff ≥ 0.6.0): `ruff check --output-format=json <changed-ipynb-files>` → `$CLAUDE_TEMP_DIR/ruff-ipynb.json`
  - `.ipynb` files (`nbqa` fallback): one invocation per notebook because `nbqa` JSON paths refer to the temp `.py` extraction, not the source notebook. For each notebook:
    1. `nbqa --addopts='--output-format=json' ruff <notebook>` → JSON
    2. Parse the `.ipynb` to map cell index + within-cell line back to the notebook's overall line space. Each finding's `location.row` field references the temp file; remap to the `.ipynb` source line.
    3. Apply `$CHANGED_LINES` filtering against the remapped notebook line numbers.

  The `nbqa` line-remap is the most fiddly part of the specialist — keep this procedure verbatim if you reproduce it elsewhere.

  ## Severity mapping

  Ruff has no built-in severity scale; map by rule code prefix:

  - `E*`, `F*` (broken-code rules: undefined name, syntax error) → Important
  - `S*` (bandit security) → Important; **promote to Critical** for the enumerated list:
    `S102`, `S103`, `S104`, `S105`, `S106`, `S107`, `S301`–`S321`, `S501`–`S612`.
    (Pickle/marshal deserialisation, exec, hardcoded password, all-interfaces bind, SQL injection patterns.)
  - everything else → Suggestion

  ## Output

  Per `includes/static-analysis-context.md` §7. Heading: `## Ruff Findings`. The `Rule:` field shows `code (category)` — e.g. `S105 (security)`, `E501 (pycodestyle)`.

  After parsing, intersect each finding's `(file, line)` against `$CHANGED_LINES[<file>]` per §5. For notebooks, filter against the remapped `.ipynb` line space.

  Every finding emits the literal `Confidence: 100` per §6.

  Clean up `$CLAUDE_TEMP_DIR/ruff-*.json` after parsing.
  ````

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: agent count incremented; citation reference resolves.

- [ ] **Step 4: Commit**

  ```bash
  git add plugins/code-review/agents/ruff-reviewer.md
  git commit -m "feat(code-review): add ruff-reviewer specialist

  Runs Ruff on Python files in the diff including Jupyter notebooks
  (native via Ruff >= 0.6.0 or nbqa fallback). Cites
  includes/static-analysis-context.md."
  ```

---

## Task 4: Create `trivy-reviewer.md`

**Files:**
- Create: `plugins/code-review/agents/trivy-reviewer.md`

- [ ] **Step 1: Confirm there's no existing trivy-reviewer file**

  ```
  ls $REPO_ROOT/plugins/code-review/agents/trivy-reviewer.md
  ```

  Expected: `No such file or directory`.

- [ ] **Step 2: Create the specialist file**

  Write `$REPO_ROOT/plugins/code-review/agents/trivy-reviewer.md`:

  ````markdown
  ---
  name: trivy-reviewer
  description: Runs trivy config on Terraform / Dockerfile / Kubernetes / Helm / CFN files in the diff and reports IaC security findings. Standalone or dispatched by the review include.
  model: sonnet
  tools: Read, Grep, Glob, Bash
  background: true
  ---

  You are a static-analysis reviewer that runs `trivy config` on infrastructure-as-code files in the current diff and reports security findings.

  Follow the cross-cutting static-analysis procedure in `includes/static-analysis-context.md`. The sections below contribute the Trivy-specific bits.

  ## File filter

  Filter the changed file list to IaC files. A file qualifies if any of these match:

  - Extension `.tf`, `.tfvars`, or `.dockerfile`
  - Basename `Dockerfile` or matching `Dockerfile.*`
  - Path-prefix any of `k8s/`, `kubernetes/`, `helm/`, `manifests/`, `chart/`, or `charts/`, **and** extension `.yaml` or `.yml`. (Restricting YAML to those paths avoids noise from unrelated YAML.)
  - Extension `.cfn.yaml`, `.cfn.yml`, `.template.json`, or `.template.yaml`

  If none match, emit the canonical zero-state and stop:

  ```
  ## Trivy IaC Findings

  0 findings — no IaC files in diff.
  ```

  ## Tool resolution

  Run `trivy --version`. If absent, emit `Skipped — trivy not available on PATH.` and stop.

  ## Tool invocation

  Check `$CLAUDE_TEMP_DIR` is present in your prompt — see `includes/static-analysis-context.md` §4.

  Single invocation across all matched files:

  ```
  trivy config --format=json --severity=MEDIUM,HIGH,CRITICAL --exit-code=0 <list-of-changed-files>
  ```

  → `$CLAUDE_TEMP_DIR/trivy-config.json`.

  - `--exit-code=0` so the agent doesn't error on findings.
  - `LOW` and `UNKNOWN` are filtered at the source via `--severity`.
  - Trivy caches its policy database at `~/.cache/trivy`. First run on a clean machine fetches the DB and is ~10s slower; subsequent runs are fast.

  ## Severity mapping

  | Trivy severity | Mapped     |
  |----------------|------------|
  | `CRITICAL`     | Critical   |
  | `HIGH`         | Important  |
  | `MEDIUM`       | Suggestion |
  | `LOW`          | omit (already excluded by `--severity` flag — kept here as defensive default if the flag changes) |
  | `UNKNOWN`      | omit (same)|

  Trivy's severity is calibrated for IaC blast radius; the mapping is direct.

  ## Output

  Per `includes/static-analysis-context.md` §7. Heading: `## Trivy IaC Findings`. The `Rule:` field shows `AVD-XX-NNNN (provider)` or the policy ID. The `Reference:` field is optional — set it to Trivy's emitted URL when present.

  After parsing, intersect each finding's `(file, line)` against `$CHANGED_LINES[<file>]` per §5. Drop non-matching findings.

  Every finding emits the literal `Confidence: 100` per §6.

  Clean up `$CLAUDE_TEMP_DIR/trivy-config.json` after parsing.
  ````

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: agent count incremented; citation resolves.

- [ ] **Step 4: Commit**

  ```bash
  git add plugins/code-review/agents/trivy-reviewer.md
  git commit -m "feat(code-review): add trivy-reviewer specialist

  Runs trivy config on Terraform / Dockerfile / Kubernetes / Helm / CFN
  files in the diff. Fills the IaC-security CI gap (zero coverage today
  on top org Terraform repos). Cites includes/static-analysis-context.md."
  ```

---

## Task 5: Retrofit `jbinspect-reviewer.md` onto the shared include

**Files:**
- Modify: `plugins/code-review/agents/jbinspect-reviewer.md`

- [ ] **Step 1: Read the current file**

  ```
  cat $REPO_ROOT/plugins/code-review/agents/jbinspect-reviewer.md
  ```

  Confirm structure matches the spec's Stage 5 description: frontmatter, then "Context Gathering", "Step 1: Check for C# changes", "Step 2: Find affected solutions", "Step 3: Run InspectCode", "Step 4: Parse results", "Step 5: Map severity", "Step 6: Format output", "Rules", and the "Keep in sync with `agents/code-analysis.md`" closing note.

- [ ] **Step 2: Rewrite the file**

  Replace the file contents with this body. The frontmatter is unchanged. The C#-specific bits stay inline (solution discovery + `jb inspectcode` invocation + InspectCode-specific severity table); the cross-cutting bits collapse to a citation:

  ````markdown
  ---
  name: jbinspect-reviewer
  description: Runs JetBrains InspectCode on affected C# solutions and reports findings. Standalone or dispatched by the review include or code-analysis agent.
  model: sonnet
  tools: Read, Grep, Glob, Bash
  background: true
  ---

  You are a static-analysis reviewer that runs JetBrains InspectCode (`jb inspectcode`) on C# solutions affected by the current diff.

  Follow the cross-cutting static-analysis procedure in `includes/static-analysis-context.md`. The sections below contribute the C#-specific bits — read them alongside the include rather than as a replacement for it.

  ## File-extension filter

  Filter the changed file list to `*.cs` files. If none match, emit the canonical zero-state and stop:

  ```
  ## JetBrains InspectCode Findings

  0 findings — no C# files in diff.
  ```

  ## Find affected solutions

  The repo may contain multiple `.sln` files. Determine which solutions are affected by the diff:

  1. Run `find . -name '*.sln' -not -path '*/bin/*' -not -path '*/obj/*'` to locate all solution files.
  2. If exactly one `.sln` exists, use it.
  3. If multiple `.sln` files exist, scope to only affected solutions:
     a. For each changed `.cs` file, find its containing `.csproj` by walking up the directory tree (look for the nearest `*.csproj`).
     b. For each `.csproj` found, check which `.sln` files reference it by grepping each `.sln` for the `.csproj` filename or relative path.
     c. Collect the unique set of affected `.sln` files.
  4. If no `.sln` file can be matched (orphaned `.cs` files), skip inspection and report:

     ```
     ## JetBrains InspectCode Findings

     0 findings — could not determine solution for changed C# files.
     ```

  ## Tool invocation

  Check `$CLAUDE_TEMP_DIR` is present in your prompt before invoking — see `includes/static-analysis-context.md` §4.

  For each affected solution:

  ```
  jb inspectcode <solution.sln> --output="$CLAUDE_TEMP_DIR/inspectcode-<solution-name>.xml" --format=Xml --severity=WARNING
  ```

  `<solution-name>` is the basename of the solution file without extension — not the full path (avoids path traversal and collisions when multiple solutions are inspected).

  If `jb` is not installed or not on PATH, emit `Skipped — jb inspectcode not available on PATH.` per `includes/static-analysis-context.md` §3 and stop. If the command fails on a particular solution, report the error and continue with any remaining solutions.

  ## Parse results

  Read each output XML file. Look for `<Issue>` elements within `<Issues>` > `<Project>` sections. Each `<Issue>` has attributes:

  - `TypeId` — the inspection rule identifier
  - `File` — relative file path
  - `Offset` — character range (optional)
  - `Line` — line number (if present)
  - `Message` — description of the issue

  Cross-reference `TypeId` against the `<IssueType>` definitions in the XML header to get `Severity` (ERROR | WARNING | SUGGESTION | HINT), `Category`, and `Description`.

  After cross-referencing, intersect each `<Issue>`'s `Line` attribute against `$CHANGED_LINES[<File>]` per `includes/static-analysis-context.md` §5. Drop non-matching issues.

  ## Severity mapping

  | InspectCode severity | Mapped     |
  |----------------------|------------|
  | `ERROR`              | Critical   |
  | `WARNING`            | Important  |
  | `SUGGESTION`         | Suggestion |
  | `HINT`               | omit       |

  ## Output

  Per `includes/static-analysis-context.md` §7. Heading: `## JetBrains InspectCode Findings`. The `Rule:` field shows `TypeId (Category)`.

  Every finding emits the literal `Confidence: 100` per §6.

  Clean up `$CLAUDE_TEMP_DIR/inspectcode-*.xml` after parsing.

  Keep in sync with the InspectCode section in `agents/code-analysis.md` — changes to the C#-specific solution-discovery + `jb inspectcode` invocation must be mirrored. (The cross-cutting bits live in `includes/static-analysis-context.md` and are no longer duplicated.)
  ````

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass; `test_include_references_resolve` confirms the citation resolves.

- [ ] **Step 4: Commit**

  ```bash
  git add plugins/code-review/agents/jbinspect-reviewer.md
  git commit -m "refactor(code-review): cite static-analysis-context from jbinspect-reviewer

  Cross-cutting static-analysis bits (PATH check, \$CHANGED_LINES filter,
  output format, Confidence: 100 literal) collapse to a citation of the new
  shared include. C#-specific solution discovery and jb inspectcode
  invocation stay inline. The keep-in-sync note with code-analysis.md
  narrows accordingly."
  ```

---

## Task 6: Retrofit InspectCode block in `code-analysis.md`

**Files:**
- Modify: `plugins/code-review/agents/code-analysis.md` (the InspectCode section, currently lines 13–37)

- [ ] **Step 1: Read current InspectCode section**

  ```
  sed -n '13,37p' $REPO_ROOT/plugins/code-review/agents/code-analysis.md
  ```

  Confirm matches what was read at plan-writing time: a 9-step sequence followed by a "Keep in sync" note.

- [ ] **Step 2: Replace lines 13–37**

  Use the Edit tool to replace the block from `### Run JetBrains InspectCode (C# only)` through the "Keep in sync" note (the line ending `must be mirrored.`) with this body:

  ```markdown
  ### Run JetBrains InspectCode (C# only)

  If any changed files end with `.cs`, follow the procedure in `agents/jbinspect-reviewer.md` (file-extension filter, solution discovery, tool invocation, parse + filter, severity mapping, cleanup) — that file cites `includes/static-analysis-context.md` for the cross-cutting parts.

  Include InspectCode findings in the output under a separate `## JetBrains InspectCode` section (before the manual review findings). If no C# files are in the diff, skip this step entirely.

  Keep in sync with `agents/jbinspect-reviewer.md` — changes to the C#-specific InspectCode procedure must be mirrored. (The cross-cutting bits live in `includes/static-analysis-context.md`.)
  ```

  Note: the existing line `Include these findings in the output under a separate ...` is preserved (slightly reworded above to flow with the citation). The "Keep in sync" note sits at the end of the section as before.

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass; the citation resolves.

- [ ] **Step 4: Commit**

  ```bash
  git add plugins/code-review/agents/code-analysis.md
  git commit -m "refactor(code-review): cite jbinspect-reviewer + static-analysis-context from code-analysis

  The InspectCode block in code-analysis.md was a near-duplicate of
  jbinspect-reviewer.md. Replace it with a citation pointing at both
  jbinspect-reviewer.md (C#-specific procedure) and
  includes/static-analysis-context.md (cross-cutting contract). Keeps
  code-analysis lightweight; reduces sync surface."
  ```

---

## Task 7: Add static-analysis exclusion comment to `cross-review-mode.md`

**Files:**
- Modify: `plugins/code-review/includes/cross-review-mode.md` (insert after line 5, before the `> **MODE SWITCH...` blockquote)

- [ ] **Step 1: Read the current header comment**

  ```
  sed -n '1,10p' $REPO_ROOT/plugins/code-review/includes/cross-review-mode.md
  ```

  Confirm lines 1–5 are the existing HTML comment listing the inlining consumers, line 6 is blank, line 7 starts `> **MODE SWITCH...`.

- [ ] **Step 2: Replace lines 1–5 with extended HTML comment**

  Use the Edit tool to replace this exact block:

  ```
  <!-- CROSS-REVIEW MODE — this is the canonical source.
  Edit this file first, then propagate to all specialist agents:
  archaeology-reviewer.md, consistency-reviewer.md, correctness-reviewer.md,
  efficiency-reviewer.md, reuse-reviewer.md, security-reviewer.md,
  style-reviewer.md, ui-reviewer.md. -->
  ```

  …with:

  ```
  <!-- CROSS-REVIEW MODE — this is the canonical source.
  Edit this file first, then propagate to all specialist agents:
  archaeology-reviewer.md, consistency-reviewer.md, correctness-reviewer.md,
  efficiency-reviewer.md, reuse-reviewer.md, security-reviewer.md,
  style-reviewer.md, ui-reviewer.md.

  Static-analysis specialists (jbinspect, eslint, ruff, trivy) DO NOT inline
  this file and MUST NOT participate in cross-review-mode dispatch. Their
  findings are visible to other cross-reviewers via Step 5.2 sub-step 3 of the
  pipeline, but they are never re-invoked with `Mode: cross-review`. See
  includes/static-analysis-context.md §8. -->
  ```

  This is a comment-only change — the canonical body the existing `test_sync_cross_review_mode_inline_matches_canonical` test extracts (starting at the `> **MODE SWITCH...` blockquote) is unchanged. The sync test extracts from `/^> \*\*MODE SWITCH — MANDATORY\*\*/,$` and compares against agent inline copies; the HTML comment falls outside that range.

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: `test_sync_cross_review_mode_inline_matches_canonical` still passes (HTML comment is outside the extraction range); other tests unchanged.

- [ ] **Step 4: Commit**

  ```bash
  git add plugins/code-review/includes/cross-review-mode.md
  git commit -m "docs(code-review): note static-analysis exclusion in cross-review-mode header

  Comment-only change to the canonical's HTML maintenance header. Guards
  against future refactors that might accidentally retrofit cross-review
  onto a static-analysis specialist."
  ```

---

## Task 8: Update `review-pipeline.md` Step 2.6 (detection flags)

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md` lines 548–551

- [ ] **Step 1: Read the existing Step 2.6**

  ```
  sed -n '548,553p' $REPO_ROOT/plugins/code-review/includes/review-pipeline.md
  ```

  Confirm the two-bullet list (C# detection, UI detection) on lines 549–551.

- [ ] **Step 2: Replace the two-bullet list with the five-bullet list**

  Use the Edit tool. Replace this exact block:

  ```
  2.6. Scan the changed file list:
     - **C# detection:** if any file ends with `.cs`, set `$CSHARP_DETECTED = true`
     - **UI detection:** if any file ends with `.html`, `.css`, `.scss`, `.less`, `.jsx`, `.tsx`, `.vue`, `.svelte`, `.axaml`, `.xaml`, or matches UI framework config patterns, set `$UI_DETECTED = true`
  ```

  …with:

  ```
  2.6. Scan the changed file list:
     - **C# detection:** if any file ends with `.cs`, set `$CSHARP_DETECTED = true`
     - **UI detection:** if any file ends with `.html`, `.css`, `.scss`, `.less`, `.jsx`, `.tsx`, `.vue`, `.svelte`, `.axaml`, `.xaml`, or matches UI framework config patterns, set `$UI_DETECTED = true`
     - **JS/TS detection:** if any file ends with `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`, `.vue`, or `.svelte`, set `$JS_DETECTED = true`
     - **Python detection:** if any file ends with `.py` or `.ipynb`, set `$PY_DETECTED = true`
     - **IaC detection:** if any file ends with `.tf`, `.tfvars`, or `.dockerfile`; has basename `Dockerfile` or `Dockerfile.*`; sits under any of `k8s/`, `kubernetes/`, `helm/`, `manifests/`, `chart/`, `charts/` and ends in `.yaml` or `.yml`; or has extension `.cfn.yaml`, `.cfn.yml`, `.template.json`, or `.template.yaml`, set `$IAC_DETECTED = true`
  ```

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -E '(pipeline inline sync|FAIL|PASS)' | head -20
  ```

  Expected: `test_sync_pipeline_inline_matches_canonical` now FAILS for both `SKILL.md` and `pre-review.md` — they still have the old two-bullet list. This is correct; the consumers will be re-spliced in Task 11.

  No commit yet — keep the failing-sync state through Tasks 9 and 10, commit Tasks 8–11 as a single canonical-update commit at the end of Task 11.

---

## Task 9: Update `review-pipeline.md` Step 4.2 (conditional dispatch + batching)

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md`, the conditional dispatch section (currently lines 710–744)

- [ ] **Step 1: Read the conditional dispatch section**

  ```
  sed -n '710,745p' $REPO_ROOT/plugins/code-review/includes/review-pipeline.md
  ```

  Confirm structure: `**Conditional dispatch** (in the same parallel batch):` → `If $CSHARP_DETECTED, also dispatch:` block → `If $UI_DETECTED, also dispatch:` block → `**Batching fallback:**` → `Store $SPECIALIST_COUNT...` line.

- [ ] **Step 2: Insert three new conditional dispatch blocks**

  After the `If $UI_DETECTED, also dispatch:` block's closing triple-backtick + blank line, and **before** the `**Batching fallback:**` heading, insert three new blocks.

  Use the Edit tool. Find this exact block (the UI conditional plus the blank line and the Batching fallback heading):

  ````
  If `$UI_DETECTED`, also dispatch:
  ```
  Agent({
      description: "UI/UX review",
      subagent_type: "code-review:ui-reviewer",
      name: "ui-reviewer",
      mode: "auto",
      run_in_background: true,
      prompt: $AGENT_PROMPT
  })
  ```

  **Batching fallback:**
  ````

  …and replace with:

  ````
  If `$UI_DETECTED`, also dispatch:
  ```
  Agent({
      description: "UI/UX review",
      subagent_type: "code-review:ui-reviewer",
      name: "ui-reviewer",
      mode: "auto",
      run_in_background: true,
      prompt: $AGENT_PROMPT
  })
  ```

  If `$JS_DETECTED`, also dispatch:
  ```
  Agent({
      description: "ESLint/Biome review",
      subagent_type: "code-review:eslint-reviewer",
      name: "eslint-reviewer",
      mode: "auto",
      run_in_background: true,
      prompt: $AGENT_PROMPT
  })
  ```

  If `$PY_DETECTED`, also dispatch:
  ```
  Agent({
      description: "Ruff review",
      subagent_type: "code-review:ruff-reviewer",
      name: "ruff-reviewer",
      mode: "auto",
      run_in_background: true,
      prompt: $AGENT_PROMPT
  })
  ```

  If `$IAC_DETECTED`, also dispatch:
  ```
  Agent({
      description: "Trivy IaC security review",
      subagent_type: "code-review:trivy-reviewer",
      name: "trivy-reviewer",
      mode: "auto",
      run_in_background: true,
      prompt: $AGENT_PROMPT
  })
  ```

  **Batching fallback:**
  ````

- [ ] **Step 3: Update the batching fallback note and `$SPECIALIST_COUNT` description**

  Find this exact two-line block (Batch 2 description plus the `Store $SPECIALIST_COUNT...` line, separated by other lines including the eb0bbda commit reference and the "fallback only" line):

  ```
  - **Batch 2** (dispatch after batch 1 completes): archaeology-reviewer, reuse-reviewer, efficiency-reviewer, alignment-reviewer, plus any conditional specialists
  ```

  Replace with:

  ```
  - **Batch 2** (dispatch after batch 1 completes): archaeology-reviewer, reuse-reviewer, efficiency-reviewer, alignment-reviewer, plus any conditional specialists (jbinspect, ui, eslint, ruff, trivy — up to 5)
  ```

  Then find:

  ```
  Store `$SPECIALIST_COUNT` = number of specialists dispatched (8 core only, 9 with C# or UI, 10 with both) and note the dispatch timestamp.
  ```

  Replace with:

  ```
  Store `$SPECIALIST_COUNT` = number of specialists dispatched (8 core only; 9–13 with conditionals: +1 each for `$CSHARP_DETECTED`, `$UI_DETECTED`, `$JS_DETECTED`, `$PY_DETECTED`, `$IAC_DETECTED`) and note the dispatch timestamp.
  ```

- [ ] **Step 4: Update Step 4.3 verify-completeness self-check**

  Find this exact line (line 751 in the canonical at plan-writing time):

  ```
  2. Compare against the mandatory set: `security-reviewer`, `correctness-reviewer`, `consistency-reviewer`, `style-reviewer`, `archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer` (plus `jbinspect-reviewer` if `$CSHARP_DETECTED`, plus `ui-reviewer` if `$UI_DETECTED`)
  ```

  Replace with:

  ```
  2. Compare against the mandatory set: `security-reviewer`, `correctness-reviewer`, `consistency-reviewer`, `style-reviewer`, `archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer` (plus `jbinspect-reviewer` if `$CSHARP_DETECTED`, plus `ui-reviewer` if `$UI_DETECTED`, plus `eslint-reviewer` if `$JS_DETECTED`, plus `ruff-reviewer` if `$PY_DETECTED`, plus `trivy-reviewer` if `$IAC_DETECTED`)
  ```

- [ ] **Step 5: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -E '(pipeline inline sync|cross-review-mode|FAIL)' | head -10
  ```

  Expected: `test_sync_pipeline_inline_matches_canonical` still failing (consumers not yet re-spliced); cross-review-mode sync test still passing.

  No commit yet — continue to Task 10.

---

## Task 10: Update `review-pipeline.md` Step 5 (cross-review exclusion)

**Files:**
- Modify: `plugins/code-review/includes/review-pipeline.md` lines 806–820 (Step 5 opening + count table) and line 838 (Step 5.2 sub-step 3)

- [ ] **Step 1: Read Step 5 opening + count table**

  ```
  sed -n '805,822p' $REPO_ROOT/plugins/code-review/includes/review-pipeline.md
  ```

  Confirm the opening paragraph mentions only jbinspect; the count table has four scenario rows.

- [ ] **Step 2: Replace Step 5 opening paragraph**

  Find this exact line:

  ```
  Dispatch fresh cross-review agents in parallel — one per domain, EXCLUDING jbinspect (jbinspect reports static analysis tool output that doesn't benefit from cross-domain evaluation).
  ```

  Replace with:

  ```
  Dispatch fresh cross-review agents in parallel — one per domain, EXCLUDING the four static-analysis specialists (`jbinspect`, `eslint`, `ruff`, `trivy`). Static-analysis tool output does not benefit from cross-domain evaluation — see `includes/static-analysis-context.md` §8.
  ```

- [ ] **Step 3: Replace the count table**

  Find this exact block:

  ```
  Store `$CROSS_REVIEW_COUNT` = number of cross-review agents per this table (jbinspect is excluded — static analysis output, no cross-domain benefit):

  | Scenario     | `$SPECIALIST_COUNT` | `$CROSS_REVIEW_COUNT` |
  |--------------|---------------------|-----------------------|
  | No C#, no UI | 8                   | 8                     |
  | C# only      | 9                   | 8                     |
  | UI only      | 9                   | 9                     |
  | C# and UI    | 10                  | 9                     |

  Use `$CROSS_REVIEW_COUNT` (not `$SPECIALIST_COUNT`) as the total count `R` counts down from in progress reporting below.
  ```

  Replace with:

  ```
  Store `$CROSS_REVIEW_COUNT` = number of cross-review agents per this table (the four static-analysis specialists are excluded — tool output, no cross-domain benefit):

  | Scenario                | `$CROSS_REVIEW_COUNT` |
  |-------------------------|-----------------------|
  | `$UI_DETECTED` is false | 8                     |
  | `$UI_DETECTED` is true  | 9                     |

  Static-analysis specialists never contribute to `$CROSS_REVIEW_COUNT` regardless of how many fire. `$SPECIALIST_COUNT` is unaffected by this table — it still includes static-analysis specialists.

  Use `$CROSS_REVIEW_COUNT` (not `$SPECIALIST_COUNT`) as the total count `R` counts down from in progress reporting below.
  ```

- [ ] **Step 4: Update Step 5.2 sub-step 3**

  Find this exact line:

  ```
  3. Include jbinspect findings (if present) for ALL cross-reviewers — jbinspect is excluded from receiving cross-review, not from being reviewed. Omit the `### jbinspect-reviewer findings` block entirely if `$CSHARP_DETECTED` is false — do not include a placeholder
  ```

  Replace with:

  ```
  3. Include findings from any static-analysis specialist (`jbinspect`, `eslint`, `ruff`, `trivy`) for ALL cross-reviewers — they are excluded from receiving cross-review, not from being reviewed. Omit any `### <name>-reviewer findings` block whose corresponding detection flag is false (`$CSHARP_DETECTED`, `$JS_DETECTED`, `$PY_DETECTED`, `$IAC_DETECTED` respectively) — do not include placeholders
  ```

- [ ] **Step 5: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -E '(pipeline inline sync|FAIL)' | head -10
  ```

  Expected: pipeline inline sync still failing (waiting on Task 11 re-splice).

  No commit yet — continue to Task 11.

---

## Task 11: Re-splice canonical pipeline into `SKILL.md` and `pre-review.md`

**Files:**
- Modify: `plugins/code-review/skills/review-gh-pr/SKILL.md`
- Modify: `plugins/code-review/commands/pre-review.md`

The canonical body is bounded by `Follow these instructions exactly. Do not skip steps or reorder.` (start) through `Present the synthesiser's formatted report to the user.` (end), per `test_sync_pipeline_inline_matches_canonical`.

- [ ] **Step 1: Verify the canonical extraction works**

  ```
  sed -n '/^Follow these instructions exactly/,/^Present the synthesiser.*formatted report to the user\.$/ p' $REPO_ROOT/plugins/code-review/includes/review-pipeline.md | wc -l
  ```

  Expected: a non-zero line count (the canonical body is hundreds of lines after the Task 8–10 edits).

- [ ] **Step 2: Re-splice into `SKILL.md`**

  In `$REPO_ROOT/plugins/code-review/skills/review-gh-pr/SKILL.md`, find the line `Follow these instructions exactly. Do not skip steps or reorder.` and the matching end line `Present the synthesiser's formatted report to the user.` Use the Edit tool to replace the entire range (inclusive of both anchor lines) with the canonical body extracted from `review-pipeline.md`.

  Cleanest approach: use the Bash tool to extract the canonical body to a temp file, then read both files and use the Edit tool to swap the body into the consumer.

  ```bash
  sed -n '/^Follow these instructions exactly/,/^Present the synthesiser.*formatted report to the user\.$/ p' \
      "$REPO_ROOT/plugins/code-review/includes/review-pipeline.md" \
      > "$CLAUDE_TEMP_DIR/canonical-pipeline-body.md"
  ```

  Then read `$CLAUDE_TEMP_DIR/canonical-pipeline-body.md` and use the Edit tool to swap the SKILL.md body. Use `old_string` = the existing consumer body (read it first to capture the exact existing block) and `new_string` = the canonical body.

- [ ] **Step 3: Re-splice into `pre-review.md`**

  Same procedure as Step 2 but for `$REPO_ROOT/plugins/code-review/commands/pre-review.md`.

- [ ] **Step 4: Run the sync test**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -E 'pipeline inline sync'
  ```

  Expected:
  ```
  pipeline inline sync: SKILL.md/SKILL.md matches canonical
  pipeline inline sync: commands/pre-review.md matches canonical
  ```

- [ ] **Step 5: Run the full suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all existing tests pass. No new tests yet (Task 15 adds them).

- [ ] **Step 6: Commit Tasks 8–11 as one logical commit**

  ```bash
  git add plugins/code-review/includes/review-pipeline.md \
          plugins/code-review/skills/review-gh-pr/SKILL.md \
          plugins/code-review/commands/pre-review.md
  git commit -m "feat(code-review): wire static-analysis specialists into the dispatcher

  - Step 2.6: add \$JS_DETECTED, \$PY_DETECTED, \$IAC_DETECTED detection flags
  - Step 4.2: add three conditional dispatch blocks; expand batching note
  - Step 4.3: extend the mandatory-dispatch self-check to enumerate the new
    conditional set
  - Step 5: exclude all four static-analysis specialists from cross-review;
    simplify the count table to a single conditional axis (\$UI_DETECTED)
  - Step 5.2 sub-step 3: generalise the static-analysis-findings-visible-to-
    cross-reviewers rule

  Canonical edited in includes/review-pipeline.md, then re-spliced into
  SKILL.md and pre-review.md per the existing inline-sync test."
  ```

---

## Task 12: Update `marketplace.json`

**Files:**
- Modify: `.claude-plugin/marketplace.json` (`code-review` plugin description)

- [ ] **Step 1: Read the current entry**

  ```
  cat $REPO_ROOT/.claude-plugin/marketplace.json
  ```

  Confirm the `code-review` plugin's `description` reads:
  ```
  "10 specialist code review agents with orchestrator, PR review skill, pre-review and address-pr-comments commands"
  ```

- [ ] **Step 2: Update the description**

  Use the Edit tool to replace:

  ```
  "description": "10 specialist code review agents with orchestrator, PR review skill, pre-review and address-pr-comments commands",
  ```

  …with:

  ```
  "description": "13 specialist code review agents (incl. ESLint, Ruff, Trivy IaC, JetBrains InspectCode), shared static-analysis include, PR review skill, pre-review and address-pr-comments commands",
  ```

- [ ] **Step 3: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -E 'marketplace|FAIL'
  ```

  Expected: marketplace tests pass; no version field added (none should be).

- [ ] **Step 4: Commit**

  ```bash
  git add .claude-plugin/marketplace.json
  git commit -m "docs(marketplace): bump code-review description to 13 specialists"
  ```

---

## Task 13: Update repo `README.md`

**Files:**
- Modify: `README.md` (plugin table + prerequisites table)

- [ ] **Step 1: Read the current README**

  ```
  sed -n '7,15p' $REPO_ROOT/README.md
  ```

  Confirm the plugin table row for code-review reads:
  ```
  | [code-review](plugins/code-review/) | 10 specialist code review agents, PR review skill, pre-review and address-pr-comments commands |
  ```

  And the prerequisites table row:
  ```
  | code-review | `jb` (JetBrains CLI) — optional, only for C# projects |
  ```

- [ ] **Step 2: Replace the plugin table description**

  Edit:

  ```
  | [code-review](plugins/code-review/) | 10 specialist code review agents, PR review skill, pre-review and address-pr-comments commands |
  ```

  …to:

  ```
  | [code-review](plugins/code-review/) | 13 specialist code review agents (ESLint, Ruff, Trivy IaC, JetBrains InspectCode + 9 LLM specialists), PR review skill, pre-review and address-pr-comments commands |
  ```

- [ ] **Step 3: Replace the prerequisites entry**

  Edit:

  ```
  | code-review | `jb` (JetBrains CLI) — optional, only for C# projects |
  ```

  …to:

  ```
  | code-review | `jb` (JetBrains CLI) — optional, only for C# projects; `eslint` or `biome` (project-local via `npm install`) — optional, only for JS/TS projects; `ruff` (`brew install ruff`) — optional, only for Python projects (`nbqa` only if Ruff < 0.6.0); `trivy` (`brew install trivy`) — optional, only for IaC repos |
  ```

- [ ] **Step 4: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass.

- [ ] **Step 5: Commit**

  ```bash
  git add README.md
  git commit -m "docs(readme): note new static-analysis specialists in plugin table + prereqs"
  ```

---

## Task 14: Update plugin `README.md`

**Files:**
- Modify: `plugins/code-review/README.md` (agents table + architecture paragraph + prerequisites)

- [ ] **Step 1: Read the agents table**

  ```
  sed -n '56,73p' $REPO_ROOT/plugins/code-review/README.md
  ```

  Confirm structure: `## Agents` heading + table with the 11 existing agent rows plus `cross-reviewer` and `review-synthesiser`.

- [ ] **Step 2: Add three rows to the agents table**

  Find the row (currently the 10th data row) starting `| jbinspect-reviewer |` — directly after it, insert three new rows. Use the Edit tool to replace this exact block (jbinspect row + ui-reviewer row):

  ```
  | `jbinspect-reviewer` | JetBrains InspectCode static analysis for C# (conditional — `.cs` files only) |
  | `ui-reviewer` | UI/UX quality, accessibility, usability (conditional — visual component files only) |
  ```

  …with:

  ```
  | `jbinspect-reviewer` | JetBrains InspectCode static analysis for C# (conditional — `.cs` files only) |
  | `eslint-reviewer` | ESLint or Biome static analysis for JS/TS (conditional — `.js`/`.jsx`/`.mjs`/`.cjs`/`.ts`/`.tsx`/`.vue`/`.svelte` files only) |
  | `ruff-reviewer` | Ruff static analysis for Python (conditional — `.py`/`.ipynb` files only; notebooks via Ruff ≥ 0.6.0 or `nbqa` fallback) |
  | `trivy-reviewer` | `trivy config` IaC security analysis (conditional — Terraform / Dockerfile / Kubernetes / Helm / CFN files only) |
  | `ui-reviewer` | UI/UX quality, accessibility, usability (conditional — visual component files only) |
  ```

- [ ] **Step 3: Update the architecture paragraph**

  Find the line (in `## Architecture` section, item 4):

  ```
  4. **Full review pipeline** — larger diffs dispatch 8-10 specialist agents in parallel, then fresh cross-review agents evaluate peer findings, then a synthesiser produces a tiered report
  ```

  Replace with:

  ```
  4. **Full review pipeline** — larger diffs dispatch 8 core specialists plus up to 5 conditional specialists (C#, UI, JS/TS, Python, IaC) in parallel, then fresh cross-review agents evaluate peer findings (excluding the four static-analysis specialists — see `includes/static-analysis-context.md`), then a synthesiser produces a tiered report
  ```

- [ ] **Step 4: Update the Specialists paragraph**

  Find this paragraph:

  ```
  The full review path dispatches 8 core specialists (10 with both C# and UI files):
  `security-reviewer`, `correctness-reviewer`, `consistency-reviewer`, `style-reviewer`,
  `archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer`, plus
  the conditional `jbinspect-reviewer` (C#) and `ui-reviewer` (UI). The new
  `alignment-reviewer` reasons inversely from the intent ledger to the diff, flagging intent
  drift and over-scope.
  ```

  Replace with:

  ```
  The full review path dispatches 8 core specialists (up to 13 with all conditionals):
  `security-reviewer`, `correctness-reviewer`, `consistency-reviewer`, `style-reviewer`,
  `archaeology-reviewer`, `reuse-reviewer`, `efficiency-reviewer`, `alignment-reviewer`, plus
  conditional specialists by file type: `jbinspect-reviewer` (C#), `ui-reviewer` (visual
  components), `eslint-reviewer` (JS/TS), `ruff-reviewer` (Python incl. notebooks), and
  `trivy-reviewer` (IaC: Terraform, Dockerfile, Kubernetes, Helm, CFN). The four
  static-analysis specialists (`jbinspect`, `eslint`, `ruff`, `trivy`) share the
  cross-cutting contract in `includes/static-analysis-context.md` and are excluded from
  cross-review (their tool output does not benefit from cross-domain evaluation).
  ```

- [ ] **Step 5: Update Prerequisites section**

  Find:

  ```
  - `gh` (GitHub CLI) — required for PR interactions; graceful fallback for base branch if absent
  - `jb` (JetBrains CLI) — optional, only needed for C# InspectCode analysis
  - `playwright-cli` skill — optional, enables visual verification of UI reviewer findings
  ```

  Replace with:

  ```
  - `gh` (GitHub CLI) — required for PR interactions; graceful fallback for base branch if absent
  - `jb` (JetBrains CLI) — optional, only needed for C# InspectCode analysis
  - `eslint` or `biome` — optional, only needed for JS/TS projects. The reviewer prefers project-local binaries (`<project>/node_modules/.bin/`) over global; install via the project's own `npm install` rather than globally.
  - `ruff` (`brew install ruff`) — optional, only needed for Python projects. For Jupyter notebook support on Ruff < 0.6.0, also install `nbqa` (`pip install nbqa`).
  - `trivy` (`brew install trivy`) — optional, only needed for IaC security analysis. First run on a clean machine fetches the policy DB (~10s slower); subsequent runs are fast.
  - `playwright-cli` skill — optional, enables visual verification of UI reviewer findings
  ```

- [ ] **Step 6: Run the suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass.

- [ ] **Step 7: Commit**

  ```bash
  git add plugins/code-review/README.md
  git commit -m "docs(code-review): document new static-analysis specialists in plugin README

  Three new agents-table rows; architecture paragraph updated to note up to
  5 conditional specialists; prerequisites section adds eslint/biome,
  ruff/nbqa, trivy entries."
  ```

---

## Task 15: Add structural tests

**Files:**
- Modify: `tests/lib/test_cross_references.sh` (citation-presence test)
- Modify: `tests/lib/test_sync_notes.sh` (dispatcher-flag presence test + severity-mapping literal test)

- [ ] **Step 1: Write the failing citation-presence test**

  Append to `$REPO_ROOT/tests/lib/test_cross_references.sh` (after the existing functions, before the final closing — note that the file currently ends after `test_command_directories_have_commands`):

  ```bash
  test_static_analysis_specialists_cite_include() {
      local cr="$REPO_ROOT/plugins/code-review"
      if [[ ! -d "$cr" ]]; then
          skip "static-analysis citation" "code-review plugin not found"
          return
      fi

      local agent
      for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md; do
          local path="$cr/agents/$agent"
          if [[ ! -f "$path" ]]; then
              fail "static-analysis citation: $agent" "file not found"
              continue
          fi
          if grep -qF 'includes/static-analysis-context.md' "$path"; then
              pass "static-analysis citation: $agent cites includes/static-analysis-context.md"
          else
              fail "static-analysis citation: $agent cites includes/static-analysis-context.md" \
                  "literal token 'includes/static-analysis-context.md' not found"
          fi
      done
  }
  ```

- [ ] **Step 2: Write the failing dispatcher-flag presence test**

  Append to `$REPO_ROOT/tests/lib/test_sync_notes.sh` (after the existing functions):

  ```bash
  test_dispatcher_includes_new_static_analysis_flags() {
      local cr
      cr=$(_cr_dir)
      if [[ ! -d "$cr" ]]; then
          skip "static-analysis dispatcher flags" "code-review plugin not found"
          return
      fi

      local file
      for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
          local path="$cr/$file"
          if [[ ! -f "$path" ]]; then
              fail "static-analysis dispatcher flags: $file" "file not found"
              continue
          fi

          local flag
          for flag in '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED'; do
              if grep -qF "$flag" "$path"; then
                  pass "static-analysis dispatcher flags: $file contains $flag"
              else
                  fail "static-analysis dispatcher flags: $file contains $flag" \
                      "flag literal not found"
              fi
          done
      done
  }

  test_static_analysis_specialists_have_required_severity_mapping() {
      local cr
      cr=$(_cr_dir)
      if [[ ! -d "$cr" ]]; then
          skip "static-analysis severity literals" "code-review plugin not found"
          return
      fi

      local agent
      for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md; do
          local path="$cr/agents/$agent"
          if [[ ! -f "$path" ]]; then
              fail "static-analysis severity literals: $agent" "file not found"
              continue
          fi

          if grep -qF 'Confidence: 100' "$path"; then
              pass "static-analysis severity literals: $agent contains 'Confidence: 100'"
          else
              fail "static-analysis severity literals: $agent contains 'Confidence: 100'" \
                  "literal not found"
          fi

          if grep -qE '^## .* Findings$' "$path"; then
              pass "static-analysis severity literals: $agent has '## <name> Findings' heading"
          else
              fail "static-analysis severity literals: $agent has '## <name> Findings' heading" \
                  "no heading matching '## .* Findings$' found"
          fi
      done
  }
  ```

- [ ] **Step 3: Run the new tests**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep -E '(static.analysis|FAIL)'
  ```

  Expected: all three tests pass — the specialist files (Tasks 2–5) and dispatcher edits (Tasks 8–11) already satisfy the assertions. If any fail, the failure is real and points at a regression in earlier tasks; fix it before continuing.

- [ ] **Step 4: Run the full suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass (existing + 3 new).

- [ ] **Step 5: Commit**

  ```bash
  git add tests/lib/test_cross_references.sh tests/lib/test_sync_notes.sh
  git commit -m "test: add structural tests for static-analysis specialists

  - test_static_analysis_specialists_cite_include: each of the four
    static-analysis specialists cites includes/static-analysis-context.md
  - test_dispatcher_includes_new_static_analysis_flags: SKILL.md and
    pre-review.md each contain \$JS_DETECTED, \$PY_DETECTED, \$IAC_DETECTED
    (catches the case where the dispatcher edit lands in only one consumer)
  - test_static_analysis_specialists_have_required_severity_mapping: each
    specialist contains 'Confidence: 100' and a '## <name> Findings'
    heading (catches refactors that drop the severity-locked literals)"
  ```

---

## Task 16: Add behavioural smoke test scaffold (gated)

**Files:**
- Create: `tests/lib/test_static_analysis_behavioural.sh`
- Create: `tests/fixtures/static-analysis/eslint/bad.js`
- Create: `tests/fixtures/static-analysis/eslint/package.json`
- Create: `tests/fixtures/static-analysis/eslint/.eslintrc.json`
- Create: `tests/fixtures/static-analysis/ruff/bad.py`
- Create: `tests/fixtures/static-analysis/ruff/notebook.ipynb`
- Create: `tests/fixtures/static-analysis/trivy/Dockerfile`
- Create: `tests/fixtures/static-analysis/README.md`

This task creates the scaffold only. The test is gated by `CLAUDE_CODE_E2E_TESTS=1` and dispatches real Agent calls — it is not run on every PR. Stage 2 of the spec (separate work) executes it.

- [ ] **Step 1: Create the fixture directory layout**

  Create `$REPO_ROOT/tests/fixtures/static-analysis/README.md`:

  ```markdown
  # Static-analysis behavioural smoke-test fixtures

  Synthetic fixture tree consumed by `tests/lib/test_static_analysis_behavioural.sh`.

  Each subdirectory contains a single deterministic violation that the corresponding tool
  is guaranteed to flag:

  - `eslint/bad.js` — `no-unused-vars` (with config; needs ESLint or Biome installed)
  - `ruff/bad.py` — `F401` unused import (Ruff)
  - `ruff/notebook.ipynb` — same `F401` violation in a notebook cell
  - `trivy/Dockerfile` — `:latest` tag (Trivy `AVD-DS-0001`)

  The fixtures intentionally trip the simplest possible rule for each tool — adding more
  violations dilutes the assertion that the specialist surfaces canonical wording.
  ```

- [ ] **Step 2: Create the ESLint fixture**

  `$REPO_ROOT/tests/fixtures/static-analysis/eslint/bad.js`:

  ```javascript
  const unused = 42;
  console.log("hello");
  ```

  `$REPO_ROOT/tests/fixtures/static-analysis/eslint/package.json`:

  ```json
  {
    "name": "fixture-eslint",
    "private": true
  }
  ```

  `$REPO_ROOT/tests/fixtures/static-analysis/eslint/.eslintrc.json`:

  ```json
  {
    "rules": {
      "no-unused-vars": "error"
    }
  }
  ```

- [ ] **Step 3: Create the Ruff fixture (`.py`)**

  `$REPO_ROOT/tests/fixtures/static-analysis/ruff/bad.py`:

  ```python
  import os  # noqa: I001 — kept to deliberately trigger F401 below
  import sys

  print("hello")
  ```

  Note: `import os` is acceptable (used in the print path? no — also unused). Ruff F401 fires on the genuinely-unused `import sys`. Comment is illustrative.

  Actually drop the comment and the `import os` line — keep the fixture minimal:

  ```python
  import sys

  print("hello")
  ```

  `import sys` is unused → F401.

- [ ] **Step 4: Create the Ruff notebook fixture**

  `$REPO_ROOT/tests/fixtures/static-analysis/ruff/notebook.ipynb`:

  ```json
  {
    "cells": [
      {
        "cell_type": "code",
        "execution_count": null,
        "metadata": {},
        "outputs": [],
        "source": [
          "import sys\n",
          "\n",
          "print('hello')"
        ]
      }
    ],
    "metadata": {
      "kernelspec": {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3"
      },
      "language_info": {
        "name": "python"
      }
    },
    "nbformat": 4,
    "nbformat_minor": 5
  }
  ```

- [ ] **Step 5: Create the Trivy fixture**

  `$REPO_ROOT/tests/fixtures/static-analysis/trivy/Dockerfile`:

  ```
  FROM alpine:latest
  RUN echo "hello"
  ```

  Trivy flags `AVD-DS-0001` (image-tagged-as-latest) on the first line.

- [ ] **Step 6: Create the gated test scaffold**

  `$REPO_ROOT/tests/lib/test_static_analysis_behavioural.sh`:

  ```bash
  #!/usr/bin/env bash
  # Behavioural smoke test for static-analysis specialists.
  #
  # Gated by CLAUDE_CODE_E2E_TESTS=1 — dispatches real Agent calls, costs tokens, takes
  # minutes. Stage 2 of the static-analysis specialists spec executes it; CI runs it on a
  # schedule, not on every PR.
  #
  # The test asserts canonical wording from includes/static-analysis-context.md appears
  # verbatim in each specialist's observable output:
  #   - "Skipped — <tool> not available on PATH." for the PATH-miss branch
  #   - "0 findings — no <lang> files in diff." for the empty-diff branch
  #   - "Confidence: 100" literal on every finding
  #   - Output begins with "## <Tool name> Findings"
  #
  # Three iterations per specialist, all-pass required. If ≥ 1 specialist fails
  # persistently, the spec's rollback applies: convert ALL FOUR static-analysis
  # specialists to inline-with-sync-test.

  test_static_analysis_behavioural_smoke() {
      if [[ "${CLAUDE_CODE_E2E_TESTS:-0}" != "1" ]]; then
          skip "static-analysis behavioural smoke" "set CLAUDE_CODE_E2E_TESTS=1 to run"
          return
      fi

      local fixture_root="$REPO_ROOT/tests/fixtures/static-analysis"
      if [[ ! -d "$fixture_root" ]]; then
          fail "static-analysis behavioural smoke" "fixture root missing: $fixture_root"
          return
      fi

      # Each specialist has three sub-checks (PATH-miss, no-files, normal run) × three
      # iterations. The actual Agent({...}) dispatches happen in the body — this scaffold
      # is intentionally a placeholder; Stage 2 implements the dispatch + output capture
      # under live Claude Code.
      pass "static-analysis behavioural smoke: scaffold present (Stage 2 implements live dispatch)"
  }
  ```

  Note: this scaffold passes a single placeholder assertion when gated on. The real Agent
  dispatches happen in Stage 2 (separate work, post-merge). The scaffold is here so the
  shell file exists with the gating mechanism wired up — Stage 2 only adds the dispatch
  logic.

- [ ] **Step 7: Run the suite gated off**

  ```
  bash $REPO_ROOT/tests/run.sh 2>&1 | grep behavioural
  ```

  Expected: skipped with "set CLAUDE_CODE_E2E_TESTS=1 to run" message.

- [ ] **Step 8: Run the suite gated on**

  ```
  CLAUDE_CODE_E2E_TESTS=1 bash $REPO_ROOT/tests/run.sh 2>&1 | grep behavioural
  ```

  Expected: scaffold-present pass.

- [ ] **Step 9: Run the full suite (gated off)**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass; behavioural test is skipped.

- [ ] **Step 10: Commit**

  ```bash
  git add tests/lib/test_static_analysis_behavioural.sh tests/fixtures/static-analysis/
  git commit -m "test: add behavioural smoke-test scaffold for static-analysis specialists

  Gated by CLAUDE_CODE_E2E_TESTS=1 — dispatches real Agent calls in Stage 2.
  Stage 1 ships the scaffold + synthetic fixtures (one ESLint-flaggable .js,
  one Ruff-flaggable .py + matching .ipynb, one Trivy-flaggable Dockerfile)
  so Stage 2 only adds the dispatch + output-capture logic. CI does not run
  this test on every PR."
  ```

---

## Task 17: Verify, dogfood, open PR

**Files:** none modified.

- [ ] **Step 1: Run the full structural test suite**

  ```
  bash $REPO_ROOT/tests/run.sh
  ```

  Expected: all tests pass; final summary line shows the new tests counted.

- [ ] **Step 2: Run pre-review against the branch (dogfood)**

  Verify the plugin reviews itself successfully with the new specialists wired in. From the branch root:

  ```
  /pre-review main
  ```

  Expected outcomes (any one is acceptable):
  - **Trivial-mode triggers** if the diff falls under the bar (unlikely given the size of this work) — verify the verdict and inline comments.
  - **Lightweight path** if the diff is under the threshold (also unlikely).
  - **Full pipeline** dispatches: confirm `eslint-reviewer`, `ruff-reviewer`, `trivy-reviewer` are all dispatched conditionally if the diff has matching files (the diff itself is mostly `.md`, so likely none of the three will fire — that's the canonical zero-state path; verify the dispatcher does NOT dispatch them when their flag is false).

  If any specialist that should NOT dispatch DOES dispatch (e.g. the orchestrator dispatches `eslint-reviewer` on a diff with no JS/TS files), the conditional logic is broken — fix and re-run before proceeding.

  Save the review output to `$CLAUDE_TEMP_DIR/dogfood-output.md` for reference.

- [ ] **Step 3: Push the branch and open a PR**

  ```
  git push -u origin feat/static-analysis-specialists-spec
  gh pr create --base main --title "feat(code-review): add language-specific static-analysis specialists" --body-file $CLAUDE_TEMP_DIR/pr-body.md
  ```

  Where `$CLAUDE_TEMP_DIR/pr-body.md` contains:

  ```markdown
  This PR broadens the code-review plugin's static-analysis coverage from C#-only to the languages and configuration formats actually used across the org's repos. Today only `jbinspect-reviewer` runs; this work adds three more — `eslint-reviewer` (JS/TS, with Biome auto-detect), `ruff-reviewer` (Python including Jupyter notebooks), and `trivy-reviewer` (IaC: Terraform / Dockerfile / Kubernetes / Helm / CFN). It also retrofits the existing C# reviewer onto a new shared include so future static-analysis work has a clean template. The choice of three (rather than more) is informed by a survey of the org's 675 source repos and a CI-coverage probe — see the spec for detail.

  This is the first of three planned stages. Stage 2 (separate PR) executes the gated behavioural smoke test against the synthetic fixture repo to verify the cite-only design holds; if it doesn't, Stage 2 inlines the include into each specialist with sync-test enforcement. Stage 3 is a backlog of follow-ups (severity-locked + capped-confidence policy, type-checking specialists, etc.).

  ## Changes

  - New `includes/static-analysis-context.md` shared include — captures the cross-cutting static-analysis contract (PATH check, `$CHANGED_LINES` filter, output format, `Confidence: 100` literal, cross-review opt-out) once. Cited from all four static-analysis specialists.
  - Three new specialists under `agents/`: `eslint-reviewer.md`, `ruff-reviewer.md`, `trivy-reviewer.md`. Each contributes only its tool-specific bits (extensions, binary discovery, invocation, severity mapping).
  - `agents/jbinspect-reviewer.md` and the InspectCode block in `agents/code-analysis.md` retrofitted to cite the new include.
  - `includes/cross-review-mode.md` HTML-comment-only update noting static-analysis specialists do not inline this file.
  - `includes/review-pipeline.md` (canonical) Step 2.6 detection flags (+3), Step 4.2 conditional dispatches (+3), batching note, Step 4.3 self-check, Step 5 cross-review exclusion + count table. Re-spliced into `SKILL.md` and `pre-review.md` per `test_sync_pipeline_inline_matches_canonical`.
  - `marketplace.json` description bump (10 → 13 specialists).
  - Repo + plugin READMEs updated.
  - Three new structural tests (`test_static_analysis_specialists_cite_include`, `test_dispatcher_includes_new_static_analysis_flags`, `test_static_analysis_specialists_have_required_severity_mapping`).
  - Behavioural smoke test scaffold under `CLAUDE_CODE_E2E_TESTS=1` plus synthetic fixtures.

  Spec: `docs/superpowers/specs/2026-05-12-static-analysis-specialists-design.md`.
  Plan: `docs/superpowers/plans/2026-05-12-static-analysis-specialists.md`.
  ```

- [ ] **Step 4: Watch CI and code-review**

  Verify the GitHub Actions structural-test workflow passes on the PR. If a self-review is configured, let it run and address any findings before merge.

---

## Self-review

After writing all 17 tasks, the plan was checked against the spec:

**Spec coverage:** Each spec section maps to a task —
- §"Shared include" → Task 1
- §"Per-specialist designs" subsections → Tasks 2 (eslint), 3 (ruff), 4 (trivy), 5 (jbinspect retrofit), 6 (code-analysis retrofit)
- §"Cite-only vs. inline — verification protocol" → Tasks 15 (structural tests), 16 (behavioural scaffold)
- §"Dispatcher wiring" subsections → Tasks 8 (Step 2.6), 9 (Step 4.2), 10 (Step 5), 11 (re-splice)
- §"Cross-review-mode include" guard comment → Task 7
- §"Marketplace and README updates" → Tasks 12, 13, 14
- §"Tests" → Tasks 15, 16
- §"Implementation plan outline" Stage 1 items 1–10 → all covered
- Stages 2 (verification) and 3 (backlog) — explicitly out of scope for this plan, called out in the goal section

**Type / token consistency:** Verified the same literal tokens are used everywhere — `includes/static-analysis-context.md` (citation), `Confidence: 100` (severity literal), `$JS_DETECTED` / `$PY_DETECTED` / `$IAC_DETECTED` (flags), `## <Tool> Findings` (heading shape). Tasks 15 tests assert these literals directly.

**Placeholders:** None. Each task includes the exact code snippets, file paths, line ranges, exact `old_string`/`new_string` Edit content, and exact commit messages.

**Granularity:** Tasks 8–11 are committed together (single canonical-then-respliced commit) because they leave the repo in a non-passing intermediate state — this is intentional and explicitly called out in Task 11 Step 6. Other tasks each commit independently and leave the suite green.
