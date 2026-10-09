#!/bin/bash
# SIM-05 (flight, F14): the Meta XR Simulator's own controllers, moved by
# its keybindings over SimRpc, fly the bird in the flight lab.
#
#   tests/shots/flight_sim_run.sh [--species=pigeon] [--refresh=72|90]
#
# Starts tests/shots/flight_sim_driver.py in the background, runs the lab
# through tools/xr.sh (which queues on the machine-wide simulator lock), and
# gives a verdict: PASS needs the lab's "[flight] SIM-05 RESULT PASS", no
# SCRIPT ERROR, and the simulator's persistent settings file unchanged.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ART="$ROOT/artifacts/flight"
mkdir -p "$ART"
SPECIES="pigeon"
EXTRA=()
DRIVER_ARGS=()
for a in "$@"; do
	case "$a" in
		--species=*) SPECIES="${a#--species=}";;
		--diag) DRIVER_ARGS+=("--diag");;
		*) EXTRA+=("$a");;
	esac
done
rm -f "$ART/sim_state.json" "$ART/sim_driver.json" "$ART/sim05_result.json"
python3 "$ROOT/tests/shots/flight_sim_driver.py" "${DRIVER_ARGS[@]+"${DRIVER_ARGS[@]}"}" >"$ART/sim_driver.log" 2>&1 &
DRIVER=$!
# Forward+ for the head-view mirror captures: the Mobile renderer paints
# MoltenVK magenta tiles on this Mac (ARCHITECTURE §2; the VR area does the
# same). The flight code under test is renderer-independent.
"$ROOT/tools/xr.sh" 75 "--rendering-method forward_plus res://scenes/dev/flight_dev.tscn" -- --pose=xr --simdrive --species="$SPECIES" \
	--view=eye --xrdiag "${EXTRA[@]+"${EXTRA[@]}"}"
CODE=$?
for i in $(seq 1 20); do kill -0 $DRIVER 2>/dev/null || break; sleep 0.5; done
kill $DRIVER 2>/dev/null
LOG=$(ls -t "$ROOT"/artifacts/xr/run_*.log | grep -v '\.app\.log$' | head -1)
cp "$LOG" "$ART/sim05_run.log"
grep -E '^\[flight\] SIM-05' "$LOG"
ERRS=$(grep -E 'SCRIPT ERROR|Parse Error' "$LOG")
UNCHANGED=$(python3 -c "import json;print(json.load(open('$ART/sim_driver.json')).get('persistent_unchanged'))" 2>/dev/null)
echo "[flight-sim] driver log: $ART/sim_driver.log; persistent settings unchanged: $UNCHANGED"
if grep -q '^\[flight\] SIM-05 RESULT PASS' "$LOG" && [ -z "$ERRS" ] && [ "$UNCHANGED" = "True" ]; then
	echo "[flight-sim] VERDICT PASS (log $ART/sim05_run.log)"
	exit 0
fi
[ -n "$ERRS" ] && echo "$ERRS" | head -10
echo "[flight-sim] VERDICT FAIL exit=$CODE (log $ART/sim05_run.log)"
exit 1
