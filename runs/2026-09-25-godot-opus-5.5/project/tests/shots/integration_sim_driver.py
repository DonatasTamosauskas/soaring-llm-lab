#!/usr/bin/env python3
"""Drive the Meta XR Simulator's controllers for the integration run of
scenes/main.tscn (tests/shots/integration_sim.gd). Reuses the VR area's
SimRpc client (tests/sim/sim_driver.py: gRPC over curl, SendKey only, the
simulator's own keybindings; it never calls SetInputPluginSettings /
SetInputSource / SetBindings / SetActionInput, which would persist into
persistent_data.json, and it checks that file's hash before and after).

  1. menu: select the right controller alone (the simulator's CYCLE_INPUT
     key), tilt it (its own pitch keys) until the game says its laser
     pointer hovers Play, then pull its trigger (T).
  2. calibrate (a first launch, integration round 1): Play closed the menu
     and VR's card asks for the spread: both controllers out into flight's
     SIM-05 spread and held still until the game has captured it and the
     run starts.
  3. flap: two-hand downstrokes and upstrokes, interleaved one hand at a
     time (the simulator has no "both controllers, head still" selection
     without a persisted setting), as the VR harness does.

Coordination: with --io=<run id> (the wrapper) the files are this run's own,
artifacts/integration/sim_io/<id>_state.json (game -> driver: phase, pid,
what the pointer hovers, game state, the calibration step) and
<id>_driver.json (driver -> game: what was done): the driver starts before
the simulator lock is ours and must never drive another agent's run.
Without --io: sim_state.json / sim_driver.json (older runs).
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tests", "sim"))
sys.path.insert(0, os.path.join(ROOT, "tests", "shots"))
import sim_driver as sd  # noqa: E402
import flight_sim_driver as fd  # noqa: E402  (flight's SIM-05 helpers: press, turn)

ART = os.path.join(ROOT, "artifacts", "integration")
IO = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--io=")), "")
if IO:
    os.makedirs(os.path.join(ART, "sim_io"), exist_ok=True)
    STATE = os.path.join(ART, "sim_io", IO + "_state.json")
    RESULT = os.path.join(ART, "sim_io", IO + "_driver.json")
else:
    STATE = os.path.join(ART, "sim_state.json")
    RESULT = os.path.join(ART, "sim_driver.json")
# More KeyboardKey codes (sim_buttons.proto: A=34 ... Z=59; arrows 1-4).
sd.KEY.update({"T": 53, "UpArrow": 3, "DownArrow": 4, "A": 34, "D": 37, "S": 52, "Space": 12})
fd.KEY.update({"T": 53, "Space": 12})


def log(*a):
    print("[integration-driver]", *a, flush=True)


def state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write(d):
    os.makedirs(ART, exist_ok=True)
    tmp = RESULT + ".tmp"
    with open(tmp, "w") as fh:
        # The simulator's pose stream sometimes carries NaN (a controller
        # yawed ~90 deg): not JSON. Written as null (flight's _clean).
        json.dump(fd._clean(d), fh, indent=2, allow_nan=False)
    os.replace(tmp, RESULT)


def wait_phase(phase, timeout):
    end = time.time() + timeout
    while time.time() < end:
        st = state()
        if st.get("phase") == phase and st.get("pid"):
            return st
        if st.get("phase") == "done":
            return None
        time.sleep(0.2)
    return None


def aim_at_play(keys, result):
    """Raise the right controller until the pointer hovers Play; True if so.
    The fixed simulator controller points forward at hand height: its ray
    lands on the menu's right column (Quit / Settings); Play is the top
    button, ~30 cm higher at the panel's distance. The hand is moved (the
    simulator's MOVE_UP / MOVE_DOWN at 1 m/s), not tilted: a translation
    moves the ray's hit point by exactly as much, which a pitch key (whose
    step depends on the frame rate) did not."""
    seen = []
    plan = [("R", 0.04)] * 16 + [("F", 0.02)] * 10 + [("R", 0.02)] * 10
    overshot = False
    for key, secs in plan:
        hov = state().get("hovered", "")
        seen.append(hov)
        if hov == "Btn_play":
            result["aim_steps"] = seen
            return True
        if key == "R" and secs == 0.04 and hov == "" and len(seen) > 1 and seen[-2] == "Btn_play":
            overshot = True
        if overshot and key == "R" and secs == 0.04:
            continue
        keys.hold(key)
        time.sleep(secs)
        keys.hold()
        time.sleep(0.4)
    result["aim_steps"] = seen
    return state().get("hovered", "") == "Btn_play"


class _Rep:
    def __init__(self):
        self.d = {}


LEFT = {"left": True, "right": False, "head": False}
RIGHT = {"left": False, "right": True, "head": False}


def spread(port, keys, poses, rep, result, tag):
    """Flight's SIM-05 spread: both controllers out (0.55 m), back in line
    with the shoulders, yawed to point along the arms. True if done."""
    keys.tap("Space")               # the simulator's own "reset controller poses"
    time.sleep(0.5)
    if not fd.select(port, keys, LEFT):
        result["error"] = "could not select the left controller"
        return False
    keys.press("A", 0.55)
    keys.press("S", 0.46)
    fd.turn(keys, poses, "left", "LeftArrow", 90.0, rep, "yaw_left_out_" + tag)
    if not fd.select(port, keys, RIGHT):
        result["error"] = "could not select the right controller"
        return False
    keys.press("D", 0.55)
    keys.press("S", 0.46)
    fd.turn(keys, poses, "right", "RightArrow", 90.0, rep, "yaw_right_out_" + tag)
    result["spread_poses_" + tag] = dict(poses.last)
    return True


def calibrate(port, result):
    """The first-flight gate: spread and hold still until the game has
    captured the calibration and started the run."""
    keys = fd.Keys(port)
    poses = fd.Poses(port)
    poses.start()
    rep = _Rep()
    try:
        t0 = time.time()
        if not spread(port, keys, poses, rep, result, "calibrate"):
            return
        result["calibrate_spread_s"] = round(time.time() - t0, 2)
        write(result)
        end = time.time() + 20.0
        while time.time() < end:
            st = state()
            if st.get("calibrated"):
                result["calibrated_after_hold_s"] = round(time.time() - t0 - result["calibrate_spread_s"], 2)
            if st.get("state") == "PLAYING":
                break
            time.sleep(0.2)
        result["calibrate_done"] = state().get("state") == "PLAYING"
        result["calibrate_turns"] = rep.d.get("turns", [])
        log("calibration step done; game state", state().get("state"), "calibrated", state().get("calibrated"))
    finally:
        keys.close()
        poses.stop()


def spread_and_flap(port, result):
    """Flight's SIM-05 moves: the spread (see spread()), a still hold (the
    game captures the wings in the head-view mirror), then interleaved
    one-wing strokes (0.5 s up, 0.5 s down at the simulator's 1 m/s)."""
    keys = fd.Keys(port)
    poses = fd.Poses(port)
    poses.start()
    rep = _Rep()
    try:
        left = LEFT
        right = RIGHT
        if not spread(port, keys, poses, rep, result, "flap"):
            return
        result["spread_poses"] = dict(result.get("spread_poses_flap", {}))
        time.sleep(3.0)
        # The game captures the spread wings in the head-view mirror, then
        # says "stroke".
        result["spread_done"] = True
        write(result)
        wait_phase("stroke", 15)
        for k in range(4):
            fd.select(port, keys, left, "LeftBracket")
            keys.press("R", 0.5)
            keys.press("F", 0.5)
            fd.select(port, keys, right, "RightBracket")
            keys.press("R", 0.5)
            keys.press("F", 0.5)
            log("stroke pair", k)
        result["turns"] = rep.d.get("turns", [])
    finally:
        keys.close()
        poses.stop()


def main():
    before = sd.sha(sd.PERSIST)
    result = {"persistent_sha_before": before, "menu_done": False, "flaps_done": False}
    write(result)
    log("waiting for the game (phase=menu)")
    st = wait_phase("menu", 300)
    if not st:
        result["error"] = "the game never reached the menu phase"
        write(result)
        return 1
    port = sd.port_for_pid(st["pid"])
    result["port"] = port
    if not port:
        result["error"] = "no SimRpc port"
        write(result)
        return 1
    keys = sd.Keys(port)
    try:
        orig = sd.plugin_settings(port)
        result["settings_before"] = orig
        ok, seen = sd.select(port, keys, {"left": False, "right": True, "head": False})
        result["right_selected"] = ok
        log("right controller selected:", ok, seen)
        pulls = 0
        for attempt in range(3):
            if not aim_at_play(keys, result):
                log("could not aim at Play; hovered:", state().get("hovered"))
                break
            result["hovered_at_pull"] = state().get("hovered")
            time.sleep(0.3)
            keys.hold("T")
            time.sleep(0.3)
            keys.hold()
            pulls += 1
            time.sleep(1.0)
            if state().get("state") == "PLAYING" or state().get("phase") == "calibrate" \
                    or state().get("calibration_step") == "capture":
                break
        result["pulls"] = pulls
        result["menu_done"] = True
        write(result)
        log("menu done; game state", state().get("state"), "phase", state().get("phase"))
        keys.close()
        if wait_phase("calibrate", 6):
            calibrate(port, result)
            write(result)
        if wait_phase("flap", 120):
            spread_and_flap(port, result)
            result["flaps_done"] = True
            write(result)
        keys = sd.Keys(port)
        ok_r, _ = sd.select(port, keys, {"left": orig["left"], "right": orig["right"], "head": orig["head"]}, 8)
        result["restored_selection"] = ok_r
        write(result)
    finally:
        keys.close()
    after = sd.sha(sd.PERSIST)
    result["persistent_unchanged"] = before == after
    result["done"] = True
    write(result)
    log("done; persistent_data unchanged:", before == after)
    return 0


if __name__ == "__main__":
    sys.exit(main())
