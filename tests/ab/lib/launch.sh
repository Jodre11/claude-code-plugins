#!/usr/bin/env bash
# tests/ab/lib/launch.sh — launch primitive for the A/B harness.
# See full notes below set -euo pipefail.

set -euo pipefail

# Sourced by tests/ab/run.sh. Replicates the setup the user's claude() shell
# function performs (source ~/.claudeenv, run aws-sso-preflight.sh) without
# wrapping in tmux and without dropping the -p flag. Then exec's
# `command claude -p <prompt>` with --permission-mode bypassPermissions and
# the per-config --model and --effort.

# Resolve the GNU timeout binary. Linux ships it as `timeout`; macOS exposes
# it as `gtimeout` via Homebrew coreutils. Returns the chosen name on stdout.
launch_resolve_timeout_binary() {
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout"
        return 0
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
        return 0
    fi
    echo "launch_resolve_timeout_binary: neither timeout nor gtimeout on PATH" >&2
    echo "neither-available"
    return 1
}

# Source ~/.claudeenv if present, then run aws-sso-preflight.sh once. Both are
# idempotent. Failure of the preflight is a hard halt — Bedrock will hang on
# expired tokens otherwise.
launch_preflight_environment() {
    if [[ -f "$HOME/.claudeenv" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.claudeenv"
    fi
    if [[ -x "$HOME/.claude/scripts/aws-sso-preflight.sh" ]]; then
        if ! "$HOME/.claude/scripts/aws-sso-preflight.sh"; then
            echo "launch_preflight_environment: aws-sso-preflight.sh failed" >&2
            return 1
        fi
    fi
}

# Build the argv to pass to `command claude`. The prompt is written to a temp
# file by the caller and fed via stdin to keep argv short and shell-safe;
# this function only emits flags. One element per line on stdout for testing.
launch_build_claude_argv() {
    local model="$1"
    local effort="$2"
    local prompt="$3"  # printed last as the positional prompt argument

    printf '%s\n' \
        "-p" \
        "--permission-mode" "bypassPermissions" \
        "--model" "$model" \
        "--effort" "$effort" \
        "--exclude-dynamic-system-prompt-sections" \
        "$prompt"
}

# Run one trial. Wraps the `command claude` invocation in `timeout`, captures
# stdout/stderr to per-trial files, and writes timing.json. Caller passes the
# trial directory and the resolved per-trial args.
#
# Returns 0 on a clean run, 124 on timeout (per GNU timeout convention), or
# the underlying exit code.
launch_run_trial() {
    local trial_dir="$1"
    local timeout_seconds="$2"
    local model="$3"
    local effort="$4"
    local prompt="$5"
    local timeout_bin="$6"

    local stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log"
    local timing="$trial_dir/timing.json"

    local start_iso
    start_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local start_epoch=$SECONDS

    # Heartbeat: emit elapsed-time updates to stderr every 60s while the
    # trial runs, so a 17-20 minute trial is observable. The heartbeat fires
    # only via stderr — never the captured stdout — so verdict regex matching
    # is unaffected. Killed in a trap when the trial returns or the harness
    # is interrupted.
    (
        hb_elapsed=0
        while sleep 60; do
            hb_elapsed=$((hb_elapsed + 60))
            echo "[$(date +'%H:%M:%S')] $(basename "$trial_dir"): still running (${hb_elapsed}s elapsed)" >&2
        done
    ) &
    local hb_pid=$!
    trap 'kill -TERM "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true' RETURN

    # CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 (set in ~/.claudeenv as a hardening
    # default) silently downgrades --permission-mode bypassPermissions to
    # default and emits a one-line stderr warning. The harness needs the
    # explicit permission flag to be honoured so non-interactive trials don't
    # stall on Class A confirmation gates. Override for this subprocess only.
    local rc=0
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
    "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
        command claude \
            -p \
            --permission-mode bypassPermissions \
            --model "$model" \
            --effort "$effort" \
            --exclude-dynamic-system-prompt-sections \
            "$prompt" \
        > "$stdout" 2> "$stderr" || rc=$?

    kill -TERM "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
    trap - RETURN

    local end_epoch=$SECONDS
    local end_iso
    end_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local elapsed=$((end_epoch - start_epoch))

    local timed_out="false"
    if [[ "$rc" == "124" ]]; then
        timed_out="true"
    fi

    jq -n \
        --arg start "$start_iso" \
        --arg end "$end_iso" \
        --argjson elapsed "$elapsed" \
        --argjson rc "$rc" \
        --arg timed_out "$timed_out" \
        '{start: $start, end: $end, wall_clock_seconds: $elapsed, exit_code: $rc, timed_out: ($timed_out == "true")}' \
        > "$timing"

    return "$rc"
}

# Build the argv for a per-agent invocation. One element per line on stdout
# for testing. The user message is passed as the positional argument; the
# system prompt body is supplied via --append-system-prompt-file. Confirmed
# at implementation time: --append-system-prompt-file is a recognised flag
# (returns "file not found" rather than "unknown option") but is not listed
# as a standalone help entry — referenced only as --append-system-prompt[-file]
# in the --bare description.
launch_build_per_agent_argv() {
    local model="$1"
    local effort="$2"
    local body_path="$3"
    local user_msg_path="$4"

    local user_msg
    user_msg=$(cat "$user_msg_path")

    printf '%s\n' \
        "-p" \
        "--permission-mode" "bypassPermissions" \
        "--model" "$model" \
        "--effort" "$effort" \
        "--append-system-prompt-file" "$body_path" \
        "--exclude-dynamic-system-prompt-sections" \
        "$user_msg"
}

# Run one per-agent trial. Sibling of launch_run_trial; differs in:
#  - cwd is <working_dir>, not the marketplace root.
#  - --append-system-prompt-file is added (file form confirmed via CLI probe).
#  - the positional argument is the user-message contents (not a slash
#    command).
#
# Returns 0 on a clean run, 124 on timeout, or the underlying exit code.
launch_run_per_agent_trial() {
    local trial_dir="$1"
    local timeout_seconds="$2"
    local model="$3"
    local effort="$4"
    local body_path="$5"
    local user_msg_path="$6"
    local timeout_bin="$7"
    local working_dir="$8"

    local stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log"
    local timing="$trial_dir/timing.json"

    local user_msg
    user_msg=$(cat "$user_msg_path")

    local start_iso
    start_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local start_epoch=$SECONDS

    # Heartbeat: emit elapsed-time updates to stderr every 60s while the
    # trial runs, so a long trial is observable. Mirrors launch_run_trial.
    # Killed in a trap when the trial returns or the harness is interrupted.
    (
        hb_elapsed=0
        while sleep 60; do
            hb_elapsed=$((hb_elapsed + 60))
            echo "[$(date +'%H:%M:%S')] $(basename "$trial_dir"): still running (${hb_elapsed}s elapsed)" >&2
        done
    ) &
    local hb_pid=$!
    trap 'kill -TERM "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true' RETURN

    # CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 silently downgrades --permission-mode
    # bypassPermissions. Override for this subprocess only (same as
    # launch_run_trial).
    local rc=0
    (
        cd "$working_dir"
        CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
        "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
            command claude \
                -p \
                --permission-mode bypassPermissions \
                --model "$model" \
                --effort "$effort" \
                --append-system-prompt-file "$body_path" \
                --exclude-dynamic-system-prompt-sections \
                "$user_msg" \
            > "$stdout" 2> "$stderr"
    ) || rc=$?

    kill -TERM "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
    trap - RETURN

    local end_epoch=$SECONDS
    local end_iso
    end_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    local elapsed=$((end_epoch - start_epoch))

    local timed_out="false"
    if [[ "$rc" == "124" ]]; then
        timed_out="true"
    fi

    jq -n \
        --arg start "$start_iso" \
        --arg end "$end_iso" \
        --argjson elapsed "$elapsed" \
        --argjson rc "$rc" \
        --arg timed_out "$timed_out" \
        '{start: $start, end: $end, wall_clock_seconds: $elapsed, exit_code: $rc, timed_out: ($timed_out == "true")}' \
        > "$timing"

    return "$rc"
}
