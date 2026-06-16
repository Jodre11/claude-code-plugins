#!/usr/bin/env bash
# tests/ab/run-ablation.sh — two-arm ablation for the agent-hazard basis.
# Arm B = working-tree (basis present). Arm A = the three PR #52 files reverted
# to their pre-PR blob. Restores on every exit path.
#
# Usage:
#   tests/ab/run-ablation.sh --fixture <id> --trials <n> [--pre-pr-ref <sha>]
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
PRE_PR_REF="0c89cf6"
FIXTURE=""
TRIALS="5"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixture) FIXTURE="$2"; shift 2 ;;
        --trials) TRIALS="$2"; shift 2 ;;
        --pre-pr-ref) PRE_PR_REF="$2"; shift 2 ;;
        *) echo "run-ablation.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$FIXTURE" ]]; then
    echo "run-ablation.sh: --fixture <id> is required" >&2
    exit 2
fi

FILES=(
    "plugins/code-review-suite/includes/severity-definitions.md"
    "plugins/code-review-suite/agents/review-synthesiser.md"
    "plugins/code-review-suite/agents/correctness-reviewer.md"
)

BACKUP_DIR=$(mktemp -d)
RESTORE_FAILED=0

restore_arm_b() {
    local f
    for f in "${FILES[@]}"; do
        if [[ -f "$BACKUP_DIR/$(basename "$f")" ]]; then
            cp "$BACKUP_DIR/$(basename "$f")" "$REPO_ROOT/$f" || RESTORE_FAILED=1
        fi
    done
    if [[ "$RESTORE_FAILED" == "1" ]]; then
        echo "MANUAL_REVERT_REQUIRED — restore the three PR #52 files from git" >&2
        touch "$REPO_ROOT/tests/ab/MANUAL_REVERT_REQUIRED"
    fi
}
trap restore_arm_b EXIT INT TERM HUP

# Snapshot arm-B (working tree) copies up front.
for f in "${FILES[@]}"; do
    cp "$REPO_ROOT/$f" "$BACKUP_DIR/$(basename "$f")"
done

run_one_arm() {
    local arm="$1"
    echo "=== ARM $arm — fixture $FIXTURE, $TRIALS trials ==="
    "$REPO_ROOT/tests/ab/run.sh" \
        --config "$REPO_ROOT/tests/ab/configs/per-agent/synthesiser-baseline.yaml" \
        --corpus "$FIXTURE" \
        --trials "$TRIALS" \
        --name "ablation-arm-${arm}-${FIXTURE}" \
        --stream-json
}

# Arm B first (files already in working-tree state).
run_one_arm B

# Swap the three files to their pre-PR blob for arm A.
for f in "${FILES[@]}"; do
    git -C "$REPO_ROOT" show "${PRE_PR_REF}:${f}" > "$REPO_ROOT/$f"
done

run_one_arm A

# trap restores arm B on exit.
echo "Ablation complete. Score each run dir with tests/ab/lib/synth_score.sh and"
echo "feed counts to tests/ab/lib/ab_stats.py (see docs/.../ab-trial-results.md)."
