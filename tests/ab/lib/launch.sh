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

# Reduce a stream-json JSONL trace to a single canonical-text string and write
# it to the given target path. Tries the canonical path first: the .result
# field of the terminal {type:"result", subtype:"success"} event. If that's
# missing or empty (Phase 3.1a Category C envelope-finalisation gap), falls
# back to concatenating .text blocks from preceding {type:"assistant"} events
# in stream order, joined by '\n'.
#
# The fallback is recovery, not substitution: 3.1a confirmed by inspection
# (trials 002/005/006/015/016/020) that the canonical text lives in those
# blocks when the envelope's .result is empty.
#
# Returns 0 on any successful reduction (including empty output when neither
# path produces text); non-zero only on jq invocation failure.
launch_jq_reduce_stream_jsonl() {
    local stream_jsonl="$1"
    local stdout="$2"

    if [[ ! -s "$stream_jsonl" ]]; then
        : > "$stdout"
        return 0
    fi

    # Canonical path: terminal result.subtype="success" with non-empty .result.
    local canonical
    canonical=$(jq -r '
        select(.type == "result" and .subtype == "success") | .result // ""
    ' "$stream_jsonl")

    if [[ -n "$canonical" ]]; then
        printf '%s' "$canonical" > "$stdout"
        return 0
    fi

    # Fallback: concatenate text blocks from assistant events in stream order,
    # joined by a single \n.
    jq -r '
        select(.type == "assistant") | .message.content[]?
        | select(.type == "text") | .text
    ' "$stream_jsonl" | awk 'NR>1 {printf "\n"} {printf "%s", $0}' > "$stdout"
}

# Validate-or-die post-condition for one per-agent trial. Inspects the
# captured artefacts in <trial_dir> and returns non-zero with a single-line
# JSON object on stderr when the trial is unrecoverable.
#
# Unrecoverable predicate:
#   stdout.log <= 1 byte
#   AND ( no stream.jsonl
#         OR no terminal {type:"result"} event
#         OR result.subtype == "error" )
#
# Anything else is recoverable: a fallback-recovered stdout.log is recoverable;
# a stream.jsonl with subtype="error" AND non-empty stdout.log is recoverable;
# a subtype="error" with empty stdout.log is unrecoverable.
#
# Stable structured-stderr fields:
#   stage, reason, stdout_bytes, stream_jsonl_present, has_terminal_result, result_subtype
#
# Reason values are an enumerated set; adding a new reason is a contract bump:
#   empty_stdout_no_stream_jsonl
#   empty_stdout_no_terminal_result
#   empty_stdout_subtype_error
#   empty_stdout_no_recovery_signal
launch_assert_trial_recoverable() {
    local trial_dir="$1"
    local stdout="$trial_dir/stdout.log"
    local stream_jsonl="$trial_dir/stream.jsonl"

    local stdout_bytes=0
    if [[ -f "$stdout" ]]; then
        stdout_bytes=$(wc -c < "$stdout" | awk '{print $1}')
    fi

    # Recoverable: stdout.log has more than 1 byte.
    if [[ "$stdout_bytes" -gt 1 ]]; then
        return 0
    fi

    # stdout is empty; classify the unrecoverable reason.
    local stream_jsonl_present="false"
    local has_terminal_result="false"
    local result_subtype=""
    local reason=""

    if [[ -f "$stream_jsonl" ]]; then
        stream_jsonl_present="true"
        # Probe for terminal result event; capture subtype if present.
        result_subtype=$(jq -r '
            select(.type == "result") | .subtype // ""
        ' "$stream_jsonl" | tail -1)
        if [[ -n "$result_subtype" ]]; then
            has_terminal_result="true"
        fi
    fi

    if [[ "$stream_jsonl_present" == "false" ]]; then
        reason="empty_stdout_no_stream_jsonl"
    elif [[ "$has_terminal_result" == "false" ]]; then
        reason="empty_stdout_no_terminal_result"
    elif [[ "$result_subtype" == "error" ]]; then
        reason="empty_stdout_subtype_error"
    else
        # Terminal subtype="success" but fallback produced nothing.
        reason="empty_stdout_no_recovery_signal"
    fi

    jq -n \
        --arg stage "launch_assert_trial_recoverable" \
        --arg reason "$reason" \
        --argjson stdout_bytes "$stdout_bytes" \
        --arg stream_jsonl_present "$stream_jsonl_present" \
        --arg has_terminal_result "$has_terminal_result" \
        --arg result_subtype "$result_subtype" \
        '{stage: $stage, reason: $reason, stdout_bytes: $stdout_bytes,
          stream_jsonl_present: ($stream_jsonl_present == "true"),
          has_terminal_result: ($has_terminal_result == "true"),
          result_subtype: $result_subtype}' \
        | jq -c '.' >&2

    return 1
}

# Run one per-agent trial. Sibling of launch_run_trial; differs in:
#  - cwd is <working_dir>, not the marketplace root.
#  - --append-system-prompt-file is added (file form confirmed via CLI probe).
#  - the positional argument is the user-message contents (not a slash
#    command).
#
# Returns 0 on a clean run, 124 on timeout, or the underlying exit code.
#
# Contract:
#  - body_path and user_msg_path MUST be absolute paths. The trial subshell
#    shifts cwd to working_dir before invoking claude, so a relative path
#    would resolve against working_dir instead of the caller's cwd.
#  - --allowed-tools is intentionally omitted; the agent inherits the full
#    tool surface. The Phase 2b faithfulness check is the safety net.
launch_run_per_agent_trial() {
    local trial_dir="$1"
    local timeout_seconds="$2"
    local model="$3"
    local effort="$4"
    local body_path="$5"
    local user_msg_path="$6"
    local timeout_bin="$7"
    local working_dir="$8"
    local stream_json="${9:-false}"

    local stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log"
    local timing="$trial_dir/timing.json"
    local stream_jsonl="$trial_dir/stream.jsonl"

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
    #
    # effort=default (or empty) means "let the model use its built-in default".
    # The claude CLI does not accept "default" as a valid --effort value, so we
    # omit the flag entirely when the config specifies it.
    #
    # stream_json=true (Phase 3.1a) opts into --output-format stream-json. The
    # CLI mandates --verbose as a companion flag in this mode (verified
    # empirically by Phase 3.1a Task 1; without it the CLI exits rc=1 with
    # "Error: When using --print, --output-format=stream-json requires
    # --verbose"). In stream-json mode, fd 1 is the JSONL trace; we capture it
    # to stream.jsonl and reconstruct stdout.log via a jq filter on the
    # terminal `result` event so downstream parsers continue to work.
    local -a extra_flags=()
    if [[ -n "$effort" && "$effort" != "default" ]]; then
        extra_flags+=("--effort" "$effort")
    fi
    if [[ "$stream_json" == "true" ]]; then
        extra_flags+=("--output-format" "stream-json" "--verbose")
    fi

    local rc=0
    if [[ "$stream_json" == "true" ]]; then
        # stream-json mode: stdout IS the JSONL trace. Capture it to
        # stream.jsonl and reconstruct the final-text stdout.log via a jq
        # filter. Schema is the Claude Code SDK envelope; canonical final-text
        # lives at .result on the single {type:"result", subtype:"success"}
        # event at EOF. If subtype is "error" or no result event exists, the
        # reconstructed stdout.log is empty — exactly the diagnostic signal
        # Phase 3.1a is hunting.
        (
            cd "$working_dir"
            CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
            "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
                command claude \
                    -p \
                    --permission-mode bypassPermissions \
                    --model "$model" \
                    "${extra_flags[@]}" \
                    --append-system-prompt-file "$body_path" \
                    --exclude-dynamic-system-prompt-sections \
                    "$user_msg" \
                > "$stream_jsonl" 2> "$stderr"
        ) || rc=$?

        launch_jq_reduce_stream_jsonl "$stream_jsonl" "$stdout"
    else
        # Pre-3.1a behaviour: stdout is the final text directly.
        (
            cd "$working_dir"
            CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
            "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
                command claude \
                    -p \
                    --permission-mode bypassPermissions \
                    --model "$model" \
                    "${extra_flags[@]}" \
                    --append-system-prompt-file "$body_path" \
                    --exclude-dynamic-system-prompt-sections \
                    "$user_msg" \
                > "$stdout" 2> "$stderr"
        ) || rc=$?
    fi

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

    # Phase 3.1c: validate-or-die. If the trial is unrecoverable (empty
    # stdout.log AND no recovery signal in stream.jsonl), the assertion
    # writes a structured-stderr JSON line to fd 2 and returns non-zero.
    # We propagate that rc only if rc was 0 — a real subprocess failure
    # (timeout=124, CLI error) takes precedence over a derived assertion.
    local assert_rc=0
    launch_assert_trial_recoverable "$trial_dir" 2>> "$stderr" || assert_rc=$?
    if [[ "$rc" == "0" && "$assert_rc" != "0" ]]; then
        rc=$assert_rc
    fi

    return "$rc"
}
