"""Spec v3-11: reachability watcher (`python -m df_llm_helper reach`).

Run 5 (J105-J110): the emergency plugs P1 (101,99,z130) and P2 (100,94,z132) cut the stair column and with it every
farm hall, the kitchens and the stills off the fort for years ("Needs plump helmet spawn" 493x, 43 dwarves).

- check:   canWalkBetween(start, point) for every watch point in ONE Lua call (lua/pilot_reach.lua check, cheap)
- cause:   for unreachable mandatory points a tile dump of the surrounding box (pilot_reach dump) and a path search
           with/without constructions (0-1 BFS, _grid.Grid.cutting_constructions) -> which construction cuts the way
- what-if: `reach what-if --wall x y z` before a wall/plug is built (perimeter seal always calls it)
- correlate: gamelog cancels ("Needs ... spawn", "Could not find path") are attributed to a point category
Read only. Points: data/reach.yaml (example values from run 5).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path

from ._grid import Grid, fmt

__all__ = ["KEY", "DEFAULTS", "Point", "load_points", "points_from_grid", "measure_grid", "parse_check",
           "find_causes", "what_if_grid", "correlate", "digest_line", "ReachWatch", "register", "check_hook",
           "LINE_MAX"]

KEY = "reach"
DEFAULTS = {"start": [100, 101, 130], "points_file": "data/reach.yaml", "interval_s": 300,
            "mandatory": ["farm", "kitchen", "still", "well", "hospital", "barracks"], "margin": 6,
            "max_tiles": 150000, "cancel_min": 20, "in_check": True}
LINE_MAX = 120

# gamelog job/reason keywords -> point category (spec 5: chain of effects)
CAT_JOBS = {
    "farm": ("plant seed", "harvest", "spawn", "seeds", "till"),
    "kitchen": ("prepare", "meal", "cook"),
    "still": ("brew",),
    "well": ("water", "well"),
    "hospital": ("diagnos", "surgery", "set bone", "suture", "dress wound", "clean patient", "apply cast"),
    "barracks": ("train", "drill"),
    "depot": ("depot", "trade"),
    "workshop": ("construct", "forge", "smelt", "make "),
}
PATH_REASONS = ("could not find path", "no path", "unreachable")
NEED_REASON = ("spawn", "seed")       # "Needs plump helmet spawn": the seeds lie in a stockpile that cannot be reached


@dataclass(frozen=True)
class Point:
    name: str
    xyz: tuple
    cat: str = ""
    mandatory: bool = True
    adjacent: bool = False      # the point is a building tile (well, ...): reached from a neighbouring tile

    def label(self) -> str:
        return f"{self.name} {fmt(self.xyz)}"


def _as_point(d: dict, mandatory_cats) -> Point | None:
    xyz = d.get("xyz") or d.get("pos")
    if not d.get("name") or not isinstance(xyz, list) or len(xyz) != 3:
        return None
    cat = str(d.get("cat") or "")
    if "mandatory" in d:
        mand = bool(d["mandatory"])
    else:
        mand = cat in (mandatory_cats or []) and not d.get("optional", False)
    return Point(str(d["name"]), tuple(int(v) for v in xyz), cat, mand, bool(d.get("adjacent", False)))


def load_points(path, mandatory_cats=None) -> tuple:
    """data/reach.yaml -> (start or None, [Point])."""
    from .. import yamlmini
    p = Path(path)
    if not p.exists():
        return None, []
    data = yamlmini.load_file(p) or {}
    pts = [q for q in (_as_point(d, mandatory_cats) for d in (data.get("points") or []) if isinstance(d, dict)) if q]
    start = data.get("start")
    return (tuple(int(v) for v in start) if isinstance(start, list) and len(start) == 3 else None), pts


def points_from_grid(grid: Grid, mandatory_cats) -> tuple:
    """Fixture meta lines '@core x y z' and '@point name x y z cat' -> (start, [Point])."""
    core = grid.meta.get("core", [[None]])[0]
    start = tuple(int(v) for v in core) if None not in core else None
    pts = [Point(v[0], (int(v[1]), int(v[2]), int(v[3])), v[4] if len(v) > 4 else "",
                 (v[4] if len(v) > 4 else "") in (mandatory_cats or [])) for v in grid.meta.get("point", [])]
    return start, pts


def measure_grid(grid: Grid, start, points) -> dict:
    """Reference implementation of the Lua check on a grid: name -> reachable."""
    reach = grid.bfs([start])
    return {p.name: grid.reached(reach, p.xyz, p.adjacent) for p in points}


def parse_check(j, points) -> dict:
    """Response of pilot_reach check -> name -> True/False/None (None = not readable)."""
    if not isinstance(j, dict) or not j.get("ok") or not isinstance(j.get("results"), list):
        return {p.name: None for p in points}
    res = j["results"]
    bad = set(j.get("invalid") or [])            # unparsable point arguments (0-based), BUG-409
    return {p.name: (bool(res[i]) if i < len(res) and i not in bad else None) for i, p in enumerate(points)}


def find_causes(grid: Grid, start, points) -> dict:
    """name -> constructions on the cheapest path ([] = reachable in the grid, None = no path even without constructions)."""
    return {p.name: grid.cutting_constructions(start, p.xyz, adjacent=p.adjacent) for p in points}


@dataclass
class WhatIf:
    cut: list = field(default_factory=list)          # mandatory points that the walls would cut off
    uncertain: list = field(default_factory=list)    # reachable live, but not inside the dump box -> cannot prove
    walls: list = field(default_factory=list)

    @property
    def safe(self) -> bool:
        return not self.cut and not self.uncertain

    def lines(self) -> list:
        w = ", ".join(fmt(x) for x in self.walls[:4]) + (f" +{len(self.walls) - 4}" if len(self.walls) > 4 else "")
        if self.safe:
            return [f"what-if {w}: no mandatory point is cut off"]
        out = []
        if self.cut:
            out.append(f"!! what-if {w}: would CUT OFF {', '.join(p.label() for p in self.cut)}"[:LINE_MAX * 2])
        if self.uncertain:
            out.append(f"what-if {w}: cannot prove {', '.join(p.name for p in self.uncertain)} (path leaves the box)")
        return out


def what_if_grid(grid: Grid, start, points, walls, live: dict | None = None) -> WhatIf:
    """Walls (constructed 'C') on the grid; mandatory points reachable before and not after -> cut."""
    walls = [tuple(w) for w in walls]
    before = grid.bfs([start])
    after = grid.with_changes({w: "C" for w in walls}).bfs([start])
    res = WhatIf(walls=walls)
    for p in points:
        if not p.mandatory:
            continue
        was, now = grid.reached(before, p.xyz, p.adjacent), grid.reached(after, p.xyz, p.adjacent)
        if was and not now:
            res.cut.append(p)
        elif not was and live and live.get(p.name):
            res.uncertain.append(p)
    return res


@dataclass
class Correlation:
    cat: str
    count: int
    who: int
    jobs: list
    points: list           # names of unreachable points of this category
    verdict: str

    def line(self) -> str:
        job = self.jobs[0] if self.jobs else "?"
        pts = ", ".join(self.points) if self.points else "no unreachable point"
        return f"{self.cat}: {self.count}x '{job}' ({self.who} dwarves) -> {pts}: {self.verdict}"[:LINE_MAX * 2]


def correlate(lines, points, unreachable: set, min_count: int = 20) -> list:
    """Gamelog cancels with path/need reasons -> category -> unreachable points of that category."""
    from ..anomaly import cancel_loops
    by_cat: dict = {}
    for c in cancel_loops(lines, min_count=1):
        reason = c.reason.lower()
        if not (reason.startswith(PATH_REASONS) or (reason.startswith("needs ") and any(k in reason for k in NEED_REASON))):
            continue
        text = f"{c.job} {c.reason}".lower()
        cat = next((k for k, kws in CAT_JOBS.items() if any(kw in text for kw in kws)), None)
        if cat is None:
            continue
        e = by_cat.setdefault(cat, {"count": 0, "who": 0, "jobs": []})
        e["count"] += c.count
        e["who"] = max(e["who"], c.who)
        e["jobs"].append(f"{c.job}: {c.reason}")
    out = []
    for cat, e in sorted(by_cat.items(), key=lambda kv: -kv[1]["count"]):
        pts = [p.name for p in points if p.cat == cat and p.name in unreachable]
        if pts and e["count"] >= min_count:
            verdict = "cause certain (point unreachable + many cancels)"
        elif pts:
            verdict = "cause likely"
        else:
            verdict = "points reachable - other cause"
        out.append(Correlation(cat, e["count"], e["who"], e["jobs"], pts, verdict))
    return out


def digest_line(points, status: dict, causes: dict | None = None) -> str:
    mand = [p for p in points if p.mandatory]
    bad = [p for p in mand if status.get(p.name) is False]
    unk = [p for p in mand if status.get(p.name) is None]
    if not bad:
        s = f"Reachable: {len(mand) - len(unk)}/{len(mand)} mandatory points"
        return s + (f" ({len(unk)} not readable)" if unk else "")
    groups: dict = {}
    for p in bad:
        cut = (causes or {}).get(p.name)
        key = fmt(cut[0]) if cut else ("?" if cut is None else "no construction")
        groups.setdefault(key, []).append(p.name)
    parts = []
    for key, names in groups.items():
        parts.append(f"{', '.join(names)} (cut at {key})" if key not in ("?", "no construction") else
                     f"{', '.join(names)} (cause unknown)")
    s = "UNREACHABLE: " + "; ".join(parts)
    if len(s) > LINE_MAX:
        s = s[:LINE_MAX - 1].rstrip() + "…"
    return s


def _bbox(points, start, margin: int):
    xs = [p[0] for p in points] + [start[0]]
    ys = [p[1] for p in points] + [start[1]]
    zs = [p[2] for p in points] + [start[2]]
    return (min(xs) - margin, min(ys) - margin, min(zs) - 1, max(xs) + margin, max(ys) + margin, max(zs) + 1)


class ReachWatch:
    def __init__(self, client, store, clock, cfg: dict | None = None, *, points=None, start=None, home=None):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        if points is None:
            from ..config import HOME
            pf = Path(self.cfg["points_file"])
            if not pf.is_absolute():
                pf = Path(home or HOME) / pf
            fstart, points = load_points(pf, self.cfg["mandatory"])
            start = start or fstart
        self.points = list(points)
        self.start = tuple(start or self.cfg["start"])

    # ---- live calls (pilot_reach.lua)
    def _run(self, cmd: str):
        from ..client import register_read
        register_read(cmd)                                   # pure read command (no write effect)
        r = self.client.run(cmd)
        return r.json if r.ok else None

    def measure(self) -> dict:
        if not self.points:
            return {}
        s = self.start
        cmd = f"claude/pilot_reach check {s[0]} {s[1]} {s[2]} " + " ".join(",".join(map(str, p.xyz)) + ("+" if p.adjacent else "") for p in self.points)
        return parse_check(self._run(cmd), self.points)

    def dump(self, box) -> Grid | None:
        x1, y1, z1, x2, y2, z2 = box
        if (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1) > int(self.cfg["max_tiles"]):
            return None
        j = self._run(f"claude/pilot_reach dump {x1} {y1} {z1} {x2} {y2} {z2}")
        return Grid.from_dump(j) if isinstance(j, dict) and j.get("ok") else None

    def grid_for(self, points) -> Grid | None:
        return self.dump(_bbox([p.xyz for p in points], self.start, int(self.cfg["margin"])))

    # ---- evaluation
    def run(self, *, dry: bool = False, gamelog_lines=None, grid: Grid | None = None) -> tuple:
        """Measure + cause search + correlation. Returns (status, causes, lines)."""
        t0 = time.time()
        now = self.clock.now().epoch
        status = measure_grid(grid, self.start, self.points) if grid is not None else self.measure()
        bad = [p for p in self.points if p.mandatory and status.get(p.name) is False]
        causes: dict = {}
        if bad:
            g = grid if grid is not None else self.grid_for(bad)
            if g is not None:
                causes = find_causes(g, self.start, bad)
        lines = [digest_line(self.points, status, causes)]
        for p in bad:
            cut = causes.get(p.name)
            if cut:
                lines.append(f"{p.label()}: cut by construction {', '.join(fmt(c) for c in cut)} -> remove it "
                             f"(designate 'remove construction') or replace it with a door")
            elif cut is None and causes:
                lines.append(f"{p.label()}: no path even without constructions (natural wall/unrevealed/box)")
        if gamelog_lines:
            for c in correlate(gamelog_lines, self.points, {p.name for p in bad}, int(self.cfg["cancel_min"])):
                if c.points:
                    lines.append(c.line())
        if not dry:
            key = "reach:unreachable"
            if bad:
                self.store.warn(now, "reach", key, lines[0], "crit")
            self.store.set("reach.last", {"ts": now, "bad": [p.name for p in bad], "line": lines[0]})
            self.store.set("reach.last_ts", now)
        self.store.log_action(now, "reach", "reach", "measure", "reach", "claude/pilot_reach check", dry, not bad,
                              f"{lines[0][:100]} ({(time.time() - t0) * 1000:.0f} ms)")
        return status, causes, lines

    def what_if(self, walls, *, grid: Grid | None = None, dry: bool = False) -> WhatIf:
        mand = [p for p in self.points if p.mandatory]
        live = None
        if grid is None:
            live = self.measure()
            grid = self.dump(_bbox([p.xyz for p in mand] + [tuple(w) for w in walls], self.start,
                                   int(self.cfg["margin"])))
            if grid is None:
                return WhatIf(uncertain=mand, walls=[tuple(w) for w in walls])
        res = what_if_grid(grid, self.start, mand, walls, live)
        self.store.log_action(self.clock.now().epoch, "reach", "reach", "what-if", "reach",
                              " ".join(fmt(w) for w in walls)[:200], dry, res.safe, "; ".join(res.lines())[:200])
        return res


# ---------------------------------------------------------------- CLI + check hook

def _watch(p, args=None) -> ReachWatch:
    cfg = p.cfg.get(KEY, {}) or {}
    pts = None
    start = None
    if args is not None and getattr(args, "grid", None):
        g = Grid.from_file(args.grid)
        start, pts = points_from_grid(g, {**DEFAULTS, **cfg}["mandatory"])
    elif args is not None and getattr(args, "points", None):
        start, pts = load_points(args.points, {**DEFAULTS, **cfg}["mandatory"])
    return ReachWatch(p.client, p.store, p.clock, cfg, points=pts, start=start)


def cmd_reach(args) -> int:
    from ..cli import _pilot
    p = _pilot(args)
    w = _watch(p, args)
    grid = Grid.from_file(args.grid) if getattr(args, "grid", None) else None
    if args.action == "points":
        for q in w.points:
            print(f"{'*' if q.mandatory else ' '} {q.label()} [{q.cat}]")
        print(f"start {fmt(w.start)}; * = mandatory")
        return 0
    if args.action == "what-if":
        walls = [tuple(int(v) for v in t) for t in (args.wall or [])]
        if not walls:
            print("what-if needs --wall x y z")
            return 2
        res = w.what_if(walls, grid=grid, dry=True)
        print("\n".join(res.lines()))
        return 0 if res.safe else 1
    lines = []
    gl = []
    if args.gamelog:
        from ..toolsfs import read_text_tolerant
        gl = read_text_tolerant(Path(args.gamelog)).splitlines()
    elif args.action == "correlate":
        gl = p.gamelog().recent()
    status, causes, lines = w.run(dry=args.dry_run, gamelog_lines=gl, grid=grid)
    if args.action == "correlate":
        bad = {k for k, v in status.items() if v is False}
        cs = correlate(gl, w.points, bad, int(w.cfg["cancel_min"]))
        lines = [c.line() for c in cs] or ["no path/need cancels in the gamelog"]
    print("\n".join(lines))
    return 1 if any(v is False for q, v in ((q, status.get(q.name)) for q in w.points) if q.mandatory) else 0


def register(sub) -> None:
    s = sub.add_parser("reach", help="Reachability watcher (spec v3-11): check|what-if|correlate|points")
    s.add_argument("action", nargs="?", default="check", choices=["check", "what-if", "correlate", "points"])
    s.add_argument("--wall", nargs=3, action="append", metavar=("X", "Y", "Z"), help="what-if: planned wall (repeatable)")
    s.add_argument("--points", help="points file instead of reach.points_file")
    s.add_argument("--grid", help="offline: grid fixture (fixtures/v3/grid/*.grid) instead of live DF")
    s.add_argument("--gamelog", help="gamelog excerpt for the correlation")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_reach)


def check_hook(pilot, report, dry: bool) -> list:
    """Every interval_s: measure; lines only while mandatory points are unreachable or when that changes."""
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    last = pilot.store.get("reach.last_ts")
    if last is not None and now - float(last) < float(cfg["interval_s"]):
        return []
    prev = (pilot.store.get("reach.last") or {}).get("bad")
    w = ReachWatch(pilot.client, pilot.store, pilot.clock, cfg)
    if not w.points:
        return []
    try:
        gl = pilot.gamelog().recent()
    except Exception:
        gl = []
    status, causes, lines = w.run(dry=dry, gamelog_lines=gl)
    if all(v is None for v in status.values()):
        return []
    bad = [k for k, v in status.items() if v is False and any(q.name == k and q.mandatory for q in w.points)]
    if bad:
        return [ln[:LINE_MAX] for ln in lines[:3]]
    if prev:
        return [lines[0] + " (again)"]
    return []
