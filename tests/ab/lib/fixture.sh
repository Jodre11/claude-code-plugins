#!/usr/bin/env bash
# tests/ab/lib/fixture.sh — fixture loader, working-dir materialiser, decay-warner.
# Sourced by tests/ab/run.sh in --mode per-agent. See full notes below
# set -euo pipefail.
set -euo pipefail

# Required keys in source.yaml. captured_under sub-keys (suite_sha, agent_model,
# agent_effort) are validated as a unit when captured_under is present.
_AB_FIXTURE_REQUIRED_KEYS="id agent captured_at captured_under working_dir_strategy intent_ledger depends_on"
_AB_FIXTURE_VALID_STRATEGIES="copy worktree patch"

# Load a fixture by id from the corpus directory. Index.yaml gates the lookup
# (no glob discovery) — if the id is absent from index.yaml, the load fails.
fixture_load() {
    local fixture_id="$1"
    local index="$REPO_ROOT/tests/ab/corpus/index.yaml"

    if [[ ! -f "$index" ]]; then
        echo "fixture_load: $index: not found" >&2
        return 1
    fi

    local count
    count=$(yq ".fixtures[] | select(.id == \"$fixture_id\") | .id" "$index" | wc -l | tr -d '[:space:]')
    if [[ "$count" == "0" ]]; then
        echo "fixture_load: $fixture_id: not in $index" >&2
        return 1
    fi

    local fixture_dir="$REPO_ROOT/tests/ab/corpus/$fixture_id"
    if [[ ! -d "$fixture_dir" ]]; then
        echo "fixture_load: $fixture_dir: directory missing" >&2
        return 1
    fi

    fixture_load_from_path "$fixture_dir/source.yaml"
    _AB_FIXTURE_DIR="$fixture_dir"
}

# Lower-level loader used by the unit tests. Validates the schema and
# populates _AB_FIXTURE_* globals; never resolves an id against index.yaml.
fixture_load_from_path() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "fixture_load_from_path: $path: not found" >&2
        return 1
    fi

    local key
    for key in $_AB_FIXTURE_REQUIRED_KEYS; do
        if [[ "$(yq "has(\"$key\")" "$path")" != "true" ]]; then
            echo "fixture_load_from_path: $path: missing required key '$key'" >&2
            return 1
        fi
    done

    _AB_FIXTURE_ID=$(yq -r '.id' "$path")
    _AB_FIXTURE_AGENT=$(yq -r '.agent' "$path")
    _AB_FIXTURE_STRATEGY=$(yq -r '.working_dir_strategy' "$path")
    _AB_FIXTURE_SOURCE_PATH=$(yq -r '.source_path // ""' "$path")
    _AB_FIXTURE_BASE_SHA=$(yq -r '.base_sha // ""' "$path")
    _AB_FIXTURE_HEAD_SHA=$(yq -r '.head_sha // ""' "$path")
    _AB_FIXTURE_CAPTURED_SUITE_SHA=$(yq -r '.captured_under.suite_sha' "$path")
    _AB_FIXTURE_SOURCE_YAML="$path"

    if ! _ab_key_in_set_lib "$_AB_FIXTURE_STRATEGY" "$_AB_FIXTURE_VALID_STRATEGIES"; then
        echo "fixture_load_from_path: $path: invalid working_dir_strategy '$_AB_FIXTURE_STRATEGY'" >&2
        return 1
    fi
}

# Materialise the per-trial working directory. <out-dir> is created if absent
# and populated according to the loaded fixture's strategy.
fixture_materialise() {
    local out_dir="$1"
    mkdir -p "$out_dir"

    case "$_AB_FIXTURE_STRATEGY" in
        copy)
            if [[ -z "$_AB_FIXTURE_SOURCE_PATH" ]]; then
                echo "fixture_materialise: source_path is required for working_dir_strategy: copy" >&2
                return 1
            fi
            local src="$REPO_ROOT/$_AB_FIXTURE_SOURCE_PATH"
            if [[ ! -d "$src" ]]; then
                echo "fixture_materialise: $src: not a directory" >&2
                return 1
            fi
            cp -R "$src/." "$out_dir/"
            ;;
        worktree)
            if [[ -z "$_AB_FIXTURE_HEAD_SHA" ]]; then
                echo "fixture_materialise: head_sha is required for working_dir_strategy: worktree" >&2
                return 1
            fi
            git -C "$REPO_ROOT" worktree add --detach "$out_dir" "$_AB_FIXTURE_HEAD_SHA"
            ;;
        patch)
            local patch="$_AB_FIXTURE_DIR/diff/full-diff.patch"
            if [[ ! -f "$patch" ]]; then
                echo "fixture_materialise: $patch: not found (required for working_dir_strategy: patch)" >&2
                return 1
            fi
            git -C "$REPO_ROOT" worktree add --detach "$out_dir" "$_AB_FIXTURE_BASE_SHA"
            ( cd "$out_dir" && git apply "$patch" )
            ;;
    esac
}

# Clean up a per-trial working directory. For worktree-strategy fixtures the
# git worktree must be removed; for copy/patch the directory tree suffices.
fixture_cleanup() {
    local out_dir="$1"
    if [[ ! -d "$out_dir" ]]; then
        return 0
    fi
    case "$_AB_FIXTURE_STRATEGY" in
        worktree|patch)
            git -C "$REPO_ROOT" worktree remove --force "$out_dir" 2>/dev/null || rm -rf "$out_dir"
            ;;
        copy)
            rm -rf "$out_dir"
            ;;
    esac
}

# Run the decay-warner across all paths in depends_on. Returns a multiline
# string of warnings (one per path that has been modified since the captured
# suite_sha) on stdout. Empty stdout = no decay.
fixture_check_decay() {
    local source_yaml="$_AB_FIXTURE_SOURCE_YAML"
    local captured_sha="$_AB_FIXTURE_CAPTURED_SUITE_SHA"

    if [[ "$captured_sha" == "pending" || -z "$captured_sha" ]]; then
        # Fixture not yet captured against a real suite_sha — no decay to check.
        return 0
    fi

    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        fixture_decay_warnings_for_path "$captured_sha" "$path"
    done < <(yq -r '.depends_on[]' "$source_yaml")
}

# Lower-level decay probe used by the unit tests. Returns one warning line
# per path-vs-sha mismatch on stdout, blank otherwise.
fixture_decay_warnings_for_path() {
    local captured_sha="$1"
    local path="$2"

    local commits
    commits=$(git log --pretty=format:%H "$captured_sha"..HEAD -- "$path" 2>/dev/null || true)
    if [[ -n "$commits" ]]; then
        echo "$path: changed since $captured_sha"
    fi
}

_ab_key_in_set_lib() {
    local needle="$1"
    local haystack="$2"
    local k
    for k in $haystack; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}
