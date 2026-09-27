#!/bin/bash
# VERIFIER PROBE (integration verify round 1): the composed game in the Meta
# XR Simulator with the SimRpc driver; see vrq_sim.gd.
#   tests/probes/integration/vrq_sim.sh <tag> [godot args before the scene, e.g. --rendering-method forward_plus] [-- user args]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DIR="$ROOT/artifacts/integration/verify/vrq"
mkdir -p "$DIR"
TAG="${1:-mobile}"; shift
PRE=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do PRE+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
rm -f "$DIR/state.json" "$DIR/driver.json"
python3 "$ROOT/tests/probes/integration/vrq_sim_driver.py" >"$DIR/${TAG}_driver.log" 2>&1 &
DRIVER=$!
SCN="res://tests/probes/integration/vrq_sim.tscn"
[ ${#PRE[@]} -gt 0 ] && SCN="${PRE[*]} $SCN"
"$ROOT/tools/xr.sh" 330 "$SCN" -- --tag="$TAG" --xrdiag "$@" | tee "$DIR/${TAG}_xr.out"
CODE=${PIPESTATUS[0]}
for i in $(seq 1 30); do kill -0 $DRIVER 2>/dev/null || break; sleep 0.5; done
kill $DRIVER 2>/dev/null
# This run's own log (xr.sh prints it); never "the newest log", which may be
# another agent's run that started as soon as the lock was released.
LOG=$(grep -o 'log=[^ ]*\.log' "$DIR/${TAG}_xr.out" | head -1 | cut -d= -f2)
cp "$LOG" "$DIR/${TAG}_run.log"
cp "$DIR/driver.json" "$DIR/${TAG}_driver.json" 2>/dev/null
grep -E '^\[integration-verify\] (CHECK|RESULT)' "$LOG"
echo "[vrq] errors/warnings in the full log:"
grep -E 'SCRIPT ERROR|^ERROR|^WARNING|Parse Error' "$LOG" | grep -v -E 'p_tracker.is_null|remove_tracker' | head -30
echo "[vrq] exit=$CODE log=$DIR/${TAG}_run.log"
