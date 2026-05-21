#!/usr/bin/env bash
# tests/ab/lib/capture.sh — parse trial stdout into structured artefacts.
# See full notes below set -euo pipefail.

set -euo pipefail

# Sourced by tests/ab/run.sh. After lib/launch.sh runs a trial and writes
# stdout.log, capture_parse_trial extracts:
#   - synthesiser-report.md  : the report block (from "# Code Review Report"
#                              through the line after Verdict:)
#   - verdict.txt            : APPROVE | REQUEST_CHANGES | INCONCLUSIVE
#   - report-stats.json      : char count, line count, finding count proxy
#
# Phase 1 deliberately skips usage.json — the spec marks token-usage capture
# as best-effort and Phase 1 leans on wall-clock as the primary thinking-
# budget proxy.

capture_parse_trial() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "capture_parse_trial: $stdout: not found" >&2
        return 1
    fi

    # 1. Extract the report block. From the first '# Code Review Report' line
    # through the next 'Verdict: ' line (inclusive). If no Verdict: line is
    # found we treat the trial as truncated — do not emit a malformed report.
    local report
    report=$(awk '
        /^# Code Review Report$/ { in_block = 1 }
        in_block { print }
        in_block && /^Verdict: / { exit }
    ' "$stdout")

    if [[ -n "$report" ]]; then
        printf '%s\n' "$report" > "$trial_dir/synthesiser-report.md"
    else
        : > "$trial_dir/synthesiser-report.md"
    fi

    # 2. Extract the verdict line. The synthesiser contract restricts it to
    # APPROVE | REQUEST_CHANGES (enforced by an existing structural test).
    # Anything else — including an absent line — is INCONCLUSIVE.
    local verdict_line
    verdict_line=$(grep -m1 -E '^Verdict: (APPROVE|REQUEST_CHANGES)$' "$stdout" || true)

    local verdict="INCONCLUSIVE"
    if [[ "$verdict_line" =~ ^Verdict:[[:space:]](APPROVE|REQUEST_CHANGES)$ ]]; then
        verdict="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$verdict" > "$trial_dir/verdict.txt"

    # 3. Coarse stats: char count, line count, and a finding count proxy
    # (number of bullet lines in the report). A real report has tier headings
    # (## Important / ## Suggestions / ## Nits / etc.); the count is a
    # directional metric, not absolute — see the spec's scoring section.
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
