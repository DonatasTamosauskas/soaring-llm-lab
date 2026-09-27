#!/bin/bash
# Round-3 engineering verifier: mutrun.sh <name> <mutation.py> [godot args...]
# Copies the tree into .sandboxes/r3e_<name>_mut (like tools/gd.sh), applies the
# python mutation there (cwd = the copy), imports and runs Godot. The shared
# tree is never modified.
set -uo pipefail
ROOT=/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5
NAME="$1"; MUT="$2"; shift 2
SB="$ROOT/.sandboxes/r3e_${NAME}_mut"
mkdir -p "$SB"
rsync -a --delete --exclude '/.godot/' --exclude '/.sandboxes/' --exclude '/artifacts/' \
	--exclude '/.git/' --exclude '/addons' --exclude '/build/' --exclude '/android/' \
	--exclude '/project.godot' --filter='P *.uid' --filter='P *.import' "$ROOT/" "$SB/"
awk -v n="r3e_${NAME}_mut" '{print} /^\[application\]$/{print "config/use_custom_user_dir=true"; print "config/custom_user_dir_name=\"soaring-sb-" n "\""}' "$ROOT/project.godot" >"$SB/project.godot"
[ -e "$SB/addons" ] || ln -s "$ROOT/addons" "$SB/addons"
( cd "$SB" && python3 "$MUT" ) || { echo "[r3eng-mut] mutation failed"; exit 3; }
perl -e 'alarm shift; exec @ARGV' 240 godot --headless --path "$SB" --import --xr-mode off >"$SB/.import.log" 2>&1
grep -E "SCRIPT ERROR|Parse Error" "$SB/.import.log" | head -5
export SOARING_ARTIFACTS="${R3_ART:-$SB/artifacts_mut}" SOARING_ROOT="$SB"
mkdir -p "$SOARING_ARTIFACTS"
exec perl -e 'alarm shift; exec @ARGV' "${GD_TIMEOUT:-900}" godot --path "$SB" --xr-mode off "$@"
