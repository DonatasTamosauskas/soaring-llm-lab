"""Turn each run's chosen screenshots and videos into compact, uniform copies in runs/<run>/media/.

run.json lists them under "media": {"source": path relative to the run folder, "file": name in
media/, "caption": ...}. Images become JPEGs at most 1600 px wide; videos become H.264 MP4s at most
720 px high with a poster frame, so the gallery loads quickly and the repo stays small.
"""
import os
import shutil
import subprocess

import common

IMAGE = {".png", ".jpg", ".jpeg", ".webp", ".exr", ".tga"}
VIDEO = {".mp4", ".webm", ".mov", ".avi", ".gif", ".mkv"}


def ffmpeg():
    found = os.environ.get("FFMPEG") or shutil.which("ffmpeg")
    fallback = os.path.expanduser("~/.juicylucy/bin/ffmpeg")
    if not found and os.path.exists(fallback):
        found = fallback
    if not found:
        raise SystemExit("ffmpeg not found: install it or set FFMPEG=/path/to/ffmpeg")
    return found


def _run(args):
    subprocess.run([ffmpeg(), "-loglevel", "error", "-y"] + args, check=True)


def poster_path(video_path):
    return os.path.splitext(video_path)[0] + ".poster.jpg"


def build(run_id, run):
    """(Re)build the media of a run whose source changed. Returns the number of files written."""
    base = common.run_dir(run_id)
    out_dir = os.path.join(base, "media")
    written = 0
    for item in run.get("media", []):
        src = os.path.normpath(os.path.join(base, item["source"]))
        dst = os.path.join(out_dir, item["file"])
        if not os.path.exists(src):
            print(f"  ! {run_id}: missing media source {item['source']}")
            continue
        if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
            continue
        os.makedirs(out_dir, exist_ok=True)
        ext = os.path.splitext(src)[1].lower()
        if ext in IMAGE:
            _run(["-i", src, "-vf", "scale='min(1600,iw)':-2", "-q:v", "3", dst])
        elif ext in VIDEO:
            _run(["-i", src, "-vf", "scale=-2:'min(720,ih)'", "-c:v", "libx264", "-preset", "slow", "-crf", "28",
                  "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "96k", dst])
            _run(["-ss", str(item.get("poster_at", 2)), "-i", dst, "-frames:v", "1", "-q:v", "3", poster_path(dst)])
        else:
            print(f"  ! {run_id}: unknown media type {item['source']}")
            continue
        written += 1
    return written
