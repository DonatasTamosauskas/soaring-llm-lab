#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAYER="$PORT_ROOT/Builds/Soaring.app/Contents/MacOS/Soaring"
[[ -x "$PLAYER" ]] || { echo "Build first: $PORT_ROOT/tools/unity.sh build-mac" >&2;exit 1; }
exec "$PLAYER" -no-xr -screen-width 1440 -screen-height 1080 -logFile "$PORT_ROOT/Logs/desktop-player.log" "$@"
