#!/bin/bash
# Import check and start-up capture of a Godot run, on a scratch copy so the archived project
# stays untouched.
#
#   tools/capture_godot.sh RUN [seconds]
#
# 1. Copies runs/RUN/project to raw/_work/RUN/project (kept out of git) and imports it headless
#    with the installed Godot, counting script and parse errors in the import log.
# 2. Runs the main scene in a desktop window with XR off (Vulkan, Forward+, 1280x720, fixed 30 fps) for
#    SECONDS (default 12) through Godot's movie writer, with no input: what the game shows on
#    start-up. A window opens on your screen for that long.
# 3. Writes runs/RUN/media/startup.mp4 (with poster), startup-first.jpg, startup-end.jpg and
#    runs/RUN/checks.json, which the report reads.
# GODOT and FFMPEG override the binaries (default: godot on PATH, ffmpeg on PATH or ~/.juicylucy/bin).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${1:?usage: tools/capture_godot.sh RUN [seconds]}"
LENGTH="${2:-12}"
SRC="$ROOT/runs/$RUN/project"
WORK="$ROOT/raw/_work/$RUN"
OUT="$ROOT/runs/$RUN/media"
GODOT="${GODOT:-godot}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo "$HOME/.juicylucy/bin/ffmpeg")}"
FPS=30

[ -f "$SRC/project.godot" ] || { echo "[capture] not a Godot project: $SRC" >&2; exit 2; }
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
mkdir -p "$WORK" "$OUT"
rsync -a --delete --exclude '/.godot/' --exclude '/build/' --exclude '/artifacts/' --exclude '/.sandboxes/' \
	--exclude '/android/' "$SRC/" "$WORK/project/"

VERSION="$("$GODOT" --version 2>/dev/null | tail -1)"
deadline 900 "$GODOT" --headless --path "$WORK/project" --import --xr-mode off >"$WORK/import.log" 2>&1
IMPORT_EXIT=$?
IMPORT_ERRORS=$(grep -cE 'SCRIPT ERROR|Parse Error|Failed to load script|Compile Error' "$WORK/import.log")
# Godot 4.7.2 can crash on exit after a headless import has finished; that is the engine, not the project.
IMPORT_DONE=$(grep -E 'DONE' "$WORK/import.log" | grep -c 'reimport')

rm -rf "$WORK/frames" && mkdir -p "$WORK/frames"
# Vulkan (MoltenVK) for every build: the movie writer cannot read frames back under Godot's Metal driver.
deadline $((LENGTH * 10 + 120)) "$GODOT" --path "$WORK/project" --xr-mode off --rendering-driver vulkan --rendering-method forward_plus \
	--resolution 1280x720 --fixed-fps "$FPS" --write-movie "$WORK/frames/frame.png" --quit-after $((LENGTH * FPS)) \
	>"$WORK/startup.log" 2>&1
RUN_EXIT=$?
RUN_ERRORS=$(grep -cE 'SCRIPT ERROR|Parse Error|Failed to load script' "$WORK/startup.log")
FRAMES=$(find "$WORK/frames" -name '*.png' | wc -l | tr -d ' ')

if [ "$FRAMES" -gt 0 ]; then
	FIRST_FRAME=$(find "$WORK/frames" -name '*.png' | sort | head -1)
	PATTERN="$WORK/frames/$(basename "$FIRST_FRAME" | sed -E 's/[0-9]+\.png$//')%08d.png"
	"$FFMPEG" -loglevel error -y -framerate "$FPS" -i "$PATTERN" -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p \
		-movflags +faststart "$OUT/startup.mp4"
	"$FFMPEG" -loglevel error -y -i "$(find "$WORK/frames" -name '*.png' | sort | sed -n "$((2 * FPS))p;$((2 * FPS))q")" \
		-q:v 3 "$OUT/startup-first.jpg"
	"$FFMPEG" -loglevel error -y -i "$(find "$WORK/frames" -name '*.png' | sort | tail -1)" -q:v 3 "$OUT/startup-end.jpg"
	cp "$OUT/startup-end.jpg" "$OUT/startup.poster.jpg"
fi

python3 - "$ROOT/runs/$RUN/checks.json" "$VERSION" "$IMPORT_EXIT" "$IMPORT_ERRORS" "$IMPORT_DONE" "$RUN_EXIT" "$RUN_ERRORS" "$FRAMES" "$LENGTH" <<'EOF'
import datetime, json, sys
path, version, import_exit, import_errors, import_done, run_exit, run_errors, frames, length = sys.argv[1:]
captures = []
if int(frames):
    captures = [
        {"file": "media/startup.mp4", "caption": f"First {length} s after launch: desktop window, XR off, no input"},
        {"file": "media/startup-first.jpg", "caption": "2 s after launch"},
        {"file": "media/startup-end.jpg", "caption": f"{length} s after launch"},
    ]
data = {
    "checked": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "godot": version,
    "import": {"ok": import_errors == "0" and (import_exit == "0" or import_done != "0"), "errors": int(import_errors),
               "crashed_on_exit": import_exit != "0"},
    "startup": {"exit": int(run_exit), "script_errors": int(run_errors), "frames": int(frames)},
    "captures": captures,
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"[capture] {path.split('/runs/')[1]}: import {'ok' if data['import']['ok'] else 'FAILED'} "
      f"({import_errors} script errors), {frames} frames, {run_errors} script errors at start-up")
EOF
