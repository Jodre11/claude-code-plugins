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

test_ab_launch_per_agent_argv_includes_append_system_prompt() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    if [[ ! -f "$launch" ]]; then
        fail "A/B per-agent launch: lib present" "missing"
        return
    fi

    local body user_msg argv
    body=$(mktemp)
    user_msg=$(mktemp)
    printf 'system prompt body\n' > "$body"
    printf 'user message\n' > "$user_msg"

    argv=$(
        # shellcheck disable=SC1090
        source "$launch"
        launch_build_per_agent_argv "haiku" "low" "$body" "$user_msg"
    )

    if echo "$argv" | grep -qE -- "--append-system-prompt(-file)?"; then
        pass "A/B per-agent launch: argv includes --append-system-prompt(-file)"
    else
        fail "A/B per-agent launch: argv includes --append-system-prompt(-file)" "argv=$argv"
    fi

    if echo "$argv" | grep -qF -- "--model"; then
        pass "A/B per-agent launch: argv includes --model"
    else
        fail "A/B per-agent launch: argv includes --model" "argv=$argv"
    fi

    if echo "$argv" | grep -qF -- "--effort"; then
        pass "A/B per-agent launch: argv includes --effort"
    else
        fail "A/B per-agent launch: argv includes --effort" "argv=$argv"
    fi

    rm -f "$body" "$user_msg"
}

test_ab_agent_capture_parses_three_findings() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-three-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$trial_dir"
    )

    if [[ -s "$trial_dir/findings.json" ]]; then
        pass "A/B agent_capture: findings.json non-empty"
    else
        fail "A/B agent_capture: findings.json non-empty" "file empty or absent"
        rm -rf "$trial_dir"
        return
    fi

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "3" "$count" "A/B agent_capture: three findings extracted"

    local first_rule first_file first_line
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    first_file=$(jq -r '.[0].file' "$trial_dir/findings.json")
    first_line=$(jq -r '.[0].line' "$trial_dir/findings.json")
    assert_equals "F401" "$first_rule" "A/B agent_capture: rule_id parsed"
    assert_equals "bad.py" "$first_file" "A/B agent_capture: file parsed"
    assert_equals "1" "$first_line" "A/B agent_capture: line parsed"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_zero_findings_is_empty_array() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-zero-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture: zero-findings fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture: zero-state yields empty array"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_skipped_marks_inconclusive() {
    # 'Skipped — ruff not available on PATH.' is not the same as zero findings;
    # the tool did not run. Capture must surface this distinctly so summary.csv
    # can mark the trial INCONCLUSIVE rather than counting it as a real zero.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-skipped.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture: skipped fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture: skipped state writes INCONCLUSIVE marker"
    else
        fail "A/B agent_capture: skipped state writes INCONCLUSIVE marker" \
            "expected $trial_dir/INCONCLUSIVE marker file"
    fi

    rm -rf "$trial_dir"
}

test_ab_agent_capture_findings_hash_is_deterministic() {
    # Two runs over the same stdout must produce identical findings_hash.
    # This is the cross-trial comparison primitive — if it is order-sensitive
    # or non-deterministic, the headline experiment cannot detect equivalent
    # behaviour as equivalent.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-three-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture: hash determinism check setup" "missing"
        return
    fi

    local d1 d2 hash1 hash2
    d1=$(mktemp -d); d2=$(mktemp -d)
    cp "$fixture" "$d1/stdout.log"
    cp "$fixture" "$d2/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d1"
        agent_capture_parse_ruff_trial "$d2"
    )

    hash1=$(cat "$d1/findings_hash.txt")
    hash2=$(cat "$d2/findings_hash.txt")

    assert_equals "$hash1" "$hash2" "A/B agent_capture: findings_hash is deterministic across runs"

    rm -rf "$d1" "$d2"
}

test_ab_fixture_loads_good() {
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    local good="$REPO_ROOT/tests/ab/fixtures/source-yaml-good.yaml"

    if [[ ! -f "$lib" || ! -f "$good" ]]; then
        fail "A/B fixture: lib + good fixture present" "missing"
        return
    fi

    local id agent
    id=$(
        # shellcheck disable=SC1090
        source "$lib"
        fixture_load_from_path "$good" >/dev/null
        echo "${_AB_FIXTURE_ID:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$lib"
        fixture_load_from_path "$good" >/dev/null
        echo "${_AB_FIXTURE_AGENT:-}"
    )

    assert_equals "smoke-good" "$id" "A/B fixture: id parsed from source.yaml"
    assert_equals "ruff-reviewer" "$agent" "A/B fixture: agent parsed from source.yaml"
}

test_ab_fixture_rejects_missing_agent() {
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/source-yaml-missing-key.yaml"

    if [[ ! -f "$lib" || ! -f "$bad" ]]; then
        fail "A/B fixture: missing-key fixture present" "missing"
        return
    fi

    local rc
    rc=$(
        # shellcheck disable=SC1090
        source "$lib"
        set +e
        fixture_load_from_path "$bad" >/dev/null 2>&1
        echo $?
    )

    if [[ "$rc" != "0" ]]; then
        pass "A/B fixture: source.yaml without agent: rejected"
    else
        fail "A/B fixture: source.yaml without agent: rejected" \
            "fixture_load accepted a source.yaml missing the required agent: field"
    fi
}

test_ab_fixture_decay_warner_against_fake_history() {
    # Build a minimal fake git history: a temp repo, two commits to a tracked
    # file, then probe the decay-warner against the older sha and expect a
    # warning (because file was modified after that sha).
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B fixture: lib present" "missing"
        return
    fi

    local repo old_warn_file head_warn_file
    repo=$(mktemp -d)
    old_warn_file=$(mktemp)
    head_warn_file=$(mktemp)

    # Capture decay-warner output for both probes inside a subshell (the
    # subshell shifts cwd into the fake repo and sources lib/fixture.sh).
    # Pass/fail assertions happen in the outer frame so counter mutations
    # persist — Bash subshells receive copies of $_pass_count and the like,
    # which are discarded on subshell exit.
    (
        cd "$repo"
        git init -q
        git config user.email "t@example.com"
        git config user.name "T"
        echo "v1" > tracked.txt
        git add tracked.txt
        git commit -qm "v1"
        local old_sha
        old_sha=$(git rev-parse HEAD)
        echo "v2" > tracked.txt
        git commit -qam "v2"

        # shellcheck disable=SC1090
        source "$lib"

        # Probe 1: old_sha < HEAD with file edited in between -> expect warning.
        fixture_decay_warnings_for_path "$old_sha" "tracked.txt" > "$old_warn_file"

        # Probe 2: HEAD vs HEAD -> expect silence.
        local head_sha
        head_sha=$(git rev-parse HEAD)
        fixture_decay_warnings_for_path "$head_sha" "tracked.txt" > "$head_warn_file"
    ) || true

    # Assertions in the outer frame so pass/fail mutations persist.
    if [[ -s "$old_warn_file" ]]; then
        pass "A/B fixture: decay-warner detects post-sha edits"
    else
        fail "A/B fixture: decay-warner detects post-sha edits" \
            "expected a warning for tracked.txt edited after the captured sha"
    fi

    if [[ ! -s "$head_warn_file" ]]; then
        pass "A/B fixture: decay-warner silent when path unchanged since sha"
    else
        local content
        content=$(cat "$head_warn_file")
        fail "A/B fixture: decay-warner silent when path unchanged since sha" \
            "unexpected warnings: $content"
    fi

    rm -f "$old_warn_file" "$head_warn_file"
    rm -rf "$repo"
}
