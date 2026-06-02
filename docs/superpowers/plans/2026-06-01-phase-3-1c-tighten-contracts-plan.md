# Phase 3.1c — tighten contracts + fail-loud Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the apparatus-level noise floor on the per-agent stream-json substrate by landing harness fallback recovery + validate-or-die + parser retightening + canonical-baseline regeneration + a §7 example block in the ruff-reviewer prompt, then prove with a 20-trial Sonnet/default validation sweep that NORMAL ≥ 80 %, DRIFT < 10 %, EMPTY = 0, validate-or-die fires = 0.

**Architecture:** Two new private helpers in `tests/ab/lib/launch.sh` extracted from and added beside the existing inline jq site (`launch_jq_reduce_stream_jsonl` + `launch_assert_trial_recoverable`), wired into `launch_run_per_agent_trial`. The parser at `tests/ab/lib/agent_capture.sh` drops its drift retrofit and pins to canonical §7. The smoke-fixture baseline regenerates to canonical §7 form preserving the existing tuple hash. The ruff-reviewer agent file gains a worked §7 example block under `## Output`. Offline tests (Tests 1–3) live alongside the existing `test_ab_per_agent_lib.sh` cases; Test 4 is a manual baseline pre-flight gate; Test 5 is a 20-trial Bedrock sweep gate.

**Tech Stack:** Phase 2 per-agent harness (`tests/ab/run.sh --mode per-agent`, `lib/launch.sh launch_run_per_agent_trial`, `lib/agent_capture.sh`). Bash 4+, `jq`, `awk`, `shasum`. Bedrock via `command claude -p --output-format stream-json --verbose`. Sonnet/default arm via `tests/ab/configs/per-agent/ruff-baseline.yaml`.

**Spec:** [`docs/superpowers/specs/2026-06-01-phase-3-1c-tighten-contracts-design.md`](../specs/2026-06-01-phase-3-1c-tighten-contracts-design.md) (commit `179be0d`).

**Driving question:** Does landing the harness fallback + validate-or-die + parser retightening + agent-prompt example collapse 3.1a's residual EMPTY/DRIFT confounders to within the merge gate (NORMAL ≥ 80 %, DRIFT < 10 %, EMPTY = 0, validate-or-die fires = 0) on a 20-trial Sonnet/default sweep against `ruff-smoke-bad-py`?

**Cost expectation:** ~50 k Bedrock tokens for the 20-trial validation sweep. ~9 minutes wall-clock for the sweep itself; ~3–4 hours wall-clock total for implementation + review + sweep + PR.

---

## Pre-flight context

Read these before executing — they will not be in your fresh subagent's context:

1. **Spec:** `docs/superpowers/specs/2026-06-01-phase-3-1c-tighten-contracts-design.md` — architecture, units A–G, error-handling matrix, testing matrix.
2. **Phase 3.1a result report:** `docs/superpowers/notes/2026-05-29-empty-stdout-investigation-result.md` — load-bearing for the EMPTY-class fix surface, the 30 % incidence rate, and the trial-002/005/006/015/016/020 stream.jsonl excerpts that justify the fallback.
3. **Spec for the parent sweep (Phase 3):** `docs/superpowers/specs/2026-05-29-static-specialist-tuning-sweep.md` — context for why 3.1c unblocks 3.1b and how 3.2/3.3/3.4 inherit the contract pin.
4. **Static-analysis canonical contract:** `plugins/code-review-suite/includes/static-analysis-context.md` — §7 is the source of truth that 3.1c pins. Do NOT modify §7 in this PR.
5. **Auto-memory:** `project_phase_3_1a_empty_stdout_investigation`, `project_phase_3_1c_brainstorm_in_progress`, `feedback_models_overlook_tuning_hooks`, `feedback_claudemd_compliance`.

## Branching

The current handover branch (`feat/phase-3-1c-handover`) carries the brainstorm, spec, and handover commits (`afc2419`, `179be0d`, `857cdfe`). The spec requires the implementation PR on `feat/phase-3-1c-tighten-contracts`. Two equivalent options:

- **(Recommended) Rename in place.** From the existing `feat/phase-3-1c-handover` checkout: `git branch -m feat/phase-3-1c-handover feat/phase-3-1c-tighten-contracts`. The spec/handover commits ship with the implementation PR — that's correct; design docs belong with the work.
- **Fresh branch.** `git checkout main && git pull && git checkout -b feat/phase-3-1c-tighten-contracts`, then `git cherry-pick afc2419 179be0d 857cdfe` to bring the spec/handover/brainstorm commits forward.

Either way, push `feat/phase-3-1c-tighten-contracts` and open the PR against `main` from there.

## Housekeeping

The Phase 3.1 housekeeping audit (action SHA pins, runner pin, nuget bumps) was no-op on 2026-05-29 and remains so as of 2026-06-01. No housekeeping PR needed before 3.1c. If the audit re-fires during implementation, ship it as a separate small PR landing first — do NOT bundle it.

## File Structure

**New files:**

| Path | Responsibility |
|---|---|
| `tests/ab/fixtures/stream-jsonl/canonical-success.jsonl` | Fixture: terminal `result.subtype="success"` with non-empty `.result`. Drives Unit A's canonical-path test. |
| `tests/ab/fixtures/stream-jsonl/empty-result-three-text-blocks.jsonl` | Fixture: terminal envelope with `.result == ""` and three preceding `assistant.message.content[].text` blocks. Drives Unit A's fallback-recovery test. Modelled on 3.1a trial-005. |
| `tests/ab/fixtures/stream-jsonl/error-subtype.jsonl` | Fixture: terminal `result.subtype="error"`, `.result == ""`. Pins behaviour, not strictness. |
| `tests/ab/fixtures/stream-jsonl/no-terminal-event.jsonl` | Fixture: JSONL truncated before the terminal envelope. |
| `tests/ab/fixtures/ruff-stdout-canonical-finding.log` | Fixture: stdout.log matching the regenerated canonical baseline. Drives Test 3 positive case. |
| `tests/ab/fixtures/ruff-stdout-drifted-finding.log` | Fixture: stdout.log with `**Finding 1**` heading + `Message:`/`Detail:` (preserved from the prior baseline). Drives Test 3 negative case (zero findings post-tightening). |
| `tests/ab/fixtures/ruff-stdout-mixed-prose.log` | Fixture: canonical §7 with extra prose paragraphs interspersed. Drives Test 3 mixed case. |
| `tests/ab/fixtures/ruff-stdout-two-findings.log` | Fixture: two canonical `### Finding` blocks with different rule_ids. Drives Test 3 multi-finding case. |
| `docs/superpowers/notes/2026-XX-XX-phase-3-1c-validation-sweep.md` | Sweep result note: per-trial classification table, Wilson CIs, verdict. Date filled in at sweep time. |

**Modified files:**

| Path | Responsibility |
|---|---|
| `tests/ab/lib/launch.sh` | Add `launch_jq_reduce_stream_jsonl` (Unit A); add `launch_assert_trial_recoverable` (Unit B); rewire `launch_run_per_agent_trial` to call A then B (Unit C). |
| `tests/ab/lib/agent_capture.sh` | Drop the `**Finding [0-9]+**` heading match at line 111 (Unit D); update comment blocks at lines 64–65 and 146–147 to remove `**Finding N**` / `Message:` / `Detail:` references. |
| `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` | Regenerate to canonical §7 form (Unit E); preserve the canonical tuple hash `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`. |
| `tests/ab/corpus/ruff-smoke-bad-py/source.yaml` | Bump `captured_at`, update `captured_under.suite_sha` to the validation-sweep SHA, add `baseline_revision: 2`. |
| `plugins/code-review-suite/agents/ruff-reviewer.md` | Append a worked §7 example block under `## Output` (Unit F). ~12 lines, F401 exemplar. |
| `tests/lib/test_ab_per_agent_lib.sh` | Add Test 1 cases (Unit A reduction) and Test 2 cases (Unit B predicate); extend the existing parser tests for Test 3 (canonical/drifted/mixed/multi-finding). |
| `tests/ab/runs/<timestamp>-ruff-baseline-validation/` | Validation-sweep run dir. Gitignored; not committed. |

**Out of scope for 3.1c (do not create or modify):**

- `plugins/code-review-suite/agents/ruff-reviewer.md` `model:` field — stays at `sonnet` until Phase 3.1b.
- `plugins/code-review-suite/includes/static-analysis-context.md` §7 text — pin makes §7 authoritative, does NOT edit it.
- `tests/ab/lib/launch.sh::launch_run_trial` (end-to-end variant) — no stream-json wiring there for 3.1c.
- Other static specialists' parsers (eslint/trivy/jbinspect) — 3.2/3.3/3.4 work.
- Upstream Claude Code bug filing — tracked as a side artefact, not a PR gate.

---

## Important context for implementers

Five details that are easy to miss:

1. **The fallback is stream-json-conditional.** Without `stream.jsonl` there is nothing to recover from. Behaviour on the non-stream-json codepath (`stream_json="false"` parameter to `launch_run_per_agent_trial`) is unchanged at the capture layer. The validate-or-die assertion still fires for non-stream-json trials but its predicate naturally only triggers if the CLI produced empty stdout *without* stream-json — a case never observed in production, but the assertion makes the silent-success failure surface impossible there too.

2. **The parser already accepts canonical §7.** Unit D is a *subtractive* change — drop the `**Finding [0-9]+**` line at `agent_capture.sh:111` and update two comment blocks. No new awk logic. The state machine, the field bullets, the path-with-line tolerance, the backtick stripping, the sort/jq/hash pipeline all stay.

3. **The canonical hash is load-bearing.** `tests/ab/corpus/ruff-smoke-bad-py/expected/findings.json` produces the hash `7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3`. The regenerated `findings-ruff.md` must parse to the same five-field tuple `{file: "bad.py", line: 1, rule_id: "F401", severity: "Important", confidence: 100}` so the existing faithfulness check at `run.sh:290–320` continues to compare equal. Test 4 (manual pre-flight) gates this.

4. **3.1a's recovered text-block fixture is real data, not synthesised.** Trial-002's stream.jsonl in `tests/ab/runs/20260529T155034Z-ruff-haiku-low/` contains a `result.subtype="success"` event with `.result == ""` and a preceding text block that says `## Ruff Findings\n\n**1 finding** ...`. Use this trace — and the trial-005 / -006 / -015 / -016 / -020 traces — to construct the `empty-result-three-text-blocks.jsonl` fixture.

5. **The dirty-tree assertion in `tests/lib/test_ab_harness.sh:550` will fire mid-iteration during TDD.** Per `feedback_claudemd_compliance` and the Phase 2 plan-defect note: this is not a real failure; it triggers during dirty-tree windows mid-iteration and clears at clean HEAD. If you see it fail mid-task, commit your work-in-progress first, then re-run.

---

## Task 1: Construct fixture stream.jsonl files for Unit A

Build the four fixture files Test 1 (Unit A reduction) consumes. No code changes. ~0 Bedrock tokens.

**Files:**
- Create: `tests/ab/fixtures/stream-jsonl/canonical-success.jsonl`
- Create: `tests/ab/fixtures/stream-jsonl/empty-result-three-text-blocks.jsonl`
- Create: `tests/ab/fixtures/stream-jsonl/error-subtype.jsonl`
- Create: `tests/ab/fixtures/stream-jsonl/no-terminal-event.jsonl`

- [ ] **Step 1: Create the fixture directory**

```bash
mkdir -p tests/ab/fixtures/stream-jsonl
```

- [ ] **Step 2: Author `canonical-success.jsonl`**

One line, terminal `result` envelope with non-empty `.result`. Schema mirrors the real Claude Code SDK envelope but trimmed to the fields the parser inspects:

```bash
cat > tests/ab/fixtures/stream-jsonl/canonical-success.jsonl <<'EOF'
{"type":"system","subtype":"init","session_id":"fixture-canonical"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## Ruff Findings\n\n### Finding — `sys` imported but unused\n- **File:** bad.py:1\n- **Confidence:** 100\n- **Severity:** Important\n- **Rule:** F401 (Pyflakes)\n- **Description:** `sys` imported but unused\n- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely."}]}}
{"type":"result","subtype":"success","is_error":false,"result":"## Ruff Findings\n\n### Finding — `sys` imported but unused\n- **File:** bad.py:1\n- **Confidence:** 100\n- **Severity:** Important\n- **Rule:** F401 (Pyflakes)\n- **Description:** `sys` imported but unused\n- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely.","stop_reason":"end_turn","session_id":"fixture-canonical"}
EOF
```

- [ ] **Step 3: Author `empty-result-three-text-blocks.jsonl`**

Three preceding assistant text blocks; terminal envelope with `.result == ""`. Modelled on 3.1a trial-005:

```bash
cat > tests/ab/fixtures/stream-jsonl/empty-result-three-text-blocks.jsonl <<'EOF'
{"type":"system","subtype":"init","session_id":"fixture-empty-result"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll run Ruff on the changed Python file."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running ruff against bad.py and parsing the JSON output."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## Ruff Findings\n\n### Finding — `sys` imported but unused\n- **File:** bad.py:1\n- **Confidence:** 100\n- **Severity:** Important\n- **Rule:** F401 (Pyflakes)\n- **Description:** `sys` imported but unused\n- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely."}]}}
{"type":"result","subtype":"success","is_error":false,"result":"","stop_reason":"end_turn","session_id":"fixture-empty-result"}
EOF
```

- [ ] **Step 4: Author `error-subtype.jsonl`**

Terminal envelope with `subtype="error"`, `.result == ""`, no preceding text blocks:

```bash
cat > tests/ab/fixtures/stream-jsonl/error-subtype.jsonl <<'EOF'
{"type":"system","subtype":"init","session_id":"fixture-error"}
{"type":"result","subtype":"error","is_error":true,"result":"","stop_reason":"error","session_id":"fixture-error"}
EOF
```

- [ ] **Step 5: Author `no-terminal-event.jsonl`**

JSONL truncated before the terminal envelope. No assistant text either:

```bash
cat > tests/ab/fixtures/stream-jsonl/no-terminal-event.jsonl <<'EOF'
{"type":"system","subtype":"init","session_id":"fixture-truncated"}
EOF
```

- [ ] **Step 6: Sanity-check each fixture is valid JSONL**

Run:

```bash
for f in tests/ab/fixtures/stream-jsonl/*.jsonl; do
    echo "=== $f ==="
    jq -c 'type' "$f" | head -5
done
```

Expected: each fixture's lines all parse as `"object"`. Any `parse error` from `jq` means the fixture is malformed; fix before continuing.

- [ ] **Step 7: Commit**

```bash
git add tests/ab/fixtures/stream-jsonl/
git commit -m "test(ab): add fixture stream.jsonl files for Phase 3.1c Unit A"
```

---

## Task 2: TDD — `launch_jq_reduce_stream_jsonl` (Unit A)

Author the helper that reduces a `stream.jsonl` to canonical text, with fallback to concatenated `assistant.message.content[].text` blocks when `.result == ""`.

**Files:**
- Modify: `tests/lib/test_ab_per_agent_lib.sh` (add four test cases)
- Modify: `tests/ab/lib/launch.sh` (add `launch_jq_reduce_stream_jsonl` helper)

- [ ] **Step 1: Write the failing tests**

Append to `tests/lib/test_ab_per_agent_lib.sh`:

```bash
test_ab_launch_jq_reduce_canonical_success() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/canonical-success.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: lib + fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    if grep -qF "### Finding — \`sys\` imported but unused" "$out" \
        && grep -qF "- **File:** bad.py:1" "$out"; then
        pass "A/B launch_jq_reduce: canonical success → .result verbatim"
    else
        fail "A/B launch_jq_reduce: canonical success → .result verbatim" "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_empty_result_falls_back_to_text_blocks() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/empty-result-three-text-blocks.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: empty-result fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    # Fallback recovers the canonical text from the third text block.
    if grep -qF "## Ruff Findings" "$out" \
        && grep -qF "### Finding — \`sys\` imported but unused" "$out" \
        && grep -qF "I'll run Ruff on the changed Python file." "$out"; then
        pass "A/B launch_jq_reduce: empty .result → fallback concatenates text blocks"
    else
        fail "A/B launch_jq_reduce: empty .result → fallback concatenates text blocks" \
            "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_error_subtype_yields_empty() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/error-subtype.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: error fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    if [[ ! -s "$out" ]]; then
        pass "A/B launch_jq_reduce: error subtype + no text blocks → empty stdout"
    else
        fail "A/B launch_jq_reduce: error subtype + no text blocks → empty stdout" \
            "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_no_terminal_event_yields_empty() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/no-terminal-event.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: no-terminal fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    if [[ ! -s "$out" ]]; then
        pass "A/B launch_jq_reduce: no terminal event + no text blocks → empty stdout"
    else
        fail "A/B launch_jq_reduce: no terminal event + no text blocks → empty stdout" \
            "$(cat "$out")"
    fi
    rm -f "$out"
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh 2>&1 | grep -E 'launch_jq_reduce|tests:'
```

Expected: four `✗` failures with messages like `launch_jq_reduce_stream_jsonl: command not found`. All other tests still pass.

- [ ] **Step 3: Add the helper to `tests/ab/lib/launch.sh`**

Insert this function above the `launch_run_per_agent_trial` definition (between the existing `launch_build_per_agent_argv` and `launch_run_per_agent_trial`):

```bash
# Reduce a stream-json JSONL trace to a single canonical-text string and write
# it to the given target path. Tries the canonical path first: the .result
# field of the terminal {type:"result", subtype:"success"} event. If that's
# missing or empty (Phase 3.1a Category C envelope-finalisation gap), falls
# back to concatenating .text blocks from preceding {type:"assistant"} events
# in stream order, joined by '\n'.
#
# The fallback is recovery, not substitution: 3.1a confirmed by inspection
# (trials 002/005/006/015/016/020) that the canonical text lives in those
# blocks when the envelope's .result is empty.
#
# Returns 0 on any successful reduction (including empty output when neither
# path produces text); non-zero only on jq invocation failure.
launch_jq_reduce_stream_jsonl() {
    local stream_jsonl="$1"
    local stdout="$2"

    if [[ ! -s "$stream_jsonl" ]]; then
        : > "$stdout"
        return 0
    fi

    # Canonical path: terminal result.subtype="success" with non-empty .result.
    local canonical
    canonical=$(jq -r '
        select(.type == "result" and .subtype == "success") | .result // ""
    ' "$stream_jsonl")

    if [[ -n "$canonical" ]]; then
        printf '%s' "$canonical" > "$stdout"
        return 0
    fi

    # Fallback: concatenate text blocks from assistant events in stream order,
    # joined by a single \n.
    jq -r '
        select(.type == "assistant") | .message.content[]?
        | select(.type == "text") | .text
    ' "$stream_jsonl" | awk 'NR>1 {printf "\n"} {printf "%s", $0}' > "$stdout"
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh 2>&1 | grep -E 'launch_jq_reduce|tests:'
```

Expected: four `✓` passes for the new tests; total fail count from the runner is unchanged from before Step 1 (i.e. no regression in any other test).

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/launch.sh tests/lib/test_ab_per_agent_lib.sh
git commit -m "feat(ab/launch): add launch_jq_reduce_stream_jsonl with text-block fallback (Phase 3.1c Unit A)"
```

---

## Task 3: TDD — `launch_assert_trial_recoverable` (Unit B)

Author the validate-or-die predicate that returns non-zero with a structured-stderr JSON line when a trial is unrecoverable.

**Files:**
- Modify: `tests/lib/test_ab_per_agent_lib.sh` (add six test cases)
- Modify: `tests/ab/lib/launch.sh` (add `launch_assert_trial_recoverable` helper)

- [ ] **Step 1: Write the failing tests**

Append to `tests/lib/test_ab_per_agent_lib.sh`:

```bash
_ab_3_1c_setup_trial_dir() {
    # Helper: build a synthetic trial dir with the given stdout.log size and
    # an optional stream.jsonl containing the given JSONL events. Echoes the
    # path on stdout for the caller to consume and clean up.
    local stdout_bytes="$1"
    local stream_jsonl_content="$2"  # empty string = no file
    local d
    d=$(mktemp -d)
    if [[ "$stdout_bytes" == "0" ]]; then
        : > "$d/stdout.log"
    else
        # Pad with predictable bytes; exact content does not matter for the predicate.
        printf '%*s' "$stdout_bytes" '' | tr ' ' 'x' > "$d/stdout.log"
    fi
    if [[ -n "$stream_jsonl_content" ]]; then
        printf '%s' "$stream_jsonl_content" > "$d/stream.jsonl"
    fi
    : > "$d/stderr.log"
    echo '{}' > "$d/timing.json"
    echo "$d"
}

test_ab_launch_assert_recovered_fallback_passes() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 500 \
        '{"type":"result","subtype":"success","result":""}')

    local rc=0
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) || rc=$?
    assert_equals "0" "$rc" "A/B launch_assert: recovered-fallback case (500 bytes stdout) is recoverable"
    rm -rf "$d"
}

test_ab_launch_assert_empty_no_stream_jsonl_fires() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 "")

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_no_stream_jsonl"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + no stream.jsonl → fires with reason=no_stream_jsonl"
    else
        fail "A/B launch_assert: empty stdout + no stream.jsonl → fires with reason=no_stream_jsonl" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_empty_no_terminal_result_fires() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 \
        '{"type":"system","subtype":"init","session_id":"x"}')

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_no_terminal_result"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + truncated stream.jsonl → fires with reason=no_terminal_result"
    else
        fail "A/B launch_assert: empty stdout + truncated stream.jsonl → fires with reason=no_terminal_result" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_empty_subtype_error_fires() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 \
        '{"type":"result","subtype":"error","result":""}')

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_subtype_error"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + subtype=error → fires with reason=subtype_error"
    else
        fail "A/B launch_assert: empty stdout + subtype=error → fires with reason=subtype_error" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_empty_subtype_success_no_recovery_fires() {
    # The unrecoverable success case: fallback already ran and produced
    # nothing (no text blocks anywhere in the JSONL), so stdout.log is empty
    # despite a successful terminal envelope.
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 \
        '{"type":"result","subtype":"success","result":""}')

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_no_recovery_signal"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + success-but-no-text → fires with reason=no_recovery_signal"
    else
        fail "A/B launch_assert: empty stdout + success-but-no-text → fires with reason=no_recovery_signal" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_non_stream_json_codepath_passes() {
    # Non-stream-json codepath: stdout.log has content, no stream.jsonl
    # exists. Recoverable.
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 1234 "")

    local rc=0
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) || rc=$?
    assert_equals "0" "$rc" "A/B launch_assert: non-empty stdout + no stream.jsonl is recoverable"
    rm -rf "$d"
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run:

```bash
tests/run.sh 2>&1 | grep -E 'launch_assert|tests:'
```

Expected: six `✗` failures (`launch_assert_trial_recoverable: command not found`).

- [ ] **Step 3: Add the helper to `tests/ab/lib/launch.sh`**

Insert this function immediately after `launch_jq_reduce_stream_jsonl`:

```bash
# Validate-or-die post-condition for one per-agent trial. Inspects the
# captured artefacts in <trial_dir> and returns non-zero with a single-line
# JSON object on stderr when the trial is unrecoverable.
#
# Unrecoverable predicate:
#   stdout.log <= 1 byte
#   AND ( no stream.jsonl
#         OR no terminal {type:"result"} event
#         OR result.subtype == "error" )
#
# Anything else is recoverable: a fallback-recovered stdout.log is recoverable;
# a stream.jsonl with subtype="error" AND non-empty stdout.log is recoverable;
# a subtype="error" with empty stdout.log is unrecoverable.
#
# Stable structured-stderr fields:
#   stage, reason, stdout_bytes, stream_jsonl_present, has_terminal_result, result_subtype
#
# Reason values are an enumerated set; adding a new reason is a contract bump:
#   empty_stdout_no_stream_jsonl
#   empty_stdout_no_terminal_result
#   empty_stdout_subtype_error
#   empty_stdout_no_recovery_signal
launch_assert_trial_recoverable() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"
    local stream_jsonl="$trial_dir/stream.jsonl"

    local stdout_bytes=0
    if [[ -f "$stdout" ]]; then
        stdout_bytes=$(wc -c < "$stdout" | awk '{print $1}')
    fi

    # Recoverable: stdout.log has more than 1 byte.
    if [[ "$stdout_bytes" -gt 1 ]]; then
        return 0
    fi

    # stdout is empty; classify the unrecoverable reason.
    local stream_jsonl_present="false"
    local has_terminal_result="false"
    local result_subtype=""
    local reason=""

    if [[ -f "$stream_jsonl" ]]; then
        stream_jsonl_present="true"
        # Probe for terminal result event; capture subtype if present.
        result_subtype=$(jq -r '
            select(.type == "result") | .subtype // ""
        ' "$stream_jsonl" | tail -1)
        if [[ -n "$result_subtype" ]]; then
            has_terminal_result="true"
        fi
    fi

    if [[ "$stream_jsonl_present" == "false" ]]; then
        reason="empty_stdout_no_stream_jsonl"
    elif [[ "$has_terminal_result" == "false" ]]; then
        reason="empty_stdout_no_terminal_result"
    elif [[ "$result_subtype" == "error" ]]; then
        reason="empty_stdout_subtype_error"
    else
        # Terminal subtype="success" but fallback produced nothing.
        reason="empty_stdout_no_recovery_signal"
    fi

    jq -n \
        --arg stage "launch_assert_trial_recoverable" \
        --arg reason "$reason" \
        --argjson stdout_bytes "$stdout_bytes" \
        --arg stream_jsonl_present "$stream_jsonl_present" \
        --arg has_terminal_result "$has_terminal_result" \
        --arg result_subtype "$result_subtype" \
        '{stage: $stage, reason: $reason, stdout_bytes: $stdout_bytes,
          stream_jsonl_present: ($stream_jsonl_present == "true"),
          has_terminal_result: ($has_terminal_result == "true"),
          result_subtype: $result_subtype}' \
        | jq -c '.' >&2

    return 1
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh 2>&1 | grep -E 'launch_assert|tests:'
```

Expected: six `✓` passes; runner totals show no other regression.

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/launch.sh tests/lib/test_ab_per_agent_lib.sh
git commit -m "feat(ab/launch): add launch_assert_trial_recoverable validate-or-die helper (Phase 3.1c Unit B)"
```

---

## Task 4: Wire Unit A and Unit B into `launch_run_per_agent_trial` (Unit C)

Replace the inline jq site at `launch.sh:265–270` with the new helper, and add the validate-or-die call before the function returns.

**Files:**
- Modify: `tests/ab/lib/launch.sh` (`launch_run_per_agent_trial` body)

- [ ] **Step 1: Replace the inline jq with `launch_jq_reduce_stream_jsonl`**

Edit `tests/ab/lib/launch.sh`. The current site at lines 265–270 reads:

```bash
        if [[ -s "$stream_jsonl" ]]; then
            jq -r 'select(.type == "result" and .subtype == "success") | .result' \
                "$stream_jsonl" > "$stdout"
        else
            : > "$stdout"
        fi
```

Replace it with:

```bash
        launch_jq_reduce_stream_jsonl "$stream_jsonl" "$stdout"
```

- [ ] **Step 2: Add the validate-or-die call before `return "$rc"`**

The function currently ends at line 312 with `return "$rc"`. Replace the final block that emits `timing.json` and returns rc:

```bash
    jq -n \
        --arg start "$start_iso" \
        --arg end "$end_iso" \
        --argjson elapsed "$elapsed" \
        --argjson rc "$rc" \
        --arg timed_out "$timed_out" \
        '{start: $start, end: $end, wall_clock_seconds: $elapsed, exit_code: $rc, timed_out: ($timed_out == "true")}' \
        > "$timing"

    return "$rc"
}
```

…with this expanded final block (timing emission unchanged; assert appended; return statement now propagates whichever rc is highest):

```bash
    jq -n \
        --arg start "$start_iso" \
        --arg end "$end_iso" \
        --argjson elapsed "$elapsed" \
        --argjson rc "$rc" \
        --arg timed_out "$timed_out" \
        '{start: $start, end: $end, wall_clock_seconds: $elapsed, exit_code: $rc, timed_out: ($timed_out == "true")}' \
        > "$timing"

    # Phase 3.1c: validate-or-die. If the trial is unrecoverable (empty
    # stdout.log AND no recovery signal in stream.jsonl), the assertion
    # writes a structured-stderr JSON line to fd 2 and returns non-zero.
    # We propagate that rc only if rc was 0 — a real subprocess failure
    # (timeout=124, CLI error) takes precedence over a derived assertion.
    local assert_rc=0
    launch_assert_trial_recoverable "$trial_dir" 2>> "$stderr" || assert_rc=$?
    if [[ "$rc" == "0" && "$assert_rc" != "0" ]]; then
        rc=$assert_rc
    fi

    return "$rc"
}
```

- [ ] **Step 3: Confirm the existing structural tests still pass**

Run:

```bash
tests/run.sh 2>&1 | tail -5
```

Expected: 0 failures. The 3.1a structural test `test_ab_run_sh_stream_json_flag_recognised` and the existing per-agent unit tests still pass; the four Task 2 tests and six Task 3 tests still pass.

- [ ] **Step 4: Smoke-test the wiring against a known-good fixture (offline)**

Reuse the fallback-recovery fixture as a synthetic trial dir; confirm the modified `launch_run_per_agent_trial` codepath would produce non-empty stdout.log and pass validate-or-die. (This is a hand-validation, not a test — Task 8's sweep is the live test.)

```bash
SMOKE_DIR=$(mktemp -d)
cp tests/ab/fixtures/stream-jsonl/empty-result-three-text-blocks.jsonl "$SMOKE_DIR/stream.jsonl"
: > "$SMOKE_DIR/stderr.log"

bash -c "
    source tests/ab/lib/launch.sh
    launch_jq_reduce_stream_jsonl '$SMOKE_DIR/stream.jsonl' '$SMOKE_DIR/stdout.log'
    echo '{}' > '$SMOKE_DIR/timing.json'
    launch_assert_trial_recoverable '$SMOKE_DIR' 2>> '$SMOKE_DIR/stderr.log'
"
echo "stdout.log bytes: $(wc -c < $SMOKE_DIR/stdout.log)"
grep -F '## Ruff Findings' "$SMOKE_DIR/stdout.log" && echo OK
test ! -s "$SMOKE_DIR/stderr.log" && echo "no validate-or-die output"
rm -rf "$SMOKE_DIR"
```

Expected: `stdout.log bytes: ` is several hundred (> 0), `OK` prints, and `no validate-or-die output` prints (the assertion did not fire because stdout.log was recovered).

- [ ] **Step 5: Commit**

```bash
git add tests/ab/lib/launch.sh
git commit -m "feat(ab/launch): wire fallback + validate-or-die into launch_run_per_agent_trial (Phase 3.1c Unit C)"
```

---

## Task 5: Build parser-tightening fixture set and tests (Test 3)

Construct the four parser fixtures and four test cases that pin canonical §7 and prove the drift retrofit is gone — BEFORE removing the drift line. This way Test 3's negative case fails first (drifted shape still parses) and confirms removal lands the change.

**Files:**
- Create: `tests/ab/fixtures/ruff-stdout-canonical-finding.log`
- Create: `tests/ab/fixtures/ruff-stdout-drifted-finding.log`
- Create: `tests/ab/fixtures/ruff-stdout-mixed-prose.log`
- Create: `tests/ab/fixtures/ruff-stdout-two-findings.log`
- Modify: `tests/lib/test_ab_per_agent_lib.sh` (add four test cases)

- [ ] **Step 1: Create `tests/ab/fixtures/ruff-stdout-canonical-finding.log`**

```bash
cat > tests/ab/fixtures/ruff-stdout-canonical-finding.log <<'EOF'
Some preamble.

## Ruff Findings

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused
- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely.
EOF
```

- [ ] **Step 2: Create `tests/ab/fixtures/ruff-stdout-drifted-finding.log`**

This is the prior baseline shape, preserved as a fixture. The retightened parser must produce zero findings here:

```bash
cat > tests/ab/fixtures/ruff-stdout-drifted-finding.log <<'EOF'
## Ruff Findings

**1 finding** — 1 Python file analysed.

---

**Finding 1**

- **File:** `bad.py`
- **Line:** 1
- **Rule:** `F401` (Pyflakes)
- **Severity:** Important
- **Confidence:** 100
- **Message:** `` `sys` imported but unused ``
- **Detail:** The `import sys` statement on line 1 is never referenced.
EOF
```

- [ ] **Step 3: Create `tests/ab/fixtures/ruff-stdout-mixed-prose.log`**

Canonical shape with extra prose paragraphs interspersed:

```bash
cat > tests/ab/fixtures/ruff-stdout-mixed-prose.log <<'EOF'
## Ruff Findings

I ran Ruff against the changed Python files and found one issue.

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused
- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely.

This is a low-risk fix with auto-fix support.
EOF
```

- [ ] **Step 4: Create `tests/ab/fixtures/ruff-stdout-two-findings.log`**

Two canonical `### Finding` blocks with different rule_ids:

```bash
cat > tests/ab/fixtures/ruff-stdout-two-findings.log <<'EOF'
## Ruff Findings

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused
- **Suggested fix:** Remove the import.

### Finding — Line too long
- **File:** bad.py:3
- **Confidence:** 100
- **Severity:** Important
- **Rule:** E501 (pycodestyle)
- **Description:** Line too long (95 > 88 characters).
- **Suggested fix:** Wrap the line.
EOF
```

- [ ] **Step 5: Append the four parser tests to `tests/lib/test_ab_per_agent_lib.sh`**

```bash
test_ab_agent_capture_canonical_shape_yields_canonical_hash() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-canonical-finding.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: canonical-fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count first_rule
    count=$(jq 'length' "$d/findings.json")
    first_rule=$(jq -r '.[0].rule_id' "$d/findings.json")
    assert_equals "1" "$count" "A/B agent_capture: canonical fixture parses one finding"
    assert_equals "F401" "$first_rule" "A/B agent_capture: canonical fixture rule_id"

    # Hash equality: the canonical tuple must produce the Phase-2 baseline hash.
    # Use the direct file-shasum form to match the harness invariant
    # (`_agent_capture_compute_hash` in `agent_capture.sh` writes the same
    # pipeline into `findings_hash.txt`). The plan's earlier `jq -c -S '.'`
    # pipeline reordered keys and yielded a different hash; that was a
    # transcription bug fixed in execution per operator decision 2026-06-01
    # (Amendment 1).
    local expected_hash="7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3"
    local actual_hash
    actual_hash=$(shasum -a 256 "$d/findings.json" | awk '{print $1}')
    assert_equals "$expected_hash" "$actual_hash" "A/B agent_capture: canonical fixture preserves Phase-2 tuple hash"

    rm -rf "$d"
}

test_ab_agent_capture_drifted_shape_yields_zero_findings() {
    # Phase 3.1c: the parser is retightened to canonical §7; the drifted
    # shape (**Finding N** + Message:/Detail:) MUST produce zero findings,
    # not retrofit-tolerated tuples.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-drifted-finding.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: drifted-fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count
    count=$(jq 'length' "$d/findings.json")
    assert_equals "0" "$count" "A/B agent_capture: drifted shape parses to zero findings (retrofit removed)"
    rm -rf "$d"
}

test_ab_agent_capture_mixed_prose_still_parses_canonical() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-mixed-prose.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: mixed-prose fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count first_rule
    count=$(jq 'length' "$d/findings.json")
    first_rule=$(jq -r '.[0].rule_id' "$d/findings.json")
    assert_equals "1" "$count" "A/B agent_capture: canonical-with-prose parses one finding"
    assert_equals "F401" "$first_rule" "A/B agent_capture: canonical-with-prose rule_id"
    rm -rf "$d"
}

test_ab_agent_capture_two_canonical_findings_sorted() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-two-findings.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: two-findings fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count first_line second_line first_rule second_rule
    count=$(jq 'length' "$d/findings.json")
    first_line=$(jq -r '.[0].line' "$d/findings.json")
    second_line=$(jq -r '.[1].line' "$d/findings.json")
    first_rule=$(jq -r '.[0].rule_id' "$d/findings.json")
    second_rule=$(jq -r '.[1].rule_id' "$d/findings.json")
    assert_equals "2" "$count" "A/B agent_capture: two canonical findings extracted"
    assert_equals "1" "$first_line" "A/B agent_capture: line-1 finding sorts first"
    assert_equals "3" "$second_line" "A/B agent_capture: line-3 finding sorts second"
    assert_equals "F401" "$first_rule" "A/B agent_capture: first rule_id"
    assert_equals "E501" "$second_rule" "A/B agent_capture: second rule_id"
    rm -rf "$d"
}
```

- [ ] **Step 6: Run the tests to confirm three pass and one fails**

Run:

```bash
tests/run.sh 2>&1 | grep -E 'agent_capture|tests:' | tail -20
```

Expected at this point (parser still has the retrofit):

- `canonical_shape_yields_canonical_hash` → `✓` (canonical input already parsed cleanly)
- `drifted_shape_yields_zero_findings` → `✗` (the retrofit is still in; drifted shape still produces 1 finding) ← this is the failing TDD red
- `mixed_prose_still_parses_canonical` → `✓`
- `two_canonical_findings_sorted` → `✓`

If the canonical-hash test fails too, the prior baseline doesn't actually have the canonical hash — investigate before continuing.

- [ ] **Step 7: Commit the fixtures and tests**

```bash
git add tests/ab/fixtures/ruff-stdout-canonical-finding.log \
        tests/ab/fixtures/ruff-stdout-drifted-finding.log \
        tests/ab/fixtures/ruff-stdout-mixed-prose.log \
        tests/ab/fixtures/ruff-stdout-two-findings.log \
        tests/lib/test_ab_per_agent_lib.sh
git commit -m "test(ab/agent_capture): add canonical/drifted/mixed/multi-finding fixtures + tests for Phase 3.1c parser tightening (red)"
```

---

## Task 6: Tighten the parser to canonical §7 only (Unit D)

Drop the `**Finding [0-9]+**` retrofit and update the comment blocks that mention it. This turns the failing Test 3 case green.

**Files:**
- Modify: `tests/ab/lib/agent_capture.sh`

- [ ] **Step 1: Remove the drift-tolerance line**

Edit `tests/ab/lib/agent_capture.sh`. Locate the awk block in `agent_capture_parse_ruff_trial`. Around line 110–111 the parser declares:

```bash
        # Finding boundary: a new heading or a second File: starts a new finding.
        /^### Finding/ { emit_if_complete(); next }
        /^\*\*Finding [0-9]+\*\*/ { emit_if_complete(); next }
```

Delete the second of those two lines (the `**Finding [0-9]+**` match). The result:

```bash
        # Finding boundary: a new heading or a second File: starts a new finding.
        /^### Finding/ { emit_if_complete(); next }
```

- [ ] **Step 1b: Heading-gate the emission (Amendment 2, operator decision 2026-06-01)**

Dropping the retrofit line alone is insufficient: the drifted shape's field bullets
(`- **File:**`, `- **Line:**`, `- **Rule:**`, `- **Severity:**`, `- **Confidence:**`)
are byte-identical to canonical bullets and accumulate tuple state regardless of any
heading, and `END { emit_if_complete }` flushes one tuple at EOF — so the drifted
fixture would still parse to one finding instead of zero. Add a heading gate:

1. Add `in_finding_block = 0` to the `BEGIN` action's initialisers.
2. Set the gate when a canonical heading matches:
   `/^### Finding/ { emit_if_complete(); in_finding_block = 1; next }`.
3. Gate emission inside `emit_if_complete`: prefix the print condition with
   `in_finding_block && …`. Do NOT reset `in_finding_block` inside
   `emit_if_complete` — it stays sticky-true for the rest of the file so
   multi-finding canonical input keeps emitting tuple-after-tuple; the gate only
   suppresses emission when NO canonical heading was ever seen (the drifted case).

- [ ] **Step 2: Update the state-machine comment block (lines 64–65)**

Locate the comment block that lists tolerated heading variants:

```bash
    #   - heading variants: `### Finding — [title]` (canonical) and
    #     `**Finding N**` (current agent surface drift)
    #   - non-tuple bullets (Description, Message, Detail, Suggested fix,
    #     Reference) — parsed and discarded; they live in the visible report
    #     but are not part of the deterministic tuple.
```

Replace with:

```bash
    #   - heading: `### Finding — [title]` (canonical §7 only post-3.1c).
    #     The `**Finding N**` shape was the prior drifted heading; Phase 3.1c
    #     pins the parser to canonical §7 so drifted shapes parse to zero
    #     findings (registers as DRIFT in the trial classifier).
    #   - non-tuple bullets (Description, Suggested fix, Reference) — parsed
    #     and discarded; they live in the visible report but are not part of
    #     the deterministic tuple.
```

- [ ] **Step 3: Update the "intentionally ignored" comment block (lines 146–147)**

Locate:

```bash
        # All other lines (Description, Message, Detail, Suggested fix,
        # Reference, prose, --- separators) are intentionally ignored.
```

Replace with:

```bash
        # All other lines (Description, Suggested fix, Reference, prose,
        # --- separators) are intentionally ignored. Pre-3.1c the parser
        # also tolerated Message / Detail bullets via the catch-all here;
        # post-3.1c those names no longer appear in canonical agent output.
```

- [ ] **Step 4: Run all tests to confirm Test 3 turns green**

Run:

```bash
tests/run.sh 2>&1 | grep -E 'agent_capture|tests:' | tail -20
```

Expected:

- All four Task 5 parser tests now `✓`.
- The pre-existing `test_ab_agent_capture_parses_three_findings` test consumes `tests/ab/fixtures/ruff-stdout-three-findings.log` which uses the drifted shape — it will now FAIL because the retrofit is gone. This is intentional.

- [ ] **Step 5: Update the pre-existing three-findings fixture to canonical shape**

Rewrite `tests/ab/fixtures/ruff-stdout-three-findings.log` to canonical §7 shape so the legacy test continues to pass and exercises the multi-finding path on canonical input:

```bash
cat > tests/ab/fixtures/ruff-stdout-three-findings.log <<'EOF'
Some preamble noise from the dispatched session.

## Ruff Findings

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused.
- **Suggested fix:** Remove the import.

### Finding — Line too long
- **File:** bad.py:3
- **Confidence:** 100
- **Severity:** Important
- **Rule:** E501 (pycodestyle)
- **Description:** Line too long (some pretext over 80 chars).
- **Suggested fix:** Wrap the line.

### Finding — Function call in argument default
- **File:** notebook.ipynb:12
- **Confidence:** 100
- **Severity:** Important
- **Rule:** B008 (bugbear)
- **Description:** Do not perform function call in argument defaults.
- **Suggested fix:** Move the call into the function body.

Trailing prose that must not be parsed as a finding.
EOF
```

- [ ] **Step 6: Re-run all tests to confirm everything is green**

Run:

```bash
tests/run.sh 2>&1 | tail -5
```

Expected: 0 failures. All Task 2, 3, 5, and pre-existing per-agent tests pass.

- [ ] **Step 7: Commit**

```bash
git add tests/ab/lib/agent_capture.sh tests/ab/fixtures/ruff-stdout-three-findings.log
git commit -m "feat(ab/agent_capture): drop **Finding N** retrofit, pin to canonical §7 (Phase 3.1c Unit D)"
```

---

## Task 7: Regenerate the canonical baseline (Unit E)

Replace `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md` with canonical §7 form and update `source.yaml`. The regenerated baseline must produce the same canonical hash as the prior baseline.

**Files:**
- Modify: `tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md`
- Modify: `tests/ab/corpus/ruff-smoke-bad-py/source.yaml`

- [ ] **Step 1: Rewrite `findings-ruff.md` to canonical §7 form**

```bash
cat > tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md <<'EOF'
## Ruff Findings

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused
- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely.
EOF
```

- [ ] **Step 2: Update `source.yaml`**

Edit `tests/ab/corpus/ruff-smoke-bad-py/source.yaml`. Update three fields and add one new field:

- `captured_at`: bump to today's UTC ISO-8601 timestamp.
- `captured_under.suite_sha`: leave the placeholder `<sweep-sha-tbd>` for now; Task 9 fills this in with the real sweep SHA.
- `captured_under.agent_model`: leave as `sonnet`.
- `captured_under.agent_effort`: leave as `default`.
- Add a new top-level field `baseline_revision: 2` immediately after `captured_under:` so future regenerations are tracked.

Diff the file before saving — the rest of the YAML (`id`, `agent`, `working_dir_strategy`, `source_path`, `base_sha`, `head_sha`, `path_scope`, `empty_tree_mode`, `intent_ledger`, `depends_on`) is unchanged.

Final shape:

```yaml
id: ruff-smoke-bad-py
agent: ruff-reviewer
captured_at: 2026-06-01T00:00:00Z
baseline_revision: 2
captured_under:
  suite_sha: <sweep-sha-tbd>
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/ruff/
base_sha: ""  # synthetic fixture: no real diff
head_sha: ""
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - Synthetic smoke fixture exercising ruff-reviewer against a single
    Python file with one F401 unused import. Bootstraps the per-agent
    reconstruction loop end-to-end. Phase 3.1c regenerated the expected
    output to canonical §7 shape; tuple hash preserved.
depends_on:
  - plugins/code-review-suite/agents/ruff-reviewer.md
  - plugins/code-review-suite/includes/static-analysis-context.md
  - tests/fixtures/static-analysis/ruff/bad.py
  - tests/fixtures/static-analysis/ruff/notebook.ipynb
```

- [ ] **Step 3: Commit**

```bash
git add tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md \
        tests/ab/corpus/ruff-smoke-bad-py/source.yaml
git commit -m "test(ab/corpus): regenerate ruff-smoke-bad-py baseline to canonical §7 (Phase 3.1c Unit E)"
```

---

## Task 8: Test 4 — manual baseline pre-flight (gate before sweep)

One-shot integrity check: parse the regenerated baseline through the retightened parser and confirm the resulting `findings.json` has the canonical hash.

**Files:** none modified. Runs locally; result documented in the PR body.

- [ ] **Step 1: Parse the regenerated baseline**

```bash
PRE=$(mktemp -d)
cp tests/ab/corpus/ruff-smoke-bad-py/expected/findings-ruff.md "$PRE/stdout.log"

bash -c "
    source tests/ab/lib/agent_capture.sh
    agent_capture_parse_ruff_trial '$PRE'
"

cat "$PRE/findings.json"
```

Expected: a JSON array with one element matching `{file: "bad.py", line: 1, rule_id: "F401", severity: "Important", confidence: 100}`.

- [ ] **Step 2: Compute the hash and compare against the canonical**

Use the direct file-shasum form — `shasum -a 256 "$PRE/findings.json"` — NOT the
key-sorting `jq -c -S '.' | shasum` pipeline. The harness invariant
(`_agent_capture_compute_hash` at `tests/ab/lib/agent_capture.sh:175`, which writes
`findings_hash.txt`) is the direct file-shasum; the canonical hash
`7b003236…91c3` is defined against that form. The `jq -c -S '.'` pipeline reorders
keys and yields a different hash (`31b419f6…bca7`), producing a spurious
PRE-FLIGHT FAIL. This mirrors Amendment 1 (the Task 5 test pipeline); Amendment 3
(operator decision 2026-06-01) propagates that fix to this gate.

```bash
ACTUAL=$(shasum -a 256 "$PRE/findings.json" | awk '{print $1}')
EXPECTED="7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3"
echo "actual:   $ACTUAL"
echo "expected: $EXPECTED"
test "$ACTUAL" == "$EXPECTED" && echo "PRE-FLIGHT PASS" || echo "PRE-FLIGHT FAIL"
rm -rf "$PRE"
```

Expected output: `PRE-FLIGHT PASS`.

- [ ] **Step 3: If pre-flight FAILs, do not proceed**

If hashes diverge, the regenerated baseline does not actually preserve the canonical tuple. Inspect both `findings.json` and the parser output, fix the baseline (or the parser), and re-run Steps 1–2. The sweep MUST NOT run until pre-flight passes — a divergent baseline would invalidate Test 5.

- [ ] **Step 4: Record the pre-flight result**

Note the timestamp, hash match, and the PRE-FLIGHT result for inclusion in the PR body. No file commit at this step.

---

## Task 9: Author the agent-prompt example block (Unit F)

Append a worked §7 example block to `plugins/code-review-suite/agents/ruff-reviewer.md` under `## Output`. ~12 lines.

**Files:**
- Modify: `plugins/code-review-suite/agents/ruff-reviewer.md`

- [ ] **Step 1: Append the example block under `## Output`**

The current `## Output` section ends at the last line of the file (line 84):

```
Clean up `$CLAUDE_TEMP_DIR/ruff-*.json` after parsing.
```

Append after that line:

```markdown

### Worked example — single F401

For a Python file `bad.py` with `import sys` on line 1 and no use of `sys` anywhere, the canonical §7 output is:

```
## Ruff Findings

### Finding — `sys` imported but unused
- **File:** bad.py:1
- **Confidence:** 100
- **Severity:** Important
- **Rule:** F401 (Pyflakes)
- **Description:** `sys` imported but unused
- **Suggested fix:** Remove the `import sys` statement on line 1; ruff's safe auto-fix removes the import entirely.
```

The heading is `### Finding — <title>` (em-dash, U+2014). The bullet field names are `File`, `Confidence`, `Severity`, `Rule`, `Description`, `Suggested fix` — exactly as canonicalised in `includes/static-analysis-context.md` §7. Do not substitute synonyms (`Message`, `Detail`) — the harness parser pins to the §7 names.
```

- [ ] **Step 2: Verify the file still passes structural tests**

Run:

```bash
tests/run.sh 2>&1 | tail -5
```

Expected: 0 failures. The marketplace-manifest tests touch `plugin.json` only, not agent bodies; conventions tests check final newlines and indentation. The example block uses 2-space indentation under the existing `## Output` section, ends with a final newline.

- [ ] **Step 3: Commit**

```bash
git add plugins/code-review-suite/agents/ruff-reviewer.md
git commit -m "feat(code-review-suite/ruff-reviewer): add worked §7 example block (Phase 3.1c Unit F)"
```

---

## Task 10: Test 5 — 20-trial validation sweep (merge gate)

Run the 20-trial Sonnet/default sweep against `ruff-smoke-bad-py` with the harness changes in place. Acceptance: NORMAL ≥ 80 %, DRIFT < 10 %, EMPTY = 0, validate-or-die fires = 0.

**Files:** none modified at this step. Sweep output lands under `tests/ab/runs/<timestamp>-ruff-baseline-validation/` (gitignored).

- [ ] **Step 1: Run the sweep**

The run mode is derived from the config YAML (`mode: per-agent` in
`ruff-baseline.yaml`); `tests/ab/run.sh` has no `--mode` flag and rejects it with
`unknown arg`. The run-name flag is `--name`, not `--experiment-name`. Do NOT pass
`--mode per-agent` (Amendment 4, operator decision 2026-06-01 — the earlier
formulation here, in the spec §Unit G, and in both handovers carried the
unsupported flag).

```bash
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-baseline.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json \
    --name ruff-baseline-validation \
    2>&1 | tee "${CLAUDE_TEMP_DIR:-/tmp}/sweep-output.log"
```

Expected: rc=0 from the harness, 20 `trial-NNN` directories under the run dir, `summary.csv` with 20 rows. ~9 minutes wall-clock, ~50 k Bedrock tokens.

- [ ] **Step 2: Locate the run dir**

```bash
RUN_DIR=$(ls -dt tests/ab/runs/*-ruff-baseline-validation | head -1)
echo "$RUN_DIR"
```

- [ ] **Step 3: Classify each trial**

Run a per-trial classifier that reads each `trial-NNN/stdout.log`, `trial-NNN/findings.json`, and `trial-NNN/stderr.log`:

```bash
echo "trial,class,findings_count,validate_or_die_fired,reason" > "$RUN_DIR/classification.csv"
for d in "$RUN_DIR"/trial-*; do
    n=$(basename "$d")
    bytes=$(wc -c < "$d/stdout.log" | awk '{print $1}')
    count=$(jq 'length' "$d/findings.json" 2>/dev/null || echo 0)
    fired="false"
    reason=""
    if grep -qF '"stage":"launch_assert_trial_recoverable"' "$d/stderr.log" 2>/dev/null; then
        fired="true"
        reason=$(jq -r '.reason' < <(grep -F '"stage":"launch_assert_trial_recoverable"' "$d/stderr.log" | tail -1))
    fi
    if [[ "$bytes" -le 1 ]]; then
        cls="EMPTY"
    elif [[ "$count" == "1" ]] && grep -qF '7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3' "$d/findings_hash.txt"; then
        cls="NORMAL"
    elif [[ "$count" == "0" ]]; then
        cls="DRIFT"
    else
        cls="OTHER"
    fi
    echo "$n,$cls,$count,$fired,$reason" >> "$RUN_DIR/classification.csv"
done
column -t -s, < "$RUN_DIR/classification.csv"
```

- [ ] **Step 4: Compute totals and the acceptance gate**

```bash
NORMAL=$(awk -F, '$2=="NORMAL"' "$RUN_DIR/classification.csv" | wc -l)
DRIFT=$(awk -F, '$2=="DRIFT"' "$RUN_DIR/classification.csv" | wc -l)
EMPTY=$(awk -F, '$2=="EMPTY"' "$RUN_DIR/classification.csv" | wc -l)
OTHER=$(awk -F, '$2=="OTHER"' "$RUN_DIR/classification.csv" | wc -l)
FIRED=$(awk -F, '$4=="true"' "$RUN_DIR/classification.csv" | wc -l)
TOTAL=20
NORMAL_PCT=$(awk -v n="$NORMAL" -v t="$TOTAL" 'BEGIN{printf "%.1f", 100*n/t}')
DRIFT_PCT=$(awk -v d="$DRIFT" -v t="$TOTAL" 'BEGIN{printf "%.1f", 100*d/t}')
echo "NORMAL: $NORMAL/$TOTAL ($NORMAL_PCT %)"
echo "DRIFT:  $DRIFT/$TOTAL ($DRIFT_PCT %)"
echo "EMPTY:  $EMPTY/$TOTAL"
echo "OTHER:  $OTHER/$TOTAL"
echo "validate-or-die fires: $FIRED"

PASS="true"
awk -v n="$NORMAL" -v t="$TOTAL" 'BEGIN{exit !(n/t >= 0.80)}' || PASS="false"
awk -v d="$DRIFT" -v t="$TOTAL" 'BEGIN{exit !(d/t < 0.10)}' || PASS="false"
test "$EMPTY" == "0" || PASS="false"
test "$FIRED" == "0" || PASS="false"
echo "GATE: $PASS"
```

Acceptance gate (all four must hold):

- NORMAL ≥ 80 % (≥ 16/20)
- DRIFT < 10 % (≤ 1/20)
- EMPTY = 0
- validate-or-die fires = 0

If GATE prints `true`, proceed to Task 11. If GATE prints `false`, follow the spec's §"Surface 3 — Validation-sweep failure modes" table to triage:

- EMPTY > 0 → fallback bug, fix Unit A.
- validate-or-die fired → Bedrock instability that day OR an unrecoverable upstream surface; capture trial trace; if Bedrock-instability, rerun once.
- DRIFT ≥ 10 % → Sonnet still emits drifted prose; either the example block isn't load-bearing enough or §7 needs additional disambiguation; fix in this PR.
- NORMAL < 80 % with neither EMPTY nor DRIFT covering the gap → unknown failure mode; triage as a fresh investigation.

- [ ] **Step 5: Compute Wilson 95 % CIs for NORMAL and DRIFT**

```bash
python3 - <<'PY'
import math
def wilson(k, n, z=1.96):
    if n == 0: return (0.0, 0.0)
    p = k / n
    denom = 1 + z*z/n
    centre = (p + z*z/(2*n)) / denom
    half = (z * math.sqrt((p*(1-p)/n) + (z*z/(4*n*n)))) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))

import os, csv
rd = os.environ["RUN_DIR"]
counts = {"NORMAL": 0, "DRIFT": 0, "EMPTY": 0, "OTHER": 0}
with open(f"{rd}/classification.csv") as f:
    next(f)
    for row in csv.reader(f):
        counts[row[1]] = counts.get(row[1], 0) + 1
n = sum(counts.values())
for cls in ("NORMAL", "DRIFT"):
    lo, hi = wilson(counts[cls], n)
    print(f"{cls}: {counts[cls]}/{n} = {100*counts[cls]/n:.1f}% (Wilson 95% CI [{100*lo:.2f}%, {100*hi:.2f}%])")
PY
```

Record the CIs for the validation-sweep note (Task 11).

- [ ] **Step 6: No commit (sweep run dir is gitignored)**

The run dir lives under `tests/ab/runs/`, which is gitignored. Do NOT add it to git. The classification.csv lives there too.

---

## Task 11: Capture sweep result and finalise PR

Write the validation-sweep note, update `source.yaml`'s suite_sha, and prepare the PR.

**Files:**
- Create: `docs/superpowers/notes/<YYYY-MM-DD>-phase-3-1c-validation-sweep.md`
- Modify: `tests/ab/corpus/ruff-smoke-bad-py/source.yaml` (fill in the real sweep SHA)

- [ ] **Step 1: Determine today's date**

```bash
TODAY=$(date -u +'%Y-%m-%d')
echo "$TODAY"
NOTE="docs/superpowers/notes/${TODAY}-phase-3-1c-validation-sweep.md"
echo "$NOTE"
```

- [ ] **Step 2: Resolve the SHA the sweep ran at**

```bash
SWEEP_SHA=$(git rev-parse HEAD)
echo "$SWEEP_SHA"
```

- [ ] **Step 3: Author the validation-sweep note**

Use this template; fill the placeholders from Tasks 10 / Step 4 + Step 5:

```markdown
# Phase 3.1c — validation-sweep result

**Date:** <YYYY-MM-DD>
**Run dir:** `tests/ab/runs/<timestamp>-ruff-baseline-validation/` (local only; gitignored)
**Sweep SHA:** `<short-sha>` (head of `feat/phase-3-1c-tighten-contracts` at sweep time)
**Config:** `tests/ab/configs/per-agent/ruff-baseline.yaml` (Sonnet/default)
**Corpus:** `ruff-smoke-bad-py`
**Trials:** 20
**Stream-json:** on
**Cost:** ~<X> k Bedrock tokens, <Y> minutes wall-clock

## Acceptance gate

| Metric | Threshold | Actual | Pass |
|---|---|---|---|
| NORMAL | ≥ 80 % | <N>/20 (<P> %) | ✓ / ✗ |
| DRIFT | < 10 % | <D>/20 (<P> %) | ✓ / ✗ |
| EMPTY | = 0 | <E> | ✓ / ✗ |
| validate-or-die fires | = 0 | <F> | ✓ / ✗ |

**Gate result:** PASS / FAIL.

## Per-trial classification

| Trial | Class | Findings count | validate-or-die fired | Reason (if fired) |
|---|---|---|---|---|
| trial-001 | NORMAL | 1 | false | |
| trial-002 | NORMAL | 1 | false | |
| ... | | | | |

(Generated from `classification.csv` in the run dir.)

## Wilson 95 % CIs

- NORMAL: <N>/20 = <P> % (Wilson 95 % CI [<lo> %, <hi> %])
- DRIFT: <D>/20 = <P> % (Wilson 95 % CI [<lo> %, <hi> %])

## Verdict

The validation gate <passes / fails>. The 30 % EMPTY incidence and 65 % DRIFT
incidence observed in 3.1a's Haiku/`low` sweep collapse to <values> at
Sonnet/default with the harness fallback + parser tightening + §7 example
block in place.

The Phase 3.1a-identified upstream Claude Code envelope-finalisation gap
remains as a side artefact (tracked separately for upstream filing); the
harness is now insulated from it.

## Cross-references

- Spec: `docs/superpowers/specs/2026-06-01-phase-3-1c-tighten-contracts-design.md`
- Phase 3.1a result report: `docs/superpowers/notes/2026-05-29-empty-stdout-investigation-result.md`
- PR: <pr-url>
```

- [ ] **Step 4: Backfill `source.yaml`'s suite_sha**

Edit `tests/ab/corpus/ruff-smoke-bad-py/source.yaml` and replace `<sweep-sha-tbd>` with `$SWEEP_SHA` (the full 40-char SHA). The rest of the file stays as Task 7 left it.

- [ ] **Step 5: Commit the note and the source.yaml backfill**

```bash
git add "docs/superpowers/notes/${TODAY}-phase-3-1c-validation-sweep.md" \
        tests/ab/corpus/ruff-smoke-bad-py/source.yaml
git commit -m "docs(superpowers): record Phase 3.1c validation-sweep result + backfill suite_sha"
```

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin feat/phase-3-1c-tighten-contracts
```

Use the PR-body template:

```bash
cat > "${CLAUDE_TEMP_DIR:-/tmp}/pr-body.md" <<'EOF'
This PR lands Phase 3.1c of the static-specialist tuning sweep (Phase 3),
the cross-cutting tightening sub-phase that resolves the two apparatus
problems identified by Phase 3.1a's Haiku/`low` empty-stdout investigation
(PR #36, merged 2026-05-29). 3.1c unblocks Phase 3.1b (re-probe ruff
cost-tuning) and pins the canonical §7 contract that Phase 3.2 / 3.3 / 3.4
inherit when authoring eslint / trivy / jbinspect parsers.

Changes:

1. **Harness fallback (`tests/ab/lib/launch.sh`).** New private helper
   `launch_jq_reduce_stream_jsonl` extends the existing `stream.jsonl` jq
   reduction with a fallback over `assistant.message.content[].text` blocks
   when `.result == ""`. Stream-json-conditional; non-stream-json codepath
   unchanged.
2. **Validate-or-die assertion (`tests/ab/lib/launch.sh`).** New private
   helper `launch_assert_trial_recoverable` is called by
   `launch_run_per_agent_trial` after rc capture. Returns non-zero with a
   structured-stderr JSON line when a trial is unrecoverable. Reason values
   are an enumerated set.
3. **Parser retightening (`tests/ab/lib/agent_capture.sh`).** Drop the
   `**Finding [0-9]+**` retrofit; pin to canonical §7. Two comment blocks
   updated.
4. **Canonical baseline regeneration (`tests/ab/corpus/ruff-smoke-bad-py/`).**
   `expected/findings-ruff.md` regenerated to canonical §7. `source.yaml`
   bumped: `captured_at`, `suite_sha`, new `baseline_revision: 2`. The
   canonical tuple hash `7b003236…91c3` is preserved (verified by manual
   pre-flight in Task 8 of the plan).
5. **Agent-prompt example block (`plugins/code-review-suite/agents/ruff-reviewer.md`).**
   Worked F401 example under `## Output` reinforces the §7 shape.
6. **Validation sweep.** 20-trial Sonnet/default sweep against
   `ruff-smoke-bad-py`. Result note at
   `docs/superpowers/notes/<YYYY-MM-DD>-phase-3-1c-validation-sweep.md`.

Related PRs:

- Phase 3.1a investigation: #36 (merged commit `dae8ca4`)
- Phase 3.1 abandoned-for-cause carrier: #35
- Per-agent harness Phase 2 chassis: #33 (commit `b214944`)

Test plan:

- [x] Tests 1–3 pass in CI (`tests/run.sh`).
- [x] Test 4 (manual baseline pre-flight) — see PR body for hash check.
- [x] Test 5 (20-trial validation sweep) — see linked sweep note for the
      acceptance-gate result.
EOF

gh pr create \
    --base main \
    --head feat/phase-3-1c-tighten-contracts \
    --title "feat(ab): Phase 3.1c — tighten contracts + fail-loud" \
    --body-file "${CLAUDE_TEMP_DIR:-/tmp}/pr-body.md"
```

Expected: `gh pr create` returns the PR URL. Record it for the validation-sweep note's `<pr-url>` placeholder; if you populate that after the PR is created, push a follow-up commit OR edit the note before opening the PR. (Either works; pick one and apply consistently.)

---

## Self-review checklist (run after writing the plan, before handing off)

- [ ] Spec coverage: every Unit A–G in the spec maps to at least one task.
  - Unit A → Task 2
  - Unit B → Task 3
  - Unit C → Task 4
  - Unit D → Task 6
  - Unit E → Task 7
  - Unit F → Task 9
  - Unit G → Task 10
  - Manual pre-flight (Test 4) → Task 8
  - Validation-sweep note → Task 11
- [ ] Placeholder scan: no TBD, TODO, "implement later", "similar to Task N".
- [ ] Type consistency: helper signatures match across tasks (`launch_jq_reduce_stream_jsonl <stream_jsonl_path> <stdout_target_path>`; `launch_assert_trial_recoverable <trial_dir>`).
- [ ] All four reason values from the spec are tested in Task 3:
      `empty_stdout_no_stream_jsonl`, `empty_stdout_no_terminal_result`,
      `empty_stdout_subtype_error`, `empty_stdout_no_recovery_signal`.
- [ ] Canonical hash `7b003236…91c3` referenced consistently across Tasks 5, 7, 8.

