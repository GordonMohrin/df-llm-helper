"""Pure tile-grid helpers shared by the v3 features reach (11), perimeter (01) and digcheck (02).

One character per tile. The same encoding is used by the grid fixtures (fixtures/v3/grid/*.grid) and by the
`dump` output of lua/pilot_reach.lua and lua/pilot_digcheck.lua, so all logic here runs unchanged on live data:

    ?  unrevealed (hidden) - never judged          #  natural wall          A  natural wall with aquifer (water_table)
    C  constructed wall/fortification (removable)  .  floor inside          ,  floor outside
    X  up/down stair inside    x  up/down stair outside    <  up stair    >  down stair
    ^  ramp inside             /  ramp outside
    _  open space inside (above ground)   '  open space outside (sky)   V  open space underground (void)
    ~  water (flow > 0)        M  magma (flow > 0)
    D  door/hatch/floodgate (walkable building)    T  trap (walkable building, part of a trap corridor)

Movement (mirrors lua/claude/zugaenge.lua): 8 directions on a level; stairs up/down when both ends are stairs;
ramps connect to the 8 neighbors one level up (and back). Liquids are not walkable (conservative, as in the prototype).
Fixture text format:
    -- comment           @origin x0 y0         @key value...  (free meta lines, e.g. @core 100 101 130)
    z <level>            followed by rows; row 0 = y0, column 0 = x0. Tiles not listed are natural wall '#'.
"""
from __future__ import annotations

from collections import deque
from pathlib import Path

__all__ = ["Grid", "WALK", "OUTSIDE", "STAIRS", "fmt", "clusters", "in_box", "box_dist", "entries", "core_sets"]

WALK = set(".,Xx<>^/DT")
OUTSIDE = set(",x/'")
STAIRS = set("Xx<>^/")          # stairs and ramps: constructions cannot be placed on them
UP = set("Xx<")
DOWN = set("Xx>")
RAMP = set("^/")
SOLID = set("#AC")
LIQUID = set("~M")
DIRS8 = [(dx, dy) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dx or dy]


def fmt(p) -> str:
    """(x,y,z130) - coordinate style of the run notes."""
    return f"({p[0]},{p[1]},z{p[2]})"


def in_box(p, box) -> bool:
    x1, y1, z1, x2, y2, z2 = box
    return (min(x1, x2) <= p[0] <= max(x1, x2) and min(y1, y2) <= p[1] <= max(y1, y2)
            and min(z1, z2) <= p[2] <= max(z1, z2))


def box_dist(p, box) -> int:
    """Chebyshev distance of a tile to a box (0 = inside)."""
    x1, y1, z1, x2, y2, z2 = box
    d = 0
    for v, a, b in ((p[0], x1, x2), (p[1], y1, y2), (p[2], z1, z2)):
        lo, hi = min(a, b), max(a, b)
        d = max(d, lo - v if v < lo else v - hi if v > hi else 0)
    return d


class Grid:
    def __init__(self, tiles: dict | None = None, default: str = "#", meta: dict | None = None):
        self.tiles: dict = dict(tiles or {})
        self.default = default
        self.meta: dict = dict(meta or {})

    # ---- construction
    @classmethod
    def from_text(cls, text: str) -> "Grid":
        g = cls()
        x0 = y0 = 0
        z = None
        row = 0
        for raw in text.splitlines():
            line = raw.rstrip("\n\r")
            s = line.strip()
            if s.startswith("--") or (not s and z is None):
                continue
            if s.startswith("@"):
                key, *vals = s[1:].split()
                if key == "origin":
                    x0, y0 = int(vals[0]), int(vals[1])
                else:
                    g.meta.setdefault(key, []).append(vals)
                continue
            if s.startswith("z ") and s[2:].strip().lstrip("-").isdigit():
                z = int(s[2:].strip())
                row = 0
                continue
            if z is None:
                continue
            for i, ch in enumerate(line.rstrip()):
                if ch != " ":
                    g.tiles[(x0 + i, y0 + row, z)] = ch
            row += 1
        return g

    @classmethod
    def from_file(cls, path) -> "Grid":
        return cls.from_text(Path(path).read_text(encoding="utf-8"))

    @classmethod
    def from_dump(cls, j: dict) -> "Grid":
        """Lua dump {"ok":true,"origin":[x0,y0],"levels":{"130":["row y0", ...]}} -> Grid."""
        g = cls()
        g.add_dump(j)
        return g

    def add_dump(self, j: dict) -> None:
        x0, y0 = (j.get("origin") or [0, 0])[:2]
        for zs, rows in (j.get("levels") or {}).items():
            z = int(zs)
            for r, line in enumerate(rows or []):
                for i, ch in enumerate(line):
                    self.tiles[(x0 + i, y0 + r, z)] = ch

    def copy(self) -> "Grid":
        return Grid(self.tiles, self.default, self.meta)

    def with_changes(self, changes: dict) -> "Grid":
        g = self.copy()
        g.tiles.update(changes)
        return g

    # ---- tiles
    def get(self, p) -> str:
        return self.tiles.get(tuple(p), self.default)

    def walkable(self, p) -> bool:
        return self.get(p) in WALK

    def outside(self, p) -> bool:
        return self.get(p) in OUTSIDE

    def hidden(self, p) -> bool:
        return self.get(p) == "?"

    def neighbors(self, p):
        x, y, z = p
        c = self.get(p)
        out = []
        for dx, dy in DIRS8:
            q = (x + dx, y + dy, z)
            if self.get(q) in WALK:
                out.append(q)
        if c in UP and self.get((x, y, z + 1)) in DOWN:
            out.append((x, y, z + 1))
        if c in DOWN and self.get((x, y, z - 1)) in UP:
            out.append((x, y, z - 1))
        for dx, dy in DIRS8:
            if c in RAMP and self.get((x + dx, y + dy, z + 1)) in WALK:
                out.append((x + dx, y + dy, z + 1))
            if self.get((x + dx, y + dy, z - 1)) in RAMP:
                out.append((x + dx, y + dy, z - 1))
        return out

    def bfs(self, sources, ok=None) -> set:
        """Tiles reachable from sources (only walkable tiles for which ok(p, ch) is true)."""
        ok = ok or (lambda p, ch: True)
        seen = {tuple(s) for s in sources if self.walkable(s) and ok(tuple(s), self.get(s))}
        q = deque(seen)
        while q:
            p = q.popleft()
            for n in self.neighbors(p):
                if n not in seen and ok(n, self.get(n)):
                    seen.add(n)
                    q.append(n)
        return seen

    def reachable(self, a, b, ok=None) -> bool:
        return tuple(b) in self.bfs([a], ok)

    def components(self) -> dict:
        """Walk group per walkable tile (like DF's walkable groups, for the Lua mock's canWalkBetween)."""
        comp, gid = {}, 0
        for p in sorted(self.tiles):
            if p in comp or not self.walkable(p):
                continue
            gid += 1
            for q in self.bfs([p]):
                comp[q] = gid
        return comp

    def cutting_constructions(self, a, b, soft: str = "C") -> list | None:
        """0-1 BFS a -> b where constructed walls cost 1 (treated as passable floor) and everything walkable costs 0.
        Returns the constructions on the cheapest path (in path order, from a), [] if b is reachable anyway,
        None if b stays unreachable even without constructions (cause elsewhere: natural wall, unrevealed, box)."""
        a, b = tuple(a), tuple(b)
        relaxed = self.copy()
        for p, ch in self.tiles.items():
            if ch in soft:
                relaxed.tiles[p] = "."
        if not self.walkable(a):
            return None
        dist = {a: 0}
        prev: dict = {}
        dq = deque([a])
        while dq:
            p = dq.popleft()
            if p == b:
                break
            for n in relaxed.neighbors(p):
                w = 1 if self.get(n) in soft else 0
                nd = dist[p] + w
                if nd < dist.get(n, 1 << 30):
                    dist[n] = nd
                    prev[n] = p
                    (dq.appendleft if w == 0 else dq.append)(n)
        if b not in dist:
            return None
        path, p = [], b
        while p != a:
            path.append(p)
            p = prev[p]
        path.reverse()
        return [p for p in path if self.get(p) in soft]

    def bbox(self):
        xs = [p[0] for p in self.tiles]
        ys = [p[1] for p in self.tiles]
        zs = [p[2] for p in self.tiles]
        return (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs)) if self.tiles else None

    def to_mock(self) -> list:
        """Tile list for tests/lua_mock/grid_mock.lua: [{x,y,z,c,g}] (g = walk group for canWalkBetween)."""
        comp = self.components()
        return [{"x": p[0], "y": p[1], "z": p[2], "c": ch, "g": comp.get(p, 0)} for p, ch in sorted(self.tiles.items())]


def clusters(points, dxy: int = 2, dz: int = 1) -> list:
    """Group tiles transitively (neighborhood +-dxy on x/y, +-dz on z). Deterministic order (sorted)."""
    pts = sorted({tuple(p) for p in points})
    left = set(pts)
    out = []
    for p in pts:
        if p not in left:
            continue
        left.discard(p)
        cl, stack = [], [p]
        while stack:
            c = stack.pop()
            cl.append(c)
            near = [q for q in left if abs(q[0] - c[0]) <= dxy and abs(q[1] - c[1]) <= dxy and abs(q[2] - c[2]) <= dz]
            for q in near:
                left.discard(q)
                stack.append(q)
        out.append(sorted(cl))
    return out


def entries(grid: Grid, z_range=None) -> list:
    """Perimeter step 1 (same algorithm as lua/pilot_perimeter.lua): multi-source BFS from every walkable outside tile;
    entry = reached walkable INSIDE tile with a reached outside tile as move neighbor."""
    zr = z_range or (-10**9, 10**9)
    okz = (lambda p, ch: zr[0] <= p[2] <= zr[1])
    seeds = [p for p, ch in grid.tiles.items() if ch in WALK and ch in OUTSIDE and okz(p, ch)]
    seen = grid.bfs(seeds, okz)
    out = []
    for p in seen:
        if grid.outside(p):
            continue
        if any(n in seen and grid.outside(n) for n in grid.neighbors(p)):
            out.append(p)
    return sorted(out)


def core_sets(grid: Grid, core, z_range=None) -> tuple:
    """Inside-only reach from the core point: (all, without trap tiles). Entry e leads to the core iff e in all."""
    zr = z_range or (-10**9, 10**9)
    inside = (lambda p, ch: ch not in OUTSIDE and zr[0] <= p[2] <= zr[1])
    no_trap = (lambda p, ch: inside(p, ch) and ch != "T")
    return grid.bfs([core], inside), grid.bfs([core], no_trap)
