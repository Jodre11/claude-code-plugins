#!/usr/bin/env bash
# Whitespace-aware significant-deletion detection — fixture-based tests.
#
# The pipeline's Phase 0.7.6 and Step 2.7 use the rule:
#   "Any single hunk in `git diff -w` output with 10+ contiguous deleted lines."
#
# These tests bake the same rule into a small awk helper and exercise it against
# pre-canned fixtures so the policy is verifiable in isolation. The fixtures live
# under tests/fixtures/deletion-detection/.

# _max_contiguous_deletions <diff-file>
# Echoes the largest contiguous run of `-` lines (excluding `---` file headers)
# in the supplied diff. Mirrors the algorithm that the orchestrator's prose
# specifies for the Phase 0.7.6 / Step 2.7 deletion scan.
_max_contiguous_deletions() {
    local diff_file="$1"
    awk '
        BEGIN { run = 0; max = 0 }
        /^---/ { run = 0; next }
        /^-/ { run++; if (run > max) max = run; next }
        { run = 0 }
        END { print max }
    ' "$diff_file"
}

# _max_contiguous_deletions_w <diff-file>
# Same as _max_contiguous_deletions but applied to the `-w`-stripped view of the
# diff. The fixtures are pre-canned static diffs (not derived from a working
# tree), so we simulate `git diff -w` by stripping every `-`/`+` pair whose
# whitespace-collapsed bodies are equal. For the canned fixtures this is
# equivalent to running `git diff -w` on the same source.
_max_contiguous_deletions_w() {
    local diff_file="$1"
    awk '
        # Pass 1: emit a sanitised diff where lines that pair as whitespace-only
        # changes are dropped. Specifically:
        #   - Buffer every `-` line.
        #   - On the next `+` line, compare whitespace-stripped bodies.
        #     If equal, discard both. Otherwise emit them in original order.
        #   - Anything else flushes the buffer.
        function flush() {
            for (i = 1; i <= n_buf; i++) print buf[i]
            n_buf = 0
        }
        function strip_ws(s) {
            gsub(/[[:space:]]/, "", s)
            return s
        }
        BEGIN { n_buf = 0 }
        /^---/ || /^\+\+\+/ { flush(); print; next }
        /^@@/ { flush(); print; next }
        /^-/ { n_buf++; buf[n_buf] = $0; next }
        /^\+/ {
            line = $0
            consumed = 0
            if (n_buf > 0) {
                neg_body = substr(buf[1], 2)
                pos_body = substr(line, 2)
                if (strip_ws(neg_body) == strip_ws(pos_body)) {
                    # Drop the paired `-` line and skip emitting this `+` line.
                    for (i = 1; i < n_buf; i++) buf[i] = buf[i + 1]
                    n_buf--
                    consumed = 1
                }
            }
            if (!consumed) {
                flush()
                print line
            }
            next
        }
        { flush(); print }
        END { flush() }
    ' "$diff_file" | awk '
        BEGIN { run = 0; max = 0 }
        /^---/ { run = 0; next }
        /^-/ { run++; if (run > max) max = run; next }
        { run = 0 }
        END { print max }
    '
}

test_deletion_detection_real_block_triggers() {
    # Plan prose calls these "12-line" fixtures, but the canned diffs supplied
    # in the plan contain 13 contiguous `-` lines (header + opening brace + 10
    # fields + closing brace). Both are well above the >= 10 threshold, so the
    # rule semantics are unchanged.
    local fixtures="$REPO_ROOT/tests/fixtures/deletion-detection"
    local diff_file="$fixtures/real-deletion.diff"

    if [[ ! -f "$diff_file" ]]; then
        fail "deletion-detection: real-deletion fixture present" "missing: $diff_file"
        return
    fi

    local raw run_w
    raw=$(_max_contiguous_deletions "$diff_file")
    run_w=$(_max_contiguous_deletions_w "$diff_file")

    # Both measurements should report a 13-line run for a genuine block deletion.
    assert_equals "13" "$raw" \
        "real-deletion fixture: raw scan reports 13 contiguous '-' lines"
    assert_equals "13" "$run_w" \
        "real-deletion fixture: -w scan reports 13 contiguous '-' lines"

    if (( run_w >= 10 )); then
        pass "real-deletion fixture: -w scan trips the 10+ threshold (\$SIGNIFICANT_DELETIONS = true)"
    else
        fail "real-deletion fixture: -w scan trips the 10+ threshold (\$SIGNIFICANT_DELETIONS = true)" \
            "expected run_w >= 10, got $run_w"
    fi
}

test_deletion_detection_reindent_does_not_trigger() {
    # Plan prose calls these "12-line" fixtures, but the canned diffs supplied
    # in the plan contain 13 contiguous `-` lines (header + opening brace + 10
    # fields + closing brace). Both are well above the >= 10 threshold, so the
    # rule semantics are unchanged.
    local fixtures="$REPO_ROOT/tests/fixtures/deletion-detection"
    local diff_file="$fixtures/reindent.diff"

    if [[ ! -f "$diff_file" ]]; then
        fail "deletion-detection: reindent fixture present" "missing: $diff_file"
        return
    fi

    local raw run_w
    raw=$(_max_contiguous_deletions "$diff_file")
    run_w=$(_max_contiguous_deletions_w "$diff_file")

    # Raw scan would falsely flag 13 contiguous `-` lines; the -w view collapses
    # the whitespace-only re-indent and reports zero deletions.
    assert_equals "13" "$raw" \
        "reindent fixture: raw scan reports 13 contiguous '-' lines (the bug)"
    assert_equals "0" "$run_w" \
        "reindent fixture: -w scan collapses whitespace-only deletions (the fix)"

    if (( run_w < 10 )); then
        pass "reindent fixture: -w scan does NOT trip the 10+ threshold (\$SIGNIFICANT_DELETIONS stays false)"
    else
        fail "reindent fixture: -w scan does NOT trip the 10+ threshold (\$SIGNIFICANT_DELETIONS stays false)" \
            "expected run_w < 10, got $run_w"
    fi
}
