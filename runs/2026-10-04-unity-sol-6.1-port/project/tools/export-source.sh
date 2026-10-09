#!/usr/bin/env bash
set -euo pipefail
PORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$(cd "$PORT_ROOT/.." && pwd)"
SANDBOX="$PORT_ROOT/.godot-export"
mkdir -p "$PORT_ROOT/Logs" "$SANDBOX" "$PORT_ROOT/Soaring/Assets/Soaring/Data/Source"
rsync -a --delete --exclude unity --exclude .git --exclude .godot --exclude .sandboxes --exclude artifacts --exclude build --exclude android "$SOURCE_ROOT/" "$SANDBOX/"
cp "$PORT_ROOT/tools/export_godot.gd" "$SANDBOX/export_godot.gd"
export SOARING_UNITY_EXPORT="$PORT_ROOT/Soaring/Assets/Soaring/Data/Source"
godot --headless --path "$SANDBOX" --xr-mode off --import > "$PORT_ROOT/Logs/godot-import.log" 2>&1
printf '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://export_godot.gd" id="1"]\n[node name="Export" type="Node"]\nscript = ExtResource("1")\n' > "$SANDBOX/export.tscn"
perl -e 'alarm shift; exec @ARGV' 180 godot --headless --path "$SANDBOX" --xr-mode off --log-file "$PORT_ROOT/Logs/godot-runtime.log" res://export.tscn > "$PORT_ROOT/Logs/godot-export.log" 2>&1
cat "$PORT_ROOT/Logs/godot-export.log"

python3 - "$SOARING_UNITY_EXPORT" <<'PYZIP'
import sys,zipfile,hashlib,json,shutil
from pathlib import Path
source=Path(sys.argv[1]); archive=source.parent/'FrozenWorld.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as bundle:
 for path in sorted(source.iterdir()):
  if path.suffix in ('.bytes','.json'):
   info=zipfile.ZipInfo(path.name,date_time=(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;bundle.writestr(info,path.read_bytes())
manifest=json.loads((source/'world.json').read_text())
(source.parent/'provenance.json').write_text(json.dumps({'seed':manifest['seed'],'source':'Soaring Godot procedural world and birds','sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'meshCount':len(manifest['meshes']),'colliderCount':len(manifest['colliders']),'perchCount':len(manifest['perches'])},indent=2)+'\n')
shutil.rmtree(source)
meta=source.parent/(source.name+'.meta')
if meta.exists():meta.unlink()
print('Frozen archive:',archive.stat().st_size//1024//1024,'MiB')
PYZIP
