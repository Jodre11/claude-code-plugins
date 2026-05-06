#!/usr/bin/env bash
# Convention compliance tests — line endings, indentation, final newlines, executable bits.

# List tracked files under plugins/ and .claude-plugin/, optionally filtered by an extension regex.
# Using `git ls-files` (rather than `find`) ensures only files in the index are scanned, so
# locally-generated artefacts (e.g. __pycache__/*.pyc) and other gitignored paths are skipped.
_list_tracked_files() {
    local ext_regex="${1:-}"
    if [[ -n "$ext_regex" ]]; then
        git -C "$REPO_ROOT" ls-files plugins .claude-plugin | grep -E "$ext_regex"
    else
        git -C "$REPO_ROOT" ls-files plugins .claude-plugin
    fi
}

test_lf_line_endings() {
    local bad_files=()
    while IFS= read -r f; do
        if grep -ql $'\r' "$REPO_ROOT/$f" 2>/dev/null; then
            bad_files+=("$f")
        fi
    done < <(_list_tracked_files '\.(md|json|ya?ml|sh|toml)$')

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
        if grep -n $'^\t' "$REPO_ROOT/$f" >/dev/null 2>&1; then
            bad_files+=("$f (tabs)")
        fi
    done < <(_list_tracked_files '\.(md|json)$')

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
    done < <(_list_tracked_files | grep -Ev '\.(png|jpg|gif)$')

    if [[ ${#bad_files[@]} -eq 0 ]]; then
        pass "all text files end with a final newline"
    else
        fail "all text files end with a final newline" "missing in: ${bad_files[*]}"
    fi
}

test_executables_have_x_bit() {
    local found_any=false
    while IFS= read -r rel; do
        found_any=true
        if [[ -x "$REPO_ROOT/$rel" ]]; then
            pass "executable: $rel"
        else
            fail "executable: $rel" "file in bin/ or tools/ is not executable"
        fi
    done < <(git -C "$REPO_ROOT" ls-files plugins | grep -E '/(bin|tools)/')

    if [[ "$found_any" == "false" ]]; then
        skip "executable bit check" "no bin/ or tools/ files found"
    fi
}

test_no_trailing_whitespace_in_structured_files() {
    local bad_files=()
    while IFS= read -r f; do
        if grep -En '[[:space:]]+$' "$REPO_ROOT/$f" >/dev/null 2>&1; then
            bad_files+=("$f")
        fi
    done < <(_list_tracked_files '\.(json|ya?ml)$')

    if [[ ${#bad_files[@]} -eq 0 ]]; then
        pass "no trailing whitespace in .json/.yml/.yaml files"
    else
        fail "no trailing whitespace in .json/.yml/.yaml files" "${bad_files[*]}"
    fi
}
