#!/usr/bin/env bash
# Panel wiring + drift tests: concern-brief↔CORE sync, host call-site threading.

_pw_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
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
    # Extract the brief's declared domain marker. Use [a-z, ]+ (no hyphen) so the
    # trailing ' -->' of the HTML comment close is not captured.
    brief_line=$(grep -oE 'CORE-DOMAINS: [a-z, ]+' "$brief" | sed 's/CORE-DOMAINS: //' | sed 's/ *$//')
    assert_equals "$core_line" "$brief_line" "concern-brief domain list tracks review-core.mjs CORE"
}
