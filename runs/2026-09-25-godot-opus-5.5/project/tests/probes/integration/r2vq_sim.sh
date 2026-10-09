#!/bin/bash
# VERIFIER PROBE (integration verify round 2, VR/simulator/Quest lens): the
# composed game in the Meta XR Simulator, a FIRST LAUNCH in a private user://
# (sandbox r2vq_sb, emptied inside the simulator lock), with the SimRpc
# driver; see r2vq_sim.gd.
#   tests/probes/integration/r2vq_sim.sh <tag> [godot args before the scene] [-- user args]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/artifacts/integration/verify/r2vq"
mkdir -p "$DIR"
TAG="${1:-mobile}"; shift
PRE=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do PRE+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
rm -f "$DIR/state.json" "$DIR/driver.json"
python3 "$ROOT/tests/probes/integration/r2vq_sim_driver.py" >"$DIR/${TAG}_driver.log" 2>&1 &
DRIVER=$!
SCN="res://tests/probes/integration/r2vq_sim.tscn"
[ ${#PRE[@]} -gt 0 ] && SCN="${PRE[*]} $SCN"
XR_SANDBOX=r2vq_sb XR_FRESH_USER=1 "$ROOT/tools/xr.sh" 480 "$SCN" -- --tag="$TAG" --xrdiag "$@" | tee "$DIR/${TAG}_xr.out"
CODE=${PIPESTATUS[0]}
for i in $(seq 1 30); do kill -0 $DRIVER 2>/dev/null || break; sleep 0.5; done
kill $DRIVER 2>/dev/null
LOG=$(grep -o 'log=[^ ]*\.log' "$DIR/${TAG}_xr.out" | head -1 | cut -d= -f2)
cp "$LOG" "$DIR/${TAG}_run.log"
cp "$DIR/driver.json" "$DIR/${TAG}_driver.json" 2>/dev/null
grep -E '^\[integration-verify\] (CHECK|RESULT)' "$LOG"
echo "[r2vq] errors/warnings in the full log:"
grep -E 'SCRIPT ERROR|^ERROR|^WARNING|Parse Error' "$LOG" | grep -v -E 'p_tracker.is_null|remove_tracker' | head -30
echo "[r2vq] exit=$CODE log=$DIR/${TAG}_run.log"
