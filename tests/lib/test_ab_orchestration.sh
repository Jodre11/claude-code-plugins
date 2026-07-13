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
# $5 (optional) = "system-only" to write a stream carrying session_id ONLY on system
# events (no terminal result event) — the timed-out/killed `claude -p` shape.
# $6 (optional) = the synthesiser verdict (APPROVE|REQUEST_CHANGES|INCONCLUSIVE) carried
# on the SAME synth result record as bodyText — mirrors the live schema. Omit to leave
# the record verdict-less (older captures / pre-verdict journals).
_orch_make_journal_fixture() {
    local projects_root="$1" session_id="$2" trial="$3" body="${4:-}" stream_shape="${5:-with-result}" verdict="${6:-}"
    mkdir -p "$trial"
    if [[ "$stream_shape" == "system-only" ]]; then
        printf '{"type":"system","subtype":"init","session_id":"%s"}\n{"type":"assistant","session_id":"%s"}\n' \
            "$session_id" "$session_id" > "$trial/stream.jsonl"
    else
        printf '{"type":"system","subtype":"init","session_id":"%s"}\n{"type":"result","session_id":"%s"}\n' \
            "$session_id" "$session_id" > "$trial/stream.jsonl"
    fi
    local wf="$projects_root/some-cwd-slug/$session_id/subagents/workflows/wf_deadbeef-000"
    mkdir -p "$wf"
    {
        printf '{"type":"result","result":{"findings":[],"status":"ok"}}\n'
        printf '{"type":"result","result":{"raised":[],"votes":[]}}\n'
        if [[ -n "$body" ]]; then
            if [[ -n "$verdict" ]]; then
                jq -cn --arg b "$body" --arg v "$verdict" '{type:"result",result:{verdict:$v,bodyText:$b}}'
            else
                jq -cn --arg b "$body" '{type:"result",result:{bodyText:$b}}'
            fi
        fi
    } > "$wf/journal.jsonl"
}

test_orch_session_id_reads_from_any_event() {
    local tmp proj trial sid
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    # system-only stream = timed-out `claude -p` (no terminal result event). The old
    # result-only reader returned nothing here and fell through to a stale on-disk log.
    _orch_make_journal_fixture "$proj" "sess-timeout" "$trial" "x" "system-only"
    source "$(_orch_lib)"
    sid=$(orchestration_session_id_from_stream "$trial/stream.jsonl" || true)
    assert_equals "sess-timeout" "$sid" "orch: session id resolves from system event when result absent"
    rm -rf "$tmp"
}

test_orch_locate_journal_finds_wf_by_session() {
    local tmp proj trial found
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    _orch_make_journal_fixture "$proj" "sess-loc" "$trial" "x"
    source "$(_orch_lib)"
    found=$(orchestration_locate_journal "sess-loc" "$proj" || true)
    if [[ -n "$found" && -f "$found" ]]; then
        pass "orch: locate_journal finds the wf journal by session id"
    else
        fail "orch: locate_journal finds the wf journal by session id" "got '$found'"
    fi
    rm -rf "$tmp"
}

test_orch_journal_has_synth_predicate() {
    local tmp proj trial_yes trial_no rc_yes rc_no jy jn
    tmp=$(mktemp -d); proj="$tmp/projects"
    trial_yes="$tmp/y"; trial_no="$tmp/n"
    _orch_make_journal_fixture "$proj" "sess-yes" "$trial_yes" "## Report"
    _orch_make_journal_fixture "$proj" "sess-no"  "$trial_no"           # no bodyText
    source "$(_orch_lib)"
    jy=$(orchestration_locate_journal "sess-yes" "$proj")
    jn=$(orchestration_locate_journal "sess-no" "$proj")
    set +e; orchestration_journal_has_synth "$jy"; rc_yes=$?; orchestration_journal_has_synth "$jn"; rc_no=$?; set -e
    if [[ "$rc_yes" == "0" && "$rc_no" != "0" ]]; then
        pass "orch: journal_has_synth true iff a synthesiser bodyText result exists"
    else
        fail "orch: journal_has_synth predicate" "rc_yes=$rc_yes rc_no=$rc_no"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_journal_survives_timeout_stream() {
    local tmp proj trial rc
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    # Timed-out stream (system-only) BUT synth landed in the journal — the harvester
    # must still recover it via the any-event session-id reader.
    _orch_make_journal_fixture "$proj" "sess-to" "$trial" "## Recovered report" "system-only"
    source "$(_orch_lib)"
    set +e; orchestration_harvest_journal "$trial" "$proj"; rc=$?; set -e
    if [[ "$rc" == "0" ]] && grep -q 'Recovered report' "$trial/durable-log.md"; then
        pass "orch: journal harvest recovers report even when stream is timeout-shaped"
    else
        fail "orch: journal harvest timeout-stream recovery" "rc=$rc"
    fi
    rm -rf "$tmp"
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

test_orch_harvest_journal_writes_authoritative_verdict() {
    local tmp proj trial rc
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    _orch_make_journal_fixture "$proj" "sess-verdict" "$trial" "## Report" "with-result" "REQUEST_CHANGES"
    # capture.sh runs BEFORE harvest and, under `claude -p`, the synth report never
    # reaches parent stdout — so verdict.txt gets the INCONCLUSIVE placeholder. Harvest
    # must overwrite it with the authoritative verdict from the journal result record.
    printf 'INCONCLUSIVE\n' > "$trial/verdict.txt"
    source "$(_orch_lib)"
    set +e; orchestration_harvest_journal "$trial" "$proj"; rc=$?; set -e
    if [[ "$rc" == "0" ]] && [[ "$(cat "$trial/verdict.txt")" == "REQUEST_CHANGES" ]]; then
        pass "orch: journal harvest overwrites verdict.txt with authoritative journal verdict"
    else
        fail "orch: journal harvest writes authoritative verdict" \
            "rc=$rc; verdict.txt='$(cat "$trial/verdict.txt" 2>&1)'"
    fi
    rm -rf "$tmp"
}

test_orch_harvest_journal_leaves_verdict_when_journal_verdictless() {
    local tmp proj trial rc
    tmp=$(mktemp -d); proj="$tmp/projects"; trial="$tmp/trial"
    # Older journals carry bodyText but no verdict field — harvest must not clobber the
    # capture-time verdict.txt with an empty/garbage value.
    _orch_make_journal_fixture "$proj" "sess-noverdict" "$trial" "## Report"
    printf 'APPROVE\n' > "$trial/verdict.txt"
    source "$(_orch_lib)"
    set +e; orchestration_harvest_journal "$trial" "$proj"; rc=$?; set -e
    if [[ "$rc" == "0" ]] && [[ "$(cat "$trial/verdict.txt")" == "APPROVE" ]]; then
        pass "orch: journal harvest preserves verdict.txt when journal carries no verdict"
    else
        fail "orch: journal harvest preserves verdict when verdictless" \
            "rc=$rc; verdict.txt='$(cat "$trial/verdict.txt" 2>&1)'"
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
