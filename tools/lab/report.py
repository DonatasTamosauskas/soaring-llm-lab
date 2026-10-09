"""The leaderboard in README.md (between its markers) and the full report in report/index.html."""
import datetime as dt
import glob
import html
import os
import re
import shutil

import common
import media

README = os.path.join(common.ROOT, "README.md")
REPORT = os.path.join(common.ROOT, "report", "index.html")
START, END = "<!-- leaderboard:start -->", "<!-- leaderboard:end -->"


# --- formatting ----------------------------------------------------------------------------

def usd(x, partial=False):
    if x is None:
        return "—"
    s = f"${x:,.0f}" if x >= 100 else f"${x:,.2f}"
    return ("≥ " if partial else "") + s


def count(n):
    if n is None:
        return "—"
    for unit, size in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if n >= size:
            return f"{n / size:.1f}{unit}".replace(".0" + unit, unit)
    return str(n)


def hours(h):
    if h is None:
        return "—"
    return f"{h * 60:.0f} min" if h < 1 else f"{h:.1f} h"


def size(b):
    return f"{b / 1048576:.1f} MB" if b >= 1048576 else f"{b / 1024:.0f} KB"


def esc(s):
    return html.escape(str(s), quote=True)


class Links:
    """Where the report points: media next to the page (under media_prefix), source files on GitHub,
    which renders them, or relative to report/ when the repo is not on GitHub."""

    def __init__(self, media_prefix):
        self.media_prefix = media_prefix
        self.repo = common.repo_url()

    def media(self, run_id, path):
        return f"{self.media_prefix}runs/{run_id}/{path}"

    def source(self, path, folder=False):
        if self.repo:
            return f"{self.repo}/{'tree' if folder else 'blob'}/main/{path}"
        return f"../{path}" + ("/" if folder else "")


# --- data ----------------------------------------------------------------------------------

def load_all():
    rows = []
    for run_id in common.run_ids():
        base = common.run_dir(run_id)
        run = common.load_run(run_id)
        metrics = common.load_json(os.path.join(base, "metrics.json"), {})
        checks = common.load_json(os.path.join(base, "checks.json"), {})
        rows.append(row(run_id, run, metrics, checks))
    return rows


def row(run_id, run, metrics, checks):
    phases = metrics.get("phases") or []
    # Runs are compared at the milestone marked "headline" in run.json (v1 delivered), else whole.
    total = next((p for p in phases if p.get("headline")), phases[-1] if phases else None)
    coverage = (metrics.get("logs") or {}).get("coverage", run.get("logs", {}).get("coverage", "none"))
    code = metrics.get("code") or {}
    git = metrics.get("git") or {}
    tokens = (total or {}).get("tokens") or {}
    processed = sum(tokens.get(k, 0) for k in ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output"))
    time = (total or {}).get("time") or {}
    active = time.get("active_h") if total else None
    langs = code.get("loc_by_language") or {}
    main_lang = max(langs, key=langs.get) if langs else None
    return {
        "id": run_id, "run": run, "metrics": metrics, "checks": checks, "phases": phases, "total": total,
        "upto": total["name"] if total else None,
        "coverage": coverage,
        "cost": total.get("cost_usd") if total else None,
        "processed": processed if total else None,
        "output": tokens.get("output") if total else None,
        "active_h": active,
        "agent_h": time.get("agent_h") if total else None,
        "git_span_h": git.get("span_h") if git.get("commits", 0) > 1 else None,
        "humans": total.get("human_messages") if total else None,
        "interrupts": total.get("interrupts") if total else None,
        "game_loc": (code.get("code") or {}).get("game", {}).get("loc"),
        "main_lang": main_lang,
        "test_loc": (code.get("code") or {}).get("test", {}).get("loc"),
        "docs": (code.get("docs") or {}).get("lines"),
    }


def gallery(r):
    """[(file relative to the run folder, caption, kind)] for a run: chosen media, then captures."""
    items = []
    base = common.run_dir(r["id"])
    for m in r["run"].get("media", []):
        path = os.path.join("media", m["file"])
        if os.path.exists(os.path.join(base, path)):
            items.append((path, m.get("caption", ""), "video" if path.endswith(".mp4") else "image"))
    for c in (r["checks"].get("captures") or []):
        if os.path.exists(os.path.join(base, c["file"])):
            items.append((c["file"], c.get("caption", ""), "video" if c["file"].endswith(".mp4") else "image"))
    return items


def cost_text(r):
    if r["coverage"] == "none":
        return "— (no logs)"
    return usd(r["cost"], partial=r["coverage"] == "partial")


def time_text(r):
    if r["active_h"] is not None:
        return hours(r["active_h"])
    if r["git_span_h"] is not None:
        return f"≈ {hours(r['git_span_h'])} (commits)"
    return "—"


def harness_text(run):
    h = run["harness"]
    if h["name"] == "unknown":
        return "agent tool unknown"
    return h["name"] + (f" · {h['mode']}" if h.get("mode") and h["mode"] != "unknown" else "")


def plural(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def check_text(checks):
    imp = checks.get("import")
    if not imp:
        return "—"
    text = "imports cleanly" if imp.get("ok") else f"{imp.get('errors', '?')} script errors on import"
    startup = checks.get("startup") or {}
    return text + (" · starts" if startup.get("frames") else " · no desktop view")


# --- README --------------------------------------------------------------------------------

def leaderboard_md(rows):
    lines = ["| Run | Model · agent tool | Engine | Measured up to | Est. API cost | Tokens (output) | Active time "
             "| Your messages | Game code | Test code | Docs | Check |",
             "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|"]
    for r in rows:
        run = r["run"]
        tokens = f"{count(r['processed'])} ({count(r['output'])})" if r["processed"] else "—"
        humans = "—" if r["humans"] is None else f"{r['humans']}" + (f" (+{r['interrupts']} stops)" if r["interrupts"] else "")
        game = f"{count(r['game_loc'])} {r['main_lang']}" if r["game_loc"] else "—"
        tests = count(r["test_loc"]) if r["test_loc"] else "—"
        lines.append(" | ".join([
            f"| [{run['title']}](runs/{r['id']}/)",
            f"{run['model']['name']} · {run['harness']['name']}",
            f"{run['engine']['name']} {run['engine'].get('version', '')}".strip(),
            r["upto"] or "—", cost_text(r), tokens, time_text(r), humans, game, tests,
            count(r["docs"]) if r["docs"] else "—",
            check_text(r["checks"]) + " |",
        ]))
    return "\n".join(lines)


def write_readme(rows):
    with open(README, encoding="utf-8") as f:
        text = f.read()
    stamp = f"_Generated by `python3 tools/lab report` from metrics collected up to {latest_metrics(rows)}. Column definitions: [eval/METHOD.md](eval/METHOD.md)._"
    block = f"{START}\n{leaderboard_md(rows)}\n\n{stamp}\n{END}"
    text = re.sub(re.escape(START) + ".*?" + re.escape(END), lambda m: block, text, flags=re.S)
    with open(README, "w", encoding="utf-8") as f:
        f.write(text)


# --- HTML ----------------------------------------------------------------------------------

CSS = """
:root{--bg:#f6f5f2;--panel:#fff;--ink:#1d1d1f;--muted:#6b6b70;--line:#e3e1dc;--accent:#2f6fde;
--accent-soft:#e7effc;--warn:#a15c00;--ok:#1d7a46;--chip:#efede8;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#141416;--panel:#1d1d20;--ink:#ececef;
--muted:#9a9aa2;--line:#2e2e33;--accent:#7aa7ff;--accent-soft:#1e2a40;--warn:#f0b35a;--ok:#5fd394;--chip:#29292e;color-scheme:dark}}
:root[data-theme=dark]{--bg:#141416;--panel:#1d1d20;--ink:#ececef;--muted:#9a9aa2;--line:#2e2e33;--accent:#7aa7ff;
--accent-soft:#1e2a40;--warn:#f0b35a;--ok:#5fd394;--chip:#29292e;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif}
main{max-width:1240px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:28px;margin:0 0 4px;letter-spacing:-.01em}h2{font-size:20px;margin:40px 0 12px}h3{font-size:17px;margin:0}
p.lede{color:var(--muted);margin:0 0 24px;max-width:70ch}
a{color:var(--accent)}
.table-wrap{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:13.5px}
th,td{padding:9px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th,td.num{white-space:nowrap}td:first-child{min-width:190px}
th{position:sticky;top:0;background:var(--panel);font-weight:600;cursor:pointer;user-select:none}
th.num,td.num{text-align:right;font-variant-numeric:tabular-nums}
th[aria-sort]::after{content:" ↕";color:var(--muted)}th[aria-sort=ascending]::after{content:" ↑"}th[aria-sort=descending]::after{content:" ↓"}
tr:last-child td{border-bottom:0}
td .sub{display:block;color:var(--muted);font-size:12px}
.note{color:var(--muted);font-size:13px;margin:8px 2px}
.cards{display:grid;gap:20px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:20px}
.card header{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline;justify-content:space-between}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 12px}
.chip{background:var(--chip);border-radius:999px;padding:2px 10px;font-size:12.5px}
.chip.warn{background:transparent;border:1px solid var(--warn);color:var(--warn)}
.summary{max-width:80ch;margin:0 0 14px}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px;margin:0 0 14px}
.stat{border:1px solid var(--line);border-radius:8px;padding:8px 10px}
.stat b{display:block;font-size:17px;font-variant-numeric:tabular-nums}.stat span{color:var(--muted);font-size:12px}
.phases{font-size:13px;margin:0 0 14px}.phases td,.phases th{padding:5px 10px}
.gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px;margin:0}
figure{margin:0}figure img,figure video{width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:8px;background:#000;display:block}
figcaption{font-size:12.5px;color:var(--muted);margin-top:4px}
.empty{color:var(--muted);font-size:13px;border:1px dashed var(--line);border-radius:8px;padding:14px}
.links{font-size:13px;margin-top:12px;display:flex;flex-wrap:wrap;gap:4px 14px}
footer{color:var(--muted);font-size:12.5px;margin-top:40px}
"""

SORT_JS = """
document.querySelectorAll('table.sortable').forEach(t=>{const ths=[...t.tHead.rows[0].cells];
ths.forEach((th,i)=>{th.setAttribute('aria-sort','none');th.addEventListener('click',()=>{
const dir=th.getAttribute('aria-sort')==='descending'?'ascending':'descending';ths.forEach(h=>h.setAttribute('aria-sort','none'));
th.setAttribute('aria-sort',dir);const rows=[...t.tBodies[0].rows];
rows.sort((a,b)=>{const x=a.cells[i].dataset.sort,y=b.cells[i].dataset.sort;const nx=parseFloat(x),ny=parseFloat(y);
let c=(!isNaN(nx)&&!isNaN(ny))?nx-ny:String(x).localeCompare(String(y));if(isNaN(nx)!==isNaN(ny))c=isNaN(nx)?1:-1;
return dir==='ascending'?c:-c});rows.forEach(r=>t.tBodies[0].appendChild(r))})})});
"""


def td(text, sort=None, num=False, sub=None):
    cls = ' class="num"' if num else ""
    key = esc(sort if sort is not None else text)
    extra = f'<span class="sub">{esc(sub)}</span>' if sub else ""
    return f'<td{cls} data-sort="{key}">{esc(text)}{extra}</td>'


def table_html(rows):
    head = ["Run", "Model · agent tool", "Engine", "Est. API cost", "Tokens", "Active time", "Your messages",
            "Game code", "Test code", "Docs", "Check"]
    nums = {3, 4, 5, 6, 7, 8, 9}
    out = ['<div class="table-wrap"><table class="sortable"><thead><tr>']
    out += [f'<th{" class=num" if i in nums else ""}>{esc(h)}</th>' for i, h in enumerate(head)]
    out.append("</tr></thead><tbody>")
    for r in rows:
        run = r["run"]
        nan = "NaN"
        out.append("<tr>")
        out.append(f'<td data-sort="{esc(r["id"])}"><a href="#{esc(r["id"])}">{esc(run["title"])}</a>'
                   f'<span class="sub">{esc(run.get("status", ""))}</span></td>')
        out.append(td(run["model"]["name"], sub=harness_text(run)))
        out.append(td(f"{run['engine']['name']} {run['engine'].get('version', '')}".strip()))
        out.append(td(cost_text(r), sort=r["cost"] if r["cost"] is not None else nan, num=True,
                      sub=f"to {r['upto']}" if r["upto"] else None))
        out.append(td(count(r["processed"]) if r["processed"] else "—", sort=r["processed"] or nan, num=True,
                      sub=f"{count(r['output'])} output" if r["output"] else None))
        out.append(td(time_text(r), sort=r["active_h"] if r["active_h"] is not None else (r["git_span_h"] or nan), num=True,
                      sub=f"{hours(r['agent_h'])} agent time" if r["agent_h"] else None))
        out.append(td("—" if r["humans"] is None else str(r["humans"]), sort=r["humans"] if r["humans"] is not None else nan,
                      num=True, sub=f"{r['interrupts']} stops" if r["interrupts"] else None))
        out.append(td(count(r["game_loc"]) if r["game_loc"] else "—", sort=r["game_loc"] or nan, num=True, sub=r["main_lang"]))
        out.append(td(count(r["test_loc"]) if r["test_loc"] else "—", sort=r["test_loc"] or nan, num=True, sub="lines"))
        out.append(td(count(r["docs"]) if r["docs"] else "—", sort=r["docs"] or nan, num=True, sub="lines"))
        out.append(td(check_text(r["checks"])))
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "\n".join(out)


def stat(value, label):
    return f'<div class="stat"><b>{esc(value)}</b><span>{esc(label)}</span></div>'


def card_html(r, links):
    run, total, code, metrics = r["run"], r["total"], r["metrics"].get("code") or {}, r["metrics"]
    rel = f"runs/{r['id']}"
    chips = [run["model"]["name"], harness_text(run),
             f"{run['engine']['name']} {run['engine'].get('version', '')}".strip(), f"started {run.get('started', '?')}"]
    logs = metrics.get("logs") or {}
    efforts = logs.get("efforts") or []
    settings = [s["text"] for s in logs.get("settings") or []]
    if efforts:
        chips.append("effort " + ", ".join(efforts))
    chips_html = "".join(f'<span class="chip">{esc(c)}</span>' for c in chips)
    if r["coverage"] != "complete":
        chips_html += f'<span class="chip warn">logs: {esc(r["coverage"])}</span>'
    if run.get("derived_from"):
        chips_html += f'<span class="chip">ports <a href="#{esc(run["derived_from"])}">{esc(run["derived_from"])}</a></span>'

    stats = []
    if total:
        t = total["tokens"]
        stats += [stat(cost_text(r), f"est. API cost, up to {r['upto']}"),
                  stat(count(r["processed"]), "tokens processed"),
                  stat(count(t["cache_read"]), "of them cache reads"),
                  stat(count(t["output"]), "output tokens" + (f" ({count(t['reasoning'])} reasoning)" if t.get("reasoning") else "")),
                  stat(f"{total['api_calls']:,}", "API calls / turns"),
                  stat(hours(total["time"]["active_h"]), "active time"),
                  stat(hours(total["time"]["agent_h"]), f"agent time (×{total['time']['parallelism'] or 1} parallel)"),
                  stat(hours(total["time"]["wall_clock_h"]), "wall clock, first to last event"),
                  stat(total["human_messages"], "messages from you"),
                  stat(total["interrupts"], "times you stopped it"),
                  stat(f"{logs.get('threads', {}).get('agent', 0)}", "subagent / automated threads")]
    elif r["git_span_h"] is not None:
        stats.append(stat(f"≈ {hours(r['git_span_h'])}", "first to last commit"))
    if code:
        c = code["code"]
        langs = ", ".join(f"{k} {count(v)}" for k, v in sorted(code["loc_by_language"].items(), key=lambda kv: -kv[1]))
        stats += [stat(count(c["game"]["loc"]), f"game code lines ({langs or '—'})"),
                  stat(count(c["test"]["loc"]), "test code lines"),
                  stat(count(c["tooling"]["loc"]), "tooling code lines"),
                  stat(count(code["docs"]["lines"]), f"doc lines ({plural(code['docs']['files'], 'file')})"),
                  stat(sum(a["files"] for a in code["assets"].values()), "asset files (textures, models, audio)"),
                  stat(size(code["bytes_tracked"]), f"{code['files_tracked']:,} tracked files")]
    git = metrics.get("git") or {}
    if git.get("commits"):
        stats.append(stat(git["commits"], "commits by the agent"))
    imp = r["checks"].get("import")
    if imp:
        godot = "Godot " + r["checks"].get("godot", "").split(".stable")[0]
        startup = r["checks"].get("startup") or {}
        stats.append(stat("✓" if imp["ok"] else f"✗ {imp.get('errors')}",
                          f"imports without script errors in {godot}" if imp["ok"] else f"script errors on import in {godot}"))
        stats.append(stat("✓" if startup.get("frames") else "✗",
                          "starts on desktop (XR off)" if startup.get("frames") else "shows nothing on desktop (XR off)"))

    phase_html = ""
    if len(r["phases"]) > 1:
        rows = "".join(
            f"<tr><td>{esc(p['name'])}</td><td class=num>{esc(usd(p['cost_usd']))}</td><td class=num>{esc(count(sum(p['tokens'][k] for k in ('input','cache_write_5m','cache_write_1h','cache_read','output'))))}</td>"
            f"<td class=num>{esc(hours(p['time']['active_h']))}</td><td class=num>{p['human_messages']}</td></tr>" for p in r["phases"])
        phase_html = ('<table class="phases"><thead><tr><th>Up to</th><th class=num>Cost</th><th class=num>Tokens</th>'
                      f'<th class=num>Active</th><th class=num>Your messages</th></tr></thead><tbody>{rows}</tbody></table>')

    items = gallery(r)
    if items:
        figs = []
        for path, caption, kind in items:
            src = links.media(r["id"], path)
            if kind == "video":
                poster = media.poster_path(path)
                poster_attr = f' poster="{esc(links.media(r["id"], poster))}"' if os.path.exists(os.path.join(common.run_dir(r["id"]), poster)) else ""
                figs.append(f'<figure><video controls preload="none"{poster_attr} src="{esc(src)}"></video><figcaption>{esc(caption)}</figcaption></figure>')
            else:
                figs.append(f'<figure><a href="{esc(src)}"><img loading="lazy" src="{esc(src)}" alt="{esc(caption)}"></a><figcaption>{esc(caption)}</figcaption></figure>')
        gallery_html = f'<div class="gallery">{"".join(figs)}</div>'
    else:
        gallery_html = '<div class="empty">No screenshots or video yet: see eval/capture-protocol.md.</div>'

    sources = [f'<a href="{esc(links.source(rel + "/project", folder=True))}">project</a>',
               f'<a href="{esc(links.source(rel + "/run.json"))}">run.json</a>',
               f'<a href="{esc(links.source(rel + "/review.md"))}">your review</a>']
    if os.path.exists(os.path.join(common.run_dir(r["id"]), "human-messages.md")):
        sources.append(f'<a href="{esc(links.source(rel + "/human-messages.md"))}">your messages</a>')
    prompt = run.get("prompt")
    if prompt:
        sources.append(f'<a href="{esc(links.source(f"prompts/{prompt}.md"))}">prompt: {esc(prompt)}</a>')
    notes = "".join(f"<p class=note>{esc(n)}</p>" for n in ([run.get("notes")] if run.get("notes") else []) + ([logs.get("note")] if logs.get("note") else []))
    settings_html = f"<p class=note>Settings during the run: {esc('; '.join(settings))}</p>" if settings else ""
    return (f'<article class="card" id="{esc(r["id"])}"><header><h3>{esc(run["title"])}</h3>'
            f'<span class="note">{esc(run.get("status", ""))}</span></header>'
            f'<div class="chips">{chips_html}</div><p class="summary">{esc(run.get("summary", ""))}</p>'
            f'<div class="stats">{"".join(stats)}</div>{phase_html}{gallery_html}{settings_html}{notes}'
            f'<div class="links">{" ".join(sources)}</div></article>')


def prompts_html(rows, links):
    used = {}
    for r in rows:
        used.setdefault(r["run"].get("prompt"), []).append(r)
    items = []
    for path in sorted(glob.glob(os.path.join(common.ROOT, "prompts", "*.md"))):
        name = os.path.splitext(os.path.basename(path))[0]
        if name == "README":
            continue
        with open(path, encoding="utf-8") as f:
            first = next((l.strip("# \n") for l in f if l.strip()), name)
        runs = ", ".join(f'<a href="#{esc(r["id"])}">{esc(r["run"]["title"])}</a>' for r in used.get(name, [])) or "not used yet"
        items.append(f'<tr><td><a href="{esc(links.source(f"prompts/{name}.md"))}">{esc(name)}</a></td><td>{esc(first)}</td><td>{runs}</td></tr>')
    return ('<div class="table-wrap"><table><thead><tr><th>Prompt</th><th>Title</th><th>Runs</th></tr></thead><tbody>'
            + "".join(items) + "</tbody></table></div>")


def latest_metrics(rows):
    stamps = [r["metrics"].get("generated") for r in rows if r["metrics"].get("generated")]
    return common.local(common.parse_ts(max(stamps))).strftime("%Y-%m-%d %H:%M") if stamps else "—"


def render_html(rows, links):
    known = [r for r in rows if r["cost"] is not None]
    source = f' Source, logs-derived data and method: <a href="{esc(links.repo)}">{esc(links.repo.split("github.com/")[-1])}</a>.' if links.repo else ""
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Soaring LLM Lab</title>
<style>{CSS}</style></head><body><main>
<h1>Soaring LLM Lab</h1>
<p class="lede">{len(rows)} builds of the same brief, a VR bird-flight game for Meta Quest, by different models and agent tools.
{len(known)} have surviving agent logs, so their token use, cost and time are measured; the rest are compared on code and media only.</p>
<h2>Leaderboard</h2>
{table_html(rows)}
<p class="note">Click a column to sort. Costs are at API list prices (eval/pricing.json), not what a subscription bills; "≥" marks partial logs.
Active time counts the periods when an agent thread was working (pauses over 10 minutes removed); agent time adds up parallel threads.
Game code excludes tests, tooling, third-party addons and generated files. Definitions: <a href="{esc(links.source("eval/METHOD.md"))}">eval/METHOD.md</a>.</p>
<h2>Runs</h2>
<div class="cards">{"".join(card_html(r, links) for r in rows)}</div>
<h2>Prompts</h2>
{prompts_html(rows, links)}
<footer>Generated by <code>python3 tools/lab report</code> from metrics collected up to {latest_metrics(rows)}.{source}</footer>
</main><script>{SORT_JS}</script></body></html>
"""


def write_html(rows):
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(REPORT, "w", encoding="utf-8") as f:
        f.write(render_html(rows, Links("../")))


def build_site(out):
    """The report as a static site (GitHub Pages): out/index.html plus every run's media/ beside it."""
    rows = load_all()
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(render_html(rows, Links("")))
    for r in rows:
        src = os.path.join(common.run_dir(r["id"]), "media")
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(out, "runs", r["id"], "media"), dirs_exist_ok=True)
    return len(rows)


def build():
    rows = load_all()
    write_readme(rows)
    write_html(rows)
    return len(rows)
