#!/usr/bin/env python3
"""Camera-heave evaluation on recorded flights (round 2): the round-2
verifier's human-flapping measures applied to the camera the ENGINE produced.

  tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_heave_dump
  tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_heave_dump --set=heldout
  python3 tests/shots/flight_heave_eval.py

The dump (tests/shots/flight_heave_dump_test.gd) flies the verifier's probe
scenarios (tempo, flap-flap-glide, one-wing, steady, irregular seeds 11-13,
the jitter/pause sweep seeds 21-23, the novice bot seeds 1-3) plus PB-08b's
and the bot course, and a held-out set with other seeds (31-33, 41-43, 21-23
novice) that was never used while tuning. Per run: the per-tick jerk ratio
(max |d2 y| of camera / body), the wingbeat-band vertical acceleration of
the view against the body's over 3 s windows (mean ratio, share of windows
above 1.1 x and 1.5 x, worst window), perceived (/ world_scale). Writes
artifacts/flight/heave_eval.json and prints a summary. The offline design
study (prototypes of every alternative and the ablations) is in
artifacts/flight/dev/heave_study/.
"""
import csv, glob, json, math, os, re

DT = 1.0 / 72.0
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ART = os.path.join(REPO, "artifacts", "flight")


def load(path):
    cols = {}
    with open(path) as f:
        r = csv.reader(f)
        hdr = next(r)
        for h in hdr:
            cols[h] = []
        for row in r:
            for h, v in zip(hdr, row):
                cols[h].append(float(v))
    return cols


def max_d2(c, ys):
    m = 0.0
    fl = c["flying"]
    for i in range(1, len(ys) - 1):
        if fl[i - 1] and fl[i] and fl[i + 1]:
            m = max(m, abs(ys[i + 1] - 2 * ys[i] + ys[i - 1]) / c["ws"][i] * 100.0)
    return m


def band_prefix(c, ys):
    n = len(ys)
    acc = [0.0] * n
    for i in range(1, n - 1):
        acc[i] = (ys[i + 1] - 2 * ys[i] + ys[i - 1]) / (DT * DT) / c["ws"][i]
    pre = [0.0] * (n + 1)
    for i in range(n):
        pre[i + 1] = pre[i] + acc[i]
    p2 = [0.0] * (n + 1)
    for i in range(n):
        d2 = 0.0
        if 37 <= i < n - 37:
            m = (pre[i + 37] - pre[i - 36]) / 73.0
            d2 = (acc[i] - m) ** 2
        p2[i + 1] = p2[i] + d2
    return p2


def band_windows(c, cam, body, win=3.0, step=0.5):
    pc, pb = band_prefix(c, cam), band_prefix(c, body)
    n, st, N = int(win / DT), int(step / DT), len(cam)

    def rms(p2, a, b):
        a, b = max(a, 37), min(b, N - 37)
        return math.sqrt((p2[b] - p2[a]) / (b - a)) if b > a else 0.0

    cnt = o11 = o15 = 0
    sc = sb = worst = 0.0
    i = 72
    while i + n < N - 72:
        if all(c["flying"][j] for j in range(i, i + n, 6)):
            cc, bb = rms(pc, i, i + n), rms(pb, i, i + n)
            if bb > 0.3:
                cnt += 1
                sc += cc
                sb += bb
                worst = max(worst, cc / bb)
                o11 += cc > 1.1 * bb
                o15 += cc > 1.5 * bb
        i += st
    d = max(cnt, 1)
    return {"cam": sc / d, "body": sb / d, "ratio": sc / max(sb, 1e-9), "over_11": o11 / d, "over_15": o15 / d,
            "worst": worst, "windows": cnt}


def main():
    report = {}
    for sub in ["heave_data", "heave_data_heldout"]:
        rows = {}
        for p in sorted(glob.glob(os.path.join(ART, "dev", sub, "*.csv"))):
            c = load(p)
            name = os.path.basename(p)[:-4]
            bw = band_windows(c, c["cam"], c["body"])
            rows[name] = dict(bw, jerk=max_d2(c, c["cam"]) / max(max_d2(c, c["body"]), 1e-9))
        sweep = {}
        for sp in ["sparrow", "pigeon", "eagle"]:
            for j, pz in [(10, 0), (20, 0), (30, 0), (10, 35), (20, 35)]:
                ks = [k for k in rows if re.match(r"%s_sweep_j%d_p%d_s\d+$" % (sp, j, pz), k)]
                if ks:
                    sweep["%s_j%d_p%d" % (sp, j, pz)] = sum(rows[k]["ratio"] for k in ks) / len(ks)
        worst = {k: max(r[k] for r in rows.values()) for k in ["ratio", "over_11", "over_15", "worst", "jerk"]}
        report[sub] = {"runs": rows, "sweep_mean_ratio": sweep, "worst": worst}
        print("== %s: %d runs" % (sub, len(rows)))
        print("   worst: mean band ratio %.3f, windows > 1.1x %.0f%%, windows > 1.5x %.0f%%, worst window %.2fx, jerk %.2fx" % (
            worst["ratio"], 100 * worst["over_11"], 100 * worst["over_15"], worst["worst"], worst["jerk"]))
        print("   sweep (3-seed mean band ratio): " + ", ".join("%s %.3f" % kv for kv in sweep.items()))
        for k in sorted(rows):
            if any(t in k for t in ["_v_", "_nov_", "_b1_", "cruise"]):
                r = rows[k]
                print("   %-30s band %.3f  >1.1x %3.0f%%  worst %.2f  jerk %.2f" % (k, r["ratio"], 100 * r["over_11"], r["worst"], r["jerk"]))
    json.dump(report, open(os.path.join(ART, "heave_eval.json"), "w"), indent=1)
    print("report: %s" % os.path.join(ART, "heave_eval.json"))


main()
