#!/usr/bin/env bash
set -euo pipefail
EXAMPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYER="${QUEST_SIMULATOR_PLAYER:-$EXAMPLE_ROOT/Builds/QuestBootstrap.app/Contents/MacOS/Quest Bootstrap}"
RUNTIME="${META_XR_SIMULATOR_JSON:-/Applications/MetaXRSimulator.app/Contents/Resources/MetaXRSimulator/meta_openxr_simulator.json}"
[[ -x "$PLAYER" ]] || { echo "Build the Mac player first: $EXAMPLE_ROOT/scripts/unity.sh build-mac" >&2; exit 1; }
[[ -f "$RUNTIME" ]] || { echo "Missing runtime manifest: $RUNTIME" >&2; exit 1; }
mkdir -p "$EXAMPLE_ROOT/Logs"
export XR_RUNTIME_JSON="$RUNTIME" XR_SELECTED_RUNTIME_JSON="$RUNTIME"
exec "$PLAYER" -logFile "$EXAMPLE_ROOT/Logs/player.log"
