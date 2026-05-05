#!/usr/bin/env bash
# Manifest schema and cross-validation tests.

test_marketplace_json_valid() {
    local mp="$REPO_ROOT/.claude-plugin/marketplace.json"
    if ! jq empty "$mp" 2>/dev/null; then
        fail "marketplace.json is valid JSON"
        return
    fi
    pass "marketplace.json is valid JSON"

    local name
    name=$(jq -r '.name // empty' "$mp")
    if [[ -n "$name" ]]; then
        pass "marketplace.json has .name"
    else
        fail "marketplace.json has .name"
    fi

    local plugin_count
    plugin_count=$(jq '.plugins | length' "$mp")
    if [[ "$plugin_count" -gt 0 ]]; then
        pass "marketplace.json has plugins ($plugin_count)"
    else
        fail "marketplace.json has plugins" "plugins array is empty"
    fi
}

test_marketplace_plugin_sources_exist() {
    local mp="$REPO_ROOT/.claude-plugin/marketplace.json"
    local sources
    mapfile -t sources < <(jq -r '.plugins[].source' "$mp")

    for src in "${sources[@]}"; do
        # Sources are relative paths like ./plugins/foo
        local resolved="${src#./}"
        assert_dir_exists "$resolved/.claude-plugin" "marketplace source exists: $resolved"
    done
}

test_plugin_json_schema() {
    local mp="$REPO_ROOT/.claude-plugin/marketplace.json"
    local sources
    mapfile -t sources < <(jq -r '.plugins[].source' "$mp")

    for src in "${sources[@]}"; do
        local resolved="${src#./}"
        local pj="$REPO_ROOT/$resolved/.claude-plugin/plugin.json"
        local plugin_dir
        plugin_dir=$(basename "$resolved")

        if ! jq empty "$pj" 2>/dev/null; then
            fail "$plugin_dir: plugin.json is valid JSON"
            continue
        fi
        pass "$plugin_dir: plugin.json is valid JSON"

        for field in name description author license keywords; do
            local val
            val=$(jq -r ".$field // empty" "$pj")
            if [[ -n "$val" ]]; then
                pass "$plugin_dir: plugin.json has .$field"
            else
                fail "$plugin_dir: plugin.json has .$field"
            fi
        done
    done
}

test_plugin_json_no_version_field() {
    local mp="$REPO_ROOT/.claude-plugin/marketplace.json"
    local sources
    mapfile -t sources < <(jq -r '.plugins[].source' "$mp")

    for src in "${sources[@]}"; do
        local resolved="${src#./}"
        local pj="$REPO_ROOT/$resolved/.claude-plugin/plugin.json"
        local plugin_dir
        plugin_dir=$(basename "$resolved")

        local has_version
        has_version=$(jq 'has("version")' "$pj")
        if [[ "$has_version" == "false" ]]; then
            pass "$plugin_dir: plugin.json has no version field"
        else
            fail "$plugin_dir: plugin.json has no version field" "version field present — versions come from git SHA"
        fi
    done
}

test_plugin_name_matches_directory() {
    local mp="$REPO_ROOT/.claude-plugin/marketplace.json"
    local sources
    mapfile -t sources < <(jq -r '.plugins[].source' "$mp")

    for src in "${sources[@]}"; do
        local resolved="${src#./}"
        local pj="$REPO_ROOT/$resolved/.claude-plugin/plugin.json"
        local dir_name
        dir_name=$(basename "$resolved")

        local json_name
        json_name=$(jq -r '.name' "$pj")

        assert_equals "$dir_name" "$json_name" "$dir_name: plugin.json name matches directory"
    done
}

test_plugin_name_matches_marketplace() {
    local mp="$REPO_ROOT/.claude-plugin/marketplace.json"
    local count
    count=$(jq '.plugins | length' "$mp")

    for ((i = 0; i < count; i++)); do
        local mp_name
        mp_name=$(jq -r ".plugins[$i].name" "$mp")
        local src
        src=$(jq -r ".plugins[$i].source" "$mp")
        local resolved="${src#./}"
        local pj="$REPO_ROOT/$resolved/.claude-plugin/plugin.json"

        local pj_name
        pj_name=$(jq -r '.name' "$pj")

        assert_equals "$mp_name" "$pj_name" "$mp_name: marketplace name matches plugin.json name"
    done
}
