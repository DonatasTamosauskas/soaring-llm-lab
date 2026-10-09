"""Agent logs: archive them out of the agent tools' own folders, then turn them into token usage,
cost, time and human-message records.

Claude Code keeps one transcript per main session in ~/.claude/projects/<project>/<session>.jsonl,
and its subagents' and workflow agents' transcripts in folders below it. It deletes transcripts
30 days after their last write unless cleanupPeriodDays says otherwise, so archive early.
Codex keeps one file per thread in ~/.codex/{sessions,archived_sessions}/; subagent and
auto-review threads are separate files. A run is matched to its Codex threads by working directory.
"""
import glob
import json
import os
import shutil
from collections import defaultdict

import common

CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")
CODEX_DIRS = [os.path.expanduser("~/.codex/sessions"), os.path.expanduser("~/.codex/archived_sessions")]
ACTIVE_GAP_S = 600  # a pause longer than this between two events of one thread counts as idle

# Token fields every tool's usage is normalised to. "input" excludes cache reads and writes;
# "reasoning" is the part of "output" spent on reasoning (Codex reports it, Claude Code does not).
FIELDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output", "reasoning")
BILLED = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")

# Lines Claude Code writes as "user" entries that are not the human typing (older versions have no
# origin field to say so).
_NOT_HUMAN = ("<command-name>", "<command-message>", "<local-command-stdout>", "<local-command-stderr>",
              "<task-notification>", "<system-reminder>", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
              "Caveat: The messages below were generated")
# User-role entries the Codex app adds itself. A message typed with the in-app browser open carries
# that browser's state first; the typed text follows the closing tag.
_CODEX_INJECTED = ("<environment_context", "<external_codex_apps_open_page", "<user_instructions", "# AGENTS.md",
                   "<turn_aborted", "<user_shell_command", "<subagent_notification")
_BROWSER_CONTEXT_END = "</in-app-browser-context>"


class Record:
    """What one agent tool's logs for a run add up to."""

    def __init__(self, tool):
        self.tool = tool
        self.usage = []        # (time, model, {field: tokens}) per API call or turn
        self.activity = []     # one sorted list of event times per thread
        self.humans = []       # (time, text)
        self.interrupts = []   # times the human stopped the agent mid-turn
        self.settings = []     # (time, text) harness settings changed during the run
        self.versions = set()
        self.efforts = set()
        self.sessions = set()
        self.threads = defaultdict(int)  # "main" / "agent" -> count


def _jsonl(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


# --- archive -------------------------------------------------------------------------------

def _copy_if_changed(src, dst):
    if os.path.exists(dst):
        s, d = os.stat(src), os.stat(dst)
        if s.st_size == d.st_size and int(s.st_mtime) <= int(d.st_mtime):
            return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    return True


def _codex_cwd(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        first = f.readline()
    try:
        o = json.loads(first)
    except ValueError:
        return None
    return (o.get("payload") or {}).get("cwd") if o.get("type") == "session_meta" else None


def archive(run_id, run):
    """Copy the run's logs into raw/<run>/, new and changed files only. Returns (copied, found)."""
    spec = run.get("logs", {})
    dst_root = os.path.join(common.RAW, run_id)
    copied = found = 0
    for project in spec.get("claude_code_projects", []):
        src_root = os.path.join(CLAUDE_PROJECTS, project)
        for src in glob.glob(os.path.join(src_root, "**", "*"), recursive=True):
            if os.path.isfile(src):
                found += 1
                copied += _copy_if_changed(src, os.path.join(dst_root, "claude", project, os.path.relpath(src, src_root)))
    cwds = set(spec.get("codex_cwds", []))
    if cwds:
        for base in CODEX_DIRS:
            for src in glob.glob(os.path.join(base, "**", "*.jsonl"), recursive=True):
                if _codex_cwd(src) in cwds:
                    found += 1
                    copied += _copy_if_changed(src, os.path.join(dst_root, "codex", os.path.basename(src)))
    return copied, found


# --- parse ---------------------------------------------------------------------------------

def _claude_text(content):
    """Text of a user entry, or None when it carries tool results (the agent's own loop)."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return None
    return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")


def parse_claude(project_dir):
    rec = Record("Claude Code")
    calls = {}
    for path in sorted(glob.glob(os.path.join(project_dir, "**", "*.jsonl"), recursive=True)):
        is_main = os.sep not in os.path.relpath(path, project_dir)
        stamps = []
        for o in _jsonl(path):
            if not o.get("timestamp"):
                continue
            t = common.parse_ts(o["timestamp"])
            stamps.append(t)
            if o.get("version"):
                rec.versions.add(o["version"])
            if is_main and o.get("sessionId"):
                rec.sessions.add(o["sessionId"])
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            if o.get("type") == "assistant" and "usage" in msg and msg.get("model") != "<synthetic>":
                # One API response is logged once per content block, with usage filled in as it
                # streams: keep the largest value of each field.
                u = msg["usage"]
                split = u.get("cache_creation") or {}
                w1h = split.get("ephemeral_1h_input_tokens") or 0
                vals = {"input": u.get("input_tokens") or 0,
                        "cache_write_5m": (u.get("cache_creation_input_tokens") or 0) - w1h,
                        "cache_write_1h": w1h,
                        "cache_read": u.get("cache_read_input_tokens") or 0,
                        "output": u.get("output_tokens") or 0,
                        "reasoning": 0}
                key = (msg.get("id"), o.get("requestId"))
                if key in calls:
                    kept = calls[key][2]
                    for k, v in vals.items():
                        kept[k] = max(kept[k], v)
                else:
                    calls[key] = (t, msg.get("model") or "?", vals)
            elif o.get("type") == "user" and is_main and not o.get("isMeta") and not o.get("isSidechain"):
                text = _claude_text(msg.get("content"))
                if text is None:
                    continue
                text = text.strip()
                if text.startswith("<local-command-stdout>Set "):
                    rec.settings.append((t, text[len("<local-command-stdout>"):].split("</local-command-stdout>")[0]))
                    continue
                if text.startswith("[Request interrupted"):
                    rec.interrupts.append(t)
                    continue
                origin = (o.get("origin") or {}).get("kind")
                human = origin == "human" if origin else bool(text) and not text.startswith(_NOT_HUMAN)
                if human:
                    rec.humans.append((t, text))
        rec.activity.append(sorted(stamps))
        rec.threads["main" if is_main else "agent"] += 1
    rec.usage = list(calls.values())
    return rec


def _codex_typed(payload):
    """What the human typed in a user-role response item, or "" for entries the app injected."""
    text = " ".join(x.get("text", "") for x in payload.get("content", []) if isinstance(x, dict)).strip()
    if _BROWSER_CONTEXT_END in text:
        text = text.split(_BROWSER_CONTEXT_END, 1)[1].strip()
        if text.startswith("## My request:"):
            text = text[len("## My request:"):].strip()
    return "" if text.startswith(_CODEX_INJECTED) else text


def parse_codex(paths):
    rec = Record("Codex")
    for path in sorted(paths):
        meta, model, previous, stamps, models, interrupts, usage = None, None, {}, [], set(), [], []
        efforts = set()
        typed, events = [], []  # user messages from response items / from user_message events (CLI)
        own_from = 0  # a forked subagent's file starts with a copy of its parent's history
        for o in _jsonl(path):
            p = o.get("payload") or {}
            if meta is None and o.get("type") == "session_meta":
                meta = p
                own_from = p.get("subagent_history_start_ordinal") or 0
                if p.get("cli_version"):
                    rec.versions.add(p["cli_version"])
                continue
            if not o.get("timestamp") or (o.get("ordinal") or 0) < own_from:
                continue
            t = common.parse_ts(o["timestamp"])
            stamps.append(t)
            if o.get("type") == "turn_context":
                model = p.get("model") or model
                models.add(model)
                effort = p.get("effort") or p.get("reasoning_effort")
                if effort:
                    efforts.add(str(effort))
            elif o.get("type") == "event_msg" and p.get("type") == "token_count" and p.get("info"):
                total = p["info"].get("total_token_usage") or {}
                delta = {k: v - previous.get(k, 0) for k, v in total.items()}
                if any(v < 0 for v in delta.values()):  # counter restarted
                    delta = dict(total)
                previous = total
                cached = delta.get("cached_input_tokens", 0)
                written = delta.get("cache_write_input_tokens", 0)
                # Codex counts cached and cache-write tokens inside input_tokens.
                usage.append((t, model or "?", {"input": max(0, delta.get("input_tokens", 0) - cached - written),
                                                "cache_write_5m": written, "cache_write_1h": 0,
                                                "cache_read": cached,
                                                "output": delta.get("output_tokens", 0),
                                                "reasoning": delta.get("reasoning_output_tokens", 0)}))
            elif o.get("type") == "response_item" and p.get("type") == "message" and p.get("role") == "user":
                text = _codex_typed(p)
                if text:
                    typed.append((t, text))
            elif o.get("type") == "event_msg" and p.get("type") == "user_message":
                text = (p.get("message") or "").strip()
                if text:
                    events.append((t, text))
            elif o.get("type") == "event_msg" and p.get("type") == "turn_aborted":
                interrupts.append(t)
        meta = meta or {}
        automated = bool(meta.get("parent_thread_id")) or (models and all(m == "codex-auto-review" for m in models))
        if not automated:  # the effort you chose; review threads run at their own
            rec.efforts |= efforts
            rec.humans += events or typed  # the CLI logs both forms of the same message
            rec.interrupts += interrupts
            rec.sessions.add(meta.get("id") or path)
        rec.threads["agent" if automated else "main"] += 1
        rec.activity.append(sorted(stamps))
        rec.usage += usage
    return rec


def load_records(run_id, run):
    """Records from the archived logs in raw/<run>/ (empty when nothing was archived)."""
    records = []
    root = os.path.join(common.RAW, run_id)
    for project in run.get("logs", {}).get("claude_code_projects", []):
        d = os.path.join(root, "claude", project)
        if os.path.isdir(d):
            records.append(parse_claude(d))
    codex = glob.glob(os.path.join(root, "codex", "*.jsonl"))
    if codex:
        records.append(parse_codex(codex))
    return records


# --- summarise -----------------------------------------------------------------------------

def price_for(pricing, model):
    entry = pricing["models"].get(model)
    while entry and "same_as" in entry:
        entry = pricing["models"].get(entry["same_as"])
    return entry


def _intervals(stamps, until):
    out = []
    for t in stamps:
        if until and t > until:
            break
        if out and (t - out[-1][1]).total_seconds() <= ACTIVE_GAP_S:
            out[-1][1] = t
        else:
            out.append([t, t])
    return out


def _hours(seconds):
    return round(seconds / 3600, 2)


def summarize(records, pricing, until=None):
    """Usage, cost, time and human involvement of a run, up to `until` (aware datetime) if given."""
    tokens = defaultdict(lambda: dict.fromkeys(FIELDS, 0))
    calls = 0
    for rec in records:
        for t, model, fields in rec.usage:
            if (until and t > until) or not any(fields.values()):
                continue
            calls += 1
            for k in FIELDS:
                tokens[model][k] += fields.get(k, 0)
    cost_by_model, unpriced = {}, []
    for model, counts in tokens.items():
        price = price_for(pricing, model)
        if price is None:
            unpriced.append(model)
        else:
            cost_by_model[model] = round(sum(counts[k] * price.get(k, 0) for k in BILLED) / 1e6, 2)

    per_thread = [_intervals(s, until) for rec in records for s in rec.activity]
    agent_s = sum((b - a).total_seconds() for iv in per_thread for a, b in iv)
    merged = []
    for a, b in sorted(i for iv in per_thread for i in iv):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    active_s = sum((b - a).total_seconds() for a, b in merged)
    stamps = [t for rec in records for s in rec.activity for t in s if not until or t <= until]

    def upto(items):
        return [x for x in items if not until or (x[0] if isinstance(x, tuple) else x) <= until]

    return {
        "api_calls": calls,
        "tokens_by_model": dict(tokens),
        "tokens": {k: sum(c[k] for c in tokens.values()) for k in FIELDS},
        "cost_usd": round(sum(cost_by_model.values()), 2) if tokens else None,
        "cost_by_model": cost_by_model,
        "unpriced_models": unpriced,
        "time": {
            "first_event": common.iso(min(stamps)) if stamps else None,
            "last_event": common.iso(max(stamps)) if stamps else None,
            "wall_clock_h": _hours((max(stamps) - min(stamps)).total_seconds()) if stamps else None,
            "active_h": _hours(active_s),
            "agent_h": _hours(agent_s),
            "parallelism": round(agent_s / active_s, 2) if active_s else None,
        },
        "human_messages": len(upto([h for rec in records for h in rec.humans])),
        "interrupts": len(upto([t for rec in records for t in rec.interrupts])),
    }


def describe(records, run):
    spec = run.get("logs", {})
    return {
        "coverage": spec.get("coverage", "none"),
        "note": spec.get("note"),
        "tools": sorted({r.tool for r in records}),
        "versions": sorted({v for r in records for v in r.versions}),
        "efforts": sorted({e for r in records for e in r.efforts}),
        "settings": [{"at": common.iso(t), "text": s} for r in records for t, s in sorted(r.settings)],
        "sessions": sum(len(r.sessions) for r in records),
        "threads": {k: sum(r.threads[k] for r in records) for k in ("main", "agent")},
    }


def write_human_messages(path, title, records):
    humans = sorted(h for r in records for h in r.humans)
    settings = sorted(s for r in records for s in r.settings)
    interrupts = sum(len(r.interrupts) for r in records)
    lines = [f"# Your messages: {title}", "",
             f"Generated by `tools/lab collect` from the archived agent logs: {len(humans)} messages typed "
             f"by you and {interrupts} interrupts. Prompts between agents, tool output and notifications "
             "are left out.", ""]
    if settings:
        lines += ["## Settings changed during the run", ""]
        lines += [f"- {common.local(t):%Y-%m-%d %H:%M} · {text}" for t, text in settings]
        lines.append("")
    for n, (t, text) in enumerate(humans, 1):
        fence = "~~~~"
        while fence in text:
            fence += "~"
        lines += [f"## {n} · {common.local(t):%a %d %b %Y, %H:%M}", "", fence + "text", text, fence, ""]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
