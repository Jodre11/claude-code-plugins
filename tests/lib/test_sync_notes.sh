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

# The files that resolve $BASE, $HEAD_SHA and $PATH_SCOPE on their own and so must agree with
# review-pipeline.md Step 1.
_sync_resolvers() {
    echo "$(_cr_dir)/includes/static-analysis-context.md"
}

# $1 variable name as it appears in the prose (e.g. '\$BASE'), $2 label.
_sync_regex_case() {
    local pipeline file got
    pipeline=$(_extract_regex "$(_cr_dir)/includes/review-pipeline.md" "$1")
    if [[ -z "$pipeline" ]]; then
        fail "$2 regex: extracted from review-pipeline.md" "no '\`$1\` matches' line found"
        return 0
    fi
    while IFS= read -r file; do
        got=$(_extract_regex "$file" "$1")
        assert_equals "$pipeline" "$got" "$2 regex: review-pipeline.md matches $(basename "$file")"
    done < <(_sync_resolvers)
}

test_sync_base_regex_matches() {
    _sync_regex_case '\$BASE' BASE
}

test_sync_head_sha_regex_matches() {
    _sync_regex_case '\$HEAD_SHA' HEAD_SHA
}

test_sync_path_scope_regex_matches() {
    _sync_regex_case '\$PATH_SCOPE' PATH_SCOPE
}

test_sync_path_scope_traversal_check_present() {
    local file
    while IFS= read -r file; do
        if grep -q 'contains `\.\.` as a substring' "$file"; then
            pass "$(basename "$file"): PATH_SCOPE .. traversal check present"
        else
            fail "$(basename "$file"): PATH_SCOPE .. traversal check present" "missing directory traversal guard"
        fi
    done < <(echo "$(_cr_dir)/includes/review-pipeline.md"; _sync_resolvers)
}

test_sync_base_branch_steps_match() {
    # review-pipeline.md lists items 1-4 under "Try these in order:"; each resolver starts
    # directly at "1. If `$ARGUMENTS`".
    local pipeline_steps steps file tmp1 tmp2 diff_output
    pipeline_steps=$(sed -n '/^Try these in order:$/,/^Store as/{
/^[1-4]\. /p
}' "$(_cr_dir)/includes/review-pipeline.md")
    if [[ -z "$pipeline_steps" ]]; then
        fail "base-branch steps: extracted from review-pipeline.md" "no steps found"
        return 0
    fi
    while IFS= read -r file; do
        steps=$(sed -n '/^1\. If `\$ARGUMENTS`/,/^Store as/{
/^[1-4]\. /p
}' "$file")
        if [[ -n "$steps" && "$pipeline_steps" == "$steps" ]]; then
            pass "base-branch resolution steps 1-4 match between pipeline and $(basename "$file")"
        else
            tmp1=$(mktemp)
            tmp2=$(mktemp)
            echo "$pipeline_steps" > "$tmp1"
            echo "$steps" > "$tmp2"
            diff_output=$(diff -u --label review-pipeline.md --label "$(basename "$file")" "$tmp1" "$tmp2" || true)
            rm -f "$tmp1" "$tmp2"
            fail "base-branch resolution steps 1-4 match between pipeline and $(basename "$file")" "$diff_output"
        fi
    done < <(_sync_resolvers)
}

# The severity ladder the static mappings use (§11): Critical stays outage / breach / data
# loss and is reachable only through a tool's allow-list.
test_sync_static_severity_definitions() {
    local sa="$(_cr_dir)/includes/static-analysis-context.md" lit
    for lit in \
        '## 11. Severity definitions' \
        '**data loss, a security breach, or a production outage**' \
        "reaches Critical only through its tool's \`Critical-allow-list:\`" \
        '(see §11)'; do
        if grep -qF -- "$lit" "$sa"; then
            pass "static severity definitions: static-analysis-context.md contains '$lit'"
        else
            fail "static severity definitions: static-analysis-context.md contains '$lit'" "literal not found in $sa"
        fi
    done
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
        for flag in '$CSHARP_DETECTED' '$JS_DETECTED' '$PY_DETECTED' '$IAC_DETECTED' '$HOUSEKEEPING_DETECTED'; do
            if grep -qF "$flag" "$path"; then
                pass "static-analysis dispatcher flags: $file contains $flag"
            else
                fail "static-analysis dispatcher flags: $file contains $flag" \
                    "flag literal not found"
            fi
        done
        # Only the static specialists read detection flags now; the LLM-domain ones retired.
        for flag in '$UI_DETECTED' '$TESTS_DETECTED' '$PRODUCTION_SOURCE_DETECTED' '$SECURITY_SENSITIVE' \
            '$SIGNIFICANT_DELETIONS'; do
            if grep -qF "$flag" "$path"; then
                fail "static-analysis dispatcher flags: $file omits retired $flag" "retired flag still present"
            else
                pass "static-analysis dispatcher flags: $file omits retired $flag"
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
    local review_core="$cr/workflows/review-core.js"
    local f
    for f in "$include" "$review_core"; do
        if [[ ! -f "$f" ]]; then
            fail "static-analysis policy literals: inputs present" "missing: $f"
            return
        fi
    done

    # §10 is the documentation of a contract review-core.js enforces. Each literal is a
    # load-bearing policy claim: drift means the prose no longer describes the code.
    local literal
    for literal in \
        '## 10. Severity-locked policy' \
        '**Severity is locked.**' \
        '**Critical-allow-list mechanism.**' \
        '### Dependency Freshness'; do
        if grep -qF "$literal" "$include"; then
            pass "static-analysis policy literals: §10 contains '$literal'"
        else
            fail "static-analysis policy literals: §10 contains '$literal'" \
                "literal not found in $include"
        fi
    done

    # The enforcement side: the STATIC set names all five specialists, a static finding blocks
    # on the tool's own Critical or Important, and a Critical off the allow-list does not block.
    local literal_code
    for literal_code in \
        "const STATIC = new Set(['jbinspect', 'eslint', 'ruff', 'trivy', 'housekeeper'])" \
        "const blocking = f.severity === 'Critical' || f.severity === 'Important'" \
        "if (f.severity === 'Critical' && !staticCriticalAllowed(s.domain, f)) {"; do
        if grep -qF -- "$literal_code" "$review_core"; then
            pass "static-analysis policy: review-core.js contains '$literal_code'"
        else
            fail "static-analysis policy: review-core.js contains '$literal_code'" \
                "the §10 enforcement line was not found in $review_core"
        fi
    done
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

test_sync_static_analysis_specialist_enumeration() {
    local cr
    cr=$(_cr_dir)
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis specialist enumeration" "code-review-suite plugin not found"
        return
    fi

    local sa_context="$cr/includes/static-analysis-context.md"
    local review_core="$cr/workflows/review-core.js"

    local file
    for file in "$sa_context" "$review_core"; do
        if [[ ! -f "$file" ]]; then
            fail "static-analysis specialist enumeration: $(basename "$file") present" "file not found"
            return
        fi
    done

    # Each of the five static-analysis specialist names must appear in both review-core.js
    # and static-analysis-context.md. Presence is asserted individually (not order/format)
    # so legitimate prose variations do not trigger false positives; dropping a name would
    # silently remove that specialist from the severity-locked contract.
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
        pass "static-analysis specialist enumeration: consistent across canonicals"
    else
        fail "static-analysis specialist enumeration: consistent across canonicals" \
            "review-core.js missing names:${core_missing:-<none>}; static-analysis-context.md missing names:${sa_missing:-<none>} — both must reference all five (jbinspect, eslint, ruff, trivy, housekeeper) static-analysis specialists"
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
    # the rubric is no longer inlined here (review-core's applyRubric applies it) and Class D
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
        "Stage 6 still contains the legacy decision matrix ('| **APPROVE** | No comments are blockers …') — this lets the orchestrator pick a verdict on its own initiative, conflicting with the rubric as sole verdict authority. Delete the matrix; the rubric replaces it."
        "Stage 6 must contain a heading '### Class A — …'. The three remaining classes (A: user-confirmation, B: PR-thread state, C: submission mechanics) document the orchestrator's full decision scope on the Workflow-only path — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Stage 6 must contain a heading '### Class B — …'. The three remaining classes (A: user-confirmation, B: PR-thread state, C: submission mechanics) document the orchestrator's full decision scope on the Workflow-only path — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Stage 6 must contain a heading '### Class C — …'. The three remaining classes (A: user-confirmation, B: PR-thread state, C: submission mechanics) document the orchestrator's full decision scope on the Workflow-only path — missing one means a class of orchestrator behaviour is undocumented and may drift toward judgement-driven action"
        "Stage 6 must read the verdict directly from the Workflow bundle (\$BUNDLE_VERDICT = bundle.verdict) — on the Workflow-only path there is no prose verdict to parse, so the orchestrator consumes bundle.verdict rather than re-deriving a verdict"
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
            "the analysis-only render path must print '> Verdict (analysis-only, not submitted): \$BUNDLE_VERDICT' so the verdict is visible without being submitted"
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
    #    path crept back, contradicting the rubric verdict being final.
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
            "Class B.3 (Outstanding peer REQUEST_CHANGES) was deleted by the 2026-05-19 spec — reintroduction reinstates the APPROVE → COMMENT downgrade path that conflicts with the rubric verdict being final"
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

# Stage 6 in the thin flow: NONE means native did not run, the Class A prompt reads counts
# from bundle.counts, and no panel-era wording survives.
test_skill_md_stage6_thin_contract() {
    local skill="$REPO_ROOT/plugins/code-review-suite/skills/review-gh-pr/SKILL.md" step6 lit
    step6=$(sed -n '/^## Stage 6: Submit Review Verdict/,/^## Stage 7/p' "$skill")
    for lit in 'bundle.native.reason' 'bundle.counts.severity' 'bundle.counts.source' \
        'Never submit `APPROVE` or `REQUEST_CHANGES` for a `NONE` bundle' '`as proposed`'; do
        if grep -qF -- "$lit" <<<"$step6"; then
            pass "Stage 6 thin contract: contains '$lit'"
        else
            fail "Stage 6 thin contract: contains '$lit'" "literal not found in Stage 6 of $skill"
        fi
    done
    for lit in 'panel-proposed' 'Rubric row' 'lightweight' 'applyRubric'; do
        if grep -qF -- "$lit" <<<"$step6"; then
            fail "Stage 6 thin contract: omits '$lit'" "panel-era wording still in Stage 6"
        else
            pass "Stage 6 thin contract: omits '$lit'"
        fi
    done
}
