#!/usr/bin/env bash
# durable-log-gate.sh — Stop-hook forcing function for the durable full log.
# Arms off a session-scoped breadcrumb the host writes in Step 3.6; if a review
# in THIS session intended a durable log but the expected file is absent, block
# turn-end with an executable corrective instruction. Inert on every non-review
# turn. Session-scoped via the stdin session_id (reconstructs /tmp/claude-<sid>/),
# so a foreign or stranded breadcrumb from another session is structurally
# invisible. Self-expiring via a breadcrumb-mtime TTL so a dead session cannot
# wedge a live one. CLAUDE_TEMP_DIR is NOT exported into hook subprocesses — the
# session id from stdin is the only session anchor available (same lesson as
# reviewer-dispatch-observe.sh falling back to $TMPDIR).
set -euo pipefail

TTL_MINUTES="${DURABLE_LOG_GATE_TTL_MINUTES:-360}"
LOGS_DIR="${DURABLE_LOG_DIR:-$HOME/.claude/code-review-suite/logs}"
TMP_BASE="${DURABLE_LOG_TMP_BASE:-/tmp}"

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)"
[[ -n "$session_id" ]] || exit 0        # no session id -> cannot scope -> inert

marker="$TMP_BASE/claude-$session_id/durable-log-expected.json"
[[ -f "$marker" ]] || exit 0            # no breadcrumb -> inert (the common case)

# Self-expiry: a marker older than the TTL is a crashed/abandoned session.
if find "$marker" -mmin "+$TTL_MINUTES" 2>/dev/null | grep -q .; then
    exit 0
fi

repo_slug="$(jq -r '.repo_slug // ""' "$marker" 2>/dev/null || true)"
ident="$(jq -r '.ident // ""' "$marker" 2>/dev/null || true)"
sha="$(jq -r '.sha // ""' "$marker" 2>/dev/null || true)"
if [[ -z "$repo_slug" || -z "$ident" || -z "$sha" ]]; then
    exit 0                              # malformed/foreign marker -> treat as absent
fi

expected_md="$LOGS_DIR/$repo_slug/$ident-$sha.md"
if [[ -f "$expected_md" ]]; then
    exit 0                              # the write happened -> disarmed
fi

reason="Durable full log NOT written for ${repo_slug}/${ident}-${sha}. A review ran this session with orchestration.full_log enabled, but ${expected_md} is missing. Complete Step 3.6: run bin/durable-log-write with the resolved --repo-slug/--ident/--sha and --payload \$CLAUDE_TEMP_DIR/bundle-log.json. If the write keeps failing, fix the cause or remove the breadcrumb at ${marker} to abandon this log."
jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
