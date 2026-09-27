#!/usr/bin/env python3
"""Drive the Meta XR Simulator's controllers from a test (VR area).

The simulator runtime loads inside the Godot process and serves SimRpc
(gRPC) on a port it writes to its log (docs/research/QUEST.md §6.1). This
driver talks to it with curl (HTTP/2, no grpcio needed):

  * Input/GetInputPluginSettings (read-only) to see which devices the
    simulator's keys move,
  * Input/SendKey (a client stream of held keys) to press the simulator's
    own keybindings: CYCLE_INPUT_FORWARD/BACKWARD (']' / '[') to select the
    controllers (head left alone), MOVE_DOWN/UP (F/R) for a two-hand flap,
    TILT_LEFT/RIGHT (Q/E) for a wrist roll, and (fix round 4) the HEAD
    selected alone with ROTATE_H_POS (LeftArrow) to turn it left, so the
    harness can check that VR.recenter() re-centres the tracking space,
  * InputPositioning/GetInputPositioning (server stream) to log the poses
    the simulator believes in, for cross-checking with Godot's.

It NEVER calls Input/SetInputPluginSettings, SetInputSource, SetBindings or
SetActionInput: those persist into the simulator's persistent_data.json
(an earlier probe left dolly_scroll_speed=0 there). Device selection by
key cycling is in-memory runtime state of this session only. The file's
SHA-256 is compared before and after, and the result says whether it
changed. Nothing under ~/Library/Application Support/MetaXR is written.

Coordination with the Godot harness (tests/sim/vr_sim.gd) goes through
artifacts/vr/sim_state.json (harness -> driver: phase, pid) and
artifacts/vr/sim_driver.json (driver -> harness: what was done, when).

  python3 tests/sim/sim_driver.py drive      # wait for the harness, run the script
  python3 tests/sim/sim_driver.py calibrate  # the calibration step's check
                                             # (tests/sim/vr_calibration_sim.gd)
  python3 tests/sim/sim_driver.py probe      # newest session: report what ']' cycles

Mode "calibrate" (the calibration redesign): with the harness's first-launch
card up, it spreads the real simulated controllers with the simulator's own
keys (A / D out to the sides, S back to the shoulders, then each turned with
the yaw and pitch keys so the grip reads like a hand on a spread arm), closed
loop on the harness's reading of them (sim_state.json "status"), then lets
them rest so the harness sees the capture; then presses B/Y (N) to cancel a
new step, and takes the headset off and puts it back on with
DeviceService/SetUserPresent (SetUserPresentRequest{bool userPresent = 2},
decoded from SIMULATOR.so; runtime state, not persisted). At the end it
resets the controller poses (Space) and restores the device selection.
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ART = os.path.join(ROOT, "artifacts", "vr")
STATE = os.path.join(ART, "sim_state.json")
RESULT = os.path.join(ART, "sim_driver.json")
SIM_DIR = os.path.expanduser("~/Library/Application Support/MetaXR/MetaXrSimulator")
LOGS = os.path.join(SIM_DIR, "logs")
PERSIST = os.path.join(SIM_DIR, "persistent_data.json")
PKG = "openxr_simulator.rpc.proto."

# KeyboardKey enum values (sim_buttons.proto, decoded from SIMULATOR.so).
KEY = {"E": 38, "F": 39, "Q": 50, "R": 51, "LeftBracket": 79, "RightBracket": 81, "Space": 12,
       "LeftArrow": 1, "RightArrow": 2, "UpArrow": 3, "DownArrow": 4,
       "A": 34, "D": 37, "N": 47, "S": 52, "W": 56}


def log(*a):
    print("[vr-driver]", *a, flush=True)


# --- protobuf / gRPC framing --------------------------------------------------

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
    """Decode one protobuf message into {field: [values]} (bytes for len-delimited)."""
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


def messages(stream_bytes):
    """Split a gRPC byte stream into message payloads."""
    out = []
    i = 0
    while i + 5 <= len(stream_bytes):
        n = struct.unpack(">I", stream_bytes[i + 1:i + 5])[0]
        out.append(stream_bytes[i + 5:i + 5 + n])
        i += 5 + n
    return out


def curl(port, method, *extra):
    return ["curl", "-s", "-N", "--http2-prior-knowledge", "-X", "POST",
            "-H", "content-type: application/grpc", "-H", "te: trailers", *extra,
            "http://[::1]:%d/%s%s" % (port, PKG, method)]


def unary(port, method, msg=b""):
    r = subprocess.run(curl(port, method, "--data-binary", "@-"), input=frame(msg),
                       capture_output=True, timeout=10)
    msgs = messages(r.stdout)
    return msgs[0] if msgs else b""


def plugin_settings(port):
    f = fields(unary(port, "Input/GetInputPluginSettings"))
    g = lambda k, d: f.get(k, [d])[0]
    return {"movement_speed": g(1, 0.0), "body_locked": bool(g(2, 0)), "left": bool(g(3, 0)),
            "right": bool(g(4, 0)), "head": bool(g(5, 0)), "dolly": g(6, 0.0)}


def input_source(port, hand):
    f = fields(unary(port, "Input/GetInputSource", b"\x10" + bytes([hand])))
    return f.get(2, [0])[0]


class Keys:
    """A held-keys client stream (each message = the full set of keys down)."""

    def __init__(self, port):
        self.p = subprocess.Popen(curl(port, "Input/SendKey", "-T", "-"), stdin=subprocess.PIPE,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def hold(self, *names):
        msg = b"".join(b"\x08" + bytes([KEY[n]]) for n in names)
        self.p.stdin.write(frame(msg))
        self.p.stdin.flush()

    def tap(self, name, secs=0.18):
        self.hold(name)
        time.sleep(secs)
        self.hold()
        time.sleep(0.25)

    def close(self):
        try:
            self.hold()
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


class Poses(threading.Thread):
    """Records the simulator's pose stream (head / left / right positions)."""

    def __init__(self, port):
        super().__init__(daemon=True)
        self.port = port
        self.samples = []
        self.t0 = time.time()
        self.p = None

    def run(self):
        self.p = subprocess.Popen(curl(self.port, "InputPositioning/GetInputPositioning", "--data-binary", "@-"),
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.p.stdin.write(frame(b""))
        self.p.stdin.close()
        buf = b""
        while True:
            chunk = self.p.stdout.read1(4096) if hasattr(self.p.stdout, "read1") else self.p.stdout.read(4096)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 5:
                n = struct.unpack(">I", buf[1:5])[0]
                if len(buf) < 5 + n:
                    break
                msg, buf = buf[5:5 + n], buf[5 + n:]
                try:
                    self.samples.append(self._decode(msg))
                except Exception:
                    pass

    def _decode(self, msg):
        f = fields(msg)
        out = {"t": round(time.time() - self.t0, 3)}
        for key, fn in (("head", 1), ("left", 2), ("right", 3)):
            if fn in f:
                pd = fields(f[fn][0])
                pos = fields(pd[1][0]) if 1 in pd else {}
                ori = fields(pd[2][0]) if 2 in pd else {}
                out[key] = [round(pos.get(k, [0.0])[0], 3) for k in (1, 2, 3)] + \
                           [round(ori.get(k, [0.0])[0], 1) for k in (1, 2, 3)]
        return out

    def stop(self):
        if self.p:
            self.p.kill()


# --- session discovery ----------------------------------------------------------

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


def newest_port(since):
    for name in sorted(os.listdir(LOGS), key=lambda n: os.path.getmtime(os.path.join(LOGS, n)), reverse=True):
        path = os.path.join(LOGS, name)
        if os.path.getmtime(path) < since:
            break
        with open(path, errors="replace") as fh:
            for line in fh:
                if "SimRpc server started on port" in line:
                    return int(line.rsplit(" ", 1)[1]), name
    return None, None


def sha(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def read_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _finite(o):
    """JSON the harness can parse: NaN / inf (the pose stream's Euler angles
    of a controller pitched through the vertical) become null."""
    if isinstance(o, float):
        return o if o == o and o not in (float("inf"), float("-inf")) else None
    if isinstance(o, dict):
        return {k: _finite(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_finite(v) for v in o]
    return o


def write_result(d):
    os.makedirs(ART, exist_ok=True)
    tmp = RESULT + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(_finite(d), fh, indent=2, allow_nan=False)
    os.replace(tmp, RESULT)


# --- device selection -------------------------------------------------------------

def select(port, keys, want, tries=6):
    """Cycles the controlled device with ']' until the settings match `want`
    ({left, right, head}); returns the list of states seen."""
    seen = []
    for _ in range(tries):
        s = plugin_settings(port)
        seen.append({k: s[k] for k in ("left", "right", "head")})
        if all(s[k] == v for k, v in want.items()):
            return True, seen
        keys.tap("RightBracket")
    s = plugin_settings(port)
    seen.append({k: s[k] for k in ("left", "right", "head")})
    return all(s[k] == v for k, v in want.items()), seen


def drive(port, result):
    keys = Keys(port)
    poses = Poses(port)
    poses.start()
    t0 = time.time()
    actions = []

    def act(name):
        actions.append([round(time.time() - t0, 3), name])
        log(name)

    try:
        orig = plugin_settings(port)
        result["settings_before"] = orig
        result["input_source_before"] = [input_source(port, 0), input_source(port, 1)]
        # The simulator's device cycle is all -> head -> left -> right (no
        # "both controllers, head still" state without SetInputPluginSettings,
        # which persists): flap with interleaved one-hand strokes, head still.
        result["flap_style"] = "interleaved one-hand strokes (head still)"
        strokes_ok = True
        for k in range(2):
            for direction, key in (("down", "F"), ("up", "R")):
                for hand, want in (("left", {"left": True, "right": False, "head": False}),
                                   ("right", {"left": False, "right": True, "head": False})):
                    ok, seen = select(port, keys, want)
                    result.setdefault("cycle_states", seen)
                    strokes_ok = strokes_ok and ok
                    if ok:
                        act("flap%d_%s_%s" % (k, direction, hand))
                        keys.hold(key)
                        time.sleep(0.45)
                        keys.hold()
                        time.sleep(0.15)
        result["both_controllers_selected"] = strokes_ok
        ok_l, seen_l = select(port, keys, {"left": True, "right": False, "head": False})
        result["cycle_states_left"] = seen_l
        result["left_selected"] = ok_l
        if ok_l:
            time.sleep(0.3)
            act("roll_left")
            keys.hold("Q")
            time.sleep(0.3)
            keys.hold()
            time.sleep(0.8)
            act("roll_back")
            keys.hold("E")
            time.sleep(0.3)
            keys.hold()
            time.sleep(0.4)
        # Turn the head left (the harness then recenters and checks the
        # view faces forward again).
        ok_h, seen_h = select(port, keys, {"left": False, "right": False, "head": True})
        result["cycle_states_head"] = seen_h
        result["head_selected"] = ok_h
        if ok_h:
            time.sleep(0.3)
            act("head_turn_left")
            keys.hold("LeftArrow")
            time.sleep(0.5)
            keys.hold()
            time.sleep(0.4)
        # Leave the session as it was found (in-memory state).
        ok_r, seen_r = select(port, keys, {"left": orig["left"], "right": orig["right"], "head": orig["head"]}, 8)
        result["restored_selection"] = ok_r
        result["settings_after"] = plugin_settings(port)
        result["input_source_after"] = [input_source(port, 0), input_source(port, 1)]
    finally:
        keys.close()
        time.sleep(0.3)
        poses.stop()
    result["actions"] = actions
    result["sim_poses"] = poses.samples[::2]


def wait_phase(want, timeout):
    """Waits for the harness's phase (one of `want`); returns it or None."""
    end = time.time() + timeout
    while time.time() < end:
        st = read_state()
        if st.get("phase") in want:
            return st.get("phase")
        time.sleep(0.1)
    return None


def status():
    return read_state().get("status", {})


def hold_until(keys, key, cond, max_s):
    """Holds `key` until cond() (checked every 30 ms) or max_s; returns the
    seconds held. Releases and lets the pose settle."""
    t0 = time.time()
    keys.hold(key)
    try:
        while time.time() - t0 < max_s:
            try:
                if cond():
                    break
            except (KeyError, IndexError, TypeError):
                pass
            time.sleep(0.03)
    finally:
        keys.hold()
    held = time.time() - t0
    time.sleep(0.35)
    return round(held, 3)


def last_motion(poses):
    """Unix time of the last pose-stream sample in which either controller
    had moved (> 2 mm) or turned (> 0.3°) since the one before."""
    last = poses.t0
    prev = None
    for smp in list(poses.samples):
        cur = [smp.get("left"), smp.get("right")]
        if prev is not None and all(c is not None for c in cur + prev):
            for a, b in zip(cur, prev):
                moved = max(abs(a[k] - b[k]) for k in range(3)) > 0.002
                # Euler angles through a gimbal pole read NaN: a change too.
                turned = any(abs(a[k] - b[k]) > 0.3 or (a[k] != a[k]) != (b[k] != b[k]) for k in range(3, 6))
                if moved or turned:
                    last = poses.t0 + smp["t"]
        prev = cur
    return last


def calibrate(port, result):
    keys = Keys(port)
    poses = Poses(port)
    poses.start()
    t0 = time.time()
    actions = []
    last_move = [time.time()]

    def act(name, extra=None):
        actions.append([round(time.time() - t0, 3), name] + ([extra] if extra is not None else []))
        log(name, extra if extra is not None else "")

    def dev(name):
        return poses.samples[-1][name] if poses.samples and name in poses.samples[-1] else None

    orig = plugin_settings(port)
    result["settings_before"] = orig
    # The same list, so every interim write carries the actions so far.
    result["actions"] = actions
    try:
        time.sleep(0.5)
        # Out to the sides (A / D move the selected controller), back to the
        # shoulders (S), each alone (the head stays still).
        for side, out_key, sign in (("left", "A", -1.0), ("right", "D", 1.0)):
            ok, seen = select(port, keys, {"left": side == "left", "right": side == "right", "head": False})
            result.setdefault("selection", []).append({side: ok, "seen": seen})
            if not ok:
                raise RuntimeError("could not select the %s controller alone" % side)
            act("move_%s_out" % side, hold_until(keys, out_key, lambda: sign * dev(side)[0] >= 0.72, 1.5))
            act("move_%s_back" % side, hold_until(keys, "S", lambda: dev(side)[2] >= -0.10, 1.2))
            last_move[0] = time.time()
        # Turn each grip like a hand on a spread arm: yaw it outward 90°, then
        # pitch it up until the harness reads its forearm axis within 20° of
        # the grip convention (the capture refuses > 45°).
        for i, (side, yaw_key, yaw_sign) in enumerate((("left", "LeftArrow", 1.0), ("right", "RightArrow", -1.0))):
            ok, _ = select(port, keys, {"left": side == "left", "right": side == "right", "head": False})
            if not ok:
                raise RuntimeError("could not select the %s controller alone" % side)
            act("turn_%s_yaw" % side, hold_until(keys, yaw_key, lambda: yaw_sign * dev(side)[4] >= 85.0, 2.5))
            act("turn_%s_pitch" % side, hold_until(keys, "UpArrow", lambda: status()["axis_deg"][i] <= 20.0, 2.0))
            last_move[0] = time.time()
        result["last_move_unix"] = last_move[0]
        result["status_after_moves"] = status()
        write_result(result)
        act("spread_done", status().get("axis_deg"))
        # The harness sees the capture, then asks the arms to relax (so a
        # new step does not capture the same still spread at once).
        ph = wait_phase(("relax", "done"), 60.0)
        act("phase", ph)
        if ph == "relax":
            # When the controllers last moved, from the simulator's own pose
            # stream (the harness checks the capture came a full hold later).
            result["last_motion_unix"] = last_motion(poses)
            ok, _ = select(port, keys, {"left": False, "right": True, "head": False})
            act("relax_right_down", hold_until(keys, "F", lambda: dev("right")[1] <= 1.05, 0.6))
            result["relaxed"] = True
            write_result(result)
            ph = wait_phase(("cancel", "done"), 30.0)
            act("phase", ph)
        if ph == "cancel":
            time.sleep(1.0)
            act("press_by")
            keys.tap("N", 0.2)
            ph = wait_phase(("presence", "done"), 30.0)
            act("phase", ph)
        if ph == "presence":
            time.sleep(0.5)
            pres = {}
            for present in (False, True):
                r = subprocess.run(curl(port, "DeviceService/SetUserPresent", "-i", "--data-binary", "@-"),
                                   input=frame(b"\x10" + bytes([1 if present else 0])), capture_output=True, timeout=10)
                head = r.stdout.split(b"\r\n\r\n", 1)[0].decode("latin-1", "replace")
                grpc_status = [ln for ln in r.stdout.decode("latin-1", "replace").splitlines() if ln.lower().startswith("grpc-status")]
                pres["present_%s" % present] = {"http": head.splitlines()[0] if head else "", "grpc_status": grpc_status}
                act("user_present_%s" % present)
                time.sleep(2.5)
            result["presence"] = pres
            result["presence_done"] = True
            write_result(result)
            wait_phase(("done",), 30.0)
    finally:
        # Leave the session as it was found: controller poses reset (Space),
        # the device selection restored (in-memory state only).
        try:
            select(port, keys, {"left": orig["left"], "right": orig["right"], "head": orig["head"]}, 8)
            keys.tap("Space", 0.15)
            result["settings_after"] = plugin_settings(port)
        finally:
            keys.close()
            time.sleep(0.3)
            poses.stop()
    result["actions"] = actions
    result["sim_poses"] = poses.samples[::2]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "drive"
    before = sha(PERSIST)
    result = {"mode": mode, "persistent_sha_before": before, "done": False}
    if mode == "probe_keys":
        port, name = newest_port(time.time() - 120)
        if not port:
            log("no running simulator session found")
            return 2
        log("session", name, "port", port)
        poses = Poses(port)
        poses.start()
        time.sleep(1.0)
        keys = Keys(port)
        marks = []
        for label, key, secs in (("F", "F", 0.4), ("R", "R", 0.4), ("]", "RightBracket", 0.15),
                                 ("F after ]", "F", 0.4), ("R after ]", "R", 0.4), ("[", "LeftBracket", 0.15)):
            marks.append((round(time.time() - poses.t0, 2), label))
            keys.hold(key)
            time.sleep(secs)
            keys.hold()
            time.sleep(0.8)
            log(label, "->", poses.samples[-1] if poses.samples else None,
                "action", fields(unary(port, "Input/GetActionInput")).get(2, [None])[0],
                {k: v for k, v in plugin_settings(port).items() if k in ("left", "right", "head")})
        keys.close()
        poses.stop()
        log("marks", marks)
        log("persistent_data unchanged:", before == sha(PERSIST))
        return 0
    if mode == "probe":
        port, name = newest_port(time.time() - 120)
        if not port:
            log("no running simulator session found")
            return 2
        log("session", name, "port", port)
        keys = Keys(port)
        states = [plugin_settings(port)]
        srcs = [[input_source(port, 0), input_source(port, 1)]]
        for _ in range(5):
            keys.tap("RightBracket")
            states.append(plugin_settings(port))
            srcs.append([input_source(port, 0), input_source(port, 1)])
        keys.close()
        for s, src in zip(states, srcs):
            log({k: s[k] for k in ("left", "right", "head", "movement_speed", "dolly")}, "sources", src)
        after = sha(PERSIST)
        log("persistent_data unchanged:", before == after)
        return 0
    # drive: wait for the harness to ask.
    log("waiting for the harness (artifacts/vr/sim_state.json phase=input)")
    end = time.time() + 1800
    st = {}
    while time.time() < end:
        st = read_state()
        if st.get("phase") == "input" and st.get("pid"):
            break
        if st.get("phase") == "done":
            log("harness finished without asking")
            return 1
        time.sleep(0.3)
    pid = st.get("pid")
    port = port_for_pid(pid)
    result["pid"] = pid
    result["port"] = port
    if not port:
        result["error"] = "no SimRpc port for pid %s" % pid
        write_result(result)
        log(result["error"])
        return 1
    log("session pid", pid, "port", port)
    try:
        if mode == "calibrate":
            calibrate(port, result)
        else:
            drive(port, result)
    except Exception as e:  # report, never leave the harness waiting
        result["error"] = repr(e)
        log("error:", e)
    after = sha(PERSIST)
    result["persistent_sha_after"] = after
    result["persistent_unchanged"] = before == after
    result["done"] = True
    write_result(result)
    log("done; persistent_data unchanged:", before == after)
    return 0


if __name__ == "__main__":
    sys.exit(main())
