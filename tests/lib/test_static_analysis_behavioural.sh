#!/usr/bin/env bash
# Behavioural smoke test for static-analysis specialists.
#
# Gated by CLAUDE_CODE_E2E_TESTS=1 — depends on a results file produced by an
# out-of-band driver session that dispatches real Agent({}) calls (subagent
# dispatches are an LLM-side capability and cannot be invoked from bash).
#
# Driver protocol
# ---------------
# A Claude Code session reads tests/fixtures/static-analysis/driver-prompt.md
# and, for each of the four static-analysis specialists, runs three sub-checks
# (PATH-miss, no-files-in-diff, normal-run) over three iterations each. The
# driver writes one JSON results file per run to:
#
#   tests/lib/.static-analysis-smoke-results.json
#
# The schema is defined in tests/fixtures/static-analysis/results-schema.md.
# This file is .gitignored; CI fetches it from the scheduled-run artifact.
#
# Assertions
# ----------
# When CLAUDE_CODE_E2E_TESTS=1 and the file exists, the test asserts:
#   - schema_version == 2 (bumped from 1 in Phase 2 of the severity-locked +
#     capped-confidence policy spec, 2026-05-13 — see results-schema.md)
#   - run_at parseable as ISO 8601 and within FRESHNESS_DAYS (default 30)
#   - all four specialists present in `specialists`
#   - each specialist has all three sub-checks
#   - each sub-check passed all 3 iterations (or up to 5 per the spec's
#     temperature-tolerance rule)
#   - synthesiser.synthesiser_severity_lock present and passed all iterations,
#     with no Dismissed tier placement, all confidences >= 50, all severities
#     == Important (defensive per-iteration checks)
#   - overall_pass == true
#
# On any assertion failure the test fails loudly so the spec's "all-pass
# required" gate triggers.
#
# When CLAUDE_CODE_E2E_TESTS=1 and the file is missing, the test fails with a
# pointer to the driver prompt — operator must run the driver first.
#
# When CLAUDE_CODE_E2E_TESTS=0 (default) the test skips with no I/O.

FRESHNESS_DAYS="${STATIC_ANALYSIS_SMOKE_FRESHNESS_DAYS:-30}"
EXPECTED_SPECIALISTS=("jbinspect-reviewer" "eslint-reviewer" "ruff-reviewer" "trivy-reviewer")
EXPECTED_SUBCHECKS=("path_miss" "no_files" "normal_run")

_smoke_assert() {
    local label="$1"
    local condition="$2"
    local detail="${3:-}"
    if [[ "$condition" == "true" ]]; then
        pass "$label"
    else
        fail "$label" "$detail"
    fi
}

test_static_analysis_behavioural_smoke() {
    if [[ "${CLAUDE_CODE_E2E_TESTS:-0}" != "1" ]]; then
        skip "static-analysis behavioural smoke" "set CLAUDE_CODE_E2E_TESTS=1 to run"
        return
    fi

    local results_file="$REPO_ROOT/tests/lib/.static-analysis-smoke-results.json"
    if [[ ! -f "$results_file" ]]; then
        fail "static-analysis behavioural smoke: results file present" \
            "missing: $results_file — run the driver from tests/fixtures/static-analysis/driver-prompt.md first"
        return
    fi

    if ! jq empty "$results_file" 2>/dev/null; then
        fail "static-analysis behavioural smoke: results JSON parses" \
            "invalid JSON: $results_file"
        return
    fi

    local schema_version
    schema_version="$(jq -r '.schema_version // empty' "$results_file")"
    # Schema 2 added the top-level `synthesiser` block (Phase 2 of the
    # severity-locked + capped-confidence policy spec, 2026-05-13). Older
    # results files must be re-generated against schema 2 to be valid.
    _smoke_assert "smoke: schema_version is 2" \
        "$([[ "$schema_version" == "2" ]] && echo true || echo false)" \
        "expected 2, got '$schema_version'"

    local run_at
    run_at="$(jq -r '.run_at // empty' "$results_file")"
    if [[ -z "$run_at" ]]; then
        fail "smoke: run_at present" "run_at field missing"
    else
        local run_at_epoch
        run_at_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$run_at" +%s 2>/dev/null || echo 0)"
        local now_epoch
        now_epoch="$(date +%s)"
        local age_days
        age_days=$(( (now_epoch - run_at_epoch) / 86400 ))
        if [[ "$run_at_epoch" -gt 0 && "$age_days" -le "$FRESHNESS_DAYS" ]]; then
            pass "smoke: run_at within $FRESHNESS_DAYS days (age=${age_days}d)"
        else
            fail "smoke: run_at within $FRESHNESS_DAYS days" \
                "run_at='$run_at' age=${age_days}d (parse_epoch=${run_at_epoch})"
        fi
    fi

    local overall_pass
    overall_pass="$(jq -r '.overall_pass // false' "$results_file")"
    _smoke_assert "smoke: overall_pass is true" \
        "$([[ "$overall_pass" == "true" ]] && echo true || echo false)" \
        "results file reports overall_pass=$overall_pass"

    for specialist in "${EXPECTED_SPECIALISTS[@]}"; do
        local present
        present="$(jq -r --arg name "$specialist" '.specialists[$name] != null' "$results_file")"
        if [[ "$present" != "true" ]]; then
            fail "smoke: $specialist results present" \
                "specialists.$specialist missing in $results_file"
            continue
        fi
        for subcheck in "${EXPECTED_SUBCHECKS[@]}"; do
            local total passed
            total="$(jq -r --arg s "$specialist" --arg c "$subcheck" \
                '.specialists[$s][$c].iterations // 0' "$results_file")"
            passed="$(jq -r --arg s "$specialist" --arg c "$subcheck" \
                '.specialists[$s][$c].passed // 0' "$results_file")"
            if [[ "$total" -eq 0 ]]; then
                local na_reason
                na_reason="$(jq -r --arg s "$specialist" --arg c "$subcheck" \
                    '.specialists[$s][$c].failure_reason // "no failure_reason recorded"' \
                    "$results_file")"
                skip "smoke: $specialist/$subcheck" "N/A — $na_reason"
            elif [[ "$total" -ge 3 && "$passed" -eq "$total" ]]; then
                pass "smoke: $specialist/$subcheck $passed/$total iterations passed"
            else
                local reason
                reason="$(jq -r --arg s "$specialist" --arg c "$subcheck" \
                    '.specialists[$s][$c].failure_reason // "no failure_reason recorded"' \
                    "$results_file")"
                fail "smoke: $specialist/$subcheck $passed/$total iterations passed" \
                    "spec requires all-pass over ≥ 3 iterations; failure_reason: $reason"
            fi
        done
    done

    # Synthesiser severity-lock sub-check (schema_version >= 2)
    local synth_present
    synth_present="$(jq -r '.synthesiser != null' "$results_file")"
    if [[ "$synth_present" != "true" ]]; then
        fail "smoke: synthesiser block present" \
            "synthesiser block missing in $results_file (schema_version 2 requires it)"
        return
    fi

    local synth_total synth_passed
    synth_total="$(jq -r '.synthesiser.synthesiser_severity_lock.iterations // 0' "$results_file")"
    synth_passed="$(jq -r '.synthesiser.synthesiser_severity_lock.passed // 0' "$results_file")"

    if [[ "$synth_total" -ge 3 && "$synth_passed" -eq "$synth_total" ]]; then
        pass "smoke: synthesiser/synthesiser_severity_lock $synth_passed/$synth_total iterations passed"
    else
        local synth_reason
        synth_reason="$(jq -r '.synthesiser.synthesiser_severity_lock.failure_reason // "no failure_reason recorded"' "$results_file")"
        fail "smoke: synthesiser/synthesiser_severity_lock $synth_passed/$synth_total iterations passed" \
            "spec requires all-pass over ≥ 3 iterations; failure_reason: $synth_reason"
    fi

    # Defensive per-iteration checks: any Dismissed placement or sub-50 confidence
    # is an outright fail even if `passed` field claims otherwise. Catches a driver
    # bug where `passed` was incorrectly computed against the underlying observations.
    local dismissed_count
    dismissed_count="$(jq -r '.synthesiser.synthesiser_severity_lock.tier_placements // [] | map(select(. == "Dismissed")) | length' "$results_file")"
    _smoke_assert "smoke: synthesiser tier_placements has no Dismissed entries" \
        "$([[ "$dismissed_count" -eq 0 ]] && echo true || echo false)" \
        "found $dismissed_count Dismissed placement(s) — policy violated"

    local sub_50_count
    sub_50_count="$(jq -r '.synthesiser.synthesiser_severity_lock.observed_confidences // [] | map(select(. < 50)) | length' "$results_file")"
    _smoke_assert "smoke: synthesiser observed_confidences all >= 50 (floor)" \
        "$([[ "$sub_50_count" -eq 0 ]] && echo true || echo false)" \
        "found $sub_50_count observation(s) with confidence < 50 — floor breached"

    local non_important_count
    non_important_count="$(jq -r '.synthesiser.synthesiser_severity_lock.observed_severities // [] | map(select(. != "Important")) | length' "$results_file")"
    _smoke_assert "smoke: synthesiser observed_severities all == Important (lock)" \
        "$([[ "$non_important_count" -eq 0 ]] && echo true || echo false)" \
        "found $non_important_count observation(s) with severity != Important — severity lock violated"
}
