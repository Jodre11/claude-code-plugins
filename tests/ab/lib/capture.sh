#!/usr/bin/env bash
# tests/ab/lib/capture.sh — parse trial stdout into structured artefacts.
# See full notes below set -euo pipefail.

set -euo pipefail

# Sourced by tests/ab/run.sh. After lib/launch.sh runs a trial and writes
# stdout.log, capture_parse_trial extracts:
#   - synthesiser-report.md  : the orchestrator's full report block as
#                              emitted to parent stdout (synthesiser's own
#                              transcript does not propagate under -p)
#   - verdict.txt            : APPROVE | REQUEST_CHANGES | INCONCLUSIVE
#   - report-stats.json      : char count, line count, finding count
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
#
# Finding count priority (first non-zero match wins):
#   1. "N consensus findings" — the orchestrator's canonical wording in the
#      Summary line. Authoritative count.
#   2. "N findings total" / "N findings" — looser variants from less-formatted
#      summaries.
#   3. Bullet-line proxy (`^- `) — last-resort fallback for reports that emit
#      pure-bullet lists. Returns 0 if none of the above hit and there are no
#      bullets, indicating capture should be reviewed rather than treated as
#      a real zero.

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
    #   b. From the first markdown heading (`^# `, `^## `, etc.) through end
    #      of stdout — the common shape under `-p` when the orchestrator
    #      structures the response (Class B.1 halt, normal posting summary,
    #      mixed table/bullet bodies).
    #   c. Whole stdout — fallback for trials that emit a single freeform
    #      paragraph with no heading at all.
    # If stdout is non-empty, the report file is non-empty.
    local report
    report=$(awk '
        /^# Code Review Report$/ { in_block = 1 }
        in_block { print }
        in_block && /^Verdict: / { exit }
    ' "$stdout")
    if [[ -z "$report" ]]; then
        report=$(awk '
            /^#{1,6} / { in_block = 1 }
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

    # 3. Stats: char count, line count, finding count.
    # Finding count uses the priority chain documented in the file header:
    #   a. "N consensus findings" (orchestrator's canonical count).
    #   b. "N findings total" / "N findings" (looser fallback).
    #   c. `^- ` bullet line count (last-resort proxy).
    local chars lines findings
    chars=$(wc -c < "$trial_dir/synthesiser-report.md" | tr -d '[:space:]')
    lines=$(wc -l < "$trial_dir/synthesiser-report.md" | tr -d '[:space:]')

    findings=0
    local found_match
    found_match=$(grep -m1 -oE '[0-9]+ consensus findings' "$trial_dir/synthesiser-report.md" || true)
    if [[ -n "$found_match" ]]; then
        findings="${found_match%% *}"
    else
        found_match=$(grep -m1 -oE '[0-9]+ findings? total' "$trial_dir/synthesiser-report.md" || true)
        if [[ -n "$found_match" ]]; then
            findings="${found_match%% *}"
        else
            found_match=$(grep -m1 -oE '[0-9]+ findings' "$trial_dir/synthesiser-report.md" || true)
            if [[ -n "$found_match" ]]; then
                findings="${found_match%% *}"
            else
                findings=$(grep -cE '^- ' "$trial_dir/synthesiser-report.md" || true)
            fi
        fi
    fi

    jq -n \
        --argjson chars "$chars" \
        --argjson lines "$lines" \
        --argjson findings "$findings" \
        '{report_chars: $chars, report_lines: $lines, finding_count: $findings}' \
        > "$trial_dir/report-stats.json"
}
