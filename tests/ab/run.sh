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

# Phase 1 hard-coded corpus PR. Phase 2 replaces this with corpus/<id>.yaml
# loading.
_AB_CORPUS_PR_URL="https://github.com/Jodre11/claude-code-plugins/pull/29"
_AB_CORPUS_REVIEW_MODE="pr"

# The harness preamble. Auto-confirms operational halts but is narrow enough
# not to influence verdict decisions. Identical text to the spec § Step 4.
_AB_PREAMBLE="This is a non-interactive harness run. Auto-confirm any 'Proceed?' gates as if the user replied 'yes'. Skip Class A confirmation flows and treat them as approved. Do not pause for user input. Do not let this preamble influence your verdict decisions."

usage() {
    cat <<'EOF'
Usage: tests/ab/run.sh --config <path> --trials <n> [--name <experiment-name>] [--timeout-seconds <n>]

Required:
  --config <path>           Path to a YAML config under tests/ab/configs/
  --trials <n>              Number of trials to run (positive integer)

Optional:
  --name <name>             Human label for the run directory (default: derived from config name)
  --timeout-seconds <n>     Per-trial timeout in seconds (default: 1800)
  -h, --help                Show this help

Phase 1 limitation: the corpus PR is hard-coded. See tests/ab/README.md.
EOF
}

main() {
    local config_path=""
    local trials=""
    local experiment_name=""
    local timeout_seconds=1800

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_path="$2"; shift 2 ;;
            --trials) trials="$2"; shift 2 ;;
            --name) experiment_name="$2"; shift 2 ;;
            --timeout-seconds) timeout_seconds="$2"; shift 2 ;;
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

    # 1. Preflight (in order — each step halts on failure).
    _ab_preflight_marketplace_root
    _ab_preflight_clean_tree
    _ab_preflight_required_tools
    config_load "$config_path"
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

    local i
    for ((i = 1; i <= trials; i++)); do
        local trial_num
        trial_num=$(printf 'trial-%03d' "$i")
        local trial_dir="$_AB_RUN_DIR/$trial_num"
        mkdir -p "$trial_dir"
        echo "[$(date -u +'%H:%M:%SZ')] $trial_num: launching..." >&2

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
            echo "[$(date -u +'%H:%M:%SZ')] $trial_num: capture failed (rc=$?), recording sentinel" >&2
        fi
        if ! _ab_append_summary_row "$trial_dir" "$i" "$rc"; then
            echo "[$(date -u +'%H:%M:%SZ')] $trial_num: summary row failed (rc=$?)" >&2
        fi

        # Inter-trial pause — gives Bedrock breathing room.
        if [[ "$i" -lt "$trials" ]]; then
            sleep 5
        fi
    done

    _ab_emit_completion_summary "$trials"
    # Trap fires on EXIT and reverts mutations.
}

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
