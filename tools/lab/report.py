"""The leaderboard in README.md (between its markers) and the full report in report/index.html."""
import datetime as dt
import glob
import html
import os
import re
import shutil

import apks
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
        "excluded": run.get("excluded"),  # a reason: kept in runs/, left out of the comparison
        # Lower bounds (eval/METHOD.md): a partial log misses usage, and Codex's long-prompt tier is not priced.
        "lower_cost": coverage == "partial" or run["harness"]["name"] == "Codex",
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
    for c in (r["checks"].get("captures") or []):  # made by the lab's capture tools, not by the agent
        if os.path.exists(os.path.join(base, c["file"])):
            items.append((c["file"], "Lab recording: " + c.get("caption", ""), "video" if c["file"].endswith(".mp4") else "image"))
    return items


def cost_text(r):
    if r["coverage"] == "none":
        return "— (no logs)"
    return usd(r["cost"], partial=r["lower_cost"])


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
             "| Human messages | Game code | Test code | Docs | Check |",
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
    asides = "".join(f"_Not compared: [{r['run']['title']}](runs/{r['id']}/). {r['excluded']}_\n\n" for r in rows if r["excluded"])
    block = f"{START}\n{leaderboard_md([r for r in rows if not r['excluded']])}\n\n{asides}{stamp}\n{END}"
    text = re.sub(re.escape(START) + ".*?" + re.escape(END), lambda m: block, text, flags=re.S)
    with open(README, "w", encoding="utf-8") as f:
        f.write(text)


# --- HTML ----------------------------------------------------------------------------------

FONTS = os.path.join(common.ROOT, "report", "fonts")

CSS = """
@font-face{font-family:"Newsreader";src:url(fonts/newsreader.woff2) format("woff2");font-weight:200 800;font-display:swap}
@font-face{font-family:"Source Sans 3";src:url(fonts/source-sans-3.woff2) format("woff2");font-weight:200 900;font-display:swap}
:root{--bg:#f6f3ec;--surface:#fcfbf8;--sky:#dfe9f3;--ink:#17202b;--ink-2:#465161;--muted:#5e6877;--line:#ddd7ca;
--line-strong:#c4bcac;--accent:#1d5b9e;--bar:#3a7fc4;--track:#e3ebf3;--ok:#1d7447;--no:#9a3412;--thumb:#e4dfd4;
--serif:"Newsreader",Georgia,"Times New Roman",serif;--sans:"Source Sans 3","Segoe UI",system-ui,-apple-system,sans-serif;
color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#0f141b;--surface:#151b23;--sky:#16202c;--ink:#e9edf2;--ink-2:#b7c0cb;
--muted:#929dab;--line:#2a323d;--line-strong:#3c4654;--accent:#86b9f0;--bar:#4a8fd6;--track:#1e2935;--ok:#62cf92;
--no:#f4a37a;--thumb:#222b36;color-scheme:dark}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
@media (prefers-reduced-motion:no-preference){html{scroll-behavior:smooth}}
body{margin:0;background:var(--bg);color:var(--ink);font:400 1rem/1.55 var(--sans);text-rendering:optimizeLegibility}
::selection{background:color-mix(in srgb,var(--bar) 32%,var(--surface));color:var(--ink)}
a{color:var(--accent);text-decoration-thickness:1px;text-underline-offset:.2em}
a:hover{text-decoration-thickness:2px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:2px}
.wrap{max-width:1280px;margin:0 auto;padding:0 16px}
@media (min-width:720px){.wrap{padding:0 32px}}
.visually-hidden{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
.icon{width:1em;height:1em;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}

.masthead{background:linear-gradient(180deg,var(--sky) 0%,var(--bg) 100%);border-bottom:1px solid var(--line);padding:64px 0 32px}
h1{font:600 clamp(2.5rem,6.5vw,4.25rem)/1 var(--serif);letter-spacing:-.025em;margin:0 0 20px;text-wrap:balance}
.dek{font:400 clamp(1.15rem,2.2vw,1.4rem)/1.45 var(--serif);color:var(--ink-2);max-width:34em;margin:0 0 16px;text-wrap:pretty}
.finding{max-width:58ch;margin:0 0 28px;font-size:1.0625rem;font-weight:600;text-wrap:pretty}
@media (min-width:1000px){.masthead .wrap{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,420px);gap:0 56px;align-items:center}
.masthead-text{min-width:0}}
.flock{margin:32px 0 0}
@media (min-width:1000px){.flock{margin:0}}
.flock ul{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px 8px;margin:0;padding:0;list-style:none}
@media (min-width:1000px){.flock ul{grid-template-columns:1fr 1fr}.flock li:first-child:nth-last-child(odd){grid-column:span 2}}
.flock a{display:block;border-radius:4px;color:var(--ink-2);text-decoration:none;font-size:.75rem;line-height:1.3}
.flock a span{display:block;margin-top:5px}
.flock a:hover span{color:var(--accent);text-decoration:underline}
.flock img{width:100%;height:auto;aspect-ratio:16/9;object-fit:cover;border-radius:4px;display:block;box-shadow:0 1px 2px rgb(23 32 43/.12),0 6px 16px -6px rgb(23 32 43/.25)}
.flock figcaption{font-size:.8125rem;color:var(--muted);margin-top:10px}
.updated{margin:20px 0 0;font-size:.8125rem;color:var(--muted)}
.toc{display:flex;flex-wrap:wrap;gap:8px 24px;margin:0;padding:0;list-style:none;font-size:.9375rem}
.toc a{color:var(--ink);text-decoration:none;border-bottom:1px solid var(--line-strong);padding-bottom:2px}
.toc a:hover{color:var(--accent);border-color:currentColor}

section{padding:56px 0 0}
h2{font:600 clamp(1.75rem,3.4vw,2.4rem)/1.12 var(--serif);letter-spacing:-.015em;margin:0 0 10px}
.intro{color:var(--ink-2);max-width:62ch;margin:0 0 24px;text-wrap:pretty}

.scroll{overflow-x:auto;border:1px solid var(--line);border-radius:8px;background:var(--surface);
scrollbar-color:var(--line-strong) transparent;scrollbar-width:thin}
table{border-collapse:separate;border-spacing:0;width:100%;font-size:.9375rem}
th,td{padding:12px 14px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}
tbody tr:last-child>*{border-bottom:0}
thead th{font-size:.8125rem;font-weight:600;color:var(--muted);white-space:nowrap;vertical-align:bottom}
thead button{all:unset;cursor:pointer;display:inline-flex;align-items:center;gap:6px;border-radius:2px}
thead button:hover,th[aria-sort=ascending] button,th[aria-sort=descending] button{color:var(--ink)}
thead button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.sort{width:8px;height:12px;flex:none}.sort path{fill:currentColor;opacity:.3}
th[aria-sort=ascending] .up,th[aria-sort=descending] .down{opacity:1}
.num{font-variant-numeric:tabular-nums}

.glance{min-width:1040px}
.glance tbody tr:hover>*{background:color-mix(in srgb,var(--track) 45%,var(--surface))}
.glance th[scope=row]{position:sticky;left:0;z-index:1;background:var(--surface);font-weight:400;
border-right:1px solid var(--line);width:280px}
.build{display:grid;grid-template-columns:96px minmax(0,1fr);column-gap:14px;align-items:center;color:inherit;text-decoration:none}
.thumb{grid-row:span 2;width:96px;height:54px;border-radius:4px;object-fit:cover;background:var(--thumb);display:grid;
place-items:center;font-size:.75rem;color:var(--ink-2)}
.build .name{font-weight:600;color:var(--ink);align-self:end;line-height:1.3}
.build:hover .name{color:var(--accent);text-decoration:underline;text-underline-offset:.2em}
.sub{display:block;color:var(--muted);font-size:.8125rem;line-height:1.35}
.build .sub{align-self:start}
.status-sub{display:none}
@media (max-width:640px){.glance .result{display:none}.status-sub{display:block;margin-top:4px;color:var(--ink-2)}
.glance th[scope=row]{width:176px;min-width:176px}.build{display:block}.build .thumb{display:none}}
.value{display:block;font-weight:600;white-space:nowrap}
.missing .value{color:var(--muted);font-weight:400}
.check{display:flex;align-items:center;gap:6px;white-space:nowrap;line-height:1.5}
.check.ok .icon{color:var(--ok)}.check.no .icon{color:var(--no)}.check.none{color:var(--muted)}
.glance .result{min-width:150px;max-width:190px;font-size:.875rem;color:var(--ink-2);line-height:1.4}
.table-note{font-size:.875rem;color:var(--muted);max-width:66ch;margin:12px 0 0}
.swipe-hint{display:none;font-size:.8125rem;color:var(--muted);margin:0 0 8px}
@media (max-width:1060px){.swipe-hint{display:block}}

.entry{padding:48px 0;border-top:1px solid var(--line)}
.entries .entry:first-child{border-top:0;padding-top:16px}
.entry h3{font:600 clamp(1.4rem,2.4vw,1.75rem)/1.15 var(--serif);letter-spacing:-.01em;margin:0 0 6px}
.meta{color:var(--ink-2);margin:0;font-size:.9375rem}
.status{margin:8px 0 0;font-weight:600}
.entry-body{display:grid;gap:28px 48px;margin-top:24px}
@media (min-width:960px){.entry-body.has-media{grid-template-columns:minmax(0,1.2fr) minmax(0,1fr)}}
.entry-body:not(.has-media) .entry-text{max-width:760px}
.lead{margin:0}
@media (min-width:960px){.gallery{position:sticky;top:24px}.entry-body.has-media{align-items:start}}
.lead img,.lead video{width:100%;aspect-ratio:16/9;object-fit:contain;border-radius:6px;background:var(--thumb);display:block}
.lead figcaption{font-size:.875rem;color:var(--muted);margin-top:8px}
.thumbs{display:grid;grid-template-columns:repeat(auto-fill,minmax(84px,1fr));gap:8px;margin:12px 0 0;padding:0;list-style:none}
.thumbs a{display:block;position:relative;border-radius:4px;background:var(--thumb)}
.thumbs img{width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:4px;display:block;opacity:.8;transition:opacity .15s ease-out}
.thumbs a:hover img,.thumbs a[aria-current=true] img{opacity:1}
.thumbs a[aria-current=true]::after{content:"";position:absolute;left:0;right:0;bottom:-6px;height:3px;border-radius:2px;background:var(--accent)}
.play{position:absolute;inset:0;margin:auto;width:24px;height:24px;fill:#fff;filter:drop-shadow(0 1px 2px rgb(0 0 0/.6))}
.summary{margin:0 0 20px;max-width:62ch;text-wrap:pretty}
.facts{margin:0 0 20px}
.facts>div{display:grid;grid-template-columns:8.5rem minmax(0,1fr);gap:4px 16px;padding:9px 0;border-top:1px solid var(--line)}
.facts>div:last-child{border-bottom:1px solid var(--line)}
.facts dt{font-size:.875rem;font-weight:600;color:var(--muted)}
.facts dd{margin:0;font-variant-numeric:tabular-nums}
.facts .check{display:inline-flex;margin-right:16px}
@media (max-width:520px){.facts>div{grid-template-columns:1fr}}
details.more{margin:-8px 0 20px}
details.more summary{cursor:pointer;font-weight:600;font-size:.9375rem;color:var(--accent);padding:6px 0;width:fit-content}
details.more[open] summary{margin-bottom:8px}
.more-facts>div:first-child{border-top:0}
.note{font-size:.9375rem;color:var(--ink-2);max-width:62ch}
.phases{font-size:.875rem;margin:0 0 20px;width:auto;min-width:min(100%,460px)}
.phases caption{text-align:left;font-weight:600;font-size:.875rem;color:var(--muted);padding:0 0 6px}
.phases th,.phases td{padding:6px 16px 6px 0}
.phases td.num,.phases th.num{text-align:right}
.notes p{font-size:.9375rem;color:var(--ink-2);max-width:62ch;margin:0 0 12px}
.links{display:flex;flex-wrap:wrap;gap:0 20px;margin:12px 0 0;font-size:.9375rem}
.links a{padding:6px 0}

.prompts{min-width:640px}
.prompts td:first-child{white-space:nowrap}
.defs{display:grid;gap:0 48px;margin:0}
@media (min-width:860px){.defs{grid-template-columns:1fr 1fr}}
.defs>div{padding:14px 0;border-top:1px solid var(--line)}
.defs dt{font-weight:600;margin-bottom:4px}
.defs dd{margin:0;color:var(--ink-2);max-width:62ch}
.foot{margin-top:72px;padding:24px 0 48px;border-top:1px solid var(--line);font-size:.875rem;color:var(--muted)}
code{font-size:.92em}
"""

JS = """
document.querySelectorAll('table.sortable').forEach(t=>{const heads=[...t.tHead.rows[0].cells];
heads.forEach((th,i)=>{const b=th.querySelector('button');if(!b)return;b.addEventListener('click',()=>{
const dir=th.getAttribute('aria-sort')==='descending'?'ascending':'descending';
heads.forEach(h=>h.querySelector('button')&&h.setAttribute('aria-sort','none'));th.setAttribute('aria-sort',dir);
const num=th.classList.contains('num'),rows=[...t.tBodies[0].rows];
rows.sort((a,b)=>{const x=a.cells[i].dataset.sort,y=b.cells[i].dataset.sort;
if(num){const ex=x==='',ey=y==='';if(ex||ey)return ex===ey?0:ex?1:-1;const c=parseFloat(x)-parseFloat(y);return dir==='ascending'?c:-c}
const c=String(x).localeCompare(String(y));return dir==='ascending'?c:-c});
rows.forEach(r=>t.tBodies[0].appendChild(r))})})});
document.querySelectorAll('.gallery').forEach(g=>{const lead=g.querySelector('.lead'),links=[...g.querySelectorAll('.thumbs a')];
links.forEach(a=>a.addEventListener('click',e=>{e.preventDefault();const src=a.getAttribute('href'),cap=a.dataset.caption;let m;
if(a.dataset.kind==='video'){m=document.createElement('video');m.controls=true;m.src=src;if(a.dataset.poster)m.poster=a.dataset.poster}
else{m=document.createElement('a');m.href=src;const img=document.createElement('img');img.src=src;img.alt=cap;m.append(img)}
const fc=document.createElement('figcaption');fc.textContent=cap;lead.replaceChildren(m,fc);
links.forEach(x=>x.removeAttribute('aria-current'));a.setAttribute('aria-current','true');
if(a.dataset.kind==='video')m.play().catch(()=>{})}))});
"""

ICON = {
    "ok": '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>',
    "no": '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 4.5l7 7m0-7l-7 7"/></svg>',
    "none": '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 8h8"/></svg>',
    "play": '<svg class="play" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l11-6.5z"/></svg>',
    "sort": '<svg class="sort" viewBox="0 0 8 12" aria-hidden="true"><path class="up" d="M4 0l4 5H0z"/><path class="down" d="M4 12l4-5H0z"/></svg>',
}
NUMBER_WORDS = "zero one two three four five six seven eight nine ten eleven twelve".split()


def words(n):
    return NUMBER_WORDS[n] if n < len(NUMBER_WORDS) else str(n)


def sentence(text):
    """Capitalised for display, leaving version tokens such as "v1" alone."""
    return text if re.match(r"v\d", text) else text[:1].upper() + text[1:]


def nice_date(day):
    return dt.date.fromisoformat(day).strftime("%-d %b %Y") if day else "?"


def media_items(r):
    """[(path in the run folder, caption, "image"|"video", poster or None)]: chosen media, then captures."""
    base = common.run_dir(r["id"])
    items = []
    for path, caption, kind in gallery(r):
        poster = media.poster_path(path) if kind == "video" else None
        items.append((path, caption, kind, poster if poster and os.path.exists(os.path.join(base, poster)) else None))
    return items


def cover(r, items):
    """The picture that stands for a run: run.json "cover" (a file in media/), else its first chosen
    image, else the end of the start-up capture, else any image or poster."""
    base = common.run_dir(r["id"])
    chosen = r["run"].get("cover")
    candidates = ([f"media/{chosen}"] if chosen else []) + [p for p, _, k, _ in items if k == "image"][:1]
    candidates += ["media/startup-end.jpg"] + [p for p, _, k, _ in items if k == "image"] + [p for _, _, _, p in items if p]
    return next((c for c in candidates if os.path.exists(os.path.join(base, c))), None)


def checks_html(checks):
    imp = checks.get("import")
    if not imp:
        return f'<span class="check none">{ICON["none"]}Not checked yet</span>'
    starts = bool((checks.get("startup") or {}).get("frames"))
    patched = bool((checks.get("build") or {}).get("patch"))  # the copy needed a fix before it would start
    errors = f"{imp.get('errors', '?')} script errors"
    start_ok = starts and not patched
    start_text = "Starts only after a fix" if starts and patched else "Starts on desktop" if starts else "No desktop view"
    return (f'<span class="check {"ok" if imp["ok"] else "no"}">{ICON["ok" if imp["ok"] else "no"]}'
            f'{"Imports cleanly" if imp["ok"] else errors}</span>'
            f'<span class="check {"ok" if start_ok else "no"}">{ICON["ok" if start_ok else "no"]}{start_text}</span>')


def check_rank(checks):
    if not checks.get("import"):
        return ""
    starts = bool((checks.get("startup") or {}).get("frames")) and not (checks.get("build") or {}).get("patch")
    return int(checks["import"]["ok"]) + int(starts)


def num_cell(value, sort, sub=None, missing=False):
    sub_html = f'<span class="sub">{esc(sub)}</span>' if sub else ""
    cls = "num missing" if missing else "num"
    return f'<td class="{cls}" data-sort="{"" if sort is None else sort}"><span class="value">{esc(value)}</span>{sub_html}</td>'


def upto_text(r, prefix="to "):
    return "for the whole run" if r["upto"] == "whole run" else prefix + r["upto"]


def tool_text(run):
    return run["harness"]["name"] if run["harness"]["name"] != "unknown" else "agent tool not recorded"


def glance_html(rows, links):
    head = [("Build", "", "descending"), ("Result", "result", None), ("Est. API cost", "num", "none"),
            ("Active time", "num", "none"), ("Human messages", "num", "none"), ("Game code (lines)", "num", "none"),
            ("Automated check", "", "none")]
    ths = "".join(f'<th scope="col" class="{c}" aria-sort="{sort}"><button type="button">{esc(h)}{ICON["sort"]}</button></th>'
                  if sort else f'<th scope="col" class="{c}">{esc(h)}</th>' for h, c, sort in head)
    body = []
    for r in rows:
        run, partial = r["run"], r["coverage"] == "partial"
        status = esc(sentence(run.get("status", "")))
        img = cover(r, media_items(r))
        thumb = (f'<img class="thumb" src="{esc(links.media(r["id"], img))}" alt="" loading="lazy" width="96" height="54">'
                 if img else '<span class="thumb">no image</span>')
        cells = [f'<th scope="row" data-sort="{esc(r["id"])}"><a class="build" href="#{esc(r["id"])}">{thumb}'
                 f'<span class="name">{esc(run["title"])}</span><span class="sub">{esc(run["model"]["name"])} · {esc(tool_text(run))}'
                 f'<span class="status-sub">{status}</span></span></a></th>',
                 f'<td class="result">{status}</td>']
        if r["coverage"] == "none":
            cells.append(num_cell("—", None, "no logs", missing=True))
        else:
            sub = None if r["upto"] == "v1 delivered" else upto_text(r)
            cells.append(num_cell(cost_text(r), r["cost"], f"{sub}, partial log" if partial and sub else sub))
        if r["active_h"] is not None:
            parallel = r["agent_h"] and r["agent_h"] >= 1.2 * r["active_h"]
            cells.append(num_cell(("≥ " if partial else "") + hours(r["active_h"]), r["active_h"],
                                  f"{hours(r['agent_h'])} agent time" if parallel else None))
        elif r["git_span_h"] is not None:  # a different measure: shown, but sorted as missing
            cells.append(num_cell(f"≈ {hours(r['git_span_h'])}", None, "first to last commit", missing=True))
        else:
            cells.append(num_cell("—", None, "no logs", missing=True))
        if r["humans"] is not None:
            cells.append(num_cell(("≥ " if partial else "") + str(r["humans"]), r["humans"],
                                  plural(r["interrupts"], "stop") if r["interrupts"] else None))
        else:
            cells.append(num_cell("—", None, "no logs", missing=True))
        if r["game_loc"]:
            cells.append(num_cell(count(r["game_loc"]), r["game_loc"], r["main_lang"]))
        else:
            cells.append(num_cell("—", None, None, missing=True))
        checks = r["checks"]
        rank = check_rank(checks)
        cells.append(f'<td data-sort="{rank}">{checks_html(checks)}</td>')
        body.append("<tr>" + "".join(cells) + "</tr>")
    return (f'<div class="scroll"><table class="glance sortable"><caption class="visually-hidden">Every build, newest first, measured '
            f'up to delivery unless a cell says otherwise. Column headings sort the table.</caption><thead><tr>{ths}</tr></thead>'
            f'<tbody>{"".join(body)}</tbody></table></div>')


def gallery_html(r, links, items):
    if not items:
        return ""
    lead_path = cover(r, items)
    lead = next((it for it in items if it[0] == lead_path), items[0])

    def lead_html(it):
        path, caption, kind, poster = it
        src = esc(links.media(r["id"], path))
        if kind == "video":
            poster_attr = f' poster="{esc(links.media(r["id"], poster))}"' if poster else ""
            return (f'<video controls preload="none"{poster_attr} src="{src}" aria-label="{esc(caption)}"></video>'
                    f'<figcaption>{esc(caption)}</figcaption>')
        return f'<a href="{src}"><img src="{src}" alt="{esc(caption)}" loading="lazy"></a><figcaption>{esc(caption)}</figcaption>'

    thumbs = ""
    if len(items) > 1:
        lis = []
        for it in items:
            path, caption, kind, poster = it
            picture = poster if kind == "video" else path
            img = f'<img src="{esc(links.media(r["id"], picture))}" alt="{esc(caption)}" loading="lazy">' if picture else ""
            poster_attr = f' data-poster="{esc(links.media(r["id"], poster))}"' if poster else ""
            current = ' aria-current="true"' if it is lead else ""
            lis.append(f'<li><a href="{esc(links.media(r["id"], path))}" data-kind="{kind}" data-caption="{esc(caption)}"'
                       f'{poster_attr}{current}>{img}{ICON["play"] if kind == "video" else ""}</a></li>')
        thumbs = f'<ul class="thumbs" aria-label="Screenshots and video of {esc(r["run"]["title"])}">{"".join(lis)}</ul>'
    return f'<div class="gallery"><figure class="lead" aria-live="polite">{lead_html(lead)}</figure>{thumbs}</div>'


def dl(facts, cls):
    return f'<dl class="{cls}">' + "".join(f"<div><dt>{esc(k)}</dt><dd>{v}</dd></div>" for k, v in facts) + "</dl>"


def facts_html(r, links):
    """(the key facts, the detail behind "Tokens, files and milestones")"""
    metrics, total, partial = r["metrics"], r["total"], r["coverage"] == "partial"
    logs, code, git = metrics.get("logs") or {}, metrics.get("code"), metrics.get("git") or {}
    facts, more = [], []
    at_least = "≥ " if partial else ""
    if total:
        whole = r["phases"][-1]
        cost = f'<b>{esc(cost_text(r))}</b> {esc(upto_text(r, "up to "))}'
        if whole is not total and whole.get("cost_usd") is not None:
            cost += f', {esc(usd(whole["cost_usd"], r["lower_cost"]))} for the whole run'
        if partial:
            cost += " (the log covers only part of the session)"
        elif r["lower_cost"]:
            cost += " (a lower bound: Codex's long-prompt pricing is not modelled)"
        facts.append(("Est. API cost", cost))
        tm = total["time"]
        time = f'<b>{at_least}{hours(tm["active_h"])}</b> active'
        if tm.get("parallelism") and tm["parallelism"] >= 1.2:
            time += f', {hours(tm["agent_h"])} of agent time across parallel threads'
        threads = (logs.get("threads") or {}).get("agent", 0)
        if threads:
            time += f' ({plural(threads, "subagent or review thread")})'
        time += f'; {hours(tm["wall_clock_h"])} from first to last log event'
        facts.append(("Time", time))
        human = f'<b>{at_least}{plural(total["human_messages"], "message")}</b>'
        if total["interrupts"]:
            human += f', {plural(total["interrupts"], "stop")}'
        facts.append(("Human steering", human))
        t = total["tokens"]
        reads = f", {t['cache_read'] / r['processed'] * 100:.0f}% of them cache reads" if r["processed"] else ""
        reasoning = f" ({count(t['reasoning'])} reasoning)" if t.get("reasoning") else ""
        more.append(("Tokens", esc(f"{at_least}{count(r['processed'])} processed{reads}; {count(t['output'])} output{reasoning}; "
                                   f"{total['api_calls']:,} API calls")))
    else:
        facts.append(("Est. API cost", "Unknown: no agent logs survive"))
        if r["git_span_h"] is not None:
            facts.append(("Time", f"About {hours(r['git_span_h'])} from the agent's first to last commit"))
    if code:
        c = code["code"]
        langs = ", ".join(k for k, _ in sorted(code["loc_by_language"].items(), key=lambda kv: -kv[1]))
        rest = ", ".join(f"{count(n)} of {what}" for n, what in ((c["test"]["loc"], "tests"), (c["tooling"]["loc"], "tooling"),
                                                                  (code["docs"]["lines"], "docs")) if n)
        facts.append(("Code", f'<b>{count(c["game"]["loc"])}</b> lines of game code{f" ({esc(langs)})" if langs else ""}'
                              + (f"; {rest}" if rest else "")))
        assets = sum(a["files"] for a in code["assets"].values())
        files = f'{code["files_tracked"]:,} files ({size(code["bytes_tracked"])}), {plural(assets, "asset file")}'
        if git.get("commits"):
            files += f'; {plural(git["commits"], "commit")} by the agent'
        more.append(("Files", files))
    apk = r["run"].get("apk") or {}
    if apk.get("bytes") and links.repo:
        named = f', shows as “{esc(apk["label"])}”' if apk.get("label") else ""
        lab = f'<span class="sub">{esc(apk["note"])}</span>' if apk.get("by") == "lab" and apk.get("note") else ""
        facts.append(("On a Quest", f'<a href="{esc(apks.asset_url(links.repo, r["id"]))}">Download the APK</a> '
                                    f'({size(apk["bytes"])}{named}) · <a href="{esc(apks.release_url(links.repo))}">how to install</a>{lab}'))
    checks = r["checks"]
    imp = checks.get("import")
    if imp:
        engine = ("Godot " + checks["godot"].split(".stable")[0] if checks.get("godot")
                  else "Unity " + checks["unity"] if checks.get("unity") else r["run"]["engine"]["name"])
        upgraded = f", upgraded from {imp['upgraded_from']}" if imp.get("upgraded_from") else ""
        fixed = "; as archived it does not start, so the recordings use a copy with one fix (see the details)" \
            if (checks.get("build") or {}).get("patch") else ""
        facts.append(("Automated check", f'{checks_html(checks)}<span class="sub">imported and launched in {esc(engine)}'
                                         f'{esc(upgraded)}{esc(fixed)}</span>'))
    else:
        reason = "Unity builds need a re-import first" if r["run"]["engine"]["name"] == "Unity" else "no capture yet"
        facts.append(("Automated check", f'{checks_html(r["checks"])}<span class="sub">{esc(reason)}</span>'))
    return dl(facts, "facts"), dl(more, "facts more-facts") if more else ""


def setting_text(text):
    """A settings line from the agent tool, reworded for the report: "model set to Opus 5"."""
    text = text.replace("`", "").rstrip(".")
    m = re.match(r"Set model to (.+?)(?: and saved .*)?$", text)
    if m:
        return f"model set to {m.group(1)}"
    m = re.match(r"Set effort level to (\w+)(?: \([^)]*\))?(?::\s*(.*))?$", text)
    if m:
        detail = m.group(2) if m.group(2) and "+" in m.group(2) else None
        return f"effort set to {m.group(1)}" + (f" ({detail.replace(' + ', ' plus ')})" if detail else "")
    return text[:1].lower() + text[1:]


def linkify(text):
    return re.sub(r"\b(github\.com/[\w-]+/[\w-]+)", lambda m: f'<a href="https://{m.group(1)}">{m.group(1)}</a>', esc(text))


def phases_html(r):
    if len(r["phases"]) <= 1:
        return ""
    keys = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")
    rows = "".join(
        f'<tr><td>{esc(p["name"])}</td><td class="num">{esc(usd(p["cost_usd"], r["coverage"] == "partial"))}</td>'
        f'<td class="num">{esc(count(sum(p["tokens"][k] for k in keys)))}</td><td class="num">{esc(hours(p["time"]["active_h"]))}</td>'
        f'<td class="num">{p["human_messages"]}</td></tr>' for p in r["phases"])
    return ('<table class="phases"><caption>Measured at each milestone</caption><thead><tr><th scope="col">Up to</th>'
            '<th scope="col" class="num">Est. cost</th><th scope="col" class="num">Tokens</th><th scope="col" class="num">Active</th>'
            f'<th scope="col" class="num">Human messages</th></tr></thead><tbody>{rows}</tbody></table>')


def entry_html(r, links, titles):
    run, logs = r["run"], r["metrics"].get("logs") or {}
    rel = f"runs/{r['id']}"
    harness = harness_text(run) if run["harness"]["name"] != "unknown" else tool_text(run)
    meta = [run["model"]["name"], harness, f"{run['engine']['name']} {run['engine'].get('version', '')}".strip(),
            "started " + nice_date(run.get("started"))]
    if logs.get("efforts"):
        meta.append("reasoning effort " + ", ".join(logs["efforts"]))
    meta_html = " · ".join(esc(m) for m in meta)
    if run.get("derived_from"):
        source = titles.get(run["derived_from"], run["derived_from"])
        meta_html += f' · ports <a href="#{esc(run["derived_from"])}">{esc(source)}</a>'
    items = media_items(r)
    # A run without logs already says so in its facts.
    notes = [n for n in (run.get("notes"), logs.get("note") if r["coverage"] != "none" else None) if n]
    settings = list(dict.fromkeys(setting_text(s["text"]) for s in logs.get("settings") or []))
    if not items:
        notes.append("No screenshots or video yet.")
    base = common.run_dir(r["id"])
    prompt = run.get("prompt")
    links_html = [f'<a href="{esc(links.source(rel + "/project", folder=True))}">Project files</a>']
    if prompt:
        links_html.append(f'<a href="{esc(links.source(f"prompts/{prompt}.md"))}">Prompt: {esc(prompt)}</a>')
    if os.path.exists(os.path.join(base, "human-messages.md")):
        links_html.append(f'<a href="{esc(links.source(rel + "/human-messages.md"))}">Human messages</a>')
    if review_written(os.path.join(base, "review.md")):
        links_html.append(f'<a href="{esc(links.source(rel + "/review.md"))}">Playtest review</a>')
    links_html += [f'<a href="{esc(links.source(rel + "/run.json"))}">run.json</a>', '<a href="#glance">Back to the table</a>']
    facts, more = facts_html(r, links)
    settings_html = f'<p class="note">Settings changed during the run: {esc("; ".join(settings))}.</p>' if settings else ""
    check_notes = r["checks"].get("notes")
    check_html = f'<p class="note">About the automated check: {esc(check_notes)}</p>' if check_notes else ""
    inner = more + phases_html(r) + settings_html + check_html
    details = f'<details class="more"><summary>Tokens, files, milestones and checks</summary>{inner}</details>' if inner else ""
    return (f'<article class="entry" id="{esc(r["id"])}"><header><h3>{esc(run["title"])}</h3><p class="meta">{meta_html}</p>'
            f'<p class="status">{esc(sentence(run.get("status", "")))}</p></header>'
            f'<div class="entry-body{" has-media" if items else ""}">{gallery_html(r, links, items)}<div class="entry-text">'
            f'<p class="summary">{linkify(run.get("summary", ""))}</p>{facts}{details}'
            f'<div class="notes">{"".join(f"<p>{esc(n)}</p>" for n in notes)}</div>'
            f'<p class="links">{"".join(links_html)}</p></div></div></article>')


def review_written(path):
    """A run's review.md counts once the template's placeholders are filled in."""
    if not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as f:
        return "<headset or simulator>" not in f.read()


def prompt_lineage():
    """[(name, used by, lineage)] in the order of the table in prompts/README.md."""
    path = os.path.join(common.ROOT, "prompts", "README.md")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return [(m.group(1), m.group(2).strip(), m.group(3).strip())
            for m in re.finditer(r"^\| \[([\w.-]+)\]\([\w.-]+\.md\) \|([^|]*)\|([^|]*)\|\s*$", text, re.M)]


def prompts_html(rows, links):
    used = {}
    for r in rows:
        used.setdefault(r["run"].get("prompt"), []).append(r)
    items = []
    for name, used_by, lineage in prompt_lineage():
        runs = ", ".join(f'<a href="#{esc(r["id"])}">{esc(r["run"]["title"])}</a>' if not r["excluded"] else
                         f'<a href="{esc(links.source("runs/" + r["id"], folder=True))}">{esc(r["run"]["title"])}</a> (not compared)'
                         for r in used.get(name, []))
        runs = runs or f'<span class="sub">{esc(used_by.replace("no run yet", "no build yet"))}</span>'
        items.append(f'<tr><td><a href="{esc(links.source(f"prompts/{name}.md"))}">{esc(name)}</a></td>'
                     f'<td>{esc(sentence(lineage))}</td><td>{runs}</td></tr>')
    return ('<div class="scroll"><table class="prompts"><caption class="visually-hidden">Every prompt, oldest first</caption>'
            '<thead><tr><th scope="col">Prompt</th><th scope="col">What it is</th><th scope="col">Used by</th></tr></thead><tbody>'
            + "".join(items) + "</tbody></table></div>")


def finding_text(rows):
    logged = [r for r in rows if r["coverage"] != "none" and r["cost"] is not None]
    complete = [r for r in logged if r["coverage"] == "complete"]
    if len(logged) < 2 or not complete:
        return ""
    lo, hi = min(logged, key=lambda r: r["cost"]), max(complete, key=lambda r: r["cost"])
    unknown = len(rows) - len(logged)
    tail = f" {words(unknown).capitalize()} builds have no surviving logs, so their cost is unknown." if unknown else ""
    return (f"Up to delivery, the builds with logs cost from {'at least ' if lo['lower_cost'] else ''}{usd(lo['cost'])} "
            f"({lo['run']['title']}) to {'at least ' if hi['lower_cost'] else ''}{usd(hi['cost'])} ({hi['run']['title']}) "
            f"at API list prices.{tail}")


def latest_metrics(rows):
    stamps = [r["metrics"].get("generated") for r in rows if r["metrics"].get("generated")]
    return common.local(common.parse_ts(max(stamps))).strftime("%-d %b %Y, %H:%M") if stamps else "—"


def flock_html(rows, links):
    """Cover shots of the builds that have one, linking to their entries: the masthead's picture."""
    tiles = []
    for r in rows:
        img = cover(r, media_items(r))
        if img:
            tiles.append(f'<li><a href="#{esc(r["id"])}"><img src="{esc(links.media(r["id"], img))}" alt="" '
                         f'width="206" height="116"><span>{esc(r["run"]["title"])}</span></a></li>')
    if len(tiles) < 2:
        return ""
    return (f'<figure class="flock"><ul>{"".join(tiles[:6])}</ul><figcaption>{words(min(len(tiles), 6)).capitalize()} '
            f'of the builds as they look today, newest first.</figcaption></figure>')


def site_url(repo):
    """The GitHub Pages address of a github.com repo URL."""
    owner, name = repo.split("github.com/")[-1].split("/")[:2]
    return f"https://{owner.lower()}.github.io/{name}/"


def install_html(installable, links):
    if not installable or not links.repo:
        return ""
    lab_built = [r for r in installable if r["run"]["apk"].get("by") == "lab"]
    return (f'<p class="table-note">{words(len(installable)).capitalize()} builds can be installed on a Meta Quest in developer '
            f'mode: <a href="{esc(apks.release_url(links.repo))}">download the APKs</a>, each as its agent built it'
            + (f' except {words(len(lab_built))}, built by the lab and marked as such' if lab_built else "") + ".</p>")


def excluded_html(rows, links):
    return "".join(f'<p class="table-note">Not compared: <a href="{esc(links.source("runs/" + r["id"], folder=True))}">'
                   f'{esc(r["run"]["title"])}</a>. {esc(r["excluded"])}</p>' for r in rows if r["excluded"])


def render_html(rows, links):
    every = rows
    rows = sorted((r for r in rows if not r["excluded"]), key=lambda r: (r["run"].get("started", ""), r["id"]), reverse=True)
    titles = {r["id"]: r["run"]["title"] for r in rows}
    no_logs = sum(1 for r in rows if r["coverage"] == "none")
    description = (f"One brief, {words(len(rows))} builds: AI models and agent tools compared on building the same VR "
                   "bird-flight game, by cost, time, human steering and what came out.")
    social = ""
    if links.repo:
        image = next(((r["id"], cover(r, media_items(r))) for r in rows if cover(r, media_items(r))), None)
        social = (f'<meta property="og:title" content="Soaring LLM Lab"><meta property="og:description" content="{esc(description)}">'
                  f'<meta property="og:url" content="{esc(site_url(links.repo))}">'
                  + (f'<meta property="og:image" content="{esc(site_url(links.repo) + "runs/" + image[0] + "/" + image[1])}">'
                     '<meta name="twitter:card" content="summary_large_image">' if image else ""))
    installable = [r for r in rows if (r["run"].get("apk") or {}).get("bytes")]
    repo = (f'<li><a href="{esc(apks.release_url(links.repo))}">Install on a Quest</a></li>' if installable and links.repo else "") + \
           (f'<li><a href="{esc(links.repo)}">Source on GitHub</a></li>' if links.repo else "")
    source = f' <a href="{esc(links.repo)}">Source, data and method on GitHub</a>.' if links.repo else ""
    method = esc(links.source("eval/METHOD.md"))
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Soaring LLM Lab</title>
<meta name="description" content="{esc(description)}">{social}
<link rel="preload" href="fonts/source-sans-3.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="fonts/newsreader.woff2" as="font" type="font/woff2" crossorigin>
<style>{CSS}</style></head><body>
<header class="masthead"><div class="wrap"><div class="masthead-text">
<h1>Soaring LLM Lab</h1>
<p class="dek">One brief, {words(len(rows))} builds. Different AI models and agent tools each built the same game: a VR bird-flight
game for Meta Quest that you fly by flapping your arms. This page compares what each build cost, how long it took, how much a
human had to steer it, and what came out.</p>
<p class="finding">{esc(finding_text(rows))}</p>
<nav aria-label="Sections"><ul class="toc"><li><a href="#glance">At a glance</a></li><li><a href="#builds">The builds</a></li>
<li><a href="#prompts">Prompts</a></li><li><a href="#method">Reading the numbers</a></li>{repo}</ul></nav>
<p class="updated">Updated {latest_metrics(rows)}</p>
</div>{flock_html(rows, links)}</div></header>
<main>
<section id="glance"><div class="wrap">
<h2>At a glance</h2>
<p class="intro">Newest first. Each build is measured up to delivery: the moment before the first request that went beyond
the brief. This is not a ranking: briefs, tools and steering differ, and no build has a playtest score yet.</p>
<p class="swipe-hint">Swipe the table sideways for the numbers.</p>
{glance_html(rows, links)}
<p class="table-note">Costs are estimates at API list prices, not what a subscription billed. “≥” marks a lower bound: the
log covers only part of the session, or the tool's pricing is not fully modelled (Codex). “No logs” means none survive.
<a href="#method">How each number is measured</a>.</p>
{install_html(installable, links)}{excluded_html(every, links)}
</div></section>
<section id="builds"><div class="wrap">
<h2>The builds</h2>
<p class="intro">Newest first. Each entry shows what came out, what it cost, and where to find the prompt, the code and every
message the human typed. Select a thumbnail to see it larger.</p>
<div class="entries">{"".join(entry_html(r, links, titles) for r in rows)}</div>
</div></section>
<section id="prompts"><div class="wrap">
<h2>Prompts</h2>
<p class="intro">The brief each build started from, oldest first. Each name opens the full text, word for word. Briefs were
revised between runs, so later builds started from better instructions.</p>
{prompts_html(every, links)}
</div></section>
<section id="method"><div class="wrap">
<h2>Reading the numbers</h2>
<p class="intro">This is a lab notebook, not a controlled experiment: briefs were revised between runs, the agent tools and
modes differ, and {words(no_logs)} builds have no surviving logs. Full definitions are in <a href="{method}">eval/METHOD.md</a>.</p>
<dl class="defs">
<div><dt>Est. API cost</dt><dd>Tokens from the agent logs priced at API list prices
(<a href="{esc(links.source("eval/pricing.json"))}">pricing.json</a>). Not what a subscription billed; Codex costs are a lower bound.</dd></div>
<div><dt>Up to delivery</dt><dd>Builds are compared at the milestone where the brief was delivered (“v1 delivered”, or “port
delivered” for the port). Each entry also lists its whole run, which can include later playtest fixes or prompt writing.</dd></div>
<div><dt>Active time</dt><dd>Time when at least one agent thread was working; pauses over 10 minutes are left out. Agent time
adds parallel threads together, so a multi-agent build has more agent time than active time.</dd></div>
<div><dt>Human messages</dt><dd>Messages the person running the experiment typed during the build. Prompts between agents and
tool output don't count. Stops are turns the human interrupted.</dd></div>
<div><dt>Game and test code</dt><dd>Non-blank lines in the files the agent committed, without third-party plugins and generated
files. Every build wrote its own test harness, so lines of test code compare better than test counts.</dd></div>
<div><dt>“≥”, lower bounds</dt><dd>A partial log misses some of a session's tokens, time and messages. Codex prompts
over 272K tokens are billed at a higher tier that is not modelled, so Codex costs are minimums too.</dd></div>
<div><dt>Reasoning effort and ultracode</dt><dd>The agent tool's effort setting (low to xhigh), read from the logs. Ultracode
is Claude Code's mode for running multi-agent workflows; “golden build” marks the build the game continues from.</dd></div>
<div><dt>Automated check</dt><dd>Each build is imported in its engine (Unity builds re-imported in Unity 6000.6.4f1) and
launched on desktop with XR off: “starts” means it drew frames. Neither replaces playing the game on a headset.</dd></div>
<div><dt>Lab recordings</dt><dd>Pictures captioned “Lab recording” were made by the lab on desktop with XR off: 12 seconds
after launch with no input, and 36 seconds of flight driven by a fixed timeline of key or controller input. Every other
picture was made by the build's own agent.</dd></div>
</dl>
</div></section>
</main>
<footer class="foot"><div class="wrap">Built from the archived agent logs and the code in the repository, last measured
{latest_metrics(rows)}.{source}</div></footer>
<script>{JS}</script></body></html>
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
    shutil.copytree(FONTS, os.path.join(out, "fonts"), dirs_exist_ok=True)
    for r in rows:
        src = os.path.join(common.run_dir(r["id"]), "media")
        if os.path.isdir(src) and not r["excluded"]:
            shutil.copytree(src, os.path.join(out, "runs", r["id"], "media"), dirs_exist_ok=True)
    return len(rows)


def build():
    rows = load_all()
    write_readme(rows)
    write_html(rows)
    return len(rows)
