#!/usr/bin/env bash
# Convention compliance tests — line endings, indentation, final newlines, executable bits.

test_lf_line_endings() {
    local bad_files=()
    while IFS= read -r f; do
        if grep -ql $'\r' "$REPO_ROOT/$f" 2>/dev/null; then
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
        if grep -n $'^\t' "$REPO_ROOT/$f" >/dev/null 2>&1; then
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
            local last_char
            last_char=$(tail -c 1 "$full")
            if [[ -n "$last_char" ]]; then
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
    local found_any=0
    while IFS= read -r f; do
        found_any=1
        local rel="${f#"$REPO_ROOT/"}"
        if [[ -x "$f" ]]; then
            pass "executable: $rel"
        else
            fail "executable: $rel" "file in bin/ or tools/ is not executable"
        fi
    done < <(find "$REPO_ROOT/plugins" -type f \( -path '*/bin/*' -o -path '*/tools/*' \) \
        -not -path '*/.git/*')

    if (( found_any == 0 )); then
        skip "executable bit check" "no bin/ or tools/ files found"
    fi
}

test_no_trailing_whitespace_in_structured_files() {
    local bad_files=()
    while IFS= read -r f; do
        if grep -En '[[:space:]]+$' "$REPO_ROOT/$f" >/dev/null 2>&1; then
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
