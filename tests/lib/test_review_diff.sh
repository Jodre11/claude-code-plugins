#!/usr/bin/env bash
# Tests for the deterministic diff-construction helper bin/review-diff and its
# wiring into the three pipeline consumers.
#
# The helper exists to make the two-arg-vs-three-dot syntax choice
# non-negotiable: an orchestrator hand-running two-arg `git diff $BASE $HEAD`
# against an un-rebased branch measures the stale base's newer commits as
# spurious deletions (finance-erp PR #593: 11 files/157 deletions measured vs
# GitHub's true 4 files/0 deletions). These tests prove the helper picks the
# right syntax from $EMPTY_TREE_MODE and refuses malformed input.

_rd_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Build a fixture where 'feature' was cut from an older 'main' and 'main' then
# advanced independently — the exact divergence that makes two-arg vs three-dot
# diverge. Echoes: "<repoDir> <featureSha> <emptyTreeSha>". Caller rm -rf's repo.
_rd_make_divergent_fixture() {
    local work
    work=$(mktemp -d)
    git init -q -b main "$work"
    git -C "$work" config user.email "t@example.com"
    git -C "$work" config user.name "T"
    printf 'a\n' > "$work/f.txt"
    git -C "$work" add f.txt
    git -C "$work" commit -qm base0
    git -C "$work" checkout -q -b feature
    printf 'a\nb\n' > "$work/f.txt"
    git -C "$work" add f.txt
    git -C "$work" commit -qm feat
    # main advances with a file 'feature' never saw.
    git -C "$work" checkout -q main
    printf 'x\ny\nz\nw\n' > "$work/other.txt"
    git -C "$work" add other.txt
    git -C "$work" commit -qm advance-main
    printf '%s %s %s\n' \
        "$work" \
        "$(git -C "$work" rev-parse feature)" \
        "$(git -C "$work" hash-object -t tree /dev/null)"
}

test_review_diff_helper_present_and_executable() {
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ -x "$helper" ]]; then
        pass "review-diff: helper present and executable"
    else
        fail "review-diff: helper present and executable" "missing or not +x: $helper"
    fi
}

test_review_diff_three_dot_ignores_stale_base_commits() {
    # The core regression: three-dot must report ONLY the feature branch's own
    # change (f.txt), never main's independently-added other.txt as a deletion.
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ ! -x "$helper" ]]; then
        fail "review-diff: three-dot ignores stale base commits" "helper missing"
        return
    fi
    local work feat empty out files patch dels
    read -r work feat empty < <(_rd_make_divergent_fixture)
    out=$(mktemp -d)

    "$helper" emit "$work" main "$feat" false "" "$out" >/dev/null

    files=$(tr '\n' ',' < "$out/changed-files.txt")
    assert_equals "f.txt," "$files" \
        "review-diff: three-dot changed-files is exactly f.txt (not other.txt)"

    # No deletion lines at all — a two-arg diff would show other.txt's 4 lines
    # as deletions.
    dels=$(grep -c '^-[^-]' "$out/review-diff.patch" || true)
    assert_equals "0" "$dels" \
        "review-diff: three-dot patch has zero spurious deletions"

    rm -rf "$work" "$out"
}

test_review_diff_two_arg_contrast_confirms_fixture() {
    # Sanity check on the fixture itself: a two-arg diff against the tip of main
    # DOES surface other.txt as a deletion. This proves the fixture reproduces
    # the #593 hazard, so the three-dot test above is meaningfully protective.
    local work feat empty dels
    read -r work feat empty < <(_rd_make_divergent_fixture)

    # Two-arg main..feature-head equivalent: `git diff main $feat`.
    dels=$(git -C "$work" diff main "$feat" | grep -c '^-[^-]' || true)
    if [[ "$dels" -ge 1 ]]; then
        pass "review-diff: fixture confirmed — two-arg diff shows spurious deletions"
    else
        fail "review-diff: fixture confirmed — two-arg diff shows spurious deletions" \
            "expected >=1 deletion under two-arg, got $dels (fixture not divergent?)"
    fi

    rm -rf "$work"
}

test_review_diff_empty_tree_mode_uses_two_arg() {
    # Empty-tree mode is the ONE legitimate two-arg case: the empty tree has no
    # history for a merge base. The helper must accept it and emit the whole
    # feature tree as additions.
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ ! -x "$helper" ]]; then
        fail "review-diff: empty-tree mode uses two-arg" "helper missing"
        return
    fi
    local work feat empty out files
    read -r work feat empty < <(_rd_make_divergent_fixture)
    out=$(mktemp -d)

    "$helper" emit "$work" "$empty" "$feat" true "" "$out" >/dev/null

    # Against the empty tree, the feature head shows its whole tree as new.
    # other.txt was added on main *after* feature diverged, so it is not in the
    # feature tree — only f.txt is.
    files=$(sort < "$out/changed-files.txt" | tr '\n' ',')
    assert_equals "f.txt," "$files" \
        "review-diff: empty-tree two-arg emits full feature tree (f.txt)"

    rm -rf "$work" "$out"
}

test_review_diff_path_scope_restricts_output() {
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ ! -x "$helper" ]]; then
        fail "review-diff: path scope restricts output" "helper missing"
        return
    fi
    local work feat empty out files
    read -r work feat empty < <(_rd_make_divergent_fixture)
    out=$(mktemp -d)

    # Scope to a path that the feature diff does not touch -> empty result.
    "$helper" emit "$work" main "$feat" false "does-not-exist" "$out" >/dev/null
    files=$(tr -d '\n' < "$out/changed-files.txt")
    assert_equals "" "$files" \
        "review-diff: path scope with no matches yields empty changed-files"

    rm -rf "$work" "$out"
}

test_review_diff_rejects_bad_empty_tree_mode() {
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ ! -x "$helper" ]]; then
        fail "review-diff: rejects bad emptyTreeMode" "helper missing"
        return
    fi
    local work feat empty out rc
    read -r work feat empty < <(_rd_make_divergent_fixture)
    out=$(mktemp -d)

    set +e
    "$helper" emit "$work" main "$feat" maybe "" "$out" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        pass "review-diff: rejects emptyTreeMode other than true/false"
    else
        fail "review-diff: rejects emptyTreeMode other than true/false" "exit 0"
    fi

    rm -rf "$work" "$out"
}

test_review_diff_rejects_bad_head_sha() {
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ ! -x "$helper" ]]; then
        fail "review-diff: rejects bad head SHA" "helper missing"
        return
    fi
    local work feat empty out rc
    read -r work feat empty < <(_rd_make_divergent_fixture)
    out=$(mktemp -d)

    set +e
    "$helper" emit "$work" main "not-a-sha" false "" "$out" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        pass "review-diff: rejects non-40-hex head SHA"
    else
        fail "review-diff: rejects non-40-hex head SHA" "exit 0"
    fi

    rm -rf "$work" "$out"
}

test_review_diff_rejects_path_scope_traversal() {
    local helper
    helper="$(_rd_cr_dir)/bin/review-diff"
    if [[ ! -x "$helper" ]]; then
        fail "review-diff: rejects path-scope traversal" "helper missing"
        return
    fi
    local work feat empty out rc
    read -r work feat empty < <(_rd_make_divergent_fixture)
    out=$(mktemp -d)

    set +e
    "$helper" emit "$work" main "$feat" false "../etc" "$out" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        pass "review-diff: rejects path scope containing .."
    else
        fail "review-diff: rejects path scope containing .." "exit 0"
    fi

    rm -rf "$work" "$out"
}

test_review_diff_wired_into_all_three_consumers() {
    # The deterministic helper call must replace the hand-run git diff in all
    # three pipeline copies (canonical + two inlined). Byte-identity is enforced
    # by test_sync_pipeline_inline_matches_canonical; this is belt-and-braces
    # against a unanimous revert to hand-run git diff.
    local cr
    cr=$(_rd_cr_dir)
    local expected='review-diff emit "$REPO_DIR" "$BASE" "$HEAD_SHA" "$EMPTY_TREE_MODE" "$PATH_SCOPE" "$RESOLVED_TEMP_DIR"'
    local missing=()
    local f
    for f in \
        "includes/review-pipeline.md" \
        "skills/review-gh-pr/SKILL.md" \
        "commands/pre-review.md"; do
        if ! grep -qF "$expected" "$cr/$f" 2>/dev/null; then
            missing+=("$f")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "review-diff: helper invocation present in all three consumers"
    else
        fail "review-diff: helper invocation present in all three consumers" \
            "missing helper call in: ${missing[*]}"
    fi
}

test_review_diff_oracle_assertion_in_canonical() {
    # The Step 2.45 GitHub cross-check must exist in the canonical (byte-identity
    # then propagates it to the two inlined copies). Assert the halt message and
    # the three guard conditions are present so a future edit cannot silently
    # gut the backstop.
    local cr canonical
    cr=$(_rd_cr_dir)
    canonical="$cr/includes/review-pipeline.md"
    if [[ ! -f "$canonical" ]]; then
        fail "review-diff: oracle assertion in canonical" "review-pipeline.md not found"
        return
    fi

    if grep -qF 'Step 2.45 halt: measured diff' "$canonical"; then
        pass "review-diff: canonical carries the Step 2.45 mismatch-halt message"
    else
        fail "review-diff: canonical carries the Step 2.45 mismatch-halt message" \
            "the deterministic backstop halt ('Step 2.45 halt: measured diff ...') is missing — a wrong base pin would ship an incorrect review with no guard"
    fi

    if grep -qF 'gh pr view "$ARGUMENTS" --repo "$OWNER_REPO" --json changedFiles' "$canonical"; then
        pass "review-diff: canonical reads GitHub changedFiles as the oracle"
    else
        fail "review-diff: canonical reads GitHub changedFiles as the oracle" \
            "Step 2.45 must query 'gh pr view ... --json changedFiles' — GitHub's merge-base count is the authoritative oracle for the cross-check"
    fi
}
