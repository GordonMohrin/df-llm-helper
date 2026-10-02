"""Spec 11: dashboard for the player (`python -m df_llm_helper dashboard`).

Static HTML page (no external libraries, light/dark, smartphone width) ONLY from state.db:
header (latest snapshot), key figures with sparklines (snapshot history history_h), forecast (spec 05), warnings
(= digest state 'digest.state.all', the same items as in the status report), build plan (building counters in kv),
bottleneck/stock (spec 07), trade (spec 02/03/07), events (warnings + actions), map excerpts (kv).
If a source is missing, the section is omitted (no placeholders). Written only if the content changed (hash).
"""
from __future__ import annotations

import hashlib
import html
import json
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

__all__ = ["DEFAULTS", "collect", "render", "validate_html", "write_if_changed", "BUILDPLAN", "LOCATIONS_CMD",
           "parse_locations"]

# count the locations of the own fortress (read only): 'TEMPLE=2 INN_TAVERN=2 HOSPITAL=3 ...'
LOCATIONS_CMD = ('lua "local t={} local s=df.global.world.world_data.active_site[0] if s then for _,b in ipairs(s.buildings) '
                 'do local n=df.abstract_building_type[b:getType()] or \'?\' t[n]=(t[n] or 0)+1 end end local o={} '
                 'for k,v in pairs(t) do o[#o+1]=k..\'=\'..v end print(table.concat(o,\' \'))"')


def parse_locations(text: str) -> dict:
    import re as _re
    return {f"Loc:{k}": int(v) for k, v in _re.findall(r"([A-Z_?]+)=(\d+)", text or "")}

DEFAULTS = {"out": "out/dashboard.html", "history_h": 6, "events": 20}
# Communal buildings (run 5 LAYOUT): name, kind, minimum count. Hospital/temple/tavern/library/guildhall are
# locations in DF 53 ('Loc:<abstract_building_type>'), not zone types (live 01.10.); zones 'Zone:*' from claude/buildings.
BUILDPLAN = [
    {"name": "Hospital", "kind": "Loc:HOSPITAL", "min": 1}, {"name": "Temple", "kind": "Loc:TEMPLE", "min": 1},
    {"name": "Tavern", "kind": "Loc:INN_TAVERN", "min": 1}, {"name": "Library", "kind": "Loc:LIBRARY", "min": 1},
    {"name": "Guildhall", "kind": "Loc:GUILDHALL", "min": 1}, {"name": "Barracks", "kind": "Zone:Barracks", "min": 1},
    {"name": "Dining hall", "kind": "Zone:DiningHall", "min": 1}, {"name": "Dormitory", "kind": "Zone:Dormitory", "min": 1},
    {"name": "Crypt (20 graves)", "kind": "Zone:Tomb", "min": 20}, {"name": "Well", "kind": "Well", "min": 1},
    {"name": "Trade depot", "kind": "TradeDepot", "min": 1},
]
KPIS = [("pop", "Population", ""), ("idle_pct", "Idle", " %"), ("food_days", "Food", " days"),
        ("drink_days", "Drinks", " days"), ("meals_head", "Meals/head", ""), ("jobs_open", "Open jobs", ""),
        ("dig_jobs", "Dig jobs", ""), ("diggers", "Active diggers", "")]
LEVEL = {"crit": ("red", "critical"), "warn": ("yellow", "Warning"), "trend": ("yellow", "Trend"), "info": ("ok", "Info")}


def _rows(store, sql: str, args=()) -> list:
    return [dict(r) for r in store.db.execute(sql, args).fetchall()]


def collect(store, now: float, cfg: dict | None = None) -> dict:
    c = {**DEFAULTS, **(cfg or {})}
    since = now - float(c["history_h"]) * 3600
    snaps = [{"ts": r["ts"], **json.loads(r["facts"])}
             for r in _rows(store, "SELECT ts, facts FROM snapshots WHERE ts >= ? ORDER BY id", (since,))]
    for s in snaps:
        if s.get("meals") is not None and s.get("pop"):
            s["meals_head"] = round(s["meals"] / s["pop"], 2)
    d: dict = {"now": now, "snaps": snaps, "last": snaps[-1] if snaps else None}
    st = store.get("digest.state.all") or {}
    rank = {"crit": 0, "warn": 1, "trend": 2, "info": 3}          # critical first, then by key
    d["alerts"] = [{"key": k, **v} for k, v in sorted((st.get("alerts") or {}).items(),
                                                       key=lambda kv: (rank.get(kv[1].get("level"), 1), kv[0]))]
    d["buildings"] = store.get("dashboard.buildings")
    d["maps"] = store.get("dashboard.maps") or {}
    d["bottleneck"] = {"line": store.get("bottleneck.line"), "stock": store.get("bottleneck.stock"),
                       "since": store.get("bottleneck.since") or {}}
    d["trade"] = {"caravan": store.get("caravan.state") or {}, "boost": store.get("trade.boost") or [],
                  "boost_bn": store.get("trade.boost_bottleneck") or []}
    try:
        from .forecast import Forecaster, fmt_line
        fc = Forecaster(store, None, {})
        d["forecast"] = fmt_line(fc.estimates()) if len(fc.series()) >= 2 else None
    except Exception:                                   # the forecast is optional
        d["forecast"] = None
    ev = [{"ts": r["ts"], "kind": r["level"], "text": f"[{r['source']}] {r['text']}"}
          for r in _rows(store, "SELECT ts, level, source, text FROM warnings ORDER BY id DESC LIMIT ?", (c["events"],))]
    ev += [{"ts": r["ts"], "kind": "action", "text": f"[{r['source']}] {r['action']}: {r['cmd']}"
            + ("" if r["ok"] else " (ERROR)")}
           for r in _rows(store, "SELECT ts, source, action, cmd, ok FROM actions WHERE dry_run = 0 "
                                 "ORDER BY id DESC LIMIT ?", (c["events"],))]
    ev.sort(key=lambda e: -e["ts"])
    d["events"] = ev[:int(c["events"])]
    return d


def _spark(values: list, w: int = 120, h: int = 28) -> str:
    vals = [v for v in values if isinstance(v, (int, float))]
    if len(vals) < 2:
        return ""
    lo, hi = min(vals), max(vals)
    span = (hi - lo) or 1.0
    pts = " ".join(f"{i * (w - 2) / (len(vals) - 1) + 1:.1f},{h - 2 - (v - lo) * (h - 4) / span:.1f}"
                   for i, v in enumerate(vals))
    return (f'<svg class="spark" viewBox="0 0 {w} {h}" width="{w}" height="{h}" aria-hidden="true">'
            f'<polyline points="{pts}" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>')


def _t(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%H:%M")


CSS = """
:root{--bg:#f7f6f2;--fg:#1d1d1b;--card:#fff;--muted:#6b6a65;--line:#dedbd2;--red:#b3261e;--yellow:#a86b00;--ok:#2e7d32;
--accent:#3b5bdb;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ecebe6;--card:#1f1f1d;--muted:#a3a29b;--line:#34332f;
--red:#ff8a80;--yellow:#ffcc66;--ok:#81c784;--accent:#8ea2ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:16px}h1{font-size:1.4rem;margin:0 0 4px}h2{font-size:1.05rem;margin:24px 0 8px}
.meta{color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
.k{color:var(--muted);font-size:.85rem}.v{font-size:1.35rem;font-weight:600}.spark{color:var(--accent);display:block;margin-top:4px}
ul{margin:0;padding-left:18px}li{margin:2px 0}.red{color:var(--red)}.yellow{color:var(--yellow)}.ok{color:var(--ok)}
pre{font:12px/1.2 var(--mono);background:var(--card);border:1px solid var(--line);border-radius:8px;padding:8px;overflow-x:auto}
table{border-collapse:collapse;width:100%}td{border-bottom:1px solid var(--line);padding:3px 6px;vertical-align:top}
@media (max-width:480px){main{padding:12px}.v{font-size:1.15rem}}
"""


def render(d: dict, cfg: dict | None = None) -> str:
    e = html.escape
    last = d.get("last")
    parts = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
             '<meta name="viewport" content="width=device-width,initial-scale=1">',
             "<title>Fortress Dashboard</title><style>" + CSS + "</style></head><body><main>"]
    if last:
        tempo = "timestream" if last.get("timestream") else "normal"
        head = [f"{e(str(last.get('date') or ''))}", f"Pop {last.get('pop')}"]
        if last.get("fps") is not None:
            head.append(f"{last.get('fps'):g} fps ({tempo})")
        head.append("paused" if last.get("paused") else "running")
        if last.get("squad_members") is not None:
            head.append(f"Guard/squads {last.get('squad_members')}")
        parts.append(f"<h1>{e(str(last.get('fort') or 'Fortress'))}</h1><p class=\"meta\">" + " · ".join(head)
                     + f" · as of {_t(last['ts'])}</p>")
        cards = []
        for key, label, unit in KPIS:
            v = last.get(key)
            if v is None:
                continue
            series = [s.get(key) for s in d["snaps"]]
            cards.append(f'<div class="card"><div class="k">{e(label)}</div><div class="v">{e(str(v))}{e(unit)}</div>'
                         f"{_spark(series)}</div>")
        parts.append("<h2>Key figures</h2><div class=\"grid\">" + "".join(cards) + "</div>")
    else:
        parts.append("<h1>Fortress Dashboard</h1><p class=\"meta\">No snapshot yet in state.db "
                     "(run python -m df_llm_helper check).</p>")
    if d.get("forecast"):
        parts.append(f"<p>{e(d['forecast'])}</p>")
    if d.get("alerts"):
        items = []
        for a in d["alerts"]:
            cls, word = LEVEL.get(a.get("level", "warn"), ("yellow", "Warning"))
            items.append(f'<li class="{cls}">{e(word)}: {e(a.get("text") or a.get("label") or a["key"])}</li>')
        parts.append("<h2>Warnings</h2><ul>" + "".join(items) + "</ul>")
    elif last:
        parts.append('<h2>Warnings</h2><p class="ok">No open warnings in the status report.</p>')
    b = d.get("buildings")
    if isinstance(b, dict) and b.get("counts"):
        rows = []
        for item in (cfg or {}).get("buildplan") or BUILDPLAN:
            n = int(b["counts"].get(item["kind"], 0))
            ok = n >= int(item.get("min", 1))
            rows.append(f'<li class="{"ok" if ok else "yellow"}">{"&#10003;" if ok else "&#9675;"} {e(item["name"])} '
                        f'({n}/{item.get("min", 1)})</li>')
        parts.append(f"<h2>Build plan</h2><p class=\"meta\">Building counters {_t(b['ts'])}</p><ul>" + "".join(rows) + "</ul>")
    bn = d.get("bottleneck") or {}
    if bn.get("line") or bn.get("stock"):
        parts.append("<h2>Bottleneck and stock</h2>")
        if bn.get("line"):
            parts.append(f"<p>{e(bn['line'])}</p>")
        st = bn.get("stock") or {}
        flat = [(k, v) for k, v in st.items() if isinstance(v, (int, float))]
        flat += [(f"Bars {k}", v) for k, v in (st.get("bars") or {}).items() if isinstance(v, (int, float))]
        if flat:
            parts.append('<div class="grid">' + "".join(f'<div class="card"><div class="k">{e(k)}</div>'
                                                         f'<div class="v">{e(str(v))}</div></div>' for k, v in flat[:12])
                         + "</div>")
    tr = d.get("trade") or {}
    cv = tr.get("caravan") or {}
    if cv or tr.get("boost") or tr.get("boost_bn"):
        lines = []
        if cv:
            lines.append(f"Caravan: {e(str(cv.get('phase') or cv.get('decision') or '?'))}"
                         + (f", decision {e(str(cv.get('decision')))}" if cv.get("decision") else ""))
        boost = list(dict.fromkeys(list(tr.get("boost") or []) + list(tr.get("boost_bn") or [])))
        if boost:
            lines.append("Buy first: " + e(", ".join(boost)))
        parts.append("<h2>Trade</h2><ul>" + "".join(f"<li>{x}</li>" for x in lines) + "</ul>")
    if d.get("events"):
        rows = "".join(f'<tr><td>{_t(x["ts"])}</td><td class="{LEVEL.get(x["kind"], ("", ""))[0]}">'
                       f'{e(x["text"][:160])}</td></tr>' for x in d["events"])
        parts.append(f"<h2>Events</h2><table>{rows}</table>")
    for label, txt in sorted((d.get("maps") or {}).items()):
        txt = str(txt).replace("\r\n", "\n").replace("\r", "")         # dfhack-run answers with CRLF (BUG-313)
        parts.append(f"<h2>Map {e(label)}</h2><pre>{e(txt)}</pre>")
    parts.append('<p class="meta">Generated by python -m df_llm_helper dashboard from state.db (read only).</p></main></body></html>')
    return "".join(parts)


VOID = {"meta", "br", "img", "input", "link", "hr", "col", "area", "base", "source", "wbr"}
SVG_SELF = {"polyline", "path", "circle", "rect", "line"}


class _Checker(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors = [], []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        if tag not in VOID and tag not in SVG_SELF:
            self.errors.append(f"<{tag}/> unexpected")

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append(f"</{tag}> does not match {self.stack[-1:] or 'nothing'}")
            if tag in self.stack:
                while self.stack and self.stack.pop() != tag:
                    pass
            return
        self.stack.pop()


def validate_html(text: str) -> list[str]:
    """Own structure check: tags balanced, doctype, no external resources."""
    ch = _Checker()
    ch.feed(text)
    ch.close()
    errs = list(ch.errors)
    if ch.stack:
        errs.append("open: " + ",".join(ch.stack))
    if not text.lower().startswith("<!doctype html>"):
        errs.append("doctype missing")
    for bad in ("http://", "https://", "<script src", "<link "):
        if bad in text:
            errs.append(f"external resource: {bad}")
    if len(text.encode("utf-8")) >= 200 * 1024:
        errs.append("larger than 200 KB")
    return errs


def write_if_changed(text: str, out: Path, store) -> bool:
    """Writes unless THIS file already has exactly this content (BUG-312: not one global hash for all paths).
    LF only on every OS. A directory as target raises IsADirectoryError."""
    out = Path(out)
    data = text.encode("utf-8")
    if out.is_dir():
        raise IsADirectoryError(f"--out is a directory, not a file: {out}")
    if out.is_file() and out.read_bytes() == data:
        return False
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    store.set("dashboard.hash", hashlib.sha1(data).hexdigest())
    return True
