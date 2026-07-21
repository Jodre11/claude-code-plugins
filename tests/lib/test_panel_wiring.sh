#!/usr/bin/env bash
# Panel wiring + drift tests: concern-brief↔CORE sync, host call-site threading.

_pw_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Both call-sites must thread the three panel params into the workflow invocation.
test_panel_params_threaded_in_both_call_sites() {
    local cr skill prerev
    cr=$(_pw_cr_dir)
    skill="$cr/skills/review-gh-pr/SKILL.md"
    prerev="$cr/commands/pre-review.md"
    for f in "$skill" "$prerev"; do
        if grep -q "orchestrationMode: \$ORCHESTRATION_MODE" "$f" \
            && grep -q "panelSize: \$PANEL_SIZE" "$f" \
            && grep -q "panelBrief: \$PANEL_BRIEF" "$f"; then
            pass "panel params threaded in $(basename "$(dirname "$f")")/$(basename "$f")"
        else
            fail "panel params threaded in $(basename "$f")" "missing orchestrationMode/panelSize/panelBrief"
        fi
    done
}

# Both call-sites must document the panel_size validation (odd, >= 3).
test_panel_size_validation_documented() {
    local cr skill prerev
    cr=$(_pw_cr_dir)
    skill="$cr/skills/review-gh-pr/SKILL.md"
    prerev="$cr/commands/pre-review.md"
    for f in "$skill" "$prerev"; do
        if grep -qiE "panel_size.*(odd|>= ?3|even)" "$f"; then
            pass "panel_size validation documented in $(basename "$f")"
        else
            fail "panel_size validation documented in $(basename "$f")" "no odd/>=3 validation prose found"
        fi
    done
}

# review_mode config default must be documented as classic in both call-sites.
test_panel_review_mode_defaults_classic() {
    local cr skill prerev
    cr=$(_pw_cr_dir)
    skill="$cr/skills/review-gh-pr/SKILL.md"
    prerev="$cr/commands/pre-review.md"
    for f in "$skill" "$prerev"; do
        if grep -qiE "review_mode.*classic" "$f"; then
            pass "review_mode default classic documented in $(basename "$f")"
        else
            fail "review_mode default classic documented in $(basename "$f")" "no classic-default prose"
        fi
    done
}

# The concern-brief's domain list must match the CORE array in review-core.mjs.
# Directional check (brief tracks CORE), not byte-parity. The brief lists domains in
# an HTML comment marker line: <!-- CORE-DOMAINS: security, correctness, ... -->
test_panel_concern_brief_domains_match_core() {
    local cr brief mjs core_line brief_line
    cr=$(_pw_cr_dir)
    brief="$cr/includes/panel-concern-brief.md"
    mjs="$cr/workflows/review-core.mjs"
    if [[ ! -f "$brief" ]]; then
        fail "panel-concern-brief.md exists" "file not found: $brief"
        return
    fi
    # Extract the CORE array contents from the mjs (the quoted domain tokens between
    # `const CORE = [` and the closing `]`), normalise to a comma-space list.
    core_line=$(sed -n '/const CORE = \[/,/\]/p' "$mjs" \
        | grep -oE "'[a-z-]+'" | tr -d "'" | paste -sd, - | sed 's/,/, /g')
    # Extract the brief's declared domain marker. Capture to end-of-line, strip
    # the CORE-DOMAINS: prefix and the trailing ' -->' comment close.
    brief_line=$(grep -oE 'CORE-DOMAINS:.*-->' "$brief" | sed 's/CORE-DOMAINS: //' | sed 's/ *-->$//' | sed 's/ *$//')
    assert_equals "$core_line" "$brief_line" "concern-brief domain list tracks review-core.mjs CORE"
}
