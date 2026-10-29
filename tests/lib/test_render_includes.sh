#!/usr/bin/env bash
# Tests for scripts/render-includes.py: the shipped copies are current, every expected
# consumer carries its generated region, and the generator renders, nests and fails as
# designed on a scratch plugin tree.

_ri_script() {
    echo "$REPO_ROOT/scripts/render-includes.py"
}

_RI_SB='<!-- BEGIN SOURCE: copied into BEGIN GENERATED regions; after editing, run scripts/render-includes.py -->'
_RI_SE='<!-- END SOURCE -->'

_ri_gb() {
    echo "<!-- BEGIN GENERATED from $1: edit that file, then run scripts/render-includes.py -->"
}

_ri_ge() {
    echo "<!-- END GENERATED from $1 -->"
}

# A scratch plugin tree: includes/src.md holds a source region; agents/a.md holds a stale copy.
_ri_fixture() {
    local root="$1"
    mkdir -p "$root/plugins/p/includes" "$root/plugins/p/agents"
    printf '# Src\n\n%s\nshared line one\nshared line two\n%s\n' "$_RI_SB" "$_RI_SE" \
        > "$root/plugins/p/includes/src.md"
    printf 'intro\n%s\nstale text\n%s\noutro\n' "$(_ri_gb includes/src.md)" "$(_ri_ge includes/src.md)" \
        > "$root/plugins/p/agents/a.md"
}

test_render_includes_shipped_copies_current() {
    local out rc=0
    out=$(python3 "$(_ri_script)" --check 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        pass "every generated region matches its source"
    else
        fail "every generated region matches its source" "$out"
    fi
}

test_render_includes_expected_consumers_present() {
    local cr="$REPO_ROOT/plugins/code-review-suite" file src
    local -a pairs=(
        "skills/review-gh-pr/SKILL.md includes/review-pipeline.md"
        "commands/pre-review.md includes/review-pipeline.md"
        "includes/review-pipeline.md includes/intent-ledger.md"
        "includes/review-pipeline.md includes/ci-status-gate.md"
    )
    local agent
    for agent in api-contract archaeology consistency correctness efficiency latent-hazard reuse security \
        style test-adequacy test-quality ui; do
        pairs+=("agents/$agent-reviewer.md includes/specialist-context.md")
    done
    pairs+=("agents/code-analysis.md includes/specialist-context.md")
    local pair
    for pair in "${pairs[@]}"; do
        file="${pair%% *}"
        src="${pair##* }"
        if grep -qF -- "$(_ri_gb "$src")" "$cr/$file"; then
            pass "$file carries the generated region from $src"
        else
            fail "$file carries the generated region from $src" "BEGIN GENERATED marker missing"
        fi
    done
}

test_render_includes_rewrites_stale_region() {
    local tmp out rc=0
    tmp=$(mktemp -d)
    _ri_fixture "$tmp"
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "1" "$rc" "--check exits 1 on a stale region"
    assert_matches "-stale text" "$out" "--check prints the stale line"
    assert_equals "stale text" "$(sed -n 3p "$tmp/plugins/p/agents/a.md")" "--check writes nothing"
    python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" > /dev/null
    assert_equals "$(printf 'intro\n%s\nshared line one\nshared line two\n%s\noutro' \
        "$(_ri_gb includes/src.md)" "$(_ri_ge includes/src.md)")" \
        "$(cat "$tmp/plugins/p/agents/a.md")" "render copies the source region between the markers"
    rc=0
    python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check > /dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "--check passes after rendering"
    rm -rf "$tmp"
}

test_render_includes_renders_nested_source_first() {
    local tmp
    tmp=$(mktemp -d)
    _ri_fixture "$tmp"
    # mid.md is itself a source whose region contains a (stale) copy of src.md.
    printf '%s\nmid before\n%s\nold\n%s\nmid after\n%s\n' "$_RI_SB" "$(_ri_gb includes/src.md)" \
        "$(_ri_ge includes/src.md)" "$_RI_SE" > "$tmp/plugins/p/includes/mid.md"
    printf '%s\n%s\n' "$(_ri_gb includes/mid.md)" "$(_ri_ge includes/mid.md)" > "$tmp/plugins/p/agents/b.md"
    python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" > /dev/null
    assert_matches "shared line two" "$(cat "$tmp/plugins/p/agents/b.md")" "a nested copy reaches the outer consumer"
    assert_not_matches "old" "$(cat "$tmp/plugins/p/agents/b.md")" "the stale nested text never reaches it"
    assert_matches "shared line one" "$(cat "$tmp/plugins/p/includes/mid.md")" "the intermediate source is rendered too"
    rm -rf "$tmp"
}

test_render_includes_rejects_bad_markers() {
    local tmp out rc
    tmp=$(mktemp -d)
    _ri_fixture "$tmp"

    printf '%s\n' "$(_ri_gb includes/src.md)" > "$tmp/plugins/p/agents/a.md"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "an unmatched BEGIN exits 2"
    assert_matches "no matching" "$out" "an unmatched BEGIN names the missing END"

    printf '<!-- BEGIN GENERATED from includes/src.md -->\n' > "$tmp/plugins/p/agents/a.md"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "a malformed marker exits 2"
    assert_matches "malformed or unmatched marker" "$out" "a malformed marker is reported"

    printf '%s\n%s\n' "$(_ri_gb ../../outside.md)" "$(_ri_ge ../../outside.md)" > "$tmp/plugins/p/agents/a.md"
    printf '%s\nx\n%s\n' "$_RI_SB" "$_RI_SE" > "$tmp/outside.md"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "a source outside the plugin exits 2"
    assert_matches "is not a file inside" "$out" "a source outside the plugin is reported"

    printf '%s\n%s\n%s\n' "$_RI_SB" "$(_ri_gb includes/src.md)" "$(_ri_ge includes/src.md)" \
        > "$tmp/plugins/p/agents/a.md"
    printf '%s\n%s\n%s\n%s\n' "$_RI_SB" "$(_ri_gb agents/a.md)" "$(_ri_ge agents/a.md)" "$_RI_SE" \
        > "$tmp/plugins/p/includes/src.md"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "an include cycle exits 2"
    assert_matches "include cycle" "$out" "an include cycle is reported"
    rm -rf "$tmp"
}
