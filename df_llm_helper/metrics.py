"""F13 metrics and token budget: usage per scope (duration, bytes, approximate tokens), game KPIs as a time series,
CSV export compatible with the header of metrics.csv (semicolon; the column names are the German ones written by
the Lua companion scripts and stay unchanged)."""
from __future__ import annotations

import csv
import io
from datetime import datetime, timezone

from .digest import tokens

__all__ = ["record_usage", "budget_rows", "budget_report", "record_kpis", "export_csv", "METRICS_HEADER"]

METRICS_HEADER = ["echtzeit", "spieldatum", "buerger", "erwachsene", "kinder", "ohne_auftrag", "mahlzeiten",
                  "getraenke", "pflanzen", "tierkadaver", "zwergenleichen", "trupp", "grabjobs", "feinde",
                  "sawdeadbody", "death", "ghosthaunt", "zivilwarnung"]
# KPI name in df-llm-helper -> column in metrics.csv
KPI_COLUMNS = {"pop": "buerger", "adults": "erwachsene", "children": "kinder", "idle": "ohne_auftrag",
               "meals": "mahlzeiten", "drinks": "getraenke", "plants": "pflanzen", "corpses": "zwergenleichen",
               "squad_members": "trupp", "dig_jobs": "grabjobs", "enemies": "feinde", "civ_alert": "zivilwarnung"}
EXTRA_KPIS = ["drink_days", "food_days", "idle_pct", "jobs_open", "fps"]


def record_usage(store, ts: float, scope: str, command: str, duration_s: float, bytes_in: int, text_out: str) -> int:
    t = tokens(text_out)
    store.db.execute("INSERT INTO usage(ts, scope, command, duration_s, bytes_in, bytes_out, tokens) VALUES(?,?,?,?,?,?,?)",
                     (ts, scope, command, duration_s, bytes_in, len(text_out.encode("utf-8")), t))
    return t


def _day(ts: float) -> str:
    return datetime.fromtimestamp(ts).astimezone().strftime("%Y-%m-%d")


def budget_rows(store, now: float) -> list[dict]:
    today, yday = _day(now), _day(now - 86400)
    rows: dict[str, dict] = {}
    for r in store.db.execute("SELECT ts, scope, duration_s, bytes_in, bytes_out, tokens FROM usage"):
        d = _day(r["ts"])
        if d not in (today, yday):
            continue
        e = rows.setdefault(r["scope"], {"scope": r["scope"], "calls": 0, "bytes_in": 0, "bytes_out": 0, "tokens": 0,
                                         "tokens_yday": 0, "seconds": 0.0})
        if d == today:
            e["calls"] += 1
            e["bytes_in"] += r["bytes_in"] or 0
            e["bytes_out"] += r["bytes_out"] or 0
            e["tokens"] += r["tokens"] or 0
            e["seconds"] += r["duration_s"] or 0.0
        else:
            e["tokens_yday"] += r["tokens"] or 0
    for e in rows.values():
        y = e["tokens_yday"]
        e["trend"] = "new" if not y else f"{(e['tokens'] - y) * 100 // y:+d}%"
    return sorted(rows.values(), key=lambda e: (-e["tokens"], e["scope"]))


def budget_report(store, now: float, daily_budget: int) -> tuple[str, bool]:
    rows = budget_rows(store, now)
    total = sum(r["tokens"] for r in rows)
    lines = ["Scope | Calls | Bytes in/out | Tokens | Trend", "---|---|---|---|---"]
    for r in rows:
        lines.append(f"{r['scope']} | {r['calls']} | {r['bytes_in']}/{r['bytes_out']} | {r['tokens']} | {r['trend']}")
    if daily_budget <= 0:                 # no daily budget (0 = off)
        lines.append(f"Total today: {total} tokens (no daily budget set)")
        return "\n".join(lines), False
    over = total > daily_budget
    lines.append(f"Total today: {total} tokens of {daily_budget} ({100 * total // max(1, daily_budget)} %)"
                 + (" - WARNING: daily budget exceeded" if over else ""))
    return "\n".join(lines), over


def record_kpis(store, ts: float, snap) -> int:
    f = snap.facts()
    f["children"] = snap.children
    f["corpses"] = snap.alerts.corpses_unburied
    n = 0
    for k in list(KPI_COLUMNS) + EXTRA_KPIS:
        v = f.get(k)
        if isinstance(v, bool):
            v = int(v)
        if isinstance(v, (int, float)):
            store.db.execute("INSERT INTO kpis(ts, game_date, name, value) VALUES(?,?,?,?)",
                             (ts, snap.date_text or "", k, float(v)))
            n += 1
    return n


def export_csv(store) -> str:
    """One row per measurement time, columns as in metrics.csv; unknown columns empty."""
    rows: dict[float, dict] = {}
    for r in store.db.execute("SELECT ts, game_date, name, value FROM kpis ORDER BY ts, id"):
        e = rows.setdefault(r["ts"], {"echtzeit": datetime.fromtimestamp(r["ts"]).astimezone().strftime("%Y-%m-%d %H:%M:%S"),
                                      "spieldatum": r["game_date"]})
        col = KPI_COLUMNS.get(r["name"])
        if col:
            v = r["value"]
            e[col] = str(int(v)) if float(v).is_integer() else f"{v:.1f}"
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=METRICS_HEADER, delimiter=";", lineterminator="\n", restval="")
    w.writeheader()
    for ts in sorted(rows):
        w.writerow(rows[ts])
    return buf.getvalue()
