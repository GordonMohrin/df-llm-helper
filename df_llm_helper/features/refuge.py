"""FEATURE-005: `python -m df_llm_helper refuge check|repair` - the alarm burrow must contain reachable water, drink, food
and the hospital.

Run 5 (invasion J125): the refuge burrow "Zuflucht" held no supply; more than 10 citizens died of thirst inside it
(BUG-423). By hand it was extended with the well (139,99,z129), the drink store (117..121,88..92,z132), the food store
(109..113,108..114,z130) and the paths between them.

check [--json]   read only. `claude/pilot_refuge info` (burrow tiles as runs, targets inside and outside the burrow:
                 non-forbidden drink/food tiles with their stockpile, wells, visible water inside the burrow, hospital
                 zones) + `claude/pilot_reach dump` of the burrow box (z slabs). Anchor = hospital zone inside the burrow,
                 else config.ZUFLUCHT.probe, else the largest walkable part of the burrow. BFS from the anchor over burrow
                 tiles only (citizens under the civilian alert stay inside the burrow). Per category water (well or water
                 tile), drink, food, hospital: OK (reached), UNREACHABLE (inside the burrow, no path inside it) or
                 MISSING (nothing inside the burrow), with coordinates.
repair [--apply] BFS from the refuge core (the hospital first) over all walkable tiles to the nearest target of every
                 category that is not OK; the path tiles plus the target rect (stockpile/well/zone) are added to the
                 burrow (`claude/pilot_refuge add`, UI: paint the burrow). Dry run (default) lists the tiles.
check hook       every interval_s: one line when the refuge is not ok; a refuge without reachable water AND drink is a
                 critical warning (the wake filter reports it).
Offline: --grid fixtures/v3/grid/refuge_*.grid (meta @burrow x1 y1 x2 y2 z, @target cat kind x y z x1 y1 x2 y2).
Fair play: only revealed tiles; the only write is the burrow assignment (UI action), dry run by default.
The civilian-alert gate stays in Lua (gefahr.civ_gate + config.REFUGE_REQUIRE_WATER, BUG-423).
"""
from __future__ import annotations

import json
from collections import deque
from dataclasses import dataclass, field

from ._grid import Grid, fmt

__all__ = ["KEY", "DEFAULTS", "CATS", "Target", "Info", "CatStatus", "Result", "parse_info", "info_from_grid",
           "runs_to_tiles", "evaluate", "plan_repair", "Plan", "Refuge", "register", "check_hook", "summary_line"]

KEY = "refuge"
DEFAULTS = {"burrow": "Zuflucht", "require": ["water", "drink", "food", "hospital"], "margin": 3, "z_margin": 1,
            "max_tiles": 600000, "slab_tiles": 150000, "near_targets": 4, "max_rect_tiles": 400, "max_path": 300,
            "max_add_tiles": 3000, "chunk": 150, "interval_s": 900, "in_check": True}
CATS = ("water", "drink", "food", "hospital")
INFO_CMD = "claude/pilot_refuge info"
LINE_MAX = 120


# ---------------------------------------------------------------- data
@dataclass
class Target:
    cat: str
    kind: str
    xyz: tuple
    rect: tuple | None = None          # x1, y1, x2, y2, z
    adjacent: bool = False             # well/water: reached from a neighbouring tile
    in_burrow: bool = False
    n: int = 1

    def label(self) -> str:
        s = f"{fmt(self.xyz)} {self.kind}"
        return s + (f", {self.n} items" if self.kind in ("item", "stockpile") and self.n > 1 else "")

    def rect_tiles(self) -> list:
        if not self.rect:
            return [self.xyz]
        x1, y1, x2, y2, z = self.rect
        return [(x, y, z) for y in range(min(y1, y2), max(y1, y2) + 1) for x in range(min(x1, x2), max(x1, x2) + 1)]


@dataclass
class Info:
    name: str = "Zuflucht"
    tiles: set = field(default_factory=set)
    targets: list = field(default_factory=list)
    anchor: tuple | None = None        # config.ZUFLUCHT.probe
    truncated: bool = False
    supply: dict = field(default_factory=dict)

    def bbox(self, extra=()) -> tuple | None:
        pts = list(self.tiles) + [p for t in extra for p in (t.rect_tiles() if t.rect else [t.xyz])]
        if not pts:
            return None
        xs, ys, zs = [p[0] for p in pts], [p[1] for p in pts], [p[2] for p in pts]
        return min(xs), min(ys), min(zs), max(xs), max(ys), max(zs)


@dataclass
class CatStatus:
    status: str                        # OK | UNREACHABLE | MISSING
    target: Target | None = None
    note: str = ""

    def line(self, cat: str, nearest: Target | None = None) -> str:
        s = f"{cat} {self.status}"
        if self.target is not None:
            s += f" {self.target.label()}"
        if self.status == "UNREACHABLE":
            s += ": inside the burrow, but no path inside the burrow from the anchor"
        elif self.status == "MISSING" and nearest is not None:
            s += f" (nearest outside: {nearest.label()})"
        if self.note:
            s += f" [{self.note}]"
        return s


@dataclass
class Result:
    name: str
    tiles: int
    anchor: tuple | None
    anchor_kind: str
    cats: dict
    checked: bool                       # reachability checked on a tile dump
    require: tuple = CATS
    reached: set = field(default_factory=set)
    note: str = ""

    @property
    def ok(self) -> bool:
        return all(self.cats[c].status == "OK" for c in self.require if c in self.cats)

    @property
    def crit(self) -> bool:
        """No reachable water source and no reachable drink: citizens die of thirst under the alert."""
        return self.cats["water"].status != "OK" and self.cats["drink"].status != "OK"

    def bad(self) -> list:
        return [c for c in self.require if c in self.cats and self.cats[c].status != "OK"]

    def lines(self, info: Info | None = None) -> list:
        how = "BFS inside the burrow" if self.checked else f"reachability NOT checked ({self.note or 'no tile dump'})"
        anc = f"anchor {self.anchor_kind} {fmt(self.anchor)}" if self.anchor else "no anchor (burrow empty?)"
        out = [f"Refuge {self.name}: {self.tiles} tiles, {anc}, {how}"]
        for c in CATS:
            near = None
            if info is not None and self.cats[c].status == "MISSING":
                near = _nearest([t for t in info.targets if t.cat == c and not t.in_burrow], self.anchor)
            out.append(self.cats[c].line(c, near))
        out.append(summary_line(self))
        return out

    def to_dict(self) -> dict:
        return {"burrow": self.name, "tiles": self.tiles, "ok": self.ok, "crit": self.crit, "checked": self.checked,
                "anchor": list(self.anchor) if self.anchor else None, "anchor_kind": self.anchor_kind,
                "categories": {c: {"status": s.status, "where": list(s.target.xyz) if s.target else None,
                                   "kind": s.target.kind if s.target else None, "note": s.note}
                               for c, s in self.cats.items()},
                "require": list(self.require), "note": self.note}


def summary_line(res: Result) -> str:
    if res.ok:
        return f"Refuge {res.name}: OK ({', '.join(res.require)} reachable)"
    by: dict = {}
    for c in res.bad():
        by.setdefault(res.cats[c].status, []).append(c)
    parts = [f"{st} {', '.join(cs)}" for st, cs in sorted(by.items())]
    s = f"{'!! ' if res.crit else ''}Refuge {res.name}: {'; '.join(parts)} -> python -m df_llm_helper refuge repair"
    return s[:LINE_MAX]


# ---------------------------------------------------------------- parsing
def runs_to_tiles(runs) -> set:
    """'z,y,x1,x2' runs of pilot_refuge info -> tile set."""
    out = set()
    for r in runs or []:
        try:
            z, y, x1, x2 = (int(v) for v in str(r).split(","))
        except ValueError:
            continue
        out.update((x, y, z) for x in range(min(x1, x2), max(x1, x2) + 1))
    return out


def _target(d: dict) -> Target | None:
    try:
        xyz = (int(d["x"]), int(d["y"]), int(d["z"]))
    except (KeyError, TypeError, ValueError):
        return None
    cat = str(d.get("cat") or "")
    if cat not in CATS:
        return None
    rect = d.get("rect")
    rect = tuple(int(v) for v in rect) if isinstance(rect, list) and len(rect) == 5 else None
    kind = str(d.get("kind") or "item")
    return Target(cat, kind, xyz, rect, bool(d.get("adjacent")) or kind in ("well", "water"),
                  bool(d.get("in_burrow")), int(d.get("n") or 1))


def parse_info(j) -> Info | None:
    if not isinstance(j, dict) or not j.get("ok"):
        return None
    b = j.get("burrow") or {}
    anc = j.get("anchor")
    info = Info(str(b.get("name") or "Zuflucht"), runs_to_tiles(j.get("tiles")),
                [t for t in (_target(d) for d in (j.get("targets") or []) if isinstance(d, dict)) if t],
                tuple(int(v) for v in anc) if isinstance(anc, list) and len(anc) == 3 else None,
                bool(j.get("truncated")), j.get("supply") or {})
    for t in info.targets:              # Lua tests the zone centre; a hospital zone counts when any of its tiles is assigned
        if t.cat == "hospital" and not t.in_burrow:
            t.in_burrow = any(p in info.tiles for p in t.rect_tiles())
    return info


def info_from_grid(grid: Grid, name: str = "Zuflucht") -> Info:
    """Fixture meta: '@burrow x1 y1 x2 y2 z' (repeatable), '@target cat kind x y z [x1 y1 x2 y2]', '@anchor x y z'."""
    tiles = set()
    for v in grid.meta.get("burrow", []):
        x1, y1, x2, y2, z = (int(a) for a in v[:5])
        tiles.update((x, y, z) for y in range(min(y1, y2), max(y1, y2) + 1) for x in range(min(x1, x2), max(x1, x2) + 1))
    targets = []
    for v in grid.meta.get("target", []):
        cat, kind = v[0], v[1]
        xyz = tuple(int(a) for a in v[2:5])
        rect = (int(v[5]), int(v[6]), int(v[7]), int(v[8]), xyz[2]) if len(v) >= 9 else None
        targets.append(Target(cat, kind, xyz, rect, kind in ("well", "water")))
    info = Info(name, tiles, targets)
    anc = grid.meta.get("anchor")
    if anc:
        info.anchor = tuple(int(a) for a in anc[0][:3])
    _mark_in_burrow(info)
    return info


def _mark_in_burrow(info: Info) -> None:
    for t in info.targets:
        t.in_burrow = t.xyz in info.tiles or (t.cat == "hospital" and any(p in info.tiles for p in t.rect_tiles()))


def _dist(p, q) -> int:
    if p is None or q is None:
        return 0
    return max(abs(p[0] - q[0]), abs(p[1] - q[1]), 3 * abs(p[2] - q[2]))


def _nearest(targets, anchor):
    return min(targets, key=lambda t: (_dist(t.xyz, anchor), t.xyz), default=None)


# ---------------------------------------------------------------- evaluation
def _anchor(info: Info, grid: Grid | None) -> tuple:
    walk = (lambda p: grid.walkable(p)) if grid is not None else (lambda p: True)
    for t in sorted((t for t in info.targets if t.cat == "hospital" and t.in_burrow), key=lambda t: t.xyz):
        tiles = [p for p in t.rect_tiles() if p in info.tiles and walk(p)]
        if tiles:
            tiles.sort(key=lambda p: (_dist(p, t.xyz), p))
            return tiles[0], "hospital"
    if info.anchor and info.anchor in info.tiles and walk(info.anchor):
        return info.anchor, "probe"
    if grid is None:
        return (min(info.tiles), "burrow") if info.tiles else (None, "")
    best: set = set()
    left = {p for p in info.tiles if grid.walkable(p)}
    while left:
        comp = grid.bfs([min(left)], ok=lambda p, ch: p in info.tiles)
        left -= comp
        if len(comp) > len(best):
            best = comp
    return (min(best), "burrow") if best else (None, "")


def evaluate(info: Info, grid: Grid | None, *, require=CATS, note: str = "") -> Result:
    anchor, kind = _anchor(info, grid)
    reached: set = set()
    if grid is not None and anchor is not None:
        reached = grid.bfs([anchor], ok=lambda p, ch: p in info.tiles)
    cats = {}
    for c in CATS:
        inside = sorted((t for t in info.targets if t.cat == c and t.in_burrow), key=lambda t: (_dist(t.xyz, anchor), t.xyz))
        if not inside:
            cats[c] = CatStatus("MISSING")
            continue
        if grid is None or anchor is None:
            cats[c] = CatStatus("OK", inside[0], "not checked" if grid is None else "no anchor")
            continue
        hit = None
        for t in inside:
            if c == "hospital":
                ok = any(p in reached for p in t.rect_tiles())
            else:
                ok = grid.reached(reached, t.xyz, t.adjacent)
            if ok:
                hit = t
                break
        cats[c] = CatStatus("OK", hit) if hit else CatStatus("UNREACHABLE", inside[0])
    return Result(info.name, len(info.tiles), anchor, kind, cats, grid is not None and anchor is not None,
                  tuple(r for r in require if r in CATS), reached, note)


# ---------------------------------------------------------------- repair (BFS from the refuge core)
@dataclass
class Step:
    cat: str
    target: Target | None
    path: list
    tiles: list                         # new tiles (not yet in the burrow)
    note: str = ""

    def line(self) -> str:
        if self.target is None:
            if self.tiles:
                return f"{self.cat}: +{len(self.tiles)} tiles ({self.note})"
            return f"{self.cat}: no plan ({self.note})"
        via = f" path {fmt(self.path[0])}..{fmt(self.path[-1])}" if self.path else ""
        return (f"{self.cat}: {self.target.label()} via {len(self.path)} path tiles{via} -> +{len(self.tiles)} tiles"
                + (f" ({self.note})" if self.note else ""))


@dataclass
class Plan:
    steps: list = field(default_factory=list)
    tiles: list = field(default_factory=list)       # all new tiles in order
    origin: tuple | None = None
    origin_kind: str = ""

    def lines(self) -> list:
        out = [f"Repair plan: {len(self.tiles)} new burrow tiles, BFS from {self.origin_kind or '?'} "
               f"{fmt(self.origin) if self.origin else ''}".rstrip()]
        out += ["  " + s.line() for s in self.steps]
        if self.tiles:                              # every new tile, as row runs (x1..x2,y,zZ)
            runs = []
            for t in self.tokens():
                v = [int(a) for a in t.split(",")]
                runs.append(f"({v[0]},{v[1]},z{v[2]})" if len(v) == 3 else f"({v[0]}..{v[2]},{v[1]},z{v[4]})")
            out.append("  tiles: " + " ".join(runs))
        return out

    def tokens(self) -> list:
        """Row runs 'x1,y,x2,y,z' for pilot_refuge add."""
        rows: dict = {}
        for x, y, z in self.tiles:
            rows.setdefault((z, y), []).append(x)
        out = []
        for (z, y), xs in sorted(rows.items()):
            xs.sort()
            start = prev = xs[0]
            for x in xs[1:] + [None]:
                if x is not None and x == prev + 1:
                    prev = x
                    continue
                out.append(f"{start},{y},{z}" if start == prev else f"{start},{y},{prev},{y},{z}")
                if x is not None:
                    start = prev = x
        return out


def _goals(grid: Grid, t: Target, max_rect: int) -> list:
    if t.cat == "hospital" or (t.rect and len(t.rect_tiles()) <= max_rect and t.kind == "stockpile"):
        tiles = [p for p in t.rect_tiles() if grid.walkable(p)]
        if tiles:
            return tiles
    if t.adjacent or not grid.walkable(t.xyz):
        return grid.ring(t.xyz)
    return [t.xyz]


def _bfs_path(grid: Grid, core: set, goals: dict, max_len: int):
    """Multi-source BFS from the core over walkable tiles -> (path from the core to the first goal, goal) or (None, None)."""
    prev: dict = {p: None for p in core}
    q = deque((p, 0) for p in sorted(core))
    while q:
        p, d = q.popleft()
        if p in goals:
            tgt, path = goals[p], []
            while p is not None and p not in core:
                path.append(p)
                p = prev[p]
            return list(reversed(path)), tgt
        if d >= max_len:
            continue
        for n in grid.neighbors(p):
            if n not in prev:
                prev[n] = p
                q.append((n, d + 1))
    return None, None


def plan_repair(info: Info, grid: Grid, res: Result, cfg: dict | None = None) -> Plan:
    c = {**DEFAULTS, **(cfg or {})}
    max_rect, max_path, max_add = int(c["max_rect_tiles"]), int(c["max_path"]), int(c["max_add_tiles"])
    plan = Plan()
    burrow = set(info.tiles)
    core = set(res.reached)
    plan.origin, plan.origin_kind = res.anchor, res.anchor_kind
    hosp = sorted((t for t in info.targets if t.cat == "hospital"), key=lambda t: (not t.in_burrow, _dist(t.xyz, res.anchor), t.xyz))
    if not core:                                    # no usable burrow part: start at the hospital ("BFS from the hospital")
        start = [p for p in (hosp[0].rect_tiles() if hosp else []) if grid.walkable(p)]
        if not start and info.anchor and grid.walkable(info.anchor):
            start = [info.anchor]
        if not start:
            plan.steps.append(Step("all", None, [], [], "no hospital and no walkable anchor: set config.ZUFLUCHT.probe"))
            return plan
        sset = set(start)
        core = sset | grid.bfs(start[:1], ok=lambda p, ch: p in burrow or p in sset)
        plan.origin, plan.origin_kind = start[0], "hospital" if hosp else "probe"
        new = [p for p in sorted(sset) if p not in burrow]
        if new:
            plan.steps.append(Step("hospital" if hosp else "anchor", hosp[0] if hosp else None, [], new,
                                   "start of the BFS"))
            plan.tiles += new
            burrow.update(new)
    order = [k for k in ("hospital", "water", "drink", "food") if k in res.require]
    for cat in order:
        st = res.cats.get(cat)
        if st is not None and st.status == "OK":
            continue
        if cat == "hospital" and any(t.cat == "hospital" and set(t.rect_tiles()) & core for t in hosp):
            continue
        cands = [t for t in info.targets if t.cat == cat]
        if not cands:
            plan.steps.append(Step(cat, None, [], [], "no target on the revealed map"))
            continue
        goals: dict = {}
        for t in cands:
            for g in _goals(grid, t, max_rect):
                goals.setdefault(g, t)
        path, tgt = _bfs_path(grid, core, goals, max_path)
        if tgt is None:
            plan.steps.append(Step(cat, None, [], [], f"no walkable path within {max_path} tiles in the dump box"))
            continue
        rect = [p for p in _goals(grid, tgt, max_rect) if grid.walkable(p)]
        if tgt.adjacent and grid.get(tgt.xyz) == "W":
            rect.append(tgt.xyz)                    # the well tile itself (painted like the UI would)
        new = []
        for p in path + rect:
            if p not in burrow and p not in new:
                new.append(p)
        if len(plan.tiles) + len(new) > max_add:
            plan.steps.append(Step(cat, tgt, path, [], f"skipped: more than max_add_tiles {max_add}"))
            continue
        note = "" if not tgt.rect or len(tgt.rect_tiles()) <= max_rect or cat == "hospital" else \
            f"stockpile larger than {max_rect} tiles: only the tile and its ring"
        plan.steps.append(Step(cat, tgt, path, new, note))
        plan.tiles += new
        burrow.update(new)
        core.update(path)
        core.update(rect)
    return plan


# ---------------------------------------------------------------- live side
def _slabs(box, slab_tiles: int) -> list:
    x1, y1, z1, x2, y2, z2 = box
    area = (x2 - x1 + 1) * (y2 - y1 + 1)
    per = max(1, slab_tiles // max(1, area))
    out, z = [], z1
    while z <= z2:
        out.append((x1, y1, z, x2, y2, min(z2, z + per - 1)))
        z += per
    return out


class Refuge:
    def __init__(self, client, store, clock, cfg: dict | None = None):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def _run(self, cmd: str):
        from ..client import register_read
        register_read(cmd)
        r = self.client.run(cmd)
        return r.json if r.ok else None

    def info(self) -> Info | None:
        name = str(self.cfg["burrow"])
        return parse_info(self._run(INFO_CMD + ("" if name == "Zuflucht" else f" --name {name}")))

    def dump(self, info: Info, extra=()) -> tuple:
        box = info.bbox(extra)
        if box is None:
            return None, "burrow has no tiles"
        m, zm = int(self.cfg["margin"]), int(self.cfg["z_margin"])
        box = (max(0, box[0] - m), max(0, box[1] - m), max(0, box[2] - zm), box[3] + m, box[4] + m, box[5] + zm)
        total = (box[3] - box[0] + 1) * (box[4] - box[1] + 1) * (box[5] - box[2] + 1)
        if total > int(self.cfg["max_tiles"]):
            return None, f"box {total} tiles > max_tiles {self.cfg['max_tiles']}"
        g = Grid()
        for s in _slabs(box, int(self.cfg["slab_tiles"])):
            j = self._run("claude/pilot_reach dump " + " ".join(str(v) for v in s))
            if not isinstance(j, dict) or not j.get("ok"):
                return None, "claude/pilot_reach dump not readable"
            g.add_dump(j)
        return g, ""

    def near_targets(self, info: Info, res: Result | None = None) -> list:
        k = int(self.cfg["near_targets"])
        anchor = res.anchor if res else (min(info.tiles) if info.tiles else info.anchor)
        out = []
        for c in CATS:
            outside = sorted((t for t in info.targets if t.cat == c and not t.in_burrow),
                             key=lambda t: (_dist(t.xyz, anchor), t.xyz))
            out += outside[:k]
        return out

    def check(self, *, grid: Grid | None = None, info: Info | None = None) -> tuple:
        """-> (info, result, grid) or (None, None, None) when pilot_refuge is not readable."""
        info = info or self.info()
        if info is None:
            return None, None, None
        note = ""
        if grid is None:
            grid, note = self.dump(info)
        if info.truncated:
            note = (note + "; " if note else "") + "burrow tile list truncated (> 40000 runs)"
        return info, evaluate(info, grid, require=tuple(self.cfg["require"]), note=note), grid

    def repair(self, *, apply: bool = False, grid: Grid | None = None, info: Info | None = None) -> tuple:
        info, res, _ = self.check(grid=grid, info=info) if grid is not None else (info or self.info(), None, None)
        if info is None:
            return None, None, ["claude/pilot_refuge info not readable (installed? burrow Zuflucht exists?)"]
        if grid is None:
            grid, note = self.dump(info, self.near_targets(info))
            if grid is None:
                return info, None, [f"repair needs a tile dump: {note}"]
            res = evaluate(info, grid, require=tuple(self.cfg["require"]))
        lines = res.lines(info)
        if res.ok:
            return info, Plan(), lines + ["nothing to repair"]
        plan = plan_repair(info, grid, res, self.cfg)
        lines += plan.lines()
        now = self.clock.now().epoch
        if not plan.tiles:
            return info, plan, lines
        if not apply:
            lines.append(f"[dry] {len(plan.tiles)} tiles would be added to burrow {info.name}: "
                         f"python -m df_llm_helper refuge repair --apply")
            self.store.log_action(now, "refuge", "refuge", "repair", info.name, "claude/pilot_refuge add", True, True,
                                  f"{len(plan.tiles)} tiles")
            return info, plan, lines
        added, ok = 0, True
        toks = plan.tokens()
        chunk = int(self.cfg["chunk"])
        name = str(self.cfg["burrow"])
        for i in range(0, len(toks), chunk):
            cmd = "claude/pilot_refuge add --apply" + ("" if name == "Zuflucht" else f" --name {name}") + " " + \
                  " ".join(toks[i:i + chunk])
            r = self.client.run(cmd)
            j = r.json if r.ok and isinstance(r.json, dict) else {}
            ok = ok and bool(j.get("ok"))
            added += int(j.get("added") or 0)
            self.store.log_action(now, "refuge", "refuge", "repair", info.name, cmd[:200], False, bool(j.get("ok")),
                                  f"added {j.get('added')}")
        lines.append(f"applied: {added} tiles added to burrow {info.name}" + ("" if ok else " (ERRORS, see actions)"))
        return info, plan, lines


# ---------------------------------------------------------------- CLI + check hook
def cmd_refuge(args) -> int:
    from ..cli import _pilot
    p = _pilot(args)
    cfg = {**DEFAULTS, **(p.cfg.get(KEY, {}) or {})}
    if args.burrow:
        cfg["burrow"] = args.burrow
    grid = info = None
    if args.grid:
        grid = Grid.from_file(args.grid)
        info = info_from_grid(grid, cfg["burrow"])
        from ..store import Store
        p.store = Store()                          # an offline fixture run never touches the fort's state.db
    rf = Refuge(p.client, p.store, p.clock, cfg)
    if args.action == "check":
        info, res, _ = rf.check(grid=grid, info=info)
        if res is None:
            print("claude/pilot_refuge info not readable (lua/pilot_refuge.lua installed? burrow exists?)")
            return 2
        if not args.grid:
            _remember(p, res, dry=False)
        if args.json:
            print(json.dumps({**res.to_dict(), "lines": res.lines(info)}, ensure_ascii=False))
        else:
            print("\n".join(res.lines(info)))
        return 0 if res.ok else 1
    if args.apply and args.grid:
        raise ValueError("refuge repair --apply works on the live game only (not with --grid)")
    info, plan, lines = rf.repair(apply=args.apply, grid=grid, info=info)
    if args.json:
        print(json.dumps({"lines": lines, "tiles": [list(t) for t in (plan.tiles if plan else [])],
                          "tokens": plan.tokens() if plan else []}, ensure_ascii=False))
    else:
        print("\n".join(lines))
    return 0 if plan is not None else 2


def register(sub) -> None:
    import argparse
    s = sub.add_parser("refuge", help="alarm burrow: check (reachable water/drink/food/hospital) | repair [--apply]",
                       description="FEATURE-005: does the refuge burrow contain reachable water, drink, food and the "
                                   "hospital? repair extends it along a BFS path (dry run by default).",
                       epilog="examples:\n  python -m df_llm_helper refuge check\n  python -m df_llm_helper refuge check "
                              "--json\n  python -m df_llm_helper refuge repair\n  python -m df_llm_helper refuge repair "
                              "--apply\n  python -m df_llm_helper refuge check --grid fixtures/v3/grid/refuge_j125.grid",
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    s.add_argument("action", nargs="?", default="check", choices=["check", "repair"])
    s.add_argument("--json", action="store_true", help="JSON output")
    s.add_argument("--apply", action="store_true", help="repair: add the tiles to the burrow (UI: paint the burrow)")
    s.add_argument("--burrow", default=None, help="burrow name (default refuge.burrow = Zuflucht)")
    s.add_argument("--grid", default=None, help="offline: grid fixture with @burrow/@target lines instead of live DF")
    s.set_defaults(fn=cmd_refuge)


def _remember(pilot, res: Result, *, dry: bool) -> None:
    if dry:
        return
    now = pilot.clock.now().epoch
    pilot.store.set("refuge.last_ts", now)
    pilot.store.set("refuge.last", {"ok": res.ok, "crit": res.crit, "line": summary_line(res), "ts": now,
                                    "bad": res.bad(), "checked": res.checked})
    if not res.ok:
        pilot.store.warn(now, "refuge", "refuge:check", summary_line(res).removeprefix("!! "),
                         "crit" if res.crit else "warn")


def check_hook(pilot, report, dry: bool) -> list:
    """Every interval_s a full check; between them the last result. One line while the refuge is not ok."""
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    last_ts = pilot.store.get("refuge.last_ts")
    if last_ts is not None and now - float(last_ts) < float(cfg["interval_s"]):
        last = pilot.store.get("refuge.last") or {}
        return [] if last.get("ok", True) else [str(last.get("line"))[:LINE_MAX]]
    info, res, _ = Refuge(pilot.client, pilot.store, pilot.clock, cfg).check()
    if res is None:
        return []
    _remember(pilot, res, dry=dry)
    return [] if res.ok else [summary_line(res)]

