#!/usr/bin/env bash
# Runs the headless flight physics suite.
#   tests/run.sh
# XR is forced off so the Meta simulator does not spin up for a pure physics run.
set -uo pipefail
cd "$(dirname "$0")/.."

output=$(godot --headless --xr-mode off --script res://tests/run_tests.gd 2>&1 \
  | grep -v -E "Meta XR Simulator|^\* daemon|Analytics|remove_tracker|xr_server\.cpp|ObjectDB instance")

echo "$output"
grep -q "ALL PASS" <<<"$output"
