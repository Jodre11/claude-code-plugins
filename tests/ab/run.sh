#!/usr/bin/env bash
# A/B test harness — entry point.
# Runs N trials of one agent against one corpus fixture under one named
# config, captures mechanical metrics per trial. See tests/ab/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"
# shellcheck source=lib/agent_dispatch.sh
source "$SCRIPT_DIR/lib/agent_dispatch.sh"
# shellcheck source=lib/fixture.sh
source "$SCRIPT_DIR/lib/fixture.sh"
# shellcheck source=lib/agent_capture.sh
source "$SCRIPT_DIR/lib/agent_capture.sh"

usage() {
    cat <<'EOF'
Usage: tests/ab/run.sh --config <path> --corpus <fixture-id> --trials <n> [options]

Required:
  --config <path>           Path to a YAML config under tests/ab/configs/per-agent/
  --corpus <fixture-id>     Id present in tests/ab/corpus/index.yaml
  --trials <n>              Number of trials to run (positive integer)

Options:
  --name <name>             Human label for the run directory
  --timeout-seconds <n>     Per-trial timeout in seconds (default: 1800)
  --faithfulness-check      Phase 2b: load the fixture's captured config and
                            compare the trial's findings against the captured
                            baseline; non-zero exit if they diverge
  --stream-json             Phase 3.1a: capture --output-format stream-json
                            JSONL trace per trial at trial-NNN/stream.jsonl;
                            reconstruct stdout.log from text events
  --include-tag <tag>       Reserved for sweep mode; not implemented in P2
  --exclude-tag <tag>       Reserved for sweep mode; not implemented in P2
  -h, --help                Show this help

Fixtures resolve via tests/ab/corpus/index.yaml. See tests/ab/README.md.
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

    if [[ -z "$corpus_id" ]]; then
        echo "run.sh: --corpus <fixture-id> is required" >&2
        exit 64
    fi
    _ab_run_per_agent "$config_path" "$trials" "$experiment_name" "$timeout_seconds" "$corpus_id" "$faithfulness_check" "$stream_json"
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

    # Preflight: no clean-tree check (per-agent never edits tracked files),
    # and we resolve the fixture before going near Bedrock.
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
                # Judgement specialists (correctness/reuse/style/...) emit no
                # `rule_id`; the static parser would drop every finding. They
                # are scored post-hoc by tests/ab/lib/specialist_score.sh
                # against stdout.log. Write the minimal artefacts the summary
                # row consumes.
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
            local parse_dir
            parse_dir=$(mktemp -d)
            cp "$md" "$parse_dir/stdout.log"
            agent_capture_parse_trial "$_AB_CONFIG_AGENT" "$parse_dir"
            cp "$parse_dir/findings.json" "$baseline"
            rm -rf "$parse_dir"
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
# Preflight helpers.
# ---------------------------------------------------------------------------
_ab_preflight_marketplace_root() {
    if [[ ! -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]]; then
        echo "preflight: not at marketplace root (expected $REPO_ROOT/.claude-plugin/marketplace.json)" >&2
        exit 1
    fi
}

_ab_preflight_required_tools() {
    local tool missing=()
    for tool in yq jq git; do
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

# ---------------------------------------------------------------------------
# Manifest writer.
# ---------------------------------------------------------------------------
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
# Summary row appender.
# ---------------------------------------------------------------------------
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
# Completion summary.
# ---------------------------------------------------------------------------
_ab_emit_completion_summary() {
    local trials="$1"
    local summary="$_AB_RUN_DIR/summary.csv"

    # Resolve the timed_out column by header name rather than a fixed index,
    # so a schema change to summary.csv cannot silently miscount timeouts.
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
