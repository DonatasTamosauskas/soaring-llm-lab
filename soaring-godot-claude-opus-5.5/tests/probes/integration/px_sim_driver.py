#!/usr/bin/env python3
"""VERIFIER PROBE driver (integration, player-experience lens, round 1).

Moves the Meta XR Simulator's own controllers for tests/probes/integration/
px_sim.tscn over SimRpc, reusing the VR / flight / integration drivers'
helpers (SendKey only; never SetInputPluginSettings / SetInputSource /
SetBindings / SetActionInput; the persistent_data.json hash is compared
before and after). Coordination through its own files:
artifacts/integration/verify/px_sim_state.json (game -> driver) and
px_sim_driver.json (driver -> game), so it never drives another run.

Phases: menu (laser on Play + trigger), spread, stroke (8 interleaved
stroke pairs), level (arms back to the spread height), twist (left wrist
leading edge down 2.5 s), dihedral (left arm raised 0.3 m for 3 s).
"""
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, "tests", "sim"))
sys.path.insert(0, os.path.join(ROOT, "tests", "shots"))
import sim_driver as sd  # noqa: E402
import flight_sim_driver as fd  # noqa: E402
import integration_sim_driver as isd  # noqa: E402

VERIFY = os.path.join(ROOT, "artifacts", "integration", "verify")
isd.STATE = os.path.join(VERIFY, "px_sim_state.json")
isd.RESULT = os.path.join(VERIFY, "px_sim_driver.json")
isd.ART = VERIFY


def log(*a):
    print("[integration-pxdriver]", *a, flush=True)


def main():
    os.makedirs(VERIFY, exist_ok=True)
    for p in (isd.STATE, isd.RESULT):
        try:
            os.remove(p)
        except OSError:
            pass
    before = sd.sha(sd.PERSIST)
    result = {"persistent_sha_before": before}
    isd.write(result)
    log("waiting for px_sim (phase=menu)")
    st = isd.wait_phase("calib" if "--first" in sys.argv else "menu", 1500)
    if not st:
        result["error"] = "no menu phase"
        isd.write(result)
        return 1
    port = sd.port_for_pid(st["pid"])
    result["port"] = port
    if not port:
        result["error"] = "no SimRpc port"
        isd.write(result)
        return 1
    if "--first" in sys.argv:
        k2 = fd.Keys(port)
        p2 = fd.Poses(port)
        p2.start()
        rep2 = isd._Rep()
        try:
            k2.tap("Space")
            time.sleep(0.5)
            fd.select(port, k2, fd.LEFT)
            k2.press("A", 0.55)
            k2.press("S", 0.46)
            fd.turn(k2, p2, "left", "LeftArrow", 90.0, rep2, "yaw_left_out")
            fd.select(port, k2, fd.RIGHT)
            k2.press("D", 0.55)
            k2.press("S", 0.46)
            fd.turn(k2, p2, "right", "RightArrow", 90.0, rep2, "yaw_right_out")
            result["calib_spread"] = True
            isd.write(result)
            time.sleep(4.0)
            k2.tap("Space")
            time.sleep(1.0)
            result["calib_done"] = True
            isd.write(result)
        finally:
            k2.close()
            p2.stop()
        st = isd.wait_phase("menu", 60) or st
    keys = sd.Keys(port)
    orig = sd.plugin_settings(port)
    result["settings_before"] = orig
    try:
        ok, seen = sd.select(port, keys, {"left": False, "right": True, "head": False})
        result["right_selected"] = ok
        pulls = 0
        for attempt in range(3):
            if not isd.aim_at_play(keys, result):
                log("could not aim at Play; hovered:", isd.state().get("hovered"))
                break
            result["hovered_at_pull"] = isd.state().get("hovered")
            time.sleep(0.3)
            keys.hold("T")
            time.sleep(0.3)
            keys.hold()
            pulls += 1
            time.sleep(1.2)
            if isd.state().get("state") == "PLAYING":
                break
        result["pulls"] = pulls
        result["menu_done"] = True
        isd.write(result)
        log("menu done:", isd.state().get("state"))
    finally:
        keys.close()
    keys = fd.Keys(port)
    poses = fd.Poses(port)
    poses.start()
    rep = isd._Rep()
    try:
        if isd.wait_phase("spread", 120):
            keys.tap("Space")
            time.sleep(0.5)
            if not fd.select(port, keys, fd.LEFT):
                result["error"] = "left select"
            keys.press("A", 0.55)
            keys.press("S", 0.46)
            fd.turn(keys, poses, "left", "LeftArrow", 90.0, rep, "yaw_left_out")
            fd.select(port, keys, fd.RIGHT)
            keys.press("D", 0.55)
            keys.press("S", 0.46)
            fd.turn(keys, poses, "right", "RightArrow", 90.0, rep, "yaw_right_out")
            spread = dict(poses.last)
            result["spread_poses"] = spread
            time.sleep(2.5)
            result["spread_done"] = True
            isd.write(result)
        if isd.wait_phase("stroke", 30):
            for k in range(8):
                fd.select(port, keys, fd.LEFT, "LeftBracket")
                keys.press("R", 0.5)
                keys.press("F", 0.5)
                fd.select(port, keys, fd.RIGHT, "RightBracket")
                keys.press("R", 0.5)
                keys.press("F", 0.5)
                log("stroke pair", k)
            result["strokes_done"] = True
            isd.write(result)
        if isd.wait_phase("level", 30):
            sp = result.get("spread_poses", {})
            for want, side, key in ((fd.LEFT, "left", "LeftBracket"), (fd.RIGHT, "right", "RightBracket")):
                if side in sp and fd.select(port, keys, want, key):
                    fd.move_y(keys, poses, side, sp[side][1], rep, "level_" + side)
            time.sleep(1.5)
            result["level_done"] = True
            isd.write(result)
        if isd.wait_phase("twist", 30):
            fd.select(port, keys, fd.LEFT, "LeftBracket")
            time.sleep(0.5)
            keys.press("DownArrow", 0.3)
            time.sleep(2.5)
            keys.press("UpArrow", 0.3)
            time.sleep(1.5)
            result["twist_done"] = True
            isd.write(result)
        if isd.wait_phase("dihedral", 30):
            fd.select(port, keys, fd.LEFT, "LeftBracket")
            keys.press("R", 0.3)
            time.sleep(3.0)
            keys.press("F", 0.3)
            time.sleep(1.5)
            result["dihedral_done"] = True
            isd.write(result)
        result["selection_restored"] = fd.select(port, keys, {"left": orig["left"], "right": orig["right"], "head": orig["head"]}, "RightBracket", 8)
    finally:
        keys.close()
        poses.stop()
    after = sd.sha(sd.PERSIST)
    result["persistent_unchanged"] = before == after
    result["done"] = True
    isd.write(result)
    log("done; persistent unchanged:", before == after)
    return 0


if __name__ == "__main__":
    sys.exit(main())
