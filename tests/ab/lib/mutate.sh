#!/usr/bin/env bash
# tests/ab/lib/mutate.sh — in-tree mutation primitives + revert trap.
# Sourced by tests/ab/run.sh; mutators also exercised against fixtures by
# tests/lib/test_ab_harness.sh. See full notes below set -euo pipefail.
set -euo pipefail

# The revert trap (mutate_install_revert_trap) is the most failure-sensitive
# part of the harness. A leaked dirty working tree from a half-reverted
# mutation poisons every subsequent run. The trap fires on EXIT, INT, TERM,
# and HUP; on a revert failure it writes a MANUAL_REVERT_REQUIRED marker
# rather than continuing silently.

# The three sync sites that must be mutated in lockstep when stripping the
# ultrathink keyword. Test test_sync_synthesiser_dispatch_uses_ultrathink in
# tests/lib/test_sync_notes.sh enforces that all three start with the keyword
# in production. Strip from all three or none.
_AB_ULTRATHINK_SYNC_SITES=(
    "plugins/code-review-suite/includes/review-pipeline.md"
    "plugins/code-review-suite/skills/review-gh-pr/SKILL.md"
    "plugins/code-review-suite/commands/pre-review.md"
)

# Files mutated during the current run. Populated by the public mutators;
# consumed by the revert trap.
_AB_MUTATED_FILES=()

# Run-directory marker location. Set by run.sh before installing the trap.
# Preserve any value already set in the environment (e.g. when sourced by tests).
_AB_RUN_DIR="${_AB_RUN_DIR:-}"

# Strip the literal `ultrathink\n\n` prefix from the synthesiser dispatch
# prompt in a single file. Matches the substring `prompt: "ultrathink\n\n`
# (the `\n` here are the two literal characters, not real newlines — the
# dispatch template encodes newlines in the JSON-like Agent({...}) prompt
# field). Idempotent: applies a no-op edit if the keyword is already absent.
mutate_strip_ultrathink_keyword() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "mutate_strip_ultrathink_keyword: $file: not a regular file" >&2
        return 1
    fi

    # sed -i differs between BSD (macOS) and GNU. Use the portable two-arg form
    # by writing to a temp file and replacing atomically.
    local tmp
    tmp=$(mktemp)
    sed 's/prompt: "ultrathink\\n\\n/prompt: "/' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Rewrite the `model:` line in YAML frontmatter to a new value. Matches the
# first occurrence of `^model:` from the top of the file (frontmatter only —
# bails after the closing `---`). Used to retarget an agent at sonnet/haiku/etc.
mutate_set_agent_model() {
    local file="$1"
    local new_model="$2"

    if [[ ! -f "$file" ]]; then
        echo "mutate_set_agent_model: $file: not a regular file" >&2
        return 1
    fi
    if [[ -z "$new_model" ]]; then
        echo "mutate_set_agent_model: $file: empty model value" >&2
        return 1
    fi

    # awk-based rewrite: only touch lines before the second '---' (which closes
    # the YAML frontmatter). After that we are in body content and must not
    # rewrite anything that happens to start with 'model:'.
    local tmp
    tmp=$(mktemp)
    awk -v new_model="$new_model" '
        BEGIN { dash_count = 0 }
        /^---$/ { dash_count++ }
        dash_count <= 1 && /^model:[[:space:]]/ { print "model: " new_model; next }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

# Track a path so the revert trap will restore it on exit.
_ab_track_mutation() {
    local file="$1"
    _AB_MUTATED_FILES+=("$file")
}

# Install the revert trap. Must be called from run.sh after _AB_RUN_DIR is set
# but before any mutation is applied. Reverts every tracked file and verifies
# the working tree is clean. On failure it writes MANUAL_REVERT_REQUIRED into
# the run directory and exits non-zero — a louder signal than silent partial
# revert.
mutate_install_revert_trap() {
    if [[ -z "${_AB_RUN_DIR:-}" ]]; then
        echo "mutate_install_revert_trap: _AB_RUN_DIR not set" >&2
        return 1
    fi
    trap '_ab_revert_on_exit' EXIT
    trap '_ab_revert_on_exit; exit 130' INT
    trap '_ab_revert_on_exit; exit 143' TERM
    trap '_ab_revert_on_exit; exit 129' HUP
}

_ab_revert_on_exit() {
    if [[ ${#_AB_MUTATED_FILES[@]} -eq 0 ]]; then
        return 0
    fi

    # `git checkout --` is idempotent and safe even if a file was never edited.
    # We feed every tracked path so a partial-mutation failure is still cleaned.
    local file revert_failed=0
    for file in "${_AB_MUTATED_FILES[@]}"; do
        if ! git -C "$REPO_ROOT" checkout -- "$file" 2>/dev/null; then
            revert_failed=1
            echo "revert: failed to checkout $file" >&2
        fi
    done

    if [[ $revert_failed -eq 1 ]]; then
        _ab_write_manual_revert_marker
        return 0
    fi

    # Verify the working tree is clean across the mutated paths only — we do
    # not touch other files so cannot speak for them. A non-zero diff against
    # any tracked-and-mutated path means revert silently failed.
    if ! git -C "$REPO_ROOT" diff --quiet -- "${_AB_MUTATED_FILES[@]}"; then
        _ab_write_manual_revert_marker
        return 0
    fi

    if [[ -n "$_AB_RUN_DIR" && -d "$_AB_RUN_DIR" ]]; then
        : > "$_AB_RUN_DIR/REVERT_OK"
    fi
}

_ab_write_manual_revert_marker() {
    if [[ -z "$_AB_RUN_DIR" || ! -d "$_AB_RUN_DIR" ]]; then
        echo "MANUAL_REVERT_REQUIRED — run dir unavailable; resolve dirty tree by hand" >&2
        return 0
    fi
    {
        echo "Mutated files (some or all may still be dirty):"
        printf '  %s\n' "${_AB_MUTATED_FILES[@]}"
        echo
        echo "git status:"
        git -C "$REPO_ROOT" status --short
    } > "$_AB_RUN_DIR/MANUAL_REVERT_REQUIRED"
    echo "MANUAL_REVERT_REQUIRED — see $_AB_RUN_DIR/MANUAL_REVERT_REQUIRED" >&2
}

# Apply all mutations declared by the loaded config. Reads the parsed config
# (populated by lib/config.sh into _AB_CONFIG_*) and dispatches per-key.
# Tracks every mutated file via _ab_track_mutation so the trap can revert.
mutate_apply_config() {
    # Strip the ultrathink keyword from all three sync sites if the config
    # disables it on the synthesiser. Strip-from-all-three-or-none is enforced
    # by the structural test test_sync_synthesiser_dispatch_uses_ultrathink.
    if [[ "${_AB_CONFIG_STRIP_ULTRATHINK:-false}" == "true" ]]; then
        local site
        for site in "${_AB_ULTRATHINK_SYNC_SITES[@]}"; do
            local abs="$REPO_ROOT/$site"
            if [[ ! -f "$abs" ]]; then
                echo "mutate_apply_config: missing sync site $site" >&2
                return 1
            fi
            mutate_strip_ultrathink_keyword "$abs"
            _ab_track_mutation "$site"
        done
    fi

    # Per-agent model rewrites. _AB_CONFIG_AGENT_MODELS is a parallel-array
    # encoding: name then value, name then value. lib/config.sh populates it.
    local i agent new_model agent_path
    if [[ -n "${_AB_CONFIG_AGENT_MODELS:-}" ]]; then
        local -a kv
        # shellcheck disable=SC2206
        kv=( ${_AB_CONFIG_AGENT_MODELS} )
        for ((i = 0; i < ${#kv[@]}; i += 2)); do
            agent="${kv[i]}"
            new_model="${kv[i+1]}"
            agent_path="plugins/code-review-suite/agents/${agent}.md"
            if [[ ! -f "$REPO_ROOT/$agent_path" ]]; then
                echo "mutate_apply_config: agent file not found: $agent_path" >&2
                return 1
            fi
            mutate_set_agent_model "$REPO_ROOT/$agent_path" "$new_model"
            _ab_track_mutation "$agent_path"
        done
    fi
}
