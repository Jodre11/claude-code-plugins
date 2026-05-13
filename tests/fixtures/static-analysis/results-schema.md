# Static-analysis behavioural smoke — results-file schema

The behavioural smoke test (`tests/lib/test_static_analysis_behavioural.sh`) reads a JSON
results file written by an out-of-band driver session. Subagent dispatches (`Agent({...})`)
are an LLM-side capability and cannot be invoked from a bash test, so the bash test
*verifies* a results file produced earlier by a Claude Code driver session — it does not
*produce* one.

## File location

```
tests/lib/.static-analysis-smoke-results.json
```

Git-ignored (the leading `.` keeps it out of `tests/lib/test_*.sh` discovery and the
file is generated, not source-controlled). CI fetches it from the scheduled-run
artifact.

## Schema (version 1)

```json
{
  "schema_version": 1,
  "run_at": "2026-05-13T12:00:00Z",
  "git_sha": "abc1234",
  "driver_session_id": "uuid",
  "overall_pass": true,
  "specialists": {
    "<specialist-name>": {
      "<sub-check-name>": {
        "iterations": 3,
        "passed": 3,
        "canonical_wording_seen": ["..."],
        "observed_excerpts": ["...", "...", "..."],
        "failure_reason": null
      }
    }
  }
}
```

### Field semantics

| Field | Meaning |
|---|---|
| `schema_version` | Integer. Currently `1`. Bump on incompatible changes. |
| `run_at` | ISO 8601 UTC timestamp of when the driver started. The bash test rejects results older than `STATIC_ANALYSIS_SMOKE_FRESHNESS_DAYS` (default 30). |
| `git_sha` | Short SHA of `HEAD` when the driver ran — lets reviewers correlate results to a code state. |
| `driver_session_id` | Optional. Claude Code session UUID for traceability. |
| `overall_pass` | `true` iff every sub-check passed every iteration. The decision gate per spec §"Cite-only vs. inline". |
| `specialists` | Object keyed by specialist name. Required keys: `jbinspect-reviewer`, `eslint-reviewer`, `ruff-reviewer`, `trivy-reviewer`. |
| `<sub-check-name>` | One of `path_miss`, `no_files`, `normal_run`. |
| `iterations` | Integer, ≥ 3. May rise to 5 per Risk 8 (temperature-tolerance retry). |
| `passed` | Integer, 0..iterations. Pass condition: assertion held in that iteration. |
| `canonical_wording_seen` | Array of literal strings observed verbatim in the dispatched specialist's reply. Empty array on failure. |
| `observed_excerpts` | Array of short verbatim excerpts (≤ 200 chars each) from each iteration's reply — for human review of failures. |
| `failure_reason` | `null` on pass; on failure, a short explanation of the divergence (e.g. "specialist used '## ESLint' instead of '## ESLint Findings'"). |

### Pass conditions per sub-check

Per `includes/static-analysis-context.md` and each specialist's per-tool wording:

| Sub-check | Required canonical literal(s) |
|---|---|
| `path_miss` | `Skipped — <tool> not available on PATH.` (per specialist: `eslint/biome`, `ruff`, `trivy`, `jb inspectcode`) |
| `no_files` | `## <Tool name> Findings` followed by `0 findings — no <lang> files in diff.` |
| `normal_run` | Output begins with `## <Tool name> Findings`; at least one finding line contains `Confidence: 100`; rule code matches the fixture's expected rule (eslint=`no-unused-vars`, ruff=`F401`, trivy=`AVD-DS-0001` or `DS-0001`, jbinspect=N/A — fixture-free, see below) |

`jbinspect-reviewer` has no fixture (it requires a C# solution). For `normal_run`, the
driver may either: skip and document in `failure_reason: "no fixture — sub-check N/A"`
with `passed: 0`, or substitute a synthetic prompt that scopes to a non-C# diff and
expects `0 findings — no C# files in diff.` (effectively a duplicate of `no_files`).
The latter is documented in the driver prompt.

## Decision gate

After parsing:

- `overall_pass: true` → cite-only design holds. Update the include's HTML comment to
  remove "provisional" framing (per spec).
- `overall_pass: false` → roll back to inline-with-sync-test for ALL FOUR specialists
  (per spec §"Rollback shape"). The convert-all-or-none rule prevents drift.
