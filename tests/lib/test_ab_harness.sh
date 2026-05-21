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

test_ab_mutate_strips_ultrathink_keyword() {
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-before.md"
    local after="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-after.md"

    if [[ ! -f "$mutate" ]]; then
        fail "A/B mutate: lib/mutate.sh exists" "missing"
        return
    fi
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B mutate: fixtures present" "missing fixture pair"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$before" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_strip_ultrathink_keyword "$tmp"
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: ultrathink keyword stripped to expected form"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$tmp" | head -30 || true)
        fail "A/B mutate: ultrathink keyword stripped to expected form" "$diff_output"
    fi
    rm -f "$tmp"
}

test_ab_mutate_rewrites_agent_model() {
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local before="$REPO_ROOT/tests/ab/fixtures/agent-before.md"
    local after="$REPO_ROOT/tests/ab/fixtures/agent-after.md"

    if [[ ! -f "$mutate" ]]; then
        fail "A/B mutate: lib/mutate.sh exists" "missing"
        return
    fi
    if [[ ! -f "$before" || ! -f "$after" ]]; then
        fail "A/B mutate: agent fixtures present" "missing fixture pair"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$before" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_set_agent_model "$tmp" sonnet
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: agent model frontmatter rewritten"
    else
        local diff_output
        diff_output=$(diff -u --label expected --label actual "$after" "$tmp" | head -30 || true)
        fail "A/B mutate: agent model frontmatter rewritten" "$diff_output"
    fi
    rm -f "$tmp"
}

test_ab_mutate_strip_idempotent() {
    # Second strip must be a no-op — exit 0, no edit. Guards against accidental
    # double-strips eating non-ultrathink prompt content.
    local mutate="$REPO_ROOT/tests/ab/lib/mutate.sh"
    local after="$REPO_ROOT/tests/ab/fixtures/synthesiser-dispatch-after.md"

    if [[ ! -f "$mutate" || ! -f "$after" ]]; then
        skip "A/B mutate: idempotent strip" "missing helper or fixture"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "$after" "$tmp"

    (
        # shellcheck disable=SC1090
        source "$mutate"
        mutate_strip_ultrathink_keyword "$tmp"
    )

    if diff -q "$tmp" "$after" >/dev/null 2>&1; then
        pass "A/B mutate: second strip is a no-op"
    else
        fail "A/B mutate: second strip is a no-op" \
            "applying the strip twice produced different output — strip is not idempotent"
    fi
    rm -f "$tmp"
}
