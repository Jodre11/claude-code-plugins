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
        && grep -q 'full_log = true' "$toml"; then
        pass "orch: apply writes review_mode/panel_size/full_log"
    else
        fail "orch: apply writes review_mode/panel_size/full_log" "$(cat "$toml")"
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
