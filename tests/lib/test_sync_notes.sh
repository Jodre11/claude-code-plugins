#!/usr/bin/env bash
# Sync-note consistency tests — validation regexes and base-branch resolution steps match across files.

_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
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
        skip "BASE regex sync" "code-review-suite plugin not found"
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
        skip "HEAD_SHA regex sync" "code-review-suite plugin not found"
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
        skip "PATH_SCOPE regex sync" "code-review-suite plugin not found"
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
        skip "PATH_SCOPE traversal check" "code-review-suite plugin not found"
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
        skip "pipeline inline sync" "code-review-suite plugin not found"
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
        skip "intent-ledger inline sync" "code-review-suite plugin not found"
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
    canonical_body=$(sed -n '/^Run Phase 0 BEFORE Step 1/,/continue to Phase 0\.55\.$/p' "$canonical")

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
            consumer_body=$(sed -n '/^Run Phase 0 BEFORE Step 1/,/continue to Phase 0\.55\.$/p' "$consumer")

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
        skip "ci-status-gate inline sync" "code-review-suite plugin not found"
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
        skip "cross-review-mode inline sync" "code-review-suite plugin not found"
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
        "$cr/agents/test-quality-reviewer.md" \
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
        skip "CHANGED_LINES rule sync" "code-review-suite plugin not found"
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
        "$cr/agents/api-contract-reviewer.md" \
        "$cr/agents/archaeology-reviewer.md" \
        "$cr/agents/code-analysis.md" \
        "$cr/agents/consistency-reviewer.md" \
        "$cr/agents/correctness-reviewer.md" \
        "$cr/agents/efficiency-reviewer.md" \
        "$cr/agents/reuse-reviewer.md" \
        "$cr/agents/security-reviewer.md" \
        "$cr/agents/style-reviewer.md" \
        "$cr/agents/test-adequacy-reviewer.md" \
        "$cr/agents/test-quality-reviewer.md" \
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
        skip "base-branch steps sync" "code-review-suite plugin not found"
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
        skip "static-analysis dispatcher flags" "code-review-suite plugin not found"
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
        for flag in '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED' '$HOUSEKEEPING_DETECTED' '$PRODUCTION_SOURCE_DETECTED'; do
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
        skip "static-analysis severity literals" "code-review-suite plugin not found"
        return
    fi

    local agent
    for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md housekeeper-reviewer.md; do
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
        skip "static-analysis policy literals" "code-review-suite plugin not found"
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
        skip "static-analysis severity lock" "code-review-suite plugin not found"
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
    # NB: housekeeper is exempt from reclassification too, but has a DISTINCT delivery
    # model (the Dependency Freshness table — see the Housekeeper carve-out), so it is
    # no longer listed in this four-tag tier-reclassification anchor. Its tag presence
    # is still asserted by the tag loop below.
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
    for tag in '[eslint]' '[ruff]' '[trivy]' '[jbinspect]' '[housekeeper]'; do
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
        skip "static-analysis dismissed-forbidden literal" "code-review-suite plugin not found"
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
        skip "static-analysis critical-allow-list" "code-review-suite plugin not found"
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
        skip "AGENT_PROMPT empty-tree-mode variable" "code-review-suite plugin not found"
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

test_sync_agent_prompt_includes_repo_dir_line() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "AGENT_PROMPT Repo dir line" "code-review-suite plugin not found"
        return
    fi

    # The $AGENT_PROMPT template (Step 2.9 canonical + 2 inlined copies) must carry a
    # "Repo dir: $REPO_DIR" line so specialists learn which repo to operate on. Extract
    # the fenced AGENT_PROMPT block and assert the line is present and interpolated
    # (literal "$REPO_DIR", not a hardcoded path).
    local file
    for file in \
        "$cr/includes/review-pipeline.md" \
        "$cr/commands/pre-review.md" \
        "$cr/skills/review-gh-pr/SKILL.md"; do

        local basename_file
        basename_file=$(basename "$file")

        if [[ ! -f "$file" ]]; then
            fail "AGENT_PROMPT Repo dir line: $basename_file" "file not found"
            continue
        fi

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
            fail "AGENT_PROMPT Repo dir line: $basename_file" "AGENT_PROMPT fenced block not found"
            continue
        fi

        if echo "$block" | grep -qE '^Repo dir: \$REPO_DIR$'; then
            pass "AGENT_PROMPT Repo dir line: $basename_file carries 'Repo dir: \$REPO_DIR'"
        else
            fail "AGENT_PROMPT Repo dir line: $basename_file carries 'Repo dir: \$REPO_DIR'" \
                "the AGENT_PROMPT template must include a 'Repo dir: \$REPO_DIR' line so specialists run git -C against the target repo; absent or hardcoded means cross-repo review silently falls back to cwd"
        fi
    done
}

test_sync_phase_minus1_target_repo_present() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "Phase -1 target repository" "code-review-suite plugin not found"
        return
    fi

    # The Phase -1 governing directive must exist in the canonical (the pipeline inline
    # sync test then enforces byte-identical propagation to the two consumers). Assert
    # the heading and the two load-bearing rules are present.
    local canonical="$cr/includes/review-pipeline.md"
    if [[ ! -f "$canonical" ]]; then
        fail "Phase -1 target repository" "review-pipeline.md not found"
        return
    fi

    if grep -qE '^## Phase -1: Target repository$' "$canonical"; then
        pass "Phase -1 target repository: section heading present"
    else
        fail "Phase -1 target repository: section heading present" \
            "review-pipeline.md must contain '## Phase -1: Target repository' before Phase 0 — it resolves \$REPO_DIR and \$OWNER_REPO once and governs git -C / gh --repo for the whole pipeline"
    fi

    if grep -qF 'git -C "$REPO_DIR"' "$canonical"; then
        pass "Phase -1 target repository: mandates git -C \$REPO_DIR"
    else
        fail "Phase -1 target repository: mandates git -C \$REPO_DIR" \
            "Phase -1 must instruct running every git command as 'git -C \"\$REPO_DIR\"' — without it the bare-git call sites operate on cwd"
    fi

    if grep -qF -- '--repo "$OWNER_REPO"' "$canonical"; then
        pass "Phase -1 target repository: mandates gh --repo \$OWNER_REPO"
    else
        fail "Phase -1 target repository: mandates gh --repo \$OWNER_REPO" \
            "Phase -1 must instruct passing '--repo \"\$OWNER_REPO\"' to gh — without it gh infers owner/repo from cwd's remote"
    fi
}

test_sync_static_analysis_cross_feed_documented() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis cross-feed documentation" "code-review-suite plugin not found"
        return
    fi

    local pipeline="$cr/includes/review-pipeline.md"
    local sa_context="$cr/includes/static-analysis-context.md"
    local cr_mode="$cr/includes/cross-review-mode.md"
    local review_core="$cr/workflows/review-core.mjs"

    local file
    for file in "$pipeline" "$sa_context" "$cr_mode" "$review_core"; do
        if [[ ! -f "$file" ]]; then
            fail "static-analysis cross-feed documentation: $(basename "$file") present" "file not found"
            return
        fi
    done

    # Assertion 1: the cross-feed now lives in the Workflow engine (review-core.mjs), not
    # inline prose. crossAndSynth must build a `peer` object over crossDomains, and the
    # STATIC set must be EXCLUDED from RECEIVING cross-review (crossDomains filters NON_CROSS
    # out). Both the STATIC set definition and the crossDomains filter are load-bearing.
    if grep -qE 'const STATIC = new Set\(\[' "$review_core" \
            && grep -qE 'const crossDomains = allSpecialists\.filter\(d => !NON_CROSS\.has\(d\)\)' "$review_core"; then
        pass "static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review"
    else
        fail "static-analysis cross-feed: review-core.mjs excludes STATIC from receiving cross-review" \
            "review-core.mjs must define 'const STATIC = new Set([...])' and 'const crossDomains = allSpecialists.filter(d => !NON_CROSS.has(d))' — this is what excludes static-analysis specialists from receiving cross-review while still feeding their findings to the cross-reviewers (the peer object in crossAndSynth)"
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

    # Assertion 4: each of the five static-analysis specialist names must appear in
    # both review-core.mjs (the STATIC set — the engine excludes them from receiving
    # cross-review) and static-analysis-context.md. We assert presence individually
    # (not order/format) so that legitimate prose variations do not trigger false
    # positives. The names are the load-bearing tokens: a future edit that drops one of
    # them would silently shrink the cross-feed scope.
    local name core_missing sa_missing
    core_missing=""
    sa_missing=""
    for name in jbinspect eslint ruff trivy housekeeper; do
        if ! grep -q "$name" "$review_core"; then
            core_missing="$core_missing $name"
        fi
        if ! grep -q "$name" "$sa_context"; then
            sa_missing="$sa_missing $name"
        fi
    done
    if [[ -z "$core_missing" && -z "$sa_missing" ]]; then
        pass "static-analysis cross-feed: specialist enumeration consistent across canonicals"
    else
        fail "static-analysis cross-feed: specialist enumeration consistent across canonicals" \
            "review-core.mjs missing names:${core_missing:-<none>}; static-analysis-context.md missing names:${sa_missing:-<none>} — both must reference all five (jbinspect, eslint, ruff, trivy, housekeeper) static-analysis specialists"
    fi
}

test_sync_synthesiser_dispatch_includes_review_mode() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch Review mode" "code-review-suite plugin not found"
        return
    fi

    # The synthesiser is now dispatched only by the Workflow engine (review-core.mjs
    # crossAndSynth). Its synthPrompt must include "Review mode: ${reviewMode}" so the
    # synthesiser can suppress verdict guidance in local mode.
    local review_core="$cr/workflows/review-core.mjs"
    if [[ ! -f "$review_core" ]]; then
        fail "synthesiser dispatch Review mode: review-core.mjs" "review-core.mjs not found"
        return
    fi

    if grep -qE "agentType: 'code-review-suite:review-synthesiser'" "$review_core"; then
        if grep -qE 'Review mode: \$\{reviewMode\}' "$review_core"; then
            pass "synthesiser dispatch Review mode: review-core.mjs synthPrompt includes reviewMode"
        else
            fail "synthesiser dispatch Review mode: review-core.mjs synthPrompt includes reviewMode" \
                "review-core.mjs's synthPrompt must include 'Review mode: \${reviewMode}' so the synthesiser can suppress verdict guidance in local mode"
        fi
    else
        fail "synthesiser dispatch Review mode: review-core.mjs" \
            "expected review-core.mjs to dispatch the synthesiser (agentType: 'code-review-suite:review-synthesiser') but none was found — was the dispatch deleted?"
    fi
}

test_sync_synthesiser_dispatch_uses_ultrathink() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch ultrathink keyword" "code-review-suite plugin not found"
        return
    fi

    # The synthesiser's synthPrompt (review-core.mjs) must START with the literal
    # "ultrathink" keyword, followed by \n\n. The keyword is what Claude Code's keyword
    # detector looks for to set the max thinking budget.
    local review_core="$cr/workflows/review-core.mjs"
    if [[ ! -f "$review_core" ]]; then
        fail "synthesiser dispatch ultrathink keyword: review-core.mjs" "review-core.mjs not found"
        return
    fi

    if grep -qE "agentType: 'code-review-suite:review-synthesiser'" "$review_core"; then
        if grep -qE "const synthPrompt =" "$review_core" \
                && grep -qE '`ultrathink\\n\\n`' "$review_core"; then
            pass "synthesiser dispatch ultrathink keyword: review-core.mjs synthPrompt starts with ultrathink"
        else
            fail "synthesiser dispatch ultrathink keyword: review-core.mjs synthPrompt starts with ultrathink" \
                "review-core.mjs's synthPrompt must begin with the literal \`ultrathink\\n\\n\` so Claude Code's keyword detector sets the max thinking budget; without it, the synthesiser runs at default effort regardless of any frontmatter declaration"
        fi
    else
        fail "synthesiser dispatch ultrathink keyword: review-core.mjs" \
            "expected review-core.mjs to dispatch the synthesiser (agentType: 'code-review-suite:review-synthesiser') but none was found — was the dispatch deleted?"
    fi
}

test_sync_synth_dispatch_passes_intent_ledger() {
    # The synthesiser's verdict rubric row 1 fires on "Intent-ledger states a goal AND
    # any consensus finding indicates the goal is not achieved." Row 1 is unevaluable
    # without the ledger, so the synthPrompt MUST include the intent ledger. The
    # synthesiser's agent definition already has the `Intent ledger:` extraction
    # block; this test asserts the producer side (review-core.mjs) is wired up too.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "synthesiser dispatch intent ledger" "code-review-suite plugin not found"
        return
    fi

    local review_core="$cr/workflows/review-core.mjs"
    if [[ ! -f "$review_core" ]]; then
        fail "synthesiser dispatch intent ledger: review-core.mjs" "review-core.mjs not found"
        return
    fi

    if grep -qE "agentType: 'code-review-suite:review-synthesiser'" "$review_core"; then
        # The synthPrompt interpolates the intentLedger arg between the Review mode line
        # and the trust boundary advisory.
        if grep -qE 'intentLedger \? `\$\{intentLedger\}' "$review_core"; then
            pass "synthesiser dispatch intent ledger: review-core.mjs synthPrompt passes intentLedger"
        else
            fail "synthesiser dispatch intent ledger: review-core.mjs synthPrompt passes intentLedger" \
                "review-core.mjs's synthPrompt must interpolate \${intentLedger} — without it the synthesiser cannot evaluate verdict rubric row 1 (intent-ledger goal unachieved) and must infer the goal from the diff non-deterministically"
        fi
    else
        fail "synthesiser dispatch intent ledger: review-core.mjs" \
            "expected review-core.mjs to dispatch the synthesiser (agentType: 'code-review-suite:review-synthesiser') but none was found — was the dispatch deleted?"
    fi
}

test_sync_verdict_rubric_inline_matches_canonical() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "verdict-rubric inline sync" "code-review-suite plugin not found"
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

    # review-synthesiser.md is the sole inlining consumer. SKILL.md (Stage 6) no longer
    # inlines the rubric: the Workflow's synthesiser applies the rubric and review-core
    # builds the body, so the orchestrator's posting step consumes only bundle.verdict.
    local consumer
    for consumer in \
        "$cr/agents/review-synthesiser.md"; do

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
        skip "synthesiser verdict restricted" "code-review-suite plugin not found"
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
            "the synthesiser's ## Verdict Output Format block must contain a 'Verdict: <APPROVE | REQUEST_CHANGES>' line — COMMENT is never a synthesiser output, only a user override"
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
        skip "SKILL.md Stage 6 rubric and classes" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "SKILL.md Stage 6 rubric and classes" "SKILL.md not found"
        return
    fi

    # Extract Stage 6's body: from "## Stage 6: Submit Review Verdict" to "## Stage 7" or
    # end of file. All assertions below operate on this slice.
    local step6
    step6=$(sed -n '/^## Stage 6: Submit Review Verdict/,/^## Stage 7/p' "$skill")

    if [[ -z "$step6" ]]; then
        fail "SKILL.md Stage 6 rubric and classes: Stage 6 section extracted" "Stage 6 not found in SKILL.md"
        return
    fi

    # Assertions on Stage 6's body, encoded as parallel arrays of
    # (sense, pattern, pass_label, fail_explanation) tuples. `sense` is `present` if the
    # pattern is required to appear or `absent` if it is forbidden (the legacy decision
    # matrix). Since the Workflow is the only path, Stage 6 consumes bundle.verdict directly:
    # the rubric is no longer inlined here (review-core's synthesiser applies it) and Class D
    # output filtering is gone (review-core applies it). Only Classes A/B/C remain.
    local senses=(
        absent
        present
        present
        present
        present
    )
    local patterns=(
        '^\| \*\*APPROVE\*\* \| No comments are blockers'
        '^### Class A —'
        '^### Class B —'
        '^### Class C —'
        'bundle\.verdict'
    )
    local labels=(
        "decision matrix removed"
        "Class A heading present"
        "Class B heading present"
        "Class C heading present"
        "consumes bundle.verdict"
    )
    local explanations=(
        "Stage 6 still contains the legacy decision matrix ('| **APPROVE** | No comments are blockers …') — this lets the orchestrator pick a verdict on its own initiative, conflicting with synthesiser-as-sole-authority. Delete the matrix; the rubric replaces it."
        "Stage 6 must contain a heading '### Class A — …'. The three remaining classes (A: user-confirmation, B: PR-thread state, C: submission mechanics) document the orchestrator's full decision scope on the Workflow-only path — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Stage 6 must contain a heading '### Class B — …'. The three remaining classes (A: user-confirmation, B: PR-thread state, C: submission mechanics) document the orchestrator's full decision scope on the Workflow-only path — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Stage 6 must contain a heading '### Class C — …'. The three remaining classes (A: user-confirmation, B: PR-thread state, C: submission mechanics) document the orchestrator's full decision scope on the Workflow-only path — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Stage 6 must read the verdict directly from the Workflow bundle (\$SYNTH_VERDICT = bundle.verdict) — on the Workflow-only path there is no synthesiser markdown to parse, so the orchestrator consumes bundle.verdict rather than re-deriving a verdict"
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
            pass "SKILL.md Stage 6 rubric and classes: ${labels[i]}"
        else
            fail "SKILL.md Stage 6 rubric and classes: ${labels[i]}" "${explanations[i]}"
        fi
    done
}

test_analysis_only_stage1_resolve_and_no_short_circuit() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Stage 1 resolve + no-short-circuit" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "analysis-only Stage 1: SKILL.md present" "missing: $skill"
        return
    fi

    # Extract Stage 1's body (from its heading to Stage 2) so the assertions can't
    # be satisfied by matching text elsewhere in the file.
    local stage1
    stage1=$(sed -n '/^## Stage 1: Gather PR Information/,/^## Stage 2:/p' "$skill")

    if grep -qF 'Resolve `orchestration.analysis_only`' <<<"$stage1"; then
        pass "analysis-only Stage 1: resolves orchestration.analysis_only"
    else
        fail "analysis-only Stage 1: resolves orchestration.analysis_only" \
            "Stage 1 must resolve \$ANALYSIS_ONLY from orchestration.analysis_only (two-layer, default false) before any PR-state decision — the anti-short-circuit and Stage 6 suppression both depend on the variable being bound here"
    fi

    if grep -qF 'Do not short-circuit on PR state under analysis-only' <<<"$stage1"; then
        pass "analysis-only Stage 1: forbids the MERGED/CLOSED short-circuit"
    else
        fail "analysis-only Stage 1: forbids the MERGED/CLOSED short-circuit" \
            "Stage 1 must carry the explicit 'Do not short-circuit on PR state under analysis-only' instruction — without it the model rationalises a halt on a merged PR before dispatching any specialist (the root-cause failure this mode fixes)"
    fi
}

test_analysis_only_phase04_suppress_present_in_canonical() {
    # The existing pipeline-inline sync test enforces byte-identity across the three
    # copies, but a *unanimous* deletion would keep them identical and pass. This
    # presence check on the canonical is belt-and-braces: it fails if the analysis-only
    # Phase 0.4 suppression clause is removed from all three at once.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Phase 0.4 suppression" "code-review-suite plugin not found"
        return
    fi

    local canonical="$cr/includes/review-pipeline.md"
    if [[ ! -f "$canonical" ]]; then
        fail "analysis-only Phase 0.4 suppression: canonical present" "missing: $canonical"
        return
    fi

    if grep -qF 'Phase 0 halt (analysis-only, not posted)' "$canonical"; then
        pass "analysis-only Phase 0.4 suppression: canonical carries the render-not-post clause"
    else
        fail "analysis-only Phase 0.4 suppression: canonical carries the render-not-post clause" \
            "review-pipeline.md Phase 0.4 pr-mode block must, under \$ANALYSIS_ONLY = true, render the halt notice to stdout ('Phase 0 halt (analysis-only, not posted)') instead of posting a REQUEST_CHANGES review — otherwise analysis-only still writes to GitHub on a narrative-less PR"
    fi
}

test_analysis_only_stage6_render_not_post() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Stage 6 render-not-post" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "analysis-only Stage 6: SKILL.md present" "missing: $skill"
        return
    fi

    # Slice Stage 6 so the assertions can't be satisfied by text elsewhere.
    local step6
    step6=$(sed -n '/^## Stage 6: Submit Review Verdict/,/^## Stage 7/p' "$skill")

    if grep -qF 'Analysis-only — render, do not post' <<<"$step6"; then
        pass "analysis-only Stage 6: carries the render-not-post subsection"
    else
        fail "analysis-only Stage 6: carries the render-not-post subsection" \
            "Stage 6 must carry an 'Analysis-only — render, do not post' subsection that, under \$ANALYSIS_ONLY = true, skips Classes A/B/C and renders the bundle to stdout — otherwise analysis-only submits the verdict and inline comments to GitHub"
    fi

    if grep -qF 'Verdict (analysis-only, not submitted)' <<<"$step6"; then
        pass "analysis-only Stage 6: renders the verdict line to stdout"
    else
        fail "analysis-only Stage 6: renders the verdict line to stdout" \
            "the analysis-only render path must print '> Verdict (analysis-only, not submitted): \$SYNTH_VERDICT' so the verdict is visible without being submitted"
    fi
}

test_sync_phase_055_local_branch_freshness_check() {
    # Phase 0.55 protects the pipeline from measuring a stale diff: if the local HEAD
    # is behind the PR's remote head, the review analyses an outdated tree and ships
    # a false-clean report against the wrong commit set. The check has three load-
    # bearing commands; this test asserts each one is present in the canonical so a
    # future edit cannot silently delete one and break the protection.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "Phase 0.55 local branch freshness" "code-review-suite plugin not found"
        return
    fi

    local canonical="$cr/includes/review-pipeline.md"
    if [[ ! -f "$canonical" ]]; then
        fail "Phase 0.55 local branch freshness" "review-pipeline.md not found"
        return
    fi

    # Site 1: the heading must exist in the canonical (the existing pipeline sync test
    # then enforces byte-identical propagation to the two inlined consumers).
    if grep -qE '^## Phase 0\.55: Local branch freshness check$' "$canonical"; then
        pass "Phase 0.55 local branch freshness: section heading present"
    else
        fail "Phase 0.55 local branch freshness: section heading present" \
            "review-pipeline.md must contain '## Phase 0.55: Local branch freshness check' as its own section, positioned between Phase 0 and Phase 0.6 — the heading is the test anchor for the three command-presence assertions below"
    fi

    # Site 2: must fetch the remote head via gh pr view --json headRefOid. Without this
    # the orchestrator has nothing to compare HEAD against — Phase 0.55 collapses to
    # a no-op.
    if grep -qE 'gh pr view "\$ARGUMENTS" --json headRefOid' "$canonical"; then
        pass "Phase 0.55 local branch freshness: fetches remote head SHA"
    else
        fail "Phase 0.55 local branch freshness: fetches remote head SHA" \
            "Phase 0.55 must fetch \$REMOTE_HEAD_SHA via 'gh pr view \"\$ARGUMENTS\" --json headRefOid' — the freshness check has no input without it"
    fi

    # Site 3: must verify the SHA is locally known via git cat-file -e. Otherwise the
    # next assertion (merge-base) would error confusingly when the remote was force-
    # pushed and the user has not fetched.
    if grep -qE 'git cat-file -e "\$REMOTE_HEAD_SHA"' "$canonical"; then
        pass "Phase 0.55 local branch freshness: verifies remote SHA is locally known"
    else
        fail "Phase 0.55 local branch freshness: verifies remote SHA is locally known" \
            "Phase 0.55 must run 'git cat-file -e \"\$REMOTE_HEAD_SHA\"' to verify the remote head exists in the local clone — otherwise an unfetched remote presents as 'diverged' rather than 'unknown', misdirecting the user"
    fi

    # Site 4: must verify HEAD is at-or-ahead of remote via merge-base --is-ancestor.
    # This is the load-bearing check — exit 0 when remote is an ancestor of HEAD
    # (local at or ahead), exit 1 when local is behind or diverged.
    if grep -qE 'git merge-base --is-ancestor "\$REMOTE_HEAD_SHA" HEAD' "$canonical"; then
        pass "Phase 0.55 local branch freshness: asserts HEAD is at-or-ahead of remote"
    else
        fail "Phase 0.55 local branch freshness: asserts HEAD is at-or-ahead of remote" \
            "Phase 0.55 must run 'git merge-base --is-ancestor \"\$REMOTE_HEAD_SHA\" HEAD' — this is the actual freshness assertion. Without it, the gate is decorative"
    fi
}

test_orchestrator_comment_elision_negative_presence() {
    # After the orchestrator-COMMENT elision (spec 2026-05-19), three legacy
    # strings must not reappear in the contractually-expected sites:
    #
    # 1. SKILL.md must not contain "Outstanding peer REQUEST_CHANGES" — Class B.3
    #    was deleted in full. Reintroduction would mean the peer-RC downgrade
    #    path crept back, contradicting `final = synth`.
    # 2. SKILL.md must not contain `$DOWNGRADE_REASON` — the variable is retired
    #    along with Class A.3's middle template. Any reference would be dangling.
    # 3. The trivial-mode mini-review verdict bullet ("COMMENT if minor
    #    observations") was removed from the canonical pipeline and both inlined
    #    consumers. Reintroduction in any of the three sites would re-enable
    #    trivial-mode COMMENT verdicts.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "orchestrator COMMENT elision negative presence" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "orchestrator COMMENT elision: SKILL.md present" "missing: $skill"
        return
    fi

    if grep -qF 'Outstanding peer REQUEST_CHANGES' "$skill"; then
        fail "orchestrator COMMENT elision: SKILL.md drops 'Outstanding peer REQUEST_CHANGES'" \
            "Class B.3 (Outstanding peer REQUEST_CHANGES) was deleted by the 2026-05-19 spec — reintroduction reinstates the APPROVE → COMMENT downgrade path that conflicts with 'final = synth'"
    else
        pass "orchestrator COMMENT elision: SKILL.md drops 'Outstanding peer REQUEST_CHANGES'"
    fi

    if grep -qF '$DOWNGRADE_REASON' "$skill"; then
        fail "orchestrator COMMENT elision: SKILL.md drops \$DOWNGRADE_REASON" \
            "the \$DOWNGRADE_REASON variable was retired by the 2026-05-19 spec — any reference is dangling"
    else
        pass "orchestrator COMMENT elision: SKILL.md drops \$DOWNGRADE_REASON"
    fi

    local pipeline_canonical="$cr/includes/review-pipeline.md"
    local pipeline_skill="$skill"
    local pipeline_command="$cr/commands/pre-review.md"

    local site
    for site in "$pipeline_canonical" "$pipeline_skill" "$pipeline_command"; do
        local label
        label=$(basename "$(dirname "$site")")/$(basename "$site")

        if [[ ! -f "$site" ]]; then
            fail "orchestrator COMMENT elision: $label present" "missing: $site"
            continue
        fi

        if grep -qF 'COMMENT if minor observations' "$site"; then
            fail "orchestrator COMMENT elision: $label drops 'COMMENT if minor observations'" \
                "the trivial-mode mini-review's COMMENT verdict bullet was removed by the 2026-05-19 spec — reintroduction in any of the three propagation sites re-enables trivial-mode COMMENT verdicts"
        else
            pass "orchestrator COMMENT elision: $label drops 'COMMENT if minor observations'"
        fi
    done
}

test_housekeeping_trigger_mirrors_engine_scope() {
    # The Step 2.6 "Housekeeping detection" prose names source-file extensions
    # that MUST mirror the engine's _NUGET_SCOPE_SUFFIXES / _NPM_SCOPE_SUFFIXES
    # constants. If the trigger names an extension the engine does not scope, the
    # housekeeper dispatches and finds nothing (dead dispatch). This test pins the
    # prose list against the engine so the two cannot drift silently — the exact
    # failure mode the 2026-06-11 source-file-trigger change fixed.
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "housekeeping trigger mirrors engine scope" "code-review-suite plugin not found"
        return
    fi

    local pipeline engine
    pipeline="$cr/includes/review-pipeline.md"
    engine="$cr/bin/housekeeper-freshness"

    if [[ ! -f "$pipeline" || ! -f "$engine" ]]; then
        fail "housekeeping trigger mirrors engine scope: inputs present" \
            "missing pipeline ($pipeline) or engine ($engine)"
        return
    fi

    # Extract the "Housekeeping detection" bullet line from the canonical.
    local bullet
    bullet=$(grep -F 'Housekeeping detection:' "$pipeline" | head -1)
    if [[ -z "$bullet" ]]; then
        fail "housekeeping trigger mirrors engine scope: bullet found" \
            "no 'Housekeeping detection:' bullet in review-pipeline.md"
        return
    fi

    # Every source-file extension the trigger must name (mirror of the engine
    # scope sets, source files only — manifest extensions like .csproj are tested
    # by the existing prose-parity test, not here).
    local ext missing
    missing=""
    for ext in .cs .fs .vb .razor .cshtml .ts .tsx .js .jsx .mjs .cjs .mts .cts .vue .svelte .py .pyi; do
        # Present in the trigger prose?
        if ! grep -qF "\`$ext\`" <<<"$bullet"; then
            missing="$missing prose:$ext"
            continue
        fi
        # Present in an engine scope constant?
        if ! grep -qF "\"$ext\"" "$engine"; then
            missing="$missing engine:$ext"
        fi
    done

    if [[ -z "$missing" ]]; then
        pass "housekeeping trigger mirrors engine scope: all source extensions present in prose and engine"
    else
        fail "housekeeping trigger mirrors engine scope: all source extensions present in prose and engine" \
            "extensions missing (prose:X = absent from trigger bullet, engine:X = absent from engine scope constants):$missing"
    fi

    # Docker is matched by Dockerfile basename, not extension. Assert the
    # trigger names 'Dockerfile' AND the engine has the _is_dockerfile gate.
    if grep -qF 'Dockerfile' <<<"$bullet" && grep -qF '_is_dockerfile' "$engine"; then
        pass "housekeeping trigger mirrors engine scope: Dockerfile detection present in prose and engine"
    else
        fail "housekeeping trigger mirrors engine scope: Dockerfile detection present in prose and engine" \
            "trigger bullet must name 'Dockerfile' and engine must define _is_dockerfile"
    fi
}

test_analysis_only_stage5_skips_posting() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only Stage 5 skips posting" "code-review-suite plugin not found"
        return
    fi

    local skill="$cr/skills/review-gh-pr/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "analysis-only Stage 5: SKILL.md present" "missing: $skill"
        return
    fi

    # Slice Stage 5 so the assertion cannot be satisfied by text elsewhere in the file.
    local stage5
    stage5=$(sed -n '/^## Stage 5: Add Inline Comments/,/^## Stage 6:/p' "$skill")

    if grep -qF 'Under `$ANALYSIS_ONLY = true`, skip this stage entirely' <<<"$stage5"; then
        pass "analysis-only Stage 5: carries skip-posting guard"
    else
        fail "analysis-only Stage 5: carries skip-posting guard" \
            "Stage 5 must open with 'Under \`\$ANALYSIS_ONLY = true\`, skip this stage entirely' — without it an analysis_only run posts inline comments to GitHub before ever reaching Stage 6's suppression clause"
    fi
}

test_analysis_only_trivial_pr_no_post() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "analysis-only trivial-mode pr no-post" "code-review-suite plugin not found"
        return
    fi

    local canonical="$cr/includes/review-pipeline.md"
    if [[ ! -f "$canonical" ]]; then
        fail "analysis-only trivial-mode pr no-post: canonical present" "missing: $canonical"
        return
    fi

    if grep -qF 'Under `$ANALYSIS_ONLY = true`, do not post' "$canonical"; then
        pass "analysis-only trivial-mode pr no-post: canonical carries Phase 0.7.9 guard"
    else
        fail "analysis-only trivial-mode pr no-post: canonical carries Phase 0.7.9 guard" \
            "review-pipeline.md Phase 0.7.9 pr-mode block must carry 'Under \`\$ANALYSIS_ONLY = true\`, do not post' so an analysis_only run skips the trivial-mode inline POST and verdict submission"
    fi
}

test_sync_agent_hazard_severity_basis() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "agent-hazard severity basis" "code-review-suite plugin not found"
        return
    fi

    local sev="$cr/includes/severity-definitions.md"
    local synth="$cr/agents/review-synthesiser.md"
    local apic="$cr/agents/api-contract-reviewer.md"

    local f
    for f in "$sev" "$synth" "$apic"; do
        if [[ ! -f "$f" ]]; then
            fail "agent-hazard severity basis: inputs present" "missing: $f"
            return
        fi
    done

    # Canonical: the basis heading, the load-bearing predicate, and the
    # Critical-untouched guardrail must all be present in severity-definitions.md.
    local lit
    for lit in \
        '**Agent-hazard basis**' \
        'predictably cause a future maintainer' \
        'Important only, never Critical'; do
        if grep -qF "$lit" "$sev"; then
            pass "agent-hazard severity basis: severity-definitions.md contains '$lit'"
        else
            fail "agent-hazard severity basis: severity-definitions.md contains '$lit'" \
                "literal not found in $sev"
        fi
    done

    # Ripple lock: the synthesiser's reclassification step must reference the
    # shared anchor, or it will silently downgrade agent-hazard findings.
    if grep -qF 'agent-hazard basis' "$synth"; then
        pass "agent-hazard severity basis: synthesiser references the agent-hazard basis"
    else
        fail "agent-hazard severity basis: synthesiser references the agent-hazard basis" \
            "anchor 'agent-hazard basis' not found in $synth"
    fi

    # Additive re-point lock: comment-truth (now in api-contract) must cite the basis.
    if grep -qF 'agent-hazard basis' "$apic"; then
        pass "agent-hazard severity basis: comment-truth cites the agent-hazard basis"
    else
        fail "agent-hazard severity basis: comment-truth cites the agent-hazard basis" \
            "anchor 'agent-hazard basis' not found in $apic"
    fi
}
