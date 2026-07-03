# Phase 3.2 — eslint-reviewer Haiku/low probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalise the harness's hardcoded ruff parser into a name-dispatched core, then probe `eslint-reviewer` at Haiku/low (n=20) against a freshly-captured Sonnet/default baseline and decide whether it is equivalent on finding sets.

**Architecture:** A pure-extraction refactor turns `agent_capture_parse_ruff_trial` into a parameterised `agent_capture_parse_trial <agent>` driven by a dispatch table (heading, rule-ID tokeniser, sentinels). The ruff path stays byte-identical (guarded by existing tests). A richer eslint fixture (3–5 findings, ground-truthed by `eslint --format=json`) gets a captured Sonnet baseline, then one operator-gated 20-trial Haiku/low Bedrock sweep produces artefacts that an offline `$CLAUDE_TEMP_DIR` classifier scores NORMAL/DRIFT/EMPTY/OTHER with Wilson 95 % CIs. A one-page report records the verdict. No production config changes.

**Tech Stack:** Bash harness (`tests/ab/run.sh`, `tests/ab/lib/agent_capture.sh`), `awk`/`jq`/`sort`, `python3` (stdlib) for the classifier, `npx eslint` for fixture ground truth, Claude Code CLI on Bedrock.

---

## Critical operational constraints (read before any task)

- **Push after every commit.** This clone is an autoUpdate-managed marketplace clone; a prior reclone wiped an unpushed branch (2026-06-02). The branch `feat/phase-3-2-eslint-haiku-low` already exists and is pushed (head `4056f0e`, carrying the committed spec). Re-push immediately after every commit.
- **Bash hook rules.** No compound commands (`&&`, `||`, `;`), no `$(...)`/backticks (except the commit/PR HEREDOC carve-out), no loops/subshells in a single Bash call. Any multi-step shell recipe goes in a script file run with one `bash <path>` call. Temp files under `$CLAUDE_TEMP_DIR` — note this is NOT exported into the Bash tool's shell; use the literal path `/tmp/claude-<session-id>/` (the SessionStart hook prints the session id; resolve it once and reuse the literal path).
- **No `*-reviewer.md` edits.** Model/effort variation flows from the config YAML only. This probe informs a later adoption decision; it does not flip production config.
- **Classifier is a per-run overlay, NOT committed to the harness** (matches the 3.1b/3.1c precedent). It lives in `$CLAUDE_TEMP_DIR`. Do not `git add` it.
- **Parser grounding is structural, not optional.** Tasks are ordered so the live Sonnet trace is captured (Task 4) BEFORE the eslint parser tests are written (Task 5). Author the parser parameters and tests from the captured `stdout.log` on disk, never from this plan. Task 5 Step 1 forces you to quote the real heading + a finding block from the captured file. See the spec's "Guarding against parser guessing".

## Key constants

- **eslint-reviewer canonical output contract** (from `plugins/code-review-suite/agents/eslint-reviewer.md`):
  - Block heading: `## ESLint Findings`
  - Zero-state line: `0 findings — no JS/TS files in diff.`
  - Skip sentinel: `Skipped — eslint/biome not available on PATH or in node_modules.`
  - `Rule:` field shape: `rule-id (plugin)` e.g. `no-unused-vars (eslint)`. Kebab-case IDs contain no spaces, so the EXISTING ruff tokeniser (split on `[ \t(]`, take token 1) extracts them unchanged — eslint needs the identity/default tokeniser, no bespoke function.
  - Every finding emits `Confidence: 100`; severity is `Important` (ESLint `error`) or `Suggestion` (ESLint `warn`).
- **Probe configs (to create):** `tests/ab/configs/per-agent/eslint-baseline.yaml` (`model: sonnet`, `effort: default`), `tests/ab/configs/per-agent/eslint-haiku-low.yaml` (`model: haiku`, `effort: low`).
- **Fixture (to create):** `tests/ab/corpus/eslint-smoke-bad-js/` with `source.yaml`, `expected/findings-eslint.md`, `expected/findings.json`, `diff/changed-lines.txt`.
- **Source fixture (to extend):** `tests/fixtures/static-analysis/eslint/bad.js` + `eslint.config.js` (currently 1 rule, `no-unused-vars`).
- **Trial count:** n=20 Haiku/low; Sonnet baseline = 1 capture + ≥3 determinism trials.
- **Test discovery is automatic:** `tests/run.sh:14` collects every `test_*` function via `declare -F`. New tests in `tests/lib/test_ab_per_agent_lib.sh` need no registration.

## File structure

- **Modify (committed):** `tests/ab/lib/agent_capture.sh` — extract `agent_capture_parse_trial`; ruff becomes a shim.
- **Modify (committed):** `tests/ab/run.sh` — dispatch by `$_AB_CONFIG_AGENT`; generalise `findings-<agent>.md`.
- **Modify (committed):** `tests/lib/test_ab_per_agent_lib.sh` — add eslint-shape parser tests.
- **Create (committed):** `tests/ab/fixtures/eslint-stdout-*.log` — eslint parser test fixtures (authored from the live trace).
- **Modify (committed):** `tests/fixtures/static-analysis/eslint/bad.js`, `eslint.config.js` — grow to 3–5 findings.
- **Create (committed):** `tests/ab/corpus/eslint-smoke-bad-js/**` — the A/B corpus fixture + captured baseline.
- **Create (committed):** `tests/ab/configs/per-agent/eslint-baseline.yaml`, `eslint-haiku-low.yaml`.
- **Create (committed):** `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md` — the one-page report.
- **Create (temp, NOT committed):** `$CLAUDE_TEMP_DIR/classify_trials.py` — classification + Wilson-CI overlay.

---

### Task 1: Pre-flight (offline, no Bedrock spend)

**Files:** none modified (verification only).

- [ ] **Step 1: Confirm the branch head and that it is pushed**

Run: `git log --oneline -1`
Expected: `4056f0e docs(ab): Phase 3.2 design — eslint Haiku/low probe + parser-dispatch refactor` (or later if more commits exist).
Run: `git ls-remote origin feat/phase-3-2-eslint-haiku-low`
Expected: the SHA matches local HEAD. If local is ahead, run `git push`.

- [ ] **Step 2: Confirm eslint tooling is reachable**

Run: `npx --yes eslint --version`
Expected: a version string (≥ v9). If it fails, stop — the fixture ground truth cannot be captured.

- [ ] **Step 3: Confirm the existing A/B parser tests pass (refactor baseline)**

Run: `tests/run.sh`
Expected: all pass (the run currently reports `330 passed, 1 skipped`). Record the count; Task 3 must not regress it.

No commit (verification only).

---

### Task 2: Refactor — extract `agent_capture_parse_trial`, keep ruff byte-identical

This is a pure extraction. The ruff path must produce identical output; the existing `ab agent capture *` tests are the regression guard.

**Files:**
- Modify: `tests/ab/lib/agent_capture.sh`
- Modify: `tests/ab/run.sh`

- [ ] **Step 1: Run the ruff parser tests in isolation to capture the green baseline**

Run: `tests/run.sh 2>&1 | grep -E "agent_capture|agent capture"`
Expected: every `A/B agent_capture:` line shows `✓`. These are the lines that must stay green after the extraction.

- [ ] **Step 2: Add the dispatch table + parameterised entry point to `agent_capture.sh`**

In `tests/ab/lib/agent_capture.sh`, immediately ABOVE the current `agent_capture_parse_ruff_trial() {` definition (line 17), add the dispatch table and the new public entry point. The body of the new function is the EXISTING ruff function body verbatim, with three substitutions: the heading regex, the skip sentinel regex, and the zero-state regex become variables read from the dispatch table; the rule-ID tokeniser stays as-is (eslint and ruff share it).

```bash
# Per-agent parser parameters. Each agent supplies the three things that
# differ across static specialists; the §7 state-machine body is shared.
#   heading       : the findings block heading, anchored (^...$)
#   skip_sentinel : ERE matching the tool-fully-skipped line
#   zero_state    : ERE matching the canonical zero-state line
# The rule-ID tokeniser (split on [ \t(], take token 1) is shared by ruff and
# eslint — kebab-case IDs have no internal spaces — so it is not parameterised.
_agent_capture_params() {
    local agent="$1"
    case "$agent" in
        ruff)
            _AC_HEADING='^## Ruff Findings$'
            _AC_SKIP='^Skipped — '
            _AC_ZERO='^0 findings — no Python files in diff\.'
            ;;
        eslint)
            _AC_HEADING='^## ESLint Findings$'
            _AC_SKIP='^Skipped — eslint/biome not available'
            _AC_ZERO='^0 findings — no JS/TS files in diff\.'
            ;;
        *)
            echo "_agent_capture_params: unknown agent: $agent" >&2
            return 1
            ;;
    esac
}

# Public entry point: parse one trial for <agent>. Looks up the agent's
# parameters, then runs the shared §7 state-machine. See agent_capture_parse_
# ruff_trial (now a shim) for the historical name.
agent_capture_parse_trial() {
    local agent="$1"
    local trial_dir="$2"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "agent_capture_parse_trial: $stdout: not found" >&2
        return 1
    fi
    _agent_capture_params "$agent" || return 1

    # 1. Tool-fully-skipped state.
    if grep -qE "$_AC_SKIP" "$stdout"; then
        : > "$trial_dir/INCONCLUSIVE"
        : > "$trial_dir/agent-output.md"
        echo '[]' > "$trial_dir/findings.json"
        printf '%s\n' "skipped" > "$trial_dir/findings_hash.txt"
        return 0
    fi

    # 2. Extract the findings block: from the heading through the last entry,
    # terminating before any subsequent same-level heading.
    awk -v heading="$_AC_HEADING" '
        BEGIN { in_block = 0 }
        $0 ~ heading { in_block = 1; print; next }
        in_block && /^## / { in_block = 0 }
        in_block { print }
    ' "$stdout" > "$trial_dir/agent-output.md"

    # 3. Canonical zero-state.
    if grep -qE "$_AC_ZERO" "$trial_dir/agent-output.md"; then
        echo '[]' > "$trial_dir/findings.json"
        _agent_capture_compute_hash "$trial_dir/findings.json" "$trial_dir/findings_hash.txt"
        return 0
    fi

    # 4. Parse per-finding §7 bullet blocks. (Body identical to the historical
    # ruff parser — the awk program below is copied verbatim from the pre-
    # refactor agent_capture_parse_ruff_trial step 4.)
    awk '
        function strip_backticks(s,    n) {
            sub(/^`+/, "", s)
            sub(/`+$/, "", s)
            return s
        }
        function emit_if_complete(    eff_line, n, dummy) {
            eff_line = line
            if (eff_line == "" && file != "") {
                n = split(file, parts, ":")
                if (n >= 2) {
                    eff_line = parts[n]
                    file_clean = parts[1]
                    for (i = 2; i <= n - 1; i++) file_clean = file_clean ":" parts[i]
                    file = file_clean
                }
            }
            if (in_finding_block && file != "" && eff_line != "" && rule_id != "" && severity != "" && confidence != "") {
                print file, eff_line, rule_id, severity, confidence
            }
            file = ""; line = ""; rule_id = ""; severity = ""; confidence = ""
        }
        BEGIN { OFS = "\t"; in_finding_block = 0; file = ""; line = ""; rule_id = ""; severity = ""; confidence = "" }
        /^### Finding/ { emit_if_complete(); in_finding_block = 1; next }
        /^- \*\*File:\*\* / {
            if (file != "") emit_if_complete()
            v = substr($0, length("- **File:** ") + 1)
            file = strip_backticks(v)
            next
        }
        /^- \*\*Line:\*\* / {
            v = substr($0, length("- **Line:** ") + 1)
            line = strip_backticks(v)
            next
        }
        /^- \*\*Rule:\*\* / {
            v = substr($0, length("- **Rule:** ") + 1)
            v = strip_backticks(v)
            split(v, a, /[ \t(]/)
            rule_id = strip_backticks(a[1])
            next
        }
        /^- \*\*Severity:\*\* / {
            v = substr($0, length("- **Severity:** ") + 1)
            severity = strip_backticks(v)
            next
        }
        /^- \*\*Confidence:\*\* / {
            v = substr($0, length("- **Confidence:** ") + 1)
            confidence = strip_backticks(v)
            next
        }
        END { emit_if_complete() }
    ' "$trial_dir/agent-output.md" > "$trial_dir/.findings.tsv"

    # 5. Sort deterministically (file, line, rule_id) and emit JSON.
    sort -t $'\t' -k1,1 -k2,2n -k3,3 "$trial_dir/.findings.tsv" \
        | jq -R -s -c '
            split("\n")
            | map(select(length > 0) | split("\t") | {
                file: .[0],
                line: (.[1] | tonumber),
                rule_id: .[2],
                severity: .[3],
                confidence: (.[4] | tonumber)
              })
          ' > "$trial_dir/findings.json"

    rm -f "$trial_dir/.findings.tsv"

    _agent_capture_compute_hash "$trial_dir/findings.json" "$trial_dir/findings_hash.txt"
}
```

NOTE: the new step-2 block-extraction uses `in_block && /^## /` (any subsequent H2) rather than the old `/^## / && !/^## Ruff Findings$/`. This is equivalent for the ruff path (the heading line is consumed by the first rule and `next`-ed, so it never reaches the terminator check) and avoids hardcoding the heading twice. Confirm equivalence via the regression tests in Step 4.

- [ ] **Step 3: Replace the old ruff function body with a thin shim**

In `tests/ab/lib/agent_capture.sh`, replace the ENTIRE existing `agent_capture_parse_ruff_trial() { ... }` definition (the old lines 17–170, ending at the close brace before `_agent_capture_compute_hash`) with:

```bash
# Backward-compatible shim. Existing callers and tests reference this name;
# it now delegates to the parameterised entry point.
agent_capture_parse_ruff_trial() {
    agent_capture_parse_trial ruff "$1"
}
```

Leave `_agent_capture_compute_hash` and `agent_capture_compare_findings` untouched.

- [ ] **Step 4: Run the full suite — ruff path must be byte-identical**

Run: `tests/run.sh`
Expected: same pass/skip count as Task 1 Step 3 (`330 passed, 1 skipped`). Every `A/B agent_capture:` line still `✓`. If ANY ruff test now fails, the extraction changed behaviour — fix until green before committing. Do not proceed otherwise.

- [ ] **Step 5: Point `run.sh` at the dispatcher**

In `tests/ab/run.sh`, line 280, replace:
```bash
        agent_capture_parse_ruff_trial "$trial_dir"
```
with:
```bash
        agent_capture_parse_trial "$_AB_CONFIG_AGENT" "$trial_dir"
```

In the faithfulness-check baseline-synth block (around lines 295–305), generalise the hardcoded markdown filename. Replace:
```bash
            local md="$_AB_FIXTURE_DIR/expected/findings-ruff.md"
```
with:
```bash
            local md="$_AB_FIXTURE_DIR/expected/findings-$_AB_CONFIG_AGENT.md"
```
and replace the synth-dir parse call:
```bash
            agent_capture_parse_ruff_trial "$synth_dir"
```
with:
```bash
            agent_capture_parse_trial "$_AB_CONFIG_AGENT" "$synth_dir"
```

- [ ] **Step 6: Re-run the suite to confirm run.sh still wires up**

Run: `tests/run.sh`
Expected: unchanged pass/skip count. (These tests exercise the parser lib directly; the run.sh dispatch line is covered later by the live sweep, but the suite must still be green.)

- [ ] **Step 7: Commit + push**

```bash
git add tests/ab/lib/agent_capture.sh tests/ab/run.sh
git commit -m "refactor(ab): dispatch agent_capture parser by agent name"
git push
```

---

### Task 3: Grow the eslint source fixture to 3–5 deterministic findings

Ground truth is `eslint`'s own JSON output. Author the file, enable the rules, then run eslint and read what it actually reports.

**Files:**
- Modify: `tests/fixtures/static-analysis/eslint/bad.js`
- Modify: `tests/fixtures/static-analysis/eslint/eslint.config.js`

- [ ] **Step 1: Expand the eslint flat config to enable the target rules**

Overwrite `tests/fixtures/static-analysis/eslint/eslint.config.js` with:

```javascript
module.exports = [
    {
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: "module",
        },
        rules: {
            "no-unused-vars": "error",
            "no-var": "error",
            "prefer-const": "error",
            "eqeqeq": "error",
        },
    },
];
```

- [ ] **Step 2: Author a JS file that triggers exactly those rules deterministically**

Overwrite `tests/fixtures/static-analysis/eslint/bad.js` with:

```javascript
var legacy = 1;
let neverReassigned = 2;
const unused = 42;

function check(a, b) {
    if (a == b) {
        return neverReassigned;
    }
    return legacy;
}

check(1, 2);
```

Rationale (verify against actual eslint output in Step 3, do NOT assume):
- `var legacy` → `no-var`
- `let neverReassigned` (never reassigned) → `prefer-const`
- `const unused` → `no-unused-vars`
- `a == b` → `eqeqeq`

- [ ] **Step 3: Run eslint to capture the ground-truth JSON**

Run (single command, no shell operators):
```bash
npx --yes eslint --no-config-lookup --config tests/fixtures/static-analysis/eslint/eslint.config.js --format json tests/fixtures/static-analysis/eslint/bad.js
```
Read the JSON. Record the exact `(line, ruleId, severity)` tuples eslint reports. This is the canonical truth for the fixture. If the set differs from the Step 2 rationale (e.g. a rule did not fire, or fired on a different line), ADJUST `bad.js` until the reported set is a clean 3–5 distinct rules, then re-run. Note: `prefer-const` and `no-unused-vars` can interact — if `unused` is also flagged by `prefer-const`, rename or restructure so each line maps to one intended rule. The goal is a deterministic, diverse, unambiguous finding set.

- [ ] **Step 4: Commit + push the source fixture**

```bash
git add tests/fixtures/static-analysis/eslint/bad.js tests/fixtures/static-analysis/eslint/eslint.config.js
git commit -m "test(ab): grow eslint smoke fixture to multi-rule finding set"
git push
```

---

### Task 4: Capture the Sonnet/default baseline (Bedrock spend, ~10k tokens)

Run one `eslint-reviewer` trial at sonnet/default, hand-verify against the eslint JSON, and promote the captured output to the corpus fixture. This trace is the source of truth for the parser in Task 5.

**Files:**
- Create: `tests/ab/configs/per-agent/eslint-baseline.yaml`
- Create: `tests/ab/corpus/eslint-smoke-bad-js/source.yaml`
- Create: `tests/ab/corpus/eslint-smoke-bad-js/diff/changed-lines.txt`
- Create: `tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md` (promoted from capture)

- [ ] **Step 1: Write the baseline config**

Create `tests/ab/configs/per-agent/eslint-baseline.yaml`:

```yaml
name: eslint-baseline
description: Production reference for eslint-reviewer — sonnet at default effort.
mode: per-agent
agent: eslint-reviewer
session:
  model: sonnet
  effort: default
```

- [ ] **Step 2: Scaffold the corpus fixture (source.yaml + diff)**

Create `tests/ab/corpus/eslint-smoke-bad-js/diff/changed-lines.txt`. Populate it with the lines eslint flagged in Task 3 Step 3 (one entry; format mirrors the ruff fixture):

```
Changed lines:
  bad.js: <comma-separated flagged line numbers from Task 3>
```

Create `tests/ab/corpus/eslint-smoke-bad-js/source.yaml` (mirror `ruff-smoke-bad-py/source.yaml`; fill `captured_under.suite_sha` with the current HEAD short SHA at capture time, and `captured_at` with the run date):

```yaml
id: eslint-smoke-bad-js
agent: eslint-reviewer
captured_at: 2026-06-02T00:00:00Z
baseline_revision: 1
captured_under:
  suite_sha: <HEAD-sha-at-capture>
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/eslint/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - Synthetic smoke fixture exercising eslint-reviewer against a single JS
    file with a multi-rule finding set (no-var, prefer-const, no-unused-vars,
    eqeqeq). Phase 3.2 baseline for the Haiku/low cost-tuning probe.
depends_on:
  - plugins/code-review-suite/agents/eslint-reviewer.md
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/eslint/bad.js
  - tests/fixtures/static-analysis/eslint/eslint.config.js
```

- [ ] **Step 3: Run a single Sonnet baseline trial**

Run (single command, no shell operators):
```bash
tests/ab/run.sh --config tests/ab/configs/per-agent/eslint-baseline.yaml --corpus eslint-smoke-bad-js --trials 1 --timeout-seconds 600 --stream-json --name eslint-baseline-capture
```
NOTE: this will fail at the faithfulness/parse step or produce no `expected/findings.json` yet — that is expected; we only need the trial's `stdout.log` and `agent-output.md`. Capture the run-dir path from the completion summary.

- [ ] **Step 4: Hand-verify the captured trial against the eslint JSON**

Read `tests/ab/runs/<ts>-eslint-baseline-capture/trial-001/stdout.log`. Confirm the agent's findings:
1. Conform to the §7 markdown shape (`## ESLint Findings`, `### Finding — …`, the five bullet fields).
2. Cover every `(file, line, ruleId)` eslint reported in Task 3 Step 3 (no missed findings).
3. Add no findings eslint did not surface (no fabrications).

If the Sonnet baseline misses or fabricates, the SPECIALIST has a defect — stop and surface it; do not paper over it in the fixture.

- [ ] **Step 5: Promote the captured findings block to the fixture**

Copy the `## ESLint Findings` block (heading through the last finding bullet) from `trial-001/agent-output.md` into `tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md`. This committed file IS the canonical trace the parser tests are written from.

- [ ] **Step 6: Commit + push**

```bash
git add tests/ab/configs/per-agent/eslint-baseline.yaml tests/ab/corpus/eslint-smoke-bad-js
git commit -m "test(ab): capture eslint-reviewer sonnet/default baseline fixture"
git push
```

(Run dirs under `tests/ab/runs/` are gitignored — only the config + corpus fixture are staged.)

---

### Task 5: eslint parser tests, authored FROM the captured trace

Now — and only now — write the offline parser tests, grounded on the real `agent-output.md` from Task 4. Do NOT write these from the plan's assumptions.

**Files:**
- Create: `tests/ab/fixtures/eslint-stdout-canonical.log`
- Create: `tests/ab/fixtures/eslint-stdout-zero-findings.log`
- Create: `tests/ab/fixtures/eslint-stdout-skipped.log`
- Modify: `tests/lib/test_ab_per_agent_lib.sh`

- [ ] **Step 1: Quote the real output (anti-guessing evidence gate)**

Run: `head -20 tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md`
In your task notes, quote: (a) the exact heading line, and (b) one complete finding block (the six lines from `### Finding` through `- **Suggested fix:**`). The parser fixtures below MUST be built from these real lines, not from this plan's examples. If the real heading is not exactly `## ESLint Findings`, update `_AC_HEADING` for eslint in `agent_capture.sh` Task 2 to match, re-run `tests/run.sh`, and note the correction.

- [ ] **Step 2: Create the canonical eslint stdout fixture**

Create `tests/ab/fixtures/eslint-stdout-canonical.log` by copying the verified `expected/findings-eslint.md` content verbatim (optionally prefixed with a line or two of agent prose before the heading, to exercise the block extractor). This guarantees the test fixture matches reality.

- [ ] **Step 3: Create the zero-state and skip fixtures**

Create `tests/ab/fixtures/eslint-stdout-zero-findings.log`:
```
## ESLint Findings

0 findings — no JS/TS files in diff.
```

Create `tests/ab/fixtures/eslint-stdout-skipped.log`:
```
Skipped — eslint/biome not available on PATH or in node_modules.
```

- [ ] **Step 4: Write the eslint parser tests**

Append to `tests/lib/test_ab_per_agent_lib.sh` (these are auto-discovered by `tests/run.sh:14`; no registration needed). Substitute `<N>`, the rule IDs, and the first tuple's `(file, line, rule_id)` with the ACTUAL values from the captured baseline (Task 4 / Step 1):

```bash
test_ab_agent_capture_eslint_canonical_parses() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-canonical.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "<N>" "$count" "A/B agent_capture eslint: canonical finding count"

    local first_rule
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    assert_equals "<first-rule-id>" "$first_rule" "A/B agent_capture eslint: first rule_id (kebab-case preserved)"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_eslint_zero_state() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-zero-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: zero-state fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture eslint: zero-state yields empty array"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_eslint_skipped_marks_inconclusive() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-skipped.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: skipped fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture eslint: skipped state writes INCONCLUSIVE marker"
    else
        fail "A/B agent_capture eslint: skipped state writes INCONCLUSIVE marker" \
            "expected $trial_dir/INCONCLUSIVE marker file"
    fi

    rm -rf "$trial_dir"
}
```

- [ ] **Step 5: Run the suite — new eslint tests must pass, ruff tests stay green**

Run: `tests/run.sh`
Expected: pass count = Task 1 baseline + 3 (the new eslint tests), 1 skipped. If the canonical test fails on count or rule_id, the parser params or the fixture are wrong — reconcile against the real `agent-output.md` (the fixture is truth), fix, re-run.

- [ ] **Step 6: Commit + push**

```bash
git add tests/ab/fixtures/eslint-stdout-canonical.log tests/ab/fixtures/eslint-stdout-zero-findings.log tests/ab/fixtures/eslint-stdout-skipped.log tests/lib/test_ab_per_agent_lib.sh
git commit -m "test(ab): eslint parser tests grounded on captured baseline"
git push
```

---

### Task 6: Generate the canonical baseline hash + Sonnet determinism check (Bedrock spend, ~30k tokens)

**Files:**
- Create: `tests/ab/corpus/eslint-smoke-bad-js/expected/findings.json` (generated by the harness from the promoted markdown)

- [ ] **Step 1: Run a 3-trial Sonnet faithfulness check**

Run (single command, no shell operators):
```bash
tests/ab/run.sh --config tests/ab/configs/per-agent/eslint-baseline.yaml --corpus eslint-smoke-bad-js --trials 3 --timeout-seconds 600 --stream-json --faithfulness-check --name eslint-sonnet-determinism
```
Expected: the harness synthesises `expected/findings.json` from `expected/findings-eslint.md` (run.sh lines ~295–305, now generalised), then compares all 3 trials. All 3 must match the baseline hash. If a trial diverges, the specialist is non-deterministic at sonnet — note and STOP (its own investigation, per parent spec Step 3).

- [ ] **Step 2: Record the canonical hash**

Run: `cat tests/ab/corpus/eslint-smoke-bad-js/expected/findings.json`
Run: `shasum -a 256 tests/ab/corpus/eslint-smoke-bad-js/expected/findings.json`
Record the hash — this is the eslint canonical hash for the classifier (Task 8).

- [ ] **Step 3: Commit + push the generated baseline JSON**

```bash
git add tests/ab/corpus/eslint-smoke-bad-js/expected/findings.json
git commit -m "test(ab): pin eslint canonical baseline findings hash"
git push
```

---

### Task 7: Operator gate, then the Haiku/low sweep (~50k tokens)

**Files:**
- Create: `tests/ab/configs/per-agent/eslint-haiku-low.yaml`

- [ ] **Step 1: Write the Haiku/low config**

Create `tests/ab/configs/per-agent/eslint-haiku-low.yaml`:

```yaml
name: eslint-haiku-low
description: Phase 3.2 directional probe — eslint-reviewer at Haiku/low. Compared against eslint-baseline (sonnet/default) on per-trial findings hash.
mode: per-agent
agent: eslint-reviewer
session:
  model: haiku
  effort: low
```

Commit + push:
```bash
git add tests/ab/configs/per-agent/eslint-haiku-low.yaml
git commit -m "test(ab): add eslint Haiku/low probe config"
git push
```

- [ ] **Step 2: Operator gate — surface the cost**

State to the operator: "About to spend ~50 k Bedrock tokens / ~9–10 min on the 20-trial eslint Haiku/low sweep. Proceed?" Wait for explicit go-ahead.

- [ ] **Step 3: Run the sweep**

Run (single command, no shell operators):
```bash
tests/ab/run.sh --config tests/ab/configs/per-agent/eslint-haiku-low.yaml --corpus eslint-smoke-bad-js --trials 20 --timeout-seconds 600 --stream-json --name eslint-haiku-low-probe
```
Expected: 20 trials, rc=0, a new gitignored dir `tests/ab/runs/<ts>-eslint-haiku-low-probe/`. Capture the run-dir path.

No commit (run dirs gitignored).

---

### Task 8: Classify the sweep + compute CIs

**Files:**
- Create (temp, NOT committed): `$CLAUDE_TEMP_DIR/classify_trials.py`

- [ ] **Step 1: Write the classifier with eslint's canonical hash**

Write the 3.1b classifier to `$CLAUDE_TEMP_DIR/classify_trials.py` (literal path `/tmp/claude-<session-id>/classify_trials.py`). Use the script verbatim from `docs/superpowers/plans/2026-06-02-phase-3-1b-ruff-haiku-low-reprobe.md` Task 2 Step 1, changing ONLY the `CANONICAL_HASH` constant to the eslint hash recorded in Task 6 Step 2.

- [ ] **Step 2: Verify the classifier against the Sonnet baseline run dir (offline oracle)**

Run: `python3 /tmp/claude-<session-id>/classify_trials.py tests/ab/runs/<ts>-eslint-sonnet-determinism`
Expected: 3/3 NORMAL (the determinism run from Task 6), zero DRIFT/EMPTY/OTHER, no validate-or-die fires. This confirms the eslint hash + classifier logic are correct before scoring the Haiku run. If the determinism run dir was pruned, re-run Task 6 Step 1.

- [ ] **Step 3: Classify the Haiku/low run dir**

Run: `python3 /tmp/claude-<session-id>/classify_trials.py tests/ab/runs/<ts>-eslint-haiku-low-probe`
Expected: a class breakdown over n=20 with Wilson CIs + wall-clock + any validate-or-die fires. `classification.csv` written into the (gitignored) run dir.

- [ ] **Step 4: Corroborate against the native summary.csv**

Run: `cat tests/ab/runs/<ts>-eslint-haiku-low-probe/summary.csv`
Cross-check: every NORMAL trial has the canonical findings_hash and exit_code 0; every EMPTY has non-zero exit_code and a `launch_assert_trial_recoverable` line in its `trial-NNN/stderr.log`.

- [ ] **Step 5: Operator gate — surface classification + verdict**

Present, before writing the report:
- Class breakdown + Wilson CIs (n=20).
- Verdict (`equivalent` | `better` | `worse` | `inconclusive`) vs the Sonnet baseline (3/3 NORMAL), applying the >25 % movement guard. Mixed within-arm hashes ⇒ inconclusive.
- On divergence: recall direction (Haiku misses findings vs fabricates) and cost delta (wall-clock vs Sonnet baseline mean).
- Any residual unrecoverable-EMPTY count, footnoted as the upstream CLI envelope bug (does not block the verdict; state the adjusted denominator if non-zero).

Wait for confirmation before Task 9.

No commit.

---

### Task 9: Write the one-page result report

**Files:**
- Create: `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md`

- [ ] **Step 1: Capture the sweep SHA**

Run: `git rev-parse --short HEAD`
Use it in the report's Sweep SHA field.

- [ ] **Step 2: Write the report**

Populate `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md` with the actual numbers (no placeholders), following the 3.1b report structure (`docs/superpowers/notes/2026-06-02-ruff-haiku-low-result.md`). Sections: header (date/status/spec/plan/baseline/run-dir/sweep-SHA), sweep configuration, baseline (the captured Sonnet 3/3 NORMAL + canonical hash), class breakdown table (n=20) with Wilson CIs, wall-clock, verdict (with >25 % guard reasoning and recall direction on any divergence; state explicitly that the probe does NOT flip `eslint-reviewer.md`), and residual-EMPTY footnote (or "zero" if none). Cross-reference the parent spec, the 3.2 spec, the 3.1b result, and the 3.1c validation.

- [ ] **Step 3: Commit + push**

```bash
git add docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md
git commit -m "docs(ab): Phase 3.2 result — eslint Haiku/low probe"
git push
```

---

### Task 10: Open the PR

**Files:** none.

- [ ] **Step 1: Final suite run**

Run: `tests/run.sh`
Expected: all pass (Task 1 baseline + 3 eslint tests). If anything fails, fix before opening the PR.

- [ ] **Step 2: Write the PR body to a temp file**

Write the PR body to `$CLAUDE_TEMP_DIR/pr-body.md` (literal `/tmp/claude-<session-id>/pr-body.md`). Begin with a 1–3 sentence non-technical contextual summary (where 3.2 sits in the Phase 3 static-specialist cost-tuning programme, that it lands the reusable parser-dispatch refactor, and the eslint verdict), then the technical detail: the parser refactor (ruff byte-identical), the fixture + baseline, the class breakdown + verdict, and that no production config changed. Link PR #40 (3.1b) and #39 (3.1c).

- [ ] **Step 3: Create the PR**

```bash
gh pr create --base main --head feat/phase-3-2-eslint-haiku-low --title "feat(ab): Phase 3.2 — eslint Haiku/low probe + parser-dispatch refactor" --body-file "$CLAUDE_TEMP_DIR/pr-body.md"
```
Return the PR URL to the operator.

---

## Self-review (completed by plan author)

- **Spec coverage:** parser-dispatch refactor (decision 2) → Task 2; richer fixture (decision 3) → Task 3; n=20 Haiku + fresh Sonnet baseline (decision 1) → Tasks 4/6/7; verdict framework (decision 4) → Task 8; guarding-against-parser-guessing (spec subsection) → task ordering (Task 4 before Task 5) + Task 5 Step 1 evidence gate; report + land (Steps 6–7) → Tasks 9/10. Repo-housekeeping: the change surface is shell + docs + a JS fixture; the eslint devDependency is pinned `^9.39.4` in the fixture's package.json — confirm current GA at fixture time (Task 3) but no separate housekeeping PR is warranted.
- **Placeholder scan:** the only bracketed fields are `<N>`, `<first-rule-id>`, `<HEAD-sha>`, `<ts>`, and `<session-id>` — all intentionally filled from live capture/run output, not plan placeholders. The refactor code and config YAMLs are complete and verbatim.
- **Type consistency:** the new entry point `agent_capture_parse_trial <agent> <trial_dir>` is used identically in `run.sh` (Task 2 Step 5), the shim (Task 2 Step 3), and all three eslint tests (Task 5 Step 4). The dispatch variables `_AC_HEADING`/`_AC_SKIP`/`_AC_ZERO` are set in `_agent_capture_params` and consumed in `agent_capture_parse_trial`. The tuple shape `{file, line, rule_id, severity, confidence}` is unchanged from the ruff parser. Test discovery via `declare -F` confirmed against `tests/run.sh:14`.
- **Empirical-grounding guard:** Task 4 (capture) strictly precedes Task 5 (parser tests); Task 5 Step 1 forces quoting the real heading + finding block before any eslint fixture is authored; the Bedrock sweep (Task 7) is downstream of the green offline suite (Task 5 Step 5). A guessed parser cannot reach the expensive step.
```
