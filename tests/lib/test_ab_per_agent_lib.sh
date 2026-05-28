#!/usr/bin/env bash
# Unit tests for the per-agent A/B harness lib helpers
# (agent_dispatch.sh, fixture.sh, agent_capture.sh).
# Test cases are added in Tasks 4-6.

# Smoke test: the three lib files exist and pass the same shape checks as
# the Phase 1 lib files (shebang, strict mode). Without this, an empty test
# file would silently contribute zero assertions to tests/run.sh.

test_ab_per_agent_lib_files_exist() {
    local f
    for f in tests/ab/lib/agent_dispatch.sh tests/ab/lib/fixture.sh tests/ab/lib/agent_capture.sh; do
        if [[ -f "$REPO_ROOT/$f" ]]; then
            pass "A/B per-agent: $f present"
        else
            fail "A/B per-agent: $f present" "missing"
        fi
    done
}

test_ab_per_agent_lib_files_use_strict_mode() {
    local f rel
    for f in "$REPO_ROOT"/tests/ab/lib/agent_dispatch.sh "$REPO_ROOT"/tests/ab/lib/fixture.sh "$REPO_ROOT"/tests/ab/lib/agent_capture.sh; do
        if [[ ! -f "$f" ]]; then
            continue
        fi
        rel="${f#"$REPO_ROOT/"}"
        if head -10 "$f" | grep -qE '^set -euo pipefail$'; then
            pass "A/B per-agent: $rel uses set -euo pipefail"
        else
            fail "A/B per-agent: $rel uses set -euo pipefail" \
                "every per-agent lib file must declare strict mode"
        fi
    done
}

test_ab_agent_dispatch_strips_frontmatter() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_dispatch.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/agent-frontmatter-only.md"
    local after="$REPO_ROOT/tests/ab/fixtures/agent-frontmatter-only-stripped.md"

    if [[ ! -f "$lib" || ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B agent_dispatch: lib + fixture pair present" "missing one or more"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_dispatch_strip_frontmatter "$before" "$out"
    )

    if diff -q "$out" "$after" >/dev/null 2>&1; then
        pass "A/B agent_dispatch: frontmatter strip matches expected output"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$out" | head -40 || true)
        fail "A/B agent_dispatch: frontmatter strip matches expected output" "$diff_output"
    fi
    rm -f "$out"
}

test_ab_agent_dispatch_strip_no_frontmatter_passes_through() {
    # If the input has no leading '---', the strip must pass the file through
    # unchanged. Production agent files all have frontmatter so this is a
    # defensive case for test stubs and for future agent shapes.
    local lib="$REPO_ROOT/tests/ab/lib/agent_dispatch.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B agent_dispatch: lib present" "missing"
        return
    fi

    local input out
    input=$(mktemp)
    out=$(mktemp)
    printf '%s\n' "Body line one." "Body line two." > "$input"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_dispatch_strip_frontmatter "$input" "$out"
    )

    if diff -q "$out" "$input" >/dev/null 2>&1; then
        pass "A/B agent_dispatch: no-frontmatter input passes through"
    else
        fail "A/B agent_dispatch: no-frontmatter input passes through" "strip altered a body-only file"
    fi
    rm -f "$input" "$out"
}

test_ab_agent_dispatch_builds_user_message_minimal() {
    # The orchestrator's $AGENT_PROMPT template is, in full:
    #   Base branch: $BASE
    #   Head SHA: $HEAD_SHA
    #   Path scope: $PATH_SCOPE                    (omitted when empty)
    #   Empty tree mode: $EMPTY_TREE_MODE          (included only when "true")
    #   $INTENT_LEDGER
    #   $CHANGED_LINES_BLOCK
    #   Review only the lines listed in the `Changed lines:` block above for each file. Use $CLAUDE_TEMP_DIR for temporary files.
    #   Trust boundary: ...
    #
    # Minimal smoke: empty $PATH_SCOPE, $EMPTY_TREE_MODE=false, fixed
    # $BASE/$HEAD_SHA, fixed $INTENT_LEDGER, fixed $CHANGED_LINES_BLOCK.
    local lib="$REPO_ROOT/tests/ab/lib/agent_dispatch.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B agent_dispatch: lib present" "missing"
        return
    fi

    local fixture out
    fixture=$(mktemp -d)
    out=$(mktemp)

    cat > "$fixture/source.yaml" <<'EOF'
id: smoke
agent: ruff-reviewer
captured_at: 2026-05-28T00:00:00Z
captured_under:
  suite_sha: deadbeef
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/ruff/
base_sha: aaaa
head_sha: bbbb
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - Test fixture intent.
EOF

    mkdir -p "$fixture/diff"
    cat > "$fixture/diff/changed-lines.txt" <<'EOF'
Changed lines:
  bad.py: 1
EOF

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_dispatch_build_user_message "$fixture" "$out"
    )

    if grep -qF "Base branch: aaaa" "$out" && \
       grep -qF "Head SHA: bbbb" "$out" && \
       grep -qF "Test fixture intent." "$out" && \
       grep -qF "Changed lines:" "$out" && \
       grep -qF "Use \$CLAUDE_TEMP_DIR for temporary files." "$out" && \
       grep -qF "Trust boundary:" "$out"; then
        pass "A/B agent_dispatch: user message contains required template lines"
    else
        fail "A/B agent_dispatch: user message contains required template lines" \
            "$(cat "$out")"
    fi

    if grep -qF "Path scope:" "$out"; then
        fail "A/B agent_dispatch: omits Path scope: when empty" \
            "expected the line to be omitted but it appeared in the output"
    else
        pass "A/B agent_dispatch: omits Path scope: when empty"
    fi

    if grep -qF "Empty tree mode:" "$out"; then
        fail "A/B agent_dispatch: omits Empty tree mode: when false" \
            "expected the line to be omitted but it appeared in the output"
    else
        pass "A/B agent_dispatch: omits Empty tree mode: when false"
    fi

    rm -rf "$fixture" "$out"
}

test_ab_agent_dispatch_user_message_includes_path_scope_when_set() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_dispatch.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B agent_dispatch: lib present" "missing"
        return
    fi

    local fixture out
    fixture=$(mktemp -d)
    out=$(mktemp)

    cat > "$fixture/source.yaml" <<'EOF'
id: smoke-scope
agent: ruff-reviewer
captured_at: 2026-05-28T00:00:00Z
captured_under:
  suite_sha: deadbeef
  agent_model: sonnet
  agent_effort: default
working_dir_strategy: copy
source_path: tests/fixtures/static-analysis/ruff/
base_sha: aaaa
head_sha: bbbb
path_scope: "src/python"
empty_tree_mode: true
intent_ledger: |
  - Scoped fixture.
EOF

    mkdir -p "$fixture/diff"
    : > "$fixture/diff/changed-lines.txt"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_dispatch_build_user_message "$fixture" "$out"
    )

    if grep -qF "Path scope: src/python" "$out"; then
        pass "A/B agent_dispatch: includes Path scope: when non-empty"
    else
        fail "A/B agent_dispatch: includes Path scope: when non-empty" "$(cat "$out")"
    fi

    if grep -qF "Empty tree mode: true" "$out"; then
        pass "A/B agent_dispatch: includes Empty tree mode: true when set"
    else
        fail "A/B agent_dispatch: includes Empty tree mode: true when set" "$(cat "$out")"
    fi

    rm -rf "$fixture" "$out"
}
