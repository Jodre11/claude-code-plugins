#!/usr/bin/env bash
# tests/ab/lib/orchestration.sh — orchestration A/B: arm toggle (temp user-level
# code-review.toml) + durable-log harvest. See rationale comments below.
set -euo pipefail

# Arm toggle rationale (see spec § "Arm toggle"): panel is selected by
# orchestration.review_mode in ~/.claude/code-review.toml, NOT by editing tracked
# files. We write a temp user-level TOML, back up any pre-existing one, and restore
# on every exit path. A failed restore writes MANUAL_REVERT_REQUIRED rather than
# leaving a stray toggle that would silently taint the operator's real reviews.

_AB_ORCH_TOML=""
_AB_ORCH_BACKUP=""
_AB_ORCH_HAD_PRIOR="false"

# Write the [orchestration] arm config to <toml_path>, backing up any prior file.
orchestration_apply_arm() {
    local arm="$1"
    local panel_size="$2"
    local toml_path="${3:-$HOME/.claude/code-review.toml}"

    case "$arm" in
        classic|panel) ;;
        *) echo "orchestration_apply_arm: unknown arm '$arm'" >&2; return 1 ;;
    esac

    _AB_ORCH_TOML="$toml_path"
    _AB_ORCH_BACKUP="${toml_path}.ab-backup"
    mkdir -p "$(dirname "$toml_path")"

    if [[ -f "$toml_path" ]]; then
        _AB_ORCH_HAD_PRIOR="true"
        cp "$toml_path" "$_AB_ORCH_BACKUP"
    else
        _AB_ORCH_HAD_PRIOR="false"
    fi

    # full_log=true and analysis_only=true are forced on for the whole experiment — the
    # durable log is the data source, and analysis_only runs the full pipeline but renders
    # to stdout instead of posting (the merged-PR corpus would otherwise short-circuit).
    # panel_size is written even for classic (the workflow ignores it).
    cat > "$toml_path" <<EOF
[orchestration]
review_mode = "$arm"
panel_size = $panel_size
full_log = true
analysis_only = true
EOF
}

# Restore the pre-run state. Idempotent; safe to call from a trap more than once.
orchestration_restore_arm() {
    [[ -n "$_AB_ORCH_TOML" ]] || return 0
    local ok=0
    if [[ "$_AB_ORCH_HAD_PRIOR" == "true" ]]; then
        if [[ -f "$_AB_ORCH_BACKUP" ]]; then
            mv -f "$_AB_ORCH_BACKUP" "$_AB_ORCH_TOML" || ok=1
        else
            ok=1
        fi
    else
        rm -f "$_AB_ORCH_TOML" || ok=1
    fi
    if [[ "$ok" -ne 0 ]]; then
        _ab_orch_manual_revert_marker
    fi
    _AB_ORCH_TOML=""  # disarm so a second trap invocation is a no-op
}

_ab_orch_manual_revert_marker() {
    local dir="${_AB_RUN_DIR:-}"
    if [[ -n "$dir" && -d "$dir" ]]; then
        {
            echo "MANUAL_REVERT_REQUIRED — code-review.toml restore failed"
            echo "toml:   $_AB_ORCH_TOML"
            echo "backup: $_AB_ORCH_BACKUP (had_prior=$_AB_ORCH_HAD_PRIOR)"
        } > "$dir/MANUAL_REVERT_REQUIRED"
    fi
    echo "orchestration: MANUAL_REVERT_REQUIRED — restore code-review.toml by hand" >&2
}

orchestration_install_restore_trap() {
    trap 'orchestration_restore_arm' EXIT
    trap 'orchestration_restore_arm; exit 130' INT
    trap 'orchestration_restore_arm; exit 143' TERM
    trap 'orchestration_restore_arm; exit 129' HUP
}

# owner/name from a github PR URL, with '/'→'-' (matches the writer's <repo-slug>).
orchestration_slug_from_url() {
    local url="$1"
    # .../<owner>/<name>/pull/<N>  → owner-name
    local path="${url#*github.com/}"
    local owner="${path%%/*}"; path="${path#*/}"
    local name="${path%%/*}"
    echo "${owner}-${name}"
}

orchestration_ident_from_url() {
    local url="$1"
    echo "pr-${url##*/}"
}

# Harvest review-core's output straight from its Workflow journal, bypassing the
# orchestrator's post-Workflow Step 3.6 durable-log write (which never runs under
# `claude -p` — see issues #94/#95: the review-core Workflow is dispatched to the
# background and its completion notification has no next turn to land in, so the
# orchestrator's tail never executes and no on-disk log is written).
#
# The Workflow tool journals every agent() return value under
#   <projects_root>/<session_id>/subagents/workflows/wf_*/journal.jsonl
# There is exactly one wf_* journal per trial session. The synthesiser's result is
# the sole entry whose `.result` object carries `bodyText` — that IS the rendered
# review report (what a human ranks and what arm-tell derivation diffs). We also copy
# the whole journal as durable-log.jsonl for the fuller per-cog corpus (specialist
# findings + panel votes).
#
# session_id comes from the trial's own stream.jsonl `type=="result"` event.
# Returns 1 (writing nothing) when the session can't be resolved or the journal holds
# no synthesiser bodyText (e.g. the trial was torn down mid-synthesis), so the caller
# records a harvest-miss and presses on.
orchestration_harvest_journal() {
    local trial_dir="$1"
    local projects_root="${2:-$HOME/.claude/projects}"

    local stream="$trial_dir/stream.jsonl"
    [[ -f "$stream" ]] || { echo "orchestration_harvest_journal: no stream.jsonl in $trial_dir" >&2; return 1; }

    local session_id
    session_id=$(jq -r 'select(.type=="result") | .session_id // empty' "$stream" 2>/dev/null | tail -1)
    if [[ -z "$session_id" ]]; then
        echo "orchestration_harvest_journal: no session_id in $stream" >&2
        return 1
    fi

    # One wf_* journal per session; glob across all project dirs (the projects-root
    # subdir is the cwd-slug, not the session id).
    local journal=""
    local cand
    for cand in "$projects_root"/*/"$session_id"/subagents/workflows/wf_*/journal.jsonl; do
        [[ -f "$cand" ]] || continue
        journal="$cand"
        break
    done
    if [[ -z "$journal" ]]; then
        echo "orchestration_harvest_journal: no wf journal for session $session_id" >&2
        return 1
    fi

    # The synthesiser result is the one whose .result carries bodyText.
    local body
    body=$(jq -r 'select(.type=="result") | select(.result | type=="object" and has("bodyText")) | .result.bodyText' "$journal" 2>/dev/null | head -c 10000000)
    if [[ -z "$body" ]]; then
        echo "orchestration_harvest_journal: journal $journal has no synthesiser bodyText (torn down pre-synth?)" >&2
        return 1
    fi

    printf '%s\n' "$body" > "$trial_dir/durable-log.md"
    cp "$journal" "$trial_dir/durable-log.jsonl"
    return 0
}

# Copy the durable log for one run into the trial dir. Returns 1 (writing nothing)
# when the jsonl is absent, so the caller records a harvest-miss and presses on.
orchestration_harvest() {
    local trial_dir="$1"
    local logs_root="$2"
    local repo_slug="$3"
    local ident="$4"
    local head_sha="$5"

    local sha12="${head_sha:0:12}"
    local src_jsonl="$logs_root/$repo_slug/${ident}-${sha12}.jsonl"
    local src_md="$logs_root/$repo_slug/${ident}-${sha12}.md"

    if [[ ! -f "$src_jsonl" ]]; then
        echo "orchestration_harvest: no durable log at $src_jsonl" >&2
        return 1
    fi
    cp "$src_jsonl" "$trial_dir/durable-log.jsonl"
    if [[ -f "$src_md" ]]; then
        cp "$src_md" "$trial_dir/durable-log.md"
    fi
    return 0
}
