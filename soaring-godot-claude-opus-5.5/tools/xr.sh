#!/bin/bash
# Run the project in the Meta XR Simulator, one session at a time.
#
#   tools/xr.sh <seconds> [scene] [-- user args...]
#
# Holds a lock so parallel agents queue for the simulator instead of fighting
# over it, starts the simulator if needed, runs Godot with XR on for
# <seconds> (the game quits itself via --autoquit), and writes:
#   artifacts/xr/run_<stamp>.log      full output (the simulator is noisy)
#   artifacts/xr/run_<stamp>.app.log  only this project's lines + errors
# Screenshots: pass -- --xrshot=5,10 (see scripts/vr/xr_mirror.gd).
# XR_SANDBOX=<name> runs in .sandboxes/<name> (default "xr") and so with its
# own user:// (soaring-sb-<name>): a harness that needs reproducible saved
# state (a first launch, no calibration) uses its own instead of the one
# every agent's simulator runs share. The simulator lock is the same.
# XR_FRESH_USER=1 (only with a private XR_SANDBOX) empties that user:// once
# the lock is ours, right before the game starts: a first launch.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:?usage: tools/xr.sh <seconds> [scene] [-- args]}"; shift
SCENE=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then SCENE="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
mkdir -p "$ROOT/.sandboxes" "$ROOT/artifacts/xr"
LOCK="$ROOT/.sandboxes/xr.lock"
waited=0
until shlock -f "$LOCK" -p $$; do
	sleep 3; waited=$((waited+3))
	if [ $waited -ge 1800 ]; then echo "[xr.sh] gave up waiting for the simulator lock" >&2; exit 3; fi
done
trap 'rm -f "$LOCK"' EXIT

if ! pgrep -f "MetaXRSimulator.app/Contents/MacOS/MetaXRSimulator" >/dev/null; then
	echo "[xr.sh] starting Meta XR Simulator"
	open -a MetaXRSimulator
	sleep 15
fi

SBX="${XR_SANDBOX:-xr}"
if [ "${XR_FRESH_USER:-0}" = "1" ] && [ "$SBX" != "xr" ] && [ -n "$SBX" ]; then
	rm -rf "$HOME/Library/Application Support/soaring-sb-$SBX"
	echo "[xr.sh] emptied user:// of sandbox $SBX (a first launch)"
fi

STAMP=$(date +%Y%m%d_%H%M%S)
LOG="$ROOT/artifacts/xr/run_$STAMP.log"
XR=1 GD_TIMEOUT=$((SECS + 90)) "$ROOT/tools/gd.sh" "$SBX" $SCENE -- --autoquit="$SECS" "$@" >"$LOG" 2>&1
CODE=$?
grep -E '^\[[a-z]+\]|SCRIPT ERROR|^ERROR|^WARNING|Parse Error|handle_crash|signal 11' "$LOG" \
	| grep -v -E 'remove_tracker|p_tracker.is_null' >"${LOG%.log}.app.log"
echo "[xr.sh] exit=$CODE log=$LOG"
echo "[xr.sh] app log: ${LOG%.log}.app.log ($(wc -l <"${LOG%.log}.app.log") lines)"
exit $CODE
