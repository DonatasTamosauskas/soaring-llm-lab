#!/bin/bash
# Run Godot against a private copy of this project.
#
#   tools/gd.sh <sandbox> [godot args...]
#
# Parallel agents share one source tree but must never share a .godot cache:
# concurrent imports rewrite global_script_class_cache.cfg and uid_cache.bin
# under each other. So every caller names a sandbox (use your area name), the
# tree is rsynced into .sandboxes/<sandbox>/ (hidden from Godot and git), the
# copy is re-imported only when something changed, and Godot runs there.
# Files Godot generates inside the copy (*.uid, *.import) are protected from
# rsync's --delete, the addons symlink is excluded as a path (not a dir), and
# directory-timestamp-only updates are not counted as changes; otherwise every
# run would look changed and re-import the whole project.
#
# Defaults: --xr-mode off is added unless XR=1 is set (use tools/xr.sh for the
# simulator). GD_TIMEOUT (seconds, default 300, capped at 2700) kills a hung
# run. Background wait loops that poll for a run's output must have a deadline
# too (e.g. `for i in $(seq 90); do ...; sleep 20; done`), never a bare
# `until ...; do sleep; done`.
# Artifacts: scripts write under $SOARING_ARTIFACTS (<project>/artifacts), see
# scripts/core/paths.gd, so output lands in the real tree, not the sandbox.
# user:// is private per sandbox too (the copied project.godot gets a custom
# user dir "soaring-sb-<sandbox>"), so one area's tests can never rewrite the
# settings, scores or calibration another area's tests read. The real game
# (run from the tree itself) keeps the normal user dir.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: tools/gd.sh <sandbox> [godot args...]}"
shift
SB="$ROOT/.sandboxes/$NAME"
mkdir -p "$SB" "$ROOT/artifacts"
touch "$ROOT/.sandboxes/.gdignore"

CHANGES=$(rsync -a -i --delete \
	--exclude '/.godot/' --exclude '/.sandboxes/' --exclude '/artifacts/' \
	--exclude '/.git/' --exclude '/addons' --exclude '/build/' --exclude '/android/' \
	--exclude '/project.godot' --exclude '/.project.godot.src' --exclude '/.import.log' \
	--filter='P *.uid' --filter='P *.import' \
	"$ROOT/" "$SB/" | grep -v '^\.d')
if ! cmp -s "$ROOT/project.godot" "$SB/.project.godot.src"; then
	cp "$ROOT/project.godot" "$SB/.project.godot.src"
	awk -v n="$NAME" '{print} /^\[application\]$/{print "config/use_custom_user_dir=true"; print "config/custom_user_dir_name=\"soaring-sb-" n "\""}' \
		"$ROOT/project.godot" >"$SB/project.godot"
	CHANGES="$CHANGES project.godot"
fi
if [ ! -e "$SB/addons" ]; then
	ln -s "$ROOT/addons" "$SB/addons"
	CHANGES="$CHANGES addons"
fi

export SOARING_ARTIFACTS="$ROOT/artifacts"
export SOARING_ROOT="$ROOT"
TIMEOUT="${GD_TIMEOUT:-300}"
# Hard ceiling: no run may outlive 45 minutes, whatever GD_TIMEOUT says, so a
# forgotten background run can never linger as a zombie eating a CPU core.
if [ "$TIMEOUT" -gt 2700 ] 2>/dev/null; then TIMEOUT=2700; fi

if [ -n "$CHANGES" ] || [ ! -f "$SB/.godot/global_script_class_cache.cfg" ]; then
	# Re-scan so new class_name scripts and resources are registered.
	perl -e 'alarm shift; exec @ARGV' 180 godot --headless --path "$SB" --import --xr-mode off >"$SB/.import.log" 2>&1
	if grep -E "SCRIPT ERROR|Parse Error|ERROR: Failed to load script" "$SB/.import.log" >/dev/null; then
		echo "[gd.sh] import reported script errors:" >&2
		grep -E -A2 "SCRIPT ERROR|Parse Error|ERROR: Failed to load script" "$SB/.import.log" | head -40 >&2
	fi
fi

XR_ARGS=(--xr-mode off)
if [ "${XR:-0}" = "1" ]; then XR_ARGS=(--xr-mode on); fi

exec perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" godot --path "$SB" "${XR_ARGS[@]}" "$@"
