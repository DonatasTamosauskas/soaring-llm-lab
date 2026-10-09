#!/usr/bin/env python3
"""The tables of docs/areas/GAMELOOP.md "Pacing, danger and cadence: results",
from the merged evidence (a doc aid, fix round 5):

    python3 tests/shots/gameloop_evidence_tables.py

Reads scripts/game/data/live_ai_evidence.json (full tier: tuning set of every
skill, competent held-out set) and live_ai_quest_evidence.json (Quest tier:
competent tuning and held-out sets); prints markdown rows and the numbers the
text quotes. A tier never reached counts as later than every run that got
there (medians of an even count: the mean of the middle two)."""
import json
import math
import os
import statistics

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
DATA = os.path.join(ROOT, "scripts", "game", "data")
SPECIES = ["moth", "wren", "sparrow", "swallow", "starling", "pigeon", "crow", "gull", "hawk", "eagle"]
INF = float("inf")


def load(name):
    with open(os.path.join(DATA, name)) as f:
        return json.load(f)


def reach(r, t):
    best = INF
    for k in range(t, 10):
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
    if s != s or s == INF:
        return "never"
    return "%d:%02d" % (int(s) // 60, int(s) % 60)


def gaps(r):
    out, prev = [], 0.0
    for c in r.get("catch_log", []):
        out.append(float(c[0]) - prev)
        prev = float(c[0])
    if r["end_reason"] != "victory":
        out.append(float(r["ended_at"]) - prev)
    return out


def climb_longest(r):
    eag = min(reach(r, 9), float(r["ended_at"]))
    prev, climb = 0.0, 0.0
    for c in r.get("catch_log", []):
        t = float(c[0])
        if prev >= eag:
            break
        climb = max(climb, min(t, eag) - prev)
        prev = t
    if prev < eag:
        climb = max(climb, eag - prev)
    return climb


def row(label, runs):
    n = len(runs)
    cells = [mmss(med([reach(r, t) for r in runs])) for t in range(3, 10)]
    deaths = [int(r["deaths"]) for r in runs]
    caught = sum(1 for d in deaths if d > 0)
    lost = sum(1 for r in runs if r["end_reason"] == "caught")
    eagle = sum(1 for r in runs if reach(r, 9) < INF)
    won = sum(1 for r in runs if r["end_reason"] == "victory")
    hunts = med([float(r.get("attacks", 0)) / max(float(r["ended_at"]) / 60.0, 1.0) for r in runs])
    return "| %s (%d) | %s | %s | %d/%d | %d/%d | %d/%d | %d/%d | %.2f |" % (
        label, n, " | ".join(cells), ("%g" % med(deaths)), caught, n, lost, n, eagle, n, won, n, hunts)


def cadence_row(label, runs):
    catches = sum(int(r["catches"]) for r in runs)
    minutes = sum(float(r["ended_at"]) for r in runs) / 60.0
    early = []
    for r in runs:
        pig = min(reach(r, 5), float(r["ended_at"]))
        e = sum(1 for c in r.get("catch_log", []) if float(c[0]) <= pig)
        early.append(e / max(pig / 60.0, 1e-6))
    medgap = med([med(gaps(r)) / 60.0 for r in runs if gaps(r)])
    longest = [max(gaps(r)) / 60.0 for r in runs if gaps(r)]
    climb = [climb_longest(r) / 60.0 for r in runs]
    un = 0
    played = 0.0
    for r in runs:
        played += min(float(r["ended_at"]), 600.0)
        un += sum(1 for c in r.get("catch_log", []) if float(c[0]) < 600.0 and float(c[3]) <= 0.0)
    return "| %s | %.2f | %.2f | %.2f min | %.1f / %.1f min | %.1f min | %.2f |" % (
        label, catches / max(minutes, 1e-6), med(early), medgap, med(longest), med(climb), max(longest),
        un / max(played / 60.0, 1e-6))


def within(runs, t, lo, hi):
    return sum(1 for r in runs if lo * 60 <= reach(r, t) <= hi * 60)


def quartiles(runs, t):
    xs = sorted(reach(r, t) for r in runs)
    n = len(xs)
    return xs[n // 4], xs[(3 * n) // 4], xs[n // 10], xs[(9 * n) // 10]


def cue_sums(runs):
    t = {}
    tg = {}
    why = {}
    ph = []
    for r in runs:
        for k, v in r.get("cue", {}).items():
            if isinstance(v, (int, float)) and k != "masked_worst_gap":
                t[k] = t.get(k, 0.0) + v
        for k, v in r.get("target_cue", {}).items():
            if k == "why":
                for kk, vv in v.items():
                    why[kk] = why.get(kk, 0) + vv
            elif k == "preference_holds":
                ph += v
            elif isinstance(v, (int, float)):
                tg[k] = tg.get(k, 0.0) + v
    return t, tg, why, ph


def main():
    live = load("live_ai_evidence.json")
    quest = load("live_ai_quest_evidence.json")
    print("fingerprint", live.get("fingerprint"), "ai", live.get("ai_code"), "world", live.get("world_code"), "core", live.get("core_code"),
          "tuning", live.get("tuning"), "date", live.get("date"))
    print("quest fingerprint", quest.get("fingerprint"), "ai", quest.get("ai_code"), "tuning", quest.get("tuning"))
    sk = lambda src, b, s: src.get(b, {}).get(s, {}).get("runs", [])
    nov, com, exp = sk(live, "skills", "novice"), sk(live, "skills", "competent"), sk(live, "skills", "expert")
    hold = sk(live, "holdout", "competent")
    qt, qh = sk(quest, "skills", "competent"), sk(quest, "holdout", "competent")
    print()
    print("| | swallow | starling | pigeon | crow | gull | hawk | eagle | deaths / run (median) | caught at least once | runs lost | reached the eagle | apex won | hunts on the player / min |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for label, runs in [("novice", nov), ("competent, tuning seeds", com), ("**competent, held-out seeds**", hold),
                        ("**competent, all**", com + hold), ("expert", exp), ("**Quest tier: competent, tuning seeds**", qt),
                        ("**Quest tier: competent, held-out seeds**", qh), ("**Quest tier: competent, all**", qt + qh)]:
        if runs:
            print(row(label, runs))
    print()
    print("| | catches / min | early: catches / min to pigeon (median) | median gap between catches | longest dry spell, median: whole run / before the eagle | worst dry spell | unassisted catches / min, first 10 min |")
    print("|---|---|---|---|---|---|---|")
    for label, runs in [("novice", nov), ("competent (all)", com + hold), ("expert", exp), ("Quest tier, competent", qt + qh)]:
        if runs:
            print(cadence_row(label, runs))
    print()
    for label, runs in [("competent all", com + hold), ("quest all", qt + qh)]:
        if not runs:
            continue
        n = len(runs)
        q = quartiles(runs, 9)
        p = quartiles(runs, 5)
        print("%s: pigeon in 5-8 %d/%d, eagle in 20-30 %d/%d; middle half pigeon %s-%s eagle %s-%s; eagle p10-p90 %s-%s" % (
            label, within(runs, 5, 5, 8), n, within(runs, 9, 20, 30), n, mmss(p[0]), mmss(p[1]), mmss(q[0]), mmss(q[1]),
            mmss(q[2]), mmss(q[3])))
        deaths = [int(r["deaths"]) for r in runs]
        print("   mean deaths %.2f, earliest death %s" % (sum(deaths) / n,
              mmss(min([float(d) for r in runs for d in r.get("death_times", [])] or [INF]))))
    allv = nov + com + hold + exp + qt + qh
    for label, runs in [("valley all", allv), ("full tier", nov + com + hold + exp), ("quest", qt + qh)]:
        t, tg, why, ph = cue_sums(runs)
        minutes = sum(float(r["ended_at"]) for r in runs) / 60.0
        am = t.get("attack_s", 0) / 60.0
        print("%s: %d runs, %.0f play-min, %.1f attack-min; cue %s" % (label, len(runs), minutes, am,
              {k: round(v, 2) for k, v in t.items()}))
        print("   target per min: " + ", ".join("%s %.2f" % (k, v / minutes) for k, v in sorted(tg.items())) +
              "; preference hold median %.1f s; why %s" % (med(ph) if ph else float("nan"), dict(sorted(why.items()))))
    w = [r["cost_us"]["watch"] for r in allv if len(r.get("cost_us", {}).get("watch", [])) >= 3]
    c = [r["cost_us"]["catch"] for r in allv if len(r.get("cost_us", {}).get("catch", [])) >= 3]
    print("watch us: median of medians %.0f, p95 median %.0f, runs p95>300 %d, worst frame median %.0f max %.0f" % (
        med([x[0] for x in w]), med([x[1] for x in w]), sum(1 for x in w if x[1] > 300), med([x[2] for x in w]), max(x[2] for x in w)))
    print("catch us: median of medians %.0f, p95 median %.0f" % (med([x[0] for x in c]), med([x[1] for x in c])))
    hits = sum(int(r.get("world_hits", 0)) for r in allv)
    played = sum(float(r["ended_at"]) for r in allv)
    print("physical: hidden catches %d, world hits %d, stuck share %.4f, slow share %.3f, unpins %d" % (
        sum(int(r.get("hidden_catches", 0)) for r in allv), hits, sum(float(r.get("stuck_s", 0)) for r in allv) / played,
        sum(float(r.get("slow_s", 0)) for r in allv) / played, sum(int(r.get("unpins", 0)) for r in allv)))


if __name__ == "__main__":
    main()
