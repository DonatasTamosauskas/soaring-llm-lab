#!/bin/bash
# VR area: the calibration step in the Meta XR Simulator. Runs
# tests/sim/vr_calibration_sim.tscn through tools/xr.sh (which queues on the
# machine-wide lock) with the SimRpc driver in mode "calibrate" alongside,
# then gives a verdict:
#
#   tests/sim/run_calibration_sim.sh [--fplus]
#
# --fplus renders with Forward+ (clean mirror images: the Mobile renderer
# paints MoltenVK magenta tiles on this Mac, never on Quest; the shots then
# end in _fplus). The verdict is the same either way.
#
# PASS needs the harness's own "[vr] SIM CALIBRATION RESULT PASS" and zero
# script errors / unexpected engine errors in the full log (the same
# tolerated exit noise as tests/sim/run_vr_sim.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ART="$ROOT/artifacts/vr"
mkdir -p "$ART"
rm -f "$ART/sim_state.json" "$ART/sim_driver.json"

SCENE="res://tests/sim/vr_calibration_sim.tscn"
ARGS=()
for a in "$@"; do
	if [ "$a" = "--fplus" ]; then SCENE="--rendering-method forward_plus $SCENE"; else ARGS+=("$a"); fi
done

python3 "$ROOT/tests/sim/sim_driver.py" calibrate >"$ART/sim_calibration_driver.log" 2>&1 &
DRIVER=$!
"$ROOT/tools/xr.sh" 120 "$SCENE" -- ${ARGS[@]+"${ARGS[@]}"}
CODE=$?
for i in $(seq 1 20); do kill -0 $DRIVER 2>/dev/null || break; sleep 0.5; done
kill $DRIVER 2>/dev/null
cp "$ART/sim_driver.json" "$ART/sim_calibration_driver.json" 2>/dev/null

LOG=$(ls -t "$ROOT"/artifacts/xr/run_*.log | grep -v '\.app\.log$' | head -1)
cp "$LOG" "$ART/sim_calibration_run.log"
NOISE='p_tracker.is_null|remove_tracker|ObjectDB instance was leaked|InteractionProfileE. were leaked|spatial_discovery_recommended|Analytics\] Failed to send health event'
ERRS=$(grep -E 'SCRIPT ERROR|^ERROR|^WARNING|Parse Error|\{ERROR\}' "$LOG" | grep -v -E "$NOISE" | grep -v '^   at:')
RESULT=$(grep -E '^\[vr\] SIM CALIBRATION RESULT' "$LOG" | tail -1)
echo "[vr-sim] log: $ART/sim_calibration_run.log"
echo "[vr-sim] driver: $ART/sim_calibration_driver.log"
grep -E '^\[vr\] SIM (PASS|FAIL)' "$LOG"
if [ -n "$ERRS" ]; then
	echo "[vr-sim] unexpected errors/warnings:"
	echo "$ERRS" | head -30
fi
if [[ "$RESULT" == *"PASS"* ]] && [ -z "$ERRS" ] && [ $CODE -eq 0 ]; then
	echo "[vr-sim] VERDICT PASS (calibration)"
	exit 0
fi
echo "[vr-sim] VERDICT FAIL (calibration) exit=$CODE result='$RESULT'"
exit 1
