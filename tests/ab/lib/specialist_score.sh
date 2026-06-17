#!/usr/bin/env bash
set -euo pipefail
# tests/ab/lib/specialist_score.sh — severity scorer for a single specialist's
# `## <Domain> Review Findings` block. Specialist output is flat: `### Finding`
# blocks, each carrying `- **File:** path:line` (or a separate `- **Line:**`
# bullet) and `- **Severity:** <tier>`. No tier sub-headings (unlike the
# synthesiser). Emits the severity of the finding that cites the planted
# file:line, or ABSENT when none does.

# specialist_score_severity <report.md> <file> <line>
# Emits one of: Critical | Important | Suggestion | ABSENT
specialist_score_severity() {
    local report="$1"
    local pfile="$2"
    local pline="$3"
    if [[ ! -f "$report" ]]; then
        echo "specialist_score_severity: $report: not found" >&2
        return 1
    fi

    awk -v pfile="$pfile" -v pline="$pline" '
        function line_matches(spec, target,    parts, lo, hi) {
            if (spec ~ /^[0-9]+$/)        return (spec + 0) == (target + 0)
            if (spec ~ /^[0-9]+-[0-9]+$/) {
                split(spec, parts, "-")
                lo = parts[1] + 0; hi = parts[2] + 0
                return (target + 0) >= lo && (target + 0) <= hi
            }
            return 0
        }
        function file_matches(v, pf, pl,    rest, sp) {
            if (substr(v, 1, length(pf) + 1) != pf ":") return 0
            rest = substr(v, length(pf) + 2)
            sp = index(rest, " ")
            if (sp > 0) rest = substr(rest, 1, sp - 1)
            return line_matches(rest, pl)
        }
        BEGIN { result = "ABSENT"; cur_sev = ""; cur_match = 0 }
        # A new finding block resets per-finding capture.
        /^#+ Finding/ { cur_sev = ""; cur_match = 0; infile = ""; next }
        /^- \*\*File:\*\* / {
            v = $0; sub(/^- \*\*File:\*\* /, "", v); gsub(/`/, "", v)
            infile = v
            if (file_matches(v, pfile, pline)) cur_match = 1
            if (cur_match && cur_sev != "") result = cur_sev
            next
        }
        /^- \*\*Line:\*\* / {
            v = $0; sub(/^- \*\*Line:\*\* /, "", v); gsub(/`/, "", v)
            if (substr(infile, 1, length(pfile)) == pfile && line_matches(v, pline)) cur_match = 1
            if (cur_match && cur_sev != "") result = cur_sev
            next
        }
        /^- \*\*Severity:\*\* / {
            v = $0; sub(/^- \*\*Severity:\*\* /, "", v); gsub(/`/, "", v)
            sub(/ .*$/, "", v)        # drop trailing prose / parenthetical
            cur_sev = v
            if (cur_match) result = cur_sev
            next
        }
        END { print result }
    ' "$report"
}
