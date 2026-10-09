#!/usr/bin/env python3
"""VERIFIER PROBE driver: headset off / on for vrq_presence.gd through the
simulator's DeviceService/SetUserPresent (runtime state, not persisted; the
persistent_data.json hash is compared before and after)."""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(ROOT, "tests", "sim"))
import sim_driver as sd  # noqa: E402

DIR = os.path.join(ROOT, "artifacts", "integration", "verify", "vrq")
STATE = os.path.join(DIR, "presence_state.json")
OUT = os.path.join(DIR, "presence_driver.json")


def state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write(d):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(d, fh)
    os.replace(tmp, OUT)


def wait(ph, timeout):
    end = time.time() + timeout
    while time.time() < end:
        st = state()
        if st.get("phase") in (ph, "done"):
            return st
        time.sleep(0.2)
    return {}


def present(port, on):
    r = subprocess.run(sd.curl(port, "DeviceService/SetUserPresent", "-i", "--data-binary", "@-"),
                       input=sd.frame(b"\x10" + bytes([1 if on else 0])), capture_output=True, timeout=10)
    return [ln for ln in r.stdout.decode("latin-1", "replace").splitlines() if ln.lower().startswith("grpc-status")]


def main():
    res = {"sha_before": sd.sha(sd.PERSIST)}
    write(res)
    st = wait("off", 300)
    if st.get("phase") != "off":
        return 1
    port = sd.port_for_pid(st["pid"])
    res["port"] = port
    res["off"] = present(port, False)
    time.sleep(3.0)
    res["off_done"] = True
    write(res)
    st = wait("on", 60)
    if st.get("phase") == "on":
        res["on"] = present(port, True)
        res["on_done"] = True
    wait("done", 60)
    res["persistent_unchanged"] = sd.sha(sd.PERSIST) == res["sha_before"]
    write(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
