#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COPY="$PORT_ROOT/.godot-export"
OUT="$PORT_ROOT/docs/comparison/raw/godot"
mkdir -p "$OUT" "$PORT_ROOT/Logs/comparison/godot-frames"
[[ -f "$COPY/project.godot" ]] || { echo "Run export-source.sh first" >&2; exit 1; }
cp "$PORT_ROOT/tools/comparison_world.gd" "$COPY/comparison_world.gd"
cp "$PORT_ROOT/tools/comparison_ui.gd" "$COPY/tests/shots/integration_comparison_ui.gd"
cat > "$COPY/comparison_world.tscn" <<'SCENE'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://comparison_world.gd" id="1"]
[node name="Comparison" type="Node3D"]
script = ExtResource("1")
SCENE
python3 - "$COPY/project.godot" <<'PY'
import sys
from pathlib import Path
path=Path(sys.argv[1]); text=path.read_text()
if 'config/custom_user_dir_name="soaring-unity-comparison"' not in text:
    text=text.replace('[application]', '[application]\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="soaring-unity-comparison"')
    path.write_text(text)
PY
export SOARING_COMPARISON_ROUTE="$PORT_ROOT/tools/comparison-route.json"
export SOARING_COMPARISON_OUTPUT="$OUT"
export SOARING_COMPARISON_FRAMES="$PORT_ROOT/Logs/comparison/godot-frames"
export SOARING_ARTIFACTS="$PORT_ROOT/Logs/comparison/godot-artifacts"
godot --headless --path "$COPY" --xr-mode off --import > "$PORT_ROOT/Logs/comparison/godot-import.log" 2>&1
perl -e 'alarm shift; exec @ARGV' 900 godot --path "$COPY" --xr-mode off --rendering-method forward_plus --resolution 1280x720 --disable-vsync --fixed-fps 30 --log-file "$PORT_ROOT/Logs/comparison/godot-world.log" res://comparison_world.tscn -- --fresh-settings
perl -e 'alarm shift; exec @ARGV' 300 godot --path "$COPY" --xr-mode off --rendering-method forward_plus --resolution 1280x720 --disable-vsync --fixed-fps 72 --log-file "$PORT_ROOT/Logs/comparison/godot-ui.log" res://scenes/main.tscn -- --harness=comparison_ui --fresh-settings
