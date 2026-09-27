#!/usr/bin/env python3
"""Fix round 4: run the round-4 tests against the ROUND-3 flight sources to
show that each new test catches the defect it pins (they must fail on the
old code). The round-3 sources are kept in artifacts/flight/verify/r3_sources
(as .gd.txt: the verifiers' sandbox copy of the code they reviewed, dated
10:18:47, the last round-3 edit). A PRIVATE copy of the project is made in
.sandboxes/flight_r4old/proj with scripts/flight replaced by those sources
and the current tests; it runs through that copy's own tools/gd.sh, so the
shared tree is never touched.

  python3 tests/shots/flight_r4_oldcode_check.py

Writes artifacts/flight/r4_old_code_check.json. Expected: every "must fail"
entry fails on the round-3 code, with the assertion named; FM-23b and
PB-19b pin contracts round 3 already had (they pass there and are covered
by mutants instead).
"""
import os, subprocess, json, re, time, shutil

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = os.path.join(REPO, ".sandboxes", "flight_r4old")
ROOT = os.path.join(WORK, "proj")
SRC = os.path.join(REPO, "artifacts", "flight", "verify", "r3_sources")

# (suite, test filter, what it pins, must fail on round 3)
CHECKS = [
    ("flight/view_turn", "vt1", "ViewTurn caps / convergence / overshoot over random owes", True),
    ("flight/view_turn", "vt2", "ViewTurn single owes from rest time-optimal", True),
    ("flight/view_turn", "vt3", "ViewTurn: the verifier's infeasible re-plan", True),
    ("flight/view_turn", "vt4", "ViewTurn: 40 000-tick stream", True),
    ("flight/collision", "c8b", "stun turn <= 40 deg, view rotation bounded", True),
    ("flight/collision", "c10", "room / floor stuns never spin the view", True),
    ("flight/perch", "p5_a", "a completed flap launches (at the stroke's bottom)", True),
    ("flight/perch", "p6_resting", "the rest pose never leaves the perch", True),
    ("flight/perch", "p6b", "relaxed postures grid", True),
    ("flight/player_bird", "pb27", "uneven symmetric strokes never shake the view", True),
    ("flight/player_bird", "pb28", "one-arm strokes turn away consistently", True),
    ("flight/flight_model", "fm18b", "no flap force across the body", True),
    ("flight/flight_model", "fm18c", "the one-wing kick grows from the dead-zone edge", True),
    ("flight/collision", "c11", "a fall along a wall is not a floor hit", True),
    ("flight/flight_model", "fm23b", "NaN guard restores (pinned contract; mutant-checked)", False),
    ("flight/player_bird", "pb19b", "dt clamp (pinned contract; mutant-checked)", False),
]


def sync():
    os.makedirs(WORK, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", "--exclude", "/.godot/", "--exclude", "/.sandboxes/",
                    "--exclude", "/artifacts/", "--exclude", "/.git/", REPO + "/", ROOT + "/"], check=True)
    dst = os.path.join(ROOT, "scripts", "flight")
    for sub in ["", "pose_sources"]:
        sd = os.path.join(SRC, sub)
        for f in os.listdir(sd):
            if f.endswith(".gd.txt"):
                shutil.copy(os.path.join(sd, f), os.path.join(dst, sub, f[:-4]))


def run(suite, test):
    env = dict(os.environ, GD_TIMEOUT="600")
    r = subprocess.run([os.path.join(ROOT, "tools", "gd.sh"), "flight_r4old", "--headless", "res://tests/runner.tscn",
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
    errors = [l.strip() for l in out.splitlines() if "SCRIPT ERROR" in l][:3]
    return p, fl, fails, errors


def main():
    sync()
    results = []
    for suite, test, what, must in CHECKS:
        t0 = time.time()
        p, fl, fails, errors = run(suite, test)
        failed = fl != 0
        ok = failed == must
        print("[r4old] %-22s %-12s %s on round 3 (%s)%s" % (suite, test, "FAILS" if failed else "passes",
              "as expected" if ok else "UNEXPECTED", " script errors" if errors else ""), flush=True)
        for x in fails[:3]:
            print("          " + x[:200])
        results.append({"suite": suite, "test": test, "pins": what, "must_fail_on_round3": must,
                        "fails_on_round3": failed, "as_expected": ok, "passed": p, "failed": fl,
                        "first_failures": fails, "script_errors": errors, "seconds": round(time.time() - t0, 1)})
    out = os.path.join(REPO, "artifacts", "flight", "r4_old_code_check.json")
    json.dump({"generated_by": "tests/shots/flight_r4_oldcode_check.py", "time": time.strftime("%Y-%m-%d %H:%M:%S"),
               "round3_sources": "artifacts/flight/verify/r3_sources", "results": results}, open(out, "w"), indent=1)
    print("[r4old] %d of %d as expected; report %s" % (sum(1 for r in results if r["as_expected"]), len(results), out))


main()
