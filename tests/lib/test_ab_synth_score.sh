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
