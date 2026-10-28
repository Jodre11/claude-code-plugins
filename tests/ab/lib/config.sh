#!/usr/bin/env bash
# tests/ab/lib/config.sh — minimal YAML config loader for the A/B harness.
# Sourced by tests/ab/run.sh. Exposes config_load <path>; full notes below
# set -euo pipefail.
set -euo pipefail

# config_load <path> validates the schema and populates the following
# environment-style globals consumed by tests/ab/run.sh and lib/launch.sh:
#
#   _AB_CONFIG_AGENT             — the agent under test (string)
#   _AB_CONFIG_MODE              — "per-agent" (the only mode)
#   _AB_CONFIG_NAME              — the config's name: field (string)
#   _AB_CONFIG_SESSION_EFFORT    — session.effort (string; passed as --effort)
#   _AB_CONFIG_SESSION_MODEL     — session.model (string; passed as --model)
#
# Unrecognised top-level or session keys are a hard error — a typo must not
# silently fall back to production defaults.

_AB_VALID_TOP_KEYS="name description session mode agent"
_AB_VALID_MODES="per-agent"
_AB_VALID_SESSION_KEYS="model effort"

config_load() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "config_load: $path: not found" >&2
        return 1
    fi

    # 1. Validate top-level keys.
    local key
    for key in $(yq 'keys | .[]' "$path"); do
        if ! _ab_key_in_set "$key" "$_AB_VALID_TOP_KEYS"; then
            echo "config_load: $path: unknown top-level key '$key' (allowed: $_AB_VALID_TOP_KEYS)" >&2
            return 1
        fi
    done

    # 2. Validate session keys.
    if [[ "$(yq 'has("session")' "$path")" == "true" ]]; then
        for key in $(yq '.session | keys | .[]' "$path"); do
            if ! _ab_key_in_set "$key" "$_AB_VALID_SESSION_KEYS"; then
                echo "config_load: $path: unknown session key '$key' (allowed: $_AB_VALID_SESSION_KEYS)" >&2
                return 1
            fi
        done
    fi

    # 3. Populate globals. yq returns 'null' for missing keys; coerce to empty.
    _AB_CONFIG_NAME=$(yq -r '.name // ""' "$path")
    _AB_CONFIG_SESSION_MODEL=$(yq -r '.session.model // ""' "$path")
    _AB_CONFIG_SESSION_EFFORT=$(yq -r '.session.effort // ""' "$path")

    if [[ -z "$_AB_CONFIG_NAME" ]]; then
        echo "config_load: $path: name: is required" >&2
        return 1
    fi

    # 4. Mode + agent. A config dispatches one agent, so agent: is mandatory.
    _AB_CONFIG_MODE=$(yq -r '.mode // "per-agent"' "$path")
    _AB_CONFIG_AGENT=$(yq -r '.agent // ""' "$path")

    if ! _ab_key_in_set "$_AB_CONFIG_MODE" "$_AB_VALID_MODES"; then
        echo "config_load: $path: unknown mode '$_AB_CONFIG_MODE' (allowed: $_AB_VALID_MODES)" >&2
        return 1
    fi

    if [[ -z "$_AB_CONFIG_AGENT" ]]; then
        echo "config_load: $path: agent: is required" >&2
        return 1
    fi
}

_ab_key_in_set() {
    local needle="$1"
    local haystack="$2"
    local k
    for k in $haystack; do
        if [[ "$k" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}
