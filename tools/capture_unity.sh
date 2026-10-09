#!/bin/bash
# Import check, start-up capture and scripted gameplay capture of a Unity run, on a scratch copy
# so the archived project stays untouched.
#
#   tools/capture_unity.sh RUN [all|import|startup|gameplay|clean|captions]
#
#   all (default)  import check, one macOS player build, start-up and gameplay captures, then
#                  deletes the copy's Library/, the player and the frames (KEEP=1 keeps them)
#   import         copy and import check only
#   startup        import, build, start-up capture; keeps Library/ so a re-run is quick
#   gameplay       import, build, gameplay capture; keeps Library/
#   clean          deletes the copy's Library/, the player, the frames and the player's data folder
#   captions       rewrites the captions and notes in checks.json from RUN.json (after reviewing the frames)
#
# 1. Copies runs/RUN/project/<project> to raw/_work/RUN/Soaring (kept out of git; Library/ and build
#    output are not copied) and opens it in batch mode with the installed Unity, accepting a version
#    upgrade in the copy. Counts distinct C# compile errors (error CSxxxx) in the Editor log.
# 2. Applies eval/capture-unity/RUN.patch.py to the copy when there is one (a documented fix a
#    player needs to load at all), adds eval/capture-unity/LabCapture.cs and LabCaptureBuild.cs and,
#    when present, the run's gameplay driver eval/capture-unity/RUN.cs (as LabDriver.cs), and builds
#    a macOS player with "Initialize XR on Startup" off. LabCaptureBuild.cs lists every setting it
#    changes.
# 3. Start-up: the player in a 1280x720 window, no input, fixed 30 fps, STARTUP_SECONDS (12) long.
#    Gameplay: the same with the driver's scripted input, gameplay_seconds long (from RUN.json).
#    A player window opens on your screen while each one records.
# 4. Writes runs/RUN/media/startup.mp4 (+ poster), startup-first.jpg (2 s), startup-end.jpg,
#    gameplay.mp4 (+ poster) and gameplay-N.jpg, and merges results into runs/RUN/checks.json.
#
# eval/capture-unity/RUN.json (optional) sets: project (folder under project/), player_args,
# gameplay_seconds, gameplay_stills (seconds), gameplay_poster (seconds), captions, notes.
# UNITY and FFMPEG override the binaries (default: Unity 6000.6.4f1 from Unity Hub, ffmpeg on PATH
# or ~/.juicylucy/bin).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="${1:?usage: tools/capture_unity.sh RUN [all|import|startup|gameplay|clean|captions]}"
MODE="${2:-all}"
UNITY="${UNITY:-/Applications/Unity/Hub/Editor/6000.6.4f1/Unity.app/Contents/MacOS/Unity}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo "$HOME/.juicylucy/bin/ffmpeg")}"
STARTUP_SECONDS="${STARTUP_SECONDS:-12}"
FPS=30
LAB="$ROOT/eval/capture-unity"
CONF="$LAB/$RUN.json"
WORK="$ROOT/raw/_work/$RUN"
COPY="$WORK/Soaring"
APP="$WORK/player/LabCapture.app"
OUT="$ROOT/runs/$RUN/media"
COMPANY="SoaringLab-${RUN//./_}" # Unity turns dots in a company name into underscores

say() { echo "[capture] $*"; }
deadline() { perl -e 'alarm shift; exec @ARGV' "$@"; }
conf() { # KEY [DEFAULT]: a value from RUN.json; lists come out space-separated
	python3 -I - "$CONF" "$1" "${2:-}" <<'EOF'
import json, os, sys
path, key, default = sys.argv[1:]
value = json.load(open(path)).get(key, default) if os.path.exists(path) else default
print(" ".join(str(v) for v in value) if isinstance(value, list) else value)
EOF
}

[ -d "$ROOT/runs/$RUN" ] || { say "no such run: $RUN" >&2; exit 2; }
PROJECT="$(conf project)"
if [ -z "$PROJECT" ]; then
	VERSION_FILE="$(find "$ROOT/runs/$RUN/project" -maxdepth 3 -path '*/ProjectSettings/ProjectVersion.txt' | head -1)"
	PROJECT="$(basename "$(dirname "$(dirname "$VERSION_FILE")")")"
fi
SRC="$ROOT/runs/$RUN/project/$PROJECT"
[ -f "$SRC/ProjectSettings/ProjectVersion.txt" ] || { say "not a Unity project: $SRC" >&2; exit 2; }

clean() {
	rm -rf "$COPY/Library" "$COPY/Temp" "$COPY/Logs" "$WORK/player" "$WORK"/frames-*
	reset_player_data
	say "cleaned $WORK (logs and the copy's sources kept)"
}
reset_player_data() { # the build saves under its own company name; start each recording fresh
	rm -rf "$HOME/Library/Application Support/$COMPANY" "$HOME/Library/Application Support/com.$COMPANY."*
	for plist in "$HOME/Library/Preferences/unity.$COMPANY."*.plist "$HOME/Library/Preferences/com.$COMPANY."*.plist; do
		[ -e "$plist" ] && { defaults delete "$(basename "$plist" .plist)" >/dev/null 2>&1; rm -f "$plist"; }
	done
	return 0
}
[ "$MODE" = clean ] && { clean; exit 0; }
if [ "$MODE" = captions ]; then
	python3 -I - "$ROOT/runs/$RUN/checks.json" "$CONF" <<'EOF'
import json, os, sys
path, conf_path = sys.argv[1:]
captions = json.load(open(conf_path)).get("captions", {}) if os.path.exists(conf_path) else {}
data = json.load(open(path))
for c in data.get("captures", []):
    key = os.path.splitext(os.path.basename(c["file"]))[0]
    if key in captions:
        c["caption"] = captions[key]
conf = json.load(open(conf_path)) if os.path.exists(conf_path) else {}
if conf.get("notes"):
    data["notes"] = conf["notes"]
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[capture] captions updated in {path}")
EOF
	exit 0
fi
case "$MODE" in all|import|startup|gameplay) ;; *) say "unknown mode: $MODE" >&2; exit 2;; esac

# --- 1. Copy and import check ------------------------------------------------------------------
mkdir -p "$WORK" "$OUT"
rsync -a --delete --exclude '/Library/' --exclude '/Temp/' --exclude '/Logs/' --exclude '/build/' \
	--exclude '/Builds/' --exclude '/obj/' "$SRC/" "$COPY/"
SOURCE_VERSION="$(sed -n 's/^m_EditorVersion: //p' "$SRC/ProjectSettings/ProjectVersion.txt")"
UNITY_VERSION="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$UNITY")")")")")"
say "$RUN: importing $PROJECT ($SOURCE_VERSION) in Unity $UNITY_VERSION"
deadline 3600 "$UNITY" -batchmode -nographics -quit -projectPath "$COPY" -logFile "$WORK/import.log" >/dev/null 2>&1
IMPORT_EXIT=$?
if [ "$IMPORT_EXIT" != 0 ] && grep -qiE 'No valid Unity Editor license|license is not active|LICENSE SYSTEM.*(fail|error)' "$WORK/import.log"; then
	say "Unity licensing failed; see $WORK/import.log. Not changing licences; stopping." >&2
	exit 3
fi
IMPORT_ERRORS=$(grep -E 'error CS[0-9]+' "$WORK/import.log" | sort -u | wc -l | tr -d ' ')
say "import exit $IMPORT_EXIT, $IMPORT_ERRORS distinct C# compile errors"

# --- 2. Inject the capture scripts and build a desktop player ---------------------------------
BUILD_EXIT=-1
PATCH=""
if [ "$MODE" != import ]; then
	if [ -f "$LAB/$RUN.patch.py" ]; then # a per-run fix the copy needs before a player can load it
		python3 -I "$LAB/$RUN.patch.py" "$COPY" | sed 's/^/[capture] /'
		PATCH="eval/capture-unity/$RUN.patch.py"
	fi
	mkdir -p "$COPY/Assets/LabCapture/Editor"
	cp "$LAB/LabCapture.cs" "$COPY/Assets/LabCapture/LabCapture.cs"
	cp "$LAB/LabCaptureBuild.cs" "$COPY/Assets/LabCapture/Editor/LabCaptureBuild.cs"
	[ -f "$LAB/$RUN.cs" ] && cp "$LAB/$RUN.cs" "$COPY/Assets/LabCapture/LabDriver.cs"
	rm -rf "$WORK/player"
	say "building the macOS player"
	deadline 3600 "$UNITY" -batchmode -nographics -buildTarget OSXUniversal -projectPath "$COPY" \
		-executeMethod LabCaptureBuild.BuildMac -labBuild "$APP" -labCompany "$COMPANY" \
		-logFile "$WORK/build.log" >/dev/null 2>&1
	BUILD_EXIT=$?
	grep -E 'LAB_BUILD|LAB_XR' "$WORK/build.log" | sed 's/^/[capture]   /'
	[ "$BUILD_EXIT" = 0 ] || say "build failed (exit $BUILD_EXIT); see $WORK/build.log" >&2
fi

# --- 3. Record -----------------------------------------------------------------------------------
read -r -a PLAYER_ARGS <<<"$(conf player_args)"
record() { # KIND FRAMES
	local kind="$1" frames="$2" dir="$WORK/frames-$1" exe
	rm -rf "$dir" && mkdir -p "$dir"
	reset_player_data
	exe="$(ls "$APP/Contents/MacOS/" | head -1)"
	say "recording $kind: $frames frames at $FPS fps (a player window opens)"
	deadline $((frames / FPS * 15 + 240)) "$APP/Contents/MacOS/$exe" -screen-width 1280 -screen-height 720 \
		-screen-fullscreen 0 -logFile "$WORK/$kind.log" -labCapture "$dir" -labFrames "$frames" -labMode "$kind" \
		${PLAYER_ARGS[@]+"${PLAYER_ARGS[@]}"} >/dev/null 2>&1
	echo $? >"$WORK/$kind.exit"
	say "$kind: exit $(cat "$WORK/$kind.exit"), $(find "$dir" -name 'frame_*.jpg' | wc -l | tr -d ' ') frames; $(grep -h 'LAB_CAPTURE_DONE' "$WORK/$kind.log")"
}
SCALE="scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
frame_file() { printf '%s/frames-%s/frame_%05d.jpg' "$WORK" "$1" "$2"; }
encode() { # KIND: the frames as H.264 for the report
	"$FFMPEG" -loglevel error -y -framerate "$FPS" -i "$WORK/frames-$1/frame_%05d.jpg" -vf "$SCALE" \
		-c:v libx264 -preset slow -crf 28 -pix_fmt yuv420p -movflags +faststart "$OUT/$1.mp4"
}
still() { # KIND FRAME-INDEX OUTPUT
	local index="$2" last
	last=$(($(find "$WORK/frames-$1" -name 'frame_*.jpg' | wc -l) - 1))
	[ "$index" -gt "$last" ] && index="$last"
	"$FFMPEG" -loglevel error -y -i "$(frame_file "$1" "$index")" -vf "$SCALE" -q:v 3 "$OUT/$3"
}
frames_of() { find "$WORK/frames-$1" -name 'frame_*.jpg' 2>/dev/null | wc -l | tr -d ' '; }

DID=""
if [ "$BUILD_EXIT" = 0 ] && { [ "$MODE" = all ] || [ "$MODE" = startup ]; }; then
	record startup $((STARTUP_SECONDS * FPS))
	if [ "$(frames_of startup)" -gt 0 ]; then
		encode startup
		still startup $((2 * FPS)) startup-first.jpg
		still startup 999999 startup-end.jpg
		cp "$OUT/startup-end.jpg" "$OUT/startup.poster.jpg"
	fi
	DID="$DID startup"
fi
GAMEPLAY_SECONDS="$(conf gameplay_seconds 36)"
if [ "$BUILD_EXIT" = 0 ] && { [ "$MODE" = all ] || [ "$MODE" = gameplay ]; }; then
	if [ -f "$LAB/$RUN.cs" ]; then
		record gameplay $((GAMEPLAY_SECONDS * FPS))
		if [ "$(frames_of gameplay)" -gt 0 ]; then
			encode gameplay
			n=0
			for s in $(conf gameplay_stills); do
				n=$((n + 1)); still gameplay "$(python3 -c "print(round($s * $FPS))")" "gameplay-$n.jpg"
			done
			still gameplay "$(python3 -c "print(round($(conf gameplay_poster 0) * $FPS))")" gameplay.poster.jpg
		fi
		DID="$DID gameplay"
	else
		say "no gameplay driver at eval/capture-unity/$RUN.cs; skipping gameplay"
	fi
fi

# --- 4. checks.json ------------------------------------------------------------------------------
python3 -I - "$ROOT" "$RUN" "$CONF" "$WORK" "$SRC" "$COPY" "$UNITY_VERSION" "$SOURCE_VERSION" "$IMPORT_EXIT" \
	"$IMPORT_ERRORS" "$BUILD_EXIT" "$DID" "$STARTUP_SECONDS" "$GAMEPLAY_SECONDS" "$PATCH" <<'EOF'
import datetime, json, os, sys
(root, run, conf_path, work, src, copy, unity, source_version, import_exit, import_errors, build_exit, did,
 startup_s, gameplay_s, patch) = sys.argv[1:]
conf = json.load(open(conf_path)) if os.path.exists(conf_path) else {}
captions = conf.get("captions", {})
path = os.path.join(root, "runs", run, "checks.json")
data = json.load(open(path)) if os.path.exists(path) else {}
media = os.path.join(root, "runs", run, "media")

def manifest(folder):
    try:
        return json.load(open(os.path.join(folder, "Packages", "manifest.json"))).get("dependencies", {})
    except OSError:
        return {}

data["checked"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
data["unity"] = unity
imp = {"ok": import_errors == "0" and import_exit == "0", "errors": int(import_errors)}
if import_exit != "0":
    imp["exit"] = int(import_exit)
if source_version != unity:
    imp["upgraded_from"] = source_version
    before, after = manifest(src), manifest(copy)
    changed = {k: f"{before.get(k, '-')} -> {v}" for k, v in after.items() if before.get(k) != v}
    if changed:
        imp["packages_upgraded"] = changed
data["import"] = imp
if build_exit != "-1":
    data["build"] = {"ok": build_exit == "0", "target": "macOS player (Apple silicon, Mono), XR init off"}
    if patch:
        data["build"]["patch"] = patch

def result(kind, seconds):
    folder = os.path.join(work, f"frames-{kind}")
    summary = {}
    try:
        summary = json.load(open(os.path.join(folder, "capture.json")))
    except OSError:
        pass
    frames = len([f for f in os.listdir(folder) if f.startswith("frame_")]) if os.path.isdir(folder) else 0
    exit_code = int(open(os.path.join(work, f"{kind}.exit")).read().strip() or -1)
    out = {"exit": exit_code, "frames": frames, "seconds": int(seconds)}
    for key in ("width", "height", "exceptions", "errors"):
        if key in summary:
            out[key] = summary[key]
    if summary.get("firstError"):
        out["first_error"] = summary["firstError"]
    return out, frames

engine = f"recorded from a macOS player build in Unity {unity}"
upgraded = f" (project upgraded from {source_version})" if source_version != unity else ""
defaults = {
    "startup": [("media/startup.mp4", f"Start-up on desktop, XR off, no input, {engine}{upgraded}"),
                ("media/startup-first.jpg", "2 s after launch (start-up capture)"),
                ("media/startup-end.jpg", f"{startup_s} s after launch (start-up capture)")],
}
stills = conf.get("gameplay_stills", [])
defaults["gameplay"] = [("media/gameplay.mp4", f"Scripted flight on desktop, XR off, {engine}")] + [
    (f"media/gameplay-{i}.jpg", f"Scripted flight, {s} s in") for i, s in enumerate(stills, 1)]

old = data.get("captures", [])
captures = []
for kind in ("startup", "gameplay"):
    if kind in did.split():
        res, frames = result(kind, startup_s if kind == "startup" else gameplay_s)
        if kind == "gameplay":
            res["driver"] = f"eval/capture-unity/{run}.cs"
        data[kind] = res
        if frames:
            for file, caption in defaults[kind]:
                key = os.path.splitext(os.path.basename(file))[0]
                if os.path.exists(os.path.join(root, "runs", run, file)):
                    captures.append({"file": file, "caption": captions.get(key, caption)})
    else:
        captures += [c for c in old if os.path.basename(c["file"]).startswith(kind)]
captures += [c for c in old if not os.path.basename(c["file"]).startswith(("startup", "gameplay"))]
data["captures"] = captures
if conf.get("notes"):
    data["notes"] = conf["notes"]
order = ["checked", "unity", "import", "build", "startup", "gameplay", "captures", "notes"]
data = {k: data[k] for k in order if k in data} | {k: v for k, v in data.items() if k not in order}
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[capture] runs/{run}/checks.json: import {'ok' if imp['ok'] else 'FAILED'} ({import_errors} compile errors)"
      + "".join(f", {k} {data[k]['frames']} frames (exit {data[k]['exit']})" for k in ("startup", "gameplay") if k in did.split()))
EOF

if [ "$MODE" = all ] && [ "${KEEP:-0}" != 1 ]; then clean; fi
