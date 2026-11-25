#!/usr/bin/env bash
# Tests for the review eval suite under evals/: fixtures are well formed, cases render for every
# arm with limits that let a review finish, a rendered scaffold builds the intended two-commit
# repo, and aggregate.py reaches each outcome of the decision rule on synthetic results.

_ev_tools() {
    echo "$REPO_ROOT/evals/tools"
}

test_evals_fixtures_well_formed() {
    local out
    out=$(python3 -I "$REPO_ROOT/tests/lib/_evals_check.py" fixtures 2>&1)
    assert_equals "" "$out" "every eval fixture is well formed"
}

test_evals_vendored_command_pinned() {
    local sum
    sum=$(shasum -a 256 "$REPO_ROOT/evals/vendor/anthropic-code-review/code-review.md")
    assert_equals "3f02ea6eed996590348264777b2e324859a6e2c0c5f7dd298617ea21deb3b1b2" "${sum%% *}" \
        "the vendored code-review command matches its pin"
    assert_file_exists "evals/vendor/anthropic-code-review/LICENSE" "the vendored command ships with its licence"
}

test_evals_cases_render_for_every_arm() {
    local tmp out count fixtures
    tmp=$(mktemp -d)
    python3 -I "$(_ev_tools)/build_cases.py" --out "$tmp/cases" > /dev/null
    count=$(find "$tmp/cases" -name case.yaml | wc -l | tr -d ' ')
    fixtures=$(find "$REPO_ROOT/evals/fixtures" -name fixture.json | wc -l | tr -d ' ')
    assert_equals "$((fixtures * 3))" "$count" "build_cases renders one case per fixture and arm"
    out=$(python3 -I "$REPO_ROOT/tests/lib/_evals_check.py" cases "$tmp/cases" 2>&1)
    assert_equals "" "$out" "every rendered case is well formed"
    rm -rf "$tmp"
}

test_evals_scaffold_builds_reviewable_repo() {
    local tmp work names toml_status plugin_sum
    tmp=$(mktemp -d)
    python3 -I "$(_ev_tools)/build_cases.py" --fixture silentfail-hit --arm hybrid --out "$tmp/cases" > /dev/null
    mkdir -p "$tmp/work" "$tmp/home"
    work="$tmp/work"
    (cd "$work" && HOME="$tmp/home" bash "$tmp/cases/silentfail-hit-hybrid/fixture.sh")
    assert_equals "feature/silentfail-hit" "$(git -C "$work" branch --show-current)" "the change is on a feature branch"
    names=$(git -C "$work" diff --name-only main..HEAD)
    assert_equals "lib/http_client.py" "$names" "main..HEAD holds exactly the planted change"
    assert_not_matches "silent" "$(cat "$work/README.md")" "the base README does not name the planted defect"
    assert_matches "fetching user profiles" "$(git -C "$work" log -1 --format=%b)" \
        "the head commit body carries the intent"
    toml_status=$(git -C "$work" status --porcelain --ignored -- .claude)
    assert_equals "!! .claude/" "$toml_status" "the hybrid config is ignored, so it is not in the diff"
    plugin_sum=$(shasum -a 256 \
        "$tmp/home/.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review.md")
    assert_equals "3f02ea6eed996590348264777b2e324859a6e2c0c5f7dd298617ea21deb3b1b2" "${plugin_sum%% *}" \
        "the hybrid scaffold places the pinned command where review-core reads it"
    rm -rf "$tmp"
}

test_evals_aggregate_reaches_each_outcome() {
    local tmp scenario expected out
    tmp=$(mktemp -d)
    for pair in "same:KEEP" "hybrid:HYBRID" "switch:SWITCH candidate"; do
        scenario="${pair%%:*}"
        expected="${pair#*:}"
        python3 -I "$REPO_ROOT/tests/lib/_evals_fake_results.py" "$scenario" "$tmp/$scenario.json" > /dev/null
        out=$(python3 -I "$(_ev_tools)/aggregate.py" "$tmp/$scenario.json" 2>&1)
        assert_matches "\*\*Decision: $expected" "$out" "aggregate decides $expected on the $scenario scenario"
    done
    rm -rf "$tmp"
}

test_evals_aggregate_drops_invalid_pairs() {
    local tmp first out
    tmp=$(mktemp -d)
    first=$(python3 -I "$REPO_ROOT/tests/lib/_evals_fake_results.py" invalid "$tmp/invalid.json")
    out=$(python3 -I "$(_ev_tools)/aggregate.py" "$tmp/invalid.json" 2>&1)
    assert_matches "$first-native: 1 of 1 runs invalid" "$out" "aggregate lists the invalid run"
    assert_matches "invalid in some arm\): $first" "$out" \
        "aggregate drops that PR from every arm's comparison"
    assert_matches "Decision set \(11 PRs\)" "$out" "the comparison pairs only the PRs valid in every arm"
    rm -rf "$tmp"
}
