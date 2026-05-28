#!/usr/bin/env bash
# tests/ab/lib/agent_capture.sh — ruff-reviewer output parser.
# Sourced by tests/ab/run.sh in --mode per-agent. See full notes below
# set -euo pipefail.
set -euo pipefail

# Public functions implemented in Task 6:
#   agent_capture_parse_ruff_trial <trial-dir>
#     — writes agent-output.md (the ## Ruff Findings block) and findings.json
#       (sorted, normalised tuples) and computes findings_hash for summary.csv
