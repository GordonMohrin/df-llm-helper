"""Site finder: `rank(snap, tpl, params)` -> top 3 placements scored on *revealed* tiles only.

Fair play (DESIGN §11.1): the snapshot carries no hidden information (`?`). Hidden tiles count as unknown
rock that may be dug (like designating into unexplored rock in the vanilla UI), with a small penalty, never
as open or safe. Revealed open space, water, magma, trees, buildings and `marks` (damp, warm, cavern, water)
inside a footprint or its wall ring reject the site.

Rooms need the fort manifest (fail closed: without zones.Z4 rank raises ValueError). The anchor is a floor
or up/down-stair tile in Z4 that is *public*: reachable from Z4 without crossing a door into a room nobody
should walk through (bedrooms, tombs, hospital, temple, the fortcore dorm and refuse room). The doorway next
to it (rotated (0,1)) and the footprint plus its 1-tile wall ring must be rock (`#`) or unknown. The
footprint keeps one rock tile to Z1/Z2, killboxes and bridges (also on the levels above and below), to Z3,
the military stair and the gallery and melee stations (same level), and stays off the refuge level.
Score: 1000 - 5 per walking step to the nearest stair (the hubs) - 1 per 10 unknown tiles; farms also
+10 per soil-marked plot tile (`marks.soil`) and -25 per level below the top of Z4.
Fortcore: the anchor is a surface floor tile under open sky with floor in front of the entrance; no level of
the footprint may hold a revealed open tile. Score: flat dry surface over the footprint, map margin.
"""
from __future__ import annotations

from collections import deque

from .emit import TEMPLATES, check_params
from .primitives import rot_uv
from .rooms import NO_THROUGH, plot_rects
from .topo import Graph

GOOD = frozenset("#?")
WET = frozenset("~w%")
MARKS = ("damp", "warm", "cavern", "water")


class _Pref:
    """2D prefix sums per z of a 0/1 grid (from a char predicate or a point set)."""

    def __init__(self, snap: dict, pred=None, points=()):
        x0, y0, z0, x1, y1, z1 = snap["bbox"]
        self.x0, self.y0, self.W, self.H = x0, y0, x1 - x0 + 1, y1 - y0 + 1
        pts = {}
        for x, y, z in points:
            if 0 <= x - x0 < self.W and 0 <= y - y0 < self.H:
                pts.setdefault(z, set()).add((x - x0, y - y0))
        self.p = {}
        for z in range(z0, z1 + 1):
            rows, zp = snap["rows"][f"z{z}"], pts.get(z, ())
            if pred is None and not zp:
                self.p[z] = [[0] * (self.W + 1) for _ in range(self.H + 1)]
                continue
            acc = [[0] * (self.W + 1)]
            for j, r in enumerate(rows):
                line, run = [0], 0
                for i, c in enumerate(r):
                    run += 1 if (pred(c) if pred else (i, j) in zp) else 0
                    line.append(run)
                acc.append([a + b for a, b in zip(line, acc[-1])])
            self.p[z] = acc

    def inside(self, x0, y0, x1, y1) -> bool:
        return x0 >= self.x0 and y0 >= self.y0 and x1 < self.x0 + self.W and y1 < self.y0 + self.H

    def count(self, x0, y0, x1, y1, z) -> int | None:
        """Ones in the rect; None if the rect leaves the snapshot."""
        if z not in self.p or not self.inside(x0, y0, x1, y1):
            return None
        a, b, c, d = x0 - self.x0, y0 - self.y0, x1 - self.x0, y1 - self.y0
        P = self.p[z]
        return P[d + 1][c + 1] - P[b][c + 1] - P[d + 1][a] + P[b][a]


def footprint(tpl: str, p: dict) -> dict[int, list[tuple[int, int, int, int]]]:
    """Local check rects per w: the dug-tile bbox grown by the wall ring (rooms: not toward the anchor row);
    a channel also opens the tile below (sump or ramp)."""
    build = TEMPLATES[tpl][0]
    plans = [build({**p, "stage": s}) for s in (1, 2, 3)] if tpl == "fortcore" else [build(p)]  # whole fort
    dug: dict[int, set] = {}
    for plan in plans:
        for w, tiles in plan.dug().items():
            dug.setdefault(w, set()).update(tiles)
    rects: dict[int, list] = {}
    for w, tiles in dug.items():
        us, vs = [t[0] for t in tiles], [t[1] for t in tiles]
        lo_v = min(vs) - 1 if tpl == "fortcore" else max(1, min(vs) - 1)
        rects.setdefault(w, []).append((min(us) - 1, lo_v, max(us) + 1, max(vs) + 1))
    for plan in plans:
        for st in plan.stages:
            for it in st.items:
                if st.mode == "dig" and it.key == "h":          # the sump/ramp the channel opens below
                    rects.setdefault(it.w - 1, []).append((it.u0 - 1, it.v0 - 1, it.u1 + 1, it.v1 + 1))
    return rects


def _rot_rect(r, ax, ay, rot):
    (xa, ya), (xb, yb) = rot_uv(r[0], r[1], rot), rot_uv(r[2], r[3], rot)
    return ax + min(xa, xb), ay + min(ya, yb), ax + max(xa, xb), ay + max(ya, yb)


def _overlap(a, b) -> bool:
    return a[0] <= b[3] and b[0] <= a[3] and a[1] <= b[4] and b[1] <= a[4] and a[2] <= b[5] and b[2] <= a[5]


def _check(rects, ax, ay, az, rot, bad, hid, mk, allow_below: bool):
    """(unknown, missing_levels, box) or None if a rect holds a revealed obstacle or leaves the map."""
    unknown, missing = 0, set()
    xs, ys, zs = [], [], []
    for w, lst in rects.items():
        for r in lst:
            x0, y0, x1, y1 = _rot_rect(r, ax, ay, rot)
            if az + w < 0:
                return None                           # below the bottom of the map
            b = bad.count(x0, y0, x1, y1, az + w)
            if b is None:
                if allow_below and bad.inside(x0, y0, x1, y1) and az + w < min(bad.p):
                    missing.add(w)                   # level below the snapshot: unknown, allowed
                    continue
                return None
            if b or mk.count(x0, y0, x1, y1, az + w):
                return None
            unknown += hid.count(x0, y0, x1, y1, az + w)
            xs += [x0, x1]
            ys += [y0, y1]
            zs.append(az + w)
    if not xs:
        return None
    return unknown, len(missing), (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))


def rank(snap: dict, tpl: str, params: dict | None = None, manifest: dict | None = None,
         n: int = 3) -> list[dict]:
    """Top `n` sites, best first: [{id:'S1'.., anchor:[x,y,z], rot, score:int, why:str}].
    Room templates need `manifest` (the fort manifest, `inspect manifest`) with zones.Z4."""
    p = check_params(tpl, params)
    if tpl != "fortcore" and not ((manifest or {}).get("zones") or {}).get("Z4"):
        raise ValueError(f"{tpl}: room sites need the fort manifest with zones.Z4 (inspect manifest)")
    marks = [tuple(q) for k in MARKS for q in snap.get("marks", {}).get(k, [])]
    bad = _Pref(snap, lambda c: c not in GOOD)
    hid = _Pref(snap, lambda c: c == "?")
    mk = _Pref(snap, points=marks)
    rects = footprint(tpl, p)
    if tpl == "fortcore":
        cands = _fortcore(snap, rects, bad, hid, mk)
    else:
        cands = _rooms(snap, tpl, p, rects, bad, hid, mk, manifest)
    cands.sort(key=lambda c: (-c["score"], c["anchor"][2], c["anchor"][1], c["anchor"][0], c["rot"]))
    out: list[dict] = []
    for c in cands:
        if all(not _overlap(c["box"], o["box"]) for o in out):
            out.append(c)
            if len(out) == n:
                break
    return [{"id": f"S{i + 1}", "anchor": c["anchor"], "rot": c["rot"], "score": c["score"], "why": c["why"]}
            for i, c in enumerate(out)]


def _stair_steps(g: Graph) -> dict[int, int]:
    dist = {i: 0 for i, c in enumerate(g.t) if c in "<>X" and g.walk[i]}
    dq = deque(dist)
    while dq:
        i = dq.popleft()
        for j in g.adj.get(i, ()):
            if j not in dist:
                dist[j] = dist[i] + 1
                dq.append(j)
    return dist


def _keep_out(m: dict) -> list[tuple]:
    """Boxes a room footprint must not overlap (each already grown by its rock margin)."""
    zones = m.get("zones", {})
    attack = [b for k in ("Z1", "Z2") for b in zones.get(k, [])] + [k["bbox"] for k in m.get("killboxes", [])]
    attack += [b["fp"] for b in m.get("bridges", {}).values()]
    mil = list(zones.get("Z3", []))
    mil += [[s[0], s[1], s[2], s[0], s[1], s[3]] for s in m.get("stairs", {}).get("mil", [])]
    st = m.get("stations", {})
    mil += [[*st[k], *st[k]] for k in ("gallery", "melee") if k in st]
    return [(b[0] - 1, b[1] - 1, b[2] - 1, b[3] + 1, b[4] + 1, b[5] + 1) for b in attack] + \
        [(b[0] - 1, b[1] - 1, b[2], b[3] + 1, b[4] + 1, b[5]) for b in mil]


def _private(r: dict) -> bool:
    if r["tpl"] == "fortcore":
        return r["id"].rsplit("_", 1)[-1] in ("dorm", "refuse", "refuge")
    return r["tpl"] in NO_THROUGH


def _public(g: Graph, m: dict) -> bytearray:
    """Z4 tiles a new room may open from: reachable from Z4 outside private rooms without crossing a door."""
    z4 = g.mask(m["zones"]["Z4"])
    private = g.mask([r["bbox"] for r in m.get("rooms", []) if _private(r)])
    doors = bytearray(c == "+" for c in g.t)
    src = [i for i in range(g.N) if z4[i] and g.walk[i] and not private[i] and not doors[i]]
    seen, _ = g.bfs(src, blocked=doors, climb=False)
    return bytearray(a & b for a, b in zip(seen, z4))


def _rooms(snap, tpl, p, rects, bad, hid, mk, manifest):
    g = Graph(snap)
    steps_of = _stair_steps(g)
    keep_out = _keep_out(manifest)
    public = _public(g, manifest)
    ref = manifest.get("refuge")
    zr = ref["anchor"][2] if ref else None
    farm = tpl == "farms"
    if farm:
        soil_pts = [tuple(q) for q in snap.get("marks", {}).get("soil", [])]
        soil = _Pref(snap, points=soil_pts)
        plots = plot_rects(p)
        area = sum((r[2] - r[0] + 1) * (r[3] - r[1] + 1) for r in plots)
        top = max(b[5] for b in manifest["zones"]["Z4"])
    out = []
    for i, c in enumerate(g.t):
        if c not in ".X" or not public[i]:
            continue
        ax, ay, az = g.pos(i)
        for rot in range(4):
            du, dv = rot_uv(0, 1, rot)
            door = g.idx((ax + du, ay + dv, az))
            if door is None or g.t[door] not in GOOD:
                continue
            res = _check(rects, ax, ay, az, rot, bad, hid, mk, False)
            if res is None or any(_overlap(res[2], b) for b in keep_out):
                continue
            unknown, _, box = res
            if zr is not None and box[2] <= zr <= box[5]:
                continue                                   # the refuge level stays the refuge's own
            steps = min(steps_of.get(i, 99), 99)
            score = 1000 - 5 * steps - unknown // 10
            why = f"rot{rot}, {steps} steps to a stair, {unknown} unknown tiles"
            if farm:
                s = sum(soil.count(*_rot_rect(r[:4], ax, ay, rot), az + r[4]) or 0 for r in plots)
                score += 10 * s - 25 * (top - az)
                why += f", soil {s}/{area} plot tiles" if soil_pts else ", soil unknown"
                why += f", {top - az} levels below the top of Z4"
            out.append({"anchor": [ax, ay, az], "rot": rot, "score": max(0, score), "box": box, "why": why})
    return out


def _fortcore(snap, rects, bad, hid, mk):
    rows = snap["rows"]
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    rough = _Pref(snap, lambda c: c != ".")
    wet = _Pref(snap, lambda c: c in WET)
    under = {w: lst for w, lst in rects.items() if w < 0}
    out = []
    step = 2 if (x1 - x0 + 1) * (y1 - y0 + 1) > 2500 else 1
    for z in range(z0, z1):
        cur, up = rows[f"z{z}"], rows[f"z{z + 1}"]
        for yy in range(0, len(cur), step):
            r, ru = cur[yy], up[yy]
            for xx in range(0, len(r), step):
                if r[xx] != "." or ru[xx] != "_":
                    continue
                ax, ay = x0 + xx, y0 + yy
                for rot in range(4):
                    ex0, ey0, ex1, ey1 = _rot_rect((-1, -2, 1, 0), ax, ay, rot)   # entrance + tiles in front
                    if rough.count(ex0, ey0, ex1, ey1, z) != 0:
                        continue
                    res = _check(under, ax, ay, z, rot, bad, hid, mk, True)
                    if res is None:
                        continue
                    _, missing, box = res
                    uneven = rough.count(box[0], box[1], box[3], box[4], z) or 0
                    water = wet.count(box[0], box[1], box[3], box[4], z) or 0
                    margin = min(ax - x0, x1 - ax, ay - y0, y1 - ay)
                    score = 1000 - uneven // 4 - 40 * water - 30 * missing - (100 if margin < 5 else 0)
                    out.append({"anchor": [ax, ay, z], "rot": rot, "score": max(score, 0),
                                "box": (ax - 6, ay - 6, z, ax + 6, ay + 6, z),
                                "why": f"rot{rot}, {uneven} uneven and {water} water surface tiles, "
                                       f"{missing} levels below the snapshot"})
    return out
