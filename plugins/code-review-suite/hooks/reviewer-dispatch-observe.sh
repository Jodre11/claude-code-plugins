#!/usr/bin/env bash
# reviewer-dispatch-observe.sh — PreToolUse(Agent) observe-mode guard.
# Logs (never denies) any MAIN-SESSION dispatch of a code-review-suite reviewer
# subagent. Evidence for the later flip to a hard deny once the Workflow is the
# only path. Discriminator: .agent_type is present only for subagent-originated
# Agent calls; absent for the main session (see allow-permissions.sh).
set -euo pipefail
input="$(cat)"
agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""')"
subagent_type="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')"
log="${CLAUDE_REVIEW_OBSERVE_LOG:-${TMPDIR:-/tmp}/code-review-observe.log}"

# Only main-session (agent_type empty) reviewer dispatches are of interest.
if [[ -z "$agent_type" ]]; then
    case "${subagent_type##*:}" in
        *-reviewer|code-analysis|review-synthesiser)
            printf '{"event":"main_session_reviewer_dispatch","subagent_type":"%s"}\n' \
                "$subagent_type" >> "$log"
            ;;
    esac
fi
exit 0
