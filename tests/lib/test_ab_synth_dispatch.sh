#!/usr/bin/env bash
# Locks the additive specialist_findings / review_mode reconstruction path in
# tests/ab/lib/agent_dispatch.sh. Absent keys => byte-identical passthrough;
# present keys => the synthesiser-shaped block is appended.

_synthdisp_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

test_ab_synth_dispatch_absent_keys_passthrough() {
    local root
    root=$(_synthdisp_repo_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/agent_dispatch.sh" ]]; then
        skip "synth dispatch passthrough" "agent_dispatch.sh not found"
        return
    fi

    local tmp out fixture
    tmp=$(mktemp -d)
    fixture="$tmp/fix"
    mkdir -p "$fixture/diff"
    cat > "$fixture/source.yaml" <<'YAML'
base_sha: main
head_sha: 0000000000000000000000000000000000000000
path_scope: ""
empty_tree_mode: false
intent_ledger: |
  ## Intent ledger
  - probe
YAML
    printf 'Changed lines:\n  bad.py: 1\n' > "$fixture/diff/changed-lines.txt"

    # shellcheck source=/dev/null
    REPO_ROOT="$root" source "$root/tests/ab/lib/agent_dispatch.sh"
    out="$tmp/out.txt"
    agent_dispatch_build_user_message "$fixture" "$out"

    if grep -qF 'Specialist findings' "$out"; then
        fail "synth dispatch passthrough: no bundle when key absent" \
            "unexpected 'Specialist findings' block in $out"
    else
        pass "synth dispatch passthrough: no bundle when key absent"
    fi
    if grep -qF 'Review mode:' "$out"; then
        fail "synth dispatch passthrough: no review-mode line when key absent" \
            "unexpected 'Review mode:' line in $out"
    else
        pass "synth dispatch passthrough: no review-mode line when key absent"
    fi
    rm -rf "$tmp"
}

test_ab_synth_dispatch_present_keys_emit_block() {
    local root
    root=$(_synthdisp_repo_root)
    if [[ -z "$root" || ! -f "$root/tests/ab/lib/agent_dispatch.sh" ]]; then
        skip "synth dispatch emit" "agent_dispatch.sh not found"
        return
    fi

    local tmp out fixture
    tmp=$(mktemp -d)
    fixture="$tmp/fix"
    mkdir -p "$fixture/diff"
    cat > "$fixture/source.yaml" <<'YAML'
base_sha: main
head_sha: 0000000000000000000000000000000000000000
path_scope: ""
empty_tree_mode: false
review_mode: pr
intent_ledger: |
  ## Intent ledger
  - probe
specialist_findings: |
  ### correctness-reviewer
  #### Finding — lying comment
  - **File:** lib/cache.py:42
  - **Severity:** Important
  - **Confidence:** 90
YAML
    printf 'Changed lines:\n  lib/cache.py: 42\n' > "$fixture/diff/changed-lines.txt"

    # shellcheck source=/dev/null
    REPO_ROOT="$root" source "$root/tests/ab/lib/agent_dispatch.sh"
    out="$tmp/out.txt"
    agent_dispatch_build_user_message "$fixture" "$out"

    local needle
    for needle in 'Review mode: pr' 'Specialist findings' 'correctness-reviewer' 'lib/cache.py:42'; do
        if grep -qF "$needle" "$out"; then
            pass "synth dispatch emit: contains '$needle'"
        else
            fail "synth dispatch emit: contains '$needle'" "not found in $out"
        fi
    done
    rm -rf "$tmp"
}
