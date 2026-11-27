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
    pairs+=("agents/anthropic-reviewer.md includes/specialist-context.md")
    # Every agent that judges or writes about a change, and the orchestrator's pipeline, must
    # carry the rule-sources block, or the reviewer's personal instructions leak into findings.
    for agent in api-contract alignment archaeology consistency correctness efficiency latent-hazard reuse \
        security style test-adequacy test-quality ui; do
        pairs+=("agents/$agent-reviewer.md includes/rule-sources.md")
    done
    pairs+=(
        "agents/code-analysis.md includes/rule-sources.md"
        "agents/anthropic-reviewer.md includes/rule-sources.md"
        "agents/panel-reviewer.md includes/rule-sources.md"
        "agents/panel-writer.md includes/rule-sources.md"
        "agents/comment-editor.md includes/rule-sources.md"
        "agents/comment-editor.md includes/comment-voice.md"
        "agents/native-reviewer.md includes/rule-sources.md"
        "includes/review-pipeline.md includes/rule-sources.md"
    )
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

_ri_js_gb() {
    echo "// BEGIN GENERATED from $1 as $2: edit that file, then run scripts/render-includes.py"
}

_ri_js_ge() {
    echo "// END GENERATED from $1"
}

# The panel retired with the thin pipeline, so review-core embeds no concern brief.
test_render_includes_review_core_embeds_no_brief() {
    local wf="$REPO_ROOT/plugins/code-review-suite/workflows/review-core.js"
    if grep -qF -- 'PANEL_BRIEF' "$wf"; then
        fail "review-core.js no longer embeds the panel concern brief" "PANEL_BRIEF still present"
    else
        pass "review-core.js no longer embeds the panel concern brief"
    fi
}

test_render_includes_embeds_whole_file_in_js() {
    local tmp out rc=0
    tmp=$(mktemp -d)
    mkdir -p "$tmp/plugins/p/includes" "$tmp/plugins/p/workflows"
    printf '# Brief\n\nsay "hi" \\ there\n' > "$tmp/plugins/p/includes/brief.md"
    printf 'const a = 1\n%s\nconst STALE = []\n%s\nrun(BRIEF)\n' \
        "$(_ri_js_gb includes/brief.md BRIEF)" "$(_ri_js_ge includes/brief.md)" > "$tmp/plugins/p/workflows/w.js"
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "1" "$rc" "--check exits 1 on a stale JS embed"
    python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" > /dev/null
    # Quoted heredoc: every escape below appears exactly as it must in the rendered file.
    cat > "$tmp/expected.js" <<'EOF_EXPECTED'
const a = 1
// BEGIN GENERATED from includes/brief.md as BRIEF: edit that file, then run scripts/render-includes.py
const BRIEF = [
    "# Brief",
    "",
    "say \"hi\" \\ there",
    "",
].join('\n')
// END GENERATED from includes/brief.md
run(BRIEF)
EOF_EXPECTED
    assert_equals "$(cat "$tmp/expected.js")" "$(cat "$tmp/plugins/p/workflows/w.js")" \
        "render embeds the whole file as a string joined from JSON-escaped lines"
    out=$(WF="$tmp/plugins/p/workflows/w.js" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8").replace("run(BRIEF)", "return BRIEF");
        process.stdout.write(new Function(src)() === fs.readFileSync(process.env.WF.replace(
            "workflows/w.js", "includes/brief.md"), "utf8") ? "SAME" : "DIFFERENT");
    ' 2>&1)
    assert_equals "SAME" "$out" "the embedded constant evaluates to the source text byte for byte"
    rc=0
    python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check > /dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "--check passes after rendering the JS embed"
    rm -rf "$tmp"
}

test_render_includes_rejects_bad_js_markers() {
    local tmp out rc
    tmp=$(mktemp -d)
    mkdir -p "$tmp/plugins/p/includes" "$tmp/plugins/p/workflows"
    printf 'x\n' > "$tmp/plugins/p/includes/brief.md"
    printf 'x\n' > "$tmp/plugins/p/includes/data.txt"

    printf '// BEGIN GENERATED from includes/brief.md\n' > "$tmp/plugins/p/workflows/w.js"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "a JS marker without a constant name exits 2"
    assert_matches "malformed or unmatched marker" "$out" "a malformed JS marker is reported"

    printf '%s\n' "$(_ri_js_gb includes/brief.md BRIEF)" > "$tmp/plugins/p/workflows/w.js"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "an unmatched JS BEGIN exits 2"
    assert_matches "no matching" "$out" "an unmatched JS BEGIN names the missing END"

    printf '%s\n%s\n' "$(_ri_js_gb includes/data.txt DATA)" "$(_ri_js_ge includes/data.txt)" \
        > "$tmp/plugins/p/workflows/w.js"
    rc=0
    out=$(python3 "$(_ri_script)" --plugins-dir "$tmp/plugins" --check 2>&1) || rc=$?
    assert_equals "2" "$rc" "a non-markdown embed source exits 2"
    assert_matches "must be markdown" "$out" "a non-markdown embed source is reported"
    rm -rf "$tmp"
}
