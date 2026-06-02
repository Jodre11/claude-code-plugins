#!/usr/bin/env bash
# tests/ab/lib/agent_capture.sh — ruff-reviewer output parser.
# Sourced by tests/ab/run.sh in --mode per-agent. See full notes below
# set -euo pipefail.
set -euo pipefail

# Per-agent parser parameters. Each agent supplies the three things that
# differ across static specialists; the §7 state-machine body is shared.
#   heading       : the findings block heading, anchored (^...$)
#   skip_sentinel : ERE matching the tool-fully-skipped line
#   zero_state    : ERE matching the canonical zero-state line
# The rule-ID tokeniser (split on [ \t(], take token 1) is shared by ruff and
# eslint — kebab-case IDs have no internal spaces — so it is not parameterised.
_agent_capture_params() {
    # Accept both the short table key (used by the parser tests) and the full
    # `<name>-reviewer` form that run.sh carries in $_AB_CONFIG_AGENT.
    local agent="$1"
    case "$agent" in
        ruff|ruff-reviewer)
            _AC_HEADING='^## Ruff Findings$'
            _AC_SKIP='^Skipped — '
            _AC_ZERO='^0 findings — no Python files in diff\.'
            ;;
        eslint|eslint-reviewer)
            _AC_HEADING='^## ESLint Findings$'
            _AC_SKIP='^Skipped — eslint/biome not available'
            _AC_ZERO='^0 findings — no JS/TS files in diff\.'
            ;;
        *)
            echo "_agent_capture_params: unknown agent: $agent" >&2
            return 1
            ;;
    esac
}

# Public entry point: parse one trial for <agent>. Looks up the agent's
# parameters, then runs the shared §7 state-machine. Reads <trial-dir>/stdout.log
# and writes:
#   - <trial-dir>/agent-output.md       : the findings block
#   - <trial-dir>/findings.json         : sorted, normalised tuples
#   - <trial-dir>/findings_hash.txt     : sha256 of findings.json contents
#   - <trial-dir>/INCONCLUSIVE          : marker file present when the tool
#                                          did not run (e.g. ruff/eslint missing)
#
# Tuple shape: {file, line, rule_id, severity, confidence}.
# Severity is captured verbatim from the agent's output (Important | Critical
# | Suggestion); confidence is parsed as an integer.
# See agent_capture_parse_ruff_trial (now a shim) for the historical name.
agent_capture_parse_trial() {
    local agent="$1"
    local trial_dir="$2"
    local stdout="$trial_dir/stdout.log"

    if [[ ! -f "$stdout" ]]; then
        echo "agent_capture_parse_trial: $stdout: not found" >&2
        return 1
    fi
    _agent_capture_params "$agent" || return 1

    # 1. Detect the tool-fully-skipped state ('Skipped — ruff not available
    # on PATH.'). The partial-coverage variant ('Notebook files (.ipynb)
    # skipped — ruff < 0.6.0 and nbqa not available on PATH.') is NOT
    # treated as INCONCLUSIVE — it falls through to the finding parser
    # because .py findings may still be present.
    if grep -qE "$_AC_SKIP" "$stdout"; then
        : > "$trial_dir/INCONCLUSIVE"
        : > "$trial_dir/agent-output.md"
        echo '[]' > "$trial_dir/findings.json"
        printf '%s\n' "skipped" > "$trial_dir/findings_hash.txt"
        return 0
    fi

    # 2. Extract the findings block: from the heading through the last finding
    # entry, terminating before any subsequent top-level heading at the same
    # level. The heading line itself is consumed and `next`-ed, so it never
    # reaches the `^## ` terminator check.
    awk -v heading="$_AC_HEADING" '
        BEGIN { in_block = 0 }
        $0 ~ heading { in_block = 1; print; next }
        in_block && /^## / { in_block = 0 }
        in_block { print }
    ' "$stdout" > "$trial_dir/agent-output.md"

    # 3. Detect the canonical zero-state.
    if grep -qE "$_AC_ZERO" "$trial_dir/agent-output.md"; then
        echo '[]' > "$trial_dir/findings.json"
        _agent_capture_compute_hash "$trial_dir/findings.json" "$trial_dir/findings_hash.txt"
        return 0
    fi

    # 4. Parse per-finding blocks per the canonical static-analysis-context.md
    # §7 contract: bold-markdown bullets of the form `- **<Field>:** <value>`.
    # The parser is tolerant of:
    #   - backticks around path values (`bad.py`) and rule IDs (`F401`)
    #   - both `- **File:** path` and `- **File:** path:line` forms
    #   - separate `- **Line:** N` bullets when File doesn't carry the line
    #   - heading: `### Finding — [title]` (canonical §7 only post-3.1c).
    #     The `**Finding N**` shape was the prior drifted heading; Phase 3.1c
    #     pins the parser to canonical §7 so drifted shapes parse to zero
    #     findings (registers as DRIFT in the trial classifier).
    #   - non-tuple bullets (Description, Suggested fix, Reference) — parsed
    #     and discarded; they live in the visible report but are not part of
    #     the deterministic tuple.
    #
    # State machine: a finding boundary (### Finding, **Finding N**, or a
    # second **File:** for the same finding) flushes any complete pending
    # tuple. EOF also flushes. The tuple is emitted only when File,
    # rule_id, severity, confidence are all populated AND a line number is
    # known (either from the File `path:line` suffix or a separate **Line:**
    # bullet).
    #
    # The .findings.tsv scratch file is an intermediate artefact. Write it,
    # consume it in the sort | jq pipeline, then delete it explicitly. Do not
    # use a RETURN trap for cleanup: bash RETURN traps set inside a function
    # are NOT scoped to that function — they persist in the shell environment
    # and fire on subsequent function returns, causing 'unbound variable'
    # errors when captured locals (like $trial_dir) are no longer in scope.
    awk '
        function strip_backticks(s,    n) {
            # Trim leading and trailing backticks (a simple wrap, not arbitrary
            # markdown). Caller-tolerant: idempotent on already-clean strings.
            sub(/^`+/, "", s)
            sub(/`+$/, "", s)
            return s
        }
        function emit_if_complete(    eff_line, n, dummy) {
            # If the File field carried a `:line` suffix, split on the LAST
            # colon. Unix-only — Windows path drives are out of scope.
            eff_line = line
            if (eff_line == "" && file != "") {
                n = split(file, parts, ":")
                if (n >= 2) {
                    eff_line = parts[n]
                    # Reassemble the path without the trailing :line.
                    file_clean = parts[1]
                    for (i = 2; i <= n - 1; i++) file_clean = file_clean ":" parts[i]
                    file = file_clean
                }
            }
            if (in_finding_block && file != "" && eff_line != "" && rule_id != "" && severity != "" && confidence != "") {
                print file, eff_line, rule_id, severity, confidence
            }
            file = ""; line = ""; rule_id = ""; severity = ""; confidence = ""
        }
        BEGIN { OFS = "\t"; in_finding_block = 0; file = ""; line = ""; rule_id = ""; severity = ""; confidence = "" }
        # Finding boundary: a new heading or a second File: starts a new finding.
        /^### Finding/ { emit_if_complete(); in_finding_block = 1; next }
        # Bold-markdown field bullets.
        /^- \*\*File:\*\* / {
            if (file != "") emit_if_complete()
            v = substr($0, length("- **File:** ") + 1)
            file = strip_backticks(v)
            next
        }
        /^- \*\*Line:\*\* / {
            v = substr($0, length("- **Line:** ") + 1)
            line = strip_backticks(v)
            next
        }
        /^- \*\*Rule:\*\* / {
            v = substr($0, length("- **Rule:** ") + 1)
            v = strip_backticks(v)
            # First whitespace-separated token is the rule ID. Handles both
            # `F401 (Pyflakes)` and `F401(Pyflakes)` forms; if the agent
            # left a backtick mid-string (e.g. `F401`(Pyflakes)) the
            # strip_backticks above only handles wrap-only cases — split
            # on space first, then re-strip the first token.
            split(v, a, /[ \t(]/)
            rule_id = strip_backticks(a[1])
            next
        }
        /^- \*\*Severity:\*\* / {
            v = substr($0, length("- **Severity:** ") + 1)
            severity = strip_backticks(v)
            next
        }
        /^- \*\*Confidence:\*\* / {
            v = substr($0, length("- **Confidence:** ") + 1)
            confidence = strip_backticks(v)
            next
        }
        # All other lines (Description, Suggested fix, Reference, prose,
        # --- separators) are intentionally ignored. Pre-3.1c the parser
        # also tolerated Message / Detail bullets via the catch-all here;
        # post-3.1c those names no longer appear in canonical agent output.
        END { emit_if_complete() }
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

# Backward-compatible shim. Existing callers and tests reference this name;
# it now delegates to the parameterised entry point.
agent_capture_parse_ruff_trial() {
    agent_capture_parse_trial ruff "$1"
}

_agent_capture_compute_hash() {
    local in="$1"
    local out="$2"
    shasum -a 256 "$in" | awk '{print $1}' > "$out"
}

# Compare two findings.json files. Exit 0 if normalised tuple sets are
# identical, non-zero with a per-line diff on stderr otherwise. The hash
# comparison is the fast path; the diff is the human-readable fallback.
agent_capture_compare_findings() {
    local baseline="$1"
    local trial="$2"

    if [[ ! -f "$baseline" ]]; then
        echo "agent_capture_compare_findings: $baseline: not found" >&2
        return 1
    fi
    if [[ ! -f "$trial" ]]; then
        echo "agent_capture_compare_findings: $trial: not found" >&2
        return 1
    fi

    local b_hash t_hash
    b_hash=$(jq -c -S '.' "$baseline" | shasum -a 256 | awk '{print $1}')
    t_hash=$(jq -c -S '.' "$trial" | shasum -a 256 | awk '{print $1}')

    if [[ "$b_hash" == "$t_hash" ]]; then
        return 0
    fi

    echo "agent_capture_compare_findings: divergence detected" >&2
    diff -u <(jq -S '.' "$baseline") <(jq -S '.' "$trial") >&2 || true
    return 1
}
