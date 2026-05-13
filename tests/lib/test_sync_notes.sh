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

test_sync_pipeline_inline_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "pipeline inline sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/review-pipeline.md"

    # Extract the pipeline body from canonical (strip leading comment block)
    local canonical_body
    canonical_body=$(sed -n '/^Follow these instructions exactly/,$ p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "pipeline inline sync: canonical body extracted" "no body found in $canonical"
        return
    fi

    # Check each consumer file contains the canonical body verbatim
    local consumer
    for consumer in \
        "$cr/skills/review-gh-pr/SKILL.md" \
        "$cr/commands/pre-review.md"; do

        local basename_consumer
        basename_consumer=$(basename "$(dirname "$consumer")")/$(basename "$consumer")

        if grep -qF "Follow these instructions exactly. Do not skip steps or reorder." "$consumer" 2>/dev/null; then
            # Extract the same range from the consumer
            local consumer_body
            consumer_body=$(sed -n '/^Follow these instructions exactly/,/^Present the synthesiser.*formatted report to the user\.$/ p' "$consumer")

            if [[ -z "$consumer_body" ]]; then
                fail "pipeline inline sync: $basename_consumer" "pipeline body not found"
                continue
            fi

            # Compare just the canonical range from both
            local canonical_range
            canonical_range=$(sed -n '/^Follow these instructions exactly/,/^Present the synthesiser.*formatted report to the user\.$/ p' "$canonical")

            if [[ "$canonical_range" == "$consumer_body" ]]; then
                pass "pipeline inline sync: $basename_consumer matches canonical"
            else
                local tmp1 tmp2
                tmp1=$(mktemp)
                tmp2=$(mktemp)
                echo "$canonical_range" > "$tmp1"
                echo "$consumer_body" > "$tmp2"
                local diff_output
                diff_output=$(diff -u --label "canonical" --label "$basename_consumer" "$tmp1" "$tmp2" | head -30 || true)
                rm -f "$tmp1" "$tmp2"
                fail "pipeline inline sync: $basename_consumer matches canonical" "$diff_output"
            fi
        else
            fail "pipeline inline sync: $basename_consumer" "pipeline body not inlined"
        fi
    done
}

test_sync_intent_ledger_inline_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "intent-ledger inline sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/intent-ledger.md"
    if [[ ! -f "$canonical" ]]; then
        skip "intent-ledger inline sync" "canonical file not found"
        return
    fi

    # Extract a range bounded by markers that appear verbatim in both the canonical and
    # each consumer. The HTML maintenance comment in the canonical lives outside this range,
    # so we compare just the prose body.
    local canonical_body
    canonical_body=$(sed -n '/^Run Phase 0 BEFORE Step 1/,/continue to Phase 0\.6\.$/p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "intent-ledger inline sync: canonical body extracted" "no body found"
        return
    fi

    local consumer
    for consumer in \
        "$cr/skills/review-gh-pr/SKILL.md" \
        "$cr/commands/pre-review.md"; do

        local basename_consumer
        basename_consumer=$(basename "$(dirname "$consumer")")/$(basename "$consumer")

        if [[ ! -f "$consumer" ]]; then
            fail "intent-ledger inline sync: $basename_consumer" "file not found"
            continue
        fi

        if grep -qF "## Phase 0: Intent Ledger" "$consumer" 2>/dev/null; then
            local consumer_body
            consumer_body=$(sed -n '/^Run Phase 0 BEFORE Step 1/,/continue to Phase 0\.6\.$/p' "$consumer")

            # Guard against vacuous pass: an empty extraction signals the sed end-anchor
            # has drifted in the consumer. Without this, [[ "" == "" ]] would silently
            # pass and false-negative on real divergence.
            if [[ -z "$consumer_body" ]]; then
                fail "intent-ledger inline sync: $basename_consumer" "consumer body extraction empty (sed anchors may need updating)"
                continue
            fi

            if [[ "$canonical_body" == "$consumer_body" ]]; then
                pass "intent-ledger inline sync: $basename_consumer matches canonical"
            else
                local tmp1 tmp2
                tmp1=$(mktemp)
                tmp2=$(mktemp)
                trap 'rm -f "$tmp1" "$tmp2"' RETURN
                echo "$canonical_body" > "$tmp1"
                echo "$consumer_body" > "$tmp2"
                local diff_output
                diff_output=$(diff -u --label "canonical" --label "$basename_consumer" "$tmp1" "$tmp2" | head -30 || true)
                rm -f "$tmp1" "$tmp2"
                fail "intent-ledger inline sync: $basename_consumer matches canonical" "$diff_output"
            fi
        else
            fail "intent-ledger inline sync: $basename_consumer" "Phase 0 not inlined"
        fi
    done
}

test_sync_ci_status_gate_inline_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "ci-status-gate inline sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/ci-status-gate.md"
    if [[ ! -f "$canonical" ]]; then
        skip "ci-status-gate inline sync" "canonical file not found"
        return
    fi

    # Same range-marker approach as intent-ledger sync. Markers chosen to exist verbatim
    # in both canonical and consumer, with the HTML maintenance comment falling outside.
    local canonical_body
    canonical_body=$(sed -n '/^### 0.6.1 Skip in local mode/,/see `agents\/review-synthesiser\.md`\.$/p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "ci-status-gate inline sync: canonical body extracted" "no body found"
        return
    fi

    local consumer
    for consumer in \
        "$cr/skills/review-gh-pr/SKILL.md" \
        "$cr/commands/pre-review.md"; do

        local basename_consumer
        basename_consumer=$(basename "$(dirname "$consumer")")/$(basename "$consumer")

        if [[ ! -f "$consumer" ]]; then
            fail "ci-status-gate inline sync: $basename_consumer" "file not found"
            continue
        fi

        if grep -qF "## Phase 0.6: CI Status Gate" "$consumer" 2>/dev/null; then
            local consumer_body
            consumer_body=$(sed -n '/^### 0.6.1 Skip in local mode/,/see `agents\/review-synthesiser\.md`\.$/p' "$consumer")

            # Guard against vacuous pass: see notes on the intent-ledger sync test.
            if [[ -z "$consumer_body" ]]; then
                fail "ci-status-gate inline sync: $basename_consumer" "consumer body extraction empty (sed anchors may need updating)"
                continue
            fi

            if [[ "$canonical_body" == "$consumer_body" ]]; then
                pass "ci-status-gate inline sync: $basename_consumer matches canonical"
            else
                local tmp1 tmp2
                tmp1=$(mktemp)
                tmp2=$(mktemp)
                trap 'rm -f "$tmp1" "$tmp2"' RETURN
                echo "$canonical_body" > "$tmp1"
                echo "$consumer_body" > "$tmp2"
                local diff_output
                diff_output=$(diff -u --label "canonical" --label "$basename_consumer" "$tmp1" "$tmp2" | head -30 || true)
                rm -f "$tmp1" "$tmp2"
                fail "ci-status-gate inline sync: $basename_consumer matches canonical" "$diff_output"
            fi
        else
            fail "ci-status-gate inline sync: $basename_consumer" "Phase 0.6 not inlined"
        fi
    done
}

test_sync_cross_review_mode_inline_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "cross-review-mode inline sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/cross-review-mode.md"
    if [[ ! -f "$canonical" ]]; then
        skip "cross-review-mode inline sync" "canonical file not found"
        return
    fi

    # Extract the body from canonical (skip the HTML comment header)
    local canonical_body
    canonical_body=$(sed -n '/^> \*\*MODE SWITCH — MANDATORY\*\*/,$ p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "cross-review-mode inline sync: canonical body extracted" "no body found"
        return
    fi

    local agent
    for agent in \
        "$cr/agents/alignment-reviewer.md" \
        "$cr/agents/archaeology-reviewer.md" \
        "$cr/agents/consistency-reviewer.md" \
        "$cr/agents/correctness-reviewer.md" \
        "$cr/agents/efficiency-reviewer.md" \
        "$cr/agents/reuse-reviewer.md" \
        "$cr/agents/security-reviewer.md" \
        "$cr/agents/style-reviewer.md" \
        "$cr/agents/ui-reviewer.md"; do

        local basename_agent
        basename_agent=$(basename "$agent")

        if [[ ! -f "$agent" ]]; then
            fail "cross-review-mode inline sync: $basename_agent" "file not found"
            continue
        fi

        # Extract the inline block between the MODE SWITCH blockquote and the --- separator
        local inline_body
        inline_body=$(sed -n '/^> \*\*MODE SWITCH — MANDATORY\*\*/,/^---$/ p' "$agent" | sed '$ d')

        if [[ -z "$inline_body" ]]; then
            fail "cross-review-mode inline sync: $basename_agent" "inline block not found"
            continue
        fi

        if [[ "$canonical_body" == "$inline_body" ]]; then
            pass "cross-review-mode inline sync: $basename_agent matches canonical"
        else
            local tmp1 tmp2
            tmp1=$(mktemp)
            tmp2=$(mktemp)
            echo "$canonical_body" > "$tmp1"
            echo "$inline_body" > "$tmp2"
            local diff_output
            diff_output=$(diff -u --label "canonical" --label "$basename_agent" "$tmp1" "$tmp2" | head -30 || true)
            rm -f "$tmp1" "$tmp2"
            fail "cross-review-mode inline sync: $basename_agent matches canonical" "$diff_output"
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

test_dispatcher_includes_new_static_analysis_flags() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis dispatcher flags" "code-review plugin not found"
        return
    fi

    local file
    for file in skills/review-gh-pr/SKILL.md commands/pre-review.md; do
        local path="$cr/$file"
        if [[ ! -f "$path" ]]; then
            fail "static-analysis dispatcher flags: $file" "file not found"
            continue
        fi

        local flag
        for flag in '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED'; do
            if grep -qF "$flag" "$path"; then
                pass "static-analysis dispatcher flags: $file contains $flag"
            else
                fail "static-analysis dispatcher flags: $file contains $flag" \
                    "flag literal not found"
            fi
        done
    done
}

test_static_analysis_specialists_have_required_severity_mapping() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis severity literals" "code-review plugin not found"
        return
    fi

    local agent
    for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md; do
        local path="$cr/agents/$agent"
        if [[ ! -f "$path" ]]; then
            fail "static-analysis severity literals: $agent" "file not found"
            continue
        fi

        if grep -qF 'Confidence: 100' "$path"; then
            pass "static-analysis severity literals: $agent contains 'Confidence: 100'"
        else
            fail "static-analysis severity literals: $agent contains 'Confidence: 100'" \
                "literal not found"
        fi

        if grep -qE '^## .* Findings$' "$path"; then
            pass "static-analysis severity literals: $agent has '## <name> Findings' heading"
        else
            fail "static-analysis severity literals: $agent has '## <name> Findings' heading" \
                "no heading matching '## .* Findings$' found"
        fi
    done
}

test_sync_static_analysis_policy_literals() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis policy literals" "code-review plugin not found"
        return
    fi

    local include="$cr/includes/static-analysis-context.md"
    local synthesiser="$cr/agents/review-synthesiser.md"

    if [[ ! -f "$include" ]]; then
        fail "static-analysis policy literals: include exists" "missing: $include"
        return
    fi
    if [[ ! -f "$synthesiser" ]]; then
        fail "static-analysis policy literals: synthesiser exists" "missing: $synthesiser"
        return
    fi

    # Two byte-identical literals must appear in BOTH §10 of the include AND the
    # synthesiser carve-out. Drift in either direction would mean the policy text
    # has diverged between its definition site and its consumer.
    local literal
    for literal in \
        'up to 5 points of confidence drop' \
        'Confidence = max(50, 100 - Σ dissent)'; do
        if grep -qF "$literal" "$include"; then
            pass "static-analysis policy literals: include contains '$literal'"
        else
            fail "static-analysis policy literals: include contains '$literal'" \
                "literal not found in $include"
        fi
        if grep -qF "$literal" "$synthesiser"; then
            pass "static-analysis policy literals: synthesiser contains '$literal'"
        else
            fail "static-analysis policy literals: synthesiser contains '$literal'" \
                "literal not found in $synthesiser"
        fi
    done
}

test_sync_static_analysis_severity_lock() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis severity lock" "code-review plugin not found"
        return
    fi

    local synthesiser="$cr/agents/review-synthesiser.md"
    if [[ ! -f "$synthesiser" ]]; then
        fail "static-analysis severity lock: synthesiser exists" "missing: $synthesiser"
        return
    fi

    # The carve-out's anchor sentence must appear verbatim. Match the load-bearing
    # phrase rather than the entire paragraph — paragraph-level matching is brittle
    # against acceptable wording polish; the anchor sentence is the policy claim.
    local anchor='Findings tagged `[eslint]`, `[ruff]`, `[trivy]`, or `[jbinspect]` are exempt from'
    if grep -qF "$anchor" "$synthesiser"; then
        pass "static-analysis severity lock: synthesiser contains carve-out anchor sentence"
    else
        fail "static-analysis severity lock: synthesiser contains carve-out anchor sentence" \
            "anchor literal not found: $anchor"
    fi

    # Each of the four specialist tags must be listed verbatim in the carve-out.
    # Drift here would silently re-enable reclassification for the missing specialist.
    local tag
    for tag in '[eslint]' '[ruff]' '[trivy]' '[jbinspect]'; do
        if grep -qF "\`$tag\`" "$synthesiser"; then
            pass "static-analysis severity lock: synthesiser lists tag $tag"
        else
            fail "static-analysis severity lock: synthesiser lists tag $tag" \
                "tag literal \`$tag\` not found"
        fi
    done
}

test_sync_static_analysis_critical_allowlist_present() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis critical-allow-list" "code-review plugin not found"
        return
    fi

    local agent
    for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md; do
        local path="$cr/agents/$agent"
        if [[ ! -f "$path" ]]; then
            fail "static-analysis critical-allow-list: $agent exists" "missing: $path"
            continue
        fi
        if grep -qF 'Critical-allow-list:' "$path"; then
            pass "static-analysis critical-allow-list: $agent contains 'Critical-allow-list:'"
        else
            fail "static-analysis critical-allow-list: $agent contains 'Critical-allow-list:'" \
                "heading literal not found"
        fi
    done
}
