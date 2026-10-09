#!/usr/bin/env python3
"""Fix round 5: run the round-5 tests against the ROUND-4 flight sources to
show that each new test catches the defect it pins (it must fail on the old
code). The round-4 sources are kept in artifacts/flight/verify/r4_sources
(as .gd.txt; README there). A PRIVATE copy of the project is made in
.sandboxes/flight_r5old/proj with scripts/flight (and the lab scripts)
replaced by those sources and the current tests; it runs through that
copy's own tools/gd.sh, so the shared tree is never touched.

  python3 tests/shots/flight_r5_oldcode_check.py

Writes artifacts/flight/r5_old_code_check.json. Expected: every "must fail"
entry fails on the round-4 code. Some fail because a round-5 member does not
exist there (the test reads FlightEnv.agl, a tuning field, ...): those are
reported with their script error, and each such fix also has a mutant in
flight_mutants.py that breaks the behaviour, not the name. The "must pass"
entries pin behaviour round 4 already had (the verifier's mutant survivors):
they pass there and are covered by mutants instead.
"""
import os, subprocess, json, re, time, shutil

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(REPO, ".sandboxes", "flight_r5old")
ROOT = os.path.join(WORK, "proj")
SRC = os.path.join(REPO, "artifacts", "flight", "verify", "r4_sources")

# (suite, test filter, what it pins, must fail on round 4)
CHECKS = [
    ("flight/ground", "g1", "a touchdown eases in (legs, run-out): <= 0.45 x per tick", True),
    ("flight/ground", "g2", "a neutral glide comes to rest, never skims below V_min", True),
    ("flight/ground", "g3_run", "the run-out: v^2 / 2 mu g at mu g", True),
    ("flight/ground", "g3b", "run-out off an edge and into a wall", True),
    ("flight/ground", "g3c", "a take-off during the run-out keeps its speed", True),
    ("flight/ground", "g4", "flares near the ground land without a stun", True),
    ("flight/ground", "g5", "the stall guard near the ground", True),
    ("flight/ground", "g6", "the landing configuration only for a landing", True),
    ("flight/player_bird", "pb29", "resume from the pause menu: no wingbeat, no manoeuvre", True),
    ("flight/player_bird", "pb30", "a recenter mid-payout stops the rig's turn", True),
    ("flight/player_bird", "pb31", "long ticks never flap slow arms", True),
    ("flight/player_bird", "pb32", "growth ramp, near plane, XR nodes at a snap", True),
    ("flight/wing_input", "wi34", "engine frame hitches through the XR source", True),
    ("flight/perch", "p13", "a sparrow perches in the full 2.64 m/s breeze", True),
    ("flight/collision", "c12", "pressed against a wall the bird slides (slide continuation)", False),
    ("flight/perch", "p12", "no capture while tucked", False),
    ("flight/view_turn", "vt5", "ViewTurn with the tick length changing every tick", False),
    ("flight/collision", "c8b", "C8b with the forced-turn total pinned", False),
]


def sync():
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", "--exclude", "/.godot/", "--exclude", "/.sandboxes/",
                    "--exclude", "/artifacts/", "--exclude", "/.git/", REPO + "/", ROOT + "/"], check=True)
    for sub, dst in [("", "scripts/flight"), ("pose_sources", "scripts/flight/pose_sources"), ("dev", "scenes/dev")]:
        sd = os.path.join(SRC, sub)
        for f in os.listdir(sd):
            if f.endswith(".gd.txt"):
                shutil.copy(os.path.join(sd, f), os.path.join(ROOT, dst, f[:-4]))


def run(suite, test):
    env = dict(os.environ, GD_TIMEOUT="600")
    r = subprocess.run([os.path.join(ROOT, "tools", "gd.sh"), "flight_r5old", "--headless", "res://tests/runner.tscn",
                        "--", "--suite=" + suite, "--test=" + test], cwd=ROOT, env=env, capture_output=True, text=True)
    out = r.stdout + r.stderr
    m = re.search(r"===== (\d+) passed, (\d+) failed", out)
    p, fl = (int(m.group(1)), int(m.group(2))) if m else (0, -1)
    fails = []
    for line in out.splitlines():
        x = line.strip()
        if x.startswith("[test]"):
            x = x[len("[test]"):].strip()
            if x.startswith("- "):
                fails.append(x[2:])
    fails = fails[:6]
    errors = []
    for i, l in enumerate(out.splitlines()):
        if "SCRIPT ERROR" in l:
            errors.append(l.strip())
    return p, fl, fails, errors[:3]


def main():
    sync()
    results = []
    for suite, test, what, must in CHECKS:
        t0 = time.time()
        p, fl, fails, errors = run(suite, test)
        failed = fl != 0
        ok = failed == must
        print("[r5old] %-20s %-8s %s on round 4 (%s)%s" % (suite, test, "FAILS" if failed else "passes",
              "as expected" if ok else "UNEXPECTED", " script errors" if errors else ""), flush=True)
        for x in (fails[:3] or errors[:2]):
            print("          " + x[:200])
        results.append({"suite": suite, "test": test, "pins": what, "must_fail_on_round4": must,
                        "fails_on_round4": failed, "as_expected": ok, "passed": p, "failed": fl,
                        "first_failures": fails, "script_errors": errors, "seconds": round(time.time() - t0, 1)})
    out = os.path.join(REPO, "artifacts", "flight", "r5_old_code_check.json")
    json.dump({"generated_by": "tests/shots/flight_r5_oldcode_check.py", "time": time.strftime("%Y-%m-%d %H:%M:%S"),
               "round4_sources": "artifacts/flight/verify/r4_sources", "results": results}, open(out, "w"), indent=1)
    print("[r5old] %d of %d as expected; report %s" % (sum(1 for r in results if r["as_expected"]), len(results), out))


main()
