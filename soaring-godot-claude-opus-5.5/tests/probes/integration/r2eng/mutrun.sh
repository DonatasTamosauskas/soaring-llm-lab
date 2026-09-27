#!/bin/bash
# mutrun.sh <name> <mutation.py> [godot args...]
# Round-2 engineering verifier: copies the tree into .sandboxes/v2e_mut_<name>
# (like tools/gd.sh), applies the python mutation there (cwd = the copy), imports
# and runs Godot in the copy. The shared tree is never modified. Artifacts go to
# the copy's own artifacts_mut/.
set -uo pipefail
ROOT=/Users/don/Projects/Soaring/soaring-godot-claude-opus-5.5
HERE="$ROOT/tests/probes/integration/r2eng"
NAME="$1"; MUT="$2"; shift 2
SB="$ROOT/.sandboxes/v2e_mut_$NAME"
mkdir -p "$SB"
rsync -a --delete --exclude '/.godot/' --exclude '/.sandboxes/' --exclude '/artifacts/' \
	--exclude '/.git/' --exclude '/addons' --exclude '/build/' --exclude '/android/' \
	--exclude '/project.godot' --filter='P *.uid' --filter='P *.import' "$ROOT/" "$SB/"
awk -v n="v2e_mut_$NAME" '{print} /^\[application\]$/{print "config/use_custom_user_dir=true"; print "config/custom_user_dir_name=\"soaring-sb-" n "\""}' "$ROOT/project.godot" >"$SB/project.godot"
[ -e "$SB/addons" ] || ln -s "$ROOT/addons" "$SB/addons"
if [ "$MUT" != "none" ]; then
	( cd "$SB" && python3 "$HERE/$MUT" "$HERE" ) || { echo "[r2eng-mut] mutation failed"; exit 3; }
fi
perl -e 'alarm shift; exec @ARGV' 240 godot --headless --path "$SB" --import --xr-mode off >"$SB/.import.log" 2>&1
grep -E "SCRIPT ERROR|Parse Error|Failed to load script" "$SB/.import.log" | head -5
export SOARING_ARTIFACTS="$SB/artifacts_mut" SOARING_ROOT="$SB"
mkdir -p "$SOARING_ARTIFACTS"
exec perl -e 'alarm shift; exec @ARGV' "${GD_TIMEOUT:-900}" godot --path "$SB" --xr-mode off "$@"
