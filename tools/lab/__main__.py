"""Soaring LLM lab: archive agent logs, collect metrics and build the report.

    python3 tools/lab archive [RUN ...]   copy each run's agent logs into raw/<run>/ (kept out of git)
    python3 tools/lab collect [RUN ...]   archived logs, git and code -> runs/<run>/metrics.json and
                                          runs/<run>/human-messages.md
    python3 tools/lab media [RUN ...]     chosen screenshots and videos -> compact copies in runs/<run>/media/
    python3 tools/lab report              runs/* -> README.md leaderboard and report/index.html
    python3 tools/lab all [RUN ...]       archive, media, collect, then report
    python3 tools/lab new RUN             start runs/RUN/ from the template

RUN is a folder name under runs/; without one, every run is processed.
Startup captures and import checks of Godot builds: tools/capture_godot.sh RUN.
"""
import datetime as dt
import os
import re
import shutil
import sys

import codestats
import common
import logs
import media
import report


def collect(run_id):
    run = common.load_run(run_id)
    base = common.run_dir(run_id)
    pricing = common.load_json(os.path.join(common.EVAL, "pricing.json"))
    records = logs.load_records(run_id, run)
    phases = []
    if records:
        for m in sorted(run.get("milestones", []), key=lambda m: common.parse_ts(m["at"])):
            phases.append(dict(name=m["name"], until=m["at"], headline=bool(m.get("headline")),
                               **logs.summarize(records, pricing, common.parse_ts(m["at"]))))
        phases.append(dict(name="whole run", until=None, headline=False, **logs.summarize(records, pricing)))
        logs.write_human_messages(os.path.join(base, "human-messages.md"), run["title"], records)
    metrics = {
        "generated": common.iso(dt.datetime.now(dt.timezone.utc)),
        "pricing_as_of": pricing.get("as_of"),
        "logs": logs.describe(records, run),
        "phases": phases,
        "code": codestats.measure(run_id, run),
        "git": codestats.git_activity(run_id, run),
    }
    path = os.path.join(base, "metrics.json")
    previous = common.load_json(path, {})
    if {k: v for k, v in previous.items() if k != "generated"} != {k: v for k, v in metrics.items() if k != "generated"}:
        common.save_json(path, metrics)  # only on a real change, so git shows what moved
    total = phases[-1] if phases else None
    cost = f"${total['cost_usd']:,.2f}" if total and total["cost_usd"] is not None else "no logs"
    print(f"  {run_id}: {cost}, {metrics['code']['code']['game']['loc']:,} game LOC")


def new_run(args):
    if len(args) != 1:
        raise SystemExit("usage: python3 tools/lab new <yyyy-mm-dd>-<engine>-<model>")
    run_id = args[0]
    target = common.run_dir(run_id)
    if os.path.exists(target):
        raise SystemExit(f"{target} already exists")
    template = os.path.join(common.EVAL, "run-template")
    shutil.copytree(template, target)
    project = os.path.join(target, "project")
    os.makedirs(project)
    run = common.load_json(os.path.join(target, "run.json"))
    run["started"] = run_id[:10]
    # Where the agent tools will log a session started in project/: Claude Code names its folder
    # after the path with every other character replaced by "-"; Codex records the path itself.
    run["logs"]["claude_code_projects"] = [re.sub(r"[^A-Za-z0-9]", "-", project)]
    run["logs"]["codex_cwds"] = [project]
    common.save_json(os.path.join(target, "run.json"), run)
    print(f"created {os.path.relpath(target, common.ROOT)}: fill in run.json, then start the agent in project/")


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    if cmd == "new":
        return new_run(args)
    if cmd == "report":
        print(f"report: {report.build()} runs")
        return
    if cmd not in ("archive", "collect", "media", "all"):
        raise SystemExit(f"unknown command {cmd!r}; see python3 tools/lab --help")
    ids = common.run_ids(args)
    if cmd in ("archive", "all"):
        print("archive:")
        for run_id in ids:
            copied, found = logs.archive(run_id, common.load_run(run_id))
            if found:
                print(f"  {run_id}: {copied} of {found} log files copied")
    if cmd in ("media", "all"):
        print("media:")
        for run_id in ids:
            written = media.build(run_id, common.load_run(run_id))
            if written:
                print(f"  {run_id}: {written} files written")
    if cmd in ("collect", "all"):
        print("collect:")
        for run_id in ids:
            collect(run_id)
    if cmd == "all":
        print(f"report: {report.build()} runs")


if __name__ == "__main__":
    main(sys.argv[1:])
