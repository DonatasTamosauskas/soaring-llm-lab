#!/usr/bin/env bash
# End-to-end menu probe: opens the real menu in the real game and presses it.
#   tests/ui.sh
# Checks the things only a scene tree can answer — that the game opens on a
# menu, that pausing genuinely stops the world, that a comfort setting reaches
# Tuning, and that FLY AGAIN starts another run.
set -uo pipefail
cd "$(dirname "$0")/.."

output=$(godot --headless --xr-mode off --fixed-fps 90 -- --uiprobe=1 2>&1 \
  | grep -v -E "Meta XR Simulator|^\* daemon|Analytics|remove_tracker|p_tracker.is_null|xr_server\.cpp|ObjectDB|object\.cpp")

echo "$output"
grep -q "MENU PROBE PASS" <<<"$output"
