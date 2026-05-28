#!/usr/bin/env bash
# tests/ab/lib/config.sh — minimal YAML config loader for the A/B harness.
# Sourced by tests/ab/run.sh. Exposes config_load <path>; full notes below
# set -euo pipefail.
set -euo pipefail

# config_load <path> validates the schema and populates the following
# environment-style globals consumed by lib/mutate.sh and lib/launch.sh:
#
#   _AB_CONFIG_AGENT             — agent name when mode: per-agent (string)
#   _AB_CONFIG_AGENT_MODELS      — space-separated "name model" pairs (parallel array)
#   _AB_CONFIG_DESCRIPTION       — optional description: field (string)
#   _AB_CONFIG_MODE              — "end-to-end" (default) | "per-agent"
#   _AB_CONFIG_NAME              — the config's name: field (string)
#   _AB_CONFIG_SESSION_EFFORT    — session.effort (string; passed as --effort)
#   _AB_CONFIG_SESSION_MODEL     — session.model (string; passed as --model)
#   _AB_CONFIG_STRIP_ULTRATHINK  — "true" if agents.review-synthesiser.ultrathink == false
#
# Unrecognised top-level or per-agent keys are a hard error — a typo must not
# silently fall back to production defaults.

_AB_VALID_TOP_KEYS="name description session agents mode agent"
_AB_VALID_MODES="end-to-end per-agent"
_AB_VALID_SESSION_KEYS="model effort"
_AB_VALID_AGENT_KEYS="model ultrathink"

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

    # 3. Validate per-agent keys.
    local agent
    for agent in $(yq '.agents // {} | keys | .[]' "$path"); do
        for key in $(yq ".agents.\"$agent\" | keys | .[]" "$path"); do
            if ! _ab_key_in_set "$key" "$_AB_VALID_AGENT_KEYS"; then
                echo "config_load: $path: unknown agent.$agent key '$key' (allowed: $_AB_VALID_AGENT_KEYS)" >&2
                return 1
            fi
        done
    done

    # 4. Populate globals. yq returns 'null' for missing keys; coerce to empty.
    _AB_CONFIG_NAME=$(yq -r '.name // ""' "$path")
    _AB_CONFIG_DESCRIPTION=$(yq -r '.description // ""' "$path")
    _AB_CONFIG_SESSION_MODEL=$(yq -r '.session.model // ""' "$path")
    _AB_CONFIG_SESSION_EFFORT=$(yq -r '.session.effort // ""' "$path")

    if [[ -z "$_AB_CONFIG_NAME" ]]; then
        echo "config_load: $path: name: is required" >&2
        return 1
    fi

    # 5. Derive the strip-ultrathink flag from the synthesiser entry.
    # Note: Mike Farah's yq (Go variant) treats `false` as null-ish for the
    # `//` alternative operator, so we read the raw value and decide in bash
    # rather than relying on `// "true"` to default a missing key.
    local synth_ultra
    synth_ultra=$(yq -r '.agents."review-synthesiser".ultrathink' "$path")
    if [[ "$synth_ultra" == "false" ]]; then
        _AB_CONFIG_STRIP_ULTRATHINK="true"
    else
        _AB_CONFIG_STRIP_ULTRATHINK="false"
    fi

    # 6. Build _AB_CONFIG_AGENT_MODELS as a space-separated parallel-array
    # encoding consumed by mutate_apply_config.
    _AB_CONFIG_AGENT_MODELS=""
    for agent in $(yq '.agents // {} | keys | .[]' "$path"); do
        local model_val
        model_val=$(yq -r ".agents.\"$agent\".model // \"\"" "$path")
        if [[ -n "$model_val" ]]; then
            _AB_CONFIG_AGENT_MODELS+=" $agent $model_val"
        fi
    done
    _AB_CONFIG_AGENT_MODELS="${_AB_CONFIG_AGENT_MODELS# }"

    # 7. Mode + agent. Defaults: mode=end-to-end (Phase 1 behaviour). When
    # mode is per-agent, an agent: top-level field is mandatory; the
    # agents: map must not declare any per-agent model override since
    # per-agent mode varies model via session.model and never edits
    # tracked files. Non-model agents: entries are not currently caught
    # by this guard — see config.sh deviation note in the Task 3 commit.
    _AB_CONFIG_MODE=$(yq -r '.mode // "end-to-end"' "$path")
    _AB_CONFIG_AGENT=$(yq -r '.agent // ""' "$path")

    if ! _ab_key_in_set "$_AB_CONFIG_MODE" "$_AB_VALID_MODES"; then
        echo "config_load: $path: unknown mode '$_AB_CONFIG_MODE' (allowed: $_AB_VALID_MODES)" >&2
        return 1
    fi

    if [[ "$_AB_CONFIG_MODE" == "per-agent" ]]; then
        if [[ -z "$_AB_CONFIG_AGENT" ]]; then
            echo "config_load: $path: agent: is required when mode: per-agent" >&2
            return 1
        fi
        if [[ -n "$_AB_CONFIG_AGENT_MODELS" ]]; then
            echo "config_load: $path: agents: must not declare per-agent model overrides when mode: per-agent (per-agent varies model via session.model only)" >&2
            return 1
        fi
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
