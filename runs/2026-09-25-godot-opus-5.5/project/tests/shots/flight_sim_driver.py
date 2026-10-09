#!/usr/bin/env python3
"""SIM-05 (flight, F14): move the Meta XR Simulator's own controllers so they
fly the bird through XRPoseSource -> WingInput -> FlightModel.

The simulator runtime loads inside the Godot process and serves SimRpc
(gRPC) on a port it writes to its log (docs/research/QUEST.md §6.1). This
driver talks to it with curl (HTTP/2; no grpcio) and uses ONLY:
  * Input/GetInputPluginSettings (read-only), to see which device the keys
    move,
  * Input/SendKey (a client stream of held keys), to press the simulator's
    own keybindings: ']' / '[' (CYCLE_INPUT_FORWARD / BACKWARD) select one
    controller with the head left alone (or, last, the headset alone), A / D
    move it sideways, R / F move it up / down (MOVE_UP / MOVE_DOWN), Q / E
    roll it (TILT_LEFT / TILT_RIGHT), the arrow keys turn it.
It never calls SetInputPluginSettings, SetInputSource, SetBindings or
SetActionInput (they persist into persistent_data.json). The file's SHA-256
is compared before and after and reported. Device selection by key cycling
is in-memory state of this session and is restored at the end.

Coordination with the lab (scenes/dev/flight_dev_simdrive.gd):
  artifacts/flight/sim_state.json   lab -> driver   {"phase", "pid"}
  artifacts/flight/sim_driver.json  driver -> lab   {"steps": [[t, name]...], "done", ...}

  python3 tests/shots/flight_sim_driver.py     (tests/shots/flight_sim_run.sh starts it)
"""
import hashlib
import json
import math
import os
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ART = os.path.join(ROOT, "artifacts", "flight")
STATE = os.path.join(ART, "sim_state.json")
RESULT = os.path.join(ART, "sim_driver.json")
SIM_DIR = os.path.expanduser("~/Library/Application Support/MetaXR/MetaXrSimulator")
LOGS = os.path.join(SIM_DIR, "logs")
PERSIST = os.path.join(SIM_DIR, "persistent_data.json")
PKG = "openxr_simulator.rpc.proto."
# KeyboardKey enum values (sim_buttons.proto; QUEST.md §6.1).
KEY = {"A": 34, "D": 37, "E": 38, "F": 39, "Q": 50, "R": 51, "S": 52, "W": 56, "LeftBracket": 79, "RightBracket": 81,
       "LeftArrow": 1, "RightArrow": 2, "UpArrow": 3, "DownArrow": 4}


def log(*a):
    print("[flight-driver]", *a, flush=True)


def frame(msg):
    return b"\x00" + struct.pack(">I", len(msg)) + msg


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if not c & 0x80:
            return r, i


def fields(b):
    out = {}
    i = 0
    while i < len(b):
        tag, i = varint(b, i)
        fn, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = varint(b, i)
        elif wt == 5:
            v = struct.unpack("<f", b[i:i + 4])[0]
            i += 4
        elif wt == 1:
            v = struct.unpack("<d", b[i:i + 8])[0]
            i += 8
        elif wt == 2:
            n, i = varint(b, i)
            v = b[i:i + n]
            i += n
        else:
            raise ValueError("wire type %d" % wt)
        out.setdefault(fn, []).append(v)
    return out


def curl(port, method, *extra):
    return ["curl", "-s", "-N", "--http2-prior-knowledge", "-X", "POST",
            "-H", "content-type: application/grpc", "-H", "te: trailers", *extra,
            "http://[::1]:%d/%s%s" % (port, PKG, method)]


def unary(port, method, msg=b""):
    r = subprocess.run(curl(port, method, "--data-binary", "@-"), input=frame(msg),
                       capture_output=True, timeout=10)
    b = r.stdout
    if len(b) >= 5:
        n = struct.unpack(">I", b[1:5])[0]
        return b[5:5 + n]
    return b""


def selection(port):
    f = fields(unary(port, "Input/GetInputPluginSettings"))
    g = lambda k: bool(f.get(k, [0])[0])
    return {"left": g(3), "right": g(4), "head": g(5)}


class Keys:
    def __init__(self, port):
        self.p = subprocess.Popen(curl(port, "Input/SendKey", "-T", "-"), stdin=subprocess.PIPE,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def hold(self, *names):
        self.p.stdin.write(frame(b"".join(b"\x08" + bytes([KEY[n]]) for n in names)))
        self.p.stdin.flush()

    def press(self, name, secs):
        self.hold(name)
        time.sleep(secs)
        self.hold()
        time.sleep(0.12)

    def tap(self, name):
        self.press(name, 0.18)
        time.sleep(0.13)

    def close(self):
        try:
            self.hold()
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


class Poses(threading.Thread):
    """The simulator's pose stream (InputPositioning/GetInputPositioning,
    ~10 Hz): {side: [x, y, z, ex, ey, ez]} with Euler degrees."""

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.last = {}
        self.p = None

    def run(self):
        self.p = subprocess.Popen(curl(self.port, "InputPositioning/GetInputPositioning", "--data-binary", "@-"),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.p.stdin.write(frame(b""))
        self.p.stdin.close()
        buf = b""
        while True:
            chunk = self.p.stdout.read1(4096)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 5:
                n = struct.unpack(">I", buf[1:5])[0]
                if len(buf) < 5 + n:
                    break
                msg, buf = buf[5:5 + n], buf[5 + n:]
                try:
                    f = fields(msg)
                    for key, fn in (("head", 1), ("left", 2), ("right", 3)):
                        if fn in f:
                            pd = fields(f[fn][0])
                            pos = fields(pd[1][0]) if 1 in pd else {}
                            ori = fields(pd[2][0]) if 2 in pd else {}
                            self.last[key] = [pos.get(k, [0.0])[0] for k in (1, 2, 3)] + \
                                             [ori.get(k, [0.0])[0] for k in (1, 2, 3)]
                except Exception:
                    pass

    def stop(self):
        if self.p:
            self.p.kill()


def r0(v):
    """round() that survives the NaN the pose stream sometimes carries."""
    return [round(x) if x == x else None for x in v]


def r2(v):
    return [round(x, 2) if x == x else None for x in v]


def finite(v):
    return all(x == x and abs(x) != float("inf") for x in v)


def ang_diff(a, b):
    return (a - b + 180.0) % 360.0 - 180.0


def heading(e):
    """Yaw (deg) of a level controller from the stream's Euler triple: past
    90 deg it is reported as (180, 180 - yaw, 180)."""
    if abs(ang_diff(e[3], 180.0)) < 45.0 and abs(ang_diff(e[5], 180.0)) < 45.0:
        return ang_diff(180.0 - e[4], 0.0)
    return e[4]


def turn(keys, poses, side, key, target_deg, rep, label, timeout=4.0):
    """Hold a yaw keybinding on the selected controller until its heading has
    turned by target_deg (closed loop on the ~10 Hz pose stream; released a
    few degrees early for the stream's lag)."""
    time.sleep(0.3)
    start = list(poses.last.get(side, [0] * 6))
    h0 = heading(start)
    keys.hold(key)
    t_end = time.time() + timeout
    turned = 0.0
    while time.time() < t_end:
        time.sleep(0.03)
        cur = poses.last.get(side)
        if cur is None or not finite(cur):
            continue
        turned = abs(ang_diff(heading(cur), h0))
        if turned >= target_deg - 8.0:
            break
    keys.hold()
    time.sleep(0.4)
    cur = poses.last.get(side, [0] * 6)
    if finite(cur):
        turned = abs(ang_diff(heading(cur), h0))
    rep.d.setdefault("turns", []).append({"label": label, "side": side, "key": key, "euler_before": start[3:],
                                          "euler_after": cur[3:], "turned_deg": turned})
    log("%s: %s heading turned %.0f deg, euler %s -> %s, position %s" % (label, side, turned,
        r0(start[3:]), r0(cur[3:]), r2(cur[:3])))


# WingInput's neck pivot in head space (scripts/flight/wing_input.gd): the
# shoulders hang from it. A person turns the head about the neck; the
# simulator yaws the headset about the eyes, which would swing this pivot
# 11 cm for a 73 deg look and read as arm motion.
NECK = (0.0, -0.08, 0.09)


def eye_for_fixed_neck(h0, yaw1_deg):
    """Where the eye must be at yaw1 for the neck of pose h0 to stay put."""
    y0 = math.radians(heading(h0))
    y1 = math.radians(yaw1_deg)
    nx = h0[0] + NECK[0] * math.cos(y0) + NECK[2] * math.sin(y0)
    nz = h0[2] - NECK[0] * math.sin(y0) + NECK[2] * math.cos(y0)
    return (nx - (NECK[0] * math.cos(y1) + NECK[2] * math.sin(y1)), nz - (-NECK[0] * math.sin(y1) + NECK[2] * math.cos(y1)))


def move_to(keys, poses, side, target, rep, label, tol=0.012, iters=12):
    """Closed-loop horizontal move of the selected device to target (x, z)
    with the simulator's A/D/W/S (their directions learned from two short
    pulses first; the pose stream is ~10 Hz)."""
    def pos():
        time.sleep(0.35)
        return list(poses.last.get(side, [0.0] * 6))[:3]
    dirs = {}
    for k in ("A", "W"):
        p0 = pos()
        keys.press(k, 0.05)
        p1 = pos()
        dirs[k] = ((p1[0] - p0[0]) / 0.05, (p1[2] - p0[2]) / 0.05)
    (ax, az), (wx, wz) = dirs["A"], dirs["W"]
    det = ax * wz - az * wx
    err = None
    for _ in range(iters):
        cur = pos()
        ex, ez = target[0] - cur[0], target[1] - cur[2]
        err = math.hypot(ex, ez)
        if err < tol or abs(det) < 1e-6:
            break
        ta = (ex * wz - ez * wx) / det
        tw = (ax * ez - az * ex) / det
        for k_pos, k_neg, t in (("A", "D", ta), ("W", "S", tw)):
            if abs(t) > 0.004:
                keys.press(k_pos if t > 0 else k_neg, min(abs(t), 0.2))
    rep.d.setdefault("moves", []).append({"label": label, "side": side, "target": target, "residual_m": err,
                                          "key_dirs": dirs})
    log("%s: %s moved to within %.3f m of %s" % (label, side, err if err is not None else -1.0, r2(list(target))))


def move_y(keys, poses, side, y_target, rep, label, tol=0.012, iters=10):
    """Closed-loop vertical move of the selected controller to y_target with
    the simulator's R (up) / F (down); the rate is learned from a short pulse.
    One frame at the keys' 1 m/s is ~14 mm, hence the tolerance."""
    def y():
        time.sleep(0.35)
        return list(poses.last.get(side, [0.0] * 6))[1]
    y0 = y()
    keys.press("R", 0.05)
    rate = (y() - y0) / 0.05
    err = None
    for _ in range(iters):
        err = y_target - y()
        if abs(err) < tol or abs(rate) < 1e-3:
            break
        t = err / rate
        keys.press("R" if t > 0 else "F", min(abs(t), 0.3))
    rep.d.setdefault("moves", []).append({"label": label, "side": side, "target_y": y_target, "residual_m": err,
                                          "rate_m_s": rate})
    log("%s: %s height to within %.3f m of %.3f (R rate %.2f m/s)" % (label, side, abs(err) if err is not None else -1.0,
                                                                    y_target, rate))


def port_for_pid(pid, timeout=60.0):
    end = time.time() + timeout
    while time.time() < end:
        for name in os.listdir(LOGS):
            if name.endswith("_%s.log" % pid):
                with open(os.path.join(LOGS, name), errors="replace") as fh:
                    for line in fh:
                        if "SimRpc server started on port" in line:
                            return int(line.rsplit(" ", 1)[1])
        time.sleep(0.5)
    return None


def sha(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


class Report:
    def __init__(self):
        self.t0 = time.time()
        self.d = {"steps": [], "done": False}

    def step(self, name, **extra):
        self.d["steps"].append([round(time.time() - self.t0, 3), name])
        self.d.update(extra)
        self.write()
        log(name)

    def write(self):
        tmp = RESULT + ".tmp"
        with open(tmp, "w") as fh:
            # The simulator's pose stream sometimes carries NaN (a controller
            # yawed ~90 deg); Python would write it as a bare NaN, which is not
            # JSON: the lab's parser rejected the whole file and SIM-05 stalled
            # after its first step (fix round 5). NaN / inf are written as null.
            json.dump(_clean(self.d), fh, indent=1, allow_nan=False)
        os.replace(tmp, RESULT)


def _clean(o):
    if isinstance(o, float):
        return o if o == o and abs(o) != float("inf") else None
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_clean(v) for v in o]
    return o


def select(port, keys, want, key="RightBracket", tries=6):
    """Cycle the controlled device until the selection is `want`."""
    for _ in range(tries):
        if selection(port) == want:
            return True
        keys.tap(key)
    return selection(port) == want


LEFT = {"left": True, "right": False, "head": False}
RIGHT = {"left": False, "right": True, "head": False}
HEAD = {"left": False, "right": False, "head": True}


def drive(port, rep):
    keys = Keys(port)
    poses = Poses(port)
    poses.start()
    try:
        orig = selection(port)
        rep.d["selection_before"] = orig
        # Spread the arms: each controller slides outward 0.55 m at 1 m/s.
        # Each controller then yaws to point out along its arm, the way a
        # hand holds it in the airplane pose (the calibration rejects a
        # forearm axis more than 45 deg from a real grip).
        if not select(port, keys, LEFT):
            raise RuntimeError("could not select the left controller alone")
        keys.press("A", 0.55)
        keys.press("S", 0.46)           # back in line with the shoulder
        turn(keys, poses, "left", "LeftArrow", 90.0, rep, "yaw_left_out")
        rep.step("spread_left")
        if not select(port, keys, RIGHT):
            raise RuntimeError("could not select the right controller alone")
        keys.press("D", 0.55)
        keys.press("S", 0.46)
        turn(keys, poses, "right", "RightArrow", 90.0, rep, "yaw_right_out")
        rep.step("spread_right")
        rep.d["poses_spread"] = dict(poses.last)
        rep.step("spread_done")
        time.sleep(2.8)                 # the lab captures the neutral (1.2 s calm)
        if "--diag" in sys.argv:
            # Rotation keys, one at a time on the left controller (which
            # simulator axis twists the wrist once the controller points out).
            select(port, keys, LEFT, "LeftBracket")
            rep.step("diag_begin")
            for key in ["Q", "E", "E", "Q", "UpArrow", "DownArrow", "DownArrow", "UpArrow", "LeftArrow", "RightArrow"]:
                e0 = list(poses.last.get("left", [0] * 6))
                keys.press(key, 0.25)
                time.sleep(0.7)
                e1 = list(poses.last.get("left", [0] * 6))
                rep.d.setdefault("diag", []).append([key, e0, e1])
                rep.step("diag_%s" % key)
                log("diag %s: euler %s -> %s pos %s" % (key, r0(e0[3:]), r0(e1[3:]), r2(e1[:3])))
            rep.step("diag_end")
        # One wrist twisted (leading edge down), held, back. For a controller
        # pointing out along the arm the simulator's DownArrow / UpArrow turn
        # it about the arm: that is the wrist twist (measured with --diag:
        # +-20 deg of WingInput twist per 0.25 s press, while Q / E, which
        # roll about the world's forward axis, only swing it, +-4.7 deg).
        select(port, keys, LEFT, "LeftBracket")
        time.sleep(0.8)
        rep.step("tilt_start")          # announced before the press: the baseline
        time.sleep(0.25)
        e0 = list(poses.last.get("left", [0] * 6))
        keys.press("DownArrow", 0.3)
        time.sleep(0.3)
        e1 = list(poses.last.get("left", [0] * 6))
        rep.d["tilt_euler"] = [e0[3:], e1[3:]]
        log("twist DownArrow: left euler %s -> %s" % (r0(e0[3:]), r0(e1[3:])))
        rep.step("tilt_left")
        time.sleep(1.9)
        keys.press("UpArrow", 0.3)
        rep.step("tilt_back")
        time.sleep(1.6)
        # One arm raised 0.3 m (dihedral), held, lowered.
        rep.step("raise_start")
        time.sleep(0.25)
        keys.press("R", 0.3)
        rep.step("raise_left")
        time.sleep(2.2)
        keys.press("F", 0.3)
        rep.step("lower_left")
        time.sleep(1.6)
        # Interleaved one-wing strokes: up 0.5 m then down 0.5 m, left then right.
        rep.step("strokes_begin")
        for k in range(4):
            select(port, keys, LEFT, "LeftBracket")
            keys.press("R", 0.5)
            keys.press("F", 0.5)
            select(port, keys, RIGHT, "RightBracket")
            keys.press("R", 0.5)
            keys.press("F", 0.5)
        rep.step("strokes_end")
        # Key-timed strokes leave the hands a few cm apart in height (the
        # holds jitter by a frame or two), and that dihedral difference flies
        # a gentle turn (fix round 4 run: roll input 0.09, ~5 deg/s). Level
        # both arms at the spread height again, closed loop, so the bird
        # flies straight into the look; the lab also subtracts any turn the
        # bird was already flying.
        after = {sd: r2(list(poses.last.get(sd, [0.0] * 6))[:3]) for sd in ("left", "right")}
        rep.d["poses_after_strokes"] = after
        log("after strokes: left %s right %s" % (after["left"], after["right"]))
        spread = rep.d.get("poses_spread", {})
        for want, sd, key in ((LEFT, "left", "LeftBracket"), (RIGHT, "right", "RightBracket")):
            if sd in spread and select(port, keys, want, key):
                move_y(keys, poses, sd, spread[sd][1], rep, "level_" + sd)
        rep.step("arms_level")
        # Look at the left wing: the headset alone yaws ~60 deg left (the
        # simulator's LeftArrow on the selected HMD), holds, and turns back.
        # 60 deg: past 70 WingInput's neck leash (FLIGHT_SPEC §5.2) takes a
        # gaze held that far round as the torso turning, by design.
        # The lab captures the head view and checks that the wing is in view
        # and that looking never steers (fix round 3).
        time.sleep(1.8)                 # the bank settles on the levelled arms
        if select(port, keys, HEAD):
            h0 = list(poses.last.get("head", [0.0] * 6))
            turn(keys, poses, "head", "LeftArrow", 64.0, rep, "look_left")
            # ... about the neck, as a person turns the head.
            h1 = list(poses.last.get("head", [0.0] * 6))
            move_to(keys, poses, "head", eye_for_fixed_neck(h0, heading(h1)), rep, "look_left_neck")
            rep.step("look_left_wing")
            time.sleep(1.6)
            rep.step("look_back_start")
            turn(keys, poses, "head", "RightArrow", 64.0, rep, "look_back")
            h2 = list(poses.last.get("head", [0.0] * 6))
            move_to(keys, poses, "head", eye_for_fixed_neck(h0, heading(h2)), rep, "look_back_neck")
            rep.step("look_back")
        else:
            rep.d["look_skipped"] = "could not select the headset alone"
            log("look skipped: could not select the headset alone")
        # Leave the session as it was found (in-memory selection).
        rep.d["selection_restored"] = select(port, keys, orig, "RightBracket", 8)
        rep.d["selection_after"] = selection(port)
    finally:
        keys.close()
        poses.stop()


def main():
    os.makedirs(ART, exist_ok=True)
    before = sha(PERSIST)
    rep = Report()
    rep.d["persistent_sha_before"] = before
    log("waiting for the lab (artifacts/flight/sim_state.json phase=input)")
    end = time.time() + 900
    st = {}
    while time.time() < end:
        try:
            with open(STATE) as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            st = {}
        if st.get("phase") == "input" and st.get("pid"):
            break
        if st.get("phase") == "done":
            log("lab finished without asking")
            return 1
        time.sleep(0.3)
    pid = st.get("pid")
    port = port_for_pid(pid)
    rep.d["pid"] = pid
    rep.d["port"] = port
    if not port:
        rep.d["error"] = "no SimRpc port for pid %s" % pid
        rep.d["done"] = True
        rep.write()
        log(rep.d["error"])
        return 1
    log("session pid", pid, "port", port)
    rep.t0 = time.time()
    try:
        drive(port, rep)
    except Exception as e:  # report, never leave the lab waiting
        rep.d["error"] = repr(e)
        log("error:", e)
    after = sha(PERSIST)
    rep.d["persistent_sha_after"] = after
    rep.d["persistent_unchanged"] = before == after
    rep.d["done"] = True
    rep.write()
    log("done; persistent_data unchanged:", before == after)
    return 0


if __name__ == "__main__":
    sys.exit(main())
