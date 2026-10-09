#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$(cd "$PORT_ROOT/.." && pwd)"
COPY="$PORT_ROOT/.godot-fog-investigation"
mkdir -p "$COPY" "$PORT_ROOT/Logs/fog-investigation"
rsync -a --exclude unity --exclude .git --exclude .godot --exclude .sandboxes --exclude artifacts --exclude build --exclude android --exclude .agents --exclude .codex "$SOURCE_ROOT/" "$COPY/"
cp "$PORT_ROOT/tools/godot_fog_probe.gd" "$COPY/fog_probe.gd"
cp "$PORT_ROOT/tools/godot_fog_preview.gd" "$COPY/tests/shots/integration_fog_preview.gd"
cat > "$COPY/fog_free_main.tscn" <<'GAME'
[gd_scene load_steps=3 format=3]
[ext_resource type="PackedScene" path="res://scenes/main.tscn" id="1"]
[ext_resource type="Script" path="res://tests/shots/integration_fog_preview.gd" id="2"]
[node name="Main" instance=ExtResource("1")]
[node name="FogPreview" type="Node" parent="."]
script = ExtResource("2")
GAME
cat > "$COPY/fog_probe.tscn" <<'SCENE'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://fog_probe.gd" id="1"]
[node name="FogProbe" type="Node3D"]
script = ExtResource("1")
SCENE
python3 - "$COPY/project.godot" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
# Isolate game settings/records from the original project's user:// directory.
s=s.replace('[application]', '[application]\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="soaring-godot-fog-investigation"')
s=s.replace('run/main_scene="res://scenes/main.tscn"', 'run/main_scene="res://fog_free_main.tscn"')
s=s.replace('config/name="Soaring"', 'config/name="Soaring Fog Preview"')
p.write_text(s)
PY
godot --headless --path "$COPY" --xr-mode off --import > "$PORT_ROOT/Logs/fog-investigation/import.log" 2>&1
