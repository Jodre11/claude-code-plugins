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
            --include='*.md' 2>/dev/null | grep -v 'includes/' | head -50)
        # Note: the grep -v 'includes/' excludes self-references within includes/ dir itself;
        # we re-include them below

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
                --include='*.md' 2>/dev/null | head -50)
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
    local cr="$REPO_ROOT/plugins/code-review"
    assert_file_exists "plugins/code-review/includes/static-analysis-context.md" \
        "code-review: static-analysis-context.md exists"
}
