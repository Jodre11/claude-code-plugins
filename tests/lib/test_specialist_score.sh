#!/usr/bin/env bash
# tests/lib/test_specialist_score.sh — unit tests for the specialist severity scorer.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/ab/lib/specialist_score.sh"

test_specialist_score_important_hit() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
## Reuse Review Findings

### Finding — reimplements canonical formatCurrency
- **File:** src/pay.ts:42
- **Confidence:** 80
- **Severity:** Important
- **Description:** reimplements an existing tested helper
- **Suggested fix:** import it
EOF
    local got
    got=$(specialist_score_severity "$tmp" "src/pay.ts" 42)
    rm -f "$tmp"
    [[ "$got" == "Important" ]] || { echo "expected Important, got $got" >&2; return 1; }
}

test_specialist_score_absent_when_not_cited() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
## Reuse Review Findings

0 findings.
EOF
    local got
    got=$(specialist_score_severity "$tmp" "src/pay.ts" 42)
    rm -f "$tmp"
    [[ "$got" == "ABSENT" ]] || { echo "expected ABSENT, got $got" >&2; return 1; }
}

test_specialist_score_range_brackets_planted_line() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
## Style Review Findings

### Finding — misleading name
- **File:** src/util.ts:39-44
- **Confidence:** 75
- **Severity:** Suggestion
- **Description:** name lies about behaviour
- **Suggested fix:** rename
EOF
    local got
    got=$(specialist_score_severity "$tmp" "src/util.ts" 42)
    rm -f "$tmp"
    [[ "$got" == "Suggestion" ]] || { echo "expected Suggestion, got $got" >&2; return 1; }
}

run_specialist_score_tests() {
    test_specialist_score_important_hit
    test_specialist_score_absent_when_not_cited
    test_specialist_score_range_brackets_planted_line
    echo "test_specialist_score: all passed"
}

run_specialist_score_tests
