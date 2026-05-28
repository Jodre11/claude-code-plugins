#!/usr/bin/env bash
# tests/ab/lib/agent_capture.sh — ruff-reviewer output parser.
# Sourced by tests/ab/run.sh in --mode per-agent. See full notes below
# set -euo pipefail.
set -euo pipefail

# Parse one ruff-reviewer trial. Reads <trial-dir>/stdout.log and writes:
#   - <trial-dir>/agent-output.md       : the ## Ruff Findings block
#   - <trial-dir>/findings.json         : sorted, normalised tuples
#   - <trial-dir>/findings_hash.txt     : sha256 of findings.json contents
#   - <trial-dir>/INCONCLUSIVE          : marker file present when the tool
#                                          did not run (e.g. ruff missing)
#
# Tuple shape: {file, line, rule_id, severity, confidence}.
# Severity is captured verbatim from the agent's output (Important | Critical
# | Suggestion); confidence is parsed as an integer.
agent_capture_parse_ruff_trial() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "agent_capture_parse_ruff_trial: $stdout: not found" >&2
        return 1
    fi

    # 1. Detect the tool-skipped state. The ruff-reviewer agent emits the
    # exact line 'Skipped — ruff not available on PATH.' or the partial
    # coverage variant. Either marks the trial as INCONCLUSIVE.
    if grep -qE '^Skipped — ' "$stdout"; then
        : > "$trial_dir/INCONCLUSIVE"
        : > "$trial_dir/agent-output.md"
        echo '[]' > "$trial_dir/findings.json"
        printf '%s\n' "skipped" > "$trial_dir/findings_hash.txt"
        return 0
    fi

    # 2. Extract the ## Ruff Findings block: from that heading through the
    # last finding entry, terminating before any subsequent top-level heading
    # at the same level.
    awk '
        BEGIN { in_block = 0 }
        /^## Ruff Findings$/ { in_block = 1; print; next }
        in_block && /^## / && !/^## Ruff Findings$/ { in_block = 0 }
        in_block { print }
    ' "$stdout" > "$trial_dir/agent-output.md"

    # 3. Detect the canonical zero-state.
    if grep -qE '^0 findings — no Python files in diff\.' "$trial_dir/agent-output.md"; then
        echo '[]' > "$trial_dir/findings.json"
        _agent_capture_compute_hash "$trial_dir/findings.json" "$trial_dir/findings_hash.txt"
        return 0
    fi

    # 4. Parse per-finding blocks. Each finding is a contiguous run of:
    #    File: <file>
    #    Line: <line>
    #    Rule: <code> (<category>)
    #    Severity: <severity>
    #    Confidence: <int>
    #    Description: ...
    # Description is intentionally NOT included in the tuple — descriptive
    # prose is rephrased run-to-run by the model and must not affect the hash.
    awk '
        BEGIN { state = "between"; OFS = "\t" }
        /^File: / { file = substr($0, 7); state = "in_finding"; next }
        state == "in_finding" && /^Line: / {
            line = substr($0, 7)
            next
        }
        state == "in_finding" && /^Rule: / {
            # "F401 (Pyflakes)" -> rule_id="F401"
            rule = substr($0, 7)
            split(rule, a, " ")
            rule_id = a[1]
            next
        }
        state == "in_finding" && /^Severity: / {
            severity = substr($0, 11)
            next
        }
        state == "in_finding" && /^Confidence: / {
            confidence = substr($0, 13)
            print file, line, rule_id, severity, confidence
            file = ""; line = ""; rule_id = ""; severity = ""; confidence = ""
            state = "between"
            next
        }
    ' "$trial_dir/agent-output.md" > "$trial_dir/.findings.tsv"

    # 5. Sort tuples deterministically (file, line, rule_id) and emit JSON.
    sort -t $'\t' -k1,1 -k2,2n -k3,3 "$trial_dir/.findings.tsv" \
        | jq -R -s -c '
            split("\n")
            | map(select(length > 0) | split("\t") | {
                file: .[0],
                line: (.[1] | tonumber),
                rule_id: .[2],
                severity: .[3],
                confidence: (.[4] | tonumber)
              })
          ' > "$trial_dir/findings.json"
    rm -f "$trial_dir/.findings.tsv"

    _agent_capture_compute_hash "$trial_dir/findings.json" "$trial_dir/findings_hash.txt"
}

_agent_capture_compute_hash() {
    local in="$1"
    local out="$2"
    shasum -a 256 "$in" | awk '{print $1}' > "$out"
}
