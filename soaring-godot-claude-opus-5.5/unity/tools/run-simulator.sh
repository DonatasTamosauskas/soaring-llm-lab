#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAYER="$PORT_ROOT/Builds/Soaring.app/Contents/MacOS/Soaring"
RUNTIME="${META_XR_SIMULATOR_JSON:-/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json}"
[[ -x "$PLAYER" ]] || { echo "Build first: $PORT_ROOT/tools/unity.sh build-mac" >&2;exit 1; }
[[ -f "$RUNTIME" ]] || { echo "Missing Meta XR Simulator manifest: $RUNTIME" >&2;exit 1; }
export XR_RUNTIME_JSON="$RUNTIME" XR_SELECTED_RUNTIME_JSON="$RUNTIME"
exec "$PLAYER" -logFile "${SOARING_SIMULATOR_LOG:-$PORT_ROOT/Logs/simulator-player.log}" "$@"
