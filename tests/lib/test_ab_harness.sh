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

test_ab_capture_extracts_freeform_verdict() {
    # Real shape from a second live -p trial: the orchestrator emitted a
    # single freeform paragraph (no heading) ending with
    # "Advisory verdict: **APPROVE** (Rubric row 4)." The capture regex
    # must match the freeform pattern as well as the headed one.
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-freeform-summary.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: freeform fixture present" "missing"
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
    assert_equals "APPROVE" "$verdict" \
        "A/B capture: freeform 'Advisory verdict: **APPROVE**' extracted"

    rm -rf "$trial_dir"
}

test_ab_capture_counts_consensus_findings_from_table_summary() {
    # Real shape from PR #29 trial 2: a structured report with title heading,
    # verdict block, table-formatted top suggestions, and a "N consensus
    # findings" line in ## Summary. The bullet-line proxy (^- ) returns 0
    # because findings are in tables/numbered lists. capture must extract the
    # authoritative N from "consensus findings".
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-table-summary.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: table-summary fixture present" "missing"
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

    local verdict findings
    verdict=$(cat "$trial_dir/verdict.txt" 2>/dev/null)
    findings=$(jq -r '.finding_count' "$trial_dir/report-stats.json" 2>/dev/null)

    assert_equals "APPROVE" "$verdict" \
        "A/B capture: table-summary verdict extracted"
    assert_equals "14" "$findings" \
        "A/B capture: table-summary 'N consensus findings' extracted"

    # The whole report (title + verdict + summary + table + cost) must land
    # in synthesiser-report.md, not just the ## Summary onward. Assert by
    # presence of the title line, the verdict block, AND the cost block.
    if grep -qF '# Review of PR #29' "$trial_dir/synthesiser-report.md" \
       && grep -qF 'Verdict: APPROVE' "$trial_dir/synthesiser-report.md" \
       && grep -qF 'Review subtotal' "$trial_dir/synthesiser-report.md"; then
        pass "A/B capture: full report block extracted from heading to end"
    else
        fail "A/B capture: full report block extracted from heading to end" \
            "title, verdict, or cost block missing from synthesiser-report.md"
    fi

    rm -rf "$trial_dir"
}

test_ab_capture_extracts_orchestrator_summary_verdict() {
    # Real shape from a live -p trial: the synthesiser report does NOT reach
    # the parent stdout under `claude -p`; the orchestrator's `## Summary`
    # block does, with `**Verdict (advisory only):** <X>` in Class B.1 halt
    # mode. capture must recognise that pattern.
    local capture="$REPO_ROOT/tests/ab/lib/capture.sh"
    local fixture="$REPO_ROOT/tests/ab/fixtures/trial-stdout-orchestrator-summary.log"

    if [[ ! -f "$capture" || ! -f "$fixture" ]]; then
        fail "A/B capture: orchestrator-summary fixture present" "missing"
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
    assert_equals "REQUEST_CHANGES" "$verdict" \
        "A/B capture: orchestrator advisory-only verdict extracted"

    if [[ -s "$trial_dir/synthesiser-report.md" ]]; then
        pass "A/B capture: orchestrator summary captured to synthesiser-report.md"
    else
        fail "A/B capture: orchestrator summary captured to synthesiser-report.md" \
            "report file missing or empty"
    fi

    rm -rf "$trial_dir"
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

    # We pass --trials 1 but expect run.sh to exit non-zero during preflight
    # because config_load fails on the unknown key. The harness must NOT begin
    # mutating the tree in this state.
    local rc
    "$run" --config "$bad" --trials 1 >/dev/null 2>&1 || rc=$?

    if [[ "${rc:-0}" != "0" ]]; then
        pass "A/B run.sh: rejects unknown config key with non-zero exit"
    else
        fail "A/B run.sh: rejects unknown config key with non-zero exit" \
            "run.sh exited 0 on a config with an unknown top-level key — this is the precondition that must hard-halt before any mutation"
    fi

    # Belt-and-braces: the working tree must still be clean. If it isn't,
    # mutations leaked despite the preflight failure.
    if git -C "$REPO_ROOT" diff --quiet; then
        pass "A/B run.sh: bad-config rejection leaves working tree clean"
    else
        fail "A/B run.sh: bad-config rejection leaves working tree clean" \
            "working tree is dirty after run.sh rejected a bad config — the preflight check fired AFTER mutations were applied, which is the wrong order"
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
            "config_load accepted mode: drift-detector — only 'end-to-end' and 'per-agent' are valid"
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
