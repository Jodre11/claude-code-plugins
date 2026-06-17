#!/usr/bin/env bash
# Unit tests for tests/ab/lib/synth_score.sh — maps the tier heading a planted
# finding lands under to a severity token. Pure parser; no model calls.

_synthscore_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

test_ab_synth_score_important() {
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score important" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report="$root/tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    if [[ "$got" == "Important" ]]; then
        pass "synth score: important report scores Important"
    else
        fail "synth score: important report scores Important" "got '$got'"
    fi
}

test_ab_synth_score_suggestion() {
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score suggestion" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report="$root/tests/ab/corpus/synth-hazard-hit/expected/sample-report-suggestion.md"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    if [[ "$got" == "Suggestion" ]]; then
        pass "synth score: suggestion report scores Suggestion"
    else
        fail "synth score: suggestion report scores Suggestion" "got '$got'"
    fi
}

test_ab_synth_score_important_trailing_prose() {
    # The live opus arm-B reports cite the planted line as
    # "lib/cache.py:42 (comment at lines 39-41)". The scorer must read the
    # leading linespec token and ignore trailing prose.
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score trailing prose" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report
    report=$(mktemp)
    printf '%s\n' \
        '## Consensus Findings' \
        '' \
        '### Important' \
        '#### Finding #1 — comment hazard [correctness]' \
        '- **File:** lib/cache.py:42 (comment at lines 39-41)' \
        '- **Confidence:** 85' \
        > "$report"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    rm -f "$report"
    if [[ "$got" == "Important" ]]; then
        pass "synth score: File with trailing prose scores Important"
    else
        fail "synth score: File with trailing prose scores Important" "got '$got'"
    fi
}

test_ab_synth_score_important_line_range() {
    # The live opus arm-B reports also cite the planted line as a range that
    # brackets it, "lib/cache.py:39-42". The planted line is the load-bearing
    # statement, so a range containing it refers to the planted finding.
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score line range" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report
    report=$(mktemp)
    printf '%s\n' \
        '## Consensus Findings' \
        '' \
        '### Important' \
        '#### Finding #1 — comment hazard [correctness]' \
        '- **File:** lib/cache.py:39-42' \
        '- **Confidence:** 85' \
        > "$report"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    rm -f "$report"
    if [[ "$got" == "Important" ]]; then
        pass "synth score: File line range bracketing planted line scores Important"
    else
        fail "synth score: File line range bracketing planted line scores Important" "got '$got'"
    fi
}

test_ab_synth_score_range_excludes_outside_line() {
    # A range that does NOT bracket the planted line must not match — guards
    # against the range matcher being too permissive.
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score range exclusion" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report
    report=$(mktemp)
    printf '%s\n' \
        '## Consensus Findings' \
        '' \
        '### Important' \
        '#### Finding #1 — unrelated [correctness]' \
        '- **File:** lib/cache.py:10-20' \
        '- **Confidence:** 85' \
        > "$report"
    local got
    got=$(synth_score_severity "$report" "lib/cache.py" "42")
    rm -f "$report"
    if [[ "$got" == "ABSENT" ]]; then
        pass "synth score: range excluding planted line scores ABSENT"
    else
        fail "synth score: range excluding planted line scores ABSENT" "got '$got'"
    fi
}

test_ab_synth_score_absent() {
    local root
    root=$(_synthscore_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/synth_score.sh" ]]; then
        skip "synth score absent" "synth_score.sh not found"
        return
    fi
    # shellcheck source=/dev/null
    source "$root/tests/ab/lib/synth_score.sh"
    local report="$root/tests/ab/corpus/synth-hazard-hit/expected/sample-report-important.md"
    local got
    got=$(synth_score_severity "$report" "lib/other.py" "99")
    if [[ "$got" == "ABSENT" ]]; then
        pass "synth score: unplanted file scores ABSENT"
    else
        fail "synth score: unplanted file scores ABSENT" "got '$got'"
    fi
}
