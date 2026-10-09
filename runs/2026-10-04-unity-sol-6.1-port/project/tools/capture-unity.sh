#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAYER="$PORT_ROOT/Builds/Soaring.app/Contents/MacOS/Soaring"
OUT="$PORT_ROOT/docs/comparison/raw/unity"
LOG="$PORT_ROOT/Logs/comparison"
mkdir -p "$OUT" "$LOG/unity-frames" "$LOG/unity-ui"
[[ -x "$PLAYER" ]] || { echo 'Run unity.sh build-mac first' >&2; exit 1; }
if [[ "${1:-all}" != ui ]]; then
    perl -e 'alarm shift; exec @ARGV' 900 "$PLAYER" -no-xr -screen-width 1280 -screen-height 720 -screen-fullscreen 0 -logFile "$LOG/unity-world.log" --comparison-route "$PORT_ROOT/tools/comparison-route.json" --comparison-output "$OUT" --comparison-frames "$LOG/unity-frames"
fi
perl -e 'alarm shift; exec @ARGV' 300 "$PLAYER" -no-xr -screen-width 1280 -screen-height 720 -screen-fullscreen 0 -logFile "$LOG/unity-ui.log" --verify-soaring --evidence "$LOG/unity-ui"
cp "$LOG/unity-ui/01-menu.png" "$OUT/menu.png"
cp "$LOG/unity-ui/02-flight.png" "$OUT/flight.png"
cp "$LOG/unity-ui/runtime-verification.json" "$OUT/ui-run.json"
