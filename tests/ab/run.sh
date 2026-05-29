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

# Phase 1 hard-coded corpus PR. Phase 2 replaces this with corpus/<id>.yaml
# loading.
_AB_CORPUS_PR_URL="https://github.com/Jodre11/claude-code-plugins/pull/29"
_AB_CORPUS_REVIEW_MODE="pr"

# The harness preamble. Auto-confirms operational halts but is narrow enough
# not to influence verdict decisions. Identical text to the spec § Step 4.
_AB_PREAMBLE="This is a non-interactive harness run. Auto-confirm any 'Proceed?' gates as if the user replied 'yes'. Skip Class A confirmation flows and treat them as approved. Do not pause for user input. Do not let this preamble influence your verdict decisions."

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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_path="$2"; shift 2 ;;
            --trials) trials="$2"; shift 2 ;;
            --name) experiment_name="$2"; shift 2 ;;
            --timeout-seconds) timeout_seconds="$2"; shift 2 ;;
            --corpus) corpus_id="$2"; shift 2 ;;
            --faithfulness-check) faithfulness_check="true"; shift ;;
            --stream-json) stream_json="true"; shift ;;
            --include-tag) shift 2 ;;  # reserved; no-op
            --exclude-tag) shift 2 ;;  # reserved; no-op
            -h|--help) usage; exit 0 ;;
            *) echo "unknown arg: $1" >&2; usage >&2; exit 64 ;;
        esac
    done

    if [[ -z "$config_path" || -z "$trials" ]]; then
        usage >&2
        exit 64
    fi
    if ! [[ "$trials" =~ ^[1-9][0-9]*$ ]]; then
        echo "--trials must be a positive integer (got: $trials)" >&2
        exit 64
    fi

    config_load "$config_path"

    case "${_AB_CONFIG_MODE:-end-to-end}" in
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

    # Materialise the working dir once and reuse across trials.
    local working_dir="${CLAUDE_TEMP_DIR:-/tmp}/per-agent-${timestamp}"
    fixture_materialise "$working_dir"
    trap "fixture_cleanup '$working_dir'" EXIT

    local timeout_bin
    timeout_bin=$(launch_resolve_timeout_binary)

    local summary="$_AB_RUN_DIR/summary.csv"
    echo "trial,exit_code,wall_clock_seconds,findings_count,findings_hash,first_finding_rule,inconclusive,timed_out" > "$summary"

    local i
    for ((i = 1; i <= trials; i++)); do
        local trial_num
        trial_num=$(printf 'trial-%03d' "$i")
        local trial_dir="$_AB_RUN_DIR/$trial_num"
        mkdir -p "$trial_dir"
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
            "$working_dir" \
            "$stream_json" \
            || rc=$?

        agent_capture_parse_ruff_trial "$trial_dir"
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
            local md="$_AB_FIXTURE_DIR/expected/findings-ruff.md"
            if [[ ! -f "$md" ]]; then
                echo "run.sh: $md: not found; cannot run faithfulness check" >&2
                exit 1
            fi
            local synth_dir
            synth_dir=$(mktemp -d)
            cp "$md" "$synth_dir/stdout.log"
            agent_capture_parse_ruff_trial "$synth_dir"
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

    printf '%d,%d,%d,%d,%s,%s,%s,%s\n' \
        "$trial_num" "$rc" "$wall" "$findings_count" "$findings_hash" "$first_rule" "$inconclusive" "$timed_out" \
        >> "$_AB_RUN_DIR/summary.csv"
}

# ---------------------------------------------------------------------------
# Completion summary (shared by both modes).
# ---------------------------------------------------------------------------
_ab_emit_completion_summary() {
    local trials="$1"
    local summary="$_AB_RUN_DIR/summary.csv"

    local succeeded timeouts
    succeeded=$(awk -F, 'NR>1 && $2==0 {n++} END {print n+0}' "$summary")
    timeouts=$(awk -F, 'NR>1 && $7=="true" {n++} END {print n+0}' "$summary")

    local mean_wall
    mean_wall=$(awk -F, 'NR>1 {s+=$3; n++} END {if (n>0) printf "%d", s/n; else print 0}' "$summary")

    echo "Run complete: ${succeeded}/${trials} trials, ${timeouts} timeouts, mean ${mean_wall}s. Output: $_AB_RUN_DIR" >&2
}

main "$@"
