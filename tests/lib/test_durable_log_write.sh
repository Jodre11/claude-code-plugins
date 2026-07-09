#!/usr/bin/env bash
# Unit tests for bin/durable-log-write — the deterministic durable-log writer.

_dlw_bin() { echo "$REPO_ROOT/plugins/code-review-suite/bin/durable-log-write"; }

# Build a payload fixture: "full" = meta + cogs + findings (normal PR/local path);
# "nocogs" = bodyText + findings only, no meta/cogs. The nocogs shape is what the
# FINALIZE / stall-recovery route emits (review-core.mjs:136 passes phaseLog=null →
# buildLogPayload returns {bodyText, findings}). NOTE: the true "lightweight" route
# (buildLightweightBundle) returns NO `log` key at all, so Step 3.6 skips it entirely;
# this fixture is the recovered-envelope case, not the lightweight case.
# $1 = "full" | "nocogs"; echoes the payload file path (caller rm -rf's the dir).
_dlw_payload() {
    local mode="$1" dir
    dir=$(mktemp -d)
    if [[ "$mode" == "full" ]]; then
        cat > "$dir/payload.json" <<'JSON'
{
  "bodyText": "## Review\nLine two.",
  "meta": {"base":"abc","head_sha":"0123456789abcdef0123456789abcdef01234567","empty_tree_mode":false,"path_scope":""},
  "cogs": [{"phase":"round1","domain":"correctness","output":{"findings":[]}}],
  "findings": [{"tier":"consensus","file":"a.py","line":3,"description":"has \"quotes\" and\na newline"}]
}
JSON
    else
        cat > "$dir/payload.json" <<'JSON'
{
  "bodyText": "No findings.",
  "findings": [{"tier":"consensus","file":"a.py","line":1,"description":"plain"}]
}
JSON
    fi
    echo "$dir/payload.json"
}

test_dlw_md_header_and_body_verbatim() {
    local bin payload out md
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha deadbee \
        --payload "$payload" --ts 2026-07-09T00:00:00Z --out-dir "$out"
    md="$out/o-r/pr-1-0123456789ab.md"
    assert_equals "<!-- plugin_sha: deadbee | ts: 2026-07-09T00:00:00Z -->" \
        "$(head -1 "$md")" "durable-log-write: .md line 1 is the provenance comment"
    # bodyText verbatim: second line onward equals the payload bodyText.
    assert_equals "## Review" "$(sed -n '2p' "$md")" "durable-log-write: .md body is bodyText verbatim (line 1)"
    assert_equals "Line two." "$(sed -n '3p' "$md")" "durable-log-write: .md body is bodyText verbatim (line 2)"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_jsonl_every_line_valid_json() {
    local bin payload out jsonl badlines
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    jsonl="$out/o-r/pr-1-0123456789ab.jsonl"
    badlines=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            badlines=$((badlines + 1))
        fi
    done < "$jsonl"
    assert_equals "0" "$badlines" "durable-log-write: every .jsonl line is valid JSON (finding with quote+newline survives)"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_jsonl_line_order() {
    local bin payload out jsonl types
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    jsonl="$out/o-r/pr-1-0123456789ab.jsonl"
    types=$(jq -r '.type' "$jsonl" | tr '\n' ' ')
    assert_equals "meta cog finding " "$types" "durable-log-write: .jsonl order is meta -> cog -> finding"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_nocogs_emits_meta_and_finding_only() {
    local bin payload out jsonl types
    bin=$(_dlw_bin); payload=$(_dlw_payload nocogs); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident my-branch --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    jsonl="$out/o-r/my-branch-0123456789ab.jsonl"
    types=$(jq -r '.type' "$jsonl" | tr '\n' ' ')
    assert_equals "meta finding " "$types" "durable-log-write: no-cogs payload (recovered envelope) emits meta + finding only"
    rm -rf "$out" "$(dirname "$payload")"
}

test_dlw_tokens_appended_and_malformed_skipped() {
    local bin payload out jsonl toks n
    bin=$(_dlw_bin); payload=$(_dlw_payload full); out=$(mktemp -d); toks=$(mktemp)
    printf '%s\n' '{"phase":"round1","tokens":10}' 'THIS IS NOT JSON' '{"phase":"synth","tokens":5}' > "$toks"
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --tokens "$toks" --out-dir "$out"
    jsonl="$out/o-r/pr-1-0123456789ab.jsonl"
    # 1 meta + 1 cog + 1 finding + 2 valid token rows (malformed skipped) = 5 lines.
    n=$(wc -l < "$jsonl" | tr -d ' ')
    assert_equals "5" "$n" "durable-log-write: valid token rows appended, malformed row skipped, still exits 0"
    rm -rf "$out" "$(dirname "$payload")" "$toks"
}

test_dlw_missing_payload_exits_1_writes_nothing() {
    local bin out rc
    bin=$(_dlw_bin); out=$(mktemp -d)
    set +e
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$out/does-not-exist.json" --out-dir "$out" >/dev/null 2>&1
    rc=$?
    set -e
    assert_equals "1" "$rc" "durable-log-write: missing --payload exits 1"
    if [[ -z "$(find "$out" -name '*.md' -o -name '*.jsonl' 2>/dev/null)" ]]; then
        pass "durable-log-write: missing --payload writes nothing"
    else
        fail "durable-log-write: missing --payload writes nothing" "files were written"
    fi
    rm -rf "$out"
}

test_dlw_malformed_payload_exits_1() {
    local bin out payload rc
    bin=$(_dlw_bin); out=$(mktemp -d); payload=$(mktemp)
    printf '%s' 'not json {' > "$payload"
    set +e
    "$bin" --repo-slug o-r --ident pr-1 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out" >/dev/null 2>&1
    rc=$?
    set -e
    assert_equals "1" "$rc" "durable-log-write: non-JSON --payload exits 1"
    rm -rf "$out" "$payload"
}

test_dlw_ident_controls_filename() {
    local bin payload out
    bin=$(_dlw_bin); payload=$(_dlw_payload nocogs); out=$(mktemp -d)
    "$bin" --repo-slug o-r --ident pr-86 --sha 0123456789ab --plugin-sha x \
        --payload "$payload" --out-dir "$out"
    if [[ -f "$out/o-r/pr-86-0123456789ab.md" ]]; then
        pass "durable-log-write: --ident pr-86 yields pr-86-<sha>.md"
    else
        fail "durable-log-write: --ident pr-86 yields pr-86-<sha>.md" "file missing"
    fi
    rm -rf "$out" "$(dirname "$payload")"
}
