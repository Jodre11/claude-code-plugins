#!/usr/bin/env bash
# tests/ab/lib/fixture.sh — fixture loader, working-dir materialiser, decay-warner.
# Sourced by tests/ab/run.sh in --mode per-agent. See full notes below
# set -euo pipefail.
set -euo pipefail

# Public functions implemented in Task 5:
#   fixture_load <fixture-id>                # validates source.yaml, populates _AB_FIXTURE_*
#   fixture_materialise <out-dir>            # produces working tree per working_dir_strategy
#   fixture_check_decay                      # returns warnings array; non-fatal
