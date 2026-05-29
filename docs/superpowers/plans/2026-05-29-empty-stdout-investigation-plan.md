# Empty-stdout investigation — Phase 3.1a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce the empty-stdout anomaly on the per-agent codepath at scale (N=20 trials at Haiku/low against `ruff-smoke-bad-py`), capture the per-event tool-use trace via `claude -p --output-format stream-json` for any occurrence, classify each trial, hypothesise probable cause, and produce a one-page report. NO production agent edits, NO orchestrator-level fixes — those land in Phase 3.1c.

**Architecture:** A small extension to the existing per-agent harness adds an opt-in `--stream-json` flag that propagates `--output-format stream-json` into `claude -p` and persists the JSONL event trace to `trial-NNN/stream.jsonl` per trial, alongside the unchanged `stdout.log` (so existing parsers and the faithfulness check continue to work bit-identically). One 20-trial sweep against the existing smoke fixture produces the data set; offline classification and trace inspection produces the report.

**Tech Stack:** Phase 2 per-agent harness (`tests/ab/run.sh --mode per-agent`, `lib/launch.sh launch_run_per_agent_trial`, `lib/agent_capture.sh`, existing `ruff-haiku-low.yaml` config from Phase 3.1's Task 2). Bash 4+, `yq`, `jq`, `gh`. New surface: a single boolean flag and its plumbing.

**Spec:** [`docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md`](../specs/2026-05-29-empty-stdout-investigation-design.md). Phase 3.1a is the strict subset of the original anomaly spec ([`2026-05-21-orchestrator-empty-stdout-anomaly.md`](../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md)) executed on the cheap per-agent substrate.

**Driving question:** What is the empty-stdout incidence rate at Haiku/low (Wilson 95% CI) and what does the stream-json trace at the moment of non-emission tell us about the probable cause?

**Cost expectation:** ~50–100k Bedrock tokens for the 20-trial sweep. ~1.5–2 hours wall-clock total including plan execution and PR.

---

## Pre-flight context

Read these before executing — they will not be in your fresh subagent's context:

1. **Spec:** `docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md` — methodology, classification rules, outcome table.
2. **Original anomaly spec:** `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md` — Phase 1 Trial 2 forensic record, hypothesis space, "What we SHOULD do" §1–5 actions.
3. **Phase 3.1 plan and the abandoned-for-cause result:** `docs/superpowers/plans/2026-05-29-static-specialist-tuning-ruff-plan.md` plus the run dir `tests/ab/runs/20260529T144359Z-ruff-haiku-low/` (gitignored; on local disk only). Trial-003 of that run is the precipitating second observation that Phase 3.1a investigates.
4. **Per-agent harness usage and three load-bearing implementation notes:** `tests/ab/README.md` § "Per-agent mode (Phase 2)".
5. **Auto-memory:** `feedback_models_overlook_tuning_hooks` (variation flows externally), `project_orchestrator_empty_stdout_anomaly` (open issue, now under investigation), `feedback_claudemd_compliance` (read before any Bash tool call).

## Branching

This plan ships as the implementation of a series of commits on `feat/per-agent-tuning-ruff-haiku-low` — the same branch that already carries the Phase 3.1 abandoned-for-cause docs. The branch becomes the carrier for Phase 3.1a's spec, plan, handover, harness extension, and report. The actual 20-trial sweep is gitignored (`tests/ab/runs/`).

If you are starting from scratch on a fresh branch (e.g. plan was merged separately), branch from the latest `main` after the carrier PR merges and reuse `tests/ab/configs/per-agent/ruff-haiku-low.yaml` as-is.

## Housekeeping

The Phase 3.1 housekeeping audit (action SHA pins, runner pin) was no-op on 2026-05-29 and remains so. No housekeeping PR needed for 3.1a.

## File Structure

**New files (Phase 3.1a):**

| Path | Responsibility |
|---|---|
| `tests/lib/test_ab_per_agent_lib.sh` (modified) | One new structural test: `--stream-json` flag is recognised by `run.sh`'s argv parser and the new `_AB_STREAM_JSON` global lands true / false. |
| `tests/ab/lib/launch.sh` (modified) | `launch_run_per_agent_trial` accepts a new boolean parameter and conditionally appends `--output-format stream-json` to the `claude -p` invocation. |
| `tests/ab/run.sh` (modified) | argv parsing for `--stream-json`; propagation of `_AB_STREAM_JSON` into `_ab_run_per_agent` and through to `agent_dispatch_run_trial` → `launch_run_per_agent_trial`. |
| `tests/ab/lib/agent_dispatch.sh` (modified) | `agent_dispatch_run_trial` accepts and forwards the new boolean. |
| `docs/superpowers/notes/2026-XX-XX-empty-stdout-investigation-result.md` | One-page report capturing the 20-trial sweep result: incidence rate + Wilson 95% CI, category breakdown, probable-cause hypothesis, recommended fix surface. New `notes/` directory; create it as part of Task 5. |
| `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md` (modified) | Status line update + appended "Results" section linking to the report. |

**Modified files (Phase 3.1a, gitignored):**

- `tests/ab/runs/<timestamp>-ruff-haiku-low-stream-json/` — the 20-trial sweep output. Not committed.

**Out of scope for Phase 3.1a (do not create):**

- Production agent file edits in `plugins/code-review-suite/agents/`.
- Orchestrator-level safety net in `plugins/code-review-suite/skills/review-gh-pr/SKILL.md` — Phase 3.1c work.
- Harness-level structural-test-time empty-stdout-with-rc-0 assertion — Phase 3.1c work.
- Stream-json plumbing for end-to-end mode (`--mode end-to-end`) — out of scope; per-agent path is the cheap reproduction substrate.
- New fixtures, new corpus entries, new specialist configs.

---

## Important context for implementers

Three details that are easy to miss:

1. **`--stream-json` must keep `stdout.log` bit-identical when stream-json is OFF.** The flag is opt-in and additive: when absent, behaviour matches Phase 2 / Phase 3.1 exactly. Existing structural tests must remain green without modification (apart from the new test added in Task 1). The faithfulness-check codepath, the parser at `lib/agent_capture.sh`, and the summary.csv schema are unchanged.

2. **The exact CLI flag spelling and the JSONL event schema MUST be empirically grounded BEFORE writing the lib code.** Per the spec § "Verifications during implementation" and per the Phase 2 plan-defect note (Task 6 closeout): authoring CLI plumbing against a hypothetical flag form is the dominant failure mode for plan-style specifications in this codebase. Run `command claude -p --output-format stream-json --help 2>&1` (or read `command claude --help`) at Task 1 Step 1 BEFORE plumbing — confirm the exact string `--output-format stream-json` is accepted, confirm the JSONL output goes where you expect (stdout? stderr? a separate file?), and confirm whether the final-text-only output is still produced when stream-json is on.

3. **The dirty-tree assertion in `tests/lib/test_ab_harness.sh:550` will fire mid-iteration during TDD.** Per `feedback_claudemd_compliance` and the Phase 2 plan-defect note #5: this is not a real failure; it triggers during dirty-tree windows mid-iteration and clears at clean HEAD. If you see it fail mid-task, commit your work-in-progress first, then re-run.

---

## Task 1: Empirically ground the `--output-format stream-json` flag and JSONL schema

NO code changes in this task. The output is a captured probe trace and a written summary that informs Tasks 2–5's plumbing. ~5k Bedrock tokens.

**Files:** none modified. Captures land under `${CLAUDE_TEMP_DIR}/`.

- [ ] **Step 1: Confirm the flag exists and capture its `--help` description**

Run:

```bash
command claude --help 2>&1 | tee "${CLAUDE_TEMP_DIR:-/tmp}/claude-help.txt"
grep -E -- "--output-format|stream" "${CLAUDE_TEMP_DIR:-/tmp}/claude-help.txt" || true
```

Expected: at least one line mentioning `--output-format` and `stream-json`. Record the exact spelling. If the flag is `--output-format=stream-json` (with `=`) vs `--output-format stream-json` (separated), use whichever the help text shows.

- [ ] **Step 2: Run a one-off probe with stream-json against the smoke fixture**

Use the existing harness manually but with stream-json bolted on, to see exactly what the CLI emits. Build the prompt by hand:

```bash
mkdir -p "${CLAUDE_TEMP_DIR:-/tmp}/probe-streamjson"
PROBE_DIR="${CLAUDE_TEMP_DIR:-/tmp}/probe-streamjson"

# Reuse Task 2's reconstruction artefacts from the existing run dir.
LAST_RUN=$(ls -t tests/ab/runs/20260529T144359Z-ruff-haiku-low/trial-001)
cp tests/ab/runs/20260529T144359Z-ruff-haiku-low/trial-001/system-prompt.md "$PROBE_DIR/system-prompt.md"
cp tests/ab/runs/20260529T144359Z-ruff-haiku-low/trial-001/user-message.txt "$PROBE_DIR/user-message.txt"

# Materialise a fresh working dir from the smoke fixture.
mkdir -p "$PROBE_DIR/wd"
cp -R tests/fixtures/static-analysis/ruff/. "$PROBE_DIR/wd/"

# Probe.
USER_MSG=$(cat "$PROBE_DIR/user-message.txt")
cd "$PROBE_DIR/wd"
CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 command claude \
    -p \
    --permission-mode bypassPermissions \
    --model haiku \
    --effort low \
    --append-system-prompt-file "$PROBE_DIR/system-prompt.md" \
    --exclude-dynamic-system-prompt-sections \
    --output-format stream-json \
    "$USER_MSG" \
    > "$PROBE_DIR/probe-stdout.log" 2> "$PROBE_DIR/probe-stderr.log"
echo "rc=$?"
cd -
```

Expected: rc=0, `probe-stdout.log` non-empty, contains JSONL events. ~2.5–5k tokens.

- [ ] **Step 3: Inspect the JSONL shape**

```bash
wc -l "$PROBE_DIR/probe-stdout.log"
head -1 "$PROBE_DIR/probe-stdout.log" | jq '.'
tail -1 "$PROBE_DIR/probe-stdout.log" | jq '.'
jq -c '. | {type: .type, role: (.message.role // null), tool: (.tool_use.name // null)}' "$PROBE_DIR/probe-stdout.log" | head -30 > "$PROBE_DIR/event-shapes.txt"
cat "$PROBE_DIR/event-shapes.txt"
```

Record:

- The top-level event types (`message_start`, `content_block_start`, `tool_use`, `text_delta`, `message_stop`, etc.).
- Whether the final text emission is reconstructable from the events.
- Whether the JSONL goes to stdout (which would conflict with our existing `stdout.log` write) or to a separate channel.

- [ ] **Step 4: Decide the plumbing strategy and write a one-paragraph note**

Two plausible plumbing options:

- **Option A: Replace stdout.log with stream.jsonl.** When `--stream-json` is on, the CLI's stdout IS the JSONL, so `> stdout.log` ends up holding JSONL. We rename or split.
- **Option B: Keep both via separate redirects.** If the CLI writes JSONL to stdout AND the final-text to a different fd, we capture both.

Most likely the CLI sends JSONL to stdout (Option A is the reality). Plumbing then is:

- When `_AB_STREAM_JSON=true`: redirect stdout to `trial-NNN/stream.jsonl` directly; reconstruct `trial-NNN/stdout.log` from the JSONL events using a small `jq` filter that walks `text_delta` events and joins them.
- When `_AB_STREAM_JSON=false`: behaviour unchanged.

Write the decision to `${CLAUDE_TEMP_DIR}/streamjson-plumbing-note.md` for handoff to Task 2.

- [ ] **Step 5: No commit (Task 1 is empirical-grounding only; no tracked-file changes)**

If you accidentally created files outside `${CLAUDE_TEMP_DIR}`, clean them up. The harness's existing tests should still pass: `tests/run.sh`.

---

## Task 2: TDD — `--stream-json` flag in run.sh and lib/launch.sh

The implementation surface is small but spans four files. We TDD it via one structural assertion that the flag is recognised by `run.sh`'s argv parser, then add the lib plumbing to make the CLI invocation actually use it.

**Files:**
- Modify: `tests/lib/test_ab_per_agent_lib.sh` (one new test asserting argv parsing)
- Modify: `tests/ab/run.sh` (argv parsing + global propagation)
- Modify: `tests/ab/lib/launch.sh` (conditional `--output-format stream-json` in `launch_run_per_agent_trial`)
- Modify: `tests/ab/lib/agent_dispatch.sh` (forward the boolean from `agent_dispatch_run_trial` → `launch_run_per_agent_trial`)

- [ ] **Step 1: Write the failing structural test**

Append to `tests/lib/test_ab_per_agent_lib.sh`:

```bash
test_ab_run_sh_stream_json_flag_recognised() {
    # Phase 3.1a: --stream-json must be a recognised flag and must propagate
    # _AB_STREAM_JSON=true into the per-agent run path. Default behaviour
    # (flag absent) must yield _AB_STREAM_JSON=false.
    local run="$REPO_ROOT/tests/ab/run.sh"
    if [[ ! -x "$run" ]]; then
        fail "A/B run.sh: --stream-json flag" "missing or not +x"
        return
    fi

    # The flag must be listed in --help so operators can discover it.
    local out
    out=$("$run" --help 2>&1)
    if echo "$out" | grep -qF -- "--stream-json"; then
        pass "A/B run.sh: --stream-json listed in usage"
    else
        fail "A/B run.sh: --stream-json listed in usage" "out=$out"
    fi
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run:

```bash
tests/run.sh
```

Expected: the new test fails because `--stream-json` is not yet listed in `run.sh`'s usage. All other tests still pass.

- [ ] **Step 3: Add the flag to `run.sh`'s `usage()` and argv parser**

Edit `tests/ab/run.sh`:

In the `usage()` block, under "Per-agent mode", insert this line at the same indentation as `--faithfulness-check`:

```
  --stream-json             Phase 3.1a: capture --output-format stream-json
                            JSONL trace per trial at trial-NNN/stream.jsonl;
                            reconstruct stdout.log from text events
```

In `main()`'s argv parsing loop, add a case for `--stream-json`:

```bash
            --stream-json)
                stream_json="true"
                shift 1
                ;;
```

Initialise `stream_json="false"` alongside the existing `faithfulness_check="false"` initialisation.

Pass the new variable into `_ab_run_per_agent`:

```bash
        per-agent)
            ...
            _ab_run_per_agent "$config_path" "$trials" "$experiment_name" "$timeout_seconds" "$corpus_id" "$faithfulness_check" "$stream_json"
            ;;
```

In `_ab_run_per_agent`, accept the new positional and propagate to a global:

```bash
_ab_run_per_agent() {
    local config_path="$1"
    local trials="$2"
    local experiment_name="$3"
    local timeout_seconds="$4"
    local corpus_id="$5"
    local faithfulness_check="$6"
    local stream_json="${7:-false}"

    _AB_STREAM_JSON="$stream_json"
    ...
```

Forward into the trial loop call to `agent_dispatch_run_trial`:

```bash
        agent_dispatch_run_trial \
            "$trial_dir" \
            "$_AB_CONFIG_AGENT" \
            "$_AB_FIXTURE_DIR" \
            "$_AB_CONFIG_SESSION_MODEL" \
            "$_AB_CONFIG_SESSION_EFFORT" \
            "$timeout_bin" \
            "$timeout_seconds" \
            "$working_dir" \
            "$_AB_STREAM_JSON" \
            || rc=$?
```

- [ ] **Step 4: Forward the flag through `agent_dispatch_run_trial`**

Edit `tests/ab/lib/agent_dispatch.sh`. `agent_dispatch_run_trial` currently takes 8 positional parameters; add a 9th, `stream_json`, with a default of `false`:

```bash
agent_dispatch_run_trial() {
    local trial_dir="$1"
    local agent_name="$2"
    local fixture_dir="$3"
    local model="$4"
    local effort="$5"
    local timeout_bin="$6"
    local timeout_seconds="$7"
    local working_dir="$8"
    local stream_json="${9:-false}"
    ...
```

Forward to `launch_run_per_agent_trial`:

```bash
    launch_run_per_agent_trial \
        "$trial_dir" \
        "$timeout_seconds" \
        "$model" \
        "$effort" \
        "$body_tmp" \
        "$user_msg_tmp" \
        "$timeout_bin" \
        "$working_dir" \
        "$stream_json"
```

- [ ] **Step 5: Add `--output-format stream-json` plumbing in `launch_run_per_agent_trial`**

Edit `tests/ab/lib/launch.sh`. `launch_run_per_agent_trial` currently takes 8 positional parameters; add a 9th, `stream_json`, default `false`. The four-way conditional below replaces the existing two-way effort split:

```bash
launch_run_per_agent_trial() {
    local trial_dir="$1"
    local timeout_seconds="$2"
    local model="$3"
    local effort="$4"
    local body_path="$5"
    local user_msg_path="$6"
    local timeout_bin="$7"
    local working_dir="$8"
    local stream_json="${9:-false}"

    local stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log"
    local timing="$trial_dir/timing.json"
    local stream_jsonl="$trial_dir/stream.jsonl"
    ...
```

Build a small array of optional CLI flags to keep the four-way conditional manageable:

```bash
    local -a extra_flags=()
    if [[ -n "$effort" && "$effort" != "default" ]]; then
        extra_flags+=("--effort" "$effort")
    fi
    if [[ "$stream_json" == "true" ]]; then
        extra_flags+=("--output-format" "stream-json")
    fi
```

Replace the existing if/else effort split with a single invocation that uses the array:

```bash
    local rc=0
    if [[ "$stream_json" == "true" ]]; then
        # stream-json mode: stdout IS the JSONL trace. Capture it to stream.jsonl
        # and reconstruct the final-text-only stdout.log via a jq filter.
        (
            cd "$working_dir"
            CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
            "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
                command claude \
                    -p \
                    --permission-mode bypassPermissions \
                    --model "$model" \
                    "${extra_flags[@]}" \
                    --append-system-prompt-file "$body_path" \
                    --exclude-dynamic-system-prompt-sections \
                    "$user_msg" \
                > "$stream_jsonl" 2> "$stderr"
        ) || rc=$?

        # Reconstruct stdout.log from text_delta events. If the CLI emits a
        # different schema than expected, this jq filter may need adjustment;
        # confirm the schema in Task 1 Step 3 before relying on this.
        if [[ -s "$stream_jsonl" ]]; then
            jq -r '
                select(.type == "content_block_delta" and .delta.type == "text_delta")
                | .delta.text
            ' "$stream_jsonl" | tr -d '\n' > "$stdout"
            # Append a final newline so existing parsers see end-of-content.
            printf '\n' >> "$stdout"
        else
            : > "$stdout"
        fi
    else
        # Pre-3.1a behaviour: stdout is the final text directly.
        (
            cd "$working_dir"
            CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
            "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
                command claude \
                    -p \
                    --permission-mode bypassPermissions \
                    --model "$model" \
                    "${extra_flags[@]}" \
                    --append-system-prompt-file "$body_path" \
                    --exclude-dynamic-system-prompt-sections \
                    "$user_msg" \
                > "$stdout" 2> "$stderr"
        ) || rc=$?
    fi
```

The rest of the function (heartbeat, timing.json, return code) is unchanged.

**Empirical-grounding caveat:** the `jq` filter above assumes the JSONL schema captured in Task 1 Step 3. If the actual schema uses different event/type/role names, replace the filter with whatever extracts the final text. Task 1's `${CLAUDE_TEMP_DIR}/streamjson-plumbing-note.md` documents the schema; reconcile here before committing.

- [ ] **Step 6: Run the tests to confirm they pass**

Run:

```bash
tests/run.sh
```

Expected: the new `test_ab_run_sh_stream_json_flag_recognised` passes; all 297 (Phase 3.1 baseline) existing tests still pass; total 298 tests, 297 pass, 1 skip, 0 fail.

- [ ] **Step 7: Smoke test the new flag end-to-end with one trial**

Run:

```bash
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 1 \
    --timeout-seconds 600 \
    --stream-json
```

Expected:

- rc=0; stderr says "Run complete: 1/1 trials".
- Run dir `tests/ab/runs/<timestamp>-ruff-haiku-low/`.
- `trial-001/stream.jsonl` exists and is non-empty (JSONL events).
- `trial-001/stdout.log` exists and contains a `## Ruff Findings` block (reconstructed from the JSONL text deltas).
- `trial-001/findings.json` is parsed (may be `[]` if Haiku/low produces format drift again — that's expected and not a 3.1a failure).
- `summary.csv` schema unchanged.

Cost: ~2.5–5k Bedrock tokens. If anything is broken (empty stream.jsonl, malformed reconstructed stdout, or broken findings parsing on a known-good Sonnet config), STOP. Investigate; do not blind-retry.

- [ ] **Step 8: Smoke test that stream-json OFF still works**

Run:

```bash
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-baseline.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 1 \
    --timeout-seconds 600 \
    --faithfulness-check
```

Expected: rc=0; `faithfulness check PASSED (1/1 trials matched)`. Pre-3.1a behaviour preserved bit-identically. ~3k Bedrock tokens.

- [ ] **Step 9: Commit**

```bash
git add tests/ab/run.sh tests/ab/lib/launch.sh tests/ab/lib/agent_dispatch.sh tests/lib/test_ab_per_agent_lib.sh
git commit -m "$(cat <<'EOF'
feat(tests/ab): add --stream-json flag for per-agent forensic captures

Phase 3.1a infrastructure: opt-in --stream-json on per-agent mode passes
--output-format stream-json to claude -p, persists the JSONL trace to
trial-NNN/stream.jsonl, and reconstructs trial-NNN/stdout.log from the
text_delta events so existing parsers (lib/agent_capture.sh) and the
faithfulness-check codepath continue to work bit-identically.

Default behaviour (flag absent) unchanged.

Structural test asserts the flag is listed in --help. End-to-end smoke
test ran one trial each at Haiku/low (stream-json on) and sonnet/default
(stream-json off, --faithfulness-check on); both passed.

This is plumbing only; the 20-trial sweep that produces the empty-stdout
characterisation is a separate task. Reusable by future probes (3.1b,
3.2-3.4) for forensic capture and by 3.1c for validate-or-die logic.
EOF
)"
```

---

## Task 3: Run the 20-trial sweep

The Bedrock-touching task. ~50–100k tokens, ~10–20 minutes wall-clock. Same cost-aware stop-and-investigate rules as Phase 2b's Task 9 Step 6 and Phase 3.1's Task 3 Step 3.

**Files:** none modified (the run dir is gitignored).

- [ ] **Step 1: Confirm Bedrock auth is current**

Run:

```bash
~/.claude/scripts/aws-sso-preflight.sh
```

Expected: zero stderr, zero exit code. If the SSO token has expired, the operator runs `aws sso login --profile <profile>` themselves; the harness will re-run preflight on `tests/ab/run.sh` invocation.

- [ ] **Step 2: Run the 20-trial sweep**

Run:

```bash
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json
```

Expected:

- 20 trials complete within ~10–20 minutes total wall-clock.
- Run dir `tests/ab/runs/<timestamp>-ruff-haiku-low/`.
- Each `trial-NNN/` contains `stream.jsonl` (non-empty for normal trials, possibly very small for empty-stdout occurrences), `stdout.log`, `stderr.log`, `findings.json`, `findings_hash.txt`, `timing.json`, `system-prompt.md`, `user-message.txt`.
- summary.csv has 20 data rows.
- Faithfulness-check is NOT invoked here.

- [ ] **Step 3: Stop-and-investigate triggers**

If any of the following occurs, halt the task at this step and surface to the operator before doing anything else:

- A trial returns an INCONCLUSIVE marker (Skipped — ruff not on PATH). Different anomaly, halt.
- A trial exits with rc ≠ 0 from `claude` itself. Different anomaly, halt.
- Per-trial wall-clock > 60s on the smoke fixture is a smell — capture timing.json and inspect.
- The harness itself crashes (non-zero exit from run.sh). Halt; do not retry.

- [ ] **Step 4: Capture run metadata**

```bash
RUN_DIR=$(ls -t tests/ab/runs | head -1)
echo "RUN_DIR=$RUN_DIR"
mkdir -p "${CLAUDE_TEMP_DIR}"
{
    echo "run_dir=$RUN_DIR"
    echo "summary.csv (20 rows expected):"
    cat "tests/ab/runs/$RUN_DIR/summary.csv"
} > "${CLAUDE_TEMP_DIR}/sweep-summary.txt"
```

The sweep-summary file is a temp artefact — never commit it.

---

## Task 4: Per-trial classification + stream-json trace inspection

Offline; no Bedrock cost.

**Files:** none modified yet (output written to `${CLAUDE_TEMP_DIR}/`).

- [ ] **Step 1: Classify each trial**

For each of the 20 `trial-NNN/` directories, assign exactly one of EMPTY / DRIFT / NORMAL / OTHER per the spec § Step 3 detection rules:

- EMPTY: `stdout.log` size ≤ 1 byte AND `timing.json` `exit_code=0` AND `timed_out=false`.
- DRIFT: `stdout.log` non-empty AND `agent-output.md` non-empty AND `findings.json` is `[]`.
- NORMAL: `findings.json` is non-empty (any number of findings).
- OTHER: anything else.

A small bash loop over the run dir:

```bash
RUN_DIR="tests/ab/runs/$RUN_DIR_NAME"  # substitute the actual name from Task 3
for t in "$RUN_DIR"/trial-*; do
    n=$(basename "$t")
    stdout_size=$(wc -c < "$t/stdout.log" 2>/dev/null || echo 0)
    rc=$(jq -r '.exit_code' "$t/timing.json")
    timed_out=$(jq -r '.timed_out' "$t/timing.json")
    findings_count=$(jq 'length' "$t/findings.json")
    agent_out_size=$(wc -c < "$t/agent-output.md" 2>/dev/null || echo 0)

    if [[ "$stdout_size" -le 1 ]] && [[ "$rc" == "0" ]] && [[ "$timed_out" == "false" ]]; then
        class="EMPTY"
    elif [[ "$stdout_size" -gt 1 ]] && [[ "$agent_out_size" -gt 0 ]] && [[ "$findings_count" -eq 0 ]]; then
        class="DRIFT"
    elif [[ "$findings_count" -gt 0 ]]; then
        class="NORMAL"
    else
        class="OTHER"
    fi

    printf '%s %s rc=%s wall=%ss findings=%d stdout_bytes=%d\n' \
        "$n" "$class" "$rc" "$(jq -r '.wall_clock_seconds' "$t/timing.json")" \
        "$findings_count" "$stdout_size"
done | tee "${CLAUDE_TEMP_DIR}/classification.txt"
```

Tally the four classes.

- [ ] **Step 2: Compute Wilson 95% CI for the EMPTY incidence**

For an observed `k` EMPTY occurrences in `n=20` trials, the Wilson 95% CI lower and upper bounds are:

```
phat = k / n
z = 1.96
denom = 1 + z²/n
center = (phat + z²/(2n)) / denom
margin = z × sqrt(phat(1-phat)/n + z²/(4n²)) / denom
ci_low = center - margin
ci_high = center + margin
```

For example: k=0 in n=20 → CI is approximately [0%, 16.1%]. k=1 → [0.9%, 23.6%]. k=4 → [8.1%, 41.0%]. Compute by hand or with a small Python one-liner; record the result.

- [ ] **Step 3: Inspect the stream.jsonl trace for each EMPTY occurrence**

For each `trial-NNN/` classified as EMPTY:

```bash
T="tests/ab/runs/$RUN_DIR_NAME/trial-NNN"
wc -l "$T/stream.jsonl"
head -1 "$T/stream.jsonl" | jq '.'
tail -3 "$T/stream.jsonl" | jq '.'

# Walk to the last event before message_stop.
jq -c '. | {type: .type, has_text: (.delta.type == "text_delta"), tool: (.tool_use.name // null)}' "$T/stream.jsonl" \
    | tail -10
```

Categorise per the spec § Step 4:

- **A**: last event is a `tool_use` block, no terminating text turn.
- **B**: last event is a Bedrock-shaped error or partial-stream marker.
- **C**: last event is a normal text turn with content, but reconstructed stdout.log shows only `\n`.
- **D**: trace inconclusive.

Record category counts. Append to `${CLAUDE_TEMP_DIR}/classification.txt`.

If the JSONL schema differs from what Task 1 captured, the `jq` filter above may need adjustment; consult `${CLAUDE_TEMP_DIR}/streamjson-plumbing-note.md`.

- [ ] **Step 4: Save the consolidated analysis**

Write `${CLAUDE_TEMP_DIR}/analysis.md` summarising:

- Total trials: 20 (sanity check).
- Class counts: NORMAL / DRIFT / EMPTY / OTHER.
- EMPTY incidence + Wilson 95% CI.
- For each EMPTY: trial number, wall-clock, category (A/B/C/D), one-sentence trace summary.
- DRIFT incidence (informational; not the headline number for 3.1a, but worth recording).

Pass this file's path to Task 5.

---

## Task 5: Write the one-page report

Write the report regardless of the headline number — the report IS the deliverable. Zero EMPTY in 20 is a publishable result with the upper-bound CI; ≥1 EMPTY is the bug-confirmed case.

**Files:**
- Create: `docs/superpowers/notes/2026-XX-XX-empty-stdout-investigation-result.md` (substitute today's date)

The `docs/superpowers/notes/` directory does not yet exist.

- [ ] **Step 1: Create the directory**

```bash
mkdir -p docs/superpowers/notes
```

- [ ] **Step 2: Write the report**

Replace all `<placeholder>` strings with real values from `${CLAUDE_TEMP_DIR}/analysis.md`. Pick one of the verdict / recommendation alternatives. No literal `<placeholder>` strings should survive.

Skeleton at `docs/superpowers/notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md`:

```markdown
# Empty-stdout investigation — Phase 3.1a result

**Date:** <YYYY-MM-DD>
**Status:** <Bug confirmed | Bounded but not reproduced | Inconclusive>
**Spec:** [`../specs/2026-05-29-empty-stdout-investigation-design.md`](../specs/2026-05-29-empty-stdout-investigation-design.md)
**Original anomaly:** [`../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md`](../specs/2026-05-21-orchestrator-empty-stdout-anomaly.md)
**Run directory:** `tests/ab/runs/<RUN_DIR_NAME>` (gitignored)
**Suite SHA at sweep time:** <git rev-parse HEAD before the sweep>

## Sweep configuration

- Config: `tests/ab/configs/per-agent/ruff-haiku-low.yaml` (`session.model: haiku`, `session.effort: low`)
- Corpus: `ruff-smoke-bad-py` (existing in-tree synthetic smoke fixture)
- Trials: 20
- `--stream-json`: enabled
- Timeout per trial: 600 seconds
- Wall-clock total: <X> minutes

## Class breakdown (n=20)

| Class | Count | % |
|---|---|---|
| NORMAL (findings.json non-empty) | <n> | <p>% |
| DRIFT (parser-mismatch on present output) | <n> | <p>% |
| EMPTY (stdout ≤ 1 byte, rc=0, no timeout) | <n> | <p>% |
| OTHER | <n> | <p>% |

## Headline result

**EMPTY incidence: <k>/20 = <p>%, Wilson 95% CI [<lo>%, <hi>%].**

<one paragraph: how does this compare with the prior observations of 1/6
in Phase 1 Trial 2 and 1/3 in Phase 3.1 trial-003? Is the bug confirmed
reproducible at scale, bounded below 5%, or somewhere in the middle?>

## Per-EMPTY trace inspection

<For each EMPTY trial:>

### trial-NNN

- Wall-clock: <s>s
- Last 3 stream.jsonl events:
  ```json
  <paste the parsed events>
  ```
- Trace category: <A | B | C | D> (<one-sentence justification>)

## Probable cause hypothesis

<one paragraph: based on the category distribution and the trace, what is
the most plausible cause? Is it likely a CLI emission swallow, a Bedrock
streaming hiccup, an orchestrator-style early-exit during a tool-use cycle,
or none of the above?>

## Recommended fix surface (input to Phase 3.1c)

<one paragraph: where should the fix live?>

- CLI-level: <upstream Claude Code issue if so; reference exact behaviour>
- Orchestrator-level safety net in `review-gh-pr/SKILL.md`: <only addresses end-to-end variant>
- Harness-level guard in `tests/ab/run.sh`: <validate-or-die when stdout ≤ 1 byte and rc=0>
- Some combination

## DRIFT observations (informational)

<DRIFT count, format-drift patterns observed, brief note that this is
the explicit subject of Phase 3.1c, not 3.1a>

## What this unblocks

- Phase 3.1c (tighten contracts + fail-loud) — concrete fix surface named.
- Phase 3.1b (ruff cost-tuning resume) — noise floor characterised; trial-count budget for future probes derives from the upper bound here.
- Phases 3.2 / 3.3 / 3.4 — inherit the noise floor.

## Reproduction

```bash
git checkout main
git log --oneline -1
tests/ab/run.sh \
    --config tests/ab/configs/per-agent/ruff-haiku-low.yaml \
    --corpus ruff-smoke-bad-py \
    --trials 20 \
    --timeout-seconds 600 \
    --stream-json
```

Expected EMPTY count: <k> (95% CI [<lo>, <hi>] absolute counts).
```

- [ ] **Step 3: Verify**

Read the report back. Verify all `<placeholder>` strings are replaced. Verify the headline number, CI, and category distribution are internally consistent.

- [ ] **Step 4: Run the structural tests**

```bash
tests/run.sh
```

Expected: 298 tests, 297 pass, 1 skip, 0 fail. Documentation-only changes do not affect the tests.

---

## Task 6: Update the original anomaly spec

**Files:**
- Modify: `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md`

- [ ] **Step 1: Update the status line**

Edit the spec's first quoted block. Change:

```
> **Status:** Open — anomaly worth investigating.
```

to (substitute the actual outcome):

```
> **Status:** Investigated <YYYY-MM-DD>; <bug confirmed at <p>% incidence | bounded ≤ <p>% at 95% CI but not reproduced at N=20>; see [`../notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md`](../notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md).
```

- [ ] **Step 2: Append a "Results" section**

At the end of the file (after the existing "Cross-references" section if it sits last, otherwise immediately before it), append:

```markdown
## Results — Phase 3.1a investigation

A 20-trial sweep at Haiku/low against `ruff-smoke-bad-py` on the
per-agent codepath was completed on <YYYY-MM-DD> as Phase 3.1a of the
static-specialist tuning sweep. EMPTY incidence: <k>/20 = <p>%
(Wilson 95% CI [<lo>%, <hi>%]). <One sentence on category distribution
and probable cause.> Full result and recommended fix surface at
[`../notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md`](../notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md).

The original spec's hypothesis space, observation, and "What we should
do" §1+§2 actions are superseded by the executed Phase 3.1a methodology
captured in [`2026-05-29-empty-stdout-investigation-design.md`](2026-05-29-empty-stdout-investigation-design.md). §3 (harness assertion), §4 (orchestrator safety net),
and §5 (stream-json reproduction) are picked up by Phase 3.1c
("tighten contracts + fail-loud", not yet brainstormed).
```

- [ ] **Step 3: Commit the documentation update + report together**

```bash
git add docs/superpowers/notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md \
    docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md
git commit -m "$(cat <<'EOF'
docs(superpowers): Phase 3.1a empty-stdout investigation result

Captures the 20-trial Haiku/low sweep result against ruff-smoke-bad-py
on the per-agent codepath. EMPTY incidence + Wilson 95% CI; per-EMPTY
stream.jsonl trace inspection; probable-cause hypothesis; recommended
fix surface for Phase 3.1c.

Promotes the original anomaly spec from "Open" to "Investigated";
appends a Results section pointing at the report. The original
hypothesis space and forensic record are intact.

Phase 3.1b (ruff cost-tuning resume) and Phases 3.2-3.4 (eslint, trivy,
jbinspect) inherit the noise floor characterised here.
EOF
)"
```

---

## Task 7: Open the Phase 3.1a / 3.1 carrier PR

The plan ships as part of the `feat/per-agent-tuning-ruff-haiku-low` branch's existing carrier PR. The branch already carries: Task 2 of the original 3.1 plan (ruff-haiku-low.yaml + structural test), the new spec at `docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md`, the new plan, and (after Tasks 1-6 of THIS plan execute) the harness `--stream-json` extension, the sweep-result report, and the original-anomaly spec update.

**Files:** none modified.

- [ ] **Step 1: Confirm the branch is clean and rebased**

```bash
git status --short
git fetch origin main
git rebase origin/main
```

Expected: clean status; rebase completes without conflicts.

- [ ] **Step 2: Push and write the PR body**

```bash
git push -u origin feat/per-agent-tuning-ruff-haiku-low
```

Write the PR body to `${CLAUDE_TEMP_DIR}/phase31a-pr-body.md`:

```markdown
This PR closes Phase 3.1 of the per-agent A/B harness programme as **abandoned-for-cause** and lands the Phase 3.1a empty-stdout investigation that re-grounds the programme. Phase 3.1's headline question (does ruff-reviewer at Haiku/low produce findings byte-identical to Sonnet/default?) was un-answerable not because Haiku misses findings, but because the apparatus had two unresolved bugs: format drift (Haiku emits §7-correct content but in two different surface shapes the parser doesn't accept) and the empty-stdout anomaly (1/3 trials returned rc=0 with stdout="\n"). 3.1a characterises the empty-stdout noise floor on the cheap per-agent substrate; the format-drift problem is the explicit subject of Phase 3.1c (cross-cutting "tighten contracts + fail-loud", not yet brainstormed); Phase 3.1b is the ruff cost-tuning resume that follows 3.1c.

## What's in this PR

- `tests/ab/configs/per-agent/ruff-haiku-low.yaml` (carries forward from Phase 3.1's Task 2; reusable as the cheap reproduction substrate for 3.1a).
- `tests/lib/test_ab_per_agent_lib.sh` — structural tests for the haiku-low config and the new `--stream-json` flag.
- `tests/ab/run.sh`, `tests/ab/lib/launch.sh`, `tests/ab/lib/agent_dispatch.sh` — `--stream-json` plumbing. JSONL trace persisted to `trial-NNN/stream.jsonl` per trial; `stdout.log` reconstructed from text deltas so existing parsers and the faithfulness check are bit-identical when the flag is absent.
- `docs/superpowers/specs/2026-05-29-empty-stdout-investigation-design.md` — Phase 3.1a methodology spec.
- `docs/superpowers/plans/2026-05-29-empty-stdout-investigation-plan.md` — this plan.
- `docs/superpowers/notes/<YYYY-MM-DD>-empty-stdout-investigation-result.md` — 20-trial Haiku/low sweep result. Headline: EMPTY incidence <k>/20 = <p>% (Wilson 95% CI [<lo>%, <hi>%]).
- `docs/superpowers/specs/2026-05-21-orchestrator-empty-stdout-anomaly.md` — promoted Open → Investigated; Results section appended.

## What's NOT in this PR

- Phase 3.1's planned production agent edit (`plugins/code-review-suite/agents/ruff-reviewer.md` `model: sonnet → haiku`). Verdict was negative-by-cause; no edit ships.
- The harness validate-or-die layer / orchestrator safety net / contract-pinning across all four static specialists. Those are Phase 3.1c work.

## Verdict for Phase 3.1

**Reject — abandoned for cause.** Three trials of Haiku/low produced semantically correct findings (F401 detected in 2/3) but reformatted off the §7 markdown contract; trial-003 hit the empty-stdout anomaly. Format drift and empty-stdout are both apparatus problems, not Haiku-capability problems. Production `ruff-reviewer.md` stays at `model: sonnet`.

## Test plan

- [x] `tests/run.sh` passes locally (covers the new structural tests and the unchanged Phase 2 test set).
- [x] One smoke trial each at Haiku/low (`--stream-json` on) and Sonnet/default (`--faithfulness-check` on, `--stream-json` off) passed.
- [x] 20-trial sweep at Haiku/low completed with `--stream-json`; result captured in the linked report.
- [ ] CI green.
```

Open the PR, replacing the existing #34 with one that targets `main` (or update an existing open PR if one is on this branch):

```bash
gh pr create \
    --title "feat(tests/ab): Phase 3.1 reframe — empty-stdout investigation (3.1a) + harness --stream-json" \
    --body-file "${CLAUDE_TEMP_DIR}/phase31a-pr-body.md"
```

If an existing PR is already on this branch (e.g. left over from the Phase 3.1 plan PR), use `gh pr edit <num> --body-file ...` instead.

- [ ] **Step 3: Watch CI green**

```bash
gh pr checks --watch
```

Expected: all checks green. If a check fails, fix locally, push the fixup, and let CI re-run.

- [ ] **Step 4: Operator-gated merge**

When the operator says "merge":

```bash
gh pr merge --squash --delete-branch
git checkout main
git pull --rebase origin main
```

---

## Task 8: Update auto-memory

Per the auto-memory protocol: 3.1a's verdict is concrete, dated, and load-bearing for every subsequent probe in the programme.

**Files:**
- Create: `~/.claude/projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/project_phase_3_1a_empty_stdout_investigation.md`
- Modify: `~/.claude/projects/-Users-jodre11--claude-plugins-marketplaces-jodre11-plugins/memory/MEMORY.md`
- Update existing: `project_orchestrator_empty_stdout_anomaly.md` (status flip)

These files are in the user's home directory, not the marketplace repo. Do not include them in this PR.

- [ ] **Step 1: Write the new memory file**

Create with content matching the actual verdict:

```markdown
---
name: phase-3-1a-empty-stdout-investigation
description: Phase 3.1a empty-stdout investigation — 20-trial Haiku/low sweep result; <bug confirmed at <p>% | bounded ≤ <p>% at 95% CI>; recommended fix surface
metadata:
  type: project
---

Phase 3.1a empty-stdout investigation result (recorded <YYYY-MM-DD>).
20-trial sweep at Haiku/low against `ruff-smoke-bad-py` on the per-agent
codepath, with `--output-format stream-json` enabled. EMPTY incidence:
<k>/20 = <p>% (Wilson 95% CI [<lo>%, <hi>%]). Trace category breakdown:
A=<n>, B=<n>, C=<n>, D=<n>.

**Verdict:** <Bug confirmed | Bounded but not reproduced at N=20 | Inconclusive>.

**Probable cause:** <one sentence>.

**Recommended fix surface:** <picked up by Phase 3.1c — cross-cutting
"tighten contracts + fail-loud" — not yet brainstormed>.

**Why:** Empty-stdout was the load-bearing apparatus problem blocking
every faithfulness check in Phase 3. Until characterised, no probe
verdict could distinguish "real divergence" from "noise". 3.1a's
forensic record is the noise floor that Phases 3.1b / 3.2 / 3.3 / 3.4
all inherit.

**How to apply:** When designing future probes (3.1b onwards), use the
upper bound of this CI to size the trial count. If the bug is bounded
< 5% at N=20, 3-trial faithfulness checks remain marginally usable; if
> 10%, plan for N≥10 trials per arm. The harness `--stream-json` flag
is the durable forensic-capture infrastructure introduced here.

**Related:**
[[phase-3-1-ruff-haiku-low-probe]] (the precipitating Phase 3.1 result),
[[orchestrator-empty-stdout-anomaly]] (now superseded; pointer flipped),
[[per-agent-harness-phase2-planning]] (the chassis 3.1a builds on),
[[models-overlook-tuning-hooks]] (variation-via-harness still applies).
```

- [ ] **Step 2: Add the index entry to `MEMORY.md`**

Append one line:

```markdown
- [Phase 3.1a empty-stdout investigation](project_phase_3_1a_empty_stdout_investigation.md) — 20-trial Haiku/low sweep; <verdict>; recommended fix surface for 3.1c
```

- [ ] **Step 3: Update the existing `project_orchestrator_empty_stdout_anomaly.md` memory entry**

Open the existing file. Update its description and body to flag the status flip:

```markdown
---
name: orchestrator-empty-stdout-anomaly
description: Orchestrator empty-stdout anomaly — Phase 1 Trial 2 + Phase 3.1 trial-003; investigated by [[phase-3-1a-empty-stdout-investigation]]
metadata:
  type: project
---

(existing body content preserved; append a status-flip note pointing at the
3.1a investigation record).
```

- [ ] **Step 4: No commit (memory dir is in `~/.claude/`, not this repo)**

The memory directory is committed in the user's `~/.claude` repo separately. Mention to the operator that they should commit and push the memory entries in `~/.claude` after this PR merges.

---

## Self-review

**Spec coverage check:**

| Spec section | Implementing task |
|---|---|
| Step 1 — `--output-format stream-json` plumbing | Tasks 1 (empirical grounding) + 2 (TDD plumbing) |
| Step 2 — 20-trial sweep | Task 3 |
| Step 3 — per-trial classification | Task 4 Step 1 |
| Step 4 — stream-json trace inspection | Task 4 Step 3 |
| Step 5 — probable cause hypothesis + report | Task 5 |
| Step 6 — update original anomaly spec | Task 6 |
| Verifications during implementation: empirical CLI flag grounding | Task 1 |
| Verifications during implementation: stdout-bit-identical when flag off | Task 2 Step 8 |
| Verifications during implementation: dirty-tree assertion behaviour | Important context point 3 |
| Cost expectations — ~50–100k tokens | Tasks 1 (~5k) + 2 (~5–8k smoke) + 3 (~50–100k sweep) |
| Outcome table mapping | Task 5 (report verdict cell) |
| Sequencing within programme | PR body (Task 7) |

**Out-of-scope items honoured (not in any task):**

- No production agent file edits.
- No new fixture / corpus entry / specialist config.
- No multi-arm sweep (all 20 trials are Haiku/low).
- No model/effort axis split.
- No end-to-end mode reproduction (per-agent substrate only).
- No structural-test-time empty-stdout assertion (3.1c).
- No orchestrator-level safety net (3.1c).

**Placeholder scan:** all `<placeholder>` strings in the report skeleton (Task 5 Step 2) and the memory entry (Task 8 Step 1) are filled-at-execution-time values — Tasks 5 / 8 explicitly check none survive.

**Type/identifier consistency check:**

- `_AB_STREAM_JSON` — declared in Task 2 Step 3, propagated through `_ab_run_per_agent` (Task 2 Step 3), forwarded to `agent_dispatch_run_trial` (Task 2 Step 4), forwarded to `launch_run_per_agent_trial` (Task 2 Step 5). Single source of truth.
- `--stream-json` — argv flag spelt identically in usage block, parser case, README implications (not modified here), structural test, smoke command, and 20-trial sweep command.
- `trial-NNN/stream.jsonl` — output path spelt identically across spec, plan, smoke command (Task 2 Step 7), classification loop (Task 4 Step 1), and trace inspection (Task 4 Step 3).
- `tests/ab/runs/<RUN_DIR_NAME>` — spec uses `<timestamp>-ruff-haiku-low`; plan uses the same shape; report skeleton substitutes the actual run directory name at execution time.

All consistent.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-empty-stdout-investigation-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration. Phase 3.1a has natural review checkpoints between Task 1 (empirical grounding), Task 2 (plumbing), and Task 3 (the live-fire sweep).
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
