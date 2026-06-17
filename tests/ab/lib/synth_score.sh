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
        # A line spec matches the planted line when it is the bare number, or a
        # "N-M" range that contains it. Models cite the same planted line three
        # observed ways: "42", "42 (comment at lines 39-41)", and "39-42"; the
        # planted line is the load-bearing statement, not the whole span, so a
        # range that brackets it still refers to the planted finding.
        function line_matches(spec, target,    parts, lo, hi) {
            if (spec ~ /^[0-9]+$/)            return (spec + 0) == (target + 0)
            if (spec ~ /^[0-9]+-[0-9]+$/) {
                split(spec, parts, "-")
                lo = parts[1] + 0; hi = parts[2] + 0
                return (target + 0) >= lo && (target + 0) <= hi
            }
            return 0
        }
        # File value form is "<path>:<linespec>[ <trailing prose>]". Require the
        # exact planted path as prefix, then test the leading linespec token.
        function file_matches(v, pf, pl,    rest, sp) {
            if (substr(v, 1, length(pf) + 1) != pf ":") return 0
            rest = substr(v, length(pf) + 2)
            sp = index(rest, " ")
            if (sp > 0) rest = substr(rest, 1, sp - 1)
            return line_matches(rest, pl)
        }
        function record(    s, t) {
            s = section; t = tier
            if (s == "dismissed") result = "Dismissed"
            else if (s == "contested") result = "Contested"
            else if (t != "") result = t
        }
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
        # File bullet — "path:linespec" (possibly with trailing prose) or bare path.
        /^- \*\*File:\*\* / {
            v=$0
            sub(/^- \*\*File:\*\* /, "", v)
            gsub(/`/, "", v)
            infile=v
            if (file_matches(v, pfile, pline)) record()
            next
        }
        # Separate Line bullet (when File had no :line suffix).
        /^- \*\*Line:\*\* / {
            v=$0
            sub(/^- \*\*Line:\*\* /, "", v)
            gsub(/`/, "", v)
            if (substr(infile, 1, length(pfile)) == pfile && line_matches(v, pline)) record()
            next
        }
        END { print result }
    ' "$report"
}
