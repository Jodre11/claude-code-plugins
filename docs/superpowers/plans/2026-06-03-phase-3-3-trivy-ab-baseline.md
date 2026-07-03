# Phase 3.3 — Trivy static-specialist A/B baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the trivy-reviewer A/B apparatus (corpus fixture, parser-dispatch case, configs, live-captured worked example) and run the matched 2×20 Sonnet/default vs Haiku/low probe, producing a verdict + cost-ratio result note.

**Architecture:** Mirror the ruff/eslint per-agent A/B pattern exactly. trivy is global-on-PATH (like ruff) so NO `setup:` provisioning race exists — the fixture is a static Dockerfile copied per-trial. Three offline tasks (fixture, parser, configs) are TDD'd against captured/synthetic output and committed before any Bedrock spend; then two GATED live steps (worked-example capture, then the 2×20 sweep) require explicit operator go-ahead.

**Tech Stack:** bash test harness (`tests/ab/`), trivy 0.71.0 (`trivy config`), yq/jq/awk, Claude Code per-agent stream-json capture.

---

## Critical offline findings (already established this session — do NOT re-derive)

A live `trivy config --format=json --severity=MEDIUM,HIGH,CRITICAL --exit-code=0`
run against the candidate Dockerfile below produced this **deterministic** finding
set (captured 2026-06-03, trivy 0.71.0):

| trivy ID | Severity (native) | Mapped | StartLine | Title |
|----------|-------------------|--------|-----------|-------|
| `DS-0001` | MEDIUM | Suggestion | 1 | `':latest' tag used` |
| `DS-0004` | MEDIUM | Suggestion | 7 | `Port 22 exposed` |
| `DS-0031` | CRITICAL | **Critical** (title contains "Secrets" → allow-list) | 9 | `Secrets passed via build-args or envs or copied secret files` |

**Two load-bearing facts:**
1. **trivy 0.71 emits bare `DS-NNNN` IDs, NOT `AVD-XX-NNNN`** as `trivy-reviewer.md`
   line 73 claims. The agent body is stale. Do NOT "fix" the agent body to force
   `AVD-` — the live capture (Task 4) is the source of truth for what the agent
   actually emits; pin the worked example to the REAL `DS-NNNN` shape it produces.
   (If the agent itself normalises `DS-0001`→`AVD-DS-0001` in its report, the
   worked example captures THAT — capture-then-pin, never invent.)
2. **A finding with no `StartLine` (the original `DS-0002` "user should not be
   root") cannot form a tuple** (no line → fails the §5 changed-line intersection
   AND the parser's line requirement). The fixture Dockerfile below adds a `USER`
   directive specifically to suppress DS-0002 and keep all three findings
   line-bearing and deterministic.

**Tokeniser check:** the shared rule-ID tokeniser splits on `[ \t(]` token 1.
`DS-0031 (dockerfile)` → `DS-0031`. No internal spaces → tokenises cleanly, NO
tokeniser change needed. Task 2's parser test asserts this.

---

## File Structure

- `tests/fixtures/static-analysis/trivy/Dockerfile` — MODIFY (replace trivial
  `alpine`+`echo` with the 3-finding fixture). The scanned input.
- `tests/ab/corpus/trivy-smoke-bad-dockerfile/source.yaml` — CREATE. Fixture metadata.
- `tests/ab/corpus/trivy-smoke-bad-dockerfile/diff/changed-lines.txt` — CREATE. §5 scope.
- `tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings-trivy.md` — CREATE
  (promoted from the Task 4 live capture, NOT pre-authored).
- `tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings.json` — CREATE
  (promoted, Task 4).
- `tests/ab/corpus/index.yaml` — MODIFY. Register the fixture.
- `tests/ab/lib/agent_capture.sh:33` — MODIFY. Add the `trivy|trivy-reviewer` case.
- `tests/ab/fixtures/trivy-stdout-three-findings.log` — CREATE. Parser test input.
- `tests/lib/test_ab_per_agent_lib.sh` — MODIFY. Add trivy parser tests.
- `tests/ab/configs/per-agent/trivy-baseline.yaml` — CREATE. sonnet/default.
- `tests/ab/configs/per-agent/trivy-haiku-low.yaml` — CREATE. haiku/low.
- `plugins/code-review-suite/agents/trivy-reviewer.md` — MODIFY (Task 5, post-capture).
  Pin the live-captured worked example. Possibly correct the stale `AVD-` claim.
- `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md` — CREATE (Task 7).

---

### Task 1: Corpus fixture (offline, no Bedrock)

**Files:**
- Modify: `tests/fixtures/static-analysis/trivy/Dockerfile`
- Create: `tests/ab/corpus/trivy-smoke-bad-dockerfile/source.yaml`
- Create: `tests/ab/corpus/trivy-smoke-bad-dockerfile/diff/changed-lines.txt`
- Modify: `tests/ab/corpus/index.yaml`

- [ ] **Step 1: Replace the trivial fixture Dockerfile**

Overwrite `tests/fixtures/static-analysis/trivy/Dockerfile` with exactly:

```dockerfile
FROM alpine:latest

RUN apk add --no-cache curl

COPY app /app

EXPOSE 22

ENV API_KEY=supersecret123

USER appuser

ENTRYPOINT ["/app/run"]
```

- [ ] **Step 2: Verify the fixture yields the expected 3-finding set**

Run (single Bash call, no compound operators):
```
trivy config --format=json --severity=MEDIUM,HIGH,CRITICAL --exit-code=0 tests/fixtures/static-analysis/trivy/ > "$CLAUDE_TEMP_DIR/trivy-fixture-check.json" 2>/dev/null
```
Then in a SEPARATE call:
```
jq -r '.Results[]? | .Misconfigurations[]? | "\(.ID)\t\(.Severity)\t\(.CauseMetadata.StartLine // "NULL")"' "$CLAUDE_TEMP_DIR/trivy-fixture-check.json"
```
Expected output (exactly three lines, all line-bearing):
```
DS-0001	MEDIUM	1
DS-0004	MEDIUM	7
DS-0031	CRITICAL	9
```
If any line shows `NULL` or a fourth finding appears, STOP — the fixture drifted;
do not proceed.

- [ ] **Step 3: Write the changed-lines scope file**

Create `tests/ab/corpus/trivy-smoke-bad-dockerfile/diff/changed-lines.txt`:
```
Changed lines:
  Dockerfile: 1,7,9
```
(Lines 1/7/9 are the three finding lines — the §5 intersection keeps all three.)

- [ ] **Step 4: Write source.yaml**

Create `tests/ab/corpus/trivy-smoke-bad-dockerfile/source.yaml`. Copy the
eslint shape but with NO `setup:` block (trivy is global-on-PATH; no provisioning):
```yaml
id: trivy-smoke-bad-dockerfile
agent: trivy-reviewer
captured_at: 2026-06-03T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: PLACEHOLDER_FILL_AT_CAPTURE
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/trivy/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - Synthetic smoke fixture exercising trivy-reviewer against a single
    Dockerfile with a deterministic three-finding IaC set (DS-0001 latest-tag,
    DS-0004 port-22, DS-0031 secret-in-env). Phase 3.3 baseline for the
    Haiku/low cost-tuning probe. trivy 0.71 emits bare DS-NNNN IDs.
depends_on:
  - plugins/code-review-suite/agents/trivy-reviewer.md
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/trivy/Dockerfile
```
NOTE: `suite_sha` is filled at capture time (Task 4) with the then-current HEAD;
leave the literal `PLACEHOLDER_FILL_AT_CAPTURE` until then so a forgotten fill is
visible. `baseline_revision: 1` (first baseline for this fixture).

- [ ] **Step 5: Register the fixture in the corpus index**

In `tests/ab/corpus/index.yaml`, append under `fixtures:`:
```yaml
  - id: trivy-smoke-bad-dockerfile
    agent: trivy-reviewer
    type: synthetic
    description: Three-finding IaC set (DS-0001 latest-tag, DS-0004 port-22, DS-0031 secret-env) on a single Dockerfile. Phase 3.3 baseline.
    tags: [smoke, deterministic]
```

- [ ] **Step 6: Run the suite (expect green except the known dirty-tree artifact)**

Run: `bash tests/run.sh`
Expected: all pass EXCEPT `A/B run.sh: bad-config rejection leaves working tree
clean` (false-fails on uncommitted changes). No OTHER failures.

- [ ] **Step 7: Commit (do NOT push yet — push after the commit per the always-push rule)**

```bash
git add tests/fixtures/static-analysis/trivy/Dockerfile tests/ab/corpus/trivy-smoke-bad-dockerfile/source.yaml tests/ab/corpus/trivy-smoke-bad-dockerfile/diff/changed-lines.txt tests/ab/corpus/index.yaml
git commit -m "test(ab): add trivy-smoke-bad-dockerfile corpus fixture (3 deterministic IaC findings)"
git push origin main
```

---

### Task 2: Parser-dispatch case + tests (offline, no Bedrock)

**Files:**
- Modify: `tests/ab/lib/agent_capture.sh` (add `trivy|trivy-reviewer` case ~line 32)
- Create: `tests/ab/fixtures/trivy-stdout-three-findings.log`
- Modify: `tests/lib/test_ab_per_agent_lib.sh`

- [ ] **Step 1: Write the captured-output test fixture**

Create `tests/ab/fixtures/trivy-stdout-three-findings.log`. This mirrors the
ruff fixture shape (preamble noise + canonical §7 block + trailing prose). Use
the REAL `DS-NNNN` rule IDs and the mapped severities from the findings table:
```
Some preamble noise from the dispatched session.

## Trivy IaC Findings

### Finding — latest tag used
- **File:** Dockerfile:1
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** DS-0001 (dockerfile)
- **Description:** ':latest' tag used.
- **Suggested fix:** Pin the base image to an explicit version.

### Finding — port 22 exposed
- **File:** Dockerfile:7
- **Confidence:** 100
- **Severity:** Suggestion
- **Rule:** DS-0004 (dockerfile)
- **Description:** Port 22 exposed.
- **Suggested fix:** Remove the EXPOSE 22 instruction unless SSH is required.

### Finding — secret in env
- **File:** Dockerfile:9
- **Confidence:** 100
- **Severity:** Critical
- **Rule:** DS-0031 (dockerfile)
- **Description:** Secrets passed via build-args or envs or copied secret files.
- **Suggested fix:** Inject the secret at runtime, not via ENV in the image.

Trailing prose that must not be parsed as a finding.
```

- [ ] **Step 2: Write the failing parser tests**

In `tests/lib/test_ab_per_agent_lib.sh`, add three tests modelled on the ruff
trio (`test_ab_agent_capture_parses_three_findings` etc., lines 270-336). Add:

```bash
test_ab_agent_capture_trivy_parses_three_findings() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trivy-stdout-three-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture trivy: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "3" "$count" "A/B agent_capture trivy: three findings extracted"

    local first_rule first_file first_line first_sev
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    first_file=$(jq -r '.[0].file' "$trial_dir/findings.json")
    first_line=$(jq -r '.[0].line' "$trial_dir/findings.json")
    assert_equals "DS-0001" "$first_rule" "A/B agent_capture trivy: bare DS-NNNN rule_id tokenises cleanly"
    assert_equals "Dockerfile" "$first_file" "A/B agent_capture trivy: file parsed"
    assert_equals "1" "$first_line" "A/B agent_capture trivy: line parsed"

    local crit_sev
    crit_sev=$(jq -r '.[] | select(.rule_id == "DS-0031") | .severity' "$trial_dir/findings.json")
    assert_equals "Critical" "$crit_sev" "A/B agent_capture trivy: DS-0031 severity Critical"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_trivy_zero_findings_is_empty_array() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## Trivy IaC Findings\n\n0 findings — no IaC files in diff.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$REPO_ROOT/tests/ab/lib/agent_capture.sh"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture trivy: zero-state yields empty array"
    rm -rf "$trial_dir"
}

test_ab_agent_capture_trivy_skipped_marks_inconclusive() {
    local trial_dir
    trial_dir=$(mktemp -d)
    printf 'Skipped — trivy not available on PATH.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$REPO_ROOT/tests/ab/lib/agent_capture.sh"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture trivy: skip marks INCONCLUSIVE"
    else
        fail "A/B agent_capture trivy: skip marks INCONCLUSIVE" "marker absent"
    fi
    rm -rf "$trial_dir"
}
```

Register the three new test function names in the test runner's list if the
suite uses an explicit registry (grep `test_ab_agent_capture_parses_three_findings`
in `tests/run.sh` and any `tests/lib/*.sh` registry; mirror however ruff's are
registered — if discovery is automatic by `test_*` prefix, no registration needed).

- [ ] **Step 3: Run the new tests to verify they FAIL**

Run: `bash tests/run.sh 2>&1 | grep -i trivy`
Expected: the three new trivy tests FAIL with "unknown agent: trivy" (the parser
case doesn't exist yet).

- [ ] **Step 4: Add the trivy parser-dispatch case**

In `tests/ab/lib/agent_capture.sh`, in `_agent_capture_params()`, add a case
BEFORE the `*)` fallthrough (after the `eslint` case, ~line 32). The zero-state
and skip lines come verbatim from `trivy-reviewer.md` lines 26-32:
```bash
        trivy|trivy-reviewer)
            _AC_HEADING='^## Trivy IaC Findings$'
            _AC_SKIP='^Skipped — trivy not available'
            _AC_ZERO='^0 findings — no IaC files in diff\.'
            ;;
```
Update the header comment block (lines 11-13) to note trivy's `DS-NNNN`/`AVD-`
IDs also tokenise cleanly (no internal spaces), so the shared tokeniser still
covers it.

- [ ] **Step 5: Run the new tests to verify they PASS**

Run: `bash tests/run.sh 2>&1 | grep -i trivy`
Expected: all three new trivy tests PASS.

- [ ] **Step 6: Run the FULL suite**

Run: `bash tests/run.sh`
Expected: all pass except the known dirty-tree artifact. Note the new total
(should be 342 + 3 = 345 passed / 1 skipped once committed clean).

- [ ] **Step 7: Commit + push**

```bash
git add tests/ab/lib/agent_capture.sh tests/ab/fixtures/trivy-stdout-three-findings.log tests/lib/test_ab_per_agent_lib.sh
git commit -m "test(ab): add trivy parser-dispatch case + captured-output tests"
git push origin main
```

---

### Task 3: A/B configs (offline, no Bedrock)

**Files:**
- Create: `tests/ab/configs/per-agent/trivy-baseline.yaml`
- Create: `tests/ab/configs/per-agent/trivy-haiku-low.yaml`

- [ ] **Step 1: Write the baseline config**

Create `tests/ab/configs/per-agent/trivy-baseline.yaml` (copy eslint-baseline shape):
```yaml
name: trivy-baseline
description: Production reference for trivy-reviewer — sonnet at default effort.
mode: per-agent
agent: trivy-reviewer
session:
  model: sonnet
  effort: default
```

- [ ] **Step 2: Write the haiku-low config**

Create `tests/ab/configs/per-agent/trivy-haiku-low.yaml`:
```yaml
name: trivy-haiku-low
description: Phase 3.3 directional probe — trivy-reviewer at Haiku/low. Compared against trivy-baseline (sonnet/default) on per-trial findings hash.
mode: per-agent
agent: trivy-reviewer
session:
  model: haiku
  effort: low
```

- [ ] **Step 3: Verify both configs parse**

If the suite has a config-parse test pattern (grep
`test_ab_config_per_agent_ruff_haiku_low_parses` in `tests/lib/`), add mirrored
`trivy` versions. Otherwise verify by hand:
```
yq -r '.session.model' tests/ab/configs/per-agent/trivy-haiku-low.yaml
```
Expected: `haiku`. And:
```
yq -r '.session.effort' tests/ab/configs/per-agent/trivy-haiku-low.yaml
```
Expected: `low`.

- [ ] **Step 4: Run the suite + commit + push**

Run: `bash tests/run.sh` (expect green bar the dirty-tree artifact).
```bash
git add tests/ab/configs/per-agent/trivy-baseline.yaml tests/ab/configs/per-agent/trivy-haiku-low.yaml
git commit -m "test(ab): add trivy baseline + haiku-low per-agent configs"
git push origin main
```

---

### Task 4: Live worked-example capture (GATED — Bedrock spend, ~1-3 trials)

**STOP. This task spends real Bedrock. Get explicit operator go-ahead before
running anything in it.** The capture-then-pin discipline (per
[[worked-example-gap]]): trivy-reviewer.md has NO worked example, so the first
capture WILL parse to zero tuples until we see the real §7 layout and pin it.

**Files:**
- Modify: `plugins/code-review-suite/agents/trivy-reviewer.md` (Task 5)
- Create: `tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings-trivy.md`
- Create: `tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings.json`

- [ ] **Step 1: Capture ONE Sonnet/default trial**

Run:
```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/trivy-baseline.yaml --corpus trivy-smoke-bad-dockerfile --trials 1 --stream-json
```
(NO `--mode` flag — mode is config-derived. Per [[phase-3-2b-pr-a-apparatus-fix]].)

- [ ] **Step 2: Inspect the captured stdout.log for the REAL §7 layout**

Read the run's trial-001 `stdout.log` under `tests/ab/runs/<ts>-trivy-baseline/`.
Note EXACTLY how the agent laid out the findings block: the heading text, the
`### Finding` shape, whether it emitted `DS-0001` or normalised to `AVD-DS-0001`,
the Rule field format, severity tokens. Check `findings.json` — if it parsed to
`[]` despite a visible report, that's the zero-tuple gap; the worked example
(Task 5) fixes it.

- [ ] **Step 3: Promote the captured report as the expected baseline**

Copy the captured findings block into
`tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings-trivy.md` and the
parsed tuples into `expected/findings.json`. Fill `suite_sha` in `source.yaml`
with the current HEAD sha (replace `PLACEHOLDER_FILL_AT_CAPTURE`).

---

### Task 5: Pin the worked example (offline, depends on Task 4 capture)

**Files:**
- Modify: `plugins/code-review-suite/agents/trivy-reviewer.md`

- [ ] **Step 1: Add a `### Worked example` section**

After the `## Output` section (~line 79), add a worked example modelled on
eslint-reviewer.md lines 90-130, using the ACTUAL captured layout from Task 4
(the three DS-NNNN findings). Do NOT invent — match what the agent emitted.

- [ ] **Step 2: If the `AVD-` claim is stale, correct it**

If Task 4 showed the agent emits `DS-NNNN` (not `AVD-XX-NNNN`), update line 73's
`The Rule: field shows AVD-XX-NNNN (provider) or the policy ID` to reflect the
real `DS-NNNN (provider)` form trivy 0.71 produces. This is a general correctness
fix to the agent body (helps any model), not a fixture-chase.

- [ ] **Step 3: Re-capture ONE trial to confirm the worked example fixes the parse (GATED)**

Get operator go-ahead. Re-run the Step-1 capture command. Confirm `findings.json`
now parses to the three expected tuples (the worked example closed the gap).

- [ ] **Step 4: Commit + push**

```bash
git add plugins/code-review-suite/agents/trivy-reviewer.md tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings-trivy.md tests/ab/corpus/trivy-smoke-bad-dockerfile/expected/findings.json tests/ab/corpus/trivy-smoke-bad-dockerfile/source.yaml
git commit -m "feat(trivy-reviewer): pin live-captured worked example; correct stale AVD- rule-ID claim"
git push origin main
```

---

### Task 6: The matched 2×20 probe (GATED — ~$4 list / ~25 min, the main Bedrock spend)

**STOP. Get explicit operator go-ahead.** Run BOTH arms at n=20 (the full matched
pair, NOT a Haiku-only shortcut — trivy has no prior data).

- [ ] **Step 1: Sonnet/default baseline arm, n=20**

```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/trivy-baseline.yaml --corpus trivy-smoke-bad-dockerfile --trials 20 --stream-json
```

- [ ] **Step 2: Haiku/low arm, n=20**

```
bash tests/ab/run.sh --config tests/ab/configs/per-agent/trivy-haiku-low.yaml --corpus trivy-smoke-bad-dockerfile --trials 20 --stream-json
```

- [ ] **Step 3: Tabulate canonical-hash rate per arm + cost ratio**

For each run's `summary.csv`: count trials whose `findings_hash` equals the modal
(canonical) hash; tally any INCONCLUSIVE/skip markers; compute mean
`total_cost_usd` per arm and the Sonnet/Haiku RATIO (report ratio only — the
stream cost is Anthropic LIST price, not Bedrock, per [[phase-3-2b-pr-b-reprobe]]).

---

### Task 7: Verdict + result note + memory (offline)

**Files:**
- Create: `docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md`

- [ ] **Step 1: Apply the verdict framework**

Per `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md`:
EQUIVALENT (Haiku matches canonical within noise) / INCONCLUSIVE (decision-4,
mixed within-arm hashes) / WORSE (>25% NORMAL-rate drop). If a real agent-side
tail survives the clean apparatus (as eslint's tier-1 tail did), CHARACTERISE it
— do NOT pre-author a fix (the tuning-to-the-test guard: a fix must be a general
correctness improvement earning its own before/after at n=20).

- [ ] **Step 2: Write the result note**

Mirror `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md`:
per-arm canonical rate, verdict, cost ratio, any agent-side tail, whether to flip
production `model: trivy-reviewer` (only on a clean EQUIVALENT — and remember the
flip needs BOTH `model: haiku` AND `effort: low` per Piece 1's resolution).

- [ ] **Step 3: Update memory**

Add/update a `project_phase_3_3_trivy_shipped.md` memory in the `~/.claude` repo
memory dir (NOT this clone): verdict, cost ratio, commits, whether production
flipped. Add the MEMORY.md index line. Commit + push the `~/.claude` repo.

- [ ] **Step 4: Commit + push the result note**

```bash
git add docs/superpowers/notes/2026-06-03-trivy-haiku-low-result.md
git commit -m "docs(ab): Phase 3.3 trivy Haiku/low A/B result + verdict"
git push origin main
```

---

## Self-review notes

- **Spec coverage:** handover Piece 2 sections 2a (fixture+provisioning — no
  setup needed, Task 1), 2b (parser case, Task 2), 2c (live worked example, Tasks
  4-5), 2d (configs, Task 3), 2e (gated probe, Tasks 6-7) — all mapped.
- **jbinspect is a SEPARATE plan** (Phase 3.4) — heavier .NET provisioning, do
  trivy end-to-end first as the worked example. Not in this plan.
- **Gating:** Tasks 1-3 are fully offline (commit freely). Tasks 4, 5-step-3, and
  6 are Bedrock spends — each STOPs for operator go-ahead.
- **The `--mode` flag does NOT exist** — mode is config-derived. Every run command
  above omits it deliberately.
