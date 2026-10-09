#!/usr/bin/env python3
"""Summary of valley part files (a tuning aid, fix round 5):

    python3 tests/shots/gameloop_batch_summary.py <glob of part names> [...]
    e.g.  python3 tests/shots/gameloop_batch_summary.py 'x1_com_*' 'x1_q_*'

Per glob: runs, sky hashes, tuning, median time to pigeon / eagle (a run that
never got there counts as later than every run that did), share reaching the
eagle, apex won, deaths (caught at least once, mean, median, lost), catches a
minute, and the cue metrics (masked attacks, attack onsets named late, target
changes away from a still-valid bird)."""
import glob
import json
import os
import statistics
import sys

ART = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "artifacts", "gameloop")
PIGEON, EAGLE = "5", "9"


def runs_of(pattern):
    out, meta = [], set()
    for f in sorted(glob.glob(os.path.join(ART, "integrated_live_part_%s.json" % pattern))):
        d = json.load(open(f))
        ev = d.get("evidence", {})
        if ev.get("partial"):
            continue
        meta.add((ev.get("fingerprint"), ev.get("ai_code"), ev.get("world_code"), json.dumps(ev.get("tuning"), sort_keys=True)))
        for block in ("skills", "holdout"):
            for sk, v in ev.get(block, {}).items():
                for r in v["runs"]:
                    r = dict(r)
                    r["_skill"] = sk
                    out.append(r)
    return out, meta


def reach(r, t):
    best = float("inf")
    for k in range(int(t), 10):
        v = r["tier_at"].get(str(k))
        if v is not None:
            best = min(best, float(v))
    return best


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return float("nan")
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def mmss(s):
    if s != s or s == float("inf"):
        return "never"
    return "%d:%02d" % (int(s) // 60, int(s) % 60)


def main():
    for pat in sys.argv[1:]:
        rs, meta = runs_of(pat)
        if not rs:
            print(pat, "no finished runs")
            continue
        n = len(rs)
        pig = [reach(r, PIGEON) for r in rs]
        eag = [reach(r, EAGLE) for r in rs]
        deaths = [int(r["deaths"]) for r in rs]
        caught = sum(1 for d in deaths if d > 0)
        lost = sum(1 for r in rs if r["end_reason"] == "caught")
        won = sum(1 for r in rs if r["end_reason"] == "victory")
        minutes = sum(float(r["ended_at"]) for r in rs) / 60.0
        catches = sum(int(r["catches"]) for r in rs)
        cue = {}
        for r in rs:
            for k, v in r.get("cue", {}).items():
                if isinstance(v, (int, float)):
                    cue[k] = cue.get(k, 0.0) + v
        tg = {}
        holds = []
        pholds = []
        why = {}
        for r in rs:
            for k, v in r.get("target_cue", {}).items():
                if k == "holds":
                    holds += v
                elif k == "preference_holds":
                    pholds += v
                elif k == "why":
                    for kk, vv in v.items():
                        why[kk] = why.get(kk, 0) + vv
                elif isinstance(v, (int, float)):
                    tg[k] = tg.get(k, 0.0) + v
        am = cue.get("attack_s", 0.0) / 60.0
        print("== %s: %d runs, %s" % (pat, n, sorted({m[1] for m in meta})))
        for m in meta:
            print("   fp %s ai %s world %s tuning %s" % m)
        print("   pigeon %s  eagle %s  (eagle reached %d/%d, apex won %d)" % (mmss(med(pig)), mmss(med(eag)),
              sum(1 for e in eag if e < float("inf")), n, won))
        print("   pigeon in 5-8: %d/%d, eagle in 20-30: %d/%d" % (sum(1 for p in pig if 300 <= p <= 480), n,
              sum(1 for e in eag if 1200 <= e <= 1800), n))
        print("   deaths: caught >=1 %d/%d (%.0f%%), mean %.2f, median %.1f, lost %d" % (caught, n, 100.0 * caught / n,
              sum(deaths) / n, med(deaths), lost))
        print("   catches/min %.2f, attack-min %.1f" % (catches / max(minutes, 1e-6), am))
        print("   cue: masked %.1fs/%d eps (live %.1fs), onsets %d late %d never %d held %d, ping_pong %d, bystander %d, harmless %d, not_own %d" % (
            cue.get("masked_s", 0), cue.get("masked_episodes", 0), cue.get("masked_live_s", 0), cue.get("onsets", 0),
            cue.get("onsets_late", 0), cue.get("onsets_never", 0), cue.get("onsets_held", 0), cue.get("ping_pong", 0),
            cue.get("attack_to_bystander", 0), cue.get("attack_to_harmless", 0), cue.get("not_own", 0)))
        print("   target: changes %.2f/min, voluntary %.2f/min, closing %.2f/min, within 3 s %d, median hold %.1f s" % (
            tg.get("changes", 0) / minutes, tg.get("voluntary", 0) / minutes, tg.get("voluntary_closing", 0) / minutes,
            tg.get("voluntary_within_3s", 0), med(holds) if holds else float("nan")))
        print("   target by preference: %.2f/min, closing %.2f/min, median hold %.1f s; why %s" % (
            tg.get("preference", 0) / minutes, tg.get("preference_closing", 0) / minutes,
            med(pholds) if pholds else float("nan"), dict(sorted(why.items()))))
        print("   per run: " + " ".join("%d:%s/%s/%d" % (r["seed"], mmss(p), mmss(e), d) for r, p, e, d in
              sorted(zip(rs, pig, eag, deaths), key=lambda x: x[0]["seed"])))


if __name__ == "__main__":
    main()
