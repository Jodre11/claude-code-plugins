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

test_ab_agent_capture_trivy_parses_three_findings() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trivy-stdout-three-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture trivy: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "3" "$count" "A/B agent_capture trivy: three findings extracted"

    local first_rule first_file first_line
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    first_file=$(jq -r '.[0].file' "$trial_dir/findings.json")
    first_line=$(jq -r '.[0].line' "$trial_dir/findings.json")
    assert_equals "DS-0001" "$first_rule" "A/B agent_capture trivy: bare DS-NNNN rule_id tokenises cleanly"
    assert_equals "Dockerfile" "$first_file" "A/B agent_capture trivy: file parsed"
    assert_equals "1" "$first_line" "A/B agent_capture trivy: line parsed"

    local crit_sev
    crit_sev=$(jq -r '.[] | select(.rule_id == "DS-0031") | .severity' "$trial_dir/findings.json")
    assert_equals "Critical" "$crit_sev" "A/B agent_capture trivy: DS-0031 severity Critical"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_trivy_zero_findings_is_empty_array() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## Trivy IaC Findings\n\n0 findings — no IaC files in diff.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture trivy: zero-state yields empty array"
    rm -rf "$trial_dir"
}

test_ab_agent_capture_trivy_skipped_marks_inconclusive() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf 'Skipped — trivy not available on PATH.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture trivy: skip marks INCONCLUSIVE"
    else
        fail "A/B agent_capture trivy: skip marks INCONCLUSIVE" "marker absent"
    fi
    rm -rf "$trial_dir"
}

test_ab_agent_capture_trivy_non_path_skip_marks_inconclusive() {
    # A skip line whose reason is NOT 'trivy not available' (e.g. the agent
    # self-aborts on the temp-dir contract) must still be classified
    # INCONCLUSIVE, not laundered into a false 0-findings result. Phase 3.3
    # trial-016 emitted this exact phrasing and the narrow sentinel mis-classed
    # it as an empty findings array (hash of literal `[]`).
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## Trivy IaC Findings\n\nSkipped — unable to create temporary files. The scan requires CLAUDE_TEMP_DIR.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial trivy "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture trivy: non-PATH skip marks INCONCLUSIVE"
    else
        fail "A/B agent_capture trivy: non-PATH skip marks INCONCLUSIVE" "marker absent (laundered to 0-findings)"
    fi
    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_parses_three_findings() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/jbinspect-stdout-three-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture jbinspect: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "3" "$count" "A/B agent_capture jbinspect: three findings extracted"

    local first_rule first_file first_line
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    first_file=$(jq -r '.[0].file' "$trial_dir/findings.json")
    first_line=$(jq -r '.[0].line' "$trial_dir/findings.json")
    assert_equals "RedundantUsingDirective" "$first_rule" "A/B agent_capture jbinspect: line-2 finding sorts first"
    assert_equals "BadCode.cs" "$first_file" "A/B agent_capture jbinspect: file parsed"
    assert_equals "2" "$first_line" "A/B agent_capture jbinspect: line parsed"

    local unused_rule
    unused_rule=$(jq -r '.[] | select(.line == 14) | .rule_id' "$trial_dir/findings.json")
    assert_equals "UnusedMember.Local" "$unused_rule" "A/B agent_capture jbinspect: CamelCase rule_id with spaced category tokenises cleanly"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_zero_findings_is_empty_array() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## JetBrains InspectCode Findings\n\n0 findings — no C# files in diff.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture jbinspect: zero-state yields empty array"
    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_no_solution_is_empty_array() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## JetBrains InspectCode Findings\n\n0 findings — could not determine solution for changed C# files.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture jbinspect: no-solution zero-state yields empty array (not skip)"
    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        fail "A/B agent_capture jbinspect: no-solution is zero not INCONCLUSIVE" "INCONCLUSIVE marker present"
    else
        pass "A/B agent_capture jbinspect: no-solution is zero not INCONCLUSIVE"
    fi
    rm -rf "$trial_dir"
}

test_ab_agent_capture_jbinspect_skipped_marks_inconclusive() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local trial_dir
    trial_dir=$(mktemp -d)
    printf '## JetBrains InspectCode Findings\n\nSkipped — jb inspectcode not available on PATH.\n' > "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial jbinspect "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture jbinspect: skip marks INCONCLUSIVE"
    else
        fail "A/B agent_capture jbinspect: skip marks INCONCLUSIVE" "marker absent"
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

test_ab_faithfulness_compares_finding_sets_correctly() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B faithfulness: lib present" "missing"
        return
    fi

    local d_baseline d_trial_match d_trial_diff match_result diff_result
    d_baseline=$(mktemp -d)
    d_trial_match=$(mktemp -d)
    d_trial_diff=$(mktemp -d)
    match_result=$(mktemp)
    diff_result=$(mktemp)

    cat > "$d_baseline/findings.json" <<'JSON'
[{"file":"a.py","line":1,"rule_id":"F401","severity":"Important","confidence":100}]
JSON
    cp "$d_baseline/findings.json" "$d_trial_match/findings.json"
    cat > "$d_trial_diff/findings.json" <<'JSON'
[{"file":"a.py","line":2,"rule_id":"E501","severity":"Important","confidence":100}]
JSON

    (
        # shellcheck disable=SC1090
        source "$lib"
        set +e
        agent_capture_compare_findings "$d_baseline/findings.json" "$d_trial_match/findings.json" >/dev/null 2>&1
        echo $? > "$match_result"
        agent_capture_compare_findings "$d_baseline/findings.json" "$d_trial_diff/findings.json" >/dev/null 2>&1
        echo $? > "$diff_result"
    )

    if [[ "$(cat "$match_result")" == "0" ]]; then
        pass "A/B faithfulness: identical finding sets compare equal"
    else
        fail "A/B faithfulness: identical finding sets compare equal" "expected exit 0; got $(cat "$match_result")"
    fi

    if [[ "$(cat "$diff_result")" != "0" ]]; then
        pass "A/B faithfulness: divergent finding sets compare unequal"
    else
        fail "A/B faithfulness: divergent finding sets compare unequal" "expected non-zero exit"
    fi

    rm -rf "$d_baseline" "$d_trial_match" "$d_trial_diff"
    rm -f "$match_result" "$diff_result"
}

test_ab_config_per_agent_ruff_haiku_low_parses() {
    # Phase 3.1: the haiku-low probe arm config must parse and expose
    # session.model=haiku, session.effort=low. The harness drives all
    # variation; the agent file is never touched at runtime.
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local probe="$REPO_ROOT/tests/ab/configs/per-agent/ruff-haiku-low.yaml"

    if [[ ! -f "$config" ]]; then
        fail "A/B config: per-agent ruff-haiku-low parses" "config.sh missing"
        return
    fi
    if [[ ! -f "$probe" ]]; then
        fail "A/B config: per-agent ruff-haiku-low parses" "ruff-haiku-low.yaml not yet authored"
        return
    fi

    local mode agent model effort
    mode=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_MODE:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_AGENT:-}"
    )
    model=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_MODEL:-}"
    )
    effort=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_EFFORT:-}"
    )

    assert_equals "per-agent" "$mode" "A/B config: ruff-haiku-low.mode = per-agent"
    assert_equals "ruff-reviewer" "$agent" "A/B config: ruff-haiku-low.agent = ruff-reviewer"
    assert_equals "haiku" "$model" "A/B config: ruff-haiku-low.session.model = haiku"
    assert_equals "low" "$effort" "A/B config: ruff-haiku-low.session.effort = low"
}

test_ab_config_per_agent_trivy_haiku_low_parses() {
    # Phase 3.3: the haiku-low probe arm config must parse and expose
    # session.model=haiku, session.effort=low. The harness drives all
    # variation; the agent file is never touched at runtime.
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local probe="$REPO_ROOT/tests/ab/configs/per-agent/trivy-haiku-low.yaml"

    if [[ ! -f "$config" ]]; then
        fail "A/B config: per-agent trivy-haiku-low parses" "config.sh missing"
        return
    fi
    if [[ ! -f "$probe" ]]; then
        fail "A/B config: per-agent trivy-haiku-low parses" "trivy-haiku-low.yaml not yet authored"
        return
    fi

    local mode agent model effort
    mode=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_MODE:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_AGENT:-}"
    )
    model=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_MODEL:-}"
    )
    effort=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_EFFORT:-}"
    )

    assert_equals "per-agent" "$mode" "A/B config: trivy-haiku-low.mode = per-agent"
    assert_equals "trivy-reviewer" "$agent" "A/B config: trivy-haiku-low.agent = trivy-reviewer"
    assert_equals "haiku" "$model" "A/B config: trivy-haiku-low.session.model = haiku"
    assert_equals "low" "$effort" "A/B config: trivy-haiku-low.session.effort = low"
}

test_ab_config_per_agent_jbinspect_haiku_low_parses() {
    # Phase 3.4: the haiku-low probe arm config must parse and expose
    # session.model=haiku, session.effort=low. The harness drives all
    # variation; the agent file is never touched at runtime.
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local probe="$REPO_ROOT/tests/ab/configs/per-agent/jbinspect-haiku-low.yaml"

    if [[ ! -f "$config" ]]; then
        fail "A/B config: per-agent jbinspect-haiku-low parses" "config.sh missing"
        return
    fi
    if [[ ! -f "$probe" ]]; then
        fail "A/B config: per-agent jbinspect-haiku-low parses" "jbinspect-haiku-low.yaml not yet authored"
        return
    fi

    local mode agent model effort
    mode=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_MODE:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_AGENT:-}"
    )
    model=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_MODEL:-}"
    )
    effort=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$probe" >/dev/null
        echo "${_AB_CONFIG_SESSION_EFFORT:-}"
    )

    assert_equals "per-agent" "$mode" "A/B config: jbinspect-haiku-low.mode = per-agent"
    assert_equals "jbinspect-reviewer" "$agent" "A/B config: jbinspect-haiku-low.agent = jbinspect-reviewer"
    assert_equals "haiku" "$model" "A/B config: jbinspect-haiku-low.session.model = haiku"
    assert_equals "low" "$effort" "A/B config: jbinspect-haiku-low.session.effort = low"
}

test_ab_run_sh_stream_json_flag_recognised() {
    # Phase 3.1a: --stream-json must be a recognised flag and listed in
    # run.sh's --help output so operators can discover it. Propagation
    # through to launch.sh's argv is verified by the smoke tests, not by
    # this structural test.
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

test_ab_launch_jq_reduce_canonical_success() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/canonical-success.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: lib + fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    if grep -qF -- "### Finding — \`sys\` imported but unused" "$out" \
        && grep -qF -- "- **File:** bad.py:1" "$out"; then
        pass "A/B launch_jq_reduce: canonical success → .result verbatim"
    else
        fail "A/B launch_jq_reduce: canonical success → .result verbatim" "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_empty_result_falls_back_to_text_blocks() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/empty-result-three-text-blocks.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: empty-result fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    # Fallback recovers the canonical text from the third text block.
    if grep -qF "## Ruff Findings" "$out" \
        && grep -qF "### Finding — \`sys\` imported but unused" "$out" \
        && grep -qF "I'll run Ruff on the changed Python file." "$out"; then
        pass "A/B launch_jq_reduce: empty .result → fallback concatenates text blocks"
    else
        fail "A/B launch_jq_reduce: empty .result → fallback concatenates text blocks" \
            "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_report_midstream_trailing_closer() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/report-midstream-trailing-closer.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: midstream-report fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    # Report lives in a mid-stream assistant turn; the terminal .result is a
    # short heading-less closer. The reducer must reconstruct the report, and
    # must NOT emit the closer (guards against reintroducing .result-first).
    if grep -qF -- "### Finding — \`sys\` imported but unused" "$out" \
        && grep -qF -- "- **File:** bad.py:1" "$out" \
        && ! grep -qF -- "Review complete." "$out"; then
        pass "A/B launch_jq_reduce: midstream report survives a trailing closer"
    else
        fail "A/B launch_jq_reduce: midstream report survives a trailing closer" "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_error_subtype_yields_empty() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/error-subtype.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: error fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    if [[ ! -s "$out" ]]; then
        pass "A/B launch_jq_reduce: error subtype + no text blocks → empty stdout"
    else
        fail "A/B launch_jq_reduce: error subtype + no text blocks → empty stdout" \
            "$(cat "$out")"
    fi
    rm -f "$out"
}

test_ab_launch_jq_reduce_no_terminal_event_yields_empty() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/stream-jsonl/no-terminal-event.jsonl"
    if [[ ! -f "$launch" || ! -f "$fx" ]]; then
        fail "A/B launch_jq_reduce: no-terminal fixture present" "missing"
        return
    fi

    local out
    out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_jq_reduce_stream_jsonl "$fx" "$out"
    )

    if [[ ! -s "$out" ]]; then
        pass "A/B launch_jq_reduce: no terminal event + no text blocks → empty stdout"
    else
        fail "A/B launch_jq_reduce: no terminal event + no text blocks → empty stdout" \
            "$(cat "$out")"
    fi
    rm -f "$out"
}

_ab_3_1c_setup_trial_dir() {
    # Helper: build a synthetic trial dir with the given stdout.log size and
    # an optional stream.jsonl containing the given JSONL events. Echoes the
    # path on stdout for the caller to consume and clean up.
    local stdout_bytes="$1"
    local stream_jsonl_content="$2"  # empty string = no file
    local d
    d=$(mktemp -d)
    if [[ "$stdout_bytes" == "0" ]]; then
        : > "$d/stdout.log"
    else
        # Pad with predictable bytes; exact content does not matter for the predicate.
        printf '%*s' "$stdout_bytes" '' | tr ' ' 'x' > "$d/stdout.log"
    fi
    if [[ -n "$stream_jsonl_content" ]]; then
        printf '%s' "$stream_jsonl_content" > "$d/stream.jsonl"
    fi
    : > "$d/stderr.log"
    echo '{}' > "$d/timing.json"
    echo "$d"
}

test_ab_launch_assert_recovered_fallback_passes() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 500 \
        '{"type":"result","subtype":"success","result":""}')

    local rc=0
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) || rc=$?
    assert_equals "0" "$rc" "A/B launch_assert: recovered-fallback case (500 bytes stdout) is recoverable"
    rm -rf "$d"
}

test_ab_launch_assert_empty_no_stream_jsonl_fires() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 "")

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_no_stream_jsonl"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + no stream.jsonl → fires with reason=no_stream_jsonl"
    else
        fail "A/B launch_assert: empty stdout + no stream.jsonl → fires with reason=no_stream_jsonl" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_empty_no_terminal_result_fires() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 \
        '{"type":"system","subtype":"init","session_id":"x"}')

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_no_terminal_result"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + truncated stream.jsonl → fires with reason=no_terminal_result"
    else
        fail "A/B launch_assert: empty stdout + truncated stream.jsonl → fires with reason=no_terminal_result" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_empty_subtype_error_fires() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 \
        '{"type":"result","subtype":"error","result":""}')

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_subtype_error"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + subtype=error → fires with reason=subtype_error"
    else
        fail "A/B launch_assert: empty stdout + subtype=error → fires with reason=subtype_error" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_empty_subtype_success_no_recovery_fires() {
    # The unrecoverable success case: fallback already ran and produced
    # nothing (no text blocks anywhere in the JSONL), so stdout.log is empty
    # despite a successful terminal envelope.
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 0 \
        '{"type":"result","subtype":"success","result":""}')

    local rc=0 stderr_out
    stderr_out=$(mktemp)
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) 2> "$stderr_out" || rc=$?
    if [[ "$rc" != "0" ]] && grep -qF '"reason":"empty_stdout_no_recovery_signal"' "$stderr_out"; then
        pass "A/B launch_assert: empty stdout + success-but-no-text → fires with reason=no_recovery_signal"
    else
        fail "A/B launch_assert: empty stdout + success-but-no-text → fires with reason=no_recovery_signal" \
            "rc=$rc stderr=$(cat "$stderr_out")"
    fi
    rm -f "$stderr_out"
    rm -rf "$d"
}

test_ab_launch_assert_non_stream_json_codepath_passes() {
    # Non-stream-json codepath: stdout.log has content, no stream.jsonl
    # exists. Recoverable.
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    local d
    d=$(_ab_3_1c_setup_trial_dir 1234 "")

    local rc=0
    (
        # shellcheck disable=SC1090
        source "$launch"
        launch_assert_trial_recoverable "$d"
    ) || rc=$?
    assert_equals "0" "$rc" "A/B launch_assert: non-empty stdout + no stream.jsonl is recoverable"
    rm -rf "$d"
}

test_ab_agent_capture_canonical_shape_yields_canonical_hash() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-canonical-finding.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: canonical-fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count first_rule
    count=$(jq 'length' "$d/findings.json")
    first_rule=$(jq -r '.[0].rule_id' "$d/findings.json")
    assert_equals "1" "$count" "A/B agent_capture: canonical fixture parses one finding"
    assert_equals "F401" "$first_rule" "A/B agent_capture: canonical fixture rule_id"

    # Hash equality: the canonical tuple must produce the Phase-2 baseline hash.
    # Use the direct file-shasum form to match the harness invariant
    # (`_agent_capture_compute_hash` in `agent_capture.sh` writes the same
    # pipeline into `findings_hash.txt`). The plan's earlier `jq -c -S '.'`
    # pipeline reordered keys and yielded a different hash; that was a
    # transcription bug fixed in execution per operator decision 2026-06-01.
    local expected_hash="7b003236b72b52271484f0b7c44ecd76a1de51e5195b4a7679c4916d74cb91c3"
    local actual_hash
    actual_hash=$(shasum -a 256 "$d/findings.json" | awk '{print $1}')
    assert_equals "$expected_hash" "$actual_hash" "A/B agent_capture: canonical fixture preserves Phase-2 tuple hash"

    rm -rf "$d"
}

test_ab_agent_capture_drifted_shape_yields_zero_findings() {
    # Phase 3.1c: the parser is retightened to canonical §7; the drifted
    # shape (**Finding N** + Message:/Detail:) MUST produce zero findings,
    # not retrofit-tolerated tuples.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-drifted-finding.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: drifted-fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count
    count=$(jq 'length' "$d/findings.json")
    assert_equals "0" "$count" "A/B agent_capture: drifted shape parses to zero findings (retrofit removed)"
    rm -rf "$d"
}

test_ab_agent_capture_mixed_prose_still_parses_canonical() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-mixed-prose.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: mixed-prose fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count first_rule
    count=$(jq 'length' "$d/findings.json")
    first_rule=$(jq -r '.[0].rule_id' "$d/findings.json")
    assert_equals "1" "$count" "A/B agent_capture: canonical-with-prose parses one finding"
    assert_equals "F401" "$first_rule" "A/B agent_capture: canonical-with-prose rule_id"
    rm -rf "$d"
}

test_ab_agent_capture_two_canonical_findings_sorted() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fx="$REPO_ROOT/tests/ab/fixtures/ruff-stdout-two-findings.log"
    if [[ ! -f "$lib" || ! -f "$fx" ]]; then
        fail "A/B agent_capture: two-findings fixture present" "missing"
        return
    fi

    local d
    d=$(mktemp -d)
    cp "$fx" "$d/stdout.log"
    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_ruff_trial "$d"
    )

    local count first_line second_line first_rule second_rule
    count=$(jq 'length' "$d/findings.json")
    first_line=$(jq -r '.[0].line' "$d/findings.json")
    second_line=$(jq -r '.[1].line' "$d/findings.json")
    first_rule=$(jq -r '.[0].rule_id' "$d/findings.json")
    second_rule=$(jq -r '.[1].rule_id' "$d/findings.json")
    assert_equals "2" "$count" "A/B agent_capture: two canonical findings extracted"
    assert_equals "1" "$first_line" "A/B agent_capture: line-1 finding sorts first"
    assert_equals "3" "$second_line" "A/B agent_capture: line-3 finding sorts second"
    assert_equals "F401" "$first_rule" "A/B agent_capture: first rule_id"
    assert_equals "E501" "$second_rule" "A/B agent_capture: second rule_id"
    rm -rf "$d"
}

# --- eslint parser tests (Phase 3.2) -----------------------------------------
# Authored from the captured Sonnet baseline trace
# (tests/ab/corpus/eslint-smoke-bad-js/expected/findings-eslint.md): a 4-rule
# finding set (no-var, prefer-const, no-unused-vars, eqeqeq) on bad.js lines
# 1,2,3,6. The eslint path reuses the shared §7 state-machine via the parser
# dispatch table; kebab-case rule IDs pass through the existing tokeniser
# unchanged.

test_ab_agent_capture_eslint_canonical_parses() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-canonical.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: lib + fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "4" "$count" "A/B agent_capture eslint: canonical finding count"

    local first_rule
    first_rule=$(jq -r '.[0].rule_id' "$trial_dir/findings.json")
    assert_equals "no-var" "$first_rule" "A/B agent_capture eslint: first rule_id (kebab-case preserved)"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_eslint_zero_state() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-zero-findings.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: zero-state fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    local count
    count=$(jq 'length' "$trial_dir/findings.json")
    assert_equals "0" "$count" "A/B agent_capture eslint: zero-state yields empty array"

    rm -rf "$trial_dir"
}

test_ab_agent_capture_eslint_skipped_marks_inconclusive() {
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-skipped.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: skipped fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture eslint: skipped state writes INCONCLUSIVE marker"
    else
        fail "A/B agent_capture eslint: skipped state writes INCONCLUSIVE marker" \
            "expected $trial_dir/INCONCLUSIVE marker file"
    fi

    rm -rf "$trial_dir"
}

test_ab_agent_capture_eslint_skipped_eslint_only_marks_inconclusive() {
    # Phase 3.2b PR C: Haiku paraphrased the skip line as 'Skipped — eslint
    # not available …' (dropping '/biome'). The old sentinel matched only the
    # 'eslint/biome' phrasing, so this slipped through as a false zero-findings
    # result instead of a skip. The widened sentinel must mark it INCONCLUSIVE.
    local lib="$REPO_ROOT/tests/ab/lib/agent_capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/eslint-stdout-skipped-eslint-only.log"

    if [[ ! -f "$lib" || ! -f "$fixture" ]]; then
        fail "A/B agent_capture eslint: eslint-only skip fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_parse_trial eslint "$trial_dir"
    )

    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        pass "A/B agent_capture eslint: eslint-only skip phrasing marks INCONCLUSIVE"
    else
        fail "A/B agent_capture eslint: eslint-only skip phrasing marks INCONCLUSIVE" \
            "expected $trial_dir/INCONCLUSIVE marker file — widened skip sentinel should catch the '/biome'-less phrasing"
    fi

    rm -rf "$trial_dir"
}

test_ab_fixture_parses_setup_command() {
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    local with_setup="$REPO_ROOT/tests/ab/fixtures/source-yaml-with-setup.yaml"
    local good="$REPO_ROOT/tests/ab/fixtures/source-yaml-good.yaml"

    if [[ ! -f "$lib" || ! -f "$with_setup" || ! -f "$good" ]]; then
        fail "A/B fixture: setup-command fixtures present" "missing"
        return
    fi

    local cmd_present cmd_absent
    cmd_present=$(
        # shellcheck disable=SC1090
        source "$lib"
        fixture_load_from_path "$with_setup" >/dev/null
        echo "${_AB_FIXTURE_SETUP_COMMAND:-}"
    )
    cmd_absent=$(
        # shellcheck disable=SC1090
        source "$lib"
        fixture_load_from_path "$good" >/dev/null
        echo "${_AB_FIXTURE_SETUP_COMMAND:-EMPTY}"
    )

    assert_equals "npm ci" "$cmd_present" "A/B fixture: setup.command parsed when present"
    assert_equals "EMPTY" "$cmd_absent" "A/B fixture: setup.command empty when absent"
}

test_ab_fixture_run_setup_executes_in_dir() {
    local lib="$REPO_ROOT/tests/ab/lib/fixture.sh"
    if [[ ! -f "$lib" ]]; then
        fail "A/B fixture: lib present for run_setup" "missing"
        return
    fi

    local d marker rc_noop
    d=$(mktemp -d)

    # With a command set, fixture_run_setup runs it with $d as cwd.
    (
        # shellcheck disable=SC1090
        source "$lib"
        _AB_FIXTURE_SETUP_COMMAND="touch setup-ran"
        fixture_run_setup "$d"
    )
    if [[ -f "$d/setup-ran" ]]; then
        marker=PRESENT
    else
        marker=ABSENT
    fi

    # With no command, fixture_run_setup is a no-op returning success.
    rc_noop=$(
        # shellcheck disable=SC1090
        source "$lib"
        _AB_FIXTURE_SETUP_COMMAND=""
        set +e
        fixture_run_setup "$d"
        echo $?
    )

    assert_equals "PRESENT" "$marker" "A/B fixture: run_setup executes command in target dir"
    assert_equals "0" "$rc_noop" "A/B fixture: run_setup is a no-op when no command set"

    rm -rf "$d"
}

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

    local out
    out=$(
        # shellcheck disable=SC1090
        source "$lib"
        agent_capture_extract_cost_csv "$fix"
    )

    assert_equals ",,," "$out" \
        "A/B cost: extract_cost_csv emits four empty fields when no result event"
}
