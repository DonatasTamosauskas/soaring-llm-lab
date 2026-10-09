#!/bin/bash
# Gameplay capture of a Godot run with scripted desktop input, on a scratch copy so the archived
# project stays untouched.
#
#   tools/capture_gameplay_godot.sh RUN [seconds]
#
# 1. Copies runs/RUN/project to raw/_work/RUN/gameplay/project (kept out of git), applies
#    eval/capture-input/RUN.patch if there is one (only to get a desktop view, never game logic),
#    adds the input driver (eval/capture-input/driver.gd) with the run's timeline
#    (eval/capture-input/RUN.gd) as an autoload, pins the window to 1280x720, gives the copy its
#    own emptied user:// folder (a first launch, real saves untouched) and imports it headless.
# 2. Runs the main scene in a desktop window with XR off (Vulkan, Forward+, 1280x720, fixed 30 fps)
#    for SECONDS through Godot's movie writer while the timeline presses keys. A window opens on
#    top of your screen for two to three minutes; leave it visible and keep the pointer and the
#    keyboard off it (the cursor stays free, but a build that reads mouse motion or polls keys
#    without capturing them, like Prime Muse, would see your input too).
# 3. Writes runs/RUN/media/gameplay.mp4, gameplay.poster.jpg and gameplay-1.jpg, -2, ... and merges
#    them into runs/RUN/checks.json ("captures" entries and a "gameplay" block); other keys are kept.
#
# The timeline file carries the capture settings in "#:" lines:
#   #: seconds: 36                      default length (the SECONDS argument overrides it)
#   #: caption: Scripted flight ...      caption of the video
#   #: still: 9.5 | caption             a still at 9.5 s (one line per still)
#   #: poster: 20                       poster frame time
#   #: args: --some-flag                user arguments passed to the game after "--"
#
# DRY=1          tuning pass: prepares the copy and plays the timeline headless in a few seconds (no
#                window, no media) and prints the "[capture-input]" steps and once-a-second positions.
# KEEP_FRAMES=1  keeps the PNG frames in raw/_work/RUN/gameplay/frames (removed by default, ~0.4 GB).
# ENCODE_ONLY=1  re-encodes kept frames (after changing stills, poster or captions) without recording.
# If the window stopped drawing part-way (covered, minimised), the run stops without touching the
# media (exit 5); ALLOW_STALLS=1 keeps it anyway.
# GODOT and FFMPEG override the binaries (default: godot on PATH, ffmpeg on PATH or ~/.juicylucy/bin).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${1:?usage: tools/capture_gameplay_godot.sh RUN [seconds]}"
SRC="$ROOT/runs/$RUN/project"
INPUT="$ROOT/eval/capture-input"
TIMELINE="$INPUT/$RUN.gd"
PATCH="$INPUT/$RUN.patch"
WORK="$ROOT/raw/_work/$RUN/gameplay"
OUT="$ROOT/runs/$RUN/media"
GODOT="${GODOT:-godot}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo "$HOME/.juicylucy/bin/ffmpeg")}"
FPS=30
# The copy's own user:// folder, under Godot's data folder (macOS, else the XDG one).
USER_DIR_NAME="soaring-capture-$RUN"
if [ "$(uname)" = Darwin ]; then DATA_HOME="$HOME/Library/Application Support"; else DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"; fi

[ -f "$SRC/project.godot" ] || { echo "[gameplay] not a Godot project: $SRC" >&2; exit 2; }
[ -f "$TIMELINE" ] || { echo "[gameplay] no input timeline: $TIMELINE" >&2; exit 2; }
setting() { sed -n -E "s/^#: $1: *//p" "$TIMELINE"; }
LENGTH="${2:-$(setting seconds | head -1)}"
LENGTH="${LENGTH:-36}"
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
read -r -a GAME_ARGS <<<"$(setting args | head -1)"
mkdir -p "$WORK" "$OUT"

if [ "${ENCODE_ONLY:-0}" != 1 ]; then
	# 1. Scratch copy, patch, driver. rsync restores any file a previous patch changed; .godot (the
	#    import cache) is excluded and therefore kept between captures.
	rsync -a --delete --exclude '/.godot/' --exclude '/build/' --exclude '/artifacts/' --exclude '/.sandboxes/' \
		--exclude '/android/' "$SRC/" "$WORK/project/"
	PATCHED=0
	if [ -f "$PATCH" ]; then
		patch -p1 --forward --no-backup-if-mismatch -d "$WORK/project" <"$PATCH" >"$WORK/patch.log" 2>&1 \
			|| { cat "$WORK/patch.log" >&2; echo "[gameplay] patch failed: $PATCH" >&2; exit 3; }
		PATCHED=1
	fi
	mkdir -p "$WORK/project/capture_input"
	cp "$INPUT/driver.gd" "$WORK/project/capture_input/driver.gd"
	sed 's#^extends "driver.gd"#extends "res://capture_input/driver.gd"#' "$TIMELINE" >"$WORK/project/capture_input/timeline.gd"
	# Register the driver as an autoload, pin the window to 1280x720 and give the copy its own
	# user:// folder (emptied before each run below); see tools/godot_overrides.py.
	python3 "$ROOT/tools/godot_overrides.py" "$WORK/project/project.godot" --user-dir "$USER_DIR_NAME" \
		--autoload CaptureInput=res://capture_input/timeline.gd
	# Every capture starts like a first launch.
	[ -n "$USER_DIR_NAME" ] && rm -rf "${DATA_HOME:?}/$USER_DIR_NAME"

	VERSION="$("$GODOT" --version 2>/dev/null | tail -1)"
	deadline 900 "$GODOT" --headless --path "$WORK/project" --import --xr-mode off >"$WORK/import.log" 2>&1
	# Godot 4.7.2 can crash on exit after a headless import has finished; that is the engine, not the
	# project, so only script and parse errors count.
	IMPORT_ERRORS=$(grep -cE 'SCRIPT ERROR|Parse Error|Failed to load script|Compile Error' "$WORK/import.log")
	[ "$IMPORT_ERRORS" -eq 0 ] || grep -E 'SCRIPT ERROR|Parse Error|Failed to load script|Compile Error' -A2 "$WORK/import.log" >&2

	if [ "${DRY:-0}" = 1 ]; then
		deadline $((LENGTH * 4 + 120)) "$GODOT" --headless --path "$WORK/project" --xr-mode off --fixed-fps "$FPS" \
			--quit-after $((LENGTH * FPS)) ${GAME_ARGS[@]+-- "${GAME_ARGS[@]}"} >"$WORK/dry.log" 2>&1
		grep -E '^\[capture-input\]|SCRIPT ERROR|Parse Error' "$WORK/dry.log"
		exit 0
	fi

	# 2. Record. Vulkan (MoltenVK) for every build: the movie writer cannot read frames back under
	#    Metal. The window is kept on top: macOS stops drawing a window that is covered or on another
	#    Space, and the movie writer then keeps saving the last image while the game plays on unseen.
	rm -rf "$WORK/frames" && mkdir -p "$WORK/frames"
	echo "[gameplay] recording $RUN for $LENGTH s: a Godot window opens on top; leave it visible, pointer off it, until it closes"
	deadline $((LENGTH * 10 + 120)) "$GODOT" --path "$WORK/project" --xr-mode off --rendering-driver vulkan \
		--rendering-method forward_plus --resolution 1280x720 --always-on-top --fixed-fps "$FPS" \
		--write-movie "$WORK/frames/frame.png" --quit-after $((LENGTH * FPS)) \
		${GAME_ARGS[@]+-- "${GAME_ARGS[@]}"} >"$WORK/gameplay.log" 2>&1
	RUN_EXIT=$?
	printf 'VERSION=%q\nIMPORT_ERRORS=%s\nPATCHED=%s\nRUN_EXIT=%s\n' "$VERSION" "$IMPORT_ERRORS" "$PATCHED" "$RUN_EXIT" >"$WORK/record.env"
else
	[ -f "$WORK/record.env" ] && [ -d "$WORK/frames" ] || { echo "[gameplay] no kept frames in $WORK (record with KEEP_FRAMES=1)" >&2; exit 2; }
	# shellcheck source=/dev/null
	. "$WORK/record.env"
fi

RUN_ERRORS=$(grep -cE 'SCRIPT ERROR|Parse Error|Failed to load script' "$WORK/gameplay.log")
FRAMES=$(find "$WORK/frames" -name '*.png' | wc -l | tr -d ' ')
grep -E '^\[capture-input\]' "$WORK/gameplay.log" >"$WORK/input.log"
[ "$FRAMES" -gt 0 ] || { tail -20 "$WORK/gameplay.log" >&2; echo "[gameplay] no frames recorded (exit $RUN_EXIT)" >&2; exit 4; }
# The movie writer's summary counts the frames it actually drew; fewer than it saved means repeats.
DRAWN=$(sed -n -E 's/^([0-9]+) frames at [0-9]+ FPS.*/\1/p' "$WORK/gameplay.log" | tail -1)
DRAWN="${DRAWN:-$FRAMES}"
if [ "$DRAWN" -lt $((FRAMES - 2)) ] && [ "${ALLOW_STALLS:-0}" != 1 ]; then
	echo "[gameplay] only $DRAWN of $FRAMES frames were drawn (the window was hidden or covered); media left unchanged." >&2
	echo "[gameplay] record again with the window visible, or set ALLOW_STALLS=1 to keep it anyway" >&2
	exit 5
fi

# 3. Encode: the start-up capture's H.264 settings, one step smaller (crf 28) for the longer clip.
#    -nostdin keeps ffmpeg from eating the still list it is called inside.
encode() { "$FFMPEG" -nostdin -loglevel error -y "$@"; }
frame_at() { # seconds -> path of the frame shown at that time
	local n
	n=$(python3 -c "import sys; print(max(1, min(int(sys.argv[2]), round(float(sys.argv[1]) * $FPS) + 1)))" "$1" "$FRAMES")
	find "$WORK/frames" -name '*.png' | sort | sed -n "${n}p;${n}q"
}
FIRST_FRAME=$(find "$WORK/frames" -name '*.png' | sort | head -1)
PATTERN="$WORK/frames/$(basename "$FIRST_FRAME" | sed -E 's/[0-9]+\.png$//')%08d.png"
encode -framerate "$FPS" -i "$PATTERN" \
	-vf "scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2" \
	-c:v libx264 -preset slow -crf 28 -pix_fmt yuv420p -movflags +faststart "$OUT/gameplay.mp4"
POSTER="$(setting poster | head -1)"
encode -i "$(frame_at "${POSTER:-$((LENGTH / 2))}")" -vf "scale='min(1600,iw)':-2" -q:v 3 "$OUT/gameplay.poster.jpg"
rm -f "$OUT"/gameplay-[0-9]*.jpg
STILLS="$WORK/stills.tsv" && : >"$STILLS"
N=0
while IFS='|' read -r AT CAPTION; do
	N=$((N + 1))
	AT="$(echo "$AT" | tr -d ' ')"
	encode -i "$(frame_at "$AT")" -vf "scale='min(1600,iw)':-2" -q:v 3 "$OUT/gameplay-$N.jpg"
	printf 'media/gameplay-%s.jpg\t%s\t%s\n' "$N" "$AT" "$(echo "$CAPTION" | sed -E 's/^ +//')" >>"$STILLS"
done < <(setting still)
[ "${KEEP_FRAMES:-0}" = 1 ] || [ "${ENCODE_ONLY:-0}" = 1 ] || rm -rf "$WORK/frames"

python3 - "$ROOT/runs/$RUN/checks.json" "$RUN" "$VERSION" "$RUN_EXIT" "$RUN_ERRORS" "$FRAMES" "$DRAWN" "$PATCHED" \
	"$IMPORT_ERRORS" "$(setting caption | head -1)" "$STILLS" <<'EOF'
import datetime, json, os, sys
path, run, version, run_exit, run_errors, frames, drawn, patched, import_errors, caption, stills = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) else {}
seconds = round(int(frames) / 30, 1)
captures = [c for c in data.get("captures", []) if not c.get("file", "").startswith("media/gameplay")]
captures.append({"file": "media/gameplay.mp4", "caption": caption or f"Scripted flight on desktop, XR off ({seconds:g} s)"})
for line in open(stills):
    file, at, text = line.rstrip("\n").split("\t")
    when = f"{float(at):g} s into the recording"
    captures.append({"file": file, "caption": f"{text} ({when})" if text else when})
data["captures"] = captures
data["gameplay"] = {
    "checked": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "godot": version,
    "seconds": seconds,
    "frames": int(frames),
    "frames_drawn": int(drawn),
    "exit": int(run_exit),
    "script_errors": int(run_errors),
    "import_errors": int(import_errors),
    "input": f"eval/capture-input/{run}.gd",
}
if patched == "1":
    data["gameplay"]["patch"] = f"eval/capture-input/{run}.patch"
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
size = os.path.getsize(os.path.join(os.path.dirname(path), "media", "gameplay.mp4")) / 1e6
print(f"[gameplay] {run}: {frames} frames ({seconds:g} s, {drawn} drawn), gameplay.mp4 {size:.1f} MB, "
      f"{run_errors} script errors, exit {run_exit}{', patched' if patched == '1' else ''}")
EOF
