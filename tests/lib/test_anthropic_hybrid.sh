#!/usr/bin/env bash
# Hybrid-arm tests: review-core's orchestration of Anthropic's code-review plugin pipeline
# (steps 2-6, one restricted anthropic-reviewer agent per plugin agent), the link-to-anchor
# parser, the fixed severity and confidence, skipped/failed statuses, the log meta flag, the
# agent contract and the host wiring. review-core.js runs end to end through
# tests/lib/_cv_runner.js (helpers _cv_run, _cv_pans and _cv_ok come from test_comment_voice.sh).

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

# Fixture results for every pipeline agent. $1 the issues step 4's agent 1 returns (agents 2-4
# return none), $2 the validated verdict every validator returns (true|false). Callers adjust
# individual labels with jq.
_ah_specs() {
    jq -cn --argjson i "${1:-[]}" --argjson ok "${2:-true}" '
        {"anthropic-claude-md": {plugin_found: true, claude_md_files: ["CLAUDE.md"]},
         "anthropic-summary": {plugin_found: true, summary: "Adds a thing."},
         "anthropic-review-1": {plugin_found: true, issues: $i},
         "anthropic-review-2": {plugin_found: true, issues: []},
         "anthropic-review-3": {plugin_found: true, issues: []},
         "anthropic-review-4": {plugin_found: true, issues: []}}
        + ([range($i | length)] | map({key: "anthropic-validate-1-\(.)",
             value: {plugin_found: true, validated: $ok, rationale: "r"}}) | from_entries)'
}

# One issue object. $1 link, $2 kind (default bug).
_ah_issue() {
    jq -cn --arg l "$1" --arg k "${2:-bug}" '{description: "d", kind: $k, link: $l, suggested_fix: ""}'
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
        assert_equals 0 "$(echo "$out" | jq '[.dispatches[] | select(.label | startswith("anthropic"))] | length')" \
            "hybrid arm: nothing dispatched when anthropicSpecialist is $flag"
        assert_equals false "$(echo "$out" | jq '.bundle.log.meta.anthropic_specialist')" \
            "hybrid arm: log.meta.anthropic_specialist false when the flag is $flag"
    done
}

test_anthropic_pipeline_shape() {
    local out issues calls
    issues=$(jq -cn --argjson a "$(_ah_issue a.cs#L10 bug)" --argjson b "$(_ah_issue a.cs#L20 claude-md)" '[$a, $b]')
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "$issues")" "$(_cv_pans 0)")
    _cv_ok "$out" "pipeline shape" || return 0
    assert_equals anthropic-claude-md "$(echo "$out" | jq -r '.dispatches[0].label')" \
        "hybrid arm: its first step is dispatched first (slowest-first order)"
    calls=$(echo "$out" | jq -c '[.dispatches[] | select(.label | startswith("anthropic")) | {label, model: .opts.model}] | sort_by(.label)')
    assert_equals '[{"label":"anthropic-claude-md","model":"haiku"},{"label":"anthropic-review-1","model":"sonnet"},{"label":"anthropic-review-2","model":"sonnet"},{"label":"anthropic-review-3","model":"opus"},{"label":"anthropic-review-4","model":"opus"},{"label":"anthropic-summary","model":"sonnet"},{"label":"anthropic-validate-1-0","model":"opus"},{"label":"anthropic-validate-1-1","model":"sonnet"}]' \
        "$calls" "hybrid arm: steps 2-5 with the plugin's models (opus validates bugs, sonnet CLAUDE.md)"
    assert_equals '["code-review-suite:anthropic-reviewer"]' \
        "$(echo "$out" | jq -c '[.dispatches[] | select(.label | startswith("anthropic")) | .opts.agentType] | unique')" \
        "hybrid arm: every step runs on the restricted anthropic-reviewer type"
    assert_equals '[{"effort":"high","stallMs":600000}]' \
        "$(echo "$out" | jq -c '[.dispatches[] | select(.label | startswith("anthropic")) | {effort: .opts.effort, stallMs: .opts.stallMs}] | unique')" \
        "hybrid arm: fixed high effort and a 600s stall budget on every step"
    assert_equals true "$(echo "$out" | jq '.bundle.log.meta.anthropic_specialist')" \
        "hybrid arm: log.meta.anthropic_specialist true when on"
    assert_matches 'Plugin command file: ~/\.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review\.md' \
        "$(echo "$out" | jq -r '.dispatches[] | select(.label == "anthropic-review-3") | .prompt')" \
        "hybrid arm: each step is pointed at the official plugin's command file"
}

test_anthropic_ignored_on_lightweight_route() {
    local out
    out=$(_cv_run "$(_ah_args true lightweight)" '{}' '[]')
    _cv_ok "$out" "lightweight" || return 0
    assert_equals 0 "$(echo "$out" | jq '[.dispatches[] | select(.label | startswith("anthropic"))] | length')" \
        "hybrid arm: lightweight route does not run the pipeline"
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
        issues=$(jq -c --argjson x "$(_ah_issue "${row%%|*}")" '. + [$x]' <<<"$issues")
    done
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "$issues")" "$(_cv_pans 0)")
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
    issues='[{"description": "Breaks the rule.", "kind": "claude-md", "link": "a.cs#L10", "suggested_fix": "Rename it.",
              "claude_md_link": " https://github.com/o/r/blob/c/CLAUDE.md#L3-L5 "},
             {"description": "Null deref.", "kind": "bug", "link": "a.cs#L20", "suggested_fix": ""}]'
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "$issues")" "$(_cv_pans 2)")
    _cv_ok "$out" "normalised fields" || return 0
    f=$(_ah_cog "$out" | jq -c '.findings[0]')
    assert_equals '{"file":"a.cs","line":10,"severity":"Important","confidence":90,"description":"Breaks the rule.","suggested_fix":"Rename it.","reference":"https://github.com/o/r/blob/c/CLAUDE.md#L3-L5"}' \
        "$f" "normalise: Important, confidence 90, CLAUDE.md link in reference"
    assert_equals false "$(_ah_cog "$out" | jq '.findings[1] | has("reference")')" "normalise: a bug carries no reference"
    assert_equals 2 "$(echo "$out" | jq '[.bundle.log.findings[] | select(.domain == "anthropic" and .tier == "consensus")] | length')" \
        "normalise: anthropic findings take the normal panel vote"
}

test_anthropic_step6_keeps_only_validated() {
    local issues specs out
    issues=$(jq -cn --argjson a "$(_ah_issue a.cs#L10)" --argjson b "$(_ah_issue a.cs#L20)" '[$a, $b]')
    specs=$(_ah_specs "$issues" | jq -c '.["anthropic-validate-1-1"].validated = false')
    out=$(_cv_run "$(_ah_args true)" "$specs" "$(_cv_pans 0)")
    _cv_ok "$out" "step 6" || return 0
    assert_equals ok "$(_ah_cog "$out" | jq -r '.status')" "step 6: a rejected issue is a verdict, not a failure"
    assert_equals '[10]' "$(_ah_cog "$out" | jq -c '[.findings[].line]')" "step 6: only the validated issue survives"
}

test_anthropic_skipped_and_failed_statuses() {
    local edit want reason out
    while IFS='|' read -r edit want reason; do
        out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "[$(_ah_issue a.cs#L1)]" | jq -c "$edit")" "$(_cv_pans 0)")
        _cv_ok "$out" "status $want ($edit)" || continue
        assert_equals "$want" "$(_ah_cog "$out" | jq -r '.status')" "status: $edit → $want"
        assert_equals 0 "$(_ah_cog "$out" | jq '.findings | length')" "status: $edit carries no findings"
        assert_equals "$reason" "$(_ah_cog "$out" | jq -r '.statusReason')" "status: $edit keeps its reason"
        assert_matches '^dispatch: 9/10 specialists ok$' "$(echo "$out" | jq -r '.logs[] | select(startswith("dispatch:"))')" \
            "status: $want counts as not ok and the review continues"
    done <<'EOF'
.["anthropic-claude-md"].plugin_found = false|skipped|official code-review plugin not found in the marketplace clone
.["anthropic-claude-md"] = null|failed|step 2 (CLAUDE.md discovery) did not return
.["anthropic-summary"] = null|failed|step 3 (summary) did not return
.["anthropic-review-3"] = null|failed|a step 4 reviewer or step 5 validator did not return
.["anthropic-review-2"] = {plugin_found: true}|failed|a step 4 reviewer or step 5 validator did not return
.["anthropic-validate-1-0"] = null|failed|a step 4 reviewer or step 5 validator did not return
EOF
    out=$(_cv_run "$(_ah_args true)" "$(_ah_specs "[$(_ah_issue a.cs#L1)]" | jq -c '.["anthropic-claude-md"].plugin_found = false')" "$(_cv_pans 0)")
    assert_equals 0 "$(echo "$out" | jq '[.dispatches[] | select(.label | startswith("anthropic-review"))] | length')" \
        "status: an absent plugin stops the pipeline before step 4"
}

test_anthropic_reviewer_agent_contract() {
    local f
    f="$(_ah_cr_dir)/agents/anthropic-reviewer.md"
    assert_file_exists "plugins/code-review-suite/agents/anthropic-reviewer.md" "anthropic-reviewer agent exists"
    assert_matches '^name: anthropic-reviewer$' "$(grep '^name:' "$f")" \
        "anthropic-reviewer: name matches the file (a *-reviewer, so reviewer-guard covers it)"
    assert_equals 'tools: Read, Grep, Glob, Bash' "$(grep '^tools:' "$f")" \
        "anthropic-reviewer: read-only tools, no Agent, Edit or Write"
    assert_matches 'Plugin command file:' "$(cat "$f")" "anthropic-reviewer: reads the plugin's command file it is pointed at"
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
