#!/usr/bin/env python3
"""Sequential Godot verification; never shares an import cache across workers."""
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"


def run(label, args, timeout=120):
    start = time.monotonic()
    result = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = result.stdout
    (ARTIFACTS / f"{label}.log").write_text(output)
    failures = bool(re.search(r"SCRIPT ERROR|Parse Error|ERROR:|(?<![=\d])[1-9]\d* failures\b|failures=[1-9]\d*", output))
    if result.returncode or failures:
        print(output)
        raise RuntimeError(f"{label} failed (exit {result.returncode}); inspect artifacts/{label}.log")
    evidence = [line for line in output.splitlines() if re.search(r"checks|EVIDENCE|SMOKE|CAPTURE", line)]
    print(f"PASS {label} ({time.monotonic()-start:.1f}s)")
    for line in evidence:
        print("  " + line[:600])
    return {"name": label, "seconds": round(time.monotonic()-start, 2), "passed": True, "evidence": evidence}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--visual", action="store_true")
    parser.add_argument("--skip-import", action="store_true")
    opts = parser.parse_args()
    godot = shutil.which("godot") or shutil.which("godot4")
    if not godot:
        raise SystemExit("Install Godot 4.7.2 or provide godot on PATH.")
    ARTIFACTS.mkdir(exist_ok=True)
    checks = []
    base = [godot, "--path", str(ROOT), "--xr-mode", "off"]
    if not opts.skip_import:
        checks.append(run("import", base + ["--headless", "--editor", "--import", "--log-file", str(ARTIFACTS / "import-engine.log")]))
    for area in ("flight", "world", "ecology", "game"):
        args = base + ["--headless", "--audio-driver", "Dummy", "--fixed-fps", "90", "--script", f"res://tests/test_{area}.gd", "--log-file", str(ARTIFACTS / f"{area}-test-engine.log")]
        if area == "ecology":
            args += ["--", "--real-world"]
        checks.append(run(area, args))
    if opts.visual:
        checks.append(run('mobile-render', base + ['--rendering-method', 'mobile', '--script', 'res://tests/render_world.gd', '--log-file', str(ARTIFACTS / 'mobile-render-engine.log')]))
        for mode in ("nest", "overview", "town", "grove", "flight", "guide", "paused"):
            extra = ["--auto-start"] if mode == "flight" else []
            args = base + ["--rendering-method", "forward_plus", "--log-file", str(ARTIFACTS / f"{mode}-engine.log"), "--", f"--capture-mode={mode}", f"--capture={ARTIFACTS / (mode+'.png')}", "--smoke-seconds=6", f"--report={ARTIFACTS / (mode+'.json')}"] + extra
            checks.append(run('capture-' + mode, args))
    report = {"godot": subprocess.check_output([godot, "--version"], text=True).strip(), "checks": checks}
    (ARTIFACTS / "verification.json").write_text(json.dumps(report, indent=2))
    print(f"All {len(checks)} verification stages passed. Visual captures still require inspection.")


if __name__ == "__main__":
    main()
