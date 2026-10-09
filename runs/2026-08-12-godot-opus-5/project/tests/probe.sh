#!/usr/bin/env bash
# End-to-end flight probe: flies the real game, real world, real collisions.
#   tests/probe.sh
# --fixed-fps decouples the sim from wall-clock so ~70 s of flight runs in a few.
set -uo pipefail
cd "$(dirname "$0")/.."

output=$(godot --headless --xr-mode off --fixed-fps 90 -- --probe=1 2>&1 \
  | grep -v -E "Meta XR Simulator|^\* daemon|Analytics|remove_tracker|p_tracker.is_null|xr_server\.cpp|ObjectDB|object\.cpp")

echo "$output"
grep -q "PROBE PASS" <<<"$output"
