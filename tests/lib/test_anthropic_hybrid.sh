#!/usr/bin/env bash
# Hybrid-arm tests: the opt-in anthropic-reviewer adapter in review-core (dispatch, the
# link-to-anchor parser, the fixed severity and confidence, skipped/failed statuses, the log
# meta flag), its agent contract, and the host wiring. review-core.js runs end to end through
# tests/lib/_cv_runner.js (helpers _cv_run and _cv_pans come from test_comment_voice.sh).

_ah_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Review args with the hybrid flag. $1 anthropicSpecialist (true|false|absent), $2 route.
_ah_args() {
    local flag="${1:-true}" route="${2:-full}"
    jq -cn --arg flag "$flag" --arg route "$route" --arg cl "$(printf '%b' 'Changed lines:\na.cs: 1-60\n')" \
        '{agentPrompt: "x", flags: {}, route: $route, selfReReview: false, reviewMode: "pr",
          base: "main", headSha: ("a" * 40), emptyTreeMode: false, pathScope: "",
          tempDir: "/tmp/claude-test/x", intentLedger: "", panelSize: 3, panelBrief: "BRIEF",
          changedLinesBlock: $cl}
         + (if $flag == "absent" then {} else {anthropicSpecialist: ($flag == "true")} end)'
}

# Specialists json whose anthropic entry is the raw adapter result $1.
_ah_specs() {
    jq -cn --argjson a "$1" '{anthropic: $a}'
}

# The anthropic round-1 cog output from a run.
_ah_cog() {
    echo "$1" | jq -c '.bundle.log.cogs[] | select(.phase == "round1" and .domain == "anthropic") | .output'
}

test_anthropic_dispatch_rank_entry() {
    assert_matches 'anthropic: 0,' "$(sed -n '/const DISPATCH_RANK = {/,/^}/p' "$(_ah_cr_dir)/workflows/review-core.js")" \
        "anthropic has DISPATCH_RANK 0 (provisionally the slowest)"
}

test_anthropic_off_by_default() {
    local out flag
    for flag in absent false; do
        out=$(_cv_run "$(_ah_args "$flag")" '{}' "$(_cv_pans 0)")
        _cv_ok "$out" "flag $flag" || continue
        assert_equals 0 "$(echo "$out" | jq '[.dispatches[] | select(.label == "anthropic")] | length')" \
            "hybrid arm: not dispatched when anthropicSpecialist is $flag"
        assert_equals false "$(echo "$out" | jq '.bundle.log.meta.anthropic_specialist')" \
            "hybrid arm: log.meta.anthropic_specialist false when the flag is $flag"
    done
}

test_anthropic_dispatched_first_when_on() {
    local out call
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs '{"status": "ok", "issues": []}')" "$(_cv_pans 0)")
    _cv_ok "$out" "flag on" || return 0
    assert_equals anthropic "$(echo "$out" | jq -r '.dispatches[0].label')" "hybrid arm: dispatched first (slowest-first order)"
    call=$(echo "$out" | jq -c '.dispatches[0].opts | {agentType, stallMs, schemaRequired}')
    assert_equals '{"agentType":"code-review-suite:anthropic-reviewer","stallMs":1800000,"schemaRequired":["status","issues"]}' \
        "$call" "hybrid arm: anthropic-reviewer dispatch with the adapter schema and a 30-minute stall budget"
    assert_equals true "$(echo "$out" | jq '.bundle.log.meta.anthropic_specialist')" \
        "hybrid arm: log.meta.anthropic_specialist true when on"
    assert_equals null "$(echo "$out" | jq '.dispatches[] | select(.label == "correctness") | .opts.stallMs')" \
        "hybrid arm: other specialists keep the default stall budget"
}

test_anthropic_ignored_on_lightweight_route() {
    local out
    out=$(_cv_run "$(_ah_args true lightweight)" '{}' '[]')
    _cv_ok "$out" "lightweight" || return 0
    assert_equals 0 "$(echo "$out" | jq '[.dispatches[] | select(.label == "anthropic")] | length')" \
        "hybrid arm: lightweight route does not dispatch the adapter"
}

# Link → anchor table: each row is "<link>|<expected file>|<expected line>".
test_anthropic_link_to_anchor_parser() {
    local sha rows row link file line issues out got want i=0
    sha=$(printf 'b%.0s' {1..40})
    rows=(
        "a.cs#L10|a.cs|10"
        "a.cs#L10-L10|a.cs|10"
        "a.cs#L5-L12|a.cs|12"
        "https://github.com/o/r/blob/$sha/src/x%20y.cs#L4-L7|src/x y.cs|7"
        "./a.cs#L3|a.cs|3"
        "a.cs|a.cs|0"
        "a.cs#L9-L2|a.cs|0"
        "a.cs#L0|a.cs|0"
        "a.cs#foo|a.cs|0"
        "https://example.com/other#L3||0"
        "#L5||0"
        "||0"
    )
    issues='[]'
    for row in "${rows[@]}"; do
        link="${row%%|*}"
        issues=$(jq -c --arg l "$link" '. + [{description: "d", link: $l, suggested_fix: ""}]' <<<"$issues")
    done
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "$(jq -cn --argjson i "$issues" '{status: "ok", issues: $i}')")" "$(_cv_pans 0)")
    _cv_ok "$out" "link parser" || return 0
    for row in "${rows[@]}"; do
        link="${row%%|*}"
        want="${row#*|}"
        file="${want%%|*}"
        line="${want##*|}"
        got=$(_ah_cog "$out" | jq -r --argjson i "$i" '.findings[$i] | "\(.file)|\(.line)"')
        assert_equals "$file|$line" "$got" "link parser: '$link' anchors at '$file' line $line"
        i=$((i + 1))
    done
}

test_anthropic_normalised_fields() {
    local issues out f
    issues='[{"description": "Breaks the rule.", "link": "a.cs#L10", "suggested_fix": "Rename it.",
              "claude_md_link": " https://github.com/o/r/blob/c/CLAUDE.md#L3-L5 "},
             {"description": "Null deref.", "link": "a.cs#L20", "suggested_fix": ""}]'
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "$(jq -cn --argjson i "$issues" '{status: "ok", issues: $i}')")" "$(_cv_pans 2)")
    _cv_ok "$out" "normalised fields" || return 0
    f=$(_ah_cog "$out" | jq -c '.findings[0]')
    assert_equals '{"file":"a.cs","line":10,"severity":"Important","confidence":90,"description":"Breaks the rule.","suggested_fix":"Rename it.","reference":"https://github.com/o/r/blob/c/CLAUDE.md#L3-L5"}' \
        "$f" "normalise: Important, confidence 90, CLAUDE.md link in reference"
    assert_equals false "$(_ah_cog "$out" | jq '.findings[1] | has("reference")')" "normalise: a bug carries no reference"
    assert_equals 2 "$(echo "$out" | jq '[.bundle.log.findings[] | select(.domain == "anthropic" and .tier == "consensus")] | length')" \
        "normalise: anthropic findings take the normal panel vote"
}

test_anthropic_skipped_and_failed_statuses() {
    local raw out want reason
    while IFS='|' read -r raw want reason; do
        out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "$raw")" "$(_cv_pans 0)")
        _cv_ok "$out" "status $want" || continue
        assert_equals "$want" "$(_ah_cog "$out" | jq -r '.status')" "status: $raw → $want"
        assert_equals 0 "$(_ah_cog "$out" | jq '.findings | length')" "status: $raw carries no findings"
        assert_equals "$reason" "$(_ah_cog "$out" | jq -r '.statusReason')" "status: $raw keeps its reason"
        assert_matches '^dispatch: 9/10 specialists ok$' "$(echo "$out" | jq -r '.logs[] | select(startswith("dispatch:"))')" \
            "status: $want counts as not ok and the review continues"
    done <<'EOF'
{"status": "skipped", "statusReason": "plugin absent", "issues": [{"description": "d", "link": "a.cs#L1", "suggested_fix": ""}]}|skipped|plugin absent
{"status": "failed", "statusReason": "agent errored", "issues": []}|failed|agent errored
null|failed|subagent returned null
{"status": "ok"}|failed|anthropic adapter returned a malformed result
{"status": "weird", "issues": []}|failed|anthropic adapter returned a malformed result
EOF
}

test_anthropic_reviewer_agent_contract() {
    local f
    f="$(_ah_cr_dir)/agents/anthropic-reviewer.md"
    assert_file_exists "plugins/code-review-suite/agents/anthropic-reviewer.md" "anthropic-reviewer agent exists"
    assert_matches '^name: anthropic-reviewer$' "$(grep '^name:' "$f")" "anthropic-reviewer: name matches the file"
    assert_matches '^effort: high$' "$(grep '^effort:' "$f")" "anthropic-reviewer: fixed high effort"
    assert_matches '^tools: (.*[ ,])?Agent(,|$)' "$(grep '^tools:' "$f")" "anthropic-reviewer: may launch the plugin's subagents"
    assert_not_matches '[ ,](Edit|Write)(,|$)' "$(grep '^tools:' "$f")" "anthropic-reviewer: no Edit or Write"
    assert_matches 'claude-plugins-official/plugins/code-review/commands/code-review\.md' "$(cat "$f")" \
        "anthropic-reviewer: follows the official plugin's command file"
}

test_anthropic_flag_threaded_in_both_hosts() {
    local cr f
    cr=$(_ah_cr_dir)
    for f in "$cr/skills/review-gh-pr/SKILL.md" "$cr/commands/pre-review.md"; do
        assert_matches 'anthropicSpecialist: \$ANTHROPIC_SPECIALIST' "$(cat "$f")" \
            "hybrid flag threaded in $(basename "$f")"
        assert_matches 'review\.anthropic_specialist' "$(cat "$f")" "hybrid flag resolution documented in $(basename "$f")"
    done
}

test_review_hosts_lead_with_panel_review() {
    local cr f
    cr=$(_ah_cr_dir)
    for f in "$cr/skills/review-gh-pr/SKILL.md" "$cr/commands/pre-review.md"; do
        assert_matches '^description: Multi-agent panel review' "$(grep '^description:' "$f")" \
            "$(basename "$f") description leads with its distinguishing use"
    done
}
