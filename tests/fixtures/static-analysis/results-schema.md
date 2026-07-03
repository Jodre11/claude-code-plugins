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

## Schema (version 2)

```json
{
  "schema_version": 2,
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
  },
  "synthesiser": {
    "synthesiser_severity_lock": {
      "iterations": 3,
      "passed": 3,
      "observed_severities": ["Important", "Important", "Important"],
      "observed_confidences": [55, 55, 60],
      "parenthetical_present": [true, true, true],
      "tier_placements": ["Contested", "Contested", "Contested"],
      "observed_excerpts": ["...", "...", "..."],
      "failure_reason": null
    }
  }
}
```

### Field semantics

| Field | Meaning |
|---|---|
| `schema_version` | Integer. Currently `2`. Bump on incompatible changes. |
| `run_at` | ISO 8601 UTC timestamp of when the driver started. The bash test rejects results older than `STATIC_ANALYSIS_SMOKE_FRESHNESS_DAYS` (default 30). |
| `git_sha` | Short SHA of `HEAD` when the driver ran — lets reviewers correlate results to a code state. |
| `driver_session_id` | Optional. Claude Code session UUID for traceability. |
| `overall_pass` | `true` iff every specialist sub-check AND the synthesiser sub-check passed every iteration. The decision gate per Stage-1 spec §"Cite-only vs. inline" plus the policy spec's synthesiser-side gate. See the iff rule under "Decision gate". |
| `specialists` | Object keyed by specialist name. Required keys: `jbinspect-reviewer`, `eslint-reviewer`, `ruff-reviewer`, `trivy-reviewer`. |
| `<sub-check-name>` | One of `path_miss`, `no_files`, `normal_run`. |
| `iterations` | Integer, ≥ 3. May rise to 5 per Risk 8 (temperature-tolerance retry). |
| `passed` | Integer, 0..iterations. Pass condition: assertion held in that iteration. |
| `canonical_wording_seen` | Array of literal strings observed verbatim in the dispatched specialist's reply. Empty array on failure. |
| `observed_excerpts` | Array of short verbatim excerpts (≤ 200 chars each) from each iteration's reply — for human review of failures. |
| `failure_reason` | `null` on pass; on failure, a short explanation of the divergence (e.g. "specialist used '## ESLint' instead of '## ESLint Findings'"). |

### Synthesiser block fields (schema_version ≥ 2)

| Field | Meaning |
|---|---|
| `synthesiser` | Object keyed by sub-check name. Currently only `synthesiser_severity_lock`. |
| `synthesiser_severity_lock.iterations` | Integer, ≥ 3. May rise to 5 per Risk 8 (temperature-tolerance retry) of the Stage-1 spec, mirroring the existing specialist-side rule. |
| `synthesiser_severity_lock.passed` | Integer, 0..iterations. Pass condition: severity unchanged AND confidence in `[50, 100]` AND parenthetical-present iff confidence < 100 AND tier ∈ {Consensus, Contested}. |
| `synthesiser_severity_lock.observed_severities` | Array of strings, length == iterations. The trivy finding's rendered severity per iteration. All entries must equal `"Important"` for `passed == iterations`. |
| `synthesiser_severity_lock.observed_confidences` | Array of integers, length == iterations. The trivy finding's rendered confidence per iteration. All entries must be in `[50, 100]`. |
| `synthesiser_severity_lock.parenthetical_present` | Array of booleans, length == iterations. `true` iff the rendered `(adjusted from 100 — …)` parenthetical is present in that iteration. Must equal `confidence[i] < 100`. |
| `synthesiser_severity_lock.tier_placements` | Array of strings, length == iterations. Each entry ∈ `{"Consensus", "Contested", "Dismissed"}`. Any `"Dismissed"` entry forces `passed < iterations` regardless of other fields. |
| `synthesiser_severity_lock.observed_excerpts` | Array of short verbatim excerpts (≤ 200 chars each) — the trivy finding block per iteration. |
| `synthesiser_severity_lock.failure_reason` | `null` on pass; on failure, a short explanation (e.g. "iteration 2 placed finding in Dismissed tier"). |

### Pass conditions per sub-check

Per `includes/static-analysis-context.md` and each specialist's per-tool wording:

| Sub-check | Required canonical literal(s) |
|---|---|
| `path_miss` | `Skipped — <tool> not available on PATH.` (per specialist: `eslint/biome`, `ruff`, `trivy`, `jb inspectcode`) |
| `no_files` | `## <Tool name> Findings` followed by `0 findings — no <lang> files in diff.` |
| `normal_run` | Output begins with `## <Tool name> Findings`; at least one finding line contains `Confidence: 100`; rule code matches the fixture's expected rule (eslint=`no-unused-vars`, ruff=`F401`, trivy=`AVD-DS-0001` or `DS-0001`, jbinspect=N/A — fixture-free, see below) |
| `synthesiser_severity_lock` | See "Synthesiser block fields (schema_version ≥ 2)" above for per-iteration assertions; the four pass conditions live in `tests/fixtures/static-analysis/driver-prompt.md` under "### Pass conditions" of the synthesiser-driver section. |

`jbinspect-reviewer` has no fixture (it requires a C# solution). For `normal_run`, the
driver may either: skip and document in `failure_reason: "no fixture — sub-check N/A"`
with `passed: 0`, or substitute a synthetic prompt that scopes to a non-C# diff and
expects `0 findings — no C# files in diff.` (effectively a duplicate of `no_files`).
The latter is documented in the driver prompt.

## Decision gate

After parsing:

- `overall_pass: true` → cite-only design holds for both the specialist side AND the
  synthesiser side. Phase 2 closes out; no rollback needed.
- `overall_pass: false` (specialist regression) → roll back the specialist side to
  inline-with-sync-test for ALL FOUR specialists (per Stage-1 spec §"Rollback shape").
- `overall_pass: false` (synthesiser breach — confidence < 50 or finding in Dismissed
  or severity reclassified) → roll back the synthesiser side: inline §10's policy text
  into `plugins/code-review-suite/agents/review-synthesiser.md` verbatim with a new sync
  test `test_sync_static_analysis_policy_inline_matches_canonical` (to be created on
  rollback, mirroring the existing `test_sync_cross_review_mode_inline_matches_canonical`).
  The cite-only design is empirically validated by the predecessor's Stage 2 so this
  rollback is unlikely; it is recorded for completeness.
- `overall_pass: false` (both specialist regression AND synthesiser breach) →
  execute both rollbacks independently. The two paths touch disjoint files (the four
  specialist files and the include vs. the synthesiser file), so they compose without
  conflict. The convert-all-or-none rule still applies within the specialist side.

`overall_pass = true` iff:

1. Every specialist sub-check has `passed == iterations >= 3` (or N/A per the
   existing rule), AND
2. The synthesiser sub-check has `passed == iterations >= 3`.
