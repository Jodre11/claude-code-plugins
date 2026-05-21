#!/usr/bin/env bash
# A/B test harness — entry point.
# Runs N trials of one corpus PR under one named config, captures mechanical
# metrics, reverts all in-tree mutations on exit. See tests/ab/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/config.sh
# shellcheck source=lib/mutate.sh
# shellcheck source=lib/launch.sh
# shellcheck source=lib/capture.sh

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
    # Filled in by later tasks. For now, fail loudly so the scaffold cannot be
    # accidentally invoked as if implemented.
    echo "tests/ab/run.sh: not yet implemented (scaffold only)" >&2
    exit 64  # EX_USAGE
}

main "$@"
