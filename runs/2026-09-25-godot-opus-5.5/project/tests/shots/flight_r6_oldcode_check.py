#!/usr/bin/env python3
"""Fix round 6: run the round-6 tests against the ROUND-5 flight sources to
show that each new test catches the defect it pins (it must fail on the old
code). The round-5 sources are kept in artifacts/flight/verify/r5_sources
(as .gd.txt; README there). A PRIVATE copy of the project is made in
.sandboxes/flight_r6old/proj with scripts/flight replaced by those sources
(except flight_geometry.gd, the tests' geometry helper, whose round-6
additions are test worlds only: slope() and gable_roof()) and the current
tests; it runs through that copy's own tools/gd.sh, so the shared tree is
never touched.

  python3 tests/shots/flight_r6_oldcode_check.py

Writes artifacts/flight/r6_old_code_check.json. Expected: every "must fail"
entry fails on the round-5 code on its own assertions (the tests read the
round-6 names defensively, so the old code runs). "must pass" entries pin
behaviour round 5 already had (the verifier's mutant survivors).
"""
import os, subprocess, json, re, time, shutil

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(REPO, ".sandboxes", "flight_r6old")
ROOT = os.path.join(WORK, "proj")
SRC = os.path.join(REPO, "artifacts", "flight", "verify", "r5_sources", "scripts_flight")
KEEP = {"flight_geometry.gd"}

# (suite, test filter, what it pins, must fail on round 5)
CHECKS = [
    ("flight/ground", "g1_touchdown", "touchdowns on slopes and roofs: no stun, <= 0.45 x per tick", True),
    ("flight/ground", "g1b", "steep touchdowns on the flat: <= 0.45 x per tick", True),
    ("flight/ground", "g3d", "the run-out along a slope's plane: v^2 / 2a", True),
    ("flight/ground", "g3e", "the run over a change of slope (a hill, a ridge)", True),
    ("flight/ground", "g5b", "the stall guard in the game (a tall flat roof)", True),
    ("flight/ground", "g8", "take-off facing up a slope: once, no touchdown loop", True),
    ("flight/ground", "g9", "take-off from a village roof facing the ridge", True),
    ("flight/ground", "g10", "bank away from a long slope after the take-off", True),
    ("flight/player_bird", "pb34", "telemetry read in an Events handler is not kept", True),
    ("flight/view_turn", "vt6", "the wrap at +-180 deg is exact (Godot's wrapf snaps)", True),
    ("flight/ground", "g1c", "a dive into the ground never jolts the view more than the body (round 5 had no skid legs)", False),
    ("flight/wing_input", "ws_copy", "WingState.copy_from copies every field (round 5 copied reflectively)", False),
    ("flight/player_bird", "pb33", "the game's XR source is frame-timed (the wiring round 5 had)", False),
    ("flight/perch", "p14", "a scrape too fast to perch locks the capture out (round 5 had it)", False),
]


def sync():
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", "--exclude", "/.godot/", "--exclude", "/.sandboxes/",
                    "--exclude", "/artifacts/", "--exclude", "/.git/", REPO + "/", ROOT + "/"], check=True)
    for sub, dst in [("", "scripts/flight"), ("pose_sources", "scripts/flight/pose_sources")]:
        sd = os.path.join(SRC, sub)
        for f in os.listdir(sd):
            if f.endswith(".gd.txt") and f[:-4] not in KEEP:
                shutil.copy(os.path.join(sd, f), os.path.join(ROOT, dst, f[:-4]))


def run(suite, test):
    env = dict(os.environ, GD_TIMEOUT="600")
    r = subprocess.run([os.path.join(ROOT, "tools", "gd.sh"), "flight_r6old", "--headless", "res://tests/runner.tscn",
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
    errors = [l.strip() for l in out.splitlines() if "SCRIPT ERROR" in l or "Parse Error" in l]
    return p, fl, fails[:6], errors[:3]


def main():
    sync()
    results = []
    for suite, test, what, must in CHECKS:
        t0 = time.time()
        p, fl, fails, errors = run(suite, test)
        failed = fl != 0
        ok = failed == must
        print("[r6old] %-20s %-12s %s on round 5 (%s)%s" % (suite, test, "FAILS" if failed else "passes",
              "as expected" if ok else "UNEXPECTED", " script errors" if errors else ""), flush=True)
        for x in (fails[:3] or errors[:2]):
            print("          " + x[:220])
        results.append({"suite": suite, "test": test, "pins": what, "must_fail_on_round5": must,
                        "fails_on_round5": failed, "as_expected": ok, "passed": p, "failed": fl,
                        "first_failures": fails, "script_errors": errors, "seconds": round(time.time() - t0, 1)})
    out = os.path.join(REPO, "artifacts", "flight", "r6_old_code_check.json")
    json.dump({"generated_by": "tests/shots/flight_r6_oldcode_check.py", "time": time.strftime("%Y-%m-%d %H:%M:%S"),
               "round5_sources": "artifacts/flight/verify/r5_sources", "results": results}, open(out, "w"), indent=1)
    print("[r6old] %d of %d as expected; report %s" % (sum(1 for r in results if r["as_expected"]), len(results), out))


main()
