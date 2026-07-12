#!/usr/bin/env bash
# tests/lib/test_ab_orchestration.sh — arm-toggle round-trip + harvest-locate gates.

_orch_lib() { echo "$REPO_ROOT/tests/ab/lib/orchestration.sh"; }

test_orch_apply_writes_expected_toml() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm panel 5 "$toml" )
    if grep -q 'review_mode = "panel"' "$toml" && grep -q 'panel_size = 5' "$toml" \
        && grep -q 'full_log = true' "$toml" && grep -q 'analysis_only = true' "$toml"; then
        pass "orch: apply writes review_mode/panel_size/full_log/analysis_only"
    else
        fail "orch: apply writes review_mode/panel_size/full_log/analysis_only" "$(cat "$toml")"
    fi
    rm -rf "$tmp"
}

test_orch_restore_removes_temp_when_no_prior() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm classic 3 "$toml"
      orchestration_restore_arm )
    if [[ ! -f "$toml" ]]; then
        pass "orch: restore removes temp file when no prior existed"
    else
        fail "orch: restore removes temp file when no prior existed" "file still present"
    fi
    rm -rf "$tmp"
}

test_orch_restore_reinstates_prior_file_byte_for_byte() {
    local tmp toml
    tmp=$(mktemp -d); toml="$tmp/code-review.toml"
    printf '[intent]\ndoc_paths = ["X.md"]\n' > "$toml"
    local before; before=$(shasum -a 256 "$toml" | awk '{print $1}')
    ( set -euo pipefail
      _AB_RUN_DIR="$tmp"; source "$(_orch_lib)"
      orchestration_apply_arm panel 3 "$toml"
      orchestration_restore_arm )
    local after; after=$(shasum -a 256 "$toml" | awk '{print $1}')
    assert_equals "$before" "$after" "orch: restore reinstates prior file byte-for-byte"
    rm -rf "$tmp"
}

test_orch_slug_and_ident_from_url() {
    local url="https://github.com/Jodre11/claude-code-plugins/pull/88"
    source "$(_orch_lib)"
    assert_equals "Jodre11-claude-code-plugins" "$(orchestration_slug_from_url "$url")" \
        "orch: slug is owner-name"
    assert_equals "pr-88" "$(orchestration_ident_from_url "$url")" "orch: ident is pr-N"
}

test_orch_harvest_locates_by_slug_ident_sha12() {
    local tmp logs trial
    tmp=$(mktemp -d); logs="$tmp/logs"; trial="$tmp/trial"
    mkdir -p "$logs/o-r" "$trial"
    printf '{"type":"meta","orchestration_mode":"panel"}\n{"type":"finding","tier":"consensus"}\n' \
        > "$logs/o-r/pr-88-0123456789ab.jsonl"
    printf '<!-- x -->\n## Review\n' > "$logs/o-r/pr-88-0123456789ab.md"
    source "$(_orch_lib)"
    orchestration_harvest "$trial" "$logs" "o-r" "pr-88" "0123456789abcdef0123456789abcdef01234567"
    if [[ -f "$trial/durable-log.jsonl" && -f "$trial/durable-log.md" ]]; then
        pass "orch: harvest copies jsonl+md by slug/ident/sha12"
    else
        fail "orch: harvest copies jsonl+md by slug/ident/sha12" "$(ls "$trial")"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_missing_jsonl_returns_nonzero() {
    local tmp logs trial rc
    tmp=$(mktemp -d); logs="$tmp/logs"; trial="$tmp/trial"
    mkdir -p "$logs/o-r" "$trial"
    source "$(_orch_lib)"
    set +e; orchestration_harvest "$trial" "$logs" "o-r" "pr-99" "abcabcabcabc000000000000000000000000abcd"; rc=$?; set -e
    assert_equals "1" "$rc" "orch: harvest returns 1 when jsonl missing"
    rm -rf "$tmp"
}

# --- journal-harvest fallback (issues #94/#95: Step 3.6 never runs under `claude -p`,
# so the durable log is harvested straight from review-core's Workflow journal) ---

# Build a fake trial dir + a projects-root wf journal for a given session id.
# $4 (optional) = the synthesiser bodyText; omit to simulate a torn-down-pre-synth run.
_orch_make_journal_fixture() {
    local projects_root="$1" session_id="$2" trial="$3" body="${4:-}"
    mkdir -p "$trial"
    printf '{"type":"result","session_id":"%s"}\n' "$session_id" > "$trial/stream.jsonl"
    local wf="$projects_root/some-cwd-slug/$session_id/subagents/workflows/wf_deadbeef-000"
    mkdir -p "$wf"
    {
        printf '{"type":"result","result":{"findings":[],"status":"ok"}}\n'
        printf '{"type":"result","result":{"raised":[],"votes":[]}}\n'
        if [[ -n "$body" ]]; then
            jq -cn --arg b "$body" '{type:"result",result:{bodyText:$b}}'
        fi
    } > "$wf/journal.jsonl"
}

test_orch_harvest_journal_extracts_synth_bodytext() {
    local tmp proj trial rc
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    _orch_make_journal_fixture "$proj" "sess-aaaa" "$trial" "## Review Summary
A real multi-finding report."
    source "$(_orch_lib)"
    set +e; orchestration_harvest_journal "$trial" "$proj"; rc=$?; set -e
    if [[ "$rc" == "0" ]] && grep -q 'Review Summary' "$trial/durable-log.md" \
        && [[ -f "$trial/durable-log.jsonl" ]]; then
        pass "orch: journal harvest extracts synth bodyText to durable-log.md + copies jsonl"
    else
        fail "orch: journal harvest extracts synth bodyText" "rc=$rc; $(ls "$trial" 2>&1)"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_journal_misses_when_pre_synth() {
    local tmp proj trial rc
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    # No bodyText → torn down before synthesis.
    _orch_make_journal_fixture "$proj" "sess-bbbb" "$trial"
    source "$(_orch_lib)"
    set +e; orchestration_harvest_journal "$trial" "$proj"; rc=$?; set -e
    if [[ "$rc" == "1" && ! -f "$trial/durable-log.md" ]]; then
        pass "orch: journal harvest returns 1 (no durable-log) when synth absent"
    else
        fail "orch: journal harvest pre-synth miss" "rc=$rc; md exists: $([[ -f "$trial/durable-log.md" ]] && echo yes || echo no)"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_journal_misses_when_no_session() {
    local tmp proj trial rc
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"; mkdir -p "$trial"
    # stream.jsonl with no result/session_id.
    printf '{"type":"system"}\n' > "$trial/stream.jsonl"
    source "$(_orch_lib)"
    set +e; orchestration_harvest_journal "$trial" "$proj"; rc=$?; set -e
    assert_equals "1" "$rc" "orch: journal harvest returns 1 when session_id unresolvable"
    rm -rf "$tmp"
}

test_orch_dispatcher_scaffolds_run_dir_and_records_corpus() {
    local tmp corpus
    tmp=$(mktemp -d); corpus="$tmp/corpus.yaml"
    cat > "$corpus" <<'YAML'
phase: pilot
prs:
  - url: https://github.com/Jodre11/claude-code-plugins/pull/88
    head_sha: a757f69000000000000000000000000000000000
    stratum: large/rc/hard
YAML
    local out
    out=$(_AB_ORCH_DRYRUN=1 CLAUDE_TEMP_DIR="$tmp" \
        bash "$REPO_ROOT/tests/ab/run.sh" --mode orchestration --corpus "$corpus" \
        --arms "classic panel:5" --trials 2 --phase pilot 2>&1 || true)
    # Dry-run prints the resolved run dir on the last "Run dir:" line.
    local run_dir; run_dir=$(printf '%s\n' "$out" | sed -n 's/.*Run dir:[[:space:]]*//p' | tail -1)
    if [[ -n "$run_dir" && -f "$run_dir/corpus.yaml" ]]; then
        pass "orch: dispatcher scaffolds run dir + copies corpus.yaml"
    else
        fail "orch: dispatcher scaffolds run dir + copies corpus.yaml" "$out"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_no_md_still_succeeds() {
    local tmp logs trial rc
    tmp=$(mktemp -d); logs="$tmp/logs"; trial="$tmp/trial"
    mkdir -p "$logs/o-r" "$trial"
    printf '{"type":"meta"}\n' > "$logs/o-r/pr-88-0123456789ab.jsonl"
    # no .md file
    source "$(_orch_lib)"
    orchestration_harvest "$trial" "$logs" "o-r" "pr-88" "0123456789abcdef0123456789abcdef01234567"
    rc=$?
    assert_equals "0" "$rc" "orch: harvest succeeds when md absent"
    if [[ -f "$trial/durable-log.jsonl" ]]; then
        pass "orch: harvest copies jsonl when md absent"
    else
        fail "orch: harvest copies jsonl when md absent" "durable-log.jsonl missing"
    fi
    if [[ ! -f "$trial/durable-log.md" ]]; then
        pass "orch: harvest does not create md when md absent"
    else
        fail "orch: harvest does not create md when md absent" "durable-log.md unexpectedly present"
    fi
    rm -rf "$tmp"
}

test_orch_criteria_mirrored_to_durable_location() {
    local tmp run anchor
    tmp=$(mktemp -d); run="$tmp/run"; mkdir -p "$run"
    printf 'catches real bugs > low FP\n' > "$run/criteria.md"
    ( set -euo pipefail
      _AB_RUN_DIR="$run"
      HOME="$tmp/home"; mkdir -p "$HOME"
      source "$REPO_ROOT/tests/ab/run.sh" 2>/dev/null || true
      _ab_orch_capture_criteria pilot 20260710T000000Z )
    anchor="$tmp/home/.claude/code-review-suite/ab-criteria/20260710T000000Z-pilot-criteria.md"
    if [[ -f "$anchor" ]]; then
        pass "orch: criteria mirrored to durable anchor location"
    else
        fail "orch: criteria mirrored to durable anchor location" "missing $anchor"
    fi
    rm -rf "$tmp"
}

test_orch_pilot_gate_auto_proceeds_on_stable_low_variance() {
    local tmp run
    tmp=$(mktemp -d); run="$tmp/run"
    # two arms, all runs agree → stability 1.0, no HARVEST_MISS.
    local arm i
    for arm in classic panel; do
        for i in 1 2 3; do
            local td; td=$(printf '%s/pr-1/%s/trial-%03d' "$run" "$arm" "$i"); mkdir -p "$td"
            printf 'REQUEST_CHANGES\n' > "$td/verdict.txt"
            printf '{"type":"meta","orchestration_mode":"%s"}\n' "$arm" > "$td/durable-log.jsonl"
        done
    done
    ( set -euo pipefail
      _AB_RUN_DIR="$run"; source "$REPO_ROOT/tests/ab/run.sh" 2>/dev/null || true
      _ab_orch_pilot_gate "$run" )
    if grep -q 'AUTO-PROCEED' "$run/pilot-gate.log"; then
        pass "orch: pilot gate auto-proceeds on stable low-variance pilot"
    else
        fail "orch: pilot gate auto-proceeds on stable low-variance pilot" "$(cat "$run/pilot-gate.log" 2>&1)"
    fi
    rm -rf "$tmp"
}

test_orch_pilot_gate_hard_stops_when_differential_fails() {
    local tmp run
    tmp=$(mktemp -d); run="$tmp/run"
    # Malformed durable-log.jsonl → differential.py's json.loads throws → non-zero
    # exit. The gate must still write a HARD-STOP log (its always-log guarantee),
    # not abort silently under set -e.
    #
    # The subshell runs `set -euo pipefail` WITHOUT a trailing `|| true` on the
    # gate call — bash disables set -e for a command on the left of `||`, which
    # would mask the very abort this test reproduces. We guard the harness with
    # an outer `set +e`/`set -e` around the subshell's exit-code capture instead.
    local arm i
    for arm in classic panel; do
        for i in 1 2 3; do
            local td; td=$(printf '%s/pr-1/%s/trial-%03d' "$run" "$arm" "$i"); mkdir -p "$td"
            printf 'REQUEST_CHANGES\n' > "$td/verdict.txt"
            printf '{not valid json\n' > "$td/durable-log.jsonl"
        done
    done
    set +e
    ( set -euo pipefail
      _AB_RUN_DIR="$run"; source "$REPO_ROOT/tests/ab/run.sh" 2>/dev/null || true
      _ab_orch_pilot_gate "$run" ) 2>/dev/null
    set -e
    if [[ -f "$run/pilot-gate.log" ]] && grep -q 'HARD-STOP' "$run/pilot-gate.log" \
        && grep -qi 'differential' "$run/pilot-gate.log"; then
        pass "orch: pilot gate writes HARD-STOP log when differential.py fails"
    else
        fail "orch: pilot gate writes HARD-STOP log when differential.py fails" \
            "$(cat "$run/pilot-gate.log" 2>&1 || echo 'pilot-gate.log missing')"
    fi
    rm -rf "$tmp"
}
