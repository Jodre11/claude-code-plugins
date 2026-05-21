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
#   2. Any line containing a `[Vv]erdict` token followed within ~50 chars by
#      APPROVE | REQUEST_CHANGES, possibly wrapped in markdown emphasis. This
#      covers the orchestrator's freeform summary, which varies trial-to-trial:
#      "**Verdict (advisory only):** REQUEST_CHANGES — ..."
#      "Advisory verdict: **APPROVE** (Rubric row 4)."
#      "Verdict: APPROVE" / "**Verdict** APPROVE"

capture_parse_trial() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "capture_parse_trial: $stdout: not found" >&2
        return 1
    fi

    # 1. Extract the report block. Try in order:
    #   a. Synthesiser raw block (`# Code Review Report` header through next
    #      `Verdict: ` line) — would only appear if subagent stdout ever
    #      propagates to the parent; preserved as a future-proof path.
    #   b. Orchestrator's `## Summary` heading through end-of-file — the
    #      common shape under Class B.1 halts.
    #   c. Whole stdout — when the orchestrator emits a single freeform
    #      paragraph with no heading (also common in `-p` mode).
    # If stdout is non-empty, the report file is non-empty.
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
    if [[ -z "$report" ]]; then
        report=$(cat "$stdout")
    fi

    if [[ -n "$report" ]]; then
        printf '%s\n' "$report" > "$trial_dir/synthesiser-report.md"
    else
        : > "$trial_dir/synthesiser-report.md"
    fi

    # 2. Extract the verdict via the priority chain documented above.
    # First look for the synthesiser raw block (future-proof fallback). Then
    # fall back to a permissive freeform match: any line containing a verdict
    # token followed within ~50 chars by APPROVE | REQUEST_CHANGES, with
    # optional markdown emphasis around the value. The freeform fallback is
    # what hits in practice under `claude -p`.
    local verdict="INCONCLUSIVE"
    local match
    match=$(grep -m1 -E '^Verdict: (APPROVE|REQUEST_CHANGES)$' "$stdout" || true)
    if [[ "$match" =~ ^Verdict:[[:space:]](APPROVE|REQUEST_CHANGES)$ ]]; then
        verdict="${BASH_REMATCH[1]}"
    else
        match=$(grep -m1 -iE '[Vv]erdict[^[:alnum:]].{0,50}(APPROVE|REQUEST_CHANGES)' "$stdout" || true)
        if [[ "$match" =~ (APPROVE|REQUEST_CHANGES) ]]; then
            verdict="${BASH_REMATCH[1]}"
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
