#!/usr/bin/env bash
# Panel wiring + drift tests: concern-brief↔CORE sync, host call-site threading.

_pw_cr_dir() {
    echo "$REPO_ROOT/plugins/code-review-suite"
}

# Both call-sites must thread the panel size into the workflow invocation.
test_panel_params_threaded_in_both_call_sites() {
    local cr skill prerev
    cr=$(_pw_cr_dir)
    skill="$cr/skills/review-gh-pr/SKILL.md"
    prerev="$cr/commands/pre-review.md"
    for f in "$skill" "$prerev"; do
        if grep -q "panelSize: \$PANEL_SIZE" "$f"; then
            pass "panel params threaded in $(basename "$(dirname "$f")")/$(basename "$f")"
        else
            fail "panel params threaded in $(basename "$f")" "missing panelSize"
        fi
    done
}

# The concern brief is embedded in review-core, so no host reads it from the plugin cache
# (unreadable in an eval child) or copies it into the args, and review-core reads no such arg.
test_panel_brief_not_threaded_through_args() {
    local cr f
    cr=$(_pw_cr_dir)
    for f in "$cr/skills/review-gh-pr/SKILL.md" "$cr/commands/pre-review.md" \
        "$cr/includes/review-pipeline.md" "$cr/workflows/review-core.js"; do
        if grep -qE 'panelBrief|\$PANEL_BRIEF|\$PLUGIN_ROOT' "$f"; then
            fail "no brief arg or plugin-root read in $(basename "$f")" \
                "$(grep -nE 'panelBrief|\$PANEL_BRIEF|\$PLUGIN_ROOT' "$f" | head -3)"
        else
            pass "no brief arg or plugin-root read in $(basename "$f")"
        fi
    done
}

# Every panelist prompt must open with the embedded brief, verbatim.
test_panel_prompt_carries_embedded_brief() {
    local cr out brief_head
    cr=$(_pw_cr_dir)
    brief_head=$(head -1 "$cr/includes/panel-concern-brief.md")
    out=$(WF="$cr/workflows/review-core.js" node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.env.WF, "utf8").replace(/^export\s+const\s+meta/m, "const meta");
        const brief = fs.readFileSync(process.env.WF.replace(/workflows\/review-core\.js$/,
            "includes/panel-concern-brief.md"), "utf8");
        const finding = { file: "a.cs", line: 3, severity: "Important", confidence: 90,
            description: "d", suggested_fix: "f" };
        const agent = async (prompt, opts) => {
            const label = (opts && opts.label) || "";
            if (label.startsWith("panel-") && label !== "panel-writer") {
                const at = prompt.indexOf(brief);
                process.stdout.write(at === -1 ? "BRIEF_ABSENT" : "BRIEF_AT_" + prompt.slice(0, at).length);
                process.exit(0);
            }
            return { status: "ok", findings: label === "correctness" ? [finding] : [] };
        };
        const parallel = (thunks) => Promise.all(thunks.map(t => t()));
        const noop = () => {};
        const args = JSON.stringify({ agentPrompt: "x", flags: {}, route: "full", selfReReview: false,
            reviewMode: "pr", base: "main", headSha: "a".repeat(40), emptyTreeMode: false, pathScope: "",
            tempDir: "/tmp/claude-test/x", intentLedger: "", panelSize: 3,
            changedLinesBlock: "Changed lines:\na.cs: 1-40\n" });
        const fn = new Function("agent", "parallel", "pipeline", "phase", "log", "args", "workflow",
            "return (async()=>{" + src + "\n})()");
        fn(agent, parallel, async () => [], noop, noop, args, async () => null)
            .then(() => process.stdout.write("NO_PANELIST"))
            .catch(e => process.stdout.write("THREW: " + e.message));
    ' 2>&1)
    assert_matches "^BRIEF_AT_" "$out" "panelist prompt contains the whole embedded brief (${brief_head})"
}

# Classic orchestration is retired: no host may still pass an orchestration mode, and
# review-core must not read one. A stale arg would be silently ignored, so a test that
# still passed it would run panel and pass while claiming to exercise classic.
test_panel_orchestration_mode_arg_absent() {
    local cr f
    cr=$(_pw_cr_dir)
    for f in "$cr/skills/review-gh-pr/SKILL.md" "$cr/commands/pre-review.md" \
        "$cr/includes/review-pipeline.md" "$cr/workflows/review-core.js"; do
        if grep -qE 'orchestrationMode|ORCHESTRATION_MODE' "$f"; then
            fail "no orchestration-mode arg in $(basename "$f")" \
                "$(grep -nE 'orchestrationMode|ORCHESTRATION_MODE' "$f" | head -3)"
        else
            pass "no orchestration-mode arg in $(basename "$f")"
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

# review_mode is retired: both call-sites must tell the user to remove it rather than
# resolve it.
test_panel_review_mode_retired_notice() {
    local cr skill prerev
    cr=$(_pw_cr_dir)
    skill="$cr/skills/review-gh-pr/SKILL.md"
    prerev="$cr/commands/pre-review.md"
    for f in "$skill" "$prerev"; do
        if grep -q "orchestration.review_mode is retired and ignored" "$f"; then
            pass "review_mode retired notice in $(basename "$f")"
        else
            fail "review_mode retired notice in $(basename "$f")" "no retired-and-ignored notice"
        fi
        if grep -qiE "review_mode.*(= ?(panel|classic)|built-in default)" "$f"; then
            fail "review_mode not resolved in $(basename "$f")" \
                "$(grep -niE 'review_mode.*(= ?(panel|classic)|built-in default)' "$f" | head -3)"
        else
            pass "review_mode not resolved in $(basename "$f")"
        fi
    done
}

# The concern-brief's domain list must match the CORE array in review-core.js.
# Directional check (brief tracks CORE), not byte-parity. The brief lists domains in
# an HTML comment marker line: <!-- CORE-DOMAINS: security, correctness, ... -->
test_panel_concern_brief_domains_match_core() {
    local cr brief mjs core_line brief_line
    cr=$(_pw_cr_dir)
    brief="$cr/includes/panel-concern-brief.md"
    mjs="$cr/workflows/review-core.js"
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
    assert_equals "$core_line" "$brief_line" "concern-brief domain list tracks review-core.js CORE"
}
