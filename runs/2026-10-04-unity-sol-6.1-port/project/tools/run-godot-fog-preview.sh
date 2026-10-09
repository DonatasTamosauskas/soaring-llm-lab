#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COPY="$PORT_ROOT/.godot-fog-investigation"
[[ -f "$COPY/fog_probe.gd" ]] || "$PORT_ROOT/tools/prepare-godot-fog-copy.sh"
exec godot --path "$COPY" --xr-mode off --rendering-method forward_plus --resolution 1280x720 --log-file "$PORT_ROOT/Logs/fog-investigation/playable.log" res://fog_free_main.tscn -- --fresh-settings "--fog-preview=${1:-no-fog}" "${@:2}"
