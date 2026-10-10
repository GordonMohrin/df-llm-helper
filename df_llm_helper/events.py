"""`dfllm events`: read events.jsonl (CONTRACTS §9.4, §12), plus shared text helpers
(game-time formatting and a conservative token estimate used by status/brief/follow)."""
from __future__ import annotations

import json
import math
import re

from . import files, schema

YEAR, SEASON, DAY = schema.TICKS["YEAR"], schema.TICKS["SEASON"], schema.TICKS["DAY"]
SEASONS = ["spr", "sum", "aut", "win"]
_PIECES = re.compile(r"[A-Za-z]{1,6}|\d{1,3}|[^\sA-Za-z\d]")


def est_tokens(text: str) -> int:
    """Conservative token estimate: max(chars/3.5, word pieces of <=6 letters, 3-digit groups, symbols)."""
    return max(math.ceil(len(text) / 3.5), len(_PIECES.findall(text)))


def clip(text: str, max_tokens: int) -> str:
    """Shorten text (keeping the start) until est_tokens <= max_tokens."""
    if est_tokens(text) <= max_tokens:
        return text
    lo, hi = 0, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if est_tokens(text[:mid] + "~") <= max_tokens:
            lo = mid
        else:
            hi = mid - 1
    return text[:lo].rstrip() + "~"


def fmt_tick(tick: int | None) -> str:
    """Absolute tick -> 'y3 sum d12' (day 1-84 within the season)."""
    if not isinstance(tick, int):
        return "?"
    y, yt = divmod(tick, YEAR)
    return f"y{y} {SEASONS[min(3, yt // SEASON)]} d{(yt % SEASON) // DAY + 1}"


def fmt_ticks(n: int | None) -> str:
    """Duration in ticks -> '450t', '12d', '3.0y'."""
    if not isinstance(n, int) or n < 0:
        return "never"
    if n < DAY:
        return f"{n}t"
    if n < YEAR:
        return f"{n // DAY}d"
    return f"{n / YEAR:.1f}y"


def fmt_age(s: float | None) -> str:
    if s is None:
        return "-"
    s = int(s)
    return f"{s}s" if s < 120 else f"{s // 60}m" if s < 7200 else f"{s // 3600}h"


def fmt_d(d: dict, max_keys: int = 4) -> str:
    if not isinstance(d, dict) or not d:
        return ""
    parts = []
    for k in list(d)[:max_keys]:
        v = d[k]
        parts.append(f"{k}={v if isinstance(v, (int, str)) else json.dumps(v, separators=(',', ':'))}")
    return " ".join(parts)


def fmt_event(e: dict, with_d: bool = True) -> str:
    msg = str(e.get("msg", ""))
    d = fmt_d(e.get("d") or {}) if with_d else ""
    return (f"#{e.get('n')} {fmt_tick(e.get('tick'))} {e.get('cls', '?')} {e.get('type', '?')} {msg}"
            + (f" [{d}]" if d and d not in msg else "")).rstrip()


def run(args, save_dir) -> int:
    cls = args.cls.upper() if args.cls else None
    types = {t.strip().upper() for t in args.type.split(",")} if args.type else None
    evs = files.tail_events(save_dir, since_n=args.since or 0, limit=args.limit or None, cls=cls, types=types)
    for e in evs:
        print(files.dumps(e) if args.json else fmt_event(e))
    if not evs and not args.json:
        print(f"no events (since #{args.since or 0}{', cls ' + cls if cls else ''})")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("events", help="read events.jsonl")
    p.add_argument("--cls", help="classes, e.g. A or AB")
    p.add_argument("--since", type=int, default=0, help="only events with n > N")
    p.add_argument("--type", help="comma-separated event types")
    p.add_argument("--limit", type=int, default=30, help="newest N matches (0 = all)")
    p.add_argument("--json", action="store_true", help="raw JSON lines")
