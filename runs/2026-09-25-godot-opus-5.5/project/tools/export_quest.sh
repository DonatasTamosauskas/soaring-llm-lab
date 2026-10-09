#!/bin/bash
# Export the Quest build from the tree (integration round 1).
#
#   tools/export_quest.sh [debug|release|pack] [output path]
#
# debug / release: the "Meta Quest" preset's APK (default build/soaring-quest.apk);
# pack: only the data pack (.pck, default the scratch path given), to check
# what the export puts in the project settings without a gradle build.
#
# Why not `tools/gd.sh export --export-debug ...` (round 0): gd.sh gives every
# sandbox a private user:// by writing application/config/use_custom_user_dir
# and custom_user_dir_name="soaring-sb-<sandbox>" into the sandbox's
# project.godot, and the export shipped them in the APK's project.binary.
# Here the sandbox is synced and imported by gd.sh as usual, then the export
# runs on the tree's own project.godot (restored afterwards), and the
# exported settings are checked: no sandbox user dir, and the settings the
# game relies on present (the OpenXR hand-tracking key the vendors plugin
# reads before Godot registers it, the Meta colour space, user presence).
# The gradle build template must be installed in the sandbox first
# (docs/INTEGRATION.md §6).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-debug}"
OUT="${2:-$ROOT/build/soaring-quest.apk}"
SB="$ROOT/.sandboxes/export"

# Sync and import the sandbox (a run that quits at once).
GD_TIMEOUT=300 "$ROOT/tools/gd.sh" export --headless --quit >/dev/null 2>&1
if [ "$MODE" != "pack" ] && [ ! -f "$SB/android/.build_version" ]; then
	echo "[export] the Android build template is not installed in $SB/android (docs/INTEGRATION.md §6)" >&2
	exit 2
fi
mkdir -p "$(dirname "$OUT")"
cp "$SB/project.godot" "$SB/.project.godot.gdsh"
cp "$ROOT/project.godot" "$SB/project.godot"
case "$MODE" in
	debug) FLAG=--export-debug;;
	release) FLAG=--export-release;;
	pack) FLAG=--export-pack;;
	*) echo "usage: tools/export_quest.sh [debug|release|pack] [out]" >&2; exit 2;;
esac
perl -e 'alarm shift; exec @ARGV' 1800 godot --headless --path "$SB" --xr-mode off $FLAG "Meta Quest" "$OUT"
CODE=$?
cp "$SB/.project.godot.gdsh" "$SB/project.godot"
rm -f "$SB/.project.godot.gdsh"
if [ $CODE -ne 0 ] || [ ! -f "$OUT" ]; then
	echo "[export] FAIL: godot exited $CODE, output $OUT"
	exit 1
fi
# What the build carries.
SETTINGS=$(mktemp)
if [ "$MODE" = "pack" ]; then
	strings "$OUT" >"$SETTINGS"
else
	unzip -p "$OUT" assets/project.binary | strings >"$SETTINGS"
fi
FAIL=0
if grep -q "custom_user_dir" "$SETTINGS"; then
	echo "[export] FAIL: the build carries a sandbox user dir setting"; FAIL=1
fi
for key in "xr/openxr/extensions/hand_tracking" "openxr/extensions/meta/color_space" "openxr/extensions/user_presence"; do
	if ! grep -q "$key" "$SETTINGS"; then
		echo "[export] FAIL: the build lacks $key"; FAIL=1
	fi
done
if [ "$MODE" != "pack" ] && unzip -l "$OUT" | grep -q "scripts/game/sim/"; then
	echo "[export] FAIL: the game loop's pacing tooling (scripts/game/sim) is in the build"; FAIL=1
fi
# (Integration round 2: the game loop's test evidence, ~0.9 MB of JSON only
# tests/unit/game/pacing_test.gd and the pacing tools read, shipped in the APK.)
if [ "$MODE" != "pack" ] && unzip -l "$OUT" | grep -q "scripts/game/data/"; then
	echo "[export] FAIL: the game loop's test evidence (scripts/game/data) is in the build"; FAIL=1
fi
if [ "$MODE" != "pack" ] && unzip -l "$OUT" | grep -qE "assets/tests/|assets/artifacts/|assets/docs/"; then
	echo "[export] FAIL: tests, artifacts or docs are in the build"; FAIL=1
fi
rm -f "$SETTINGS"
ls -l "$OUT"
if [ $FAIL -eq 0 ]; then
	echo "[export] PASS: $OUT"
fi
exit $FAIL
