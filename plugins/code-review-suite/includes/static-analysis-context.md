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

## 0. Read-only mandate

This re-states the READ-ONLY MANDATE from `includes/specialist-context.md` because
static-analysis specialists skip most of that file (see §1 — only the "Determine base
branch" section is inherited). Keep the two copies in sync.

> **READ-ONLY MANDATE — NON-NEGOTIABLE**
>
> You are a reviewer. Your ONLY output is a findings report. You MUST NOT modify the
> repository in any way: no editing/creating/deleting files, and no `git add`,
> `git commit`, `git push`, `git reset`, `git checkout --`, `git stash`, or any other
> state-mutating command. Your Bash grant exists ONLY to run the analysis tool in its
> read-only mode plus read-only git queries (`git diff`, `git log`, `git show`). Never
> run a linter/formatter in `--fix`/`--write` mode. If you identify a fix, DESCRIBE it in
> the finding's `Suggested fix:` field — never apply it. Mutating the tree corrupts the
> commit the other reviewers are pinned to; it is a contract violation, not a convenience.

## 1. Inherit base context

Follow the "Determine the target repository" and "Determine base branch" sections of
`includes/specialist-context.md` to resolve `$REPO_DIR`, `$BASE`, `$HEAD_SHA`,
`$EMPTY_TREE_MODE`, `$PATH_SCOPE`, and `$CHANGED_LINES`. Skip the "Gather context"
pass (full diff, CLAUDE.md, file reads) — static-analysis specialists only need the file list.

Apply `$REPO_DIR` to EVERY command below: run every `git` invocation as
`git -C "$REPO_DIR" …`, and point the analysis tool at the work-tree under `$REPO_DIR`
(resolve solution/config roots beneath it; use the tool's working-directory flag, or
`git -C "$REPO_DIR" rev-parse --show-toplevel` to anchor the scan). When `$REPO_DIR` is
the current working directory this is a no-op — it is what lets a static-analysis pass
target a repository other than the current directory.

Run `git -C "$REPO_DIR" diff --name-only` to get the changed file list. Use the diff syntax
determined by `$EMPTY_TREE_MODE` (two-arg when true, three-dot when false).

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

## 8. Scope of a static-analysis specialist

Specialists report only their tool's findings. Leave security, style, and correctness judgement
to the LLM specialists and the panel: every static-analysis finding is shown to each panelist
alongside the other specialists' findings, and a panelist may raise a related issue from another
angle as its own finding.

## 9. Cleanup

Remove the tool's intermediate output files from the resolved temp-dir path after parsing. Skip cleanup
if the run was aborted (PATH miss, temp-dir absent) — there is nothing to clean.

## 10. Severity-locked policy

Findings from static-analysis specialists are tool-derived data. The panel votes only on
whether each one is real; it never reclassifies its severity. `review-core.js`
(`mapSpreadToTierConfidence`) enforces this contract in code.

**Severity is locked.** Each specialist's mapped severity (per its per-tool table —
ESLint mapping in `agents/eslint-reviewer.md`, Ruff in `agents/ruff-reviewer.md`,
Trivy in `agents/trivy-reviewer.md`, JetBrains InspectCode in
`agents/jbinspect-reviewer.md`) is authoritative. Panelist severity votes on findings from
`eslint`, `ruff`, `trivy`, `jbinspect`, or `housekeeper` are ignored. There is no LLM
override on severity for these findings.

**Existence gate.** A static-analysis specialist is an LLM relaying tool output, so it can
misreport a result. A finding that a panel majority votes not real is dismissed, exactly as
for an LLM specialist. Static trust governs severity, never whether the issue is real.

**Confidence reflects panel agreement.** A finding every panelist votes real carries
confidence `high` and, when its locked severity is Important or Critical, lands in Consensus
and blocks. A finding only a majority votes real carries confidence `low` and lands in
Contested, where it never blocks.

**Critical-allow-list mechanism.** Each specialist's per-tool severity mapping caps
its highest tier at `Important` by default (Trivy `CRITICAL` → Important,
JetBrains `ERROR` → Important, ESLint `error` → Important, Ruff `S*` → Important).
Specific rule IDs that warrant `Critical` are listed in a `Critical-allow-list:`
subsection in each specialist file. The list is an explicit override rather than a
heuristic: a rule must be enumerated to escalate. This fails *safe* — a new tool rule
that should be Critical but is not on the list maps to its default cap; the LLM
`security-reviewer` can still flag it separately under the LLM-specialist contract.

The `housekeeper` specialist emits a uniform `Suggestion` severity (staleness is a smell, not a defect) and has no Critical-allow-list — its findings are severity-locked at `Suggestion`.

**Housekeeper delivery model (distinct from the other static analysers).** Because
housekeeper findings routinely target manifest lines outside the diff hunk (it audits
the whole touched project, not just changed lines), they are NOT delivered as comments.
Every housekeeper finding the panel does not dismiss is rendered by `review-core.js` into a
single `### Dependency Freshness` table in the review body — informational, never
verdict-affecting, never producing an inline comment. When the housekeeper ran cleanly and
nothing survived, the section reads "all current"; when it did not run, the section is
omitted. The one route to the verdict is the **escalation break-out**: when a panelist
establishes that a specific upgrade is genuinely Important (a known CVE in the current
version, a security-critical fix, or an upgrade another finding depends on), it raises that
upgrade as its own finding, which is tallied, posted and verdict-eligible like any other
panel-raised finding. The table row stays as well.
