"""Dig planner (SPEC F11.2): order of dig designations for one z level, pure functions.

Input is the character grid of ``claude/area`` (see ``fixtures/run5/area_z130.txt``):
``#`` rock, ``,`` soil, ``*`` ore/vein (diggable), ``.`` floor and other floor characters (walkable), ``?`` undiscovered,
``d`` existing dig order (counts as "already planned area"), buildings ``W``/``w``/``B`` block.

Rules
- Neighborhood = 4-neighbors (conservative; diagonal digging is not assumed).
- A wall tile is diggable if it borders walkable or already planned area (BFS over the targets).
- Priority: smaller number = earlier. With ``inherit_priority`` a tile inherits the priority of the most important
  target reached through it (on the shortest path), so that access tiles do not end up behind minor things.
- Order: (inherited priority, distance from open area, y, x) -> deterministic.
- Batch size <= min(max_open, 10 * picks) (minus jobs already open in the first batch).
- Optional ``access=True``: non-adjacent targets are connected via the shortest path through diggable rock
  (access tiles are listed in ``DigPlan.access``).
"""
from __future__ import annotations

import heapq
import re
from collections import deque
from dataclasses import dataclass, field
from typing import Iterable, Optional, Sequence, Union

__all__ = ["Area", "DigTarget", "DigPlan", "parse_area", "plan_dig", "batch_to_csv", "WALKABLE", "DIGGABLE"]

Tile = tuple[int, int]

# walkable characters (assumption, verify live: furniture 'n' and buildings W/w/B count as blocking)
WALKABLE = frozenset('."o+<>X^vSfDb@!at')
DIGGABLE = frozenset("#,*")
DESIGNATED = "d"
_INF = 10 ** 9
_HEADER = re.compile(r"z\s*=\s*(-?\d+)\s+x\s*=\s*(-?\d+)\s*\.\.\s*(-?\d+)\s+y\s*=\s*(-?\d+)\s*\.\.\s*(-?\d+)")
_MAPSIZE = re.compile(r"(?:Karte|Map)\s+(\d+)x(\d+)x(\d+)")


@dataclass
class Area:
    z: int
    x0: int
    y0: int
    rows: list[str]
    map_size: Optional[tuple[int, int, int]] = None

    @property
    def width(self) -> int:
        return max((len(r) for r in self.rows), default=0)

    @property
    def height(self) -> int:
        return len(self.rows)

    def get(self, x: int, y: int) -> Optional[str]:
        """Character at an absolute coordinate; None outside the grid."""
        ry, rx = y - self.y0, x - self.x0
        if 0 <= ry < len(self.rows) and 0 <= rx < len(self.rows[ry]):
            return self.rows[ry][rx]
        return None


@dataclass(frozen=True)
class DigTarget:
    x: int
    y: int
    priority: int = 0


@dataclass
class DigPlan:
    batches: list[list[Tile]]
    unreachable: list[Tile]
    notes: list[str] = field(default_factory=list)
    skipped: list[tuple[Tile, str]] = field(default_factory=list)   # (tile, reason): duplicate/already_open/already_designated
    reasons: dict[Tile, str] = field(default_factory=dict)          # reason per unreachable tile
    access: list[Tile] = field(default_factory=list)                # added access tiles (access=True)
    z: Optional[int] = None

    @property
    def order(self) -> list[Tile]:
        return [t for b in self.batches for t in b]


def parse_area(text: str) -> Area:
    """Parses the output of ``claude/area`` (header line with offsets, ruler, rows ``%4d <characters>``)."""
    lines = text.splitlines()
    m = None
    start = 0
    for i, line in enumerate(lines):
        m = _HEADER.search(line)
        if m:
            start = i + 1
            break
    if not m:
        raise ValueError("header line 'z=.. x=..a..b y=..c..d' not found")
    z, x0, x1, y0, y1 = (int(g) for g in m.groups())
    if x1 < x0 or y1 < y0:
        raise ValueError("invalid range in the header line")
    ms = _MAPSIZE.search(lines[start - 1])
    map_size = tuple(int(g) for g in ms.groups()) if ms else None
    width = x1 - x0 + 1
    rows: dict[int, str] = {}
    for line in lines[start:]:
        label = line[:4].strip()
        if not label.lstrip("-").isdigit() or len(line) < 5 or line[4] != " ":
            continue   # ruler, legend, blank lines
        y = int(label)
        if y0 <= y <= y1 and y not in rows:
            rows[y] = line[5:5 + width].ljust(width)
    missing = [y for y in range(y0, y1 + 1) if y not in rows]
    if missing:
        raise ValueError(f"rows missing: y={missing[0]}..{missing[-1]} ({len(missing)} rows)")
    return Area(z=z, x0=x0, y0=y0, rows=[rows[y] for y in range(y0, y1 + 1)], map_size=map_size)  # type: ignore[arg-type]


def _norm_targets(targets: Iterable[Union[DigTarget, Sequence[int]]]) -> list[DigTarget]:
    out = []
    for t in targets:
        if isinstance(t, DigTarget):
            out.append(t)
        elif len(t) == 2:
            out.append(DigTarget(int(t[0]), int(t[1]), 0))
        elif len(t) == 3:
            out.append(DigTarget(int(t[0]), int(t[1]), int(t[2])))
        else:
            raise ValueError(f"target {t!r}: (x, y) or (x, y, prio) expected")
    return out


def _neighbors(t: Tile) -> list[Tile]:
    x, y = t
    return [(x, y - 1), (x - 1, y), (x + 1, y), (x, y + 1)]


def plan_dig(grid: Union[Area, Sequence[str]], targets: Iterable[Union[DigTarget, Sequence[int]]], *,
             starts: Optional[Iterable[Tile]] = None, picks: int = 1, max_open: int = 150,
             origin: Tile = (0, 0), open_jobs: Optional[int] = None,
             walkable: Iterable[str] = WALKABLE, diggable: Iterable[str] = DIGGABLE,
             inherit_priority: bool = True, access: bool = False) -> DigPlan:
    """Planner core, see the module docs. Coordinates of targets/starts are absolute (grid origin = ``origin`` or Area)."""
    area = grid if isinstance(grid, Area) else Area(z=0, x0=origin[0], y0=origin[1], rows=list(grid))
    walk, dig = frozenset(walkable), frozenset(diggable)
    notes: list[str] = []
    skipped: list[tuple[Tile, str]] = []
    reasons: dict[Tile, str] = {}

    # --- normalize targets (duplicates -> smallest priority), sort deterministically
    prio: dict[Tile, int] = {}
    for t in _norm_targets(targets):
        key = (t.x, t.y)
        if key in prio:
            skipped.append((key, "duplicate"))
            prio[key] = min(prio[key], t.priority)
        else:
            prio[key] = t.priority

    # --- open area: walkable (connected to the starts) + existing orders
    def is_open(t: Tile) -> bool:
        c = area.get(*t)
        return c is not None and (c in walk or c == DESIGNATED)

    cells = [(cx + area.x0, ry + area.y0, ch) for ry, row in enumerate(area.rows) for cx, ch in enumerate(row)]
    designated = [(x, y) for x, y, ch in cells if ch == DESIGNATED]
    if starts is None:
        region = {(x, y) for x, y, ch in cells if ch in walk or ch == DESIGNATED}
    else:
        region = set()
        queue: deque[Tile] = deque()
        for s in sorted(set(tuple(s) for s in starts)):  # type: ignore[arg-type]
            if is_open(s):
                region.add(s)
                queue.append(s)
            else:
                notes.append(f"start point {s} not walkable, ignored")
        while queue:
            cur = queue.popleft()
            for n in _neighbors(cur):
                if n not in region and is_open(n):
                    region.add(n)
                    queue.append(n)
        if not region:
            notes.append("no valid start point: nothing reachable")

    # --- classify targets
    pending: dict[Tile, int] = {}
    for t in sorted(prio, key=lambda k: (prio[k], k[1], k[0])):
        c = area.get(*t)
        if c is None:
            reasons[t] = "outside"
        elif c == DESIGNATED:
            skipped.append((t, "already_designated"))
        elif c in walk:
            skipped.append((t, "already_open"))
        elif c == "?":
            reasons[t] = "unknown"
        elif c not in dig:
            reasons[t] = f"not_diggable:{c!r}"
        else:
            pending[t] = prio[t]

    def bfs(sources: Iterable[Tile], nodes: Union[dict, set, frozenset]) -> dict[Tile, int]:
        """Distance (in tiles) of the nodes from the open area; adjacent nodes have distance 1."""
        dist: dict[Tile, int] = {}
        q: deque[Tile] = deque()
        for s in sorted(sources):
            for n in _neighbors(s):
                if n in nodes and n not in dist:
                    dist[n] = 1
                    q.append(n)
        while q:
            cur = q.popleft()
            for n in _neighbors(cur):
                if n in nodes and n not in dist:
                    dist[n] = dist[cur] + 1
                    q.append(n)
        return dist

    open_area = region | set(designated)
    dist = bfs(open_area, pending)
    access_tiles: list[Tile] = []
    stray = [t for t in pending if t not in dist]
    if stray and access:
        # shortest path through diggable rock (without '?') from the open area
        rock = {(x, y) for x, y, ch in cells if ch in dig}
        parent: dict[Tile, Optional[Tile]] = {}
        q2: deque[Tile] = deque()
        for s in sorted(open_area):
            for n in _neighbors(s):
                if n in rock and n not in parent:
                    parent[n] = None
                    q2.append(n)
        while q2:
            cur = q2.popleft()
            for n in _neighbors(cur):
                if n in rock and n not in parent:
                    parent[n] = cur
                    q2.append(n)
        for t in sorted(stray, key=lambda k: (pending[k], k[1], k[0])):
            if t not in parent:
                continue
            cur: Optional[Tile] = t
            while cur is not None:
                if cur not in pending:
                    pending[cur] = _INF       # priority is inherited via the distance
                    access_tiles.append(cur)
                cur = parent[cur]
        dist = bfs(open_area, pending)
        stray = [t for t in pending if t not in dist]
    for t in sorted(stray, key=lambda k: (k[1], k[0])):
        reasons[t] = "not_adjacent"
        del pending[t]
    if access_tiles:
        notes.append(f"{len(access_tiles)} access tiles added")

    # --- inherited priority: from the farthest distance to the nearest along shortest paths
    eff = dict(pending)
    if inherit_priority:
        for t in sorted(pending, key=lambda k: (-dist[k], k[1], k[0])):
            for n in _neighbors(t):
                if n in pending and dist[n] == dist[t] + 1 and eff[n] < eff[t]:
                    eff[t] = eff[n]

    # --- Prim-like order: only tiles that border open/already planned area
    order: list[Tile] = []
    heap: list[tuple[int, int, int, int]] = []
    queued: set[Tile] = set()
    for t in pending:
        if dist[t] == 1:
            heapq.heappush(heap, (eff[t], 1, t[1], t[0]))
            queued.add(t)
    while heap:
        _, _, y, x = heapq.heappop(heap)
        order.append((x, y))
        for n in _neighbors((x, y)):
            if n in pending and n not in queued:
                heapq.heappush(heap, (eff[n], dist[n], n[1], n[0]))
                queued.add(n)

    # --- batches
    cap = min(max_open, 10 * picks)
    jobs = len(designated) if open_jobs is None else open_jobs
    batches: list[list[Tile]] = []
    if cap <= 0:
        notes.append("no pick carriers or max_open <= 0: nothing plannable" if order else "no pick carriers")
    elif order:
        first = cap - jobs
        i = 0
        if first <= 0:
            notes.append(f"{jobs} open jobs >= batch size {cap}: first batch only after they are worked off")
        else:
            batches.append(order[:first])
            i = first
        while i < len(order):
            batches.append(order[i:i + cap])
            i += cap
    if skipped:
        notes.append(f"{len(skipped)} targets skipped (duplicate/already open/already designated)")
    if reasons:
        notes.append(f"{len(reasons)} targets unreachable")
    unreachable = sorted(reasons, key=lambda k: (k[1], k[0]))
    return DigPlan(batches=batches, unreachable=unreachable, notes=notes,
                   skipped=sorted(skipped, key=lambda s: (s[0][1], s[0][0], s[1])),
                   reasons=reasons, access=sorted(access_tiles, key=lambda k: (k[1], k[0])), z=area.z)


def batch_to_csv(tiles: Iterable[Tile], key: str = "d", label: str = "dig") -> tuple[str, Tile]:
    """Quickfort #dig CSV for one batch. Returns (text, origin x,y) - the origin is the ``-c`` cursor."""
    ts = sorted(set(tiles))
    if not ts:
        raise ValueError("empty batch")
    x0, x1 = min(t[0] for t in ts), max(t[0] for t in ts)
    y0, y1 = min(t[1] for t in ts), max(t[1] for t in ts)
    want = set(ts)
    rows = [",".join(key if (x, y) in want else "" for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
    return f"#dig label({label})\n" + "\n".join(rows) + "\n", (x0, y0)
