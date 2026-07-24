#!/usr/bin/env bash
# Structural checks for scripts/adoption-glance.sh — existence, executable bit, and syntax.

test_adoption_glance_exists_and_is_executable() {
    local script="$REPO_ROOT/scripts/adoption-glance.sh"
    if [[ -f "$script" ]]; then
        pass "scripts/adoption-glance.sh exists"
    else
        fail "scripts/adoption-glance.sh exists" "not found: scripts/adoption-glance.sh"
        return
    fi

    if [[ -x "$script" ]]; then
        pass "scripts/adoption-glance.sh is executable"
    else
        fail "scripts/adoption-glance.sh is executable" "file exists but lacks executable bit"
    fi
}

test_adoption_glance_syntax() {
    local script="$REPO_ROOT/scripts/adoption-glance.sh"
    if [[ ! -f "$script" ]]; then
        skip "scripts/adoption-glance.sh syntax" "file not found — covered by existence test"
        return
    fi

    if bash -n "$script" 2>/dev/null; then
        pass "scripts/adoption-glance.sh passes bash -n syntax check"
    else
        local err
        err=$(bash -n "$script" 2>&1)
        fail "scripts/adoption-glance.sh passes bash -n syntax check" "$err"
    fi
}
