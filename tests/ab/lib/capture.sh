#!/usr/bin/env bash
# tests/ab/lib/capture.sh — parse trial stdout into structured artefacts.
# See full notes below set -euo pipefail.

set -euo pipefail

# Sourced by tests/ab/run.sh. After lib/launch.sh runs a trial and writes
# stdout.log, capture_parse_trial extracts:
#   - synthesiser-report.md  : the orchestrator's top-level summary block
#                              (the synthesiser's own report does NOT reach
#                              the parent stdout under `claude -p`; the
#                              orchestrator's Step 6 / Step 7 summary does)
#   - verdict.txt            : APPROVE | REQUEST_CHANGES | INCONCLUSIVE
#   - report-stats.json      : char count, line count, finding count proxy
#
# Phase 1 deliberately skips usage.json — the spec marks token-usage capture
# as best-effort and Phase 1 leans on wall-clock as the primary thinking-
# budget proxy.
#
# Verdict regex priority (first match wins):
#   1. `^Verdict: (APPROVE|REQUEST_CHANGES)$` — synthesiser raw block (would
#      appear if subagent stdout ever propagates; preserved as a future-proof
#      fallback).
#   2. `Verdict (advisory only):** (APPROVE|REQUEST_CHANGES)` — the
#      orchestrator's Class B.1 halt summary, emitted when the PR is already
#      closed or merged at submission time.
#   3. `^\*\*Verdict\*\* (APPROVE|REQUEST_CHANGES)$` — the orchestrator's
#      Class C posting summary for normal open-PR runs.

capture_parse_trial() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "capture_parse_trial: $stdout: not found" >&2
        return 1
    fi

    # 1. Extract the report block. Prefer the synthesiser raw header if present
    # (would only appear if subagent stdout propagation changes), otherwise
    # fall back to the orchestrator's "## Summary" block, which is what `-p`
    # mode actually emits today. If neither marker is found the report file is
    # left empty.
    local report
    report=$(awk '
        /^# Code Review Report$/ { in_block = 1 }
        in_block { print }
        in_block && /^Verdict: / { exit }
    ' "$stdout")
    if [[ -z "$report" ]]; then
        report=$(awk '
            /^## Summary$/ { in_block = 1 }
            in_block { print }
        ' "$stdout")
    fi

    if [[ -n "$report" ]]; then
        printf '%s\n' "$report" > "$trial_dir/synthesiser-report.md"
    else
        : > "$trial_dir/synthesiser-report.md"
    fi

    # 2. Extract the verdict via the priority chain documented above.
    local verdict="INCONCLUSIVE"
    local match
    match=$(grep -m1 -E '^Verdict: (APPROVE|REQUEST_CHANGES)$' "$stdout" || true)
    if [[ "$match" =~ ^Verdict:[[:space:]](APPROVE|REQUEST_CHANGES)$ ]]; then
        verdict="${BASH_REMATCH[1]}"
    else
        match=$(grep -m1 -E 'Verdict \(advisory only\):\*\* (APPROVE|REQUEST_CHANGES)' "$stdout" || true)
        if [[ "$match" =~ Verdict[[:space:]]\(advisory[[:space:]]only\):\*\*[[:space:]](APPROVE|REQUEST_CHANGES) ]]; then
            verdict="${BASH_REMATCH[1]}"
        else
            match=$(grep -m1 -E '^\*\*Verdict\*\*[[:space:]](APPROVE|REQUEST_CHANGES)' "$stdout" || true)
            if [[ "$match" =~ ^\*\*Verdict\*\*[[:space:]](APPROVE|REQUEST_CHANGES) ]]; then
                verdict="${BASH_REMATCH[1]}"
            fi
        fi
    fi
    printf '%s\n' "$verdict" > "$trial_dir/verdict.txt"

    # 3. Coarse stats: char count, line count, and a finding count proxy
    # (number of bullet lines in the report). The count is a directional
    # metric, not absolute — see the spec's scoring section.
    local chars lines findings
    chars=$(wc -c < "$trial_dir/synthesiser-report.md" | tr -d '[:space:]')
    lines=$(wc -l < "$trial_dir/synthesiser-report.md" | tr -d '[:space:]')
    findings=$(grep -cE '^- ' "$trial_dir/synthesiser-report.md" || true)

    jq -n \
        --argjson chars "$chars" \
        --argjson lines "$lines" \
        --argjson findings "$findings" \
        '{report_chars: $chars, report_lines: $lines, finding_count: $findings}' \
        > "$trial_dir/report-stats.json"
}
