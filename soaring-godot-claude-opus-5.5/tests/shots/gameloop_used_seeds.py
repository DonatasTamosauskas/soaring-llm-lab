#!/usr/bin/env python3
"""Every seed any stored game-loop run used, by batch: the committed list
scripts/game/data/used_seeds.json that pacing_test checks the held-out seeds
against ("the held-out seeds were never run before their evaluation").

Scans artifacts/gameloop/ recursively (tuning batches, earlier evidence parts,
the verifiers' probe outputs, diagnostics) for runs - objects with a "seed" and
"tier_at"/"catches"/"deaths" - and merges in `extra` (batches whose runs were
not stored, e.g. diagnostics). The held-out evidence of the current round (the
top level's integrated_live_part_ev_hold_*.json and the merged integrated_live.json)
is left out: it is what the list is checked against (fix round 5: the
top-level integrated_live_part_hold_* and _qhold_* parts and the merged
integrated_live.json / integrated_live_quest.json).

    python3 tests/shots/gameloop_used_seeds.py > scripts/game/data/used_seeds.json
"""
import collections
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
ART = os.path.join(ROOT, "artifacts", "gameloop")
# Runs that left no file behind (round 4 diagnostics: tests/shots/gameloop_cue_diag_test.gd).
EXTRA = {"r4_diagnostics (cue naming, valley, 2 x 10 min)": {"competent": [990, 991]}}
# (Fix round 5: the full tier's held-out parts are hold_*, the Quest tier's
# qhold_*; round 4's ev_hold_* now live in r4_evidence_parts/ and count as
# used.)
SKIP_TOP = ("integrated_live_part_hold_", "integrated_live_part_qhold_", "integrated_live.json",
            "integrated_live_quest.json")


def scan(obj, batch, prov, hint=None):
    if isinstance(obj, dict):
        if isinstance(obj.get("seed"), (int, float)) and ("tier_at" in obj or "catches" in obj or "deaths" in obj):
            prov[batch][str(obj.get("skill", hint) or "any")].add(int(obj["seed"]))
        for k, v in obj.items():
            scan(v, batch, prov, k if k in ("novice", "competent", "expert") else hint)
    elif isinstance(obj, list):
        for v in obj:
            scan(v, batch, prov, hint)


def main():
    prov = collections.defaultdict(lambda: collections.defaultdict(set))
    for dp, _dn, fn in os.walk(ART):
        for f in sorted(fn):
            if not f.endswith(".json") or f == "open_findings_b1.json":
                continue
            rel = os.path.relpath(os.path.join(dp, f), ART)
            if os.path.dirname(rel) == "" and f.startswith(SKIP_TOP):
                continue
            # (Files at the top level: the current evidence's tuning-set parts and merges.)
            batch = os.path.dirname(rel) or "current evidence (top level; held-out parts excluded)"
            try:
                with open(os.path.join(dp, f)) as fh:
                    scan(json.load(fh), batch, prov)
            except (ValueError, OSError):
                pass
    for b, v in EXTRA.items():
        for sk, seeds in v.items():
            prov[b][sk].update(seeds)
    batches = {b: {sk: sorted(prov[b][sk]) for sk in sorted(prov[b])} for b in sorted(prov)}
    used = sorted({s for b in prov.values() for v in b.values() for s in v})
    json.dump({"about": "Every seed a stored game-loop run used before the current held-out evaluation, "
               "by batch (tests/shots/gameloop_used_seeds.py). pacing_test: the held-out seeds are in none of them.",
               "batches": batches, "used": used}, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
