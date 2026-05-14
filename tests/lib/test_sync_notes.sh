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
    canonical_body=$(sed -n '/^### 0.6.1 Skip in local mode/,/Stop the pipeline cleanly\.$/p' "$canonical")

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
            consumer_body=$(sed -n '/^### 0.6.1 Skip in local mode/,/Stop the pipeline cleanly\.$/p' "$consumer")

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

test_sync_changed_lines_rule_matches_canonical() {
    # The extraction below intentionally starts at the blockquote header
    # (`> **CHANGED_LINES OUTPUT FILTER — MANDATORY**`), not at the preceding HTML
    # comment. The HTML comment is a maintainer-facing propagation hint that
    # legitimately differs across canonical (which lists target files) and inlined
    # copies (which refer back to the canonical), and is not load-bearing for the
    # runtime agent. Tightening the window to include it would trigger spurious
    # failures; conversely, if HTML-comment consistency does need enforcing, add a
    # separate test rather than expanding this extraction.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "CHANGED_LINES rule sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/specialist-context.md"
    if [[ ! -f "$canonical" ]]; then
        skip "CHANGED_LINES rule sync" "canonical file not found"
        return
    fi

    # Extract the canonical block from the MANDATORY blockquote header.
    local canonical_body
    canonical_body=$(sed -n '/^> \*\*CHANGED_LINES OUTPUT FILTER — MANDATORY\*\*/,$ p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "CHANGED_LINES rule sync: canonical body extracted" "no body found"
        return
    fi

    local agent
    for agent in \
        "$cr/agents/archaeology-reviewer.md" \
        "$cr/agents/code-analysis.md" \
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
            fail "CHANGED_LINES rule sync: $basename_agent" "file not found"
            continue
        fi

        # Each agent embeds the block bounded by the same blockquote header and the
        # next "---" separator. Mirror the cross-review-mode extraction pattern.
        local inline_body
        inline_body=$(sed -n '/^> \*\*CHANGED_LINES OUTPUT FILTER — MANDATORY\*\*/,/^---$/ p' "$agent" | sed '$ d')

        if [[ -z "$inline_body" ]]; then
            fail "CHANGED_LINES rule sync: $basename_agent" "inline block not found"
            continue
        fi

        if [[ "$canonical_body" == "$inline_body" ]]; then
            pass "CHANGED_LINES rule sync: $basename_agent matches canonical"
        else
            local tmp1 tmp2
            tmp1=$(mktemp)
            tmp2=$(mktemp)
            echo "$canonical_body" > "$tmp1"
            echo "$inline_body" > "$tmp2"
            local diff_output
            diff_output=$(diff -u --label "canonical" --label "$basename_agent" "$tmp1" "$tmp2" | head -30 || true)
            rm -f "$tmp1" "$tmp2"
            fail "CHANGED_LINES rule sync: $basename_agent matches canonical" "$diff_output"
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
                "tag literal \`$tag\` not found in $synthesiser"
        fi
    done
}

test_sync_static_analysis_dismissed_forbidden_literal() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis dismissed-forbidden literal" "code-review plugin not found"
        return
    fi

    local include="$cr/includes/static-analysis-context.md"
    local synthesiser="$cr/agents/review-synthesiser.md"

    if [[ ! -f "$include" ]]; then
        fail "static-analysis dismissed-forbidden literal: include exists" "missing: $include"
        return
    fi
    if [[ ! -f "$synthesiser" ]]; then
        fail "static-analysis dismissed-forbidden literal: synthesiser exists" "missing: $synthesiser"
        return
    fi

    # The Dismissed-forbidden rule is verified behaviourally by the Phase 2 smoke
    # (no Dismissed entries in tier_placements). This structural check is belt-and-
    # braces: it catches drift in the source-of-truth wording before a behavioural
    # run, and it survives an empty results file or a CLAUDE_CODE_E2E_TESTS=0 run.
    # The literal must appear in BOTH §10 of the include AND the synthesiser carve-out's
    # surrounding context (the carve-out cites "never placed in Dismissed" inline).
    if grep -qF 'Dismissed tier is forbidden' "$include"; then
        pass "static-analysis dismissed-forbidden literal: include contains 'Dismissed tier is forbidden'"
    else
        fail "static-analysis dismissed-forbidden literal: include contains 'Dismissed tier is forbidden'" \
            "literal not found in $include"
    fi
    if grep -qF 'never placed in Dismissed' "$synthesiser"; then
        pass "static-analysis dismissed-forbidden literal: synthesiser contains 'never placed in Dismissed'"
    else
        fail "static-analysis dismissed-forbidden literal: synthesiser contains 'never placed in Dismissed'" \
            "literal not found in $synthesiser"
    fi
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
                "heading literal not found in $path"
        fi
    done
}

test_sync_agent_prompt_empty_tree_mode_uses_variable() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "AGENT_PROMPT empty-tree-mode variable" "code-review plugin not found"
        return
    fi

    # The $AGENT_PROMPT template (Step 2.9 in the canonical) and its inlined copies
    # MUST use $EMPTY_TREE_MODE interpolation, not a literal "true"/"false". Search for
    # the offending literal string within the template fence range.
    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "AGENT_PROMPT empty-tree-mode variable: $basename_file" "file not found"
            continue
        fi

        # Extract the AGENT_PROMPT fenced block: from "Define `\$AGENT_PROMPT`" through
        # the next "```" closer. grep the block for a literal "Empty tree mode: true"
        # OR "Empty tree mode: false" that is NOT inside backticks (the bullet at line
        # ~580 legitimately quotes "Empty tree mode: true" in backticks while documenting
        # the rule — that is fine).
        local block
        block=$(awk '
            /Define `\$AGENT_PROMPT`/ { in_block = 1 }
            in_block && /^```$/ {
                if (saw_fence) { in_block = 0 } else { saw_fence = 1 }
                next
            }
            in_block && saw_fence { print }
        ' "$file")

        if [[ -z "$block" ]]; then
            fail "AGENT_PROMPT empty-tree-mode variable: $basename_file" "AGENT_PROMPT fenced block not found"
            continue
        fi

        if echo "$block" | grep -qE '^Empty tree mode: (true|false)$'; then
            fail "AGENT_PROMPT empty-tree-mode variable: $basename_file" "template literally hardcodes 'Empty tree mode: true|false' instead of '\$EMPTY_TREE_MODE' interpolation"
        else
            pass "AGENT_PROMPT empty-tree-mode variable: $basename_file uses interpolation"
        fi
    done
}

test_sync_static_analysis_cross_feed_documented() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis cross-feed documentation" "code-review plugin not found"
        return
    fi

    local pipeline="$cr/includes/review-pipeline.md"
    local sa_context="$cr/includes/static-analysis-context.md"
    local cr_mode="$cr/includes/cross-review-mode.md"

    local file
    for file in "$pipeline" "$sa_context" "$cr_mode"; do
        if [[ ! -f "$file" ]]; then
            fail "static-analysis cross-feed documentation: $(basename "$file") present" "file not found"
            return
        fi
    done

    # Assertion 1: review-pipeline.md Step 5.2 sub-step 3 must require static-analysis
    # findings to be included in EVERY cross-reviewer's prompt. The phrase "for ALL
    # cross-reviewers" is the load-bearing part.
    if grep -qE 'Include findings from any static-analysis specialist .*for ALL cross-reviewers' "$pipeline"; then
        pass "static-analysis cross-feed: Step 5.2 sub-step 3 includes findings for ALL cross-reviewers"
    else
        fail "static-analysis cross-feed: Step 5.2 sub-step 3 includes findings for ALL cross-reviewers" \
            "the canonical Step 5.2 sub-step 3 in review-pipeline.md must contain the load-bearing phrase 'Include findings from any static-analysis specialist ... for ALL cross-reviewers' — this is what wires static-analysis findings into the stochastic cross-reviewer prompts"
    fi

    # Assertion 2: static-analysis-context.md §8 must affirm that findings ARE shown
    # to cross-reviewers. The phrase "shown to the" + "cross-reviewers" is the claim.
    if grep -qE 'findings ARE shown to .*cross-reviewers' "$sa_context"; then
        pass "static-analysis cross-feed: §8 affirms findings shown to cross-reviewers"
    else
        fail "static-analysis cross-feed: §8 affirms findings shown to cross-reviewers" \
            "static-analysis-context.md §8 must contain the affirmation 'findings ARE shown to ... cross-reviewers' — this is the consumer-side documentation of the same policy"
    fi

    # Assertion 3: cross-review-mode.md HTML header must restate the same rule for
    # specialists reading their own inlined block.
    if grep -qE 'findings are visible to other cross-reviewers' "$cr_mode"; then
        pass "static-analysis cross-feed: cross-review-mode.md restates rule"
    else
        fail "static-analysis cross-feed: cross-review-mode.md restates rule" \
            "cross-review-mode.md HTML header must restate that static-analysis findings are visible to cross-reviewers"
    fi

    # Assertion 4: each of the four static-analysis specialist names must appear in
    # both review-pipeline.md and static-analysis-context.md. We assert presence
    # individually (not order/format) so that legitimate prose variations between
    # the two canonicals do not trigger false positives. The names are the load-
    # bearing tokens: a future edit that drops one of them from either canonical
    # would silently shrink the cross-feed scope.
    local name pipeline_missing sa_missing
    pipeline_missing=""
    sa_missing=""
    for name in jbinspect eslint ruff trivy; do
        if ! grep -q "$name" "$pipeline"; then
            pipeline_missing="$pipeline_missing $name"
        fi
        if ! grep -q "$name" "$sa_context"; then
            sa_missing="$sa_missing $name"
        fi
    done
    if [[ -z "$pipeline_missing" && -z "$sa_missing" ]]; then
        pass "static-analysis cross-feed: specialist enumeration consistent across canonicals"
    else
        fail "static-analysis cross-feed: specialist enumeration consistent across canonicals" \
            "review-pipeline.md missing names:${pipeline_missing:-<none>}; static-analysis-context.md missing names:${sa_missing:-<none>} — both canonicals must reference all four (jbinspect, eslint, ruff, trivy) static-analysis specialists"
    fi
}

test_sync_synthesiser_dispatch_includes_review_mode() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch Review mode" "code-review plugin not found"
        return
    fi

    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "synthesiser dispatch Review mode: $basename_file" "file not found"
            continue
        fi

        # Find the synthesiser dispatch prompt (single line containing the prompt
        # template) and assert it includes "Review mode: $REVIEW_MODE". The three
        # files enumerated above are the contractually-mandated synthesiser dispatch
        # sites — failure to find a dispatch in any of them is a regression, not a
        # benign skip. If a future file legitimately drops the dispatch, remove it
        # from the loop above rather than relaxing this branch.
        if grep -qE 'subagent_type: "code-review:review-synthesiser"' "$file"; then
            if grep -qE 'Review mode: \$REVIEW_MODE' "$file"; then
                pass "synthesiser dispatch Review mode: $basename_file includes \$REVIEW_MODE"
            else
                fail "synthesiser dispatch Review mode: $basename_file includes \$REVIEW_MODE" \
                    "the synthesiser dispatch prompt must include 'Review mode: \$REVIEW_MODE\\n' so the synthesiser can suppress verdict guidance in local mode"
            fi
        else
            fail "synthesiser dispatch Review mode: $basename_file" \
                "expected file to contain a synthesiser dispatch (subagent_type: \"code-review:review-synthesiser\") but none was found — was the dispatch deleted?"
        fi
    done
}

test_sync_synthesiser_dispatch_uses_ultrathink() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch ultrathink keyword" "code-review plugin not found"
        return
    fi

    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "synthesiser dispatch ultrathink keyword: $basename_file" "file not found"
            continue
        fi

        # The synthesiser dispatch prompt body must START with the literal "ultrathink"
        # keyword, followed by \n\n, before any other content. The keyword is what
        # Claude Code's keyword detector looks for to set the max thinking budget.
        # Detect the dispatch via the subagent_type marker, then assert the prompt
        # field begins with "ultrathink\n\n".
        if grep -qE 'subagent_type: "code-review:review-synthesiser"' "$file"; then
            if grep -qE 'prompt: "ultrathink\\n\\n' "$file"; then
                pass "synthesiser dispatch ultrathink keyword: $basename_file prompt starts with ultrathink"
            else
                fail "synthesiser dispatch ultrathink keyword: $basename_file prompt starts with ultrathink" \
                    "the synthesiser dispatch prompt must begin with the literal 'ultrathink\\n\\n' so Claude Code's keyword detector sets the max thinking budget; without it, the synthesiser runs at default effort regardless of any frontmatter declaration"
            fi
        else
            fail "synthesiser dispatch ultrathink keyword: $basename_file" \
                "expected file to contain a synthesiser dispatch (subagent_type: \"code-review:review-synthesiser\") but none was found — was the dispatch deleted?"
        fi
    done
}

test_sync_synth_dispatch_passes_intent_ledger() {
    # The synthesiser's verdict rubric row 1 fires on "Intent-ledger states a goal AND
    # any consensus finding indicates the goal is not achieved." Row 1 is unevaluable
    # without the ledger, so the dispatch prompt MUST include $INTENT_LEDGER. The
    # synthesiser's agent definition already has the `Intent ledger:` extraction
    # block; this test asserts the producer side is wired up too.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch intent ledger" "code-review plugin not found"
        return
    fi

    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "synthesiser dispatch intent ledger: $basename_file" "file not found"
            continue
        fi

        if grep -qE 'subagent_type: "code-review:review-synthesiser"' "$file"; then
            # The dispatch prompt must contain '\n\n$INTENT_LEDGER\n' between the
            # Review mode line and the trust boundary advisory. The literal token
            # `$INTENT_LEDGER` is the variable name as it appears in the prompt
            # template — the orchestrator substitutes its value at runtime.
            if grep -qE 'Review mode: \$REVIEW_MODE\\n\\n\$INTENT_LEDGER\\n\\nTrust boundary' "$file"; then
                pass "synthesiser dispatch intent ledger: $basename_file passes \$INTENT_LEDGER"
            else
                fail "synthesiser dispatch intent ledger: $basename_file passes \$INTENT_LEDGER" \
                    "the synthesiser dispatch prompt must include \$INTENT_LEDGER between the Review mode line and the trust boundary advisory — without it the synthesiser cannot evaluate verdict rubric row 1 (intent-ledger goal unachieved) and must infer the goal from the diff non-deterministically"
            fi
        else
            fail "synthesiser dispatch intent ledger: $basename_file" \
                "expected file to contain a synthesiser dispatch (subagent_type: \"code-review:review-synthesiser\") but none was found — was the dispatch deleted?"
        fi
    done
}

test_sync_verdict_rubric_inline_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "verdict-rubric inline sync" "code-review plugin not found"
        return
    fi

    local canonical="$cr/includes/verdict-rubric.md"
    if [[ ! -f "$canonical" ]]; then
        skip "verdict-rubric inline sync" "canonical file not found"
        return
    fi

    # Extract canonical body from "### Verdict rubric (PR mode only" through end-of-file.
    # The HTML maintenance comment is excluded from the inlined copies (consumers do not
    # duplicate the canonical's maintenance metadata).
    local canonical_body
    canonical_body=$(sed -n '/^### Verdict rubric (PR mode only, first match wins)/,$ p' "$canonical")

    if [[ -z "$canonical_body" ]]; then
        fail "verdict-rubric inline sync: canonical body extracted" "no body found"
        return
    fi

    local consumer
    for consumer in \
        "$cr/agents/review-synthesiser.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_consumer
        basename_consumer=$(basename "$(dirname "$consumer")")/$(basename "$consumer")

        if [[ ! -f "$consumer" ]]; then
            fail "verdict-rubric inline sync: $basename_consumer" "file not found"
            continue
        fi

        # Each consumer inlines the canonical body bounded by the same start anchor and
        # the line "operations — no prose parsing." (last line of the Synthesiser contract
        # section, unique in the canonical — note the body wraps so the literal
        # "operations" begins the final line).
        local consumer_body
        consumer_body=$(sed -n '/^### Verdict rubric (PR mode only, first match wins)/,/^operations — no prose parsing\.$/p' "$consumer")

        if [[ -z "$consumer_body" ]]; then
            fail "verdict-rubric inline sync: $basename_consumer" "inline block not found (sed anchors may need updating)"
            continue
        fi

        # The canonical's body extracted via the same end-anchor pattern for like-for-like comparison.
        local canonical_range
        canonical_range=$(sed -n '/^### Verdict rubric (PR mode only, first match wins)/,/^operations — no prose parsing\.$/p' "$canonical")

        if [[ "$canonical_range" == "$consumer_body" ]]; then
            pass "verdict-rubric inline sync: $basename_consumer matches canonical"
        else
            local tmp1 tmp2
            tmp1=$(mktemp)
            tmp2=$(mktemp)
            echo "$canonical_range" > "$tmp1"
            echo "$consumer_body" > "$tmp2"
            local diff_output
            diff_output=$(diff -u --label "canonical" --label "$basename_consumer" "$tmp1" "$tmp2" | head -30 || true)
            rm -f "$tmp1" "$tmp2"
            fail "verdict-rubric inline sync: $basename_consumer matches canonical" "$diff_output"
        fi
    done
}

test_synthesiser_verdict_output_restricted_to_two_values() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser verdict restricted" "code-review plugin not found"
        return
    fi

    local synthesiser="$cr/agents/review-synthesiser.md"
    if [[ ! -f "$synthesiser" ]]; then
        fail "synthesiser verdict restricted" "review-synthesiser.md not found"
        return
    fi

    # Assert the ## Verdict Output Format block exists and the Verdict: line restricts
    # to "APPROVE | REQUEST_CHANGES" — exactly two values, no COMMENT, no other variants.
    if grep -qE '^Verdict: <APPROVE \| REQUEST_CHANGES>$' "$synthesiser"; then
        pass "synthesiser verdict restricted: ## Verdict block lists exactly APPROVE | REQUEST_CHANGES"
    else
        fail "synthesiser verdict restricted: ## Verdict block lists exactly APPROVE | REQUEST_CHANGES" \
            "the synthesiser's ## Verdict Output Format block must contain a 'Verdict: <APPROVE | REQUEST_CHANGES>' line — COMMENT is never a synthesiser output, only a Class B downgrade or user override"
    fi

    # Assert the synthesiser does NOT include COMMENT as a possible Verdict: value.
    if grep -qE '^Verdict: <APPROVE \| REQUEST_CHANGES \| COMMENT' "$synthesiser"; then
        fail "synthesiser verdict restricted: COMMENT is NOT a synthesiser output" \
            "the synthesiser's ## Verdict Output Format block must NOT include COMMENT as a possible Verdict: value — Class B downgrade and user override are the only routes to COMMENT"
    else
        pass "synthesiser verdict restricted: COMMENT is NOT a synthesiser output"
    fi

    # Assert the Rubric row applied: line lists exactly the four rubric rows.
    if grep -qE '^Rubric row applied: <1 \| 2 \| 3 \| 4>$' "$synthesiser"; then
        pass "synthesiser verdict restricted: Rubric row applied lists exactly 1 | 2 | 3 | 4"
    else
        fail "synthesiser verdict restricted: Rubric row applied lists exactly 1 | 2 | 3 | 4" \
            "the synthesiser's ## Verdict block must contain 'Rubric row applied: <1 | 2 | 3 | 4>' — the four rubric rows are the only legal values"
    fi
}

test_skill_md_step6_references_rubric_and_classes() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "SKILL.md Step 6 rubric and classes" "code-review plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "SKILL.md Step 6 rubric and classes" "SKILL.md not found"
        return
    fi

    # Extract Step 6's body: from "## Step 6: Submit Review Verdict" to "## Step 7" or
    # end of file. All assertions below operate on this slice.
    local step6
    step6=$(sed -n '/^## Step 6: Submit Review Verdict/,/^## Step 7/p' "$skill")

    if [[ -z "$step6" ]]; then
        fail "SKILL.md Step 6 rubric and classes: Step 6 section extracted" "Step 6 not found in SKILL.md"
        return
    fi

    # Six assertions on Step 6's body, encoded as parallel arrays of
    # (sense, pattern, pass_label, fail_explanation) tuples. `sense` is `present` if the
    # pattern is required to appear (rubric heading, four Class headings) or `absent` if
    # it is forbidden (the legacy decision matrix). The loop body branches once on sense
    # and dispatches the same pass/fail bookkeeping in both cases — replaces an earlier
    # mix of two ad-hoc assertions and one for-loop with a single uniform structure.
    local senses=(
        present
        absent
        present
        present
        present
        present
    )
    local patterns=(
        '^### Verdict rubric \(PR mode only, first match wins\)$'
        '^\| \*\*APPROVE\*\* \| No comments are blockers'
        '^### Class A —'
        '^### Class B —'
        '^### Class C —'
        '^### Class D —'
    )
    local labels=(
        "rubric inlined"
        "decision matrix removed"
        "Class A heading present"
        "Class B heading present"
        "Class C heading present"
        "Class D heading present"
    )
    local explanations=(
        "Step 6 must inline the verdict rubric heading '### Verdict rubric (PR mode only, first match wins)' — without it the orchestrator has no documented authority chain to the synthesiser's verdict"
        "Step 6 still contains the legacy decision matrix ('| **APPROVE** | No comments are blockers …') — this lets the orchestrator pick a verdict on its own initiative, conflicting with synthesiser-as-sole-authority. Delete the matrix; the rubric replaces it."
        "Step 6 must contain a heading '### Class A — …'. The four classes (A: user-confirmation, B: PR-thread state, C: submission mechanics, D: output filtering) document the orchestrator's full decision scope — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Step 6 must contain a heading '### Class B — …'. The four classes (A: user-confirmation, B: PR-thread state, C: submission mechanics, D: output filtering) document the orchestrator's full decision scope — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Step 6 must contain a heading '### Class C — …'. The four classes (A: user-confirmation, B: PR-thread state, C: submission mechanics, D: output filtering) document the orchestrator's full decision scope — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Step 6 must contain a heading '### Class D — …'. The four classes (A: user-confirmation, B: PR-thread state, C: submission mechanics, D: output filtering) document the orchestrator's full decision scope — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
    )
    local i
    for ((i = 0; i < ${#senses[@]}; i++)); do
        local matched
        if echo "$step6" | grep -qE "${patterns[i]}"; then
            matched=yes
        else
            matched=no
        fi

        if [[ ${senses[i]} == present && $matched == yes ]] \
                || [[ ${senses[i]} == absent && $matched == no ]]; then
            pass "SKILL.md Step 6 rubric and classes: ${labels[i]}"
        else
            fail "SKILL.md Step 6 rubric and classes: ${labels[i]}" "${explanations[i]}"
        fi
    done
}

test_skill_md_filter_rationale_propagated_to_three_sites() {
    # The `filtered-by-confidence` rationale (introduced by Class D §D.2) is a third
    # permitted blank-`Outgoing comment ID` rationale. It must be enumerated at three
    # propagation sites in SKILL.md, otherwise Step 5.5 false-halts on every APPROVE
    # with sub-75 confidence findings, or Step 3's table column rule contradicts the
    # no-filter rule introduced in the same step.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "SKILL.md filter rationale propagation" "code-review plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "SKILL.md filter rationale propagation" "SKILL.md not found"
        return
    fi

    # Site 1: Step 3 no-filter rule must list filtered-by-confidence as a permitted
    # blank-rationale (alongside dedup-with-#N and dismissed-by-synthesiser).
    if grep -qE '^> 3\. \*\*`filtered-by-confidence' "$skill"; then
        pass "SKILL.md filter rationale propagation: Step 3 no-filter rule lists filtered-by-confidence"
    else
        fail "SKILL.md filter rationale propagation: Step 3 no-filter rule lists filtered-by-confidence" \
            "Step 3's no-filter rule (the bulleted list of legal omission reasons) must include a third item starting '> 3. **\`filtered-by-confidence' — without it the rule contradicts Class D §D.2's permission for confidence-driven omissions"
    fi

    # Site 2: Step 3 table column rule must also list filtered-by-confidence. This
    # is the rule directly under the example reconciliation table that says
    # "may be blank ONLY when ...". Earlier versions listed only two rationales,
    # contradicting the no-filter rule; the third rationale must propagate here too.
    if grep -qE 'may be blank ONLY when `Rationale` is `dedup-with-#N`,$' "$skill" \
            && grep -qE '`dismissed-by-synthesiser`, or `filtered-by-confidence ' "$skill"; then
        pass "SKILL.md filter rationale propagation: Step 3 table column rule lists filtered-by-confidence"
    else
        fail "SKILL.md filter rationale propagation: Step 3 table column rule lists filtered-by-confidence" \
            "Step 3's table column rule under the example reconciliation table must enumerate all three rationales — currently it omits filtered-by-confidence and contradicts the no-filter rule above it"
    fi

    # Site 3: Step 5.5 must define P (filtered-by-confidence count) and the assertion
    # must subtract it. C == R - D - X without the P term false-halts every APPROVE
    # with sub-75 findings; that is the common case under APPROVE so the missing
    # term is a hot-path bug.
    if grep -qE '^- `P` = number of rows whose rationale is `filtered-by-confidence' "$skill"; then
        pass "SKILL.md filter rationale propagation: Step 5.5 defines P"
    else
        fail "SKILL.md filter rationale propagation: Step 5.5 defines P" \
            "Step 5.5's variable list must include 'P = number of rows whose rationale is filtered-by-confidence (verdict APPROVE, confidence < 75)' — without P the assertion 2 formula does not account for confidence-filtered rows"
    fi

    if grep -qE '`C == R - D - X - P`' "$skill"; then
        pass "SKILL.md filter rationale propagation: Step 5.5 assertion subtracts P"
    else
        fail "SKILL.md filter rationale propagation: Step 5.5 assertion subtracts P" \
            "Step 5.5 assertion 2 must read 'C == R - D - X - P' — the pre-existing 'C == R - D - X' false-halts every APPROVE verdict where any consensus finding has confidence < 75 (the common case)"
    fi
}
