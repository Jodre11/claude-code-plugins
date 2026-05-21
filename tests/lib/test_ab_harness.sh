#!/usr/bin/env bash
# Structural tests for the A/B test harness scaffold and lib scripts.

_ab_dir() {
    echo "$REPO_ROOT/tests/ab"
}

test_ab_scaffold_present() {
    local ab
    ab=$(_ab_dir)
    if [[ ! -d "$ab" ]]; then
        fail "A/B harness: tests/ab/ exists" "directory missing"
        return
    fi

    assert_file_exists "tests/ab/run.sh" "A/B harness: run.sh exists"
    assert_dir_exists "tests/ab/lib" "A/B harness: lib/ exists"
    assert_dir_exists "tests/ab/configs" "A/B harness: configs/ exists"
    assert_dir_exists "tests/ab/fixtures" "A/B harness: fixtures/ exists"

    if [[ -x "$ab/run.sh" ]]; then
        pass "A/B harness: run.sh is executable"
    else
        fail "A/B harness: run.sh is executable" "missing +x bit on tests/ab/run.sh"
    fi
}

test_ab_runs_dir_gitignored() {
    if grep -qE '^tests/ab/runs/?$' "$REPO_ROOT/.gitignore"; then
        pass "A/B harness: tests/ab/runs/ is gitignored"
    else
        fail "A/B harness: tests/ab/runs/ is gitignored" \
            "expected an exact line 'tests/ab/runs/' in .gitignore so trial output never accidentally lands in commits"
    fi
}

test_ab_shell_scripts_have_strict_mode() {
    local script
    for script in "$REPO_ROOT"/tests/ab/run.sh "$REPO_ROOT"/tests/ab/lib/*.sh; do
        if [[ ! -f "$script" ]]; then
            continue
        fi
        local rel="${script#"$REPO_ROOT/"}"
        if head -5 "$script" | grep -qE '^set -euo pipefail$'; then
            pass "A/B harness: $rel uses set -euo pipefail"
        else
            fail "A/B harness: $rel uses set -euo pipefail" \
                "every shell script in tests/ab/ must declare strict mode in its first 5 lines"
        fi
        if head -1 "$script" | grep -qE '^#!/usr/bin/env bash$'; then
            pass "A/B harness: $rel has /usr/bin/env bash shebang"
        else
            fail "A/B harness: $rel has /usr/bin/env bash shebang" \
                "first line must be '#!/usr/bin/env bash' for portability"
        fi
    done
}
