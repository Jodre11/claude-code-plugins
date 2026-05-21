#!/usr/bin/env bash
# Structural tests for the A/B test harness scaffold and lib scripts.

_ab_dir() {
    echo "$REPO_ROOT/tests/ab"
}

test_ab_scaffold_present() {
    local ab
    ab=$(_ab_dir)
    if [[ ! -d "$ab" ]]; then
        fail "A/B harness: tests/ab/ exists" "directory missing"
        return
    fi

    assert_file_exists "tests/ab/run.sh" "A/B harness: run.sh exists"
    assert_dir_exists "tests/ab/lib" "A/B harness: lib/ exists"
    assert_dir_exists "tests/ab/configs" "A/B harness: configs/ exists"
    assert_dir_exists "tests/ab/fixtures" "A/B harness: fixtures/ exists"

    if [[ -x "$ab/run.sh" ]]; then
        pass "A/B harness: run.sh is executable"
    else
        fail "A/B harness: run.sh is executable" "missing +x bit on tests/ab/run.sh"
    fi
}

test_ab_runs_dir_gitignored() {
    if grep -qE '^tests/ab/runs/?$' "$REPO_ROOT/.gitignore"; then
        pass "A/B harness: tests/ab/runs/ is gitignored"
    else
        fail "A/B harness: tests/ab/runs/ is gitignored" \
            "expected an exact line 'tests/ab/runs/' in .gitignore so trial output never accidentally lands in commits"
    fi
}

test_ab_shell_scripts_have_strict_mode() {
    local script
    for script in "$REPO_ROOT"/tests/ab/run.sh "$REPO_ROOT"/tests/ab/lib/*.sh; do
        if [[ ! -f "$script" ]]; then
            continue
        fi
        local rel="${script#"$REPO_ROOT/"}"
        if head -5 "$script" | grep -qE '^set -euo pipefail$'; then
            pass "A/B harness: $rel uses set -euo pipefail"
        else
            fail "A/B harness: $rel uses set -euo pipefail" \
                "every shell script in tests/ab/ must declare strict mode in its first 5 lines"
        fi
        if head -1 "$script" | grep -qE '^#!/usr/bin/env bash$'; then
            pass "A/B harness: $rel has /usr/bin/env bash shebang"
        else
            fail "A/B harness: $rel has /usr/bin/env bash shebang" \
                "first line must be '#!/usr/bin/env bash' for portability"
        fi
    done
}

test_ab_mutate_strips_ultrathink_keyword() {
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-before.md"
    local after="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-after.md"

    if [[ ! -f "$mutate" ]]; then
        fail "A/B mutate: lib/mutate.sh exists" "missing"
        return
    fi
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B mutate: fixtures present" "missing fixture pair"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$before" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_strip_ultrathink_keyword "$tmp"
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: ultrathink keyword stripped to expected form"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$tmp" | head -30 || true)
        fail "A/B mutate: ultrathink keyword stripped to expected form" "$diff_output"
    fi
    rm -f "$tmp"
}

test_ab_mutate_rewrites_agent_model() {
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/agent-before.md"
    local after="$REPO_ROOT/tests/ab/fixtures/agent-after.md"

    if [[ ! -f "$mutate" ]]; then
        fail "A/B mutate: lib/mutate.sh exists" "missing"
        return
    fi
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B mutate: agent fixtures present" "missing fixture pair"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$before" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_set_agent_model "$tmp" sonnet
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: agent model frontmatter rewritten"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$tmp" | head -30 || true)
        fail "A/B mutate: agent model frontmatter rewritten" "$diff_output"
    fi
    rm -f "$tmp"
}

test_ab_mutate_strip_idempotent() {
    # Second strip must be a no-op — exit 0, no edit. Guards against accidental
    # double-strips eating non-ultrathink prompt content.
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local after="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-after.md"

    if [[ ! -f "$mutate" || ! -f "$after" ]]; then
        skip "A/B mutate: idempotent strip" "missing helper or fixture"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$after" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_strip_ultrathink_keyword "$tmp"
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: second strip is a no-op"
    else
        fail "A/B mutate: second strip is a no-op" \
            "applying the strip twice produced different output — strip is not idempotent"
    fi
    rm -f "$tmp"
}

test_ab_config_loads_baseline() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local baseline="$REPO_ROOT/tests/ab/configs/baseline.yaml"

    if [[ ! -f "$config" || ! -f "$baseline" ]]; then
        fail "A/B config: lib/config.sh and baseline.yaml exist" "missing one or both"
        return
    fi

    local name strip
    name=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$baseline" >/dev/null
        echo "$_AB_CONFIG_NAME"
    )
    strip=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$baseline" >/dev/null
        echo "${_AB_CONFIG_STRIP_ULTRATHINK:-false}"
    )

    assert_equals "baseline" "$name" "A/B config: baseline.yaml exposes name=baseline"
    assert_equals "false" "$strip" "A/B config: baseline.yaml does not strip ultrathink"
}

test_ab_config_loads_no_ultrathink() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local cfg="$REPO_ROOT/tests/ab/configs/no-ultrathink.yaml"

    if [[ ! -f "$config" || ! -f "$cfg" ]]; then
        fail "A/B config: lib/config.sh and no-ultrathink.yaml exist" "missing one or both"
        return
    fi

    local strip
    strip=$(
        # shellcheck disable=SC1090
        source "$config"
        config_load "$cfg" >/dev/null
        echo "${_AB_CONFIG_STRIP_ULTRATHINK:-false}"
    )

    assert_equals "true" "$strip" "A/B config: no-ultrathink.yaml strips ultrathink"
}

test_ab_config_rejects_unknown_top_level_key() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/config-bad-key.yaml"

    if [[ ! -f "$config" || ! -f "$bad" ]]; then
        fail "A/B config: bad-key fixture present" "missing"
        return
    fi

    local rc
    rc=$(
        # shellcheck disable=SC1090
        source "$config"
        set +e
        config_load "$bad" >/dev/null 2>&1
        echo $?
    )

    if [[ "$rc" != "0" ]]; then
        pass "A/B config: unknown top-level keys rejected"
    else
        fail "A/B config: unknown top-level keys rejected" \
            "config_load accepted a config with 'unknown_top_level_key' — schema validation must hard-fail on unrecognised keys per the spec"
    fi
}

test_ab_launch_resolves_timeout_binary() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    if [[ ! -f "$launch" ]]; then
        fail "A/B launch: lib/launch.sh exists" "missing"
        return
    fi

    local result
    result=$(
        # shellcheck disable=SC1090
        source "$launch"
        # PATH manipulation: prepend a sandbox where we have only `timeout`
        # available. The function must accept either timeout or gtimeout.
        if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
            launch_resolve_timeout_binary
        else
            echo "neither-available"
        fi
    )

    if [[ "$result" == "timeout" || "$result" == "gtimeout" ]]; then
        pass "A/B launch: resolves timeout or gtimeout from PATH"
    elif [[ "$result" == "neither-available" ]]; then
        skip "A/B launch: timeout binary present" "neither timeout nor gtimeout on PATH on this host"
    else
        fail "A/B launch: resolves timeout or gtimeout from PATH" \
            "expected 'timeout' or 'gtimeout' on PATH; got: '$result'"
    fi
}

test_ab_launch_builds_argv_for_claude_p() {
    local launch="$REPO_ROOT/tests/ab/lib/launch.sh"
    if [[ ! -f "$launch" ]]; then
        fail "A/B launch: lib/launch.sh exists" "missing"
        return
    fi

    # Source the helper, call launch_build_claude_argv with known inputs, and
    # assert the resulting argv array contains the expected flags. The
    # function writes one argv element per line to stdout for testability.
    local argv
    argv=$(
        # shellcheck disable=SC1090
        source "$launch"
        launch_build_claude_argv "opus" "max" "/review-gh-pr https://example/pr/29"
    )

    if echo "$argv" | grep -qF -- "-p"; then
        pass "A/B launch: argv includes -p flag"
    else
        fail "A/B launch: argv includes -p flag" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "--permission-mode"; then
        pass "A/B launch: argv includes --permission-mode"
    else
        fail "A/B launch: argv includes --permission-mode" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "bypassPermissions"; then
        pass "A/B launch: argv passes bypassPermissions"
    else
        fail "A/B launch: argv passes bypassPermissions" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "--model"; then
        pass "A/B launch: argv includes --model"
    else
        fail "A/B launch: argv includes --model" "argv=$argv"
    fi
    if echo "$argv" | grep -qF -- "--effort"; then
        pass "A/B launch: argv includes --effort"
    else
        fail "A/B launch: argv includes --effort" "argv=$argv"
    fi
}

test_ab_capture_extracts_verdict_approve() {
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-approve.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: helper and fixture exist" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$capture"
        capture_parse_trial "$trial_dir"
    )

    local verdict
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    assert_equals "APPROVE" "$verdict" "A/B capture: APPROVE verdict extracted"

    if [[ -s "$trial_dir/synthesiser-report.md" ]]; then
        pass "A/B capture: synthesiser-report.md is non-empty"
    else
        fail "A/B capture: synthesiser-report.md is non-empty" "report file missing or empty"
    fi

    rm -rf "$trial_dir"
}

test_ab_capture_extracts_verdict_request_changes() {
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-request-changes.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: REQUEST_CHANGES fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$capture"
        capture_parse_trial "$trial_dir"
    )

    local verdict
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    assert_equals "REQUEST_CHANGES" "$verdict" "A/B capture: REQUEST_CHANGES verdict extracted"

    rm -rf "$trial_dir"
}

test_ab_capture_handles_truncated_output() {
    # When the trial timed out before the synthesiser emitted a verdict, the
    # capture must write 'INCONCLUSIVE' rather than silently producing an
    # empty verdict.txt — silent empty would corrupt the summary CSV.
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-truncated.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: truncated fixture present" "missing"
        return
    fi

    local trial_dir
    trial_dir=$(mktemp -d)
    cp "$fixture" "$trial_dir/stdout.log"

    (
        # shellcheck disable=SC1090
        source "$capture"
        capture_parse_trial "$trial_dir"
    )

    local verdict
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    assert_equals "INCONCLUSIVE" "$verdict" "A/B capture: truncated stdout yields INCONCLUSIVE"

    rm -rf "$trial_dir"
}
