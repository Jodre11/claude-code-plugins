#!/usr/bin/env bash
# tests/ab/lib/agent_dispatch.sh — per-agent prompt reconstruction.
# Sourced by tests/ab/run.sh in --mode per-agent. See full notes below
# set -euo pipefail.
set -euo pipefail

# Public functions implemented in Task 4:
#   agent_dispatch_strip_frontmatter <agent-md-path> <out-path>
#   agent_dispatch_build_user_message <fixture-dir> <out-path>
#   agent_dispatch_run_trial <trial-dir> <agent-name> <fixture-dir> <model> <effort> <timeout-bin> <timeout-seconds> <working-dir>
