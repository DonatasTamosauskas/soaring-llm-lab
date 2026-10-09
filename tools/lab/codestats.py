"""Code, test, docs and asset statistics for a run's project, from the files git tracks, plus the
run's commit history in this repo."""
import os
import re

import common

LANGUAGES = {".gd": "GDScript", ".cs": "C#", ".gdshader": "Shader", ".shader": "Shader", ".hlsl": "Shader",
             ".cginc": "Shader", ".compute": "Shader", ".py": "Python", ".sh": "Shell", ".js": "JavaScript",
             ".mjs": "JavaScript", ".ts": "TypeScript"}
SCENE_DATA = {".tscn", ".tres", ".scn", ".res", ".unity", ".prefab", ".asset", ".mat", ".controller", ".anim",
              ".inputactions", ".shadergraph", ".json", ".cfg"}
ASSET_KINDS = {".png": "textures", ".jpg": "textures", ".jpeg": "textures", ".exr": "textures", ".tga": "textures",
               ".webp": "textures", ".hdr": "textures", ".psd": "textures", ".svg": "textures",
               ".glb": "models", ".gltf": "models", ".fbx": "models", ".obj": "models", ".blend": "models",
               ".wav": "audio", ".ogg": "audio", ".mp3": "audio", ".flac": "audio",
               ".mp4": "video", ".webm": "video", ".mov": "video", ".gif": "video"}
# Third-party and engine-generated folders: not the agent's work. Matched anywhere in the path.
DEFAULT_EXCLUDE = {
    "Godot": ["addons/", "android/", ".godot/"],
    "Unity": ["Library/", "Packages/", "ProjectSettings/", "UserSettings/", "Assets/Samples/",
              "Assets/VRTemplateAssets/", "Assets/TextMesh Pro/", "Assets/XR/", "Assets/XRI/",
              "Assets/CompositionLayers/", "Assets/Oculus/", "Assets/Plugins/"],
}
TEST_DEFINITION = {
    "GDScript": re.compile(r"^\s*func\s+test_?\w*\s*\(", re.M),
    "C#": re.compile(r"\[\s*(?:Test|UnityTest|TestCase)\b"),
    "Python": re.compile(r"^\s*def\s+test_\w*\s*\(", re.M),
}
_TEST_FILE = re.compile(r"(^test_|_test\.|Tests?\.cs$)")
HOUSEKEEPING_TRAILER = "Lab-Housekeeping"


def _role(rel, language):
    """game / test / tooling: tests by folder or file name; Python, shell, tools/ and Unity
    Editor/ scripts are tooling (they run at build or verification time, not in the game)."""
    parts = rel.split("/")
    folders = parts[:-1]
    if any(p.lower() in ("tests", "test") for p in folders) or _TEST_FILE.search(parts[-1]):
        return "test"
    if language in ("Python", "Shell") or any(p.lower() == "tools" for p in folders) or "Editor" in folders:
        return "tooling"
    return "game"


def measure(run_id, run):
    project = os.path.join("runs", run_id, "project")
    engine = run.get("engine", {}).get("name")
    exclude = DEFAULT_EXCLUDE.get(engine, []) + run.get("code_exclude", [])
    out = {
        "files_tracked": 0, "bytes_tracked": 0, "excluded": exclude,
        "code": {r: {"files": 0, "loc": 0} for r in ("game", "test", "tooling")},
        "loc_by_language": {}, "tests_defined": 0,
        "docs": {"files": 0, "lines": 0},
        "scene_data": {"files": 0, "bytes": 0},
        "assets": {k: {"files": 0, "bytes": 0} for k in ("textures", "models", "audio", "video")},
    }
    for path in common.git("ls-files", "-z", "--", project).split("\0"):
        if not path:
            continue
        rel = path[len(project) + 1:]
        full = os.path.join(common.ROOT, path)
        if not os.path.isfile(full):
            continue
        size = os.path.getsize(full)
        out["files_tracked"] += 1
        out["bytes_tracked"] += size
        if any(("/" + pattern) in ("/" + rel) for pattern in exclude):
            continue
        ext = os.path.splitext(rel)[1].lower()
        if ext in LANGUAGES or ext == ".md":
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read()
            loc = sum(1 for line in text.splitlines() if line.strip())
            if ext == ".md":
                out["docs"]["files"] += 1
                out["docs"]["lines"] += loc
                continue
            language = LANGUAGES[ext]
            role = _role(rel, language)
            out["code"][role]["files"] += 1
            out["code"][role]["loc"] += loc
            if role == "game":
                out["loc_by_language"][language] = out["loc_by_language"].get(language, 0) + loc
            if role == "test" and language in TEST_DEFINITION:
                out["tests_defined"] += len(TEST_DEFINITION[language].findall(text))
        elif ext in SCENE_DATA:
            out["scene_data"]["files"] += 1
            out["scene_data"]["bytes"] += size
        elif ext in ASSET_KINDS:
            kind = out["assets"][ASSET_KINDS[ext]]
            kind["files"] += 1
            kind["bytes"] += size
    return out


def _housekeeping():
    """Commits that only moved or imported builds in this lab, not the agents' own work."""
    shas = set()
    path = os.path.join(common.EVAL, "housekeeping-commits.txt")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.split("#")[0].strip()
                if line:
                    shas.add(line.split()[0])
    return shas


def git_activity(run_id, run):
    """The agent's commits in this repo: those touching the run's current or earlier paths,
    minus housekeeping (listed in eval/housekeeping-commits.txt or marked with a trailer)."""
    paths = [os.path.join("runs", run_id, "project")] + run.get("git_paths", [])
    # One record per commit (\x1e-separated): the trailer value can span lines.
    log = common.git("log", f"--format=%H%x1f%aI%x1f%(trailers:key={HOUSEKEEPING_TRAILER},valueonly)%x1e", "--", *paths)
    skip = _housekeeping()
    commits = []
    for record in log.split("\x1e"):
        fields = record.strip().split("\x1f")
        if len(fields) < 2:
            continue
        sha, when, trailer = (fields + [""])[:3]
        if trailer.strip() or any(sha.startswith(s) for s in skip):
            continue
        commits.append(when)
    if not commits:
        return {"commits": 0}
    first, last = min(commits, key=common.parse_ts), max(commits, key=common.parse_ts)
    span = (common.parse_ts(last) - common.parse_ts(first)).total_seconds() / 3600
    return {"commits": len(commits), "first": first, "last": last, "span_h": round(span, 2)}
