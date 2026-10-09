#!/usr/bin/env bash
# Headless suites. XR is forced off so the simulator does not spin up.
#   tests/run.sh            all suites
#   tests/run.sh flight     one suite
set -uo pipefail
cd "$(dirname "$0")/.."
only=""
[ $# -gt 0 ] && only="-- --only=$1"
output=$(godot --headless --xr-mode off --script res://tests/run_tests.gd $only 2>&1 \
  | grep -v -E "Meta XR Simulator|Analytics|remove_tracker|p_tracker.is_null|xr_server\.cpp|ObjectDB instance|^\s*$|crash info version|mach_o_image")
echo "$output"
grep -q "ALL PASS" <<<"$output"
