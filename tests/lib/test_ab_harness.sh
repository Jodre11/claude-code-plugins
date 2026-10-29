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

test_ab_run_sh_help_succeeds() {
    local run="$REPO_ROOT/tests/ab/run.sh"
    if [[ ! -x "$run" ]]; then
        fail "A/B run.sh: executable" "missing or not +x"
        return
    fi

    local out rc
    out=$("$run" --help 2>&1)
    rc=$?

    if [[ "$rc" == "0" ]] && echo "$out" | grep -qF "Usage: tests/ab/run.sh"; then
        pass "A/B run.sh: --help exits 0 and prints usage"
    else
        fail "A/B run.sh: --help exits 0 and prints usage" \
            "rc=$rc out=$out"
    fi
}

test_ab_run_sh_per_agent_tmp_base_is_hook_exempt() {
    # Regression (Phase 3.4 jbinspect fix-validation trial 8): the per-agent
    # trial working dirs must live under a /tmp/claude- prefix, NOT bare /tmp.
    # CLAUDE_TEMP_DIR is not exported into the harness shell, so a bare
    # `${CLAUDE_TEMP_DIR:-/tmp}` fallback put trial copies at /private/tmp/...,
    # outside the operator's hook-exempt /tmp/claude-* namespace. A dispatched
    # agent that referenced the ABSOLUTE trial path in a tool command (e.g.
    # `jb inspectcode /private/tmp/.../foo.sln`) then tripped the global
    # bash-guard temp-path policy and was denied — a non-deterministic
    # apparatus confound mis-scored as an agent-side skip. The fallback must
    # base under /tmp/claude- so the exemption holds for absolute paths too.
    local run="$REPO_ROOT/tests/ab/run.sh"
    if [[ ! -f "$run" ]]; then
        fail "A/B run.sh: per-agent tmp base is hook-exempt" "run.sh missing"
        return
    fi

    # The fallback base must be a /tmp/claude- path, never bare /tmp.
    if grep -qE 'CLAUDE_TEMP_DIR:-/tmp/claude-' "$run"; then
        pass "A/B run.sh: per-agent tmp base falls back under /tmp/claude- (hook-exempt)"
    else
        fail "A/B run.sh: per-agent tmp base falls back under /tmp/claude- (hook-exempt)" \
            "expected a \${CLAUDE_TEMP_DIR:-/tmp/claude-...} fallback for the per-agent base dir"
    fi

    # No per-agent dir may use the bare-/tmp fallback form that caused the confound.
    if grep -qE '\$\{CLAUDE_TEMP_DIR:-/tmp\}/per-agent-' "$run"; then
        fail "A/B run.sh: per-agent dirs do not use bare-/tmp fallback" \
            "found a \${CLAUDE_TEMP_DIR:-/tmp}/per-agent- path — this lands at /private/tmp and trips the global temp-path hook"
    else
        pass "A/B run.sh: per-agent dirs do not use bare-/tmp fallback"
    fi
}

test_ab_run_sh_rejects_unknown_config_key() {
    local run="$REPO_ROOT/tests/ab/run.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/config-bad-key.yaml"
    if [[ ! -x "$run" || ! -f "$bad" ]]; then
        fail "A/B run.sh: bad-config rejection" "missing run.sh or fixture"
        return
    fi

    # We pass --trials 1 but expect run.sh to exit non-zero before preflight
    # because config_load fails on the unknown key. Assert on the message too:
    # without --corpus, a non-zero exit alone could come from the missing flag.
    local rc out
    out=$("$run" --config "$bad" --trials 1 2>&1) || rc=$?

    if [[ "${rc:-0}" != "0" ]] && echo "$out" | grep -qF "unknown top-level key"; then
        pass "A/B run.sh: rejects unknown config key with non-zero exit"
    else
        fail "A/B run.sh: rejects unknown config key with non-zero exit" \
            "rc=${rc:-0} out=$out — run.sh must hard-halt on a config with an unknown top-level key"
    fi
}

test_ab_config_loads_per_agent_good() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local good="$REPO_ROOT/tests/ab/fixtures/config-per-agent-good.yaml"

    if [[ ! -f "$config" || ! -f "$good" ]]; then
        fail "A/B config: per-agent good fixture present" "missing"
        return
    fi

    local mode agent
    mode=$(
        # shellcheck disable=SC1090
        source "$config"
        set +e
        config_load "$good" >/dev/null 2>&1
        echo "${_AB_CONFIG_MODE:-}"
    )
    agent=$(
        # shellcheck disable=SC1090
        source "$config"
        set +e
        config_load "$good" >/dev/null 2>&1
        echo "${_AB_CONFIG_AGENT:-}"
    )

    assert_equals "per-agent" "$mode" "A/B config: per-agent mode parsed"
    assert_equals "ruff-reviewer" "$agent" "A/B config: per-agent agent parsed"
}

test_ab_config_rejects_per_agent_missing_agent() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/config-per-agent-missing-agent.yaml"

    if [[ ! -f "$config" || ! -f "$bad" ]]; then
        fail "A/B config: per-agent missing-agent fixture present" "missing"
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
        pass "A/B config: per-agent without agent: rejected"
    else
        fail "A/B config: per-agent without agent: rejected" \
            "config_load accepted a mode: per-agent config without an agent: field — must hard-fail"
    fi
}

test_ab_config_rejects_retired_agents_map() {
    # The agents: map drove the retired end-to-end mode's tracked-file
    # mutations. It must now hard-fail, not be silently ignored.
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    if [[ ! -f "$config" ]]; then
        fail "A/B config: lib/config.sh exists" "missing"
        return
    fi

    local tmp rc
    tmp=$(mktemp)
    printf 'name: smoke\nmode: per-agent\nagent: ruff-reviewer\nagents: {}\n' > "$tmp"
    rc=$(
        # shellcheck disable=SC1090
        source "$config"
        set +e
        config_load "$tmp" >/dev/null 2>&1
        echo $?
    )
    rm -f "$tmp"

    if [[ "$rc" != "0" ]]; then
        pass "A/B config: retired agents: map rejected"
    else
        fail "A/B config: retired agents: map rejected" \
            "config_load accepted an agents: map — it has no effect since end-to-end mode was removed"
    fi
}

test_ab_config_rejects_unknown_mode() {
    local config="$REPO_ROOT/tests/ab/lib/config.sh"
    local bad="$REPO_ROOT/tests/ab/fixtures/config-per-agent-unknown-mode.yaml"

    if [[ ! -f "$config" || ! -f "$bad" ]]; then
        fail "A/B config: unknown-mode fixture present" "missing"
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
        pass "A/B config: unknown mode: value rejected"
    else
        fail "A/B config: unknown mode: value rejected" \
            "config_load accepted mode: drift-detector — only 'per-agent' is valid"
    fi
}

test_ab_run_sh_faithfulness_check_help_recognised() {
    # Smoke: --faithfulness-check is a recognised flag (does not error out
    # the parser). Behaviour test (actual exit code on a real divergence) is
    # cost-prohibitive to put in the structural suite.
    local run="$REPO_ROOT/tests/ab/run.sh"
    if [[ ! -x "$run" ]]; then
        fail "A/B run.sh: faithfulness flag" "missing or not +x"
        return
    fi

    local out
    out=$("$run" --help 2>&1)
    if echo "$out" | grep -qF -- "--faithfulness-check"; then
        pass "A/B run.sh: --faithfulness-check listed in usage"
    else
        fail "A/B run.sh: --faithfulness-check listed in usage" "out=$out"
    fi
}
