#!/usr/bin/env python3
"""VERIFIER PROBE driver (integration verify round 3, VR/simulator/Quest lens).

Moves the Meta XR Simulator's own controllers and headset for
tests/probes/integration/r3vq_sim.gd, using the VR area's SimRpc client
(tests/sim/sim_driver.py: SendKey only, never the persisting settings
calls; the persistent_data.json hash is compared before and after), plus
DeviceService/SetUserPresent (runtime state, not persisted) for the
headset coming off and back on.

Phases (the game writes artifacts/integration/verify/r3vq/state.json):
  aim:<id>        translate the right controller by the game's aim delta
                  until its laser hovers the button, then pull its trigger
  menu_button     left controller selected, press its menu button (M)
  calibrate_bad   spread both controllers but with the LEFT hand raised
                  ~0.25 m (closed loop on the pose stream), hold still 4 s
  calibrate_fix   lower the left hand back to level and hold still
  calibrate_again a normal spread (closed loop) and hold still
  relax           reset the controller poses (Space)
  spread_flap     spread, then interleaved one-hand strokes (R/F)
  pause_button    left menu button
  head_turn / recenter / head_back   head yaw while paused, A/X held
  y_hold          left controller selected, B/Y key (N) held 1.8 s
  by_cancel       a short B/Y press
  presence_off / presence_on        SetUserPresent false / true
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, "tests", "sim"))
import sim_driver as sd  # noqa: E402

DIR = os.path.join(ROOT, "artifacts", "integration", "verify", "r3vq")
STATE = os.path.join(DIR, "state.json")
RESULT = os.path.join(DIR, "driver.json")
sd.KEY.update({"T": 53, "M": 46, "N": 47, "B": 35})

LEFT = {"left": True, "right": False, "head": False}
RIGHT = {"left": False, "right": True, "head": False}
HEAD = {"left": False, "right": False, "head": True}


def log(*a):
    print("[r3vq-driver]", *a, flush=True)


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


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def wait_phase(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        st = state()
        ph = st.get("phase", "")
        if ph == "done":
            return "done"
        if st.get("pid") and not alive(st.get("pid")):
            return "done"
        if pred(ph):
            return ph
        time.sleep(0.1)
    return None


def spread(port, keys, poses, result, raise_left=False):
    def dev(name):
        return poses.samples[-1][name]

    def axis(i):
        return state().get("status", {}).get("axis_deg", [999, 999])[i]

    acts = []
    keys.tap("Space", 0.15)
    time.sleep(0.6)
    for side, out_key, sign in (("left", "A", -1.0), ("right", "D", 1.0)):
        ok, _ = sd.select(port, keys, LEFT if side == "left" else RIGHT)
        if not ok:
            raise RuntimeError("could not select %s" % side)
        acts.append(["out_" + side, sd.hold_until(keys, out_key, lambda: sign * dev(side)[0] >= 0.72, 1.5)])
        acts.append(["back_" + side, sd.hold_until(keys, "S", lambda: dev(side)[2] >= -0.10, 1.2)])
        if side == "left" and raise_left:
            y0 = dev("left")[1]
            result["left_y_before_raise"] = y0
            acts.append(["raise_left", sd.hold_until(keys, "R", lambda: dev("left")[1] >= y0 + 0.24, 1.0)])
            result["left_y_raised"] = dev("left")[1]
    for i, (side, yaw_key, yaw_sign) in enumerate((("left", "LeftArrow", 1.0), ("right", "RightArrow", -1.0))):
        ok, _ = sd.select(port, keys, LEFT if side == "left" else RIGHT)
        if not ok:
            raise RuntimeError("could not select %s" % side)
        acts.append(["yaw_" + side, sd.hold_until(keys, yaw_key, lambda: yaw_sign * dev(side)[4] >= 85.0, 2.5)])
        acts.append(["pitch_" + side, sd.hold_until(keys, "UpArrow", lambda: axis(i) <= 20.0, 2.0)])
    result.setdefault("spreads", []).append({"raise_left": raise_left, "actions": acts, "status": state().get("status")})
    write(result)


def aim_click(port, keys, result, target, hold_s=0.3):
    ok, _ = sd.select(port, keys, RIGHT)
    keys.tap("Space", 0.15)
    time.sleep(0.6)
    steps = []
    for it in range(60):
        st = state()
        if not (st.get("phase", "").startswith("aim:") or st.get("phase", "").startswith("hold:")):
            break
        a = st.get("aim") or {}
        if st.get("hovered") == a.get("target") and a.get("target"):
            time.sleep(0.35)
            if state().get("hovered") != a.get("target"):
                continue
            keys.hold("T")
            time.sleep(hold_s)
            keys.hold()
            steps.append(["pull", st.get("hovered"), hold_s])
            for _ in range(30):
                time.sleep(0.1)
                ph2 = state().get("phase", "")
                if not (ph2.startswith("aim:") or ph2.startswith("hold:")):
                    break
            else:
                continue
            break
        if "dx" not in a:
            steps.append(["no_aim", a.get("error", ""), st.get("hovered")])
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
    result.setdefault("aims", []).append({"target": target, "select_ok": ok, "steps": steps[-12:], "n_steps": len(steps)})
    write(result)


def user_present(port, present):
    r = subprocess.run(sd.curl(port, "DeviceService/SetUserPresent", "-i", "--data-binary", "@-"),
                       input=sd.frame(b"\x10" + bytes([1 if present else 0])), capture_output=True, timeout=10)
    txt = r.stdout.decode("latin-1", "replace")
    return {"http": txt.splitlines()[0] if txt else "",
            "grpc_status": [ln for ln in txt.splitlines() if ln.lower().startswith("grpc-status")]}


def main():
    before = sd.sha(sd.PERSIST)
    result = {"persistent_sha_before": before}
    write(result)
    ph = wait_phase(lambda p: p in ("menu",) or p.startswith("aim:"), 300)
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
    relaxed = 0
    try:
        while True:
            ph = wait_phase(lambda p: p in ("menu_button", "calibrate_bad", "calibrate_fix", "calibrate_again", "relax",
                                            "spread_flap", "pause_button", "head_turn", "recenter", "head_back",
                                            "y_hold", "by_cancel", "presence_off", "presence_on", "skip", "bank") or p.startswith("aim:") or p.startswith("hold:"), 300)
            if ph is None or ph == "done":
                break
            log("phase", ph)
            if ph.startswith("aim:"):
                aim_click(port, keys, result, ph[4:])
                wait_phase(lambda p: not p.startswith("aim:"), 30)
            elif ph.startswith("hold:"):
                aim_click(port, keys, result, ph[5:], hold_s=1.4)
                wait_phase(lambda p: not p.startswith("hold:"), 30)
            elif ph == "bank":
                bank = {}
                try:
                    ok, _ = sd.select(port, keys, LEFT)
                    y0 = poses.samples[-1]["left"][1]
                    bank["y0"] = y0
                    bank["raise"] = sd.hold_until(keys, "R", lambda: poses.samples[-1]["left"][1] >= y0 + 0.30, 1.5)
                    bank["y_up"] = poses.samples[-1]["left"][1]
                    time.sleep(4.0)
                    bank["lower"] = sd.hold_until(keys, "F", lambda: poses.samples[-1]["left"][1] <= y0 - 0.30, 2.5)
                    bank["y_down"] = poses.samples[-1]["left"][1]
                    time.sleep(4.0)
                    bank["level"] = sd.hold_until(keys, "R", lambda: poses.samples[-1]["left"][1] >= y0, 1.5)
                    bank["y_end"] = poses.samples[-1]["left"][1]
                    time.sleep(1.5)
                except Exception as e:  # noqa: BLE001
                    bank["error"] = repr(e)
                result["bank"] = bank
                result["bank_done"] = True
                write(result)
                wait_phase(lambda p: p != "bank", 30)
            elif ph == "skip":
                ok, _ = sd.select(port, keys, RIGHT)
                time.sleep(0.4)
                keys.tap("N", 0.2)
                result["skip_pressed"] = ok
                write(result)
                wait_phase(lambda p: p != "skip", 25)
            elif ph == "menu_button":
                ok, _ = sd.select(port, keys, LEFT)
                keys.tap("M", 0.2)
                result["menu_pressed"] = ok
                write(result)
                wait_phase(lambda p: p != "menu_button", 25)
            elif ph == "calibrate_bad":
                try:
                    spread(port, keys, poses, result, raise_left=True)
                    result["bad_raised"] = True
                    write(result)
                    time.sleep(4.0)
                    result["bad_status"] = state().get("status")
                    result["bad_held"] = True
                    write(result)
                except Exception as e:  # noqa: BLE001
                    result["spread_error"] = repr(e)
                    write(result)
                wait_phase(lambda p: p != "calibrate_bad", 70)
            elif ph == "calibrate_fix":
                ok, _ = sd.select(port, keys, LEFT)
                y_target = result.get("left_y_before_raise", 1.37)
                result["lower_left"] = sd.hold_until(keys, "F", lambda: poses.samples[-1]["left"][1] <= y_target + 0.01, 1.0)
                result["left_y_lowered"] = poses.samples[-1]["left"][1]
                write(result)
                wait_phase(lambda p: p != "calibrate_fix", 40)
            elif ph == "calibrate_again":
                try:
                    spread(port, keys, poses, result, raise_left=False)
                except Exception as e:  # noqa: BLE001
                    result["spread_error2"] = repr(e)
                    write(result)
                wait_phase(lambda p: p != "calibrate_again", 50)
            elif ph == "relax":
                time.sleep(0.5)
                keys.tap("Space", 0.15)
                time.sleep(0.8)
                relaxed += 1
                result["relaxed" if relaxed == 1 else "relaxed2"] = True
                write(result)
                wait_phase(lambda p: p != "relax", 30)
            elif ph == "spread_flap":
                def dev(name):
                    return poses.samples[-1][name]
                acts = []
                keys.tap("Space", 0.15)
                time.sleep(0.6)
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
            elif ph == "pause_button":
                ok, _ = sd.select(port, keys, LEFT)
                result["pause_select_ok"] = ok
                keys.tap("M", 0.2)
                result["pause_pressed"] = True
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
                result["head_turned_n"] = result.get("head_turned_n", 0) + 1
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
                sd.select(port, keys, RIGHT)
                keys.hold("R")
                time.sleep(0.12)
                keys.hold()
                time.sleep(0.6)
                keys.hold("F")
                time.sleep(0.12)
                keys.hold()
                time.sleep(0.6)
                result["head_poses"] = [s.get("head") for s in poses.samples[n0::5]]
                result["head_turn_done"] = True
                result["head_turn_done_n"] = result.get("head_turn_done_n", 0) + 1
                write(result)
                wait_phase(lambda p: p != "head_back", 30)
            elif ph == "y_hold":
                ok, _ = sd.select(port, keys, LEFT)
                keys.tap("Space", 0.15)
                time.sleep(0.5)
                keys.hold("N")
                time.sleep(1.9)
                keys.hold()
                result["y_held"] = ok
                write(result)
                wait_phase(lambda p: p != "y_hold", 25)
            elif ph == "by_cancel":
                sd.select(port, keys, RIGHT)
                time.sleep(0.5)
                keys.tap("N", 0.2)
                result["by_pressed"] = True
                write(result)
                wait_phase(lambda p: p != "by_cancel", 25)
            elif ph == "presence_off":
                result.setdefault("presence", {})["off"] = user_present(port, False)
                write(result)
                wait_phase(lambda p: p != "presence_off", 20)
            elif ph == "presence_on":
                time.sleep(1.0)
                result.setdefault("presence", {})["on"] = user_present(port, True)
                write(result)
                wait_phase(lambda p: p != "presence_on", 20)
    finally:
        try:
            user_present(port, True)
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
