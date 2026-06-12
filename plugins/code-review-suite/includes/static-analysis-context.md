<!-- STATIC-ANALYSIS CONTRACT — canonical source for static-analysis specialists.

Cited from:
  - agents/eslint-reviewer.md
  - agents/ruff-reviewer.md
  - agents/trivy-reviewer.md
  - agents/jbinspect-reviewer.md
  - agents/code-analysis.md (InspectCode section)

Cite-only design confirmed by Stage 2 behavioural smoke (33 dispatches across 4 specialists × 3
sub-checks × 3 iterations, jbinspect/normal_run N/A — no C# fixture): every specialist emitted
the canonical wording verbatim, with no skip-by-rationalisation. Driver protocol in
tests/fixtures/static-analysis/driver-prompt.md; results consumed by
tests/lib/test_static_analysis_behavioural.sh under CLAUDE_CODE_E2E_TESTS=1. See spec
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
file. Do not fall back to bare `/tmp/` or any path outside the resolved temp-dir path from the `Use <path> for temporary files.` line.

## 4. Temp-dir contract

The dispatcher injects a resolved absolute path via the `Use <path> for temporary files.` line in the specialist's prompt. Read the concrete path from that line (e.g. `/tmp/claude-5bf0f026-…/`) and use it directly — it is NOT an environment variable and does not require shell expansion. If the line is absent, report the omission and stop — never fall back to bare `/tmp/`. All intermediate files written by the specialist's tool invocation live under the resolved path.

## 5. `$CHANGED_LINES` filter

At parse time, intersect each finding's `(file, line)` against `$CHANGED_LINES[<file>]`. Drop
non-matching findings. Files marked `(empty — rename only)` accept zero findings. Files not in
`$CHANGED_LINES` at all are dropped entirely.

This filter is the load-bearing scope rule for static-analysis specialists. Without it, a
whole-tree scan reports findings on every pre-existing issue in every changed file — the goal is
to review what the PR introduced, not audit the rest.

## 6. Confidence and severity contract

Every finding includes the literal `Confidence: 100`. Severity is tool-derived; each specialist's
file declares its own mapping table (e.g. WARNING → Important, SUGGESTION → Suggestion — see §10
for the default-cap and Critical-allow-list mechanism). The `Confidence: 100` literal lets the
severity-locked + capped-confidence policy (§10) apply uniformly across all static-analysis
specialists.

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

**Authoring suggested fixes:** read the file around the flagged line and provide a concrete recommendation — don't paraphrase the tool's rule description. The `Suggested fix:` field should answer "what should the developer change?", not "what does the rule mean?".

Zero-findings case (after `$CHANGED_LINES` filtering): `## <Tool name> Findings\n\n0 findings.`

Report ALL findings whose mapped severity is not `omit`. Specialists may add a `Reference:` field
when the tool emits a stable URL.

## 8. Cross-review opt-out

Static-analysis specialists do NOT participate in cross-review mode. They are never re-invoked
with `Mode: cross-review`. Their findings ARE shown to the eight cross-reviewers (per Step 5.2
of the pipeline) — `security-cross-review` etc. may flag a static-analysis finding from another
angle — but the static-analysis specialist itself sits out the cross-review phase. The exclusion
generalises the existing jbinspect carve-out to the new specialists.

Specialists report only their tool's findings. Leave security, style, and correctness judgement
to peer reviewers — the cross-review machinery in Step 5 of the pipeline already triangulates
those domains.

## 9. Cleanup

Remove the tool's intermediate output files from the resolved temp-dir path after parsing. Skip cleanup
if the run was aborted (PATH miss, temp-dir absent) — there is nothing to clean.

## 10. Severity-locked + capped-confidence policy

Findings from static-analysis specialists are tool-derived, deterministic data. The
synthesiser must not reclassify their severity, must not silently dismiss them, and
must not adjust their confidence outside a hard envelope. This section codifies that
contract. The synthesiser cites it from `agents/review-synthesiser.md` under its
"Severity Reclassification" section.

**Severity is locked.** Each specialist's mapped severity (per its per-tool table —
ESLint mapping in `agents/eslint-reviewer.md`, Ruff in `agents/ruff-reviewer.md`,
Trivy in `agents/trivy-reviewer.md`, JetBrains InspectCode in
`agents/jbinspect-reviewer.md`) is authoritative. The synthesiser's "Severity
Reclassification" pass skips findings tagged `[eslint]`, `[ruff]`, `[trivy]`,
`[jbinspect]`, or `[housekeeper]`. There is no LLM override on severity for these findings.

**Confidence starts at 100.** Every static-analysis finding emits the literal
`Confidence: 100` (per §6). The synthesiser may cap it down within a bounded envelope
based on cross-reviewer dissent, but cannot raise it above 100.

**Per-source dissent budget.** The synthesiser examines the qualitative
`agree/disagree/supplement` text from each of 8 cross-reviewers (`security`,
`correctness`, `consistency`, `style`, `archaeology`, `reuse`, `efficiency`,
`alignment`) plus its own independent analysis as a 9th source. For each source it
decides whether that source dissented and how strongly, allocating
up to 5 points of confidence drop per source. Silence is not agreement —
silent sources contribute 0. Agreement also contributes 0; there is no "credit"
mechanism — confidence cannot exceed 100.

**Floor 50.** The clamp is `Confidence = max(50, 100 - Σ dissent)`. With 9 sources ×
5 points each, the maximum drop is 45, giving a hard floor of 50. The synthesiser
must not breach this floor — even if it judges every source maximally dissenting,
the rendered confidence stays at 50.

**Dismissed tier is forbidden.** Static-analysis findings only land in Consensus or
Contested. A floor-50 finding with substantial cross-review pushback lands in
Contested with the synthesiser's reasoning. Findings cannot be silently suppressed
into Dismissed.

**Critical-allow-list mechanism.** Each specialist's per-tool severity mapping caps
its highest tier at `Important` by default (Trivy `CRITICAL` → Important,
JetBrains `ERROR` → Important, ESLint `error` → Important, Ruff `S*` → Important).
Specific rule IDs that warrant `Critical` are listed in a `Critical-allow-list:`
subsection in each specialist file. The list is an explicit override rather than a
heuristic: a rule must be enumerated to escalate. This fails *safe* — a new tool rule
that should be Critical but is not on the list maps to its default cap; the LLM
`security-reviewer` can still flag it separately under the LLM-specialist contract.

The `housekeeper` specialist emits a uniform `Suggestion` severity (staleness is a smell, not a defect) and has no Critical-allow-list — its findings are severity-locked at `Suggestion`.

**Rendered output.** When the synthesiser adjusts confidence (`C < 100`), render the
adjusted value with this literal:

```
- **Confidence:** <C>  *(adjusted from 100 — <D> of 9 sources dissented)*
```

`C` is the final confidence (50–100); `D` is the number of dissenting sources
(0–9). When `C == 100` (no adjustment), the parenthetical is omitted entirely. Most
findings will not be adjusted, so the noise stays low.
