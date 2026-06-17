#!/usr/bin/env bash
# tests/ab/run-specialist-ablation.sh — generic single-file two-arm ablation.
# Arm B = working tree (retarget present). Arm A = the named reviewer file
# swapped to its pre-edit git blob (--ref, default HEAD). Restores on every
# exit path. Specialist output is scored post-hoc with
# tests/ab/lib/specialist_score.sh — this runner only produces the run dirs.
#
# Usage:
#   tests/ab/run-specialist-ablation.sh --agent <name> --fixture <id> \
#       --file <repo-relative-path> [--ref <git-ref>] [--trials <n>]
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
AGENT=""
FIXTURE=""
FILE=""
REF="HEAD"
TRIALS="5"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent) AGENT="$2"; shift 2 ;;
        --fixture) FIXTURE="$2"; shift 2 ;;
        --file) FILE="$2"; shift 2 ;;
        --ref) REF="$2"; shift 2 ;;
        --trials) TRIALS="$2"; shift 2 ;;
        *) echo "run-specialist-ablation.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$AGENT" || -z "$FIXTURE" || -z "$FILE" ]]; then
    echo "run-specialist-ablation.sh: --agent, --fixture, and --file are required" >&2
    exit 2
fi

BACKUP=$(mktemp)
RESTORE_FAILED=0
cp "$REPO_ROOT/$FILE" "$BACKUP"

restore_arm_b() {
    if ! cp "$BACKUP" "$REPO_ROOT/$FILE"; then
        RESTORE_FAILED=1
    fi
    if [[ "$RESTORE_FAILED" == "1" ]]; then
        echo "MANUAL_REVERT_REQUIRED — restore $FILE from git" >&2
        touch "$REPO_ROOT/tests/ab/MANUAL_REVERT_REQUIRED"
    fi
}
trap restore_arm_b EXIT INT TERM HUP

run_one_arm() {
    local arm="$1"
    echo "=== ARM $arm — agent $AGENT, fixture $FIXTURE, $TRIALS trials ==="
    "$REPO_ROOT/tests/ab/run.sh" \
        --config "$REPO_ROOT/tests/ab/configs/per-agent/${AGENT%-reviewer}-baseline.yaml" \
        --corpus "$FIXTURE" \
        --trials "$TRIALS" \
        --name "spec-ablation-arm-${arm}-${FIXTURE}" \
        --stream-json
}

# Arm B first (working-tree state = retarget present).
run_one_arm B

# Swap the single file to its pre-edit blob for arm A.
git -C "$REPO_ROOT" show "${REF}:${FILE}" > "$REPO_ROOT/$FILE"
run_one_arm A

# trap restores arm B on exit.
echo "Ablation complete. Score each run dir's trial-NNN/stdout.log with"
echo "tests/ab/lib/specialist_score.sh and feed counts to tests/ab/lib/ab_stats.py."
