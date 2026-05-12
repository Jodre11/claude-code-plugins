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
