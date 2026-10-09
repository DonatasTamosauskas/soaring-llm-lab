#!/usr/bin/env bash
# The hunting gate: an autopilot flies ten minutes of the real game and has to
# come back with meals.
#   tests/hunt.sh [seconds]
#
# This is the slowest gate (about 70 s of wall clock for ten minutes of flight)
# and the only one that can see the hunting rules at all. GameManager's
# THREAT_NOTICE_RADIUS / HUNT_NOTICE_RADIUS / FLEE_STAMINA can be reverted to
# the state that caught nothing in ten minutes and run.sh, probe.sh, ui.sh and
# firstcontact.sh all stay green — a chase needs a world, a flock, an AI and a
# flight model to exist at once, so the only honest test is to fly one.
#
# Ten minutes rather than four because the first catch takes about three: the
# autopilot starts at size 1.0 with a thin speed advantage over anything it can
# eat, and the run accelerates as it grows. A four-minute gate measures the
# hardest part of the run and nothing else.
set -uo pipefail
cd "$(dirname "$0")/.."

seconds="${1:-600}"

output=$(godot --headless --xr-mode off --fixed-fps 90 \
  -- --hunt="$seconds" --hunt_gate=1 2>&1 \
  | grep -v -E "Meta XR Simulator|^\* daemon|Analytics|remove_tracker|p_tracker.is_null|xr_server\.cpp|ObjectDB|object\.cpp")

echo "$output" | sed -n '/^  flown/,$p'
grep -q "HUNT PROBE PASS" <<<"$output"
