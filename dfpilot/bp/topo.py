"""Worst-case topology audit on snapshots (DESIGN §5.4 R1; CONTRACTS §9.10 legend, §13 `audit` verb).

Worst case: every bridge footprint is passable (lowered, `=` and `H`), doors and hatches are open (`+`),
hidden tiles (`?`) are impassable unknown. Movement model (DF-like, 8-connected, no corner rule, so
diagonal gaps leak):
- walkable: `. < > X r v + = H ^ w`, and `_` resting on a solid tile (`# S C F`: the top of a wall);
- stairs: `<`/`X` below `>`/`X`; a `+` counts as either (a hatch may cover a stair);
- ramps: `r` connects to the walkable 8-neighbours one level up when the tile above it is open (`_`/`v`);
- climbing (attackers only): an unsupported `_` tile next to a climbable tile (`# F T`, at its level or one
  below) is a cling position; clings connect to everything around them and vertically. Smoothed (`S`) and
  constructed (`C`) walls are not climbable; an overhang (floor above the climber) blocks the climb.
"""
from __future__ import annotations

from collections import deque

PASS = frozenset(".<>Xrv+=H^w")
SOLID = frozenset("#SCF")
CLIMB = frozenset("#FT")
UPC, DNC = frozenset("<X+"), frozenset(">X+")
ARMED = frozenset("WS")             # weapon and stone-fall traps count as armed traps (R2 >= 30)
H8 = ((1, 0), (-1, 1), (0, 1), (1, 1))     # forward half of the 8-neighbourhood (edges are undirected)
H4 = ((1, 0), (0, 1))
N8 = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))


def _msg(s: str) -> str:
    return s if len(s) <= 80 else s[:77] + "..."


class Graph:
    """Movement graph of a snapshot. Indices are local: i = (z*H + y)*W + x."""

    def __init__(self, snap: dict, diag: bool = True, closed: str = ""):
        """`diag=False`: orthogonal moves only; `closed`: extra chars treated as walls (e.g. '+' doors)."""
        self.bbox = snap["bbox"]
        self.diag = diag
        x0, y0, z0, x1, y1, z1 = self.bbox
        W, H, D = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
        self.W, self.H, self.D, self.WH, self.N = W, H, D, W * H, W * H * D
        t = "".join("".join(snap["rows"][f"z{z}"]) for z in range(z0, z1 + 1))
        for c in closed:
            t = t.replace(c, "#")
        self.t = t
        N, WH = self.N, self.WH
        walk = bytearray(N)
        for i, c in enumerate(t):
            if c in PASS or (c == "_" and i >= WH and t[i - WH] in SOLID):
                walk[i] = 1
        cling = bytearray(N)
        for i, c in enumerate(t):
            if c == "_" and not walk[i] and self._near_climb(i):
                cling[i] = 1
        self.walk, self.cling = walk, cling
        self.adj: dict[int, list[int]] = {}
        self.cadj: dict[int, list[int]] = {}
        self._edges()

    def _near_climb(self, i: int) -> bool:
        x, y = i % self.W, (i // self.W) % self.H
        for base in (i, i - self.WH):
            if base < 0:
                continue
            for dx, dy in N8:
                if 0 <= x + dx < self.W and 0 <= y + dy < self.H and self.t[base + dy * self.W + dx] in CLIMB:
                    return True
        return False

    def _link(self, a: int, b: int, climb: bool) -> None:
        d = self.cadj if climb else self.adj
        d.setdefault(a, []).append(b)
        d.setdefault(b, []).append(a)

    def _edges(self) -> None:
        W, H, WH, t, walk, cling = self.W, self.H, self.WH, self.t, self.walk, self.cling
        for i in range(self.N):
            if not (walk[i] or cling[i]):
                continue
            x, y, z = i % W, (i // W) % H, i // WH
            for dx, dy in (H8 if self.diag else H4):
                if 0 <= x + dx < W and y + dy < H:
                    j = i + dy * W + dx
                    if walk[j] or cling[j]:
                        self._link(i, j, bool(cling[i] or cling[j]))
            if z + 1 >= self.D:
                continue
            j = i + WH
            if walk[i] and walk[j] and t[i] in UPC and t[j] in DNC and not (t[i] == "+" == t[j]):
                self._link(i, j, False)
            if cling[j]:
                self._link(i, j, True)
            if t[i] == "r" and t[j] in "_v":
                if walk[j]:
                    self._link(i, j, False)
                for dx, dy in N8:
                    if 0 <= x + dx < W and 0 <= y + dy < H:
                        k = j + dy * W + dx
                        if walk[k]:
                            self._link(i, k, False)

    # ------------------------------------------------------------ helpers
    def idx(self, p) -> int | None:
        x0, y0, z0, x1, y1, z1 = self.bbox
        x, y, z = p[0], p[1], p[2]
        if not (x0 <= x <= x1 and y0 <= y <= y1 and z0 <= z <= z1):
            return None
        return ((z - z0) * self.H + (y - y0)) * self.W + (x - x0)

    def pos(self, i: int) -> tuple[int, int, int]:
        x0, y0, z0 = self.bbox[:3]
        return x0 + i % self.W, y0 + (i // self.W) % self.H, z0 + i // self.WH

    def node(self, i) -> bool:
        return i is not None and bool(self.walk[i] or self.cling[i])

    def mask(self, boxes) -> bytearray:
        m = bytearray(self.N)
        x0, y0, z0, x1, y1, z1 = self.bbox
        for b in boxes:
            ax, ay, az, bx, by, bz = max(b[0], x0), max(b[1], y0), max(b[2], z0), min(b[3], x1), min(b[4], y1), \
                min(b[5], z1)
            for z in range(az, bz + 1):
                for y in range(ay, by + 1):
                    s = self.idx((ax, y, z))
                    if s is not None and bx >= ax:
                        m[s:s + bx - ax + 1] = b"\x01" * (bx - ax + 1)
        return m

    def mask_pts(self, pts) -> bytearray:
        m = bytearray(self.N)
        for p in pts:
            i = self.idx(p)
            if i is not None:
                m[i] = 1
        return m

    def nodes_in(self, m) -> list[int]:
        return [i for i in range(self.N) if m[i] and (self.walk[i] or self.cling[i])]

    def bfs(self, sources, blocked=None, climb: bool = True, stop=None, parents=None):
        """Returns (seen, hit): hit = first reached index with stop[i] set, else None.
        `parents` (a dict) receives the BFS tree for `path()`."""
        seen = bytearray(self.N)
        dq = deque()
        for s in sources:
            if s is not None and not seen[s] and not (blocked and blocked[s]):
                seen[s] = 1
                dq.append(s)
        adj, cadj = self.adj, self.cadj
        while dq:
            i = dq.popleft()
            if stop is not None and stop[i]:
                return seen, i
            for lst in (adj.get(i, ()), cadj.get(i, ()) if climb else ()):
                for j in lst:
                    if not seen[j] and not (blocked and blocked[j]):
                        seen[j] = 1
                        dq.append(j)
                        if parents is not None:
                            parents[j] = i
        return seen, None

    @staticmethod
    def path(parents: dict, hit: int) -> list[int]:
        out = [hit]
        while out[-1] in parents:
            out.append(parents[out[-1]])
        return out[::-1]

    def min_cost(self, sources, cost, targets) -> int | None:
        """0-1 BFS: fewest cost tiles entered on any path sources -> targets (climbing allowed)."""
        INF = 1 << 30
        dist = [INF] * self.N
        dq = deque()
        for s in sources:
            if s is not None and dist[s] > cost[s]:
                dist[s] = cost[s]
                dq.append(s)
        while dq:
            i = dq.popleft()
            if targets[i]:
                return dist[i]
            di = dist[i]
            for lst in (self.adj.get(i, ()), self.cadj.get(i, ())):
                for j in lst:
                    nd = di + cost[j]
                    if nd < dist[j]:
                        dist[j] = nd
                        (dq.appendleft if cost[j] == 0 else dq.append)(j)
        return None


def _or(*ms) -> bytearray:
    n = len(ms[0])
    v = 0
    for m in ms:
        v |= int.from_bytes(m, "little")
    return bytearray(v.to_bytes(n, "little"))


def _minus(a, b) -> bytearray:
    n = len(a)
    return bytearray((int.from_bytes(a, "little") & ~int.from_bytes(b, "little")).to_bytes(n, "little"))


def fort_boxes(m: dict) -> list:
    """The fort's own geometry in a manifest: zones, rooms, killboxes, bridges, stairs, stations, refuge."""
    pt = lambda p: [p[0], p[1], p[2], p[0], p[1], p[2]]  # noqa: E731
    boxes = [b for lst in m.get("zones", {}).values() for b in lst]
    boxes += [r["bbox"] for r in m.get("rooms", [])] + [k["bbox"] for k in m.get("killboxes", [])]
    boxes += [b["fp"] for b in m.get("bridges", {}).values()]
    boxes += [[s[0], s[1], s[2], s[0], s[1], s[3]] for lst in m.get("stairs", {}).values() for s in lst]
    boxes += [pt(p) for p in m.get("stations", {}).values()]
    if m.get("refuge"):
        boxes.append(pt(m["refuge"]["anchor"]))
    return boxes


def sources(g: Graph, manifest: dict) -> list[int]:
    """Attacker sources: the manifest `edge` tiles plus every walkable or climbable bbox-border tile outside
    the fort's own geometry. `edge` alone would hide surface regions it cannot reach (the far bank of a
    river, a cliff face); leaving out the fort keeps a tight snapshot bbox from starting attackers inside."""
    src = {i for i in (g.idx(p) for p in manifest.get("edge", [])) if g.node(i)}
    inner = g.mask(fort_boxes(manifest))
    W, H = g.W, g.H
    ring = [x for x in range(W)] + [(H - 1) * W + x for x in range(W)] + \
        [y * W for y in range(1, H - 1)] + [y * W + W - 1 for y in range(1, H - 1)]
    for z in range(g.D):
        for r in ring:
            i = z * g.WH + r
            if (g.walk[i] or g.cling[i]) and not inner[i]:
                src.add(i)
    return sorted(src)


def audit(snap: dict, manifest: dict | None, graph: Graph | None = None) -> dict:
    """{ok, fails, min_traps, bypass, refuge_sep, civ_sep, caverns} (= the `audit` verb args minus `snap`)."""
    g = graph or Graph(snap)
    m = manifest or {}
    fails: list[str] = []
    res = {"ok": False, "fails": fails, "min_traps": 0, "bypass": True, "refuge_sep": False,
           "civ_sep": False, "caverns": True}
    zones = m.get("zones", {})
    Z = {k: g.mask(zones.get(k, [])) for k in ("Z1", "Z2", "Z3", "Z4")}
    kill = g.mask([k["bbox"] for k in m.get("killboxes", [])])
    src = sources(g, m)
    if not src:
        fails.append("edge: no walkable edge tile in the snapshot")
        return res
    T = _or(Z["Z3"], Z["Z4"])
    if not g.nodes_in(T):
        fails.append("manifest: no walkable Z3/Z4 tile in the snapshot")
        return res
    # 1. bypass: with the trap hall removed no edge -> Z3/Z4 path may remain
    if not any(Z["Z2"]):
        fails.append("manifest: no Z2 trap hall")
    _, hit = g.bfs(src, blocked=Z["Z2"], stop=T)
    res["bypass"] = hit is not None
    if hit is not None:
        fails.append(_msg("bypass: edge->Z3/Z4 avoids the trap hall (reaches %d,%d,%d)" % g.pos(hit)))
    # 2. armed traps on every attacker path
    cost = bytearray(g.N)
    for t in snap.get("traps", []):
        i = g.idx(t)
        if i is not None and t[3] in ARMED and (len(t) < 6 or t[5]):
            cost[i] = 1
        if t[3] == "C" and i is not None and (Z["Z1"][i] or Z["Z2"][i] or kill[i]):
            fails.append(_msg("cage trap on the main path at %d,%d,%d" % tuple(t[:3])))
    mt = g.min_cost(src, cost, T)
    if mt is None:
        fails.append("no attack path with bridges lowered (snapshot or manifest incomplete)")
    res["min_traps"] = mt or 0
    # 3. refuge separation
    ref = m.get("refuge")
    rpts = ([ref["anchor"]] if ref else []) + list(snap.get("marks", {}).get("refuge", []))
    rmask = g.mask_pts(rpts)
    core = g.nodes_in(Z["Z4"])
    attack = _or(Z["Z1"], Z["Z2"], kill)
    if not any(g.node(g.idx(p)) for p in rpts):
        fails.append("refuge: none (manifest refuge.anchor) or not walkable")
    else:
        _, h1 = g.bfs(core, blocked=_or(attack, Z["Z3"]), climb=False, stop=rmask)
        _, h2 = g.bfs(src, blocked=_minus(Z["Z4"], rmask), stop=rmask)
        if h1 is None:
            fails.append("refuge: not reachable from the core without Z1/Z2/Z3")
        if h2 is not None:
            fails.append("refuge: on the attack path (reachable without passing Z4)")
        res["refuge_sep"] = h1 is not None and h2 is None
    # 4. civilian path != attacker path
    st = m.get("stairs", {})
    civ, mil = st.get("civ", []), st.get("mil", [])
    col = lambda lst: g.mask([[s[0], s[1], s[2], s[0], s[1], s[3]] for s in lst])  # noqa: E731
    ok = True
    if not civ or not mil:
        fails.append("stairs: need a civilian and a separate military stair")
        ok = False
    else:
        if any(max(abs(a[0] - b[0]), abs(a[1] - b[1])) < 2 for a in civ for b in mil):
            fails.append("stairs: civilian and military stair are not separate (<2 tiles)")
            ok = False
        cm, mm = col(civ), col(mil)
        if any(c and a for c, a in zip(cm, attack)):
            fails.append("stairs: civilian stair inside Z1/Z2/killbox")
            ok = False
        if g.nodes_in(Z["Z3"]):
            _, a = g.bfs(src, stop=Z["Z3"])
            _, b = g.bfs(src, blocked=cm, stop=Z["Z3"])
            if a is not None and b is None:
                fails.append("stairs: the civilian stair is on the attack path to Z3")
                ok = False
        if any(rmask) and core:
            _, h = g.bfs(core, blocked=_or(attack, Z["Z3"], mm), climb=False, stop=rmask)
            if h is None:
                fails.append("civ: core->refuge needs attacker zones or the military stair")
                ok = False
    res["civ_sep"] = ok
    # 5. caverns sealed
    cav = g.mask_pts(snap.get("marks", {}).get("cavern", []))
    if any(cav):
        _, h = g.bfs(g.nodes_in(T), stop=cav)
        if h is not None:
            res["caverns"] = False
            fails.append(_msg("caverns: open to the fort at %d,%d,%d" % g.pos(h)))
    # 6. gallery reachable only from inside, roofed
    gal = m.get("stations", {}).get("gallery")
    if gal:
        gi = g.idx(gal)
        if not g.node(gi):
            fails.append("gallery: station not walkable")
        else:
            _, h = g.bfs(src, blocked=Z["Z3"], stop=g.mask_pts([gal]))
            if h is not None:
                fails.append("gallery: reachable without passing Z3")
            above = g.idx((gal[0], gal[1], gal[2] + 1))
            if above is not None and g.t[above] == "_":
                fails.append("gallery: not roofed")
    # 7. bridges: levers inside, footprint present
    inner = _or(Z["Z3"], Z["Z4"])
    for n, b in sorted(m.get("bridges", {}).items()):
        lv = b.get("levers", [])
        if len(lv) < 2:
            fails.append(f"levers: {n} has {len(lv)} lever(s), needs 2")
        if any(g.idx(p) is None or not inner[g.idx(p)] for p in lv):
            fails.append(f"levers: a lever of {n} is outside Z3/Z4")
        fi = g.idx(b["fp"][:3])
        if fi is not None and g.t[fi] not in "=H":
            fails.append(f"bridge {n}: footprint is not a bridge in the snapshot")
    res["ok"] = not fails
    res["fails"] = fails[:50]
    return res
