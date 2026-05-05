#!/usr/bin/env bash
# Sync-note consistency tests — validation regexes and base-branch resolution steps match across files.

_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review"
}

_extract_regex() {
    # Extract the regex pattern following "matches `" for a given variable name
    local file="$1"
    local var_name="$2"
    grep "\`$var_name\` matches" "$file" 2>/dev/null \
        | grep -oE 'matches `[^`]+' \
        | sed 's/^matches `//' \
        | head -1
}

test_sync_base_regex_matches() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "BASE regex sync" "code-review plugin not found"
        return
    fi

    local pipeline specialist synthesiser
    pipeline=$(_extract_regex "$cr/includes/review-pipeline.md" '\$BASE')
    specialist=$(_extract_regex "$cr/includes/specialist-context.md" '\$BASE')
    synthesiser=$(_extract_regex "$cr/agents/review-synthesiser.md" '\$BASE')

    assert_equals "$pipeline" "$specialist" \
        "BASE regex: review-pipeline.md matches specialist-context.md"
    assert_equals "$pipeline" "$synthesiser" \
        "BASE regex: review-pipeline.md matches review-synthesiser.md"
}

test_sync_head_sha_regex_matches() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "HEAD_SHA regex sync" "code-review plugin not found"
        return
    fi

    local pipeline specialist synthesiser
    pipeline=$(_extract_regex "$cr/includes/review-pipeline.md" '\$HEAD_SHA')
    specialist=$(_extract_regex "$cr/includes/specialist-context.md" '\$HEAD_SHA')
    synthesiser=$(_extract_regex "$cr/agents/review-synthesiser.md" '\$HEAD_SHA')

    assert_equals "$pipeline" "$specialist" \
        "HEAD_SHA regex: review-pipeline.md matches specialist-context.md"
    assert_equals "$pipeline" "$synthesiser" \
        "HEAD_SHA regex: review-pipeline.md matches review-synthesiser.md"
}

test_sync_path_scope_regex_matches() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "PATH_SCOPE regex sync" "code-review plugin not found"
        return
    fi

    local pipeline specialist synthesiser
    pipeline=$(_extract_regex "$cr/includes/review-pipeline.md" '\$PATH_SCOPE')
    specialist=$(_extract_regex "$cr/includes/specialist-context.md" '\$PATH_SCOPE')
    synthesiser=$(_extract_regex "$cr/agents/review-synthesiser.md" '\$PATH_SCOPE')

    assert_equals "$pipeline" "$specialist" \
        "PATH_SCOPE regex: review-pipeline.md matches specialist-context.md"
    assert_equals "$pipeline" "$synthesiser" \
        "PATH_SCOPE regex: review-pipeline.md matches review-synthesiser.md"
}

test_sync_path_scope_traversal_check_present() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "PATH_SCOPE traversal check" "code-review plugin not found"
        return
    fi

    for file in includes/review-pipeline.md includes/specialist-context.md agents/review-synthesiser.md; do
        local basename_file
        basename_file=$(basename "$file")
        if grep -q 'contains `\.\.` as a substring' "$cr/$file" 2>/dev/null; then
            pass "$basename_file: PATH_SCOPE .. traversal check present"
        else
            fail "$basename_file: PATH_SCOPE .. traversal check present" "missing directory traversal guard"
        fi
    done
}

test_sync_base_branch_steps_match() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "base-branch steps sync" "code-review plugin not found"
        return
    fi

    # Extract numbered items 1-4 from each file
    # review-pipeline.md: under "Try these in order:", items 1-4
    # specialist-context.md: starts directly at "1. If `$ARGUMENTS`", items 1-4

    local pipeline_steps specialist_steps

    pipeline_steps=$(sed -n '/^Try these in order:$/,/^Store as/{
/^[1-4]\. /p
}' "$cr/includes/review-pipeline.md")
    specialist_steps=$(sed -n '/^1\. If `\$ARGUMENTS`/,/^Store as/{
/^[1-4]\. /p
}' "$cr/includes/specialist-context.md")

    if [[ -z "$pipeline_steps" ]]; then
        fail "base-branch steps: extracted from review-pipeline.md" "no steps found"
        return
    fi
    if [[ -z "$specialist_steps" ]]; then
        fail "base-branch steps: extracted from specialist-context.md" "no steps found"
        return
    fi

    if [[ "$pipeline_steps" == "$specialist_steps" ]]; then
        pass "base-branch resolution steps 1-4 match between pipeline and specialist"
    else
        local tmp1 tmp2
        tmp1=$(mktemp)
        tmp2=$(mktemp)
        echo "$pipeline_steps" > "$tmp1"
        echo "$specialist_steps" > "$tmp2"
        local diff_output
        diff_output=$(diff -u --label review-pipeline.md --label specialist-context.md "$tmp1" "$tmp2" || true)
        rm -f "$tmp1" "$tmp2"
        fail "base-branch resolution steps 1-4 match between pipeline and specialist" "$diff_output"
    fi
}
