# Phase 3.2b — PR B (clean re-probe + cost capture) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-measure `eslint-reviewer` at Haiku/low vs a re-established Sonnet/default baseline at symmetric n=20 on the apparatus-fixed harness, capturing the per-trial Bedrock cost delta (the programme's actual deliverable), and record a verdict + result note.

**Architecture:** Split into an OFFLINE half (Tasks 1–2: a sourceable cost-extraction helper added to `agent_capture.sh`, TDD'd against committed fixtures + verified against existing gitignored run dirs with zero new spend, then wired into `summary.csv`) and a LIVE half (Tasks 3–6: a gated Sonnet baseline re-capture + promotion, the 2×20 sweep, the verdict, and the result note). The OFFLINE/LIVE boundary is a hard operator gate — no live Bedrock spend happens until Tasks 1–2 are merged, pushed, and the operator approves.

**Tech Stack:** Bash (4-space indent, LF), `jq` for the `result`-envelope extraction, `yq` for YAML, the in-tree `tests/lib/harness.sh` assertion framework (`assert_equals`, `pass`, `fail`), the per-agent A/B harness (`tests/ab/run.sh --config <cfg> --corpus eslint-smoke-bad-js --trials 20 --stream-json`).

**Spec:** [`../specs/2026-06-02-phase-3-2b-eslint-apparatus-and-reprobe-design.md`](../specs/2026-06-02-phase-3-2b-eslint-apparatus-and-reprobe-design.md) (§"PR B — clean re-probe + result note", deliverables B1–B5).

**Predecessor:** PR A (apparatus fix) SHIPPED + verified 2026-06-03 (commits `7cb0ee6`…`fe321af`). Both apparatus confounds (install race + terminal-`.result` capture drop) are fixed. Test-suite baseline: **339 passed / 1 skipped**.

---

## House rules (apply to EVERY Bash call you and subagents issue)

- NO compound shell (`&&`, `||`, `;`), NO `$(...)`/backticks, NO pipes/subshells in a single Bash call — use separate Bash calls and pass output between them. A single `> file 2>&1` redirect is allowed; a lone `grep`/`jq`/`yq` with no pipe is allowed. Carve-out: `git commit` HEREDOC for literal multi-line bodies.
- 4-space shell indent, LF endings. Commit messages: NO Co-Authored-By, NO Claude advertising. `git add` specific paths only (never `-A` / `.`).
- **PUSH after every commit.** This is an autoUpdate-managed clone; a prior reclone wiped an unpushed branch. Direct-push to `main` is the established workflow (no PR required).
- Pass the resolved `CLAUDE_TEMP_DIR` literal into every subagent prompt; the SessionStart hook injects it into the parent's context but it is NOT exported into the Bash shell.

## Verified facts (confirmed against real data this session)

- `result`-envelope field names (confirmed against `tests/ab/runs/20260603T061349Z-eslint-haiku-low/trial-001/stream.jsonl`): `total_cost_usd`, `num_turns`, `usage.output_tokens`, `usage.cache_read_input_tokens`. trial-001 result row: `output_tokens=1667, num_turns=6, cache_read_input_tokens=158826, total_cost_usd=0.07827885`.
- The existing run dir `20260603T061349Z-eslint-haiku-low` predates the `fe321af` capture fix (trials 008/010 show the old false-zero findings), but its `stream.jsonl` result envelopes are intact and carry all four cost fields — usable as offline verification data with zero new spend.
- `run.sh` ends with `main "$@"`, so it is NOT sourceable. The cost-extraction logic must live in a sourceable lib (`agent_capture.sh`) to be unit-testable; `_ab_append_per_agent_summary_row` then calls it.
- Committed stream-jsonl fixtures live in `tests/ab/fixtures/stream-jsonl/`. Existing ones (`canonical-success.jsonl`, `no-terminal-event.jsonl`, etc.) carry MINIMAL result envelopes with NO cost fields — Task 1 adds a dedicated cost fixture.

---

## File structure

| File | Responsibility | Change |
|---|---|---|
| `tests/ab/fixtures/stream-jsonl/result-with-cost-fields.jsonl` | Offline fixture: a result envelope carrying all four cost fields | Create (Task 1) |
| `tests/ab/lib/agent_capture.sh` | Add sourceable `agent_capture_extract_cost_csv <stream_jsonl>` helper | Modify (Task 1) |
| `tests/lib/test_ab_per_agent_lib.sh` | Unit tests for the cost-extraction helper | Modify — append (Task 1) |
| `tests/ab/run.sh` | Extend `summary.csv` header + `_ab_append_per_agent_summary_row` with the four cost columns | Modify (Task 2) |
| `tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md` | Re-established Sonnet/default baseline report | Modify — promote new capture (Task 4) |
| `tests/ab/corpus/eslint-smoke-bad-js/source.yaml` | Bump `baseline_revision` + `captured_under.suite_sha` | Modify (Task 4) |
| `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md` | Result note: verdict + measured Bedrock cost-delta ratio | Create (Task 6) |
| `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md` | Add a supersession cross-link header | Modify (Task 6) |

**Ordering rationale:** Tasks 1–2 are pure offline plumbing (the cost-column extension), TDD'd and verifiable with zero spend. Task 3 is the HARD OPERATOR GATE. Task 4 (baseline re-capture + promotion) must precede Task 5 (the 2×20 sweep) because the sweep's faithfulness comparison is against the promoted baseline. Task 6 (verdict + note) consumes Task 5's `summary.csv` files.

---

## Task 1: Sourceable cost-extraction helper (OFFLINE — no spend)

**Files:**
- Create: `tests/ab/fixtures/stream-jsonl/result-with-cost-fields.jsonl`
- Modify: `tests/ab/lib/agent_capture.sh`
- Test: `tests/lib/test_ab_per_agent_lib.sh`

- [ ] **Step 1: Create the offline cost fixture**

Create `tests/ab/fixtures/stream-jsonl/result-with-cost-fields.jsonl`. Two lines: one assistant text event (so the file is a realistic mixed stream) and one terminal `result` event carrying all four cost fields. Field values chosen to be unambiguous and distinct so an off-by-one column slip is caught.

```jsonl
{"type":"assistant","message":{"content":[{"type":"text","text":"## ESLint Findings\n\n### Finding — no-var\n- **File:** bad.js:1\n- **Rule:** no-var (eslint)"}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":7,"total_cost_usd":0.0625,"usage":{"output_tokens":1234,"cache_read_input_tokens":98765}}
```

- [ ] **Step 2: Write the failing test for the extraction helper**

Append to `tests/lib/test_ab_per_agent_lib.sh`. The helper `agent_capture_extract_cost_csv <stream_jsonl>` must echo a 4-field CSV fragment in the column order `output_tokens,num_turns,cache_read_input_tokens,total_cost_usd`. When no `result` event exists, it must echo four empty fields (`,,,`) and still return 0 — a missing/truncated stream must not abort the summary row.

```bash
test_ab_cost_extract_present() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fix="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/result-with-cost-fields.jsonl"

    if [[ ! -f "$lib" || ! -f "$fix" ]]; then
        fail "A/B cost: lib + fixture present" "missing"
        return
    fi

    local out
    out=$(
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_extract_cost_csv "$fix"
    )

    assert_equals "1234,7,98765,0.0625" "$out" \
        "A/B cost: extract_cost_csv emits out_tok,turns,cache_read,cost in order"
}

test_ab_cost_extract_no_result_event() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fix="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/no-terminal-event.jsonl"

    if [[ ! -f "$lib" || ! -f "$fix" ]]; then
        fail "A/B cost: lib + no-terminal fixture present" "missing"
        return
    fi

    local out rc
    out=$(
        # shellcheck disable=SC1090
        source "$lib"
        set +e
        agent_capture_extract_cost_csv "$fix"
        echo "rc=$?" >&2
    ) 2>"$REPO_ROOT/.cost-rc.tmp"
    rc=$(grep -o 'rc=[0-9]*' "$REPO_ROOT/.cost-rc.tmp" | head -1)
    rm -f "$REPO_ROOT/.cost-rc.tmp"

    assert_equals ",,," "$out" \
        "A/B cost: extract_cost_csv emits four empty fields when no result event"
    assert_equals "rc=0" "$rc" \
        "A/B cost: extract_cost_csv returns 0 when no result event"
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/run.sh > /tmp/<CLAUDE_TEMP_DIR>/cost-fail.log 2>&1`
Run: `grep -E "extract_cost_csv" /tmp/<CLAUDE_TEMP_DIR>/cost-fail.log`
Expected: FAIL — `agent_capture_extract_cost_csv: command not found` (function not defined yet).

- [ ] **Step 4: Implement the helper in agent_capture.sh**

Add this function to `tests/ab/lib/agent_capture.sh`, after `agent_capture_compare_findings` (the last function in the file). It uses a single `jq -rs` slurp: take the LAST `result` event (robust to multiple), pull the four fields with `// ""` fallbacks so a missing field becomes an empty string rather than the literal `null`, and join into a CSV fragment. Column order is FIXED: `output_tokens,num_turns,cache_read_input_tokens,total_cost_usd`.

```bash
# Extract the four per-trial cost columns from a trial's stream.jsonl, as a
# CSV fragment in the order: output_tokens,num_turns,cache_read_input_tokens,
# total_cost_usd. Reads the LAST {type:"result"} event (robust to repeats).
# Emits four empty fields (",,,") and returns 0 when no result event exists,
# so a truncated/absent stream never aborts the summary row. The CC stream's
# total_cost_usd is Anthropic LIST price, not Bedrock — report the RATIO.
agent_capture_extract_cost_csv() {
    local stream_jsonl="$1"
    if [[ ! -s "$stream_jsonl" ]]; then
        echo ",,,"
        return 0
    fi
    jq -rs '
        (map(select(.type == "result")) | last) as $r
        | [ ($r.usage.output_tokens // ""),
            ($r.num_turns // ""),
            ($r.usage.cache_read_input_tokens // ""),
            ($r.total_cost_usd // "") ]
        | map(tostring) | join(",")
    ' "$stream_jsonl"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run.sh > /tmp/<CLAUDE_TEMP_DIR>/cost-pass.log 2>&1`
Run: `grep -E "extract_cost_csv" /tmp/<CLAUDE_TEMP_DIR>/cost-pass.log`
Expected: PASS for all four assertions (present-case, no-result-case value, no-result-case rc).

- [ ] **Step 6: Verify the helper against a REAL existing run dir (zero spend)**

This is the spec's "do not transcribe blind" check — prove the helper works on actual Bedrock output, not just the synthetic fixture.

Run: `bash -c 'source tests/ab/lib/agent_capture.sh; agent_capture_extract_cost_csv tests/ab/runs/20260603T061349Z-eslint-haiku-low/trial-001/stream.jsonl'`
Expected: `1667,6,158826,0.07827885000000001`

(Note: this single `bash -c` runs offline against a committed gitignored fixture dir and costs nothing. It is the one carve-out from the no-subshell rule needed to source-and-call in one shot for verification; if the operator's hook rejects it, split into a tiny temp script instead.)

- [ ] **Step 7: Run the full suite to confirm no regressions**

Run: `bash tests/run.sh > /tmp/<CLAUDE_TEMP_DIR>/cost-suite.log 2>&1`
Run: `tail -3 /tmp/<CLAUDE_TEMP_DIR>/cost-suite.log`
Expected: `343 passed, 1 skipped` (339 baseline + 4 new assertions).

- [ ] **Step 8: Commit and push**

```bash
git add tests/ab/lib/agent_capture.sh tests/ab/fixtures/stream-jsonl/result-with-cost-fields.jsonl tests/lib/test_ab_per_agent_lib.sh
```
```bash
git commit -m "$(cat <<'EOF'
feat(ab): add sourceable per-trial cost-extraction helper

agent_capture_extract_cost_csv pulls output_tokens, num_turns,
cache_read_input_tokens, total_cost_usd from a trial's stream.jsonl
result envelope as an ordered CSV fragment, degrading to empty fields
when no result event is present. Offline-tested against a synthetic
fixture and a real run dir; no Bedrock spend.
EOF
)"
```
```bash
git push
```

---

## Task 2: Wire the cost columns into summary.csv (OFFLINE — no spend)

**Files:**
- Modify: `tests/ab/run.sh` (the `summary.csv` header line ~262 and `_ab_append_per_agent_summary_row` ~499)

- [ ] **Step 1: Extend the summary.csv header**

In `tests/ab/run.sh`, the header write (currently line 262) is:

```bash
    echo "trial,exit_code,wall_clock_seconds,findings_count,findings_hash,first_finding_rule,inconclusive,timed_out" > "$summary"
```

Append the four cost columns (so existing `awk` column indices 1–8 used by `_ab_emit_completion_summary` are UNCHANGED — the new columns are 9–12):

```bash
    echo "trial,exit_code,wall_clock_seconds,findings_count,findings_hash,first_finding_rule,inconclusive,timed_out,output_tokens,num_turns,cache_read_input_tokens,total_cost_usd" > "$summary"
```

- [ ] **Step 2: Extend the row-append function**

In `_ab_append_per_agent_summary_row` (currently lines 499–519), after the `inconclusive` block and before the `printf`, add the cost extraction. The function already receives `$trial_dir`; the stream lives at `$trial_dir/stream.jsonl`:

```bash
    local cost_csv
    cost_csv=$(agent_capture_extract_cost_csv "$trial_dir/stream.jsonl")
```

Then change the `printf` to append `,%s` for the cost fragment (it is already comma-joined, so append it as a single `%s` preceded by a literal comma):

```bash
    printf '%d,%d,%d,%d,%s,%s,%s,%s,%s\n' \
        "$trial_num" "$rc" "$wall" "$findings_count" "$findings_hash" "$first_rule" "$inconclusive" "$timed_out" "$cost_csv" \
        >> "$_AB_RUN_DIR/summary.csv"
```

- [ ] **Step 3: Verify run.sh is syntactically valid**

Run: `bash -n tests/ab/run.sh`
Run: `echo "exit=$?"`
Expected: `exit=0` (no syntax errors).

- [ ] **Step 4: Confirm the completion-summary awk indices are unaffected**

`_ab_emit_completion_summary` uses `$2` (exit_code), `$7` (timed_out), `$3` (wall). WAIT — verify: the OLD header has `timed_out` at column 8, but the awk on line 530 reads `$7=="true"` for timeouts. Read the current code to confirm which column `timed_out` truly occupies BEFORE appending, so the new columns don't shift a field the awk depends on.

Run: `grep -n 'awk -F,' tests/ab/run.sh`
Then read each matched line and confirm every column index it references (`$2`, `$3`, `$7`, etc.) still points at the same field after the header extension. The cost columns are appended at the END (positions 9–12), so indices 1–8 are preserved — but VERIFY, because if `_ab_emit_completion_summary` already had an index bug or referenced column 8, appending must not mask it. Record the finding; if an index is now wrong, fix it in this task.

- [ ] **Step 5: Offline end-to-end check of the row format using a real trial dir**

The harness can't run a trial offline, but the row-append logic can be exercised directly. Write a tiny throwaway harness that sources the libs, points `_AB_RUN_DIR` at a temp dir, seeds a fake `timing.json`/`findings.json`/`findings_hash.txt` plus a real `stream.jsonl`, and calls `_ab_append_per_agent_summary_row`. Confirm the emitted row has 12 comma-separated fields with the cost values populated.

Because `run.sh` is not sourceable (`main "$@"` at EOF), copy the two edited functions is NOT the approach — instead verify by inspection in Step 4 plus a real sweep in Task 5. Mark this step satisfied by Step 4's index audit + Task 5's live `summary.csv` inspection. (No separate offline harness needed; documenting the decision here so the executor doesn't build a sourceable shim for `run.sh`.)

- [ ] **Step 6: Run the full suite (no new assertions, but confirm no breakage)**

Run: `bash tests/run.sh > /tmp/<CLAUDE_TEMP_DIR>/wire-suite.log 2>&1`
Run: `tail -3 /tmp/<CLAUDE_TEMP_DIR>/wire-suite.log`
Expected: `343 passed, 1 skipped` (unchanged from Task 1 — this task adds no unit tests, only wiring).

- [ ] **Step 7: Commit and push**

```bash
git add tests/ab/run.sh
```
```bash
git commit -m "$(cat <<'EOF'
feat(ab): emit per-trial cost columns in summary.csv

Extend the per-agent summary.csv with output_tokens, num_turns,
cache_read_input_tokens, total_cost_usd (columns 9-12, appended so the
existing completion-summary awk indices are preserved). The cost delta
is the Phase 3 programme's actual deliverable, omitted by Phase 3.2.
EOF
)"
```
```bash
git push
```

---

## Task 3: HARD OPERATOR GATE — stop before any live spend

- [ ] **Step 1: Confirm the offline half is complete, pushed, and green**

Run: `git log --oneline -3`
Expected: the Task 1 and Task 2 commits are present and pushed (`git status` clean, branch up to date with origin).

Run: `git status --short`
Expected: clean (the preflight `_ab_preflight_clean_tree` refuses to start a sweep on a dirty tree).

- [ ] **Step 2: Present the live-spend estimate and STOP**

Report to the operator, verbatim shape:

> Offline half (Tasks 1–2) shipped and pushed: cost-extraction helper + summary.csv columns, suite 343/1. The remaining work spends real Bedrock:
> - **B1 baseline re-capture:** 1 Sonnet/default trial (~$0.16 list).
> - **B2 sweep:** 20 Sonnet/default + 20 Haiku/low = 40 trials (≈ 3× a single-arm sweep).
> Total ≈ 41 trials. Proceed?

Do NOT run Task 4, 5, or 6 until the operator gives explicit go-ahead. This is the spec's CRITICAL GATE.

---

## Task 4: Re-establish the Sonnet/default baseline (LIVE — gated)

**Files:**
- Modify: `tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md`
- Modify: `tests/ab/corpus/eslint-smoke-bad-js/source.yaml`

Runs only after Task 3's operator go-ahead.

- [ ] **Step 1: Capture one Sonnet/default trial on the fixed harness**

Run: `bash tests/ab/run.sh --config tests/ab/configs/per-agent/eslint-baseline.yaml --corpus eslint-smoke-bad-js --trials 1 --stream-json`
Expected: 1 trial completes, exit 0, a new run dir under `tests/ab/runs/`. Note its timestamp.

- [ ] **Step 2: Hand-verify the captured report against eslint --format=json**

The fixture's `bad.js` has four rule violations on lines 1/2/3/6 (no-var, prefer-const, no-unused-vars, eqeqeq). Confirm the captured `agent-output.md`:
1. conforms to §7 (four `### Finding —` blocks, each with File/Confidence/Severity/Rule/Description/Suggested fix);
2. covers all four rules on the correct lines;
3. fabricates NONE (no finding outside lines 1/2/3/6, no invented rule).

Run: `cat tests/ab/runs/<new-run-dir>/trial-001/agent-output.md`
Then read the fixture to cross-check the four expected rules:
Run: `cat tests/fixtures/static-analysis/eslint/bad.js`
Expected: exactly four findings, one per rule, matching the lines above. If the capture drifts (missing rule, fabrication, §7 malformation), do NOT promote it — re-capture once; if it drifts again, STOP and bring it to the operator (a baseline that won't reproduce is itself a finding).

- [ ] **Step 3: Promote the verified capture to the expected baseline**

Run: `cp tests/ab/runs/<new-run-dir>/trial-001/agent-output.md tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md`

(The corpus stores the markdown; `run.sh` regenerates `expected/findings.json` from it on the next faithfulness run. Confirm the markdown is the agent's verbatim report, not a hand-edit.)

- [ ] **Step 4: Bump baseline_revision and suite_sha in source.yaml**

In `tests/ab/corpus/eslint-smoke-bad-js/source.yaml`:
- bump `baseline_revision: 1` → `baseline_revision: 2`;
- set `captured_under.suite_sha` to the current HEAD sha of THIS repo at capture time.

Run: `git rev-parse HEAD`
Then edit `source.yaml`: set `suite_sha` to that value, and `baseline_revision: 2`.

- [ ] **Step 5: Regenerate and sanity-check the derived findings.json**

Delete the stale derived baseline so the next run regenerates it from the new markdown:
Run: `rm -f tests/ab/corpus/eslint-smoke-bad-js/expected/findings.json`

(It will be regenerated by the faithfulness path in Task 5. Alternatively regenerate now via the synth-dir path; the Task 5 sweep does it idempotently.)

- [ ] **Step 6: Commit and push**

```bash
git add tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md tests/ab/corpus/eslint-smoke-bad-js/source.yaml tests/ab/corpus/eslint-smoke-bad-js/expected/findings.json
git commit -m "$(cat <<'EOF'
test(ab): re-establish eslint Sonnet/default baseline on fixed harness

Discard the Phase 3.2 n=3 baseline (captured on the contaminated
apparatus) and promote a fresh Sonnet/default capture from the
apparatus-fixed harness. Bump baseline_revision to 2 and record the
capturing suite_sha.
EOF
)"
```
```bash
git push
```

(If `findings.json` was removed rather than regenerated, drop it from the `git add` list — add only the files that exist.)

---

## Task 5: Run both arms at n=20 (LIVE — gated)

**Files:** none modified (produces gitignored run dirs under `tests/ab/runs/`).

- [ ] **Step 1: Sweep the Sonnet/default arm at n=20**

Run: `bash tests/ab/run.sh --config tests/ab/configs/per-agent/eslint-baseline.yaml --corpus eslint-smoke-bad-js --trials 20 --stream-json`
Expected: 20 trials complete. Note the run-dir timestamp. Confirm `summary.csv` now carries the 12-column header including the four cost fields.

Run: `head -1 tests/ab/runs/<sonnet-run-dir>/summary.csv`
Expected: header ends with `...,timed_out,output_tokens,num_turns,cache_read_input_tokens,total_cost_usd`.

- [ ] **Step 2: Sweep the Haiku/low arm at n=20**

Run: `bash tests/ab/run.sh --config tests/ab/configs/per-agent/eslint-haiku-low.yaml --corpus eslint-smoke-bad-js --trials 20 --stream-json`
Expected: 20 trials complete. Note the run-dir timestamp.

- [ ] **Step 3: Confirm zero binary-missing skips in both arms**

Run: `grep -rl "not available on PATH or in node_modules" tests/ab/runs/<sonnet-run-dir>/`
Run: `grep -rl "not available on PATH or in node_modules" tests/ab/runs/<haiku-run-dir>/`
Expected: no matches in either arm (the apparatus fix holds; contrast Phase 3.2's spurious skips).

- [ ] **Step 4: Confirm no false-zero capture drops**

The `fe321af` capture fix should mean every successful trial that emitted a report has it captured. Check for any `findings_count==0` rows that are NOT genuine skips:

Run: `awk -F, 'NR>1 && $4==0 {print $1}' tests/ab/runs/<haiku-run-dir>/summary.csv`
For each zero-row (if any), inspect its `stream.jsonl` to confirm whether the report was genuinely absent (real divergence) or present-but-dropped (capture regression — should NOT happen post-`fe321af`). Record the finding.

---

## Task 6: Verdict + result note (offline analysis of Task 5 output)

**Files:**
- Create: `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md`
- Modify: `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md` (supersession header)

- [ ] **Step 1: Compute the canonical-hash distribution per arm**

Run: `awk -F, 'NR>1 {print $5}' tests/ab/runs/<sonnet-run-dir>/summary.csv | sort | uniq -c`
Run: `awk -F, 'NR>1 {print $5}' tests/ab/runs/<haiku-run-dir>/summary.csv | sort | uniq -c`

(These two `awk | sort | uniq` pipelines are read-only analysis of local CSV — if the no-pipe hook rejects them, run `awk` to a temp file, then `sort`/`uniq` as separate calls.)

Apply the B4 verdict framework (spec, verbatim):
- Both arms 20/20 identical canonical hash → **EQUIVALENT**.
- Mixed within-arm hashes → **INCONCLUSIVE** (decision-4), then characterise the residual.
- >25% NORMAL-rate movement → **WORSE**, with recall-direction analysis (misses vs fabrications).

- [ ] **Step 2: Compute the cost-delta ratio**

Mean `total_cost_usd` (column 12) and mean `num_turns` (column 10) per arm:

Run: `awk -F, 'NR>1 {c+=$12; t+=$10; n++} END {printf "mean_cost=%.5f mean_turns=%.2f n=%d\n", c/n, t/n, n}' tests/ab/runs/<sonnet-run-dir>/summary.csv`
Run: `awk -F, 'NR>1 {c+=$12; t+=$10; n++} END {printf "mean_cost=%.5f mean_turns=%.2f n=%d\n", c/n, t/n, n}' tests/ab/runs/<haiku-run-dir>/summary.csv`

Compute the ratio `sonnet_mean_cost / haiku_mean_cost`. **Report the RATIO, not the absolute dollars** — the CC stream's `total_cost_usd` is Anthropic LIST price, not Bedrock. State this caveat explicitly in the note.

- [ ] **Step 3: Write the result note**

Create `docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md` with:
- Header: date, status, what it supersedes (cross-link the 3.2 note, do not delete it), parent programme + spec links.
- The arm matrix actually run (2 × n=20, fixed harness).
- The verdict (from Step 1) with the hash distributions as evidence.
- The measured cost-delta RATIO + the list-price caveat (from Step 2), plus the turn-count observation (cost is dominated by turns × cached context, per the spec's existing finding).
- If a residual agent-side tail survived (e.g. a §7 drop on the clean apparatus), characterise it (what drifted, on which trials, misses vs fabrications) and flag it as the PR C candidate — but do NOT author a fix (PR C is operator-gated; see the tuning-to-the-test guard).
- A "no PR C unless a real tail survived" line stating the gate explicitly.

- [ ] **Step 4: Add the supersession cross-link to the 3.2 note**

In `docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md`, add a header note near the top: "**Superseded by** [the 3.2b re-probe result](2026-06-02-eslint-haiku-low-reprobe-result.md) — the 3.2 inconclusive verdict was largely an apparatus confound; see PR A." Do not delete the 3.2 note.

- [ ] **Step 5: Commit and push**

```bash
git add docs/superpowers/notes/2026-06-02-eslint-haiku-low-reprobe-result.md docs/superpowers/notes/2026-06-02-eslint-haiku-low-result.md
git commit -m "$(cat <<'EOF'
docs(ab): Phase 3.2b PR B re-probe result + cost-delta

Record the clean n=20 vs n=20 eslint Haiku/low cost-tuning verdict on
the apparatus-fixed harness, with the measured Bedrock cost-delta ratio
(list-price caveat noted). Supersedes the Phase 3.2 inconclusive note.
EOF
)"
```
```bash
git push
```

- [ ] **Step 6: Update memory**

Update the jodre11-plugins memory dir in `~/.claude`:
- Add/refresh a memory recording the PR B verdict + cost-delta ratio and whether a PR C tail survived.
- Update `MEMORY.md` index.
- Commit + push the scoped memory files to `~/.claude` (specific paths only).

---

## Self-review

**Spec coverage (PR B scope, B1–B5):**
- §B1 re-establish Sonnet baseline, hand-verify, promote, bump revision/suite_sha → Task 4 ✓
- §B2 both arms n=20 → Task 5 ✓
- §B3 per-trial cost columns (output_tokens, num_turns, cache_read_input_tokens, total_cost_usd) → Tasks 1–2 ✓
- §B4 verdict framework (equivalent / inconclusive / worse) → Task 6 Step 1 ✓
- §B5 result note + Bedrock cost-delta ratio + memory update → Task 6 ✓
- §Verifications "don't transcribe cost-field names blind" → Task 1 Step 6 (verify against real run dir) ✓
- §CRITICAL GATE "all offline work first, then STOP for go-ahead" → Tasks 1–2 offline, Task 3 hard gate ✓
- §Tuning-to-the-test guard "no *-reviewer.md or config model/effort edit; PR C gated" → no task touches an agent body or config model/effort; Task 6 Step 3 explicitly defers PR C ✓

**Placeholder scan:** The only `<placeholder>` tokens are `<new-run-dir>`, `<sonnet-run-dir>`, `<haiku-run-dir>` (runtime-generated timestamps the executor substitutes) and `<CLAUDE_TEMP_DIR>` (the session temp dir literal). No TBD/TODO; every code step shows the exact code and every run step shows the command + expected output.

**Type/name consistency:** The helper `agent_capture_extract_cost_csv` is defined in Task 1 Step 4, tested in Task 1 Step 2, and called in Task 2 Step 2 — same name throughout. Column order `output_tokens,num_turns,cache_read_input_tokens,total_cost_usd` is identical in the fixture (Task 1 Step 1), the helper jq (Task 1 Step 4), the header (Task 2 Step 1), and the analysis awk indices `$10`/`$12` (Task 6) — columns 9/10/11/12 map to output_tokens/num_turns/cache_read/total_cost. Verified consistent.

**Scope guard:** No task edits any `*-reviewer.md` body or any config `model`/`effort` field. Tasks 1–2 are harness plumbing; Task 4 touches only corpus baseline + metadata; Task 6 is docs + memory. PR C is explicitly deferred and operator-gated.
