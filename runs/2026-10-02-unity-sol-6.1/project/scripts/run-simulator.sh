#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export XR_RUNTIME_JSON="${META_XR_SIMULATOR_JSON:-/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json}"
export XR_SELECTED_RUNTIME_JSON="$XR_RUNTIME_JSON"
mkdir -p "$ROOT/Logs"
exec "$ROOT/Builds/Soaring.app/Contents/MacOS/Soaring" -logFile "$ROOT/Logs/player.log" "$@"
