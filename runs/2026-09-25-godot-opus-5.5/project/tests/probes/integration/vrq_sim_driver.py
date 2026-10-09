#!/usr/bin/env python3
"""VERIFIER PROBE driver (integration verify round 1, VR/simulator/Quest lens).

Moves the Meta XR Simulator's own controllers and headset for
tests/probes/integration/vrq_sim.gd, using the VR area's SimRpc client
(tests/sim/sim_driver.py: SendKey only, never the persisting settings
calls; the persistent_data.json hash is compared before and after).

Phases (the game writes artifacts/integration/verify/vrq/state.json):
  calibrate     spread both controllers like VR's own calibration check does
                (A/D out, S back, yaw out, pitch until the grip axis reads
                <= 20 deg), hold still until the game captures
  relax         reset the controller poses (Space)
  aim:<id>      translate the right controller by the game's aim delta until
                its laser hovers the button, then pull the trigger (T)
  pause_button  left controller selected, press its menu button (M)
  head_turn     head selected, turn it left then back (arrows); then the
                right controller moved up and down (all while paused)
  flap          interleaved one-hand strokes (R/F), as integration's driver
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, "tests", "sim"))
import sim_driver as sd  # noqa: E402

DIR = os.path.join(ROOT, "artifacts", "integration", "verify", "vrq")
STATE = os.path.join(DIR, "state.json")
RESULT = os.path.join(DIR, "driver.json")
sd.KEY.update({"T": 53, "M": 46, "N": 47, "B": 35})

LEFT = {"left": True, "right": False, "head": False}
RIGHT = {"left": False, "right": True, "head": False}
HEAD = {"left": False, "right": False, "head": True}


def log(*a):
    print("[vrq-driver]", *a, flush=True)


def state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write(d):
    os.makedirs(DIR, exist_ok=True)
    tmp = RESULT + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(sd._finite(d), fh, indent=1, allow_nan=False)
    os.replace(tmp, RESULT)


def wait_phase(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        st = state()
        ph = st.get("phase", "")
        if ph == "done":
            return "done"
        if pred(ph):
            return ph
        time.sleep(0.1)
    return None


def spread(port, keys, poses, result):
    def dev(name):
        return poses.samples[-1][name]

    def axis(i):
        return state().get("status", {}).get("axis_deg", [999, 999])[i]

    acts = []
    for side, out_key, sign in (("left", "A", -1.0), ("right", "D", 1.0)):
        ok, _ = sd.select(port, keys, LEFT if side == "left" else RIGHT)
        if not ok:
            raise RuntimeError("could not select %s" % side)
        acts.append(["out_" + side, sd.hold_until(keys, out_key, lambda: sign * dev(side)[0] >= 0.72, 1.5)])
        acts.append(["back_" + side, sd.hold_until(keys, "S", lambda: dev(side)[2] >= -0.10, 1.2)])
    for i, (side, yaw_key, yaw_sign) in enumerate((("left", "LeftArrow", 1.0), ("right", "RightArrow", -1.0))):
        ok, _ = sd.select(port, keys, LEFT if side == "left" else RIGHT)
        if not ok:
            raise RuntimeError("could not select %s" % side)
        acts.append(["yaw_" + side, sd.hold_until(keys, yaw_key, lambda: yaw_sign * dev(side)[4] >= 85.0, 2.5)])
        acts.append(["pitch_" + side, sd.hold_until(keys, "UpArrow", lambda: axis(i) <= 20.0, 2.0)])
    result["spread_actions"] = acts
    result["status_after_spread"] = state().get("status")
    write(result)


def aim_click(port, keys, result, target, log_list):
    ok, _ = sd.select(port, keys, RIGHT)
    # Controllers back to their rest pose first (the spread for the flaps
    # leaves the right one yawed 90 deg outward).
    keys.tap("Space", 0.15)
    time.sleep(0.6)
    steps = []
    for it in range(60):
        st = state()
        if not st.get("phase", "").startswith("aim:"):
            break
        a = st.get("aim") or {}
        if st.get("hovered") == a.get("target") and a.get("target"):
            time.sleep(0.35)
            if state().get("hovered") != a.get("target"):
                continue
            keys.hold("T")
            time.sleep(0.3)
            keys.hold()
            steps.append(["pull", st.get("hovered")])
            # The game moves on once the click did what it should.
            for _ in range(30):
                time.sleep(0.1)
                if not state().get("phase", "").startswith("aim:"):
                    break
            else:
                continue
            break
        if "dx" not in a:
            steps.append(["no_aim", a.get("error", "")])
            time.sleep(0.3)
            continue
        dx, dy = a["dx"], a["dy"]
        if abs(dx) >= abs(dy):
            key, d = ("D" if dx > 0 else "A"), dx
        else:
            key, d = ("R" if dy > 0 else "F"), dy
        secs = min(0.3, max(0.02, abs(d) * 0.8))
        steps.append([key, round(d, 3), round(secs, 3), st.get("hovered")])
        keys.hold(key)
        time.sleep(secs)
        keys.hold()
        time.sleep(0.45)
    log_list.append({"target": target, "select_ok": ok, "steps": steps})
    write(result)


def main():
    before = sd.sha(sd.PERSIST)
    result = {"persistent_sha_before": before, "aims": []}
    write(result)
    ph = wait_phase(lambda p: p in ("menu_card", "calibrate"), 300)
    st = state()
    if not ph or ph == "done":
        result["error"] = "game never reached the menu"
        write(result)
        return 1
    port = sd.port_for_pid(st["pid"])
    result["port"] = port
    if not port:
        result["error"] = "no SimRpc port"
        write(result)
        return 1
    keys = sd.Keys(port)
    poses = sd.Poses(port)
    poses.start()
    orig = sd.plugin_settings(port)
    result["settings_before"] = orig
    try:
        while True:
            ph = wait_phase(lambda p: p in ("calibrate", "relax", "pause_button", "head_turn", "recenter", "head_back", "spread_flap") or p.startswith("aim:"), 240)
            if ph is None or ph == "done":
                break
            log("phase", ph)
            if ph == "calibrate":
                try:
                    spread(port, keys, poses, result)
                except Exception as e:  # noqa: BLE001
                    result["spread_error"] = repr(e)
                    write(result)
                wait_phase(lambda p: p != "calibrate", 70)
            elif ph == "relax":
                time.sleep(0.5)
                keys.tap("Space", 0.15)
                time.sleep(0.8)
                result["relaxed"] = True
                write(result)
                wait_phase(lambda p: p != "relax", 30)
            elif ph.startswith("aim:"):
                aim_click(port, keys, result, ph[4:], result["aims"])
                wait_phase(lambda p: not p.startswith("aim:"), 30)
            elif ph == "pause_button":
                ok, _ = sd.select(port, keys, LEFT)
                result["pause_select_ok"] = ok
                keys.tap("M", 0.2)
                result["menu_pressed"] = True
                write(result)
                wait_phase(lambda p: p != "pause_button", 25)
            elif ph == "head_turn":
                ok, _ = sd.select(port, keys, HEAD)
                result["head_select_ok"] = ok
                result["n0"] = len(poses.samples)
                keys.hold("LeftArrow")
                time.sleep(0.6)
                keys.hold()
                time.sleep(1.0)
                result["head_turned"] = True
                write(result)
                wait_phase(lambda p: p != "head_turn", 20)
            elif ph == "recenter":
                ok, _ = sd.select(port, keys, RIGHT)
                keys.hold("B")
                time.sleep(1.5)
                keys.hold()
                time.sleep(0.5)
                result["recenter_held"] = True
                write(result)
                wait_phase(lambda p: p != "recenter", 20)
            elif ph == "head_back":
                n0 = result.get("n0", 0)
                sd.select(port, keys, HEAD)
                keys.hold("RightArrow")
                time.sleep(0.6)
                keys.hold()
                time.sleep(0.8)
                ok2, _ = sd.select(port, keys, RIGHT)
                keys.hold("R")
                time.sleep(0.12)
                keys.hold()
                time.sleep(0.6)
                keys.hold("F")
                time.sleep(0.12)
                keys.hold()
                time.sleep(0.6)
                result["head_poses"] = [s.get("head") for s in poses.samples[n0::3]]
                result["head_turn_done"] = True
                write(result)
                wait_phase(lambda p: p != "head_back", 30)
            elif ph == "spread_flap":
                def dev(name):
                    return poses.samples[-1][name]
                acts = []
                for side, out_key, sign, yaw_key, ysign in (("left", "A", -1.0, "LeftArrow", 1.0), ("right", "D", 1.0, "RightArrow", -1.0)):
                    sd.select(port, keys, LEFT if side == "left" else RIGHT)
                    acts.append(["out_" + side, sd.hold_until(keys, out_key, lambda: sign * dev(side)[0] >= 0.72, 1.5)])
                    acts.append(["back_" + side, sd.hold_until(keys, "S", lambda: dev(side)[2] >= -0.10, 1.2)])
                    acts.append(["yaw_" + side, sd.hold_until(keys, yaw_key, lambda: ysign * dev(side)[4] >= 85.0, 2.5)])
                result["flap_spread"] = acts
                time.sleep(1.5)
                for k in range(4):
                    sd.select(port, keys, LEFT)
                    keys.hold("R"); time.sleep(0.5); keys.hold(); time.sleep(0.1)
                    keys.hold("F"); time.sleep(0.5); keys.hold(); time.sleep(0.1)
                    sd.select(port, keys, RIGHT)
                    keys.hold("R"); time.sleep(0.5); keys.hold(); time.sleep(0.1)
                    keys.hold("F"); time.sleep(0.5); keys.hold(); time.sleep(0.1)
                result["flaps_done"] = True
                write(result)
                wait_phase(lambda p: p != "spread_flap", 30)
    finally:
        try:
            sd.select(port, keys, {"left": orig["left"], "right": orig["right"], "head": orig["head"]}, 8)
            keys.tap("Space", 0.15)
        finally:
            keys.close()
            poses.stop()
    after = sd.sha(sd.PERSIST)
    result["persistent_unchanged"] = before == after
    result["done"] = True
    write(result)
    log("done; persistent_data unchanged:", before == after)
    return 0


if __name__ == "__main__":
    sys.exit(main())
