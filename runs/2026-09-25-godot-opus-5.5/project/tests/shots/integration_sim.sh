#!/bin/bash
# The composed game (scenes/main.tscn) in the Meta XR Simulator, with the
# SimRpc controller driver alongside (integration):
#
#   tests/shots/integration_sim.sh [--tag=<name>] [--renderer=forward_plus] [--keep-user] [extra user args, e.g. --quality=full]
#
# PASS needs the game's own "[integration] SIM RESULT PASS" and no SCRIPT
# ERROR / unexpected ERROR / WARNING in the full log. Tolerated: the engine's
# exit messages present in every simulator run of every area (remove_tracker,
# the ObjectDB / OpenXR InteractionProfile RID leak at exit, the spatial-
# entity signal disconnect at shutdown) and the simulator's analytics note.
#
# Integration round 1 (verifier findings):
#  * every run is a FIRST LAUNCH, reproducibly: the game runs in its own
#    sandbox (XR_SANDBOX=xr_integ: its own user://, soaring-sb-xr_integ),
#    which is emptied before each run (no saved calibration, settings,
#    tutorial or records from earlier runs or other agents). --keep-user
#    keeps it (a returning player).
#  * the game and the driver talk through files named for this run only
#    (artifacts/integration/sim_io/<run id>_*.json): the driver starts
#    before the simulator lock is ours, and must never read another agent's
#    run.
#  * the verdict reads the log xr.sh names for THIS run ("log=" line), not
#    the newest run_*.log (a queued run of another agent may have started).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ART="$ROOT/artifacts/integration"
mkdir -p "$ART/sim_io"
TAG="default"
SCENE="res://scenes/main.tscn"
KEEP_USER=0
ARGS=()
for a in "$@"; do case "$a" in
	--tag=*) TAG="${a#--tag=}"; ARGS+=("$a");;
	# Forward+ for clean mirror images (the Mobile renderer paints MoltenVK
	# magenta tiles on this Mac); the default Mobile run is the one to judge
	# frame rate and draw calls by (it is what the Quest runs).
	--renderer=*) SCENE="--rendering-method ${a#--renderer=} $SCENE";;
	--keep-user) KEEP_USER=1;;
	*) ARGS+=("$a");;
esac; done
RUN_ID="${TAG}_$$_$(date +%s)"
export XR_SANDBOX="xr_integ"

python3 "$ROOT/tests/shots/integration_sim_driver.py" --io="$RUN_ID" >"$ART/sim_driver_$TAG.log" 2>&1 &
DRIVER=$!
# The private user dir is emptied inside the lock, right before the game
# starts (xr.sh, XR_FRESH_USER).
if [ $KEEP_USER -eq 0 ]; then
	export XR_FRESH_USER=1
fi
OUT=$("$ROOT/tools/xr.sh" 240 "$SCENE" -- --harness=sim --sim_io="$RUN_ID" --xrdiag ${ARGS[@]+"${ARGS[@]}"} 2>&1)
CODE=$?
echo "$OUT"
for i in $(seq 1 20); do kill -0 $DRIVER 2>/dev/null || break; sleep 0.5; done
kill $DRIVER 2>/dev/null

LOG=$(echo "$OUT" | sed -n 's/^\[xr\.sh\] exit=[0-9]* log=//p' | tail -1)
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
	echo "[integration-sim] VERDICT FAIL ($TAG): xr.sh named no log for this run"
	exit 1
fi
cp "$LOG" "$ART/sim_run_$TAG.log"
RES="$ART/sim_io/${RUN_ID}_result.json"
[ -f "$RES" ] && cp "$RES" "$ART/sim_result_$TAG.json"
[ -f "$ART/sim_io/${RUN_ID}_driver.json" ] && cp "$ART/sim_io/${RUN_ID}_driver.json" "$ART/sim_driver_$TAG.json"
rm -f "$ART/sim_io/${RUN_ID}_"*.json "$ART/sim_io/${RUN_ID}_"*.tmp
NOISE='p_tracker.is_null|remove_tracker|ObjectDB instance was leaked|InteractionProfileE. were leaked|spatial_discovery_recommended|Analytics\] Failed to send health event'
ERRS=$(grep -E 'SCRIPT ERROR|^ERROR|^WARNING|Parse Error|\{ERROR\}' "$LOG" | grep -v -E "$NOISE" | grep -v '^   at:')
RESULT=$(grep -E '^\[integration\] SIM RESULT' "$LOG" | tail -1)
echo "[integration-sim] log: $ART/sim_run_$TAG.log (from $LOG)"
grep -E '^\[integration\] SIM (PASS|FAIL)' "$LOG"
if [ -n "$ERRS" ]; then
	echo "[integration-sim] unexpected errors/warnings:"
	echo "$ERRS" | head -30
fi
if [[ "$RESULT" == *"PASS"* ]] && [ -z "$ERRS" ] && [ $CODE -eq 0 ]; then
	echo "[integration-sim] VERDICT PASS ($TAG)"
	exit 0
fi
echo "[integration-sim] VERDICT FAIL ($TAG) exit=$CODE result='$RESULT'"
exit 1
