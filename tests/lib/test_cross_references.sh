#!/usr/bin/env bash
# Cross-reference integrity tests — include references resolve, expected files exist.

test_include_references_resolve() {
    # Find all backtick-quoted references to includes/ in plugin Markdown files
    while IFS= read -r plugin_dir; do
        local plugin_name
        plugin_name=$(basename "$plugin_dir")
        local refs_found=false

        while IFS=: read -r file match; do
            refs_found=true
            # Extract path from backtick-quoted reference like `includes/foo.md`
            local ref_path
            ref_path=$(echo "$match" | grep -oE 'includes/[a-zA-Z0-9_-]+\.md' | head -1)
            if [[ -z "$ref_path" ]]; then
                continue
            fi

            local full_path="$plugin_dir/$ref_path"
            local rel_file
            rel_file=$(echo "$file" | sed "s|^$REPO_ROOT/||")
            if [[ -f "$full_path" ]]; then
                pass "$plugin_name: $ref_path referenced from $(basename "$rel_file")"
            else
                fail "$plugin_name: $ref_path referenced from $(basename "$rel_file")" "file not found: $full_path"
            fi
        done < <(grep -rn 'includes/[a-zA-Z0-9_-]*\.md' "$plugin_dir" \
            --include='*.md' 2>/dev/null | grep -v "^$plugin_dir/includes/")
        # Files inside includes/ are checked by the loop below.

        # Also check references FROM includes/ files to other includes/ files
        if [[ -d "$plugin_dir/includes" ]]; then
            while IFS=: read -r file match; do
                refs_found=true
                local ref_path
                ref_path=$(echo "$match" | grep -oE 'includes/[a-zA-Z0-9_-]+\.md' | head -1)
                if [[ -z "$ref_path" ]]; then
                    continue
                fi
                local full_path="$plugin_dir/$ref_path"
                local rel_file
                rel_file=$(echo "$file" | sed "s|^$REPO_ROOT/||")
                if [[ -f "$full_path" ]]; then
                    pass "$plugin_name: $ref_path referenced from $(basename "$rel_file")"
                else
                    fail "$plugin_name: $ref_path referenced from $(basename "$rel_file")" "not found"
                fi
            done < <(grep -rn 'includes/[a-zA-Z0-9_-]*\.md' "$plugin_dir/includes" \
                --include='*.md' 2>/dev/null)
        fi

    done < <(find "$REPO_ROOT/plugins" -mindepth 1 -maxdepth 1 -type d)
}

test_every_plugin_has_readme() {
    while IFS= read -r plugin_dir; do
        local name
        name=$(basename "$plugin_dir")
        assert_file_exists "plugins/$name/README.md" "$name: has README.md"
    done < <(find "$REPO_ROOT/plugins" -mindepth 1 -maxdepth 1 -type d)
}

test_skill_directories_have_skill_md() {
    while IFS= read -r plugin_dir; do
        local name
        name=$(basename "$plugin_dir")
        if [[ -d "$plugin_dir/skills" ]]; then
            local skill_count
            skill_count=$(find "$plugin_dir/skills" -name 'SKILL.md' | wc -l | tr -d ' ')
            if [[ "$skill_count" -gt 0 ]]; then
                pass "$name: skills/ has SKILL.md ($skill_count)"
            else
                fail "$name: skills/ has SKILL.md" "skills/ directory exists but contains no SKILL.md"
            fi
        fi
    done < <(find "$REPO_ROOT/plugins" -mindepth 1 -maxdepth 1 -type d)
}

test_agent_directories_have_agents() {
    while IFS= read -r plugin_dir; do
        local name
        name=$(basename "$plugin_dir")
        if [[ -d "$plugin_dir/agents" ]]; then
            local agent_count
            agent_count=$(find "$plugin_dir/agents" -name '*.md' | wc -l | tr -d ' ')
            if [[ "$agent_count" -gt 0 ]]; then
                pass "$name: agents/ has definitions ($agent_count)"
            else
                fail "$name: agents/ has definitions" "agents/ directory exists but contains no .md files"
            fi
        fi
    done < <(find "$REPO_ROOT/plugins" -mindepth 1 -maxdepth 1 -type d)
}

test_command_directories_have_commands() {
    while IFS= read -r plugin_dir; do
        local name
        name=$(basename "$plugin_dir")
        if [[ -d "$plugin_dir/commands" ]]; then
            local cmd_count
            cmd_count=$(find "$plugin_dir/commands" -name '*.md' | wc -l | tr -d ' ')
            if [[ "$cmd_count" -gt 0 ]]; then
                pass "$name: commands/ has definitions ($cmd_count)"
            else
                fail "$name: commands/ has definitions" "commands/ directory exists but contains no .md files"
            fi
        fi
    done < <(find "$REPO_ROOT/plugins" -mindepth 1 -maxdepth 1 -type d)
}

test_static_analysis_context_exists() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    assert_file_exists "plugins/code-review-suite/includes/static-analysis-context.md" \
        "code-review-suite: static-analysis-context.md exists"
}

test_static_analysis_specialists_cite_include() {
    local cr="$REPO_ROOT/plugins/code-review-suite"
    if [[ ! -d "$cr" ]]; then
        skip "static-analysis citation" "code-review-suite plugin not found"
        return
    fi

    local agent
    for agent in eslint-reviewer.md ruff-reviewer.md trivy-reviewer.md jbinspect-reviewer.md; do
        local path="$cr/agents/$agent"
        if [[ ! -f "$path" ]]; then
            fail "static-analysis citation: $agent" "file not found"
            continue
        fi
        if grep -qF 'includes/static-analysis-context.md' "$path"; then
            pass "static-analysis citation: $agent cites includes/static-analysis-context.md"
        else
            fail "static-analysis citation: $agent cites includes/static-analysis-context.md" \
                "literal token 'includes/static-analysis-context.md' not found"
        fi
    done
}

# Every path to an agent or include file that the plugins, tests or evals name must exist, so a
# deleted agent or include cannot leave a dangling reference behind.
test_plugin_file_references_resolve() {
    local ref plugin
    while IFS= read -r ref; do
        plugin="${ref#plugins/}"
        plugin="${plugin%%/*}"
        # A path into a plugin that does not exist is a synthetic test fixture, not a reference.
        [[ -d "$REPO_ROOT/plugins/$plugin" ]] || continue
        if [[ -f "$REPO_ROOT/$ref" ]]; then
            pass "file reference resolves: $ref"
        else
            fail "file reference resolves: $ref" "named in plugins/, tests/ or evals/ but not found"
        fi
    done < <(git -C "$REPO_ROOT" grep -hoIE 'plugins/[a-z0-9-]+/(agents|includes)/[A-Za-z0-9_-]+\.(md|json)' \
        -- plugins tests evals | sort -u)
    # Inside a plugin, a bare agents/<name>.md names that plugin's own agent.
    local plugin_dir
    while IFS= read -r plugin_dir; do
        plugin=$(basename "$plugin_dir")
        while IFS= read -r ref; do
            if [[ -f "$plugin_dir/$ref" ]]; then
                pass "$plugin: $ref resolves"
            else
                fail "$plugin: $ref resolves" "named inside plugins/$plugin but not found"
            fi
        done < <(git -C "$REPO_ROOT" grep -hoIE 'agents/[A-Za-z0-9_-]+\.md' -- "plugins/$plugin" | sort -u)
    done < <(find "$REPO_ROOT/plugins" -mindepth 1 -maxdepth 1 -type d)
}

# Every code-review-suite:<name> reference must name an agent, skill or command that exists.
test_code_review_suite_names_resolve() {
    local cr="$REPO_ROOT/plugins/code-review-suite" name
    while IFS= read -r name; do
        name="${name#code-review-suite:}"
        if [[ -f "$cr/agents/$name.md" || -f "$cr/commands/$name.md" || -d "$cr/skills/$name" \
            || -f "$cr/workflows/$name.js" ]]; then
            pass "code-review-suite:$name resolves"
        else
            fail "code-review-suite:$name resolves" "no agent, command, skill or workflow of that name"
        fi
    done < <(git -C "$REPO_ROOT" grep -hoIE 'code-review-suite:[a-z][a-z0-9-]*[a-z0-9]' \
        -- plugins tests evals | sort -u)
}
