#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COPY="$PORT_ROOT/.godot-export"
[[ -f "$COPY/project.godot" ]] || { echo 'Run export-source.sh first' >&2; exit 1; }
cp "$PORT_ROOT/tools/export_ui_art.gd" "$COPY/export_ui_art.gd"
cat > "$COPY/export_ui_art.tscn" <<'SCENE'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://export_ui_art.gd" id="1"]
[node name="UIExport" type="Node"]
script = ExtResource("1")
SCENE
export SOARING_UI_EXPORT="$PORT_ROOT/Soaring/Assets/Soaring/Resources/UI/Art"
perl -e 'alarm shift; exec @ARGV' 120 godot --path "$COPY" --xr-mode off --rendering-method forward_plus --resolution 256x256 --fixed-fps 30 --log-file "$PORT_ROOT/Logs/ui-art-export.log" res://export_ui_art.tscn
