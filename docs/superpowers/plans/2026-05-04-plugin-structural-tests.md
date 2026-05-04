# Plugin Structural Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shell-based structural test suite that validates plugin manifests, file conventions, cross-references, and sync-note consistency across all 5 plugins, runnable locally and in CI.

**Architecture:** A single `tests/run.sh` entrypoint sources per-category test files from `tests/lib/`. Each test file contains individual test functions. A minimal TAP-like harness (`tests/lib/harness.sh`) provides `pass`/`fail`/`skip` helpers and a summary. Tests run against the working tree (no git operations needed). CI runs the same script via a GitHub Actions workflow.

**Tech Stack:** POSIX shell (bash 4+), `jq` (JSON validation), `grep`/`sed`/`diff` (text assertions). Zero external dependencies beyond what's already available in the CI runner (`ubuntu-latest`) and local dev (macOS with Homebrew).

---

## File Structure

```
tests/
  run.sh                       # Entrypoint — sources harness + test files, runs all, prints summary
  lib/
    harness.sh                 # pass/fail/skip helpers, counters, summary, exit code
    test_manifests.sh          # T1: marketplace + plugin.json schema validation
    test_conventions.sh        # T2: line endings, indentation, final newlines, executable bits
    test_cross_references.sh   # T3: include references resolve, marketplace source paths exist
    test_sync_notes.sh         # T4: base-branch resolution steps match across 3 files, validation regexes match
.github/workflows/tests.yml   # CI workflow
```

Each `test_*.sh` file defines functions named `test_*`. `run.sh` sources them all and calls every function matching that pattern.

---

### Task 1: Test Harness

**Files:**
- Create: `tests/lib/harness.sh`

This is the foundation — all subsequent tasks depend on it.

- [ ] **Step 1: Write `harness.sh`**

```bash
#!/usr/bin/env bash
# Minimal test harness — pass/fail/skip helpers with TAP-like output.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_pass_count=0
_fail_count=0
_skip_count=0
_failures=()

pass() {
    local desc="$1"
    _pass_count=$((_pass_count + 1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
}

fail() {
    local desc="$1"
    local detail="${2:-}"
    _fail_count=$((_fail_count + 1))
    _failures+=("$desc")
    printf '  \033[31m✗\033[0m %s\n' "$desc"
    if [[ -n "$detail" ]]; then
        printf '    %s\n' "$detail"
    fi
}

skip() {
    local desc="$1"
    local reason="${2:-}"
    _skip_count=$((_skip_count + 1))
    printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$desc" "$reason"
}

assert_file_exists() {
    local path="$1"
    local desc="${2:-file exists: $path}"
    if [[ -f "$REPO_ROOT/$path" ]]; then
        pass "$desc"
    else
        fail "$desc" "not found: $path"
    fi
}

assert_dir_exists() {
    local path="$1"
    local desc="${2:-directory exists: $path}"
    if [[ -d "$REPO_ROOT/$path" ]]; then
        pass "$desc"
    else
        fail "$desc" "not found: $path"
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local desc="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_matches() {
    local pattern="$1"
    local value="$2"
    local desc="$3"
    if [[ "$value" =~ $pattern ]]; then
        pass "$desc"
    else
        fail "$desc" "value '$value' does not match pattern '$pattern'"
    fi
}

assert_not_matches() {
    local pattern="$1"
    local value="$2"
    local desc="$3"
    if [[ ! "$value" =~ $pattern ]]; then
        pass "$desc"
    else
        fail "$desc" "value '$value' unexpectedly matches pattern '$pattern'"
    fi
}

summary() {
    local total=$((_pass_count + _fail_count + _skip_count))
    echo ""
    printf '%d tests: \033[32m%d passed\033[0m' "$total" "$_pass_count"
    if [[ $_fail_count -gt 0 ]]; then
        printf ', \033[31m%d failed\033[0m' "$_fail_count"
    fi
    if [[ $_skip_count -gt 0 ]]; then
        printf ', \033[33m%d skipped\033[0m' "$_skip_count"
    fi
    echo ""

    if [[ $_fail_count -gt 0 ]]; then
        echo ""
        printf '\033[31mFailed:\033[0m\n'
        for f in "${_failures[@]}"; do
            printf '  - %s\n' "$f"
        done
        return 1
    fi
    return 0
}
```

- [ ] **Step 2: Verify the file was written correctly**

Run: `bash -n tests/lib/harness.sh`
Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```
git add tests/lib/harness.sh
git commit -m "test: add minimal test harness with pass/fail/skip helpers"
```

---

### Task 2: Test Runner

**Files:**
- Create: `tests/run.sh`

- [ ] **Step 1: Write `run.sh`**

```bash
#!/usr/bin/env bash
# Run all structural tests for the plugin marketplace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/harness.sh"

for test_file in "$SCRIPT_DIR"/lib/test_*.sh; do
    source "$test_file"
done

# Discover and run all test_ functions
mapfile -t test_functions < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

for fn in "${test_functions[@]}"; do
    # Section header from function name: test_foo_bar → foo bar
    section="${fn#test_}"
    section="${section//_/ }"
    printf '\n\033[1m%s\033[0m\n' "$section"
    "$fn"
done

summary
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x tests/run.sh`

- [ ] **Step 3: Verify syntax and that it sources correctly**

Run: `bash -n tests/run.sh`
Expected: no output (syntax OK)

- [ ] **Step 4: Commit**

```
git add tests/run.sh
git commit -m "test: add test runner entrypoint"
```

---

### Task 3: Manifest Tests

**Files:**
- Create: `tests/lib/test_manifests.sh`

Tests:
- marketplace.json is valid JSON with required fields
- Each plugin listed in marketplace.json has a matching plugin.json
- Each plugin.json is valid JSON with required fields (`name`, `description`, `author`, `license`, `keywords`)
- No plugin.json contains a `version` field (versions come from git SHA)
- Plugin `name` in plugin.json matches the directory name
- Plugin `name` in plugin.json matches the `name` in its marketplace.json entry

- [ ] **Step 1: Write the test file**

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tests/lib/test_manifests.sh`
Expected: no output

- [ ] **Step 3: Run the test suite to verify manifest tests pass**

Run: `tests/run.sh`
Expected: all manifest tests pass (green ticks)

- [ ] **Step 4: Commit**

```
git add tests/lib/test_manifests.sh
git commit -m "test: add manifest schema and cross-validation tests"
```

---

### Task 4: Convention Tests

**Files:**
- Create: `tests/lib/test_conventions.sh`

Tests:
- All text files use LF line endings (no CRLF)
- All `.md` and `.json` files use 2-space indentation (per `.editorconfig`)
- All `.sh` files use 4-space indentation (per `.editorconfig`)
- All text files end with a final newline
- All files in `bin/` and `tools/` directories are executable (`+x`)
- No trailing whitespace in `.json`, `.yml`, `.yaml` files (`.md` is exempt per `.editorconfig`)

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bash
# Convention compliance tests — line endings, indentation, final newlines, executable bits.

test_lf_line_endings() {
    local bad_files=()
    while IFS= read -r f; do
        if grep -Plq '\r\n' "$REPO_ROOT/$f" 2>/dev/null; then
            bad_files+=("$f")
        fi
    done < <(find "$REPO_ROOT/plugins" "$REPO_ROOT/.claude-plugin" -type f \
        \( -name '*.md' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.sh' -o -name '*.toml' \) \
        -not -path '*/.git/*' | sed "s|^$REPO_ROOT/||")

    if [[ ${#bad_files[@]} -eq 0 ]]; then
        pass "all text files use LF line endings"
    else
        fail "all text files use LF line endings" "CRLF found in: ${bad_files[*]}"
    fi
}

test_md_json_indentation() {
    local bad_files=()
    while IFS= read -r f; do
        # Check for lines indented with tabs or odd-space indentation (not multiple of 2)
        # Only check lines that start with whitespace
        if grep -Pn '^\t' "$REPO_ROOT/$f" >/dev/null 2>&1; then
            bad_files+=("$f (tabs)")
        fi
    done < <(find "$REPO_ROOT/plugins" "$REPO_ROOT/.claude-plugin" -type f \
        \( -name '*.md' -o -name '*.json' \) \
        -not -path '*/.git/*' | sed "s|^$REPO_ROOT/||")

    if [[ ${#bad_files[@]} -eq 0 ]]; then
        pass ".md and .json files use space indentation (no tabs)"
    else
        fail ".md and .json files use space indentation (no tabs)" "${bad_files[*]}"
    fi
}

test_final_newline() {
    local bad_files=()
    while IFS= read -r f; do
        local full="$REPO_ROOT/$f"
        # File must be non-empty and end with a newline
        if [[ -s "$full" ]]; then
            local last_byte
            last_byte=$(tail -c 1 "$full" | xxd -p)
            if [[ "$last_byte" != "0a" ]]; then
                bad_files+=("$f")
            fi
        fi
    done < <(find "$REPO_ROOT/plugins" "$REPO_ROOT/.claude-plugin" -type f \
        -not -path '*/.git/*' -not -name '*.png' -not -name '*.jpg' -not -name '*.gif' \
        | sed "s|^$REPO_ROOT/||")

    if [[ ${#bad_files[@]} -eq 0 ]]; then
        pass "all text files end with a final newline"
    else
        fail "all text files end with a final newline" "missing in: ${bad_files[*]}"
    fi
}

test_executables_have_x_bit() {
    local found_any=false
    while IFS= read -r f; do
        found_any=true
        local rel
        rel=$(echo "$f" | sed "s|^$REPO_ROOT/||")
        if [[ -x "$f" ]]; then
            pass "executable: $rel"
        else
            fail "executable: $rel" "file in bin/ or tools/ is not executable"
        fi
    done < <(find "$REPO_ROOT/plugins" -type f \( -path '*/bin/*' -o -path '*/tools/*' \) \
        -not -path '*/.git/*')

    if [[ "$found_any" == "false" ]]; then
        skip "executable bit check" "no bin/ or tools/ files found"
    fi
}

test_no_trailing_whitespace_in_structured_files() {
    local bad_files=()
    while IFS= read -r f; do
        if grep -Pn '\s+$' "$REPO_ROOT/$f" >/dev/null 2>&1; then
            bad_files+=("$f")
        fi
    done < <(find "$REPO_ROOT/plugins" "$REPO_ROOT/.claude-plugin" -type f \
        \( -name '*.json' -o -name '*.yml' -o -name '*.yaml' \) \
        -not -path '*/.git/*' | sed "s|^$REPO_ROOT/||")

    if [[ ${#bad_files[@]} -eq 0 ]]; then
        pass "no trailing whitespace in .json/.yml/.yaml files"
    else
        fail "no trailing whitespace in .json/.yml/.yaml files" "${bad_files[*]}"
    fi
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tests/lib/test_conventions.sh`
Expected: no output

- [ ] **Step 3: Run the test suite**

Run: `tests/run.sh`
Expected: all convention tests pass

- [ ] **Step 4: Commit**

```
git add tests/lib/test_conventions.sh
git commit -m "test: add convention compliance tests (line endings, indentation, newlines, +x)"
```

---

### Task 5: Cross-Reference Tests

**Files:**
- Create: `tests/lib/test_cross_references.sh`

Tests:
- Every `includes/` reference in agent/skill/command Markdown resolves to an existing file
- Every plugin has a README.md
- Every plugin with a `skills/` directory has at least one `SKILL.md`
- Every plugin with an `agents/` directory has at least one `.md` file
- Every plugin with a `commands/` directory has at least one `.md` file

- [ ] **Step 1: Write the test file**

```bash
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
            ref_path=$(echo "$match" | grep -oP 'includes/[a-zA-Z0-9_\-]+\.md' | head -1)
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
                ref_path=$(echo "$match" | grep -oP 'includes/[a-zA-Z0-9_\-]+\.md' | head -1)
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tests/lib/test_cross_references.sh`
Expected: no output

- [ ] **Step 3: Run the test suite**

Run: `tests/run.sh`
Expected: all cross-reference tests pass

- [ ] **Step 4: Commit**

```
git add tests/lib/test_cross_references.sh
git commit -m "test: add cross-reference integrity tests (includes, README, skill/agent/command dirs)"
```

---

### Task 6: Sync-Note Tests

**Files:**
- Create: `tests/lib/test_sync_notes.sh`

Tests:
- `$BASE` validation regex is identical across all 3 files (review-pipeline.md, specialist-context.md, review-synthesiser.md)
- `$HEAD_SHA` validation regex is identical across all 3 files
- `$PATH_SCOPE` validation regex is identical across all 3 files
- `$PATH_SCOPE` directory traversal (`..`) check is present in all 3 files
- Base-branch resolution steps 1–4 match between review-pipeline.md and specialist-context.md (the numbered list items)

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bash
# Sync-note consistency tests — validation regexes and base-branch resolution steps match across files.

_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review"
}

_extract_regex() {
    # Extract the regex pattern following "matches `" for a given variable name
    local file="$1"
    local var_name="$2"
    grep "\\\`$var_name\\\` matches" "$file" 2>/dev/null \
        | grep -oP 'matches `\K[^`]+' \
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
    # review-pipeline.md: under "### Step 1: Determine base branch", items 1-4
    # specialist-context.md: under "### Determine base branch", items 1-4

    local pipeline_steps specialist_steps

    # Extract lines starting with "1. " through "4. " (the numbered resolution steps)
    pipeline_steps=$(sed -n '/^Try these in order:$/,/^Store as/{ /^[1-4]\. /p }' \
        "$cr/includes/review-pipeline.md")
    specialist_steps=$(sed -n '/^1\. If `\$ARGUMENTS`/,/^Store as/{ /^[1-4]\. /p }' \
        "$cr/includes/specialist-context.md")

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
        # Write to temp files for diff
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tests/lib/test_sync_notes.sh`
Expected: no output

- [ ] **Step 3: Run the test suite**

Run: `tests/run.sh`
Expected: all sync-note tests pass. If any fail, the extraction `sed`/`grep` patterns need tuning — adjust the patterns and re-run until all pass.

- [ ] **Step 4: Commit**

```
git add tests/lib/test_sync_notes.sh
git commit -m "test: add sync-note consistency tests (validation regexes, base-branch steps)"
```

---

### Task 7: CI Workflow

**Files:**
- Create: `.github/workflows/tests.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: tests

on:
  push:
  pull_request:
    branches: [main]

jobs:
  structural-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - run: tests/run.sh
```

- [ ] **Step 2: Verify syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tests.yml'))"`
Expected: no output (valid YAML)

- [ ] **Step 3: Run the full test suite one final time**

Run: `tests/run.sh`
Expected: all tests pass

- [ ] **Step 4: Commit**

```
git add .github/workflows/tests.yml
git commit -m "ci: add structural test workflow"
```

---

### Task 8: Update CLAUDE.md and gitignore

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a testing section to CLAUDE.md**

Append after the `## Conventions` section:

```markdown
## Testing

Run `tests/run.sh` to validate plugin structure. The test suite checks:
- Manifest schema (marketplace.json + plugin.json fields, no version field)
- Conventions (LF line endings, indentation, final newlines, executable bits)
- Cross-references (include paths resolve, expected directories populated)
- Sync-note consistency (validation regexes and base-branch steps match across files)
```

- [ ] **Step 2: Run the full suite to confirm everything still passes**

Run: `tests/run.sh`
Expected: all tests pass

- [ ] **Step 3: Commit**

```
git add CLAUDE.md
git commit -m "docs: add testing section to CLAUDE.md"
```
