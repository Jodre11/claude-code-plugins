#!/usr/bin/env bash
# A/B test harness — entry point.
# Runs N trials of one corpus PR under one named config, captures mechanical
# metrics, reverts all in-tree mutations on exit. See tests/ab/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/mutate.sh
source "$SCRIPT_DIR/lib/mutate.sh"
# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"
# shellcheck source=lib/capture.sh
source "$SCRIPT_DIR/lib/capture.sh"
# shellcheck source=lib/agent_dispatch.sh
source "$SCRIPT_DIR/lib/agent_dispatch.sh"
# shellcheck source=lib/fixture.sh
source "$SCRIPT_DIR/lib/fixture.sh"
# shellcheck source=lib/agent_capture.sh
source "$SCRIPT_DIR/lib/agent_capture.sh"
# shellcheck source=lib/orchestration.sh
source "$SCRIPT_DIR/lib/orchestration.sh"

# Phase 1 hard-coded corpus PR. Phase 2 replaces this with corpus/<id>.yaml
# loading.
_AB_CORPUS_PR_URL="https://github.com/Jodre11/claude-code-plugins/pull/29"
_AB_CORPUS_REVIEW_MODE="pr"

# The harness preamble. Auto-confirms operational halts but is narrow enough
# not to influence verdict decisions. Identical text to the spec § Step 4.
_AB_PREAMBLE="This is a non-interactive harness run. Auto-confirm any 'Proceed?' gates as if the user replied 'yes'. Skip Class A confirmation flows and treat them as approved. Do not pause for user input. Do not let this preamble influence your verdict decisions."

# Orchestration-only rider. The review-core Workflow is dispatched to the background;
# under `claude -p` its completion notification has no next turn to land in, so a
# passive 'I'll wait for the notification' ends the turn BEFORE synthesis completes and
# the review-core journal never gains a synthesiser result to harvest (issues #94/#95).
# Instructing the orchestrator to actively poll the workflow to completion keeps the
# `-p` process alive until synthesis lands. This is measurement-safe: it is applied
# identically to both arms and cannot affect review-core's deterministic output — it
# only governs how long the parent stays alive to let that output be produced.
_AB_ORCH_POLL_RIDER="After dispatching the review-core Workflow, do NOT passively wait for a completion notification — it will not arrive in this non-interactive run. Instead, actively poll the Workflow's progress (e.g. read its journal) in a loop until the synthesiser has produced its report, and only then proceed. Keep polling until the review core is fully complete."

usage() {
    cat <<'EOF'
Usage: tests/ab/run.sh --config <path> --trials <n> [options]

Required:
  --config <path>           Path to a YAML config under tests/ab/configs/
  --trials <n>              Number of trials to run (positive integer)

End-to-end mode (--mode end-to-end, default):
  --name <name>             Human label for the run directory
  --timeout-seconds <n>     Per-trial timeout in seconds (default: 1800)

Per-agent mode (--mode per-agent or config-derived):
  --corpus <fixture-id>     Required: id present in tests/ab/corpus/index.yaml
  --faithfulness-check      Phase 2b: load the fixture's captured config and
                            compare the trial's findings against the captured
                            baseline; non-zero exit if they diverge
  --stream-json             Phase 3.1a: capture --output-format stream-json
                            JSONL trace per trial at trial-NNN/stream.jsonl;
                            reconstruct stdout.log from text events
  --include-tag <tag>       Reserved for sweep mode; not implemented in P2
  --exclude-tag <tag>       Reserved for sweep mode; not implemented in P2

Common:
  -h, --help                Show this help

Phase 1 hard-codes the end-to-end corpus PR; per-agent mode resolves
fixtures via tests/ab/corpus/index.yaml. See tests/ab/README.md.
EOF
}

main() {
    local config_path=""
    local trials=""
    local experiment_name=""
    local timeout_seconds=1800
    local corpus_id=""
    local faithfulness_check="false"
    local stream_json="false"
    local _cli_mode=""
    local arms=""
    local phase=""
    local panel_size="3"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_path="$2"; shift 2 ;;
            --trials) trials="$2"; shift 2 ;;
            --name) experiment_name="$2"; shift 2 ;;
            --timeout-seconds) timeout_seconds="$2"; shift 2 ;;
            --corpus) corpus_id="$2"; shift 2 ;;
            --mode) _cli_mode="$2"; shift 2 ;;
            --arms) arms="$2"; shift 2 ;;
            --phase) phase="$2"; shift 2 ;;
            --panel-size) panel_size="$2"; shift 2 ;;
            --faithfulness-check) faithfulness_check="true"; shift ;;
            --stream-json) stream_json="true"; shift ;;
            --include-tag) shift 2 ;;  # reserved; no-op
            --exclude-tag) shift 2 ;;  # reserved; no-op
            -h|--help) usage; exit 0 ;;
            *) echo "unknown arg: $1" >&2; usage >&2; exit 64 ;;
        esac
    done

    local mode="${_cli_mode:-${_AB_CONFIG_MODE:-end-to-end}}"

    # Orchestration mode varies the arm via a temp user-level TOML, not a
    # tracked agent-config frontmatter, so it needs neither --config nor
    # config_load. The other modes still require a config path.
    if [[ "$mode" != "orchestration" && -z "$config_path" ]]; then
        usage >&2
        exit 64
    fi
    if [[ -z "$trials" ]]; then
        usage >&2
        exit 64
    fi
    if ! [[ "$trials" =~ ^[1-9][0-9]*$ ]]; then
        echo "--trials must be a positive integer (got: $trials)" >&2
        exit 64
    fi

    if [[ "$mode" != "orchestration" ]]; then
        config_load "$config_path"
        # config_load may reset mode to the config-derived value; re-resolve so
        # an explicit --mode still wins, then fall back to the config's mode.
        mode="${_cli_mode:-${_AB_CONFIG_MODE:-end-to-end}}"
    fi

    case "$mode" in
        end-to-end)
            _ab_run_end_to_end "$config_path" "$trials" "$experiment_name" "$timeout_seconds"
            ;;
        per-agent)
            if [[ -z "$corpus_id" ]]; then
                echo "run.sh: --corpus <fixture-id> is required for mode: per-agent" >&2
                exit 64
            fi
            _ab_run_per_agent "$config_path" "$trials" "$experiment_name" "$timeout_seconds" "$corpus_id" "$faithfulness_check" "$stream_json"
            ;;
        orchestration)
            if [[ -z "$corpus_id" || -z "$arms" || -z "$phase" ]]; then
                echo "run.sh: --corpus <corpus.yaml> --arms <spec> --phase <pilot|full> required for orchestration" >&2
                exit 64
            fi
            _ab_run_orchestration "$corpus_id" "$arms" "$trials" "$phase" "$panel_size" "$timeout_seconds"
            ;;
        *)
            echo "run.sh: unknown mode: $mode" >&2
            exit 64
            ;;
    esac
}

# ---------------------------------------------------------------------------
# End-to-end mode (Phase 1). Preflight → manifest → mutate → loop → revert.
# ---------------------------------------------------------------------------
_ab_run_end_to_end() {
    local config_path="$1"
    local trials="$2"
    local experiment_name="$3"
    local timeout_seconds="$4"

    # 1. Preflight (in order — each step halts on failure).
    _ab_preflight_marketplace_root
    _ab_preflight_clean_tree
    _ab_preflight_required_tools
    _ab_preflight_corpus_reachable
    launch_preflight_environment

    # 2. Set up run directory and write manifest.
    if [[ -z "$experiment_name" ]]; then
        experiment_name="$_AB_CONFIG_NAME"
    fi
    local timestamp
    timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    _AB_RUN_DIR="$SCRIPT_DIR/runs/${timestamp}-${experiment_name}"
    mkdir -p "$_AB_RUN_DIR"
    _ab_write_manifest "$config_path" "$timestamp" "$experiment_name" "$trials" "$timeout_seconds"

    # 3. Install mutations + revert trap. Trap MUST be installed before
    # mutations are applied so a SIGINT during mutate_apply_config still
    # reverts whatever was already touched.
    mutate_install_revert_trap
    mutate_apply_config

    # Append a record of the active mutations to the manifest.
    git -C "$REPO_ROOT" diff --stat >> "$_AB_RUN_DIR/manifest.yaml"

    # 4. Trial loop.
    local timeout_bin
    timeout_bin=$(launch_resolve_timeout_binary)

    local prompt
    prompt="$_AB_PREAMBLE"$'\n\n'"/review-gh-pr $_AB_CORPUS_PR_URL"

    local summary="$_AB_RUN_DIR/summary.csv"
    echo "trial,exit_code,wall_clock_seconds,verdict,finding_count,report_chars,timed_out" > "$summary"

    # Run-start banner. Wall-clock estimate is empirical (~17-20 min/trial
    # observed against PR #29 in Phase 1).
    local est_min=$((trials * 18 + (trials - 1) * 5 / 60))
    echo "" >&2
    echo "==> A/B harness run starting" >&2
    echo "    Experiment:    $experiment_name" >&2
    echo "    Trials:        $trials (per-trial timeout ${timeout_seconds}s)" >&2
    echo "    Corpus:        $_AB_CORPUS_PR_URL" >&2
    echo "    Session:       model=$_AB_CONFIG_SESSION_MODEL effort=$_AB_CONFIG_SESSION_EFFORT" >&2
    echo "    Mutations:     strip_ultrathink=$_AB_CONFIG_STRIP_ULTRATHINK agent_models='${_AB_CONFIG_AGENT_MODELS:-none}'" >&2
    echo "    Run dir:       $_AB_RUN_DIR" >&2
    echo "    Estimated:     ~${est_min} min wall-clock" >&2
    echo "    Started:       $(date +'%Y-%m-%dT%H:%M:%S%z') (local)" >&2
    echo "" >&2

    local i
    for ((i = 1; i <= trials; i++)); do
        local trial_num
        trial_num=$(printf 'trial-%03d' "$i")
        local trial_dir="$_AB_RUN_DIR/$trial_num"
        mkdir -p "$trial_dir"
        echo "[$(date +'%H:%M:%S')] $trial_num: launching..." >&2

        local rc=0
        launch_run_trial \
            "$trial_dir" \
            "$timeout_seconds" \
            "$_AB_CONFIG_SESSION_MODEL" \
            "$_AB_CONFIG_SESSION_EFFORT" \
            "$prompt" \
            "$timeout_bin" \
            || rc=$?

        # Tolerate per-trial capture/summary failures: a crashed trial must
        # not abort the loop or skip the revert. Log and press on; the
        # sentinel row still lands in summary.csv.
        if ! capture_parse_trial "$trial_dir"; then
            echo "[$(date +'%H:%M:%S')] $trial_num: capture failed (rc=$?), recording sentinel" >&2
        fi
        if ! _ab_append_summary_row "$trial_dir" "$i" "$rc"; then
            echo "[$(date +'%H:%M:%S')] $trial_num: summary row failed (rc=$?)" >&2
        fi

        # Inter-trial pause — gives Bedrock breathing room.
        if [[ "$i" -lt "$trials" ]]; then
            sleep 5
        fi
    done

    _ab_emit_completion_summary "$trials"
    # Trap fires on EXIT and reverts mutations.
}

# ---------------------------------------------------------------------------
# Per-agent mode (Phase 2). Preflight → fixture → materialise → loop → summary.
# ---------------------------------------------------------------------------
_ab_run_per_agent() {
    local config_path="$1"
    local trials="$2"
    local experiment_name="$3"
    local timeout_seconds="$4"
    local corpus_id="$5"
    local faithfulness_check="$6"  # "true" | "false"
    local stream_json="${7:-false}"

    # Preflight: same as end-to-end except no clean-tree check (per-agent
    # never edits tracked files) and we resolve the fixture before going
    # near Bedrock.
    _ab_preflight_marketplace_root
    _ab_preflight_required_tools
    fixture_load "$corpus_id"
    launch_preflight_environment

    # Run dir.
    if [[ -z "$experiment_name" ]]; then
        experiment_name="$_AB_CONFIG_NAME"
    fi
    local timestamp
    timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    _AB_RUN_DIR="$SCRIPT_DIR/runs/${timestamp}-${experiment_name}"
    mkdir -p "$_AB_RUN_DIR"

    # Decay warnings — recorded but warn-only.
    local decay_warnings
    decay_warnings=$(fixture_check_decay || true)

    _ab_write_manifest_per_agent "$config_path" "$timestamp" "$experiment_name" "$trials" "$timeout_seconds" "$corpus_id" "$decay_warnings"

    # Materialise + provision a TEMPLATE once, then give each trial a fresh
    # per-trial copy of the template (Phase 3.2b: hermetic, order-independent
    # trials — no shared mutable working dir, no install race).
    #
    # Base the ephemeral dirs under a /tmp/claude- prefix. CLAUDE_TEMP_DIR is
    # already session-scoped under /tmp/claude-<id>/; when it is unset (the
    # harness shell does not export it) fall back to a /tmp/claude-ab-<ts> dir
    # rather than bare /tmp. This keeps the trial working dir inside the
    # operator's hook-exempt /tmp/claude-* namespace — a dispatched agent that
    # invokes a tool with the ABSOLUTE trial path (e.g.
    # `jb inspectcode /private/tmp/.../foo.sln`) must not trip the global
    # bash-guard temp-path policy that denies bare /tmp/ writes. Without this,
    # whether a trial is denied depends on whether the model happened to use a
    # relative or absolute path — a non-deterministic apparatus confound that
    # mis-scores as an agent-side skip (Phase 3.4 jbinspect fix-validation
    # trial 8).
    local tmp_base="${CLAUDE_TEMP_DIR:-/tmp/claude-ab-${timestamp}}"
    mkdir -p "$tmp_base"
    local template_dir="${tmp_base}/per-agent-${timestamp}-template"
    fixture_materialise "$template_dir"
    fixture_run_setup "$template_dir"
    local trials_root="${tmp_base}/per-agent-${timestamp}-trials"
    mkdir -p "$trials_root"
    # Remove the fallback base dir on exit too, but only when WE created it
    # (CLAUDE_TEMP_DIR unset). When CLAUDE_TEMP_DIR is set, tmp_base IS the
    # session dir and must be left intact. rmdir (not rm -rf) so a non-empty
    # session dir is never clobbered.
    local tmp_base_cleanup=""
    if [[ -z "${CLAUDE_TEMP_DIR:-}" ]]; then
        tmp_base_cleanup="rmdir '$tmp_base' 2>/dev/null || true"
    fi
    trap "fixture_cleanup '$template_dir'; rm -rf '$trials_root'; ${tmp_base_cleanup:-true}" EXIT

    local timeout_bin
    timeout_bin=$(launch_resolve_timeout_binary)

    local summary="$_AB_RUN_DIR/summary.csv"
    echo "trial,exit_code,wall_clock_seconds,findings_count,findings_hash,first_finding_rule,inconclusive,timed_out,output_tokens,num_turns,cache_read_input_tokens,total_cost_usd" > "$summary"

    local i
    for ((i = 1; i <= trials; i++)); do
        local trial_num
        trial_num=$(printf 'trial-%03d' "$i")
        local trial_dir="$_AB_RUN_DIR/$trial_num"
        mkdir -p "$trial_dir"
        local trial_work="$trials_root/$trial_num"
        mkdir -p "$trial_work"
        cp -R "$template_dir/." "$trial_work/"
        echo "[$(date +'%H:%M:%S')] $trial_num: launching..." >&2

        local rc=0
        agent_dispatch_run_trial \
            "$trial_dir" \
            "$_AB_CONFIG_AGENT" \
            "$_AB_FIXTURE_DIR" \
            "$_AB_CONFIG_SESSION_MODEL" \
            "$_AB_CONFIG_SESSION_EFFORT" \
            "$timeout_bin" \
            "$timeout_seconds" \
            "$trial_work" \
            "$stream_json" \
            || rc=$?

        case "$_AB_CONFIG_AGENT" in
            ruff-reviewer|eslint-reviewer|trivy-reviewer|jbinspect-reviewer|housekeeper-reviewer)
                agent_capture_parse_trial "$_AB_CONFIG_AGENT" "$trial_dir"
                ;;
            *)
                # Judgement specialists (correctness/reuse/style) and the
                # synthesiser emit no `rule_id`; the static parser would drop
                # every finding. They are scored post-hoc — the synthesiser by
                # tests/ab/lib/synth_score.sh, the specialists by
                # tests/ab/lib/specialist_score.sh — against stdout.log. Write
                # the minimal artefacts the summary row consumes.
                printf '[]\n' > "$trial_dir/findings.json"
                printf '%s\n' "$_AB_CONFIG_AGENT" > "$trial_dir/findings_hash.txt"
                ;;
        esac
        _ab_append_per_agent_summary_row "$trial_dir" "$i" "$rc"

        if [[ "$i" -lt "$trials" ]]; then
            sleep 5
        fi
    done

    _ab_emit_completion_summary "$trials"

    if [[ "$faithfulness_check" == "true" ]]; then
        local baseline="$_AB_FIXTURE_DIR/expected/findings.json"
        # Convert the captured agent-output.md to a normalised findings.json
        # one-shot if not already present (older fixtures store only the
        # markdown). The helper does this idempotently.
        if [[ ! -f "$baseline" ]]; then
            # The expected-markdown filename uses the short tool key
            # (findings-ruff.md, findings-eslint.md), while $_AB_CONFIG_AGENT
            # carries the full `<tool>-reviewer` name — strip the suffix.
            local agent_key="${_AB_CONFIG_AGENT%-reviewer}"
            local md="$_AB_FIXTURE_DIR/expected/findings-$agent_key.md"
            if [[ ! -f "$md" ]]; then
                echo "run.sh: $md: not found; cannot run faithfulness check" >&2
                exit 1
            fi
            local synth_dir
            synth_dir=$(mktemp -d)
            cp "$md" "$synth_dir/stdout.log"
            agent_capture_parse_trial "$_AB_CONFIG_AGENT" "$synth_dir"
            cp "$synth_dir/findings.json" "$baseline"
            rm -rf "$synth_dir"
        fi

        local fail_count=0
        for ((i = 1; i <= trials; i++)); do
            local trial_num
            trial_num=$(printf 'trial-%03d' "$i")
            local trial_dir="$_AB_RUN_DIR/$trial_num"
            if ! agent_capture_compare_findings "$baseline" "$trial_dir/findings.json" 2> "$trial_dir/faithfulness.diff"; then
                fail_count=$((fail_count + 1))
            fi
        done

        if [[ "$fail_count" -gt 0 ]]; then
            echo "run.sh: faithfulness check FAILED on $fail_count of $trials trials" >&2
            exit 1
        fi
        echo "run.sh: faithfulness check PASSED ($trials/$trials trials matched)" >&2
    fi
}

# ---------------------------------------------------------------------------
# Orchestration mode (Phase 2, spec §"Panel-vs-classic A/B"). Iterates the
# corpus PRs × arms × trials, toggling the panel/classic arm via a temp
# user-level code-review.toml, and harvests the durable orchestration log per
# trial. Unlike the other modes, the arm difference is entirely in the TOML
# toggle — model/effort are the production session defaults so both arms run
# exactly as a real /review-gh-pr would.
# ---------------------------------------------------------------------------
_ab_run_orchestration() {
    local corpus_yaml="$1" arms_spec="$2" trials="$3" phase="$4" default_panel="$5" timeout_seconds="$6"

    _ab_preflight_marketplace_root
    _ab_preflight_required_tools
    [[ -f "$corpus_yaml" ]] || { echo "run.sh: corpus.yaml not found: $corpus_yaml" >&2; exit 1; }

    local timestamp; timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    _AB_RUN_DIR="$SCRIPT_DIR/runs/${timestamp}-orchestration-${phase}"
    mkdir -p "$_AB_RUN_DIR"
    cp "$corpus_yaml" "$_AB_RUN_DIR/corpus.yaml"

    echo "==> orchestration A/B: phase=$phase arms='$arms_spec' trials=$trials" >&2
    echo "    Run dir: $_AB_RUN_DIR" >&2

    if [[ "${_AB_ORCH_DRYRUN:-0}" == "1" ]]; then
        return 0    # test hook: scaffold only, no Bedrock
    fi

    # Pre-registration criteria: the operator places criteria.md at $_AB_RUN_DIR/criteria.md
    # or $CLAUDE_TEMP_DIR/criteria.md BEFORE any run; this call refuses to proceed without it
    # and mirrors it to the durable honesty-anchor location (survives run-dir prune).
    _ab_orch_capture_criteria "$phase" "$timestamp"

    launch_preflight_environment
    local timeout_bin; timeout_bin=$(launch_resolve_timeout_binary)
    local logs_root="$HOME/.claude/code-review-suite/logs"

    # Iterate PRs from corpus.yaml.
    local n_prs; n_prs=$(yq '.prs | length' "$_AB_RUN_DIR/corpus.yaml")
    local pi
    for ((pi = 0; pi < n_prs; pi++)); do
        local url head_sha
        url=$(yq -r ".prs[$pi].url" "$_AB_RUN_DIR/corpus.yaml")
        head_sha=$(yq -r ".prs[$pi].head_sha" "$_AB_RUN_DIR/corpus.yaml")
        local slug ident pr_slug
        slug=$(orchestration_slug_from_url "$url")
        ident=$(orchestration_ident_from_url "$url")
        pr_slug="${slug}-${ident}"

        _ab_orch_preflight_no_repo_override "$url"   # disqualify repo-level orchestration.* (spec step 2)
        _ab_orch_preflight_merged "$url"             # confirm MERGED so §B.1 no-post holds

        local arm_spec
        for arm_spec in $arms_spec; do
            local arm psize
            arm="${arm_spec%%:*}"
            psize="$default_panel"
            [[ "$arm_spec" == *:* ]] && psize="${arm_spec#*:}"

            orchestration_install_restore_trap
            orchestration_apply_arm "$arm" "$psize" "$HOME/.claude/code-review.toml"

            local prompt; prompt="$_AB_PREAMBLE"$'\n\n'"$_AB_ORCH_POLL_RIDER"$'\n\n'"/review-gh-pr $url"
            local i
            for ((i = 1; i <= trials; i++)); do
                local trial_dir; trial_dir=$(printf '%s/%s/%s/trial-%03d' "$_AB_RUN_DIR" "$pr_slug" "$arm" "$i")
                mkdir -p "$trial_dir"
                local rc=0
                _ab_orch_launch_trial "$trial_dir" "$timeout_seconds" "$prompt" "$timeout_bin" || rc=$?
                capture_parse_trial "$trial_dir" || true
                # Prefer the on-disk durable log (orchestrator Step 3.6). Under
                # `claude -p` that write never fires (issues #94/#95), so fall back to
                # harvesting review-core's output directly from its Workflow journal.
                # Only a genuine miss on BOTH paths records HARVEST_MISS.
                orchestration_harvest "$trial_dir" "$logs_root" "$slug" "$ident" "$head_sha" \
                    || orchestration_harvest_journal "$trial_dir" "$HOME/.claude/projects" \
                    || : > "$trial_dir/HARVEST_MISS"
                [[ "$i" -lt "$trials" ]] && sleep 5
            done

            orchestration_restore_arm
            trap - EXIT INT TERM HUP
        done
    done

    if [[ "$phase" == "pilot" ]]; then
        _ab_orch_pilot_gate "$_AB_RUN_DIR"
    fi

    echo "Run complete: $_AB_RUN_DIR" >&2
}

# Thin orchestration trial launcher. Mirrors launch_run_trial but runs in
# --output-format stream-json --verbose mode (the mechanism
# launch_run_per_agent_trial uses): fd 1 is the JSONL trace, captured to
# stream.jsonl, from which stdout.log is reconstructed via
# launch_jq_reduce_stream_jsonl so the cost model has the stream and the
# verdict parser has the text. Model/effort are intentionally NOT passed —
# orchestration uses the production session defaults; the arm difference lives
# entirely in the TOML toggle.
_ab_orch_launch_trial() {
    local trial_dir="$1" timeout_seconds="$2" prompt="$3" timeout_bin="$4"
    local stream_jsonl="$trial_dir/stream.jsonl" stdout="$trial_dir/stdout.log"
    local stderr="$trial_dir/stderr.log" timing="$trial_dir/timing.json"
    local start_iso; start_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); local start=$SECONDS

    # Heartbeat: emit elapsed-time updates to stderr every 60s while the trial
    # runs, so a long orchestration trial is observable. Mirrors the sibling
    # launch_run_per_agent_trial. Killed in a trap when the trial returns or the
    # harness is interrupted.
    (
        hb_elapsed=0
        while sleep 60; do
            hb_elapsed=$((hb_elapsed + 60))
            echo "[$(date +'%H:%M:%S')] $(basename "$trial_dir"): still running (${hb_elapsed}s elapsed)" >&2
        done
    ) &
    local hb_pid=$!
    trap 'kill -TERM "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true' RETURN

    local rc=0
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0 \
    "$timeout_bin" --foreground --signal=TERM --kill-after=30 "$timeout_seconds" \
        command claude -p --permission-mode bypassPermissions \
            --output-format stream-json --verbose \
            --exclude-dynamic-system-prompt-sections "$prompt" \
        > "$stream_jsonl" 2> "$stderr" || rc=$?

    kill -TERM "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
    trap - RETURN

    launch_jq_reduce_stream_jsonl "$stream_jsonl" "$stdout"
    local elapsed=$((SECONDS - start)); local timed_out=false
    [[ "$rc" == "124" ]] && timed_out=true
    jq -n --arg s "$start_iso" --arg e "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --argjson el "$elapsed" --argjson rc "$rc" --arg to "$timed_out" \
        '{start:$s,end:$e,wall_clock_seconds:$el,exit_code:$rc,timed_out:($to=="true")}' > "$timing"
    return "$rc"
}

_ab_orch_capture_criteria() {
    local phase="$1" timestamp="$2"
    local src=""
    if [[ -f "$_AB_RUN_DIR/criteria.md" ]]; then
        src="$_AB_RUN_DIR/criteria.md"
    elif [[ -n "${CLAUDE_TEMP_DIR:-}" && -f "$CLAUDE_TEMP_DIR/criteria.md" ]]; then
        src="$CLAUDE_TEMP_DIR/criteria.md"
        cp "$src" "$_AB_RUN_DIR/criteria.md"
    fi
    if [[ -z "$src" ]]; then
        echo "orchestration: NO pre-registration criteria.md found." >&2
        echo "  Write your 'what is a better review' criteria to $_AB_RUN_DIR/criteria.md" >&2
        echo "  BEFORE any run — it is the timestamped honesty anchor. Refusing to proceed." >&2
        exit 1
    fi
    # Mirror to a durable location outside the run dir (survives scratch prune).
    local anchor_dir="$HOME/.claude/code-review-suite/ab-criteria"
    mkdir -p "$anchor_dir"
    cp "$_AB_RUN_DIR/criteria.md" "$anchor_dir/${timestamp}-${phase}-criteria.md"
}

_ab_orch_pilot_gate() {
    local run_dir="$1"
    local log="$run_dir/pilot-gate.log"
    local diff_json="$run_dir/differential.json"

    # differential.py can throw (e.g. malformed harvested JSONL in json.loads).
    # Capture its rc rather than letting set -e abort the gate before it logs —
    # the gate's contract is to ALWAYS record the path taken to pilot-gate.log.
    local diff_rc=0
    python3 "$SCRIPT_DIR/lib/differential.py" --run-dir "$run_dir" --out "$diff_json" >/dev/null 2>&1 \
        || diff_rc=$?
    if [[ "$diff_rc" != "0" ]]; then
        {
            echo "HARD-STOP"
            echo "reason: differential.py failed (exit $diff_rc) — likely malformed harvested JSONL"
            echo "action: maintainer review harvested durable-log.jsonl files before Phase B"
        } > "$log"
        cat "$log" >&2
        return 0
    fi

    local min_stab; min_stab=$(jq -r '[.prs[].within_arm_stability] | min // 0' "$diff_json")
    local harvest_misses; harvest_misses=$(find "$run_dir" -name HARVEST_MISS | wc -l | tr -d ' ')

    # bash has no float compare; use awk. Threshold 0.8.
    local stable; stable=$(awk -v s="$min_stab" 'BEGIN{print (s>=0.8)?"1":"0"}')
    if [[ "$stable" == "1" && "$harvest_misses" == "0" ]]; then
        {
            echo "AUTO-PROCEED"
            echo "reason: min within-arm stability=$min_stab (>=0.8), harvest_misses=0"
            echo "next: size Phase B N from observed variance (higher noise -> more runs/arm)"
        } > "$log"
    else
        {
            echo "HARD-STOP"
            echo "reason: min within-arm stability=$min_stab (need >=0.8), harvest_misses=$harvest_misses"
            echo "action: maintainer review before Phase B — check blinding held + harvest complete"
        } > "$log"
    fi
    cat "$log" >&2
}

_ab_orch_preflight_merged() {
    local url="$1" state
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null || echo UNKNOWN)
    if [[ "$state" != "MERGED" ]]; then
        echo "orchestration: corpus PR not MERGED ($state) — §B.1 no-post safety not guaranteed: $url" >&2
        exit 1
    fi
}

_ab_orch_preflight_no_repo_override() {
    local url="$1"
    # A repo-level .claude/code-review.toml [orchestration] key would win over our
    # user-level temp toggle (SKILL.md:1035-1040). We cannot cheaply inspect the
    # remote repo's working tree here, so this is a RECORDED WARNING the operator
    # must clear when selecting the SHA (spec step 2). Log it; do not hard-fail.
    echo "orchestration: confirm $url's repo sets no [orchestration] key at repo layer (spec corpus step 2)" >&2
}

# ---------------------------------------------------------------------------
# Preflight helpers (shared by both modes).
# ---------------------------------------------------------------------------
_ab_preflight_marketplace_root() {
    if [[ ! -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]]; then
        echo "preflight: not at marketplace root (expected $REPO_ROOT/.claude-plugin/marketplace.json)" >&2
        exit 1
    fi
}

_ab_preflight_clean_tree() {
    if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
        echo "preflight: working tree is dirty — refusing to start (mutations + dirty tree = unsafe revert)" >&2
        exit 1
    fi
}

_ab_preflight_required_tools() {
    local tool missing=()
    for tool in yq jq gh git; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        missing+=("timeout (or gtimeout via Homebrew coreutils on macOS)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "preflight: missing required tools: ${missing[*]}" >&2
        exit 1
    fi
}

_ab_preflight_corpus_reachable() {
    if ! gh pr view "$_AB_CORPUS_PR_URL" --json state >/dev/null 2>&1; then
        echo "preflight: corpus PR not reachable: $_AB_CORPUS_PR_URL" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Manifest writers.
# ---------------------------------------------------------------------------
_ab_write_manifest() {
    local config_path="$1"
    local timestamp="$2"
    local experiment_name="$3"
    local trials="$4"
    local timeout_seconds="$5"

    local config_sha
    config_sha=$(shasum -a 256 "$config_path" | awk '{print $1}')

    local suite_sha
    suite_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)

    local hostname
    hostname=$(hostname)

    cat > "$_AB_RUN_DIR/manifest.yaml" <<EOF
experiment_name: $experiment_name
timestamp: $timestamp
trials: $trials
timeout_seconds: $timeout_seconds
config:
  path: ${config_path#"$REPO_ROOT/"}
  sha256: $config_sha
  name: $_AB_CONFIG_NAME
  description: $_AB_CONFIG_DESCRIPTION
corpus:
  pr_url: $_AB_CORPUS_PR_URL
  review_mode: $_AB_CORPUS_REVIEW_MODE
suite_git_sha: $suite_sha
host: $hostname
session:
  model: $_AB_CONFIG_SESSION_MODEL
  effort: $_AB_CONFIG_SESSION_EFFORT
mutations:
  strip_ultrathink: $_AB_CONFIG_STRIP_ULTRATHINK
  agent_models: "$_AB_CONFIG_AGENT_MODELS"

# git diff --stat after mutations applied:
EOF
}

_ab_write_manifest_per_agent() {
    local config_path="$1"
    local timestamp="$2"
    local experiment_name="$3"
    local trials="$4"
    local timeout_seconds="$5"
    local corpus_id="$6"
    local decay_warnings="$7"

    local config_sha source_yaml_sha suite_sha hostname
    config_sha=$(shasum -a 256 "$config_path" | awk '{print $1}')
    source_yaml_sha=$(shasum -a 256 "$_AB_FIXTURE_SOURCE_YAML" | awk '{print $1}')
    suite_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    hostname=$(hostname)

    {
        echo "mode: per-agent"
        echo "experiment_name: $experiment_name"
        echo "timestamp: $timestamp"
        echo "trials: $trials"
        echo "timeout_seconds: $timeout_seconds"
        echo "config:"
        echo "  path: ${config_path#"$REPO_ROOT/"}"
        echo "  sha256: $config_sha"
        echo "  name: $_AB_CONFIG_NAME"
        echo "fixture:"
        echo "  id: $corpus_id"
        echo "  source_yaml_sha256: $source_yaml_sha"
        if [[ -n "$decay_warnings" ]]; then
            echo "  decay_warnings:"
            while IFS= read -r warn; do
                [[ -z "$warn" ]] && continue
                echo "    - \"$warn\""
            done <<< "$decay_warnings"
        else
            echo "  decay_warnings: []"
        fi
        echo "agent_under_test: $_AB_CONFIG_AGENT"
        echo "suite_git_sha: $suite_sha"
        echo "host: $hostname"
        echo "session:"
        echo "  model: $_AB_CONFIG_SESSION_MODEL"
        echo "  effort: $_AB_CONFIG_SESSION_EFFORT"
    } > "$_AB_RUN_DIR/manifest.yaml"
}

# ---------------------------------------------------------------------------
# Summary row appenders.
# ---------------------------------------------------------------------------
_ab_append_summary_row() {
    local trial_dir="$1"
    local trial_num="$2"
    local rc="$3"

    # Sentinel defaults for crashed trials with missing artefacts. -1 makes
    # post-hoc filtering trivial; CAPTURE_FAILED never collides with the three
    # legal verdicts (APPROVE | REQUEST_CHANGES | INCONCLUSIVE).
    local wall=-1 verdict="CAPTURE_FAILED" findings=-1 chars=-1 timed_out="false"
    if [[ -f "$trial_dir/timing.json" ]]; then
        wall=$(jq -r '.wall_clock_seconds // -1' "$trial_dir/timing.json" 2>/dev/null || echo -1)
        timed_out=$(jq -r '.timed_out // false' "$trial_dir/timing.json" 2>/dev/null || echo false)
    fi
    if [[ -f "$trial_dir/verdict.txt" ]]; then
        verdict=$(cat "$trial_dir/verdict.txt")
    fi
    if [[ -f "$trial_dir/report-stats.json" ]]; then
        findings=$(jq -r '.finding_count // -1' "$trial_dir/report-stats.json" 2>/dev/null || echo -1)
        chars=$(jq -r '.report_chars // -1' "$trial_dir/report-stats.json" 2>/dev/null || echo -1)
    fi

    printf '%d,%d,%d,%s,%d,%d,%s\n' \
        "$trial_num" "$rc" "$wall" "$verdict" "$findings" "$chars" "$timed_out" \
        >> "$_AB_RUN_DIR/summary.csv"
}

_ab_append_per_agent_summary_row() {
    local trial_dir="$1"
    local trial_num="$2"
    local rc="$3"

    local wall timed_out findings_count findings_hash first_rule inconclusive
    wall=$(jq -r '.wall_clock_seconds' "$trial_dir/timing.json")
    timed_out=$(jq -r '.timed_out' "$trial_dir/timing.json")
    findings_count=$(jq -r 'length' "$trial_dir/findings.json")
    findings_hash=$(cat "$trial_dir/findings_hash.txt")
    first_rule=$(jq -r 'if length > 0 then .[0].rule_id else "" end' "$trial_dir/findings.json")
    if [[ -f "$trial_dir/INCONCLUSIVE" ]]; then
        inconclusive="true"
    else
        inconclusive="false"
    fi

    local cost_csv
    cost_csv=$(agent_capture_extract_cost_csv "$trial_dir/stream.jsonl")

    printf '%d,%d,%d,%d,%s,%s,%s,%s,%s\n' \
        "$trial_num" "$rc" "$wall" "$findings_count" "$findings_hash" "$first_rule" "$inconclusive" "$timed_out" "$cost_csv" \
        >> "$_AB_RUN_DIR/summary.csv"
}

# ---------------------------------------------------------------------------
# Completion summary (shared by both modes).
# ---------------------------------------------------------------------------
_ab_emit_completion_summary() {
    local trials="$1"
    local summary="$_AB_RUN_DIR/summary.csv"

    # Resolve the timed_out column by header name rather than a fixed index:
    # this function is shared by both modes, whose schemas place timed_out in
    # different positions (orchestrator col 7, per-agent col 8). exit_code is
    # column 2 in both schemas, so a fixed index is safe there.
    local succeeded timeouts
    succeeded=$(awk -F, 'NR>1 && $2==0 {n++} END {print n+0}' "$summary")
    timeouts=$(awk -F, 'NR==1 {for (i=1; i<=NF; i++) if ($i=="timed_out") c=i; next} c && $c=="true" {n++} END {print n+0}' "$summary")

    local mean_wall
    mean_wall=$(awk -F, 'NR>1 {s+=$3; n++} END {if (n>0) printf "%d", s/n; else print 0}' "$summary")

    echo "Run complete: ${succeeded}/${trials} trials, ${timeouts} timeouts, mean ${mean_wall}s. Output: $_AB_RUN_DIR" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
