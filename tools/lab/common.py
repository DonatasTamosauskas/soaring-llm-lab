"""Paths, run loading and small helpers shared by the lab commands."""
import datetime as dt
import json
import os
import re
import subprocess
from zoneinfo import ZoneInfo

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNS = os.path.join(ROOT, "runs")
RAW = os.path.join(ROOT, "raw")
EVAL = os.path.join(ROOT, "eval")
LOCAL_TZ = ZoneInfo("Europe/Amsterdam")


def load_json(path, default=None):
    if not os.path.exists(path):
        return default
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def run_ids(selected=None):
    """Every run folder that has a run.json, or the selected ones (checked to exist)."""
    ids = sorted(d for d in os.listdir(RUNS) if os.path.isfile(os.path.join(RUNS, d, "run.json")))
    if not selected:
        return ids
    unknown = [s for s in selected if s not in ids]
    if unknown:
        raise SystemExit("unknown run(s): " + ", ".join(unknown))
    return list(selected)


def run_dir(run_id):
    return os.path.join(RUNS, run_id)


def load_run(run_id):
    return load_json(os.path.join(RUNS, run_id, "run.json"))


_FRACTION = re.compile(r"\.(\d+)")


def parse_ts(s):
    """ISO-8601 timestamp with Z or an offset -> aware datetime (Python 3.9 wants 3 or 6 fraction digits)."""
    s = s.replace("Z", "+00:00")
    s = _FRACTION.sub(lambda m: "." + (m.group(1) + "000000")[:6], s, count=1)
    return dt.datetime.fromisoformat(s)


def iso(t):
    return t.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") if t else None


def local(t):
    return t.astimezone(LOCAL_TZ)


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args), check=True, capture_output=True, text=True).stdout


def repo_url():
    """This repo's page on GitHub (https://github.com/<owner>/<name>), from the origin remote; None elsewhere."""
    try:
        origin = git("remote", "get-url", "origin").strip()
    except subprocess.CalledProcessError:
        return None
    m = re.search(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$", origin)
    return f"https://github.com/{m.group(1)}" if m else None
