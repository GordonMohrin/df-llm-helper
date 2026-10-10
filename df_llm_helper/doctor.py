"""`dfllm doctor`: speed and health from perf.csv, state, heartbeat and events (DESIGN §10, §14). 0 DF calls."""
from __future__ import annotations

import csv
import statistics
from pathlib import Path

from . import files, paths
from .events import fmt_age

WINDOW_S = 600
TPS_MIN = {"PEACE": 450, "SIEGE": 100, "DRILL": 100}     # §14 (PEACE at pop <= 55)
KERN_MS_S, HB_MAX_S, INBOX_STUCK_S = 25, 120, 10
EVENTS_WARN_B = 5 << 20


def read_perf(save_dir: Path, window_s: int = WINDOW_S) -> list[dict]:
    """perf.csv rows (ints; mods as {name: ms}) within window_s of the newest row."""
    rows = []
    try:
        with open(Path(save_dir) / "perf.csv", encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                try:
                    row = {k: int(r[k]) for k in ("wall", "tick", "tps", "pop", "units", "items", "ms_s",
                                                   "gap_max_ms", "gaps3")}
                except (KeyError, TypeError, ValueError):
                    continue
                row["mode"] = r.get("mode") or "?"
                mods = {}
                for part in (r.get("mods") or "").split(";"):
                    k, _, v = part.partition("=")
                    if k and v.lstrip("-").isdigit():
                        mods[k] = int(v)
                row["mods"] = mods
                rows.append(row)
    except OSError:
        return []
    if not rows:
        return []
    newest = max(r["wall"] for r in rows)
    return [r for r in rows if newest - r["wall"] <= window_s]


def perf_summary(rows: list[dict]) -> dict:
    if not rows:
        return {}
    span = max(30, rows[-1]["wall"] - rows[0]["wall"] + 30)
    by_mode: dict[str, list[int]] = {}
    for r in rows:
        by_mode.setdefault(r["mode"], []).append(r["tps"])
    mods: dict[str, int] = {}
    for r in rows:
        for k, v in r["mods"].items():
            mods[k] = mods.get(k, 0) + v
    return {"rows": len(rows), "span_s": span, "last": rows[-1],
            "tps": {m: (int(statistics.median(v)), min(v), max(v)) for m, v in by_mode.items()},
            "ms_s_avg": round(sum(r["ms_s"] for r in rows) / len(rows)), "ms_s_max": max(r["ms_s"] for r in rows),
            "gap_max": max(r["gap_max_ms"] for r in rows), "gaps3": sum(r["gaps3"] for r in rows),
            "mods": sorted(((k, v / span) for k, v in mods.items()), key=lambda x: -x[1])}


def diagnose(save_dir: Path) -> tuple[list[str], list[str]]:
    """(report lines, problems)."""
    d = Path(save_dir)
    out, bad = [], []
    active = paths.active_save()
    hb, age = files.read_heartbeat(d)
    state, info = files.read_state_ex(d)
    out.append(f"doctor {d.name}: ACTIVE={'yes' if active == d.name else active or 'none'} heartbeat {fmt_age(age)}"
               + (f" frame {hb['frame']} {'paused' if hb['paused'] else 'running'}" if hb else "")
               + (f" | state seq {info['seq']} slot {info['slot']}" if state else " | no valid state"))
    if active == d.name and (age is None or age > HB_MAX_S):
        bad.append(f"heartbeat {fmt_age(age)} old (> {HB_MAX_S}s): DF hung or kern stopped")
    if state is None and info.get("errors"):
        bad.append("state unreadable: " + "; ".join(f"{k}: {v}" for k, v in info["errors"].items())[:200])
    s = perf_summary(read_perf(d))
    if s:
        tps = " ".join(f"{m} {med} ({lo}-{hi})" for m, (med, lo, hi) in sorted(s["tps"].items()))
        out.append(f"ticks/s median by mode over {s['span_s'] // 60} min: {tps}; last {s['last']['tps']} "
                   f"pop {s['last']['pop']} units {s['last']['units']} items {s['last']['items']}")
        out.append(f"kernel {s['ms_s_avg']} ms/s avg, {s['ms_s_max']} max (limit {KERN_MS_S}); "
                   f"max frame gap {s['gap_max']} ms; gaps > 3 s: {s['gaps3']}")
        if s["mods"]:
            out.append("modules ms/s: " + " ".join(f"{k} {v:.1f}" for k, v in s["mods"][:8]))
        for m, (med, _, _) in s["tps"].items():
            if m in TPS_MIN and med < TPS_MIN[m] and not (m == "PEACE" and s["last"]["pop"] > 55):
                bad.append(f"{m} median {med} ticks/s < {TPS_MIN[m]}")
        if s["ms_s_avg"] > KERN_MS_S:
            bad.append(f"kernel {s['ms_s_avg']} ms/s > {KERN_MS_S}")
        if s["gaps3"]:
            bad.append(f"{s['gaps3']} frame gap(s) > 3 s in {s['span_s'] // 60} min (autosave?)")
    else:
        out.append("perf.csv: no rows")
    if state:
        k = state["k"]
        out.append(f"state: tps {state['t']['tps']} ms/s {k['ms_s']} gap {k['gap_max_ms']} ms faults {k['faults']}"
                   f" slow {','.join(k['slow']) or '-'} disabled {','.join(k.get('disabled', [])) or '-'}"
                   + (f" ms_max {k['ms_max']}" if "ms_max" in k else ""))
        if k.get("disabled"):
            bad.append(f"disabled modules: {','.join(k['disabled'])}")
    evs = files.tail_events(d, 0, limit=300, types={"KERNEL_SLOW", "KERN_FAULT", "PERF_DEGRADED", "ACT_FAIL"})
    for e in evs[-6:]:
        out.append(f"  #{e['n']} {e['type']}: {e.get('msg', '')}")
    stuck = [n for n, a in files.pending_inbox(d) if a > INBOX_STUCK_S]
    if stuck:
        bad.append(f"{len(stuck)} inbox file(s) older than {INBOX_STUCK_S}s (kern not reading): {stuck[0]}")
    try:
        size = (d / "events.jsonl").stat().st_size
        if size > EVENTS_WARN_B * 1.2:
            bad.append(f"events.jsonl {size >> 20} MB: rotation not happening")
    except OSError:
        pass
    rs = files.read_json(paths.runtime_root() / "restore.json")
    if isinstance(rs, dict) and rs.get("active") and active is None:
        bad.append(f"restore.json active for {rs.get('save')} with no ACTIVE save: settings not restored (crash?)")
    lock = files.read_json(paths.runtime_root() / "live.lock")
    if isinstance(lock, dict):
        out.append(f"live.lock: {lock.get('holder')} {lock.get('purpose')}")
    return out, bad


def run(args, save_dir: Path) -> int:
    lines, bad = diagnose(save_dir)
    for x in lines:
        print(x)
    print("verdict: OK" if not bad else "verdict: " + str(len(bad)) + " problem(s)")
    for b in bad:
        print(f"  - {b}")
    return 1 if bad else 0


def add_parser(sub) -> None:
    sub.add_parser("doctor", help="ticks/s, kernel ms per module, frame gaps, stalls")
