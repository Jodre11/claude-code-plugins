#!/usr/bin/env bash
# tests/ab/lib/synth_score.sh — severity tier scorer for synthesiser reports.
set -euo pipefail
# Tracks the current tier heading (### Critical / ### Important / ### Suggestions)
# and matches the planted file:line inside a #### Finding block.

# synth_score_severity <report.md> <file> <line>
# Emits one of: Critical | Important | Suggestion | Contested | Dismissed | ABSENT
synth_score_severity() {
    local report="$1"
    local pfile="$2"
    local pline="$3"
    if [[ ! -f "$report" ]]; then
        echo "synth_score_severity: $report: not found" >&2
        return 1
    fi

    awk -v pfile="$pfile" -v pline="$pline" '
        BEGIN { section=""; tier=""; result="ABSENT" }
        # Top-level sections.
        /^## Dismissed Findings$/ { section="dismissed"; tier=""; next }
        /^## Contested Findings$/ { section="contested"; tier=""; next }
        /^## Consensus Findings$/ { section="consensus"; tier=""; next }
        /^## Synthesiser Findings$/ { section="synthesiser"; tier=""; next }
        /^## / { section="other"; tier=""; next }
        # Tier sub-headings within Consensus.
        /^### Critical$/    { tier="Critical"; next }
        /^### Important$/   { tier="Important"; next }
        /^### Suggestions$/ { tier="Suggestion"; next }
        # A finding boundary resets the per-finding file capture.
        /^#### Finding / { infile=""; next }
        # File bullet — accept "path:line" or a bare "path".
        /^- \*\*File:\*\* / {
            v=$0
            sub(/^- \*\*File:\*\* /, "", v)
            gsub(/`/, "", v)
            infile=v
            # If File carries :line, check immediately.
            target=pfile ":" pline
            if (v == target) {
                if (section=="dismissed") result="Dismissed"
                else if (section=="contested") result="Contested"
                else if (tier!="") result=tier
            }
            next
        }
        # Separate Line bullet (when File had no :line suffix).
        /^- \*\*Line:\*\* / {
            v=$0
            sub(/^- \*\*Line:\*\* /, "", v)
            gsub(/`/, "", v)
            if (infile==pfile && v==pline) {
                if (section=="dismissed") result="Dismissed"
                else if (section=="contested") result="Contested"
                else if (tier!="") result=tier
            }
            next
        }
        END { print result }
    ' "$report"
}
