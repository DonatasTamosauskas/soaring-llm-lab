#!/bin/bash
# VR area simulator harness: runs tests/sim/vr_sim.tscn in the Meta XR
# Simulator (through tools/xr.sh, which queues on the machine-wide lock)
# with the SimRpc controller driver alongside, then gives a verdict:
#
#   tests/sim/run_vr_sim.sh [--refresh=72|90] [--tag=<name>] [--no-world]
#
# PASS needs the harness's own "[vr] SIM RESULT PASS" and zero script
# errors / unexpected engine errors in the full log. The only lines
# tolerated are engine/runtime exit noise present in every simulator run of
# every area: remove_tracker p_tracker.is_null, the ObjectDB / OpenXR
# InteractionProfile RID leak reports at exit, the OpenXR spatial-entity
# signal disconnect at shutdown, and the simulator's analytics warning.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ART="$ROOT/artifacts/vr"
mkdir -p "$ART"
TAG="default"
for a in "$@"; do case "$a" in --tag=*) TAG="${a#--tag=}";; esac; done
rm -f "$ART/sim_state.json" "$ART/sim_driver.json"

python3 "$ROOT/tests/sim/sim_driver.py" drive >"$ART/sim_driver_$TAG.log" 2>&1 &
DRIVER=$!
"$ROOT/tools/xr.sh" 150 res://tests/sim/vr_sim.tscn -- --tag="$TAG" "$@"
CODE=$?
# The driver exits by itself once the harness asked and it finished; if the
# harness never asked (crash), stop it.
for i in $(seq 1 20); do kill -0 $DRIVER 2>/dev/null || break; sleep 0.5; done
kill $DRIVER 2>/dev/null

LOG=$(ls -t "$ROOT"/artifacts/xr/run_*.log | grep -v '\.app\.log$' | head -1)
cp "$LOG" "$ART/sim_run_$TAG.log"
NOISE='p_tracker.is_null|remove_tracker|ObjectDB instance was leaked|InteractionProfileE. were leaked|spatial_discovery_recommended|Analytics\] Failed to send health event'
ERRS=$(grep -E 'SCRIPT ERROR|^ERROR|^WARNING|Parse Error|\{ERROR\}' "$LOG" | grep -v -E "$NOISE" | grep -v '^   at:')
RESULT=$(grep -E '^\[vr\] SIM RESULT' "$LOG" | tail -1)
echo "[vr-sim] log: $ART/sim_run_$TAG.log"
echo "[vr-sim] driver: $ART/sim_driver_$TAG.log"
grep -E '^\[vr\] SIM (PASS|FAIL)' "$LOG"
if [ -n "$ERRS" ]; then
	echo "[vr-sim] unexpected errors/warnings:"
	echo "$ERRS" | head -30
fi
if [[ "$RESULT" == *"PASS"* ]] && [ -z "$ERRS" ] && [ $CODE -eq 0 ]; then
	echo "[vr-sim] VERDICT PASS ($TAG)"
	exit 0
fi
echo "[vr-sim] VERDICT FAIL ($TAG) exit=$CODE result='$RESULT'"
exit 1
