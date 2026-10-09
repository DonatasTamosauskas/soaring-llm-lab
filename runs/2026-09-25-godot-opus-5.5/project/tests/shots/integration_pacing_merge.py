#!/usr/bin/env python3
"""Summarises batches of real-chain pacing runs (tests/shots/integration_pacing.sh)
and writes the stored evidence real_pacing_test reads.

    python3 tests/shots/integration_pacing_merge.py <batch dir> [<batch dir> ...]
        [--evidence=<out.json> --holdout=<batch>[,<batch>] --tuning=<batch>[,<batch>...]]

Per tier and skill ("full", "quest", "full:novice", ...): the median time to
each species (a run that never got there counts as later than every run
that did: the median is then INF if half never did), how many runs got
there, deaths, lost runs, catches a minute, the share of catches made
without the catch assist, and how chases ended.

With --evidence (core loop round: "tune on a declared set of tuning seeds,
evaluate once on fresh held-out seeds; record both sets in the evidence
file"): the runs of the --holdout batches are the evidence ("runs",
"summary"); the --tuning batches are summarised beside them ("tuning": their
batches, seeds and summary); and "seed_log" is every real-chain pacing run
ever logged - artifacts/integration/pacing/seed_log.tsv, which the batch
script appends to before each run starts, united with every part file
stored under artifacts/integration/pacing/ (runs started by hand) - so the
test can check that no held-out seed was run in any other batch.
"""
import glob
import json
import math
import os
import sys

SPECIES = ["moth", "wren", "sparrow", "swallow", "starling", "pigeon", "crow", "gull", "hawk", "eagle"]
PACING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "artifacts", "integration", "pacing")


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return None
    if n % 2:
        return xs[n // 2]
    a, b = xs[n // 2 - 1], xs[n // 2]
    if math.isinf(a) or math.isinf(b):
        return math.inf if math.isinf(a) else b if not math.isinf(b) else math.inf
    return 0.5 * (a + b)


def fmt(s):
    if s is None:
        return "-"
    if math.isinf(s):
        return "never"
    return "%d:%02d" % (int(s // 60), int(s % 60))


def tier_key(p):
    t = p["tier"] if p.get("npcs", 0) in (0, 60, 28) else "%s%d" % (p["tier"], p["npcs"])
    sk = p.get("skill", "competent")
    return t if sk == "competent" else "%s:%s" % (t, sk)


def reached(p):
    """Tier index -> time first reached it OR anything bigger (a meal can
    skip a tier; a death can drop back into one)."""
    ta = {int(k): float(v) for k, v in p["tier_at"].items()}
    best = math.inf
    out = {}
    for i in range(len(SPECIES) - 1, -1, -1):
        if i in ta:
            best = min(best, ta[i])
        if not math.isinf(best):
            out[i] = best
    return out


def summarize(parts):
    out = {}
    for key in sorted(set(tier_key(p) for p in parts)):
        runs = [p for p in parts if tier_key(p) == key]
        row = {"runs": len(runs), "seeds": sorted(p["seed"] for p in runs), "codes": sorted(set(p["code"] for p in runs)),
               "growth": sorted(set(tuple(p["growth"]) for p in runs)), "minutes": sorted(set(p["minutes"] for p in runs))}
        for i, sp in enumerate(SPECIES):
            if i < 3:
                continue
            ts = [reached(p).get(i, math.inf) for p in runs]
            row[sp] = {"median_s": median(ts), "reached": sum(1 for x in ts if not math.isinf(x)),
                       "times_s": [x if not math.isinf(x) else None for x in ts]}
        deaths = [len(p["deaths"]) for p in runs]
        mins = [p["ended_at"] / 60.0 for p in runs]
        catches = [len(p["catches"]) for p in runs]
        row["deaths_median"] = median(deaths)
        row["deaths_mean"] = sum(deaths) / max(len(deaths), 1)
        row["caught_at_least_once"] = sum(1 for d in deaths if d > 0)
        row["lost"] = sum(1 for p in runs if p["end_reason"] == "lost")
        row["victory"] = sum(1 for p in runs if p["end_reason"] == "victory")
        row["catches_per_min"] = sum(catches) / max(sum(mins), 1e-6)
        allc = [c for p in runs for c in p["catches"]]
        row["unassisted_share"] = sum(1 for c in allc if c["assist"] <= 0.0) / max(len(allc), 1)
        # Early growth: the catches made as a sparrow-sized player (under the
        # swallow's mass) that were moths (the pellets: the swarms' and the
        # sky's own).
        early = [c for c in allc if c["g"] < 55.0]
        row["early_catches"] = len(early)
        row["early_pellet_share"] = sum(1 for c in early if c.get("prey") == "moth") / max(len(early), 1)
        row["early_swarm_share"] = sum(1 for c in early if c.get("swarm")) / max(len(early), 1)
        ends = {}
        for p in runs:
            for k, v in p["person"]["chase_ends"].items():
                ends[k] = ends.get(k, 0) + v
        row["chase_ends"] = ends
        killers = {}
        for p in runs:
            for d in p["deaths"]:
                killers[d["by"]] = killers.get(d["by"], 0) + 1
        row["killers"] = killers
        cue = {}
        for p in runs:
            for k, v in p.get("cue", {}).items():
                cue[k] = cue.get(k, 0) + v
        row["cue"] = cue
        row["cue_changes_per_min"] = cue.get("changes", 0) / max(sum(mins), 1e-6)
        # Deaths soon after the first tier-up (the first celebrated moment).
        soon = 0
        firsts = 0
        for p in runs:
            t1 = reached(p).get(3)
            if t1 is None:
                continue
            firsts += 1
            if any(0.0 <= d["t"] - float(t1) <= 30.0 for d in p["deaths"]):
                soon += 1
        row["first_tier_ups"] = firsts
        row["deaths_within_30s_of_first_tier_up"] = soon
        row["first_tier_up_median_s"] = median([reached(p).get(3, math.inf) for p in runs])
        # The danger director: the first attack, and attacks a minute over
        # the first ten minutes after it.
        firsts_att = [p["attack_times"][0] if p.get("attack_times") else math.inf for p in runs]
        row["first_attack_median_s"] = median(firsts_att)
        # The first time anything set off after the player (a bird hunting it).
        row["first_hunt_median_s"] = median([p.get("first_hunt_t", -1.0) if p.get("first_hunt_t", -1.0) >= 0.0 else math.inf for p in runs])
        early_rate = []
        for p in runs:
            at = p.get("attack_times", [])
            if not at:
                early_rate.append(0.0)
                continue
            win = [x for x in at if x <= at[0] + 600.0]
            early_rate.append(len(win) / 10.0)
        row["attacks_per_min_first_10"] = median(early_rate)
        row["attacks_per_run_median"] = median([p.get("attacks", 0) for p in runs])
        marks = {}
        for p in runs:
            for k, v in p.get("danger_marks", {}).items():
                marks[k] = marks.get(k, 0) + v
        row["danger_marks"] = marks
        row["npc_catches_seen_median"] = median([len(p.get("npc_catches_seen", [])) for p in runs])
        ct = {}
        for p in runs:
            for k, v in p.get("cue_track", {}).items():
                if isinstance(v, (int, float)):
                    ct[k] = ct.get(k, 0) + v
        row["cue_track"] = ct
        tcue = {}
        for p in runs:
            for k, v in p.get("target_cue", {}).items():
                if isinstance(v, (int, float)) and k != "hold_median_s":
                    tcue[k] = tcue.get(k, 0) + v
        # The ring's churn as the player meets it (core loop fix round 1: the
        # same bars as mechanics_test's modelled runs, now on the real chain):
        # changes a minute away from a still-valid bird, away from one the
        # player was gaining on, and the pooled median hold before such a change.
        tcue["voluntary_per_min"] = tcue.get("voluntary", 0) / max(sum(mins), 1e-6)
        tcue["voluntary_closing_per_min"] = tcue.get("voluntary_closing", 0) / max(sum(mins), 1e-6)
        tcue["preference_per_min"] = tcue.get("preference", 0) / max(sum(mins), 1e-6)
        holds = sorted(h for p in runs for h in p.get("target_cue", {}).get("holds", []))
        tcue["hold_median_s"] = holds[len(holds) // 2] if holds else None
        row["target_cue"] = tcue
        # Tier-ups less than 30 s after the one before (first reaches; the
        # "murmuration buffet" of the core loop round's held-out runs: Quest
        # 405 went sparrow -> crow in 54 s). GameLoop.TIER_SETTLE_S.
        fast = 0
        for p in runs:
            ts = sorted(float(v) for k, v in p.get("tier_at", {}).items() if float(v) > 0.0)
            fast += sum(1 for a, b in zip(ts, ts[1:]) if b - a < 30.0)
        row["tier_ups_within_30s"] = fast
        row["errors"] = sum(p["errors"] for p in runs)
        row["wall_s_median"] = median([p["wall_s"] for p in runs])
        row["unsticks"] = sum(p["person"].get("unsticks", 0) for p in runs)
        row["evading_share"] = sum(p["person"].get("evading_s", 0.0) for p in runs) / max(sum(mins) * 60.0, 1e-6)
        out[key] = row
    return out


def clean(x):
    """JSON without Infinity (Godot's parser refuses it): a median never reached is null."""
    if isinstance(x, float) and (math.isinf(x) or math.isnan(x)):
        return None
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [clean(v) for v in x]
    return x


def compact(p):
    """A run as the evidence keeps it (its per-minute rows and the target
    cue's hold lists left out)."""
    q = {k: v for k, v in p.items() if k not in ("rows",)}
    tc = dict(q.get("target_cue", {}))
    for k in ("holds", "preference_holds"):
        tc.pop(k, None)
    q["target_cue"] = tc
    return q


def load_parts(d):
    out = []
    for f in sorted(glob.glob(os.path.join(d, "part_*.json"))):
        with open(f) as fh:
            p = json.load(fh)
        p["batch_dir"] = os.path.basename(os.path.normpath(d))
        out.append(p)
    return out


def seed_log():
    """Every real-chain pacing run ever logged: the batch script's log plus
    every part file stored (date, batch, tier, seed, skill)."""
    rows = set()
    path = os.path.join(PACING, "seed_log.tsv")
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                f = line.rstrip("\n").split("\t")
                if len(f) < 4:
                    continue
                extra = f[4] if len(f) > 4 else ""
                skill = "competent"
                for a in extra.split():
                    if a.startswith("--skill="):
                        skill = a.split("=", 1)[1]
                # (A mistyped launch logged "full,quest" / "101,102,..." as one
                # job - cl_it7: every seed and tier it named counts as used.)
                for tier in f[2].split(","):
                    for sd in f[3].split(","):
                        rows.add((f[0][:10], f[1], tier, int(sd), skill))
    for fpath in glob.glob(os.path.join(PACING, "*", "part_*.json")):
        try:
            with open(fpath) as fh:
                p = json.load(fh)
        except (OSError, ValueError):
            continue
        rows.add((str(p.get("date", "?"))[:10], os.path.basename(os.path.dirname(fpath)), p.get("tier", "?"),
                  int(p.get("seed", -1)), p.get("skill", "competent")))
    return sorted(rows, key=lambda r: (r[1], r[2], r[3], r[4], r[0]))


def main():
    dirs = []
    ev = None
    holdout = []
    tuning = []
    for a in sys.argv[1:]:
        if a.startswith("--evidence="):
            ev = a.split("=", 1)[1]
        elif a.startswith("--holdout="):
            holdout = [x for x in a.split("=", 1)[1].split(",") if x]
        elif a.startswith("--tuning="):
            tuning = [x for x in a.split("=", 1)[1].split(",") if x]
        else:
            dirs.append(a)
    parts = []
    for d in dirs:
        parts += load_parts(d)
    summ = summarize(parts)
    if dirs:
        with open(os.path.join(dirs[0], "summary.json"), "w") as fh:
            json.dump(clean(summ), fh, indent=1)
    for tier, row in summ.items():
        print("[integration] %s: %d runs (seeds %s), growth %s, code %s" % (tier, row["runs"], row["seeds"], row["growth"], row["codes"]))
        print("  median to: " + ", ".join("%s %s (%d/%d)" % (sp, fmt(row[sp]["median_s"]), row[sp]["reached"], row["runs"])
                                          for sp in SPECIES[3:]))
        print("  deaths median %s mean %.2f, caught >=1: %d, lost %d, victory %d, catches/min %.2f, unassisted %.0f%%, errors %d, wall %s s, unsticks %d" % (
            row["deaths_median"], row["deaths_mean"], row["caught_at_least_once"], row["lost"], row["victory"],
            row["catches_per_min"], 100 * row["unassisted_share"], row["errors"], row["wall_s_median"], row["unsticks"]))
        print("  early catches %d, pellets %.0f%%; first tier-up %s; first hunt %s, first attack %s, attacks/min (first 10) %s, per run %s; evading %.0f%%; NPC catches seen %s" % (
            row["early_catches"], 100 * row["early_pellet_share"], fmt(row["first_tier_up_median_s"]), fmt(row["first_hunt_median_s"]), fmt(row["first_attack_median_s"]),
            row["attacks_per_min_first_10"], row["attacks_per_run_median"], 100 * row["evading_share"], row["npc_catches_seen_median"]))
        print("  chase ends %s; killers %s; marks %s" % (row["chase_ends"], row["killers"], row["danger_marks"]))
        print("  cue changes %.1f/min %s; deaths within 30 s of the first tier-up: %d of %d" % (
            row["cue_changes_per_min"], row["cue"], row["deaths_within_30s_of_first_tier_up"], row["first_tier_ups"]))
    if ev:
        hold_parts = [p for p in parts if p["batch_dir"] in holdout] if holdout else parts
        tune_parts = []
        for b in tuning:
            tune_parts += load_parts(os.path.join(PACING, b))
        out = {"summary": summarize(hold_parts), "runs": [compact(p) for p in hold_parts],
               "holdout": {"batches": holdout, "seeds": sorted(set(p["seed"] for p in hold_parts))},
               "tuning": {"batches": tuning, "seeds": sorted(set(p["seed"] for p in tune_parts)),
                          "summary": summarize(tune_parts) if tune_parts else {}},
               "seed_log": [list(r) for r in seed_log()]}
        if os.path.dirname(ev):
            os.makedirs(os.path.dirname(ev), exist_ok=True)
        with open(ev, "w") as fh:
            json.dump(clean(out), fh, indent=None, separators=(",", ":"))


if __name__ == "__main__":
    main()
