#!/usr/bin/env bash
# Unit tests for hooks/durable-log-gate.sh — the durable-log Stop-hook gate.

_dlg_hook() { echo "$REPO_ROOT/plugins/code-review-suite/hooks/durable-log-gate.sh"; }

# Build a session temp base with a marker for session $sid. Args:
#   $1 tmp_base  $2 sid  $3 repo_slug  $4 ident  $5 sha
_dlg_write_marker() {
    local tmp_base="$1" sid="$2" repo_slug="$3" ident="$4" sha="$5" mdir
    mdir="$tmp_base/claude-$sid"
    mkdir -p "$mdir"
    jq -cn --arg r "$repo_slug" --arg i "$ident" --arg s "$sha" \
        '{repo_slug:$r, ident:$i, sha:$s, ts:"2026-07-09T00:00:00Z"}' \
        > "$mdir/durable-log-expected.json"
    echo "$mdir/durable-log-expected.json"
}

# Run the hook with a given session_id; sets globals DLG_RC and DLG_OUT.
_dlg_run() {
    local sid="$1" tmp_base="$2" logs_dir="$3" ttl="${4:-360}" tmpf
    tmpf=$(mktemp)
    set +e
    printf '{"session_id":"%s","hook_event_name":"Stop"}' "$sid" \
        | DURABLE_LOG_TMP_BASE="$tmp_base" DURABLE_LOG_DIR="$logs_dir" \
          DURABLE_LOG_GATE_TTL_MINUTES="$ttl" bash "$(_dlg_hook)" > "$tmpf" 2>/dev/null
    DLG_RC=$?
    set -e
    DLG_OUT="$(cat "$tmpf")"
    rm -f "$tmpf"
}

test_dlg_no_breadcrumb_inert() {
    local tmp_base logs
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_run "sid-none" "$tmp_base" "$logs"
    assert_equals "0" "$DLG_RC" "durable-log-gate: no breadcrumb -> exit 0"
    assert_equals "" "$DLG_OUT" "durable-log-gate: no breadcrumb -> no block output"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_breadcrumb_no_log_blocks() {
    local tmp_base logs
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab" >/dev/null
    _dlg_run "sid-a" "$tmp_base" "$logs"
    assert_equals "0" "$DLG_RC" "durable-log-gate: block path still exits 0 (block via stdout JSON)"
    assert_equals "block" "$(printf '%s' "$DLG_OUT" | jq -r '.decision')" \
        "durable-log-gate: breadcrumb present + log absent -> decision block"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_breadcrumb_with_log_passes() {
    local tmp_base logs
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab" >/dev/null
    mkdir -p "$logs/o-r"
    printf 'x\n' > "$logs/o-r/pr-1-0123456789ab.md"
    _dlg_run "sid-a" "$tmp_base" "$logs"
    assert_equals "0" "$DLG_RC" "durable-log-gate: log present -> exit 0"
    assert_equals "" "$DLG_OUT" "durable-log-gate: log present -> no block (disarmed by log existence)"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_foreign_session_invisible() {
    # Marker exists for sid-a; hook runs as sid-b -> reconstructs sid-b's dir,
    # finds no marker -> inert. Proves session-scoping kills the cross-session
    # false-block landmine.
    local tmp_base logs
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    _dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab" >/dev/null
    _dlg_run "sid-b" "$tmp_base" "$logs"
    assert_equals "0" "$DLG_RC" "durable-log-gate: foreign session's breadcrumb is invisible -> exit 0"
    assert_equals "" "$DLG_OUT" "durable-log-gate: foreign session -> no block"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_stale_breadcrumb_expires() {
    local tmp_base logs marker
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    marker=$(_dlg_write_marker "$tmp_base" "sid-a" "o-r" "pr-1" "0123456789ab")
    # Age the marker 10 minutes; run with a 1-minute TTL -> treated as absent.
    touch -t "$(date -v-600S +%Y%m%d%H%M.%S 2>/dev/null || date -d '-600 seconds' +%Y%m%d%H%M.%S)" "$marker"
    _dlg_run "sid-a" "$tmp_base" "$logs" 1
    assert_equals "0" "$DLG_RC" "durable-log-gate: stale breadcrumb (past TTL) -> exit 0"
    assert_equals "" "$DLG_OUT" "durable-log-gate: stale breadcrumb -> no block (self-expiry)"
    rm -rf "$tmp_base" "$logs"
}

test_dlg_no_session_id_inert() {
    local tmpf
    tmpf=$(mktemp)
    set +e
    printf '{"hook_event_name":"Stop"}' \
        | bash "$(_dlg_hook)" > "$tmpf" 2>/dev/null
    DLG_RC=$?
    set -e
    DLG_OUT="$(cat "$tmpf")"
    rm -f "$tmpf"
    assert_equals "0" "$DLG_RC" "durable-log-gate: missing session_id -> exit 0 (cannot scope)"
    assert_equals "" "$DLG_OUT" "durable-log-gate: missing session_id -> no block"
}

test_dlg_malformed_stdin_inert() {
    local tmpf
    tmpf=$(mktemp)
    set +e
    printf 'not json {' \
        | bash "$(_dlg_hook)" > "$tmpf" 2>/dev/null
    DLG_RC=$?
    set -e
    DLG_OUT="$(cat "$tmpf")"
    rm -f "$tmpf"
    assert_equals "0" "$DLG_RC" "durable-log-gate: malformed stdin -> exit 0 (inert, not crash)"
    assert_equals "" "$DLG_OUT" "durable-log-gate: malformed stdin -> no block output"
}

test_dlg_malformed_marker_inert() {
    local tmp_base logs mdir
    tmp_base=$(mktemp -d); logs=$(mktemp -d)
    mdir="$tmp_base/claude-sid-c"
    mkdir -p "$mdir"
    printf 'not-json' > "$mdir/durable-log-expected.json"
    _dlg_run "sid-c" "$tmp_base" "$logs"
    assert_equals "0" "$DLG_RC" "durable-log-gate: malformed marker -> exit 0 (treat as absent)"
    assert_equals "" "$DLG_OUT" "durable-log-gate: malformed marker -> no block"
    rm -rf "$tmp_base" "$logs"
}
