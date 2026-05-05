#!/usr/bin/env bash
# Run all structural tests for the plugin marketplace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/harness.sh"

for test_file in "$SCRIPT_DIR"/lib/test_*.sh; do
    source "$test_file"
done

# Discover and run all test_ functions
mapfile -t test_functions < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

for fn in "${test_functions[@]}"; do
    # Section header from function name: test_foo_bar → foo bar
    section="${fn#test_}"
    section="${section//_/ }"
    printf '\n\033[1m%s\033[0m\n' "$section"
    "$fn"
done

summary
