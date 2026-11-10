"""Site finder: `rank(snap, tpl, params)` -> top 3 placements scored on *revealed* tiles only.

Fair play (DESIGN §11.1): the snapshot carries no hidden information (`?`). Hidden tiles count as unknown
rock that may be dug (like designating into unexplored rock in the vanilla UI), with a small penalty, never
as open or safe. Revealed open space, water, magma, trees, buildings and `marks` (damp, warm, cavern, water)
inside a footprint or its wall ring reject the site, and so does revealed water or magma on the level just above
a dug rect (live L1: a farm room under a swamp pond hit "damp stone located" at once).

Rooms need the fort manifest (fail closed: without zones.Z4 rank raises ValueError). The anchor is a floor
or up/down-stair tile in Z4 that is *public*: reachable from Z4 without crossing a door into a room nobody
should walk through (bedrooms, tombs, hospital, temple, the fortcore dorm and refuse room). The doorway next
to it (rotated (0,1)) and the footprint plus its 1-tile wall ring must be rock (`#`) or unknown. The
footprint keeps one rock tile to Z1/Z2, killboxes and bridges (also on the levels above and below), to Z3,
the military stair and the gallery and melee stations (same level), and stays off the refuge level.
Score: 1000 - 5 per walking step to the nearest stair (the hubs) - 1 per 10 unknown tiles; farms also
+10 per soil-marked plot tile (`marks.soil`) and -25 per level below the top of Z4; BUG-346: on a soil level (the fort's
dug Z4 floor there is soil, `soil_levels`) the undug plot tiles count as soil (the snapshot marks floor only).
Fortcore: the anchor is a surface floor tile under open sky with floor in front of the entrance; no level of
the footprint may hold a revealed open tile. Score: flat dry surface over the footprint, map margin, and water
(live L3: the only water was a brook 90 tiles away and bedridden dwarves died of thirst): + up to 60 when a
revealed body of water (>= 8 tiles: a brook, river or lake, not a puddle or a sump) is within WATER_NEAR (30)
walking steps of the anchor, minus 1 per step beyond, -80 when no revealed water is reachable at all. BUG-130: a
fortcore's dig keeps BREACH_R tiles from every breach the kernel recorded (manifest `breaches`, `caverns`) on its levels
(+-1) and out of a wet layer (damp/water stops of LAYER_MIN projects on one level); ValueError when nothing dry is left.
BUG-482: a room (refuge-level rooms among them) keeps CAV_KEEP tiles from known cavern water (`cavern_water`: the manifest's recorded
cavern stops and cavern_lake breaches, revealed water with a cavern mark); BUG-484: a fortcore with no p.aquifer is dropped where its dig
passes a level a dig of ours met a heavy aquifer on (`_flooded`), and `aquifer=pass` without p.depth is ranked at the depth that puts the core
under the known aquifer (`_rank_pass`, each site names its depth; the ValueError says why when no depth up to 12 does).
Refuge beds (`rooms.refuge_beds`, Run 10): anchors on the floor of the fortcore refuge room (no lever tile), the
dormitory dug into the rock beside it (footprint and wall ring rock or unknown: it opens no new way in). The refuge drink
store (`rooms.refuge_drink`, FR-69) the same way; BUG-319: also from the floor of those refuge-level rooms (the refuge grows
when the refuge room's walls are taken), ranked after the refuge room's own anchors; with no site the ValueError says why and names the largest smaller
store that has one (Run 11's Tiefe+ is a cramped 212-tile shaft).
Cistern (`rooms.cistern`): a dry cistern ranks like any room; with a `path` (the pipe to a brook or river) only
anchors whose pipe ends at a valid intake count: shaft column B and breach tile G on revealed bank floor, the
water W behind G (`water=bed`: one level below the bank, a brook; `bank`: at bank level), every pipe and shaft
tile rock or unknown with a rock ring (no revealed open tile within 1), nothing open or wet right above a pipe
tile (a pressurized pipe must not rise into anything). `level=refuge` puts the well room on the refuge level
(anchors in the fortcore refuge room). `plan_cistern` routes such a pipe on a snapshot (`python -m
dfpilot.bp.sites cistern --save <folder>` prints the params and the bp.place command). `water=aquifer` (BUG-262, no path):
the basin one level below the well room lies on a known aquifer level (manifest aquifer_levels, damp marks), the room level
and the one above it are dry, no heavy aquifer was recorded there (`aquifer_well`); damp marks do not reject it.
Explore (`mine.explore`, Run 10: no ore for years): public Z4 anchors like a room, never on or below the refuge level;
its footprint ring per level (all round below the anchor level) must be rock or unknown, levels below the snapshot are
unknown; the shaft must not reach a level in `p.avoid`, one with a revealed cavern, damp or warm mark, or (Run 11) the
level of a cavern breach the kernel recorded (manifest `caverns`) (ValueError names them when nothing else is left). Score: 1000 - 5 per step to a stair + 10 per level below the top of Z4.
Hospital (BUG-040, Run 11 y453: the sites ignored the water the plan check demands): with `water` (the kernel's accepted
sources, state water.src; cmd.water_ctx) only sites whose hospital zone lies within `near` (water.lua's radius, 30) of an
accepted source count, measured as water.lua's served() does (Chebyshev from the source to the zone rect, z included);
+2 per tile nearer; ValueError names the source, the nearest candidate and the refuge's water when none is left.
`fill_source`: what a bucket-fed cistern (no pipe) could be filled from (revealed open water reachable from the core).
Startup shops (`workshops` p.surface = 1, BUG-356), the trade `depot` (BUG-368), the `office` p.surface = 1 (BUG-396, 3x3) and the
`hospital` p.surface = 1 (BUG-384, a 7x5 block near accepted water): no manifest needed; a block of open surface floor (every tile '.' with '_'
above, on the citizens' walk group), nearest the middle of the snapshot (or `near`), clear of the fortcore's keep-out tiles.
Aqshaft (BUG-292): columns from public Z4 floor whose levels below are rock or unknown with rock on their 4 sides,
off the keep-out boxes and the cavern/warm levels; + AQ_SPAN for passing a known aquifer level (`_aqshaft`).
"""
from __future__ import annotations

import heapq
from collections import deque

from . import aquifer, defense, fortcore, mine, rooms, surfacecore, topo, traps
from .emit import TEMPLATES, check_params
from .primitives import Xform, rot_uv
from .rooms import NO_THROUGH, plot_rects
from .topo import Graph, N8

RANK_V = 12                           # BUG-346/359/400/407/553/584/602: the ranking rules' version (cmd's sites cache re-ranks older ones)
GOOD = frozenset("#?")
WET = frozenset("~w%")
WATER = frozenset("~w")               # drinkable: not magma
MARKS = ("damp", "warm", "cavern", "water")
WATER_NEAR = 30                       # walking steps from a fortcore anchor to revealed water (live L3)
OPEN_UP = frozenset("_v>X~w%")        # tiles a pressurized pipe below could rise into


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
    a channel also opens the tile below (sump or ramp). A cistern pipe adds one ring rect per pipe tile and per
    shaft tile below the bank (a bbox around a long pipe would demand rock over half the map); the shaft top and
    the breach tile are checked by the intake rule instead."""
    build = TEMPLATES[tpl][0]
    stages = range(1, fortcore.STAGES + 1)
    plans = [build({**p, "stage": s}) for s in stages] if tpl == "fortcore" else [build(p)]  # whole fort
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
    if tpl == "cistern":
        for w, u, v in intake_tiles(rooms.cistern_layout(p)):
            rects.setdefault(w, []).append((u - 1, v - 1, u + 1, v + 1))
    return rects


def intake_tiles(L: dict) -> list[tuple[int, int, int]]:
    """Local (w, u, v) of the pipe tiles and of the shaft tiles below the bank level (each needs a rock ring)."""
    if not L["intake"]:
        return []
    out = [(-1, u, v) for u, v in L["pipe"]]
    bu, bv = L["shaft"]
    out += [(w, bu, bv) for w in range(-1, L["w_top"])]
    return out


def _rot_rect(r, ax, ay, rot):
    (xa, ya), (xb, yb) = rot_uv(r[0], r[1], rot), rot_uv(r[2], r[3], rot)
    return ax + min(xa, xb), ay + min(ya, yb), ax + max(xa, xb), ay + max(ya, yb)


def _overlap(a, b) -> bool:
    return a[0] <= b[3] and b[0] <= a[3] and a[1] <= b[4] and b[1] <= a[4] and a[2] <= b[5] and b[2] <= a[5]


def _check(rects, ax, ay, az, rot, bad, hid, mk, allow_below: bool, wet=None):
    """(unknown, missing_levels, box) or None if a rect holds a revealed obstacle, has revealed liquid on the
    level above, or leaves the map."""
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
            if wet is not None and (wet.count(x0, y0, x1, y1, az + w + 1) or 0):
                return None                           # liquid right above: damp, never dig under it
            unknown += hid.count(x0, y0, x1, y1, az + w)
            xs += [x0, x1]
            ys += [y0, y1]
            zs.append(az + w)
    if not xs:
        return None
    return unknown, len(missing), (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))


NEAR_WITHIN = 12            # FR-78: `near` keeps the sites whose footprint lies within this many tiles of the point


def _near_point(cands: list, tpl: str, near, within: int | None, at) -> list:
    """FR-78 (Run 14 note 65: `bp sites` ranked automatically and could not be asked for "beside building X"): the
    candidates whose footprint lies within `within` tiles of the point `near` (Chebyshev, z included, as water.lua's
    dist_box), nearest first (the score breaks ties); with `at` only the candidates whose anchor is that tile. ValueError
    when none is left, naming the nearest candidate and the explicit-anchor label that places it."""
    if at is not None:
        pt = [int(v) for v in at]
        out = [{**c, "_d": 0, "why": c["why"] + f", at {_pos(pt)}"} for c in cands if list(c["anchor"]) == pt]
        if out:
            return out
        if not cands:
            raise ValueError(f"{tpl}: no valid site on the snapshot")
        c = min(cands, key=lambda c: (box_dist(pt, c["box"]), -c["score"]))
        raise ValueError(f"{tpl}: {_pos(pt)} is no valid anchor (the footprint meets a wall, liquid or hidden rock, leaves the "
                         f"map or is not level); the nearest valid anchor is {_pos(c['anchor'])} rot{c['rot']}, "
                         f"{box_dist(pt, c['box'])} tiles from it: bp.place site=A{c['anchor'][0]}_{c['anchor'][1]}_"
                         f"{c['anchor'][2]}_{c['rot']}")
    pt = [int(v) for v in near]
    w = NEAR_WITHIN if within is None else int(within)
    scored = [(box_dist(pt, c["box"]), c) for c in cands]
    out = [{**c, "_d": d, "why": c["why"] + f", {d} tiles from {_pos(pt)}"} for d, c in scored if d <= w]
    if out:
        return out
    if not scored:
        raise ValueError(f"{tpl}: no valid site on the snapshot")
    d, c = min(scored, key=lambda t: (t[0], -t[1]["score"]))
    raise ValueError(f"{tpl}: no site within {w} tiles of {_pos(pt)}; the nearest candidate {_pos(c['anchor'])} rot{c['rot']} is "
                     f"{d} tiles away: --within {d} or bp.place at an explicit anchor A<x>_<y>_<z>")


def rank(snap: dict, tpl: str, params: dict | None = None, manifest: dict | None = None,
         n: int = 3, water: dict | None = None, near=None, within: int | None = None, at=None,
         free=None) -> list[dict]:
    """Top `n` sites, best first: [{id:'S1'.., anchor:[x,y,z], rot, score:int, why:str}].
    Room templates need `manifest` (the fort manifest, `inspect manifest`) with zones.Z4.
    `water` (BUG-040, WATER_TPLS only): {src: [[x,y,z]..] accepted sources, near, lbl?: labels parallel to src,
    refuge?: {name, box, wd, ws}}: only sites near accepted water, each with water {d, src}; None = not filtered.
    `near` (FR-78): [x, y, z], only sites whose footprint lies within `within` (default NEAR_WITHIN) tiles of it, nearest
    first; `at`: [x, y, z], only the sites anchored exactly there (the reason when there is none). Both apply to room,
    explore and fortcore sites; the defense builds have the one site the manifest fixes. `free` (BUG-292): a callable
    candidate -> bool (cmd: no clash with a placed project); only free candidates are kept, ValueError when none is."""
    if tpl in mine.BUILD and "depth" not in (params or {}):
        return _rank_depths(snap, tpl, params, manifest, n, water, near, within, at, free)      # BUG-553: a smaller depth when 12 has none
    if tpl in mine.BUILD and "arm" not in (params or {}):
        return _rank_arms(snap, tpl, params, manifest, n, water, near, within, at, free)      # BUG-528: shorter side tunnels
    p = check_params(tpl, params)
    furnish = tpl == "hospital" and bool(p.get("furnish"))      # BUG-581: one table in a hospital room that stands
    if tpl in WATER_TPLS and water is not None and water.get("hrm") and not furnish:
        # BUG-539 (Run 16b i2 Brotherarrow: water.unstick removed the hospital zone, the room with its beds stood on, the site search
        # then found 'no valid site' and a second hospital would have been built beside the first): the kernel remembers
        # removed hospital zones; the room is the hospital, its zone comes back with the verb
        # BUG-540: water.hrm counts only what can come back (not expired; a dry memory only with accepted water near the old room;
        # a zoneless hospital room of the manifest too): a dry memory does not block a site that has water
        n = int(water["hrm"])
        raise ValueError(f"{tpl}: the fort's hospital room still stands, only its zone is missing ({n} zone"
                         f"{'' if n == 1 else 's'} to draw again: a removed or lost zone, accepted water near): "
                         "`dfllm cmd hospital.restore` draws it again at its old location (beds and tables keep their place); "
                         "no second hospital until then")
    if tpl == "fortcore" and p.get("aquifer") == "pass" and "depth" not in (params or {}):
        return _rank_pass(snap, params, manifest, n, water, near, within, at, free)       # BUG-484: the depth that clears the aquifer
    if tpl in aquifer.BUILD:
        p["depth_auto"] = "depth" not in (params or {})     # BUG-432: no p.depth = down to the core level, not 20
    if tpl in defense.BUILD:
        return _defense(snap, tpl, p, manifest)[:n]          # one site the manifest fixes: near/at do not apply
    if tpl in traps.BUILD:                                   # FR-96: absolute trap tiles, the site is the first one
        return traps.site(snap, p, _At(snap))[:n]
    # BUG-356/368/384: no fort manifest needed (the startup shops, the trade depot, the surface hospital)
    # BUG-387: the surface core and the surface variants of dining, bedrooms, tavern and office need none either
    rebuild = tpl == "workshops" and bool(p.get("rebuild"))       # BUG-562: the old place of a shop manifest.gone lists
    surface_shops = (tpl in ("workshops", "hospital", *rooms.SURFACE_ROOMS) and bool(p.get("surface")) and not rebuild) \
        or tpl in ("depot", "tradepost", "surfacecore")
    surface_farm = tpl == "farms" and bool(p.get("surface"))      # BUG-407: needs no fort manifest either (ground anywhere)
    if tpl != "fortcore" and not surface_shops and not surface_farm and not rebuild and not furnish \
            and not ((manifest or {}).get("zones") or {}).get("Z4"):
        raise ValueError(f"{tpl}: room sites need the fort manifest with zones.Z4 (inspect manifest)")
    if tpl == "deepcore":                                    # FR-103: its own ranking (shaft + deep level, bp/deep.py)
        from . import deep
        return deep.rank(snap, p, manifest, n=n, near=near, within=within, at=at)
    aqwell = tpl == "cistern" and p.get("water") == "aquifer"     # BUG-262: damp is what its basin looks for
    marks = [tuple(q) for k in MARKS if not (aqwell and k == "damp") for q in snap.get("marks", {}).get(k, [])]
    bad = _Pref(snap, lambda c: c not in GOOD)
    hid = _Pref(snap, lambda c: c == "?")
    mk = _Pref(snap, points=marks)
    wet = _Pref(snap, lambda c: c in WET)
    rects = explore_rects(p) if tpl in mine.BUILD else {} if tpl in aquifer.BUILD else footprint(tpl, p)
    if tpl in aquifer.BUILD:                                 # BUG-292: shaft columns are ranked (FR-95 named them only)
        cands = _aqshaft(snap, p, manifest)
    elif tpl == "farms" and p.get("surface"):               # BUG-297: plots on soil floor that stands already
        cands = _surface_farms(snap, p, manifest or {})
    elif rebuild:                                            # BUG-562: where the shop stood
        cands = _rebuild_shops(snap, p, manifest or {})
    elif furnish:                                            # BUG-581: a free floor tile inside the hospital room
        cands = _furnish_hospital(snap, manifest or {})
    elif surface_shops:                                      # BUG-356: the startup shops on open surface floor
        cands = _surface_shops(snap, p, manifest or {}, tpl)
        if not cands and surface_top_floor(snap) >= SURFACE_TOP_MIN and not sky_over_floor(snap):
            raise ValueError(f"{tpl}: no valid site on the snapshot: its top level z{snap['bbox'][5]} holds "
                             f"{surface_top_floor(snap)} floor tiles but no level above it to show open sky (BUG-399: a sites "
                             "export from an older kernel ends at the surface; dfllm reload, then `bp sites --fresh`)")
    elif tpl == "fortcore":
        cands = _fortcore(snap, rects, bad, hid, mk, wet)
        cands = _dry(cands, manifest)                      # BUG-130: never again into a recorded breach
        cands = _flooded(cands, snap, manifest, p, rects)  # BUG-359: the water and aquifer levels under the shaft
    elif tpl in mine.BUILD:
        cands = _explore(snap, p, rects, bad, hid, mk, manifest, wet)
    else:
        cands = _rooms(snap, tpl, p, rects, bad, hid, mk, manifest, wet)
        if not cands and tpl == "refuge_drink":
            raise ValueError(_no_store(snap, p, manifest, bad, hid, mk, wet))
        cands = cavern_keep(cands, tpl, snap, manifest)    # BUG-482: never beside known cavern water
    if aqwell:
        cands = aquifer_well(cands, snap, manifest)         # BUG-262: the basin on an aquifer level, the room dry
    elif tpl not in aquifer.BUILD:                          # a shaft passes the aquifer levels: that is its point
        before = len(cands)
        cands = aquifer_ok(cands, tpl, p, rects, manifest, snap)  # FR-95/BUG-359: the levels known damp or wet
        if before and not cands and tpl != "fortcore":            # BUG-447: say so, 'none (0 ranked)' hid it for years
            lv = ",".join(f"z{z}" for z in sorted(known_aquifer(snap, manifest)))
            raise ValueError(f"{tpl}: all {before} candidate site(s) lie on or right under a known aquifer level ({lv}); rooms keep "
                             "one dry level between (a refuge-level room may use the levels the refuge room itself stands on)")
    if tpl in WATER_TPLS and water is not None and not furnish:
        cands = _near_water(cands, tpl, p, water)
    cands = reachable(cands, snap, tpl, near if near is not None else at)    # BUG-352: the citizens' walk group (snapshot wg)
    if near is not None or at is not None:                 # FR-78: a position asked for; nearest first
        cands = _near_point(cands, tpl, near, within, at)
    cands.sort(key=lambda c: (c.get("_d", 0), -c["score"], c["anchor"][2], c["anchor"][1], c["anchor"][0], c["rot"]))
    out: list[dict] = []
    taken = 0
    for c in cands:
        if all(not _overlap(c["box"], o["box"]) for o in out):
            if free is not None and not free(c):            # BUG-292: on or beside a placed project
                taken += 1
                continue
            out.append(c)
            if len(out) == n:
                break
    if free is not None and cands and not out:
        held = sorted(getattr(free, "held", None) or ())
        why = getattr(free, "why", None) or {}
        first = getattr(free, "first", None) or {}
        # BUG-502: say which test held the candidates (a placed project's tiles, the floor of a placed room under the shaft's top
        # tile, a template that would not emit there) and always name the holders, so the player knows what to cancel
        parts = []
        if why.get("clash"):
            parts.append(f"{why['clash']} touch a placed project's tiles")
        if why.get("top"):
            parts.append(f"{why['top']} start on the floor of a placed room (a shaft starts in a corridor: fortcore, aqshaft or "
                         "explore floor, or open ground)")
        if why.get("emit"):
            parts.append(f"{why['emit']} cannot be emitted there ({first.get('emit', '')})")
        raise ValueError(f"{tpl}: all {taken} candidate site(s) lie on or beside placed projects"
                         f"{' (' + ', '.join(held[:6]) + (' +%d more' % (len(held) - 6) if len(held) > 6 else '') + ')' if held else ''}"
                         f"{': ' + '; '.join(parts) if parts else ''} (bp.cancel frees a parked one's tiles; a "
                         "seal's cancel drops only its unbuilt pieces; a finished shaft holds only the levels it dug)")
    return [{"id": f"S{i + 1}", "anchor": c["anchor"], "rot": c["rot"], "score": c["score"],
             "why": c["why"] + (f"; walk group {c['walk']}" if "walk" in c else ""),
             **({"water": c["water"]} if "water" in c else {}),
             **({"depth": c["depth"]} if "depth" in c else {}),          # BUG-432: an aqshaft site names its own depth
             **({"walk": c["walk"]} if "walk" in c else {})} for i, c in enumerate(out)]


PASS_DEPTH_MAX = fortcore.PARAMS["depth"][2]


def _rank_pass(snap, params, manifest, n, water, near, within, at, free) -> list[dict]:
    """BUG-484 (Run 16a i1 Basementflew y388-y390: `bp sites fortcore aquifer=pass` = 0 sites, known aquifer z116-z127 with heavy
    layers under a light one; the default depth 3 can never put the core under a level 12 below the surface): without p.depth
    the pass core is ranked at the shallowest depth, from the one that clears the shallowest anchor level, to PASS_DEPTH_MAX, whose
    core levels all lie under the deepest known aquifer level (`aquifer_ok`); every site names its depth (`site_params` hands it to
    bp.place, a later stage takes it from the stage 1 file, BUG-364). ValueError with the levels and the depth that was
    short when none fits at any depth."""
    aq = known_aquifer(snap, manifest)
    top = snap["bbox"][5] - 1
    d0 = fortcore.PARAMS["depth"][0]
    if aq:
        for d in range(d0, PASS_DEPTH_MAX + 1):
            lo = min(footprint("fortcore", {**check_params("fortcore", {"aquifer": "pass"}), "depth": d}))
            d0 = d
            if top + lo + 1 < min(aq):
                break
    errs: list[str] = []
    for d in range(d0, PASS_DEPTH_MAX + 1):
        try:
            sites = rank(snap, "fortcore", {**(params or {}), "depth": d}, manifest, n=n, water=water, near=near, within=within,
                         at=at, free=free)
        except ValueError as e:
            errs.append(f"depth {d}: {str(e).removeprefix('fortcore: ')[:120]}")
            continue
        if not sites:
            errs.append(f"depth {d}: every site meets a known aquifer level or has no room")
            continue
        low = min(footprint("fortcore", {**check_params("fortcore", {"aquifer": "pass"}), "depth": d}))
        return [{**s, "depth": d, "why": s["why"] + f"; depth {d}: the core's deepest level z{s['anchor'][2] + low}"
                 + (f" under the aquifer levels z{min(aq)}-z{max(aq)}" if aq else "")} for s in sites]
    heavy = sorted(heavy_breach_levels(manifest), reverse=True)
    raise ValueError(
        f"fortcore: no site puts the core under the aquifer (known levels {', '.join('z' + str(z) for z in sorted(aq, reverse=True)) or 'none'}"
        + (f", heavy at {', '.join('z' + str(z) for z in heavy)}" if heavy else "")
        + f") at any depth {d0}..{PASS_DEPTH_MAX} from the surface z{top}: " + "; ".join(errs[:2])
        + f". The template digs at most {PASS_DEPTH_MAX} levels under the surface: no core fits under these layers from here. "
          "What to do: another part of the map (a lower start), an aqshaft with its heavy ring down to the deepest layer and "
          "`bp sites fortcore aquifer=pass --fresh` again once it is done (the shaft shows what lies under), or stone and goods by "
          "caravan (trade.want stone, mechanism); no core is dug through a known layer without p.aquifer")


def walk_at(snap: dict, pos) -> str | None:
    """BUG-352: '1' when the tile lies in the citizens' walk group, '0' in another walk group, None when the snapshot has
    no walk groups (an older export, not a sites export), the tile lies outside it or no walkable tile was read there."""
    wg = snap.get("wg")
    if not isinstance(wg, dict):
        return None
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    x, y, z = (int(v) for v in pos)
    rows = (wg.get("rows") or {}).get(f"z{z}")
    if not rows or not (x0 <= x <= x1 and y0 <= y <= y1 and z0 <= z <= z1):
        return None
    try:
        c = rows[y - y0][x - x0]
    except IndexError:
        return None
    return c if c in "01" else None


def reachable(cands: list, snap: dict, tpl: str, focus=None) -> list:
    """BUG-352 (Run 16c site97: fortcore ranked S3/S2 on soil beyond the brook, a project 30 d at s1.dig 0 %, 'unreachable
    DigChannel'): the sites whose anchor tile lies in another walk group than the citizens stand in are dropped (the kernel's
    sites export marks it: snapshot wg); the others carry `walk` = the citizens' group. A tile without a read group claims
    nothing; a snapshot without walk groups is not filtered. ValueError when every candidate lies beyond.
    BUG-391: a ranking asked for one spot (`focus` = near / at) on a tile of another walk group (a cut-off group's well) is
    is not filtered to the citizens' group: the caller chose the cut-off group, so the sites on the citizens' group are dropped."""
    wg = snap.get("wg")
    if not isinstance(wg, dict) or not cands:
        return cands
    if focus is not None and walk_at(snap, focus) == "0":
        # the caller chose the cut-off group: only sites on that side (or without a read group) are offered, never a
        # site on the citizens' main group, which the stranded cannot reach
        stranded = [c for c in cands if walk_at(snap, c["anchor"]) != "1"]
        if not stranded:
            raise ValueError(f"{tpl}: every candidate site near that spot lies on the citizens' walk group "
                             f"{wg.get('home')}, which the cut-off group there cannot reach")
        return stranded
    home = wg.get("home")
    keep, far = [], []
    for c in cands:
        w = walk_at(snap, c["anchor"])
        if w == "0":
            far.append(c)
            continue
        if w == "1":
            c["walk"] = home
        keep.append(c)
    if far and not keep:
        raise ValueError(f"{tpl}: all {len(far)} candidate site(s) lie in a walk group the citizens cannot reach (they stand in "
                         f"walk group {home}, e.g. the far side of a brook or a cave); open a way there (a bridge, a ramp, "
                         "a stair) or choose another level")
    return keep


def _no_store(snap, p, manifest, bad, hid, mk, wet) -> str:
    """FR-69: why the refuge drink store has no site beside the refuge room, and the largest smaller store that has one
    (the refuge room's walls hold rooms, sumps, stairs and levers; a cramped refuge leaves rock only for a small one)."""
    if not manifest.get("refuge"):
        return ("refuge_drink: no refuge in the fort manifest (fortcore stage 3 digs the refuge room the store is dug "
                "from)")
    where = ", ".join(f"{b[0]}-{b[3]},{b[1]}-{b[4]} z{b[2]}" for b in refuge_rooms(manifest)[:2])
    shape = rooms.drink_room(p["n"])
    head = f"refuge_drink: no site for {p['n']} barrels ({shape[0]}x{shape[1]}) beside the refuge room {where}"
    tried = {shape}
    for k in (9, 6, 4, 2):
        wh = rooms.drink_room(k)
        if k >= p["n"] or wh in tried:
            continue
        tried.add(wh)
        q = {**p, "n": k}
        c = _rooms(snap, "refuge_drink", q, footprint("refuge_drink", q), bad, hid, mk, manifest, wet)
        try:
            c = cavern_keep(c, "refuge_drink", snap, manifest)       # BUG-482: a smaller store beside cavern water is none
        except ValueError:
            c = []
        if c:
            return (f"{head}: no wall of it has rock or unknown tiles for that room and its wall ring; a smaller store "
                    f"fits: n={k} ({wh[0]}x{wh[1]}): dfllm bp sites refuge_drink n={k}")
    return (f"{head}, not even a 3x1 store (2 barrels): no wall of it has rock or unknown tiles behind it for a room "
            "and its wall ring (rooms, sumps, stairs, levers or caves beside it); the refuge needs a well or cistern of "
            "its own (dfllm bp sites cistern level=refuge) or its drink carried in")


# ---------------------------------------------------------------- BUG-040: a hospital only near accepted water
WATER_TPLS = ("hospital",)            # templates whose sites follow the kernel's accepted water (BUG-034/040)


def zone_box(tpl: str, p: dict, anchor, rot: int) -> list[int]:
    """The room's zone rect [x0, y0, z0, x1, y1, z1] at a placement (the template's room bbox, rotated): what water.lua
    measures a hospital's water from."""
    plan = TEMPLATES[tpl][0](check_params(tpl, p))
    b = plan.rooms[0]["bbox"]
    x0, y0, x1, y1 = _rot_rect((b[0], b[1], b[3], b[4]), anchor[0], anchor[1], rot)
    return [x0, y0, anchor[2] + b[2], x1, y1, anchor[2] + b[5]]


def box_dist(pt, box) -> int:
    """water.lua dist_box: Chebyshev distance from a tile to a rect, z included."""
    d = [max(box[k] - pt[k], 0, pt[k] - box[k + 3]) for k in range(3)]
    return max(d)


def _pos(t) -> str:
    return ",".join(str(int(v)) for v in t)


def src_label(water: dict, i: int) -> str:
    """'well 19098 at 137,77,143 in Kern+' (state water.src_l) or 'accepted water at 137,77,143'."""
    lbl = water.get("lbl") or []
    pos = _pos(water["src"][i])
    if i < len(lbl) and isinstance(lbl[i], str) and lbl[i]:
        kind, _, inn = lbl[i].partition(" in ")
        return f"{kind} at {pos}" + (f" in {inn}" if inn else "")
    return f"accepted water at {pos}"


def refuge_water(water: dict) -> str:
    """BUG-040 (Run 11: Tiefe+ z129-136 had no accepted water, the one wet well stood in Kern+): '; no accepted water in
    Tiefe+ (126-128,56-77 z129-136; nearest: well 19098 at 137,77,143 in Kern+, 9 tiles from Tiefe+)', '' while a
    wet well stands in the refuge (state water.refuge_ok) or its place is not known (state alert.ref box/wd/ws)."""
    ref = water.get("refuge") or {}
    box = ref.get("box")
    if not (isinstance(box, list) and len(box) == 6) or ref.get("ok") == 1:
        return ""
    name = ref.get("name") or "Tiefe+"
    where = f"{box[0]}-{box[3]},{box[1]}-{box[4]} z{box[2]}-{box[5]}"
    src, wd, ws = water.get("src") or [], ref.get("wd", -1), ref.get("ws")
    if not src or not isinstance(wd, int) or wd < 0:
        return f"; no accepted water in {name} ({where})"
    i = next((k for k, s in enumerate(src) if list(s) == list(ws or [])), 0)
    return f"; no accepted water in {name} ({where}; nearest: {src_label(water, i)}, {wd} tiles from {name})"


def _near_water(cands: list, tpl: str, p: dict, water: dict) -> list:
    """Candidates whose zone lies within `near` of an accepted source (water.lua served()), scored +2 per tile nearer;
    ValueError when there is no accepted source or no candidate near one."""
    src = [list(s) for s in water.get("src") or [] if isinstance(s, (list, tuple)) and len(s) == 3]
    water = {**water, "src": src}
    near = water.get("near") or WATER_NEAR
    rw = refuge_water(water)
    if not src:
        # BUG-262/263: a well fed only by its own pond is no accepted water (water.lua M.loops, the same state); without a
        # brook an aquifer level is one (a cistern with p.water aquifer)
        raise ValueError(f"{tpl}: no accepted water in the fort (state water.src is empty: no well over water, no water "
                         "zone on water >= 4/7; a well fed only by its own pond is none): a hospital without it is worse "
                         "than none (BUG-034); water first (dfllm cmd inspect '{\"what\":\"water_sources\"}'; no brook: "
                         "dfllm bp sites cistern water=aquifer on a known aquifer level)" + rw
                         + (f"; the water scan found: {water['cand']} (BUG-324: the kernel zones it as Water Source "
                            "dfllm-water itself while none is accepted; the sites follow a game day later)"
                            if water.get("cand") else ""))
    out, best = [], None
    for c in cands:
        zb = zone_box(tpl, p, c["anchor"], c["rot"])
        d, i = min((box_dist(s, zb), k) for k, s in enumerate(src))
        if best is None or d < best[0]:
            best = (d, c, i)
        if d <= near:
            out.append({**c, "score": c["score"] + 2 * (near - d), "water": {"d": d, "src": src[i]},
                        "why": c["why"] + f", {src_label(water, i)} {d} tiles"})
    if not out:
        if best is None:
            raise ValueError(f"{tpl}: no valid site on the snapshot (nearest accepted water: {src_label(water, 0)}){rw}")
        d, c, i = best
        raise ValueError(f"{tpl}: no site within {near} tiles of accepted water (nearest: {src_label(water, i)}; the "
                         f"nearest candidate {_pos(c['anchor'])} rot{c['rot']} is {d} tiles from it){rw}: dig the core "
                         f"toward that water (a surface fort: `bp sites {tpl} surface=1` offers the open ground beside it; an "
                         f"explicit anchor A<x>_<y>_<z> must pass this same test, BUG-502) or "
                         "bring water nearer (a water zone on deep water, a piped cistern: python -m "
                         "dfpilot.bp.sites cistern)")
    return out


BUCKET_STEPS_MAX = 40       # BUG-469: farther than this a bucket-fed cistern stays dry (same as water.patient_far / drink_far)


def fill_source(snap: dict, manifest: dict | None) -> dict:
    """BUG-040 (Run 11: the cisterns y450s0b0 and y452s1b0 were done and their wells stayed dry): what a bucket-fed
    cistern (no pipe) could be filled from: a revealed body of drinkable water (>= 8 tiles: a brook, river or lake; not
    one with a cavern mark, not water inside the fort's own geometry such as a sump or a cistern) that a walker reaches
    from the civilian core (Z4). A wet well is no fill source (live L6: the carriers take from the nearest source, the
    cistern's own well once it is wet, and water.lua removes such a pond as a loop). Returns {ok, why, steps, at, far}."""
    z4 = ((manifest or {}).get("zones") or {}).get("Z4") or []
    cav = {tuple(q) for q in (snap.get("marks") or {}).get("cavern", []) if isinstance(q, (list, tuple))}
    fort = [(b[0] - 1, b[1] - 1, b[2] - 1, b[3] + 1, b[4] + 1, b[5] + 1) for b in topo.fort_boxes(manifest or {})]

    def inside(t):
        return any(b[0] <= t[0] <= b[3] and b[1] <= t[1] <= b[4] and b[2] <= t[2] <= b[5] for b in fort)
    keep, ncav = [], 0
    for comp in _water_components(snap, 8):
        if any((x + dx, y + dy, z + dz) in cav for x, y, z in comp for dx in (-1, 0, 1) for dy in (-1, 0, 1)
               for dz in (-1, 0, 1)):
            ncav += 1
            continue
        if any(inside(t) for t in comp):
            continue
        keep.append(comp)
    sid = snap.get("id", "?")
    cv = f" ({ncav} cavern water bod{'y' if ncav == 1 else 'ies'}: never)" if ncav else ""
    if not keep:
        return {"ok": False, "steps": None, "at": None,
                "why": f"no revealed brook, river or lake (>= 8 tiles) on snapshot {sid}{cv}"}
    if not z4:
        return {"ok": None, "steps": None, "at": None, "why": "the fort manifest has no core (zones.Z4): not checked"}
    g = Graph(snap)
    dist = water_steps(g, [t for comp in keep for t in comp], ice_tiles(snap), other_group(snap, g))
    core = g.mask(z4)
    steps = min((d for i, d in dist.items() if core[i]), default=None)
    if steps is None:
        return {"ok": False, "steps": None, "at": None,
                "why": f"no revealed brook, river or lake (>= 8 tiles) reachable on foot from the core on snapshot "
                       f"{sid}{cv}"}
    i = min((k for k, d in dist.items() if core[k] and d == steps))
    while dist[i] > 0:                                       # downhill to the bank tile a carrier fills at
        nxt = next((j for j in g.adj.get(i, ()) if dist.get(j) == dist[i] - 1), None)
        if nxt is None:
            break
        i = nxt
    at = list(g.pos(i))
    # BUG-469 (Run 16d i4 / 16c i3: cisterns 87-106 steps from the pond zone, the wells dry after 30 days): `far` = the carriers walk
    # more than BUCKET_STEPS_MAX steps; the water is there (ok), but a bucket-fed cistern does not fill from it in any useful time
    far = steps > BUCKET_STEPS_MAX
    return {"ok": True, "steps": steps, "at": at, "far": far,
            "why": f"revealed water at {_pos(at)}, {steps} steps from the core on snapshot {sid}"
                   + (f" (> {BUCKET_STEPS_MAX}: too far for bucket carriers)" if far else "")}


SEAL_OPEN = {"floor": ".^", "ramp": "r", "stair_up": "<", "stair_down": ">", "stair_updown": "X", "stair": "<>X"}


def _seal(snap: dict, p: dict) -> list[dict]:
    """seal: the one site is its first opening (absolute tiles, rot 0). Every revealed opening must still be open
    with the shape its kind names, and every piece's tile must take it (a ramp top must be open space above the
    ramp); a tile outside the snapshot is taken as given (the entrance check saw it)."""
    pcs = defense.seal_pieces(p)
    at = _At(snap)
    for pc in pcs:
        c = at(*pc["pos"])
        if c == "?":
            raise ValueError(f"seal: {pc['why']}: tile {pc['pos'][0]},{pc['pos'][1]},{pc['pos'][2]} is not revealed on "
                             f"snapshot {snap.get('id', '?')} (undug or unexplored rock: there may be no opening there): "
                             "look at the tile in the game, then dfllm bp sites seal --fresh; never reveal it by tool "
                             "(fair play). `seal at=refuge` moves a stair hatch to the nearest revealed tile of the same stair")
        want = SEAL_OPEN.get(pc["kind"], ".")
        if c is not None and c not in want:
            raise ValueError(f"seal: {pc['why']}: the snapshot shows {c!r}, not the {pc['kind']} (closed already?)")
        top = at(*pc["at"]) if pc["at"] != pc["pos"] else None
        if top is not None and top not in "_v":
            raise ValueError(f"seal: {pc['why']}: the ramp top is {top!r}, not open space")
    return [{"id": "S1", "anchor": list(pcs[0]["pos"]), "rot": 0, "score": 1000,
             "why": "; ".join(pc["why"] for pc in pcs)}]


def _defense(snap: dict, tpl: str, p: dict, manifest: dict | None) -> list[dict]:
    """gallery_o1: the one site the fortcore manifest fixes (defense.frame), if the revealed tiles allow it; raises
    ValueError with the reason otherwise (one possible site: the reason is more use than an empty ranking).
    seal: see _seal."""
    if tpl == "seal":
        return _seal(snap, p)
    anchor, rot = defense.frame(manifest)
    X = Xform(anchor, rot)
    why = defense.site_problem(_At(snap), X)
    marks = {tuple(q) for k in MARKS for q in snap.get("marks", {}).get(k, [])}
    dug = [X.pos(u, v, 0) for u, v in defense.FLINE + defense.inside_tiles()]
    if not why and marks & set(dug):
        why = "a damp, warm, cavern or water mark on the corridor"
    if why:
        raise ValueError(f"{tpl} at {anchor} rot{rot}: {why}")
    hid = sum(_At(snap)(*t) == "?" for t in dug)
    return [{"id": "S1", "anchor": anchor, "rot": rot, "score": 1000 - hid // 10,
             "why": f"rot{rot}, the O1 frame of the fortcore manifest, {hid} unknown tiles"}]


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
    if r["tpl"] in ("fortcore", "deepcore"):              # FR-103: the deep core's dorm too
        return r["id"].rsplit("_", 1)[-1] in ("dorm", "refuse", "refuge")
    return r["tpl"] in NO_THROUGH


def _private_boxes(m: dict) -> list[list[int]]:
    """Private room boxes; a cistern's well room counts with the basin under it and one tile around (live L4:
    follow placed three tombs whose anchors lay in the refuge cistern's basin, which emit had added to Z4)."""
    out = []
    for r in m.get("rooms", []):
        b = r["bbox"]
        if r["tpl"] == "cistern":
            out.append([b[0] - 1, b[1] - 1, b[2] - 1, b[3] + 1, b[4] + 1, b[5]])
        elif _private(r):
            out.append(b)
    return out


def _public(g: Graph, m: dict) -> bytearray:
    """Z4 tiles a new room may open from: reachable from Z4 outside private rooms without crossing a door."""
    z4 = g.mask(m["zones"]["Z4"])
    private = g.mask(_private_boxes(m))
    doors = bytearray(c == "+" for c in g.t)
    src = [i for i in range(g.N) if z4[i] and g.walk[i] and not private[i] and not doors[i]]
    seen, _ = g.bfs(src, blocked=doors, climb=False)
    return bytearray(a & b for a, b in zip(seen, z4))


def refuge_rooms(m: dict) -> list[list[int]]:
    """bboxes of the refuge room(s): fortcore rooms with the `_refuge` suffix on the refuge anchor's level."""
    ref = m.get("refuge")
    if not ref:
        return []
    zr = ref["anchor"][2]
    out = [r["bbox"] for r in m.get("rooms", []) if r["tpl"] == "fortcore" and r["id"].endswith("_refuge")
           and r["bbox"][2] <= zr <= r["bbox"][5]]
    return out or [[*ref["anchor"], *ref["anchor"]]]


# BUG-319 (Run 15b Earthboat y385: three refuge_beds rooms and the drink store took every wall of the 7x9 refuge room;
# `bp sites refuge_beds --fresh` found none, plan check's bed ERROR stopped the year plan): the refuge grows from its own
# rooms too. A refuge-level room (refuge_beds, refuge_drink) lies in the refuge burrow and opens only into the refuge, so
# a new one dug off its floor (footprint and wall ring rock or unknown) adds no way in either. Such anchors rank after the
# refuge room's own (REFUGE_EXT_PEN)
REFUGE_EXT_PEN = 20


def refuge_ext(m: dict) -> list[list[int]]:
    """BUG-319: bboxes of the manifest's refuge-level rooms (rooms.REFUGE_LEVEL templates) on the refuge anchor's level."""
    ref = m.get("refuge")
    if not ref:
        return []
    zr = ref["anchor"][2]
    return [r["bbox"] for r in m.get("rooms", []) if isinstance(r, dict) and r.get("tpl") in rooms.REFUGE_LEVEL
            and isinstance(r.get("bbox"), list) and len(r["bbox"]) == 6 and r["bbox"][2] <= zr <= r["bbox"][5]]


def _lever_tiles(m: dict) -> set[tuple[int, int, int]]:
    return {tuple(p) for b in m.get("bridges", {}).values() for p in b.get("levers", [])}


def on_refuge(tpl: str, p: dict) -> bool:
    """Templates that sit on the refuge level: refuge_beds (Run 10), refuge_drink (FR-69), a cistern with
    level=refuge."""
    return tpl in rooms.REFUGE_LEVEL or (tpl == "cistern" and p.get("level") == "refuge")


def civ_stair_tiles(m: dict) -> set[tuple[int, int, int]]:
    """BUG-157 (live i4: hospital S1 and tombs on the stair at 77,68, tombs at its head 77,68,125, the refuge hatch tile):
    every tile of the manifest's civilian stair columns (stairs.civ [x, y, z0, z1]); the refuge's hatch tile is the one
    of them above the refuge level."""
    out = set()
    for c in (m.get("stairs") or {}).get("civ") or []:
        if isinstance(c, (list, tuple)) and len(c) == 4 and all(isinstance(v, int) for v in c):
            out |= {(c[0], c[1], z) for z in range(min(c[2], c[3]), max(c[2], c[3]) + 1)}
    return out


def _anchor_tiles(g: Graph, tpl: str, p: dict, manifest: dict) -> list[int]:
    """Room anchors: public Z4 floor; refuge_beds and a cistern with level=refuge: floor of the refuge room or (BUG-319)
    of a refuge-level room dug off it (no lever tile). BUG-157: never a tile of a civilian stair column (the refuge's hatch tile among them): a room opens next to
    the stair, its door never on the citizens' stair or where the seal puts the hatch."""
    stair = civ_stair_tiles(manifest)
    if on_refuge(tpl, p):
        m = g.mask(refuge_rooms(manifest) + refuge_ext(manifest))     # BUG-319: and off its own rooms
        levers = _lever_tiles(manifest)
        return [i for i, c in enumerate(g.t) if m[i] and c in ".X" and g.pos(i) not in levers and g.pos(i) not in stair]
    public = _public(g, manifest)
    return [i for i, c in enumerate(g.t) if c in ".X" and public[i] and g.pos(i) not in stair]


class _At:
    """Legend char at an absolute tile of a snapshot (None outside)."""

    def __init__(self, snap: dict):
        self.x0, self.y0, self.z0, self.x1, self.y1, self.z1 = snap["bbox"]
        self.rows = snap["rows"]

    def __call__(self, x, y, z):
        if not (self.x0 <= x <= self.x1 and self.y0 <= y <= self.y1 and self.z0 <= z <= self.z1):
            return None
        return self.rows[f"z{z}"][y - self.y0][x - self.x0]


def _rock_top_ok(at, B, G) -> bool:
    """BUG-424 (Run 16a i1 Manorsubtle: the brook ran in a rock gully 8 tiles from the start room, no bank floor beside it, so the
    cistern had no intake): the shaft top B and the breach tile G (absolute x, y, z at the intake level) may be rock when the whole
    intake is sealed rock: both tiles and every tile round B are rock or unknown, the ring of G is rock, unknown or water, and
    rock or unknown lies right above both. The template digs them (shaft, breach); nobody frees-digs beside the water."""
    if at(*B) not in GOOD or at(*G) not in GOOD:
        return False
    for x, y, z in (B, G):
        if (at(x, y, z + 1) or "?") not in GOOD:
            return False
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            if at(B[0] + dx, B[1] + dy, B[2]) not in GOOD:
                return False
            c = at(G[0] + dx, G[1] + dy, G[2])
            if c not in GOOD and c not in WATER:
                return False
    return True


def intake_ok(at, L: dict, X: Xform) -> str:
    """'' if the cistern's intake fits the revealed terrain at this placement, else the reason."""
    (bu, bv), (du, dv), wt = L["shaft"], L["side"], L["w_top"]
    G, W = (bu + du, bv + dv), (bu + 2 * du, bv + 2 * dv)
    if (at(*X.pos(bu, bv, wt)) != "." or at(*X.pos(*G, wt)) != ".") \
            and not _rock_top_ok(at, X.pos(bu, bv, wt), X.pos(*G, wt)):       # BUG-424: a sealed rock intake is one too
        return "shaft top or breach tile is not revealed bank floor"
    if at(*X.pos(*G, wt - 1)) not in GOOD:
        return "no rock under the breach tile"
    if not any(at(*X.pos(u, v, w)) in WATER for u, v, w in L["water"][:1]):
        return "no revealed water behind the breach tile"
    for u, v in L["pipe"]:
        if (at(*X.pos(u, v, 0)) or "?") in OPEN_UP:
            return "a pipe tile lies under an open or wet tile"
    return ""


def _rect_boxes(rects, ax, ay, az, rot):
    for w, lst in rects.items():
        for r in lst:
            x0, y0, x1, y1 = _rot_rect(r, ax, ay, rot)
            yield (x0, y0, az + w, x1, y1, az + w)


def aquifer_levels(manifest: dict | None) -> set[int]:
    """FR-95: the manifest's `aquifer_levels` (levels the kernel saw damp or wet on revealed tiles)."""
    return {int(z) for z in (manifest or {}).get("aquifer_levels") or [] if isinstance(z, int) and not isinstance(z, bool)}


def snapshot_aquifer(snap: dict | None) -> dict[int, int]:
    """BUG-359: {z: revealed tiles with the aquifer flag} of a sites export (snapshot `aqz`; hidden tiles never count)."""
    out: dict[int, int] = {}
    for k, n in ((snap or {}).get("aqz") or {}).items():
        try:
            z = int(str(k)[1:])
        except ValueError:
            continue
        if isinstance(n, int) and not isinstance(n, bool) and n > 0:
            out[z] = n
    return out


def known_aquifer(snap: dict | None, manifest: dict | None) -> set[int]:
    """BUG-359 (Run 16c: 'light aquifer' at embark, then heavy_aquifer at z118, a lake at z120): every level known wet
    without digging first: the manifest's aquifer_levels (the kernel saw damp or wet), the levels with a revealed
    aquifer tile on the snapshot (aqz) and the wet layers the recorded breaches show (`_breach_layers`)."""
    return aquifer_levels(manifest) | set(snapshot_aquifer(snap)) | set(_breach_layers(manifest))


def aquifer_ok(cands: list, tpl: str, p: dict, rects: dict, manifest: dict | None, snap: dict | None = None) -> list:
    """FR-95: rooms keep off the aquifer levels and off the level right below one (water drips from an aquifer ceiling;
    one dry solid level stays between an aquifer and a room under it); shafts (explore) may pass. fortcore p.aquifer =
    above: its deepest level above every aquifer level; = pass: its deepest level at least one dry level below them;
    '' as before (not filtered)."""
    aq = known_aquifer(snap, manifest)
    if not aq or tpl in mine.BUILD:
        return cands
    if tpl == "fortcore":
        mode = p.get("aquifer", "")
        if not mode:
            return cands
        low = min(rects) if rects else 0
        if mode == "above":
            return [c for c in cands if c["anchor"][2] + low > max(aq)]
        return [c for c in cands if c["anchor"][2] + low + 1 < min(aq)]
    # BUG-447 (Run 16c i3 Castletongs: refuge_drink 'none (0 ranked)' for years, 27 sites on the refuge level all dropped here): the
    # refuge room itself stands on aquifer level z119 and right under z120, it was dug there and holds. A refuge-level room dug off
    # it (refuge_beds, refuge_drink, a refuge cistern) lies on the very levels the refuge occupies, so those levels do not rule it
    # out (damp and aquifer marks still do, they are marked tiles of the ranking); every other level of the rule stays
    if manifest and manifest.get("refuge") and on_refuge(tpl, p):
        aq = aq - {z for b in refuge_rooms(manifest) for z in range(b[2], b[5] + 2)}
        if not aq:
            return cands
    out = []
    for c in cands:
        z0, z1 = c["box"][2], c["box"][5]
        if not any(z0 <= z <= z1 + 1 for z in aq):
            out.append(c)
    return out


CAV_KEEP = 4        # BUG-482: tiles (x/y/z) a room or refuge site keeps from known cavern water


def cavern_water(snap: dict | None, manifest: dict | None) -> list[tuple[int, int, int]]:
    """BUG-482 (Run 16b i2 Roadvises y398-y400: the refuge z107 lay beside a cavern lake at 91,110,107, refuge_beds was drafted there
    twice and `plan check` demanded it again): the tiles known to be cavern water or an opening into a cavern: the manifest's
    recorded cavern stops (`caverns`), the recorded breaches that were a cavern lake, and the revealed water tiles that carry a
    cavern mark on the snapshot. Hidden rock is unknown and never listed."""
    out: set[tuple[int, int, int]] = set()
    for q in (manifest or {}).get("caverns") or []:
        if isinstance(q, (list, tuple)) and len(q) == 3 and all(isinstance(v, int) for v in q):
            out.add((q[0], q[1], q[2]))
    for b in (manifest or {}).get("breaches") or []:
        pos = b.get("pos") if isinstance(b, dict) else None
        if str((b or {}).get("why", "")).startswith("cavern") and isinstance(pos, (list, tuple)) and len(pos) == 3:
            out.add((int(pos[0]), int(pos[1]), int(pos[2])))
    if snap and snap.get("rows"):
        at = _At(snap)
        for q in (snap.get("marks") or {}).get("cavern", []):
            if isinstance(q, (list, tuple)) and len(q) == 3 and at(*q) in WET:
                out.add((int(q[0]), int(q[1]), int(q[2])))
    return sorted(out)


def cavern_keep(cands: list, tpl: str, snap: dict, manifest: dict | None) -> list:
    """BUG-482: room sites (a refuge-level room among them) keep CAV_KEEP tiles from known cavern water: a site whose box, grown
    by CAV_KEEP in x/y and one level in z, holds a `cavern_water` tile is dropped. ValueError naming the water when that leaves
    nothing (the refuge room cannot move: plan check then warns instead of demanding the template)."""
    pts = cavern_water(snap, manifest)
    if not pts or not cands:
        return cands
    out, hit = [], None
    for c in cands:
        x0, y0, z0, x1, y1, z1 = c["box"]
        w = next((q for q in pts if x0 - CAV_KEEP <= q[0] <= x1 + CAV_KEEP and y0 - CAV_KEEP <= q[1] <= y1 + CAV_KEEP
                  and z0 - 1 <= q[2] <= z1 + 1), None)
        if w is None:
            out.append(c)
        elif hit is None:
            hit = w
    if not out:
        raise ValueError(f"{tpl}: all {len(cands)} candidate site(s) lie within {CAV_KEEP} tiles of known cavern water "
                         f"(e.g. {_pos(hit)}); a room keeps off it (a breach into a cavern floods or lets the invaders in): "
                         "another quadrant, or none now")
    return out


HEAVY_WHY = ("heavy_aquifer", "water")      # BUG-262: breach stops that show a heavy aquifer (visible water, not damp)


def aquifer_well(cands: list, snap: dict, manifest: dict | None) -> list:
    """BUG-262 (Run 15 Inkintense, Guildcleans: no brook, a light aquifer, 'hospital held back (BUG-034)' for good): the
    sites of a cistern with p.water = aquifer, whose basin (one level below the well room) is dug into an aquifer level so
    the aquifer seeps into it under the well. The aquifer levels are the manifest's `aquifer_levels` and the levels of the
    snapshot's damp marks (revealed tiles only). A site counts when its basin level is one of them, its room level and the
    level above the room are none (no drip into the room), and no heavy aquifer was recorded on the basin level (a breach
    stop with visible water: manifest `breaches` why heavy_aquifer/water). ValueError with the reason when none is left."""
    aq = aquifer_levels(manifest)
    for q in (snap.get("marks") or {}).get("damp", []):
        if isinstance(q, (list, tuple)) and len(q) == 3:
            aq.add(int(q[2]))
    if not aq:
        raise ValueError("cistern water=aquifer: no aquifer level known (no manifest aquifer_levels, no damp mark on the "
                         "snapshot): an aqshaft or a dig that met damp stone shows one first")
    heavy = {int(b["pos"][2]) for b in (manifest or {}).get("breaches") or []
             if isinstance(b, dict) and b.get("why") in HEAVY_WHY and isinstance(b.get("pos"), (list, tuple))
             and len(b["pos"]) == 3}
    out = []
    for c in cands:
        z = c["anchor"][2]
        if z - 1 in aq and z not in aq and z + 1 not in aq and z - 1 not in heavy:
            out.append({**c, "why": c["why"] + f", basin on aquifer level z{z - 1}"})
    if not out:
        lv = ",".join(f"z{z}" for z in sorted(aq))
        hv = f"; heavy (refused): {','.join(f'z{z}' for z in sorted(heavy))}" if heavy else ""
        raise ValueError(f"cistern water=aquifer: no site with its basin on an aquifer level ({lv}) under a dry room level"
                         f"{hv}: the room level must lie right above an aquifer level and be dry itself")
    return out


def _rooms(snap, tpl, p, rects, bad, hid, mk, manifest, wet=None):
    g = Graph(snap)
    steps_of = _stair_steps(g)
    keep_out = _keep_out(manifest)
    ref = manifest.get("refuge")
    zr = ref["anchor"][2] if ref else None
    farm = tpl == "farms"
    cis = rooms.cistern_layout(p) if tpl == "cistern" else None
    intake = bool(cis and cis["intake"])
    refuge_level = on_refuge(tpl, p)
    own = g.mask(refuge_rooms(manifest)) if refuge_level else None      # BUG-319: anchors off it rank after
    core_rects = footprint("cistern", {**p, "path": ""}) if intake else rects
    at = _At(snap)
    if farm:
        soil_pts = [tuple(q) for q in snap.get("marks", {}).get("soil", [])]
        soil = _Pref(snap, points=soil_pts)
        plots = plot_rects(p)
        area = sum((r[2] - r[0] + 1) * (r[3] - r[1] + 1) for r in plots)
        top = max(b[5] for b in manifest["zones"]["Z4"])
        slv = soil_level_set(soil_levels(snap, manifest))      # BUG-346
    out = []
    for i in _anchor_tiles(g, tpl, p, manifest):
        ax, ay, az = g.pos(i)
        for rot in range(4):
            du, dv = rot_uv(0, 1, rot)
            door = g.idx((ax + du, ay + dv, az))
            if door is None or g.t[door] not in GOOD:
                continue
            if intake and intake_ok(at, cis, Xform((ax, ay, az), rot)):
                continue                                   # cheap test first: the pipe must end at real water
            res = _check(rects, ax, ay, az, rot, bad, hid, mk, False, wet)
            if res is None:
                continue
            unknown, _, box = res
            # a pipe's bbox spans half the map: its keep-out test goes per tile ring
            parts = _rect_boxes(rects, ax, ay, az, rot) if intake else (box,)
            if any(_overlap(r, b) for r in parts for b in keep_out):
                continue
            core = box
            if intake:
                cb = list(_rect_boxes(core_rects, ax, ay, az, rot))
                core = (min(b[0] for b in cb), min(b[1] for b in cb), min(b[2] for b in cb),
                        max(b[3] for b in cb), max(b[4] for b in cb), max(b[5] for b in cb))
            if zr is not None and core[2] <= zr <= core[5] and not refuge_level:
                continue                                   # the refuge level stays the refuge's own
            steps = min(steps_of.get(i, 99), 99)
            score = 1000 - 5 * steps - unknown // 10
            why = f"rot{rot}, {steps} steps to a stair, {unknown} unknown tiles"
            if own is not None and not own[i]:
                score -= REFUGE_EXT_PEN
                why += ", dug off a refuge-level room (BUG-319)"
            if intake:
                why += f", pipe {len(cis['pipe'])} tiles to the water"
                box = core
            if farm:
                # BUG-346 (Run 15 Guildcleans y381, Inkintense: 'only 0 free site(s) for farms' for years though the fort's
                # z128 floors were 499 of 499 soil): the snapshot marks soil on revealed floor only, never on the rock or
                # hidden tiles a farm room is dug from, so every room site counted 'soil 0/70'. On a soil level (the
                # fort's own dug Z4 floor there is soil, soil_levels) the undug plot tiles count as soil: the layer.
                s = lv = 0
                for r in plots:
                    x0, y0, x1, y1 = _rot_rect(r[:4], ax, ay, rot)
                    m = soil.count(x0, y0, x1, y1, az + r[4]) or 0
                    s += m
                    if az + r[4] in slv:
                        lv += (x1 - x0 + 1) * (y1 - y0 + 1) - m
                s += lv
                # BUG-257 (Run 15 Inkintense/Drillchamber: farms on 'soil 0/70' sites, build_lost 'missing p' for 8
                # seasons): quickfort builds farm plots only on soil or mud, so with the soil known (the snapshot's soil
                # marks) a site needs soil under half its plot tiles; unknown soil stays a warning (plan check)
                if soil_pts and 2 * s < area:
                    continue
                score += 10 * s - 25 * (top - az)
                if soil_pts:
                    why += f", soil {s}/{area} plot tiles" + (f" ({lv} by the soil level)" if lv else "")
                else:
                    why += ", soil unknown"
                why += f", {top - az} levels below the top of Z4"
            out.append({"anchor": [ax, ay, az], "rot": rot, "score": max(0, score), "box": box, "why": why})
    return out


SOIL_LEVEL_MIN = 8                    # BUG-346: soil-marked fort floor tiles that make a level a soil level


def soil_levels(snap: dict, manifest: dict | None) -> dict[int, tuple[int, int]]:
    """BUG-346: {z: (soil, floor)}: the fort's revealed floor tiles ('.') inside its Z4 boxes per level and how many of them
    carry a soil mark. A level whose dug floor is soil lies in a soil layer (what the player sees on the walls of every
    room dug there); a farm room dug on it gets soil floor."""
    marks = (snap.get("marks") or {}).get("soil") or []
    soil = {tuple(q) for q in marks if isinstance(q, (list, tuple)) and len(q) == 3}
    if not soil:
        return {}
    at = _At(snap)
    seen: set = set()
    out: dict[int, list[int]] = {}
    for b in ((manifest or {}).get("zones") or {}).get("Z4") or []:
        if not (isinstance(b, (list, tuple)) and len(b) == 6):
            continue
        for z in range(b[2], b[5] + 1):
            for x in range(b[0], b[3] + 1):
                for y in range(b[1], b[4] + 1):
                    t = (x, y, z)
                    if t in seen or at(x, y, z) != ".":
                        continue
                    seen.add(t)
                    row = out.setdefault(z, [0, 0])
                    row[1] += 1
                    row[0] += t in soil
    return {z: (v[0], v[1]) for z, v in out.items()}


def soil_level_set(levels: dict) -> set[int]:
    """BUG-346: the soil levels: at least SOIL_LEVEL_MIN soil floor tiles and half the level's fort floor."""
    return {z for z, (s, f) in levels.items() if s >= SOIL_LEVEL_MIN and 2 * s >= f}


def farm_soil_why(snap: dict, manifest: dict | None) -> str:
    """BUG-346: why no farms room site: the soil of the fort's levels (`z128 499/499`), named for the no-site error."""
    lv = soil_levels(snap, manifest)
    if not lv:
        return "farms: no soil marks in this snapshot (the soil is unknown)"
    slv = soil_level_set(lv)
    each = ", ".join(f"z{z} {s}/{f}" for z, (s, f) in sorted(lv.items(), reverse=True)[:5])
    if not slv:
        return (f"farms: no soil level in the fort (soil on its dug floor: {each}); farm plots need soil, a dug stone "
                "floor has none: a surface farm (p.surface=1, in PEACE) or trade for food")
    return (f"farms: soil levels {', '.join(f'z{z}' for z in sorted(slv, reverse=True))} (soil on the dug floor: {each}); "
            "no room site there is free of rock-ring, keep-out or refuge rules")


SURFACE_NEAR = 12                     # BUG-297: a surface farm lies inside Z4 or within this many tiles of the entrance
MUD_WET_R = 3                         # BUG-407: a muddy plot keeps this many tiles from water (irrigation is risky)
FAR_SCORE = 500                       # BUG-407: a plot beyond SURFACE_NEAR scores below any near one (<= this, - 1 per tile)


def _marks_of(snap: dict, kind: str) -> set:
    return {tuple(q) for q in (snap.get("marks") or {}).get(kind, []) if isinstance(q, (list, tuple)) and len(q) == 3}


def farm_ground_why(snap: dict, manifest: dict | None) -> str:
    """BUG-407 (Run 16a i1 Bachwald: 'only 0 free site(s) for farms surface=1' on a mountain, 13 thirsty citizens died): why a
    surface farm has no site, with the ground it looked at and what is left to do (the DECISION: trade, or a plot by hand)."""
    soil, mud = _marks_of(snap, "soil"), _marks_of(snap, "mud")
    floors = sum(str(r).count(".") for rows in (snap.get("rows") or {}).values() for r in rows)
    if not soil and not mud:
        return (f"farms surface=1: no soil and no mud floor in this snapshot ({floors} revealed floor tiles, rock ground: a farm "
                "plot needs a soil or mud floor, quickfort drops the others); DECISION: buy food and seeds from the caravans "
                "(trade.want food seeds), dig down to a soil layer (explore), or wait for rain to mud a floor and run "
                "`dfllm bp sites farms surface=1 --fresh` again; irrigation by a channel to water is risky, never near the "
                "fort's wells")
    return (f"farms surface=1: {len(soil)} soil and {len(mud)} mud floor tiles, but no plot block fits (the blocks overlap the "
            "fort's own tiles, a wall, a tree or water, or lie on another walk group than the citizens'); DECISION: fewer plots "
            "(p.plots=1), another spot (`bp sites farms surface=1 --near x,y,z`) or trade for food and seeds")


def _surface_farms(snap: dict, p: dict, manifest: dict) -> list[dict]:
    """BUG-297 (Run 15c Inkintense y376: `bp sites farms --fresh` 0 ranked, the BUG-257 soil rule refused every undug site
    and nothing else was offered; one plot for 50 citizens in a famine): farms p.surface = 1 sites. Every plot tile is a
    revealed floor ('.') with a soil mark (the snapshot's revealed soil, as the vanilla UI shows it), nothing is dug; the
    plot block lies inside a Z4 box (the walled fort, roofed: best) or within SURFACE_NEAR tiles of the fort entrance
    (manifest `edge`, the tiles in front of the fortcore door) on the entrance's level, never on the attack path, the
    military's tiles or a bridge (_keep_out), and overlaps no manifest room, workshop, depot, pit, station or stair.
    BUG-407 (Run 16a i1 Bachwald: a fort with no fortcore, 'only 0 free site(s)'; Run 16c i3 the same): (1) a muddy floor counts
    as ground (snapshot marks.mud, quickfort's has_mud: farm plots stand on soil or mud) when no tile of the block lies within
    MUD_WET_R of water; (2) when no block lies inside Z4 or near the entrance (no entrance at all without a fortcore), the
    soil or mud anywhere on the citizens' walk group is offered, FAR_SCORE minus the tiles to the entrance, the depot or the
    middle of the snapshot."""
    soil, mud = _marks_of(snap, "soil"), _marks_of(snap, "mud")
    ground = soil | mud
    if not ground:
        return []
    at = _At(snap)
    plots = plot_rects(p)
    z4 = [tuple(b) for b in (manifest.get("zones") or {}).get("Z4", [])]
    edge = [tuple(e) for e in manifest.get("edge") or [] if isinstance(e, (list, tuple)) and len(e) == 3]
    keep = list(_keep_out(manifest)) if manifest else []
    keep += [tuple(r["bbox"]) for r in manifest.get("rooms", []) if isinstance(r, dict) and len(r.get("bbox") or []) == 6]
    pts = [w.get("pos") for w in manifest.get("workshops", []) if isinstance(w, dict)]
    pts += [manifest.get("depot"), manifest.get("pit")] + list((manifest.get("stations") or {}).values())
    keep += [(q[0] - 1, q[1] - 1, q[2], q[0] + 1, q[1] + 1, q[2]) for q in pts if isinstance(q, list) and len(q) == 3]
    for kind in ("civ", "mil"):
        keep += [(s[0], s[1], s[2], s[0], s[1], s[3]) for s in (manifest.get("stairs") or {}).get(kind, []) if len(s) == 4]
    keep += [(e[0] - 2, e[1] - 2, e[2], e[0] + 2, e[1] + 2, e[2]) for e in edge]     # the way in stays clear
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    dep = manifest.get("depot")
    ref = edge[0] if edge else (dep if isinstance(dep, list) and len(dep) == 3 else None)
    cx, cy = (ref[0], ref[1]) if ref else ((x0 + x1) // 2, (y0 + y1) // 2)
    wet = _Pref(snap, lambda c: c in WET) if mud else None

    def inside(b, box):
        return box[0] <= b[0] and b[3] <= box[3] and box[1] <= b[1] and b[4] <= box[4] and box[2] <= b[2] <= box[5]

    near_out, far_out = [], []
    for (ax, ay, az) in sorted(ground):
        for rot in range(4):
            tiles, ok, nmud = [], True, 0
            for r in plots:
                rx0, ry0, rx1, ry1 = _rot_rect(r[:4], ax, ay, rot)
                for x in range(rx0, rx1 + 1):
                    for y in range(ry0, ry1 + 1):
                        t = (x, y, az + r[4])
                        if t not in ground or at(*t) != ".":
                            ok = False
                            break
                        nmud += t not in soil
                        tiles.append((x, y))
                    if not ok:
                        break
                if not ok:
                    break
            if not ok or not tiles:
                continue
            box = (min(t[0] for t in tiles), min(t[1] for t in tiles), az, max(t[0] for t in tiles),
                   max(t[1] for t in tiles), az)
            if any(_overlap(box, k) for k in keep):
                continue
            if nmud and (wet.count(box[0] - MUD_WET_R, box[1] - MUD_WET_R, box[3] + MUD_WET_R, box[4] + MUD_WET_R, az) or 0):
                continue                                # BUG-407: mud beside water floods (irrigation is risky)
            roofed = any(inside(box, b) for b in z4)
            d = min((box_dist(list(e), list(box)) for e in edge if e[2] == az), default=None)
            what = "soil floor" if not nmud else f"muddy floor ({nmud} of {len(tiles)} tiles mud)"
            if roofed or (d is not None and d <= SURFACE_NEAR):
                score = 1000 - (0 if roofed else 200 + 5 * (d or 0)) - (30 if nmud else 0)
                where = "inside the fort (Z4)" if roofed else f"{d} tiles from the entrance"
                near_out.append({"anchor": [ax, ay, az], "rot": rot, "score": max(0, score), "box": box,
                                 "why": f"rot{rot}, surface farm on {what} {where}, {len(tiles)} plot tiles, nothing dug"})
            else:
                if "0" in (walk_at(snap, (box[0], box[1], az)), walk_at(snap, (box[3], box[4], az))):
                    continue                            # another walk group than the citizens'
                dd = max(abs((box[0] + box[3]) // 2 - cx), abs((box[1] + box[4]) // 2 - cy))
                far_out.append({"anchor": [ax, ay, az], "rot": rot, "score": max(0, FAR_SCORE - dd - (30 if nmud else 0)),
                                "box": box, "why": f"rot{rot}, surface farm on {what} {dd} tiles from "
                                                   f"{'the entrance' if edge else 'the middle of the snapshot'}, "
                                                   f"{len(tiles)} plot tiles, nothing dug"})
    return near_out or far_out


SHOP_NEAR = 25                        # BUG-356: a startup block within this many tiles of the fort entrance scores best


SURFACE_TOP_MIN = 25                  # BUG-399: floor tiles on the top level that make an empty answer suspicious


def surface_top_floor(snap: dict) -> int:
    """BUG-399 (Run 16c i3: `bp sites depot` 0 sites for years, 8,366 floor tiles on the snapshot's top level z127): the floor
    tiles of the top level, where the sky check of the surface templates has no row above it to read."""
    try:
        return sum(str(r).count(".") for r in snap["rows"][f"z{snap['bbox'][5]}"])
    except (KeyError, TypeError, IndexError):
        return 0


def sky_over_floor(snap: dict) -> bool:
    """BUG-404 (Run 16b i2 Ostgate: the BUG-399 guard fired on a snapshot z127..z138 whose surface lies at z131 and whose top
    level z138 is a mountain peak with 1865 floor tiles; `surfacecore`, bedrooms, dining and tavern were refused 'no level above
    it to show open sky' for days while `office surface=1` found 4 sites): True when the snapshot shows open sky ('_') right above a
    floor ('.') anywhere. Then the export does reach above the surface, the guard's reading (the box ends AT the surface) is wrong,
    and an empty answer is a real 'no valid site'."""
    try:
        z0, z1 = snap["bbox"][2], snap["bbox"][5]
        for z in range(z0, z1):
            lo, up = snap["rows"].get(f"z{z}"), snap["rows"].get(f"z{z + 1}")
            if not lo or not up:
                continue
            for rl, ru in zip(lo, up):
                if any(a == "." and b == "_" for a, b in zip(rl, ru)):
                    return True
    except (KeyError, TypeError, IndexError, AttributeError):
        return False
    return False


def _surface_shops(snap: dict, p: dict, manifest: dict, tpl: str = "workshops") -> list[dict]:
    """BUG-356 (Run 16a-d: the first year hung on the fortcore: Kueche/Still refused, drink 3 d -> 0): workshops p.surface = 1
    sites. The block (rooms.surface_block of the shops asked for) is flat open ground: every tile a revealed floor ('.') on
    one level with open sky ('_') right above it, nothing dug, on the citizens' walk group (snapshot wg) where that is read,
    clear of the fort's own tiles (the fortcore's attack path and military tiles, rooms, workshops and the way in).
    Score: 1000, - 1 per tile from the middle of the snapshot (the embark: the wagon stands there; `near` = the wagon's
    tile overrides it), + 60 when within SHOP_NEAR of the fort entrance (manifest `edge`). The caller's free callable keeps
    it off every placed project. BUG-368 (Run 16b i2 Ostgate: no trade depot without a fortcore, NO_DEPOT every year): the same
    for `depot` (tpl): one rooms.DEPOT_SIDE square of open surface floor, the depot stands where a caravan's wagon reaches it
    without the dug core. BUG-384 (Run 16c i3: 'hospital: 0 sites without a fortcore', 7 hurt): and for `hospital` with p.surface = 1,
    a 7x5 block; rank() then keeps the ones near accepted water (WATER_TPLS) like the dug hospital."""
    rect = None                              # BUG-387: the local rect that must be open floor (default: from the anchor)
    if tpl == "depot":
        W = H = rooms.DEPOT_SIDE
        what = "a trade depot"
    elif tpl == "tradepost":                 # BUG-488: the trade pile beside the depot (4x2 open surface floor)
        W, H = rooms.TRADEPOST
        what = "the trade pile"
    elif tpl == "surfacecore":               # BUG-387: the walled compound, depot apron included
        W, H = surfacecore.block(p)
        what = "the surface core"
    elif tpl in rooms.SURFACE_ROOMS:         # BUG-387: the room's walls and floor, and the tile before its doorway
        rect = rooms.BUILD[tpl](p).surface_rect
        W, H = rect[2] - rect[0] + 1, rect[3] - rect[1] + 1
        what = f"a surface {tpl}"
    elif tpl == "hospital":                  # BUG-384: the surface hospital's 7x5 block, ranked by the accepted water after
        W, H = rooms.HOSPITAL_SURFACE
        what = "a hospital"
    else:
        todo = rooms.workshops(p).workshops
        W, H = rooms.surface_block(len(todo))
        what = f"{len(todo)} shops"
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    floor = _Pref(snap, lambda c: c == ".")
    sky = _Pref(snap, lambda c: c == "_")
    edge = [tuple(e) for e in manifest.get("edge") or [] if isinstance(e, (list, tuple)) and len(e) == 3]
    keep = list(_keep_out(manifest)) if manifest else []
    keep += [tuple(r["bbox"]) for r in manifest.get("rooms", []) if isinstance(r, dict) and len(r.get("bbox") or []) == 6]
    keep += [(w["pos"][0] - 2, w["pos"][1] - 2, w["pos"][2], w["pos"][0] + 2, w["pos"][1] + 2, w["pos"][2])
             for w in manifest.get("workshops", []) if isinstance(w, dict) and isinstance(w.get("pos"), list)
             and len(w["pos"]) == 3]
    keep += [(e[0] - 2, e[1] - 2, e[2], e[0] + 2, e[1] + 2, e[2]) for e in edge]
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    if (tpl in rooms.SURFACE_ROOMS or tpl == "tradepost") and isinstance(manifest.get("depot"), (list, tuple))             and len(manifest["depot"]) == 3:
        cx, cy = manifest["depot"][0], manifest["depot"][1]      # BUG-387: a room stands beside the surface core's depot (BUG-488: the pile too)
    keep += [tuple(b) for b in (manifest.get("zones") or {}).get("Z4", []) if isinstance(b, (list, tuple)) and len(b) == 6]
    rect = rect or (0, 0, W - 1, H - 1)
    step = 2 if (x1 - x0 + 1) * (y1 - y0 + 1) > 2500 and tpl not in rooms.SURFACE_ROOMS and tpl != "tradepost" else 1
    out = []
    for z in range(z0, z1):
        cur, up = snap["rows"][f"z{z}"], snap["rows"][f"z{z + 1}"]
        for yy in range(0, len(cur), step):
            for xx in range(0, len(cur[yy]), step):
                if cur[yy][xx] != "." or up[yy][xx] != "_":
                    continue
                ax, ay = x0 + xx, y0 + yy
                for rot in range(4):
                    bx0, by0, bx1, by1 = _rot_rect(rect, ax, ay, rot)
                    if floor.count(bx0, by0, bx1, by1, z) != W * H or sky.count(bx0, by0, bx1, by1, z + 1) != W * H:
                        continue
                    box = (bx0, by0, z, bx1, by1, z)
                    if any(_overlap(box, k) for k in keep):
                        continue
                    if "0" in (walk_at(snap, (bx0, by0, z)), walk_at(snap, (bx1, by1, z)),
                               walk_at(snap, ((bx0 + bx1) // 2, (by0 + by1) // 2, z))):
                        continue                                # BUG-352: another walk group than the citizens'
                    d = max(abs((bx0 + bx1) // 2 - cx), abs((by0 + by1) // 2 - cy))
                    de = min((box_dist(list(e), list(box)) for e in edge if e[2] == z), default=None)
                    near = de is not None and de <= SHOP_NEAR
                    out.append({"anchor": [ax, ay, z], "rot": rot, "score": max(0, 1000 - d + (60 if near else 0)), "box": box,
                                "why": f"rot{rot}, {W}x{H} open surface floor for {what}, {d} tiles from the middle "
                                       "of the snapshot" + (f", {de} from the entrance" if near else "") + ", nothing dug"})
    return out


def _rebuild_shops(snap: dict, p: dict, manifest: dict) -> list[dict]:
    """BUG-562 (Run 16b i2 Brotherarrow y398-y404: Craftsdwarfs 99,119,134 and Clothiers 107,116,134 left the manifest as 'no longer
    stands' (manifest.gone), their places in the fortcore's workshop rooms stayed free, `bp sites workshops` ranks whole workshop rooms
    and said '0 free sites' / 'no valid site' for 417 days): workshops p.rebuild = 1 (one type, `only=`) ranks the entries of
    manifest.gone of that type, newest first: the shop's own footprint (3x3, 1x1 Quern / Millstone, 5x5 Kennels / Siege) centred on
    the old position, every tile a revealed floor ('.'), clear of the standing workshops of the manifest, on the citizens' walk group.
    The anchor is the old position; the doc's manifest lists the shop there again (the kernel then drops it from gone)."""
    name = rooms.workshops(p).workshops[0][0]
    side = rooms.SHOP_SIZE.get(name, 3)
    h = side // 2
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    floor = _Pref(snap, lambda c: c == ".")
    gone = [g for g in manifest.get("gone") or []
            if isinstance(g, dict) and g.get("type") == name and isinstance(g.get("pos"), (list, tuple)) and len(g["pos"]) == 3]
    if not gone:
        raise ValueError(f"workshops rebuild=1: no {name} in manifest.gone (the kernel lists a shop there once it found it gone for "
                         "rec_scans daily scans; a shop that never stood is a plain `workshops only=" + name + "`)")
    keep = [(w["pos"][0] - 2, w["pos"][1] - 2, w["pos"][2], w["pos"][0] + 2, w["pos"][1] + 2, w["pos"][2])
            for w in manifest.get("workshops") or [] if isinstance(w, dict) and isinstance(w.get("pos"), (list, tuple))
            and len(w["pos"]) == 3]
    out: list[dict] = []
    why_not: list[str] = []
    for rank_i, g in enumerate(reversed(gone)):
        x, y, z = (int(v) for v in g["pos"])
        box = (x - h, y - h, z, x + h, y + h, z)
        if not (x0 <= box[0] and box[3] <= x1 and y0 <= box[1] and box[4] <= y1 and z0 <= z <= z1):
            why_not.append(f"{x},{y},{z} lies outside the snapshot")
        elif floor.count(box[0], box[1], box[3], box[4], z) != side * side:
            why_not.append(f"{x},{y},{z}: the {side}x{side} footprint is not all open floor now")
        elif any(_overlap(box, k) for k in keep):
            why_not.append(f"{x},{y},{z}: a standing workshop of the manifest overlaps it")
        elif walk_at(snap, (x, y, z)) == "0":
            why_not.append(f"{x},{y},{z}: another walk group than the citizens'")
        else:
            out.append({"anchor": [x, y, z], "rot": 0, "score": 1000 - rank_i, "box": box,
                        "why": f"rebuild {name} where it stood ({x},{y},{z}), {side}x{side} open floor, gone from the manifest"})
    if not out:
        raise ValueError(f"workshops rebuild=1: no old place of {name} can be built again: " + "; ".join(why_not[:3])
                         + " (`dfllm bp sites workshops only=" + name + "` ranks a new room instead)")
    return out


def _furnish_hospital(snap: dict, manifest: dict) -> list[dict]:
    """BUG-581 (Run 16d i4 Trumpetrealms y411-y415: `no_table` for years in a hospital room that stood with four beds, the older template
    placed no table and no command put one there): hospital p.furnish = 1 ranks the open floor tiles ('.') of the manifest's hospital
    rooms for ONE table. A tile with more wall neighbours is better (a corner blocks no way), a tile with none (the middle of the
    room: beds and the pond hole stand there) is left out, a tile of another walk group than the citizens' too. The anchor is the tile."""
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    floor = _Pref(snap, lambda c: c == ".")
    wall = _Pref(snap, lambda c: c in "#SF")
    out: list[dict] = []
    seen = 0
    for r in manifest.get("rooms") or []:
        if not (isinstance(r, dict) and r.get("tpl") == "hospital" and isinstance(r.get("bbox"), (list, tuple)) and len(r["bbox"]) == 6):
            continue
        seen += 1
        bx0, by0, bz0, bx1, by1, bz1 = (int(v) for v in r["bbox"])
        if not (x0 <= bx0 and bx1 <= x1 and y0 <= by0 and by1 <= y1 and z0 <= bz0 <= z1):
            continue
        for y in range(by0, by1 + 1):
            for x in range(bx0, bx1 + 1):
                if (floor.count(x, y, x, y, bz0) or 0) != 1 or walk_at(snap, (x, y, bz0)) == "0":
                    continue
                walls = sum((wall.count(x + dx, y + dy, x + dx, y + dy, bz0) or 0) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                if walls == 0:
                    continue                                   # the middle of the room: beds and the pond hole stand there
                out.append({"anchor": [x, y, bz0], "rot": 0, "score": 100 * walls - abs(x - bx0) - abs(y - by0), "box": (x, y, bz0, x, y, bz0),
                            "why": f"a table inside the hospital room {r.get('id', '?')} at {x},{y},{bz0} ({walls} wall side(s))"})
    if not seen:
        raise ValueError("hospital furnish=1: no hospital room in the fort manifest (a hospital that is built is `hospital`, not furnish)")
    if not out:
        raise ValueError("hospital furnish=1: no open floor tile beside a wall inside the hospital room of the manifest")
    return out


EXPLORE_ARMS = (4, 3, 2, 1, 0)        # BUG-528: side-tunnel lengths tried (longest that fits first) when the template's own arm has no site


def _rank_arms(snap, tpl, params, manifest, n, water, near, within, at, free) -> list[dict]:
    """BUG-528 (Run 16d i4 Trumpetrealms y375-y400: a soil fort with its core at z136/z139, caverns at z124-z127: explore depth 4 to 12 found
    no site for 25 years, no ore and no hard stone, because the default 6-tile side tunnels (W, E, S) met the core's own rooms on
    every anchor; a bare shaft to z131 and z128 had 12 free anchors): when the asked arm (no p.arm = the template's default) has no
    site, the longest shorter arm of EXPLORE_ARMS that has one is ranked, every site carries it (`arm`, applied to the document
    by cmd.site_params) and says so. p.arm given is never changed. All arms empty: the error of the bare shaft (arm 0), the most
    permissive, so its reason is the real one."""
    base = dict(params or {})
    first = None
    try:
        got = rank(snap, tpl, {**base, "arm": mine.PARAMS[tpl]["arm"][0]}, manifest, n, water, near, within, at, free)
        if got:
            return got
    except ValueError as e:
        first = e
    last = first
    top = mine.PARAMS[tpl]["arm"][0]
    for arm in EXPLORE_ARMS:
        if arm >= top:
            continue
        try:
            got = rank(snap, tpl, {**base, "arm": arm}, manifest, n, water, near, within, at, free)
        except ValueError as e:
            last = e
            continue
        if got:
            note = (f"side tunnels cut to {arm} tiles (the template's {top} meet the core's rooms, water or a mark; "
                    "BUG-528)")
            return [{**s, "arm": arm, "why": s["why"] + "; " + note} for s in got]
    if last is not None:
        raise ValueError(f"{last} (arm {top}, " + ", ".join(str(a) for a in EXPLORE_ARMS if a < top) + " tried)") from None
    return []


EXPLORE_DEPTHS = (9, 6, 4, 2)         # BUG-553: depths tried (deepest that fits first) when the template's own depth has no site
EXPLORE_NO_SITE = ("avoided level", "no safe explore site", "explore: no site at depth")


def _rank_depths(snap, tpl, params, manifest, n, water, near, within, at, free) -> list[dict]:
    """BUG-553 (Run 16d i4 Trumpetrealms y399-y405: `bp sites explore` without p.depth said 'depth 12 reaches avoided level' and ranked
    nothing for years while `depth=6` had 3 sites, and plan propose / bp.place explore S1 never found them): when the template's own
    depth (no p.depth = 12) has no site because every shaft of that depth reaches an avoided level, meets a dig that stopped or the
    core's rooms, the deepest smaller depth of EXPLORE_DEPTHS that has a site is ranked; every site then carries it (`depth`, applied to
    the document by cmd.site_params) and says so. p.depth given is never changed. A site at the template's depth stays as it was
    (no `depth` key). All depths empty: the error of the template's own depth, with the depths tried."""
    base = dict(params or {})
    top = mine.PARAMS[tpl]["depth"][0]

    def at_depth(d):                               # p.arm given is the player's: no arm search then
        q = {**base, "depth": d}
        return rank(snap, tpl, q, manifest, n, water, near, within, at, free) if "arm" in q             else _rank_arms(snap, tpl, q, manifest, n, water, near, within, at, free)
    try:
        return at_depth(top)
    except ValueError as e:
        first = e
    if not any(w in str(first) for w in EXPLORE_NO_SITE):
        raise first
    for d in EXPLORE_DEPTHS:
        if d >= top:
            continue
        try:
            got = at_depth(d)
        except ValueError:
            continue
        if got:
            note = f"shaft cut to depth {d} (the template's {top} reaches an avoided level or meets something; BUG-553)"
            return [{**s, "depth": d, "why": s["why"] + "; " + note} for s in got]
    raise ValueError(f"{first} (depth {top}, " + ", ".join(str(d) for d in EXPLORE_DEPTHS if d < top) + " tried)") from None


EXPLORE_LEVEL = 10                    # explore: score per level below the top of Z4 (a deeper start searches deeper)
AVOID_MARKS = ("cavern", "damp", "warm")


EXPLORE_FAR = 8                       # BUG-584: score per tile (x/y) a new probe lies from the nearest earlier one, up to EXPLORE_FAR_MAX tiles
EXPLORE_FAR_MAX = 30


EXPLORE_RING = 3                      # BUG-453: tiles a side tunnel keeps from any revealed opening, water or mark


def explore_rects(p: dict) -> dict[int, list[tuple[int, int, int, int]]]:
    """Local check rects of an explore shaft: per level the dug tiles' bbox grown by the wall ring (the shaft top level
    not toward the anchor row, as rooms; below it all round: a tunnel must not break into an open space there)."""
    rects: dict[int, list] = {}
    for w, tiles in mine.explore(p).dug().items():
        us, vs = [t[0] for t in tiles], [t[1] for t in tiles]
        rects[w] = [(min(us) - 1, max(1, min(vs) - 1) if w == 0 else min(vs) - 1, max(us) + 1, max(vs) + 1)]
    return rects


def explore_wide_rects(p: dict) -> dict[int, list[tuple[int, int, int, int]]]:
    """BUG-453 (Run 16a i1 Syrupobeyed y384: our own explore shaft made an R0 bypass, the route came up its stair 40,86,138 and no seal piece
    closes a stair): the levels with side tunnels, grown by EXPLORE_RING tiles all round, so an arm never ends within three tiles of a
    revealed floor, ramp, water or mark. Only checked (the project's footprint box stays the one-tile ring of explore_rects)."""
    tun = set(mine.tunnel_levels(p)) if p.get("arm") else set()
    out: dict[int, list] = {}
    for w, tiles in mine.explore(p).dug().items():
        if w in tun:
            us, vs = [t[0] for t in tiles], [t[1] for t in tiles]
            out[w] = [(min(us) - EXPLORE_RING, min(vs) - EXPLORE_RING, max(us) + EXPLORE_RING, max(vs) + EXPLORE_RING)]
    return out


def heavy_breach_levels(manifest: dict | None) -> set[int]:
    """BUG-468 (Run 16c i3 Castletongs: an explore to z110 every year through the heavy z113, the shaft stopped at z112/z110 as breach:
    heavy_aquifer three times; Run 16a i1 Basementflew: explore depth 24 from z129 through heavy z123 and z120 with `p.avoid` empty): the
    levels where a dig of ours met a heavy aquifer (manifest `breaches` why heavy_aquifer, any template). An aquifer spans a whole level,
    so the whole level counts, not the tiles around the stop."""
    out = set()
    for b in (manifest or {}).get("breaches") or []:
        pos = b.get("pos") if isinstance(b, dict) else None
        if isinstance(b, dict) and b.get("why") == "heavy_aquifer" and isinstance(pos, (list, tuple)) and len(pos) == 3                 and isinstance(pos[2], int) and not isinstance(pos[2], bool):
            out.add(pos[2])
    return out


def avoid_levels(snap: dict, p: dict, manifest: dict | None = None) -> set[int]:
    """Levels an explore shaft must not reach: params.avoid plus every level with a revealed cavern, damp or warm mark
    (a cavern layer or a wet/hot stone layer: the vanilla UI shows those tiles too), plus (Run 11: explores kept
    breaking into the cavern lakes on z127, below the sites snapshot) the level of every cavern breach the kernel
    recorded (manifest `caverns`), plus (BUG-468) every level a dig of ours met a heavy aquifer on (heavy_breach_levels): an explore
    stops above it (an aqshaft passes it with its ring, an explore never)."""
    out = mine.parse_avoid(p.get("avoid", ""))
    for k in AVOID_MARKS:
        out |= {int(q[2]) for q in snap.get("marks", {}).get(k, []) if isinstance(q, (list, tuple)) and len(q) == 3}
    out |= {int(q[2]) for q in (manifest or {}).get("caverns", []) if isinstance(q, (list, tuple)) and len(q) == 3}
    out |= heavy_breach_levels(manifest)
    return out


EXPLORE_REDO_R = 6          # BUG-392: tiles (x/y) around a failed explore's anchor / a recorded breach the new shaft keeps off


def failed_explores(manifest: dict | None) -> list[tuple[tuple[int, int, int], str]]:
    """BUG-392 (Run 16b i2 Ostgate: the draft proposed explore at 54,100,129 again after it stopped there as breach:cavern_lake,
    and 3 tiles away from the y374 one that stopped as breach:water): the anchors of explore projects that stopped at a
    breach (manifest `failed_explore`, cmd.fort_manifest: the anchor of the bp file of each breach whose tpl is explore),
    each with a label for the reason line."""
    out = []
    for f in (manifest or {}).get("failed_explore") or []:
        a = f.get("anchor") if isinstance(f, dict) else None
        if isinstance(a, (list, tuple)) and len(a) == 3:
            out.append((tuple(int(v) for v in a), f"{f.get('why', 'breach')} {_pos(a)}" + (f" {f['proj']}" if f.get("proj") else "")))
    return out


def _explore_redo(ax: int, ay: int, az: int, depth: int, pts: list, failed: list) -> str | None:
    """BUG-392: why an explore anchor repeats a failure: its shaft (az-depth-1 .. az+1, arms EXPLORE_REDO_R wide) holds a
    recorded breach, or it lies within EXPLORE_REDO_R tiles of a failed explore's anchor on the same level +-1."""
    R = EXPLORE_REDO_R
    for (x, y, z), lbl in pts:
        if az - depth - 1 <= z <= az + 1 and abs(x - ax) <= R and abs(y - ay) <= R:
            return lbl
    for (x, y, z), lbl in failed:
        if abs(z - az) <= 1 and abs(x - ax) <= R and abs(y - ay) <= R:
            return "failed explore " + lbl
    return None


def _fail_why(rects, ax, ay, az, rot, bad, mk, wet) -> tuple[str, int] | None:
    """BUG-625: what `_check` refuses first for these rects: ('open', w) a revealed open / non-rock tile on level az+w, ('mark', w) a
    cavern / damp / warm mark there, ('wet', w) liquid right above, ('map', w) the map's edge; None when nothing is refused."""
    for w, lst in rects.items():
        for r in lst:
            x0, y0, x1, y1 = _rot_rect(r, ax, ay, rot)
            if az + w < 0:
                return ("map", w)
            b = bad.count(x0, y0, x1, y1, az + w)
            if b is None:
                if bad.inside(x0, y0, x1, y1) and az + w < min(bad.p):
                    continue
                return ("map", w)
            if b:
                return ("open", w)
            if mk.count(x0, y0, x1, y1, az + w):
                return ("mark", w)
            if wet is not None and (wet.count(x0, y0, x1, y1, az + w + 1) or 0):
                return ("wet", w)
    return None


_WHY_KIND = {"open": "an open or built tile", "mark": "a cavern/damp/warm mark", "wet": "liquid right above", "map": "the map's edge"}


def _geo_text(geo: dict, p: dict) -> str:
    """BUG-625: the anchors the geometry took out, by what met the shaft and on which level of the shaft (w = 0 the anchor's own level,
    w = -d the d-th level down): 'z136: 400 meet an open or built tile on the anchor level; 120 two levels down'."""
    parts = []
    for (az, kind, w), n in sorted(geo.items(), key=lambda kv: (-kv[1], kv[0])):
        where = "on the anchor level" if w == 0 else f"{-w} level(s) below it (z{az + w})"
        parts.append(f"{n} anchor(s) of z{az}: {_WHY_KIND.get(kind, kind)} {where}")
    return "; ".join(parts[:4]) + (" +more" if len(parts) > 4 else "")


def _explore(snap, p, rects, bad, hid, mk, manifest, wet=None):
    """explore (Run 10): public Z4 anchors like a room whose shaft (depth levels) reaches no avoided level; footprint and
    ring rock or unknown (levels below the snapshot count as unknown); never from the refuge level or below it (the
    refuge stays a sealed dead end: a cavern breach must not open into it); the deeper the anchor, the better. Raises
    ValueError naming the levels when only the avoided levels kept every anchor out."""
    g = Graph(snap)
    steps_of = _stair_steps(g)
    keep_out = _keep_out(manifest)
    top = max(b[5] for b in manifest["zones"]["Z4"])
    ref = manifest.get("refuge")
    zr = ref["anchor"][2] if ref else None
    avoid = avoid_levels(snap, p, manifest)
    wide = explore_wide_rects(p)
    out, hit, redo = [], set(), []
    pts, failed = breach_points(manifest), failed_explores(manifest)
    # BUG-584 (Run 16d i4 Trumpetrealms y412-y415: probes of depth 2-6 round the core of a mudstone fort found no ore, no hard stone, and the
    # ranking kept offering that neighbourhood): the earlier probes of the fort (manifest `explored`, cmd._with_explored) are rock the
    # fort knows; a new probe scores higher the farther it lies from the nearest of them
    done_at = [(int(a[0]), int(a[1])) for a in (manifest.get("explored") or []) if isinstance(a, (list, tuple)) and len(a) == 3]
    n_all = n_ref = n_hit = n_redo = n_geom = 0                # BUG-528: how many anchors each test took out (the message says so)
    geo: dict = {}                                             # BUG-625: (anchor z, what met the shaft, shaft level w) -> anchors
    for i in _anchor_tiles(g, "explore", p, manifest):
        ax, ay, az = g.pos(i)
        n_all += 1
        if zr is not None and az <= zr:
            n_ref += 1
            continue
        lv = {z for z in avoid if az - p["depth"] <= z <= az}
        if lv:
            hit |= lv
            n_hit += 1
            continue
        why = _explore_redo(ax, ay, az, p["depth"], pts, failed) if (pts or failed) else None
        if why:                                              # BUG-392: not again where a dig already stopped
            n_redo += 1
            if why not in redo:
                redo.append(why)
            continue
        n_out, n_door, fail = len(out), 0, None
        for rot in range(4):
            du, dv = rot_uv(0, 1, rot)
            door = g.idx((ax + du, ay + dv, az))
            if door is None or g.t[door] not in GOOD:
                continue
            n_door += 1
            res = _check(rects, ax, ay, az, rot, bad, hid, mk, True, wet)
            if res is None or (wide and _check(wide, ax, ay, az, rot, bad, hid, mk, True, wet) is None):
                if fail is None:                             # BUG-625: the first rotation's refusal names the anchor's reason
                    fail = _fail_why(rects, ax, ay, az, rot, bad, mk, wet) or (wide and _fail_why(wide, ax, ay, az, rot, bad, mk, wet))
                continue                                     # BUG-453: the tunnels also keep EXPLORE_RING tiles from any opening
            unknown, missing, box = res
            if any(_overlap(r, b) for r in _rect_boxes(rects, ax, ay, az, rot) for b in keep_out):
                continue
            steps = min(steps_of.get(i, 99), 99)
            far, far_why = 0, ""
            if done_at:
                dist = int(min(((ax - px) ** 2 + (ay - py) ** 2) ** 0.5 for px, py in done_at))
                far = EXPLORE_FAR * min(dist, EXPLORE_FAR_MAX)
                far_why = f", {dist} tiles from the nearest of {len(done_at)} earlier probe(s)"
            out.append({"anchor": [ax, ay, az], "rot": rot, "box": box,
                        "score": max(0, 1000 - 5 * steps + EXPLORE_LEVEL * (top - az) + far),
                        "why": f"rot{rot}, {top - az} levels below the top of the core, shaft to z{az - p['depth']}, "
                               f"{steps} steps to a stair, {unknown} unknown tiles, {missing} levels below the snapshot{far_why}"})
        if len(out) == n_out and n_door:
            n_geom += 1                                      # a floor to dig from, but the shaft or its tunnels meet something
            if fail:
                key = (az, fail[0], fail[1])
                geo[key] = geo.get(key, 0) + 1
    if not out:
        raise ValueError(_explore_none(p, hit, redo, (n_all, n_ref, n_hit, n_redo, n_geom), geo))
    return out


def _explore_none(p: dict, hit: set, redo: list, n: tuple, geo: dict | None = None) -> str:
    """BUG-528 (Run 16d i4 Trumpetrealms y399: a cavern breach 78,127,127 'locked' the soil fort out of explore for years; the message said
    'every anchor lies within 6 tiles of a dig that already stopped' while 12 anchors were free of it and the side tunnels (arm 6) met
    the core's own rooms): why no anchor took the shaft of this depth and arm, with the number of anchors each test removed. The
    wording a caller matches stays ('avoided level (z..', 'no safe explore site')."""
    n_all, n_ref, n_hit, n_redo, n_geom = n
    parts = []
    if n_ref:
        parts.append(f"{n_ref} lie on or under the refuge level (the refuge stays a sealed dead end)")
    if n_hit:
        parts.append(f"{n_hit} have a shaft that reaches an avoided level")
    if n_redo:
        parts.append(f"{n_redo} lie within {EXPLORE_REDO_R} tiles of a dig that already stopped")
    if n_geom:
        parts.append(f"{n_geom} have a shaft or side tunnels (arm {p.get('arm')}) that meet the core's own open rooms, water or a "
                     "mark (a smaller arm= or depth= can fit between them)")
    tally = f" [{n_all} anchor tile(s): {'; '.join(parts)}]" if parts else f" [{n_all} anchor tile(s)]"
    if geo:                                                  # BUG-625: exactly what met the shaft, on which level
        lv = sorted({k[0] for k in geo})
        tally += (f" [BUG-625: explore starts only from the public floor of the core, level(s) {', '.join('z' + str(z) for z in lv)}; "
                  f"the shaft was refused by: {_geo_text(geo, p)}]")
    if hit and not n_redo and not n_geom:
        return (f"explore: every anchor's shaft of depth {p['depth']} reaches an avoided level "
                f"(z{','.join(str(z) for z in sorted(hit)[:6])}: avoid, a cavern/damp/warm mark, a cavern "
                "breach or a heavy aquifer breach); give a smaller depth (p.depth)" + (tally if n_ref else ""))
    head = f"explore: no site at depth {p['depth']} arm {p.get('arm')}"
    if hit:
        head += (f"; avoided level (z{','.join(str(z) for z in sorted(hit)[:6])}: avoid, a cavern/damp/warm mark, a cavern breach or a "
                 "heavy aquifer breach)")
    if redo:
        head += (f"; {'every anchor lies' if n_redo and n_redo == n_all - n_ref else 'some anchors lie'} within {EXPLORE_REDO_R} tiles "
                 f"of a dig that already stopped ({'; '.join(redo[:3])}{' +more' if len(redo) > 3 else ''}); no safe explore site "
                 "there")
    if n_geom or not (hit or redo):
        head += ("; no free rock for it beside the core: p.arm=0..3 (shorter side tunnels) or a smaller p.depth may fit, else open a "
                 "new core level first and trade for ore, bars and stone")
    else:
        head += ": trade for ore and bars, or open a new core level first"
    return head + tally


AQ_ORTH = ((1, 0), (-1, 0), (0, 1), (0, -1))
AQ_SPAN = 40                          # aqshaft: score for a column that passes a known aquifer level
AQ_REACH = 2                          # BUG-432: levels below the shallowest aquifer level the shaft reaches: the core's top level (the aquifer
                                      # level and the one right under it are forbidden for a core, aquifer_ok), not the refuge room 3 deeper
WATER_KEEP = 3                        # BUG-412: no open water within this many tiles of the shaft (any level it passes)
AQ_LAKE_R = 8                         # BUG-633: a cavern breach on a known aquifer level, with no cavern mark there, is a LOCAL flood of our own
                                      # dug rooms: a shaft column keeps this many tiles (x/y, both ways) from it; farther columns pass
MARKS_CAP = 500                       # snapshot.lua CFG.marks_max: a mark list this long was cut off (scan order: low z first)
AQ_BREACH = ("heavy_aquifer", "damp", "water")      # breach stops that are the aquifer itself (manifest `breaches` why)


class CavernLevels:
    """BUG-432: the levels a shaft must not pass or open into: {z: evidence} of revealed cavern/warm marks and recorded cavern
    breaches. A cavern is a whole level (marks are sparse, a breach is one point of a large volume): a level with any evidence
    is refused level-wide. `zcap`: the cavern mark list hit MARKS_CAP, so the levels from the last mark up were not fully
    scanned; a shaft touching one of them is refused as well (coverage incomplete)."""

    def __init__(self, levels: dict[int, str], zcap: int | None = None, local: dict | None = None):
        self.levels, self.zcap = levels, zcap
        # BUG-633 (Run 16c i3 Wallfree y376-y383: manifest.caverns cavern_lake 97,59,143 -- a breach into a flooded room we dug on the
        # aquifer level z143 -- refused all 297 / 478 columns of the fort for the level z143, 'avoided cavern level'): a breach on a
        # known aquifer level that no revealed cavern mark confirms is water in OUR rooms, not a cavern volume. {z: [(x, y, label)]}:
        # it only refuses the columns within AQ_LAKE_R tiles of the point (hits() with x/y); without x/y it stays level-wide
        self.local = local or {}

    def __bool__(self) -> bool:
        return bool(self.levels) or self.zcap is not None or bool(self.local)

    def hits(self, lo: int, hi: int, x: int | None = None, y: int | None = None) -> list[tuple[int, str]]:
        out = [(z, self.levels[z]) for z in sorted(self.levels) if lo <= z <= hi]
        for z in sorted(self.local):
            if z in self.levels or not lo <= z <= hi:
                continue
            for bx, by, label in self.local[z]:
                if x is None or y is None or (abs(x - bx) <= AQ_LAKE_R + 1 and abs(y - by) <= AQ_LAKE_R + 1):
                    out.append((z, label if x is None else f"{label}, {max(abs(x - bx), abs(y - by))} tiles from the column; "
                                f"a column more than {AQ_LAKE_R + 1} tiles away passes"))
                    break
        if self.zcap is not None:
            out += [(z, f"cavern marks capped at {MARKS_CAP}, z{z} not fully scanned") for z in range(max(lo, self.zcap + 1), hi + 1)
                    if z not in self.levels]
        return sorted(out)


def shaft_avoid(snap: dict, manifest: dict | None) -> CavernLevels:
    """Revealed cavern or warm marks and recorded cavern breaches (manifest `caverns`: only cavern / cavern_lake stops; one whose
    position is also an aquifer breach in `breaches` inside the known aquifer span is the aquifer, not a cavern, and is skipped): a shaft never passes or opens
    into such a level."""
    lv: dict[int, str] = {}
    zcap = None
    marks = snap.get("marks", {})
    for k in ("cavern", "warm"):
        lst = [q for q in marks.get(k, []) if isinstance(q, (list, tuple)) and len(q) == 3]
        for x, y, z in lst:
            lv.setdefault(int(z), f"{k} mark at {int(x)},{int(y)},{int(z)}")
        if k == "cavern" and len(lst) >= MARKS_CAP:
            zcap = max(int(q[2]) for q in lst)
    wet = {tuple(int(v) for v in b["pos"]) for b in (manifest or {}).get("breaches") or []
           if isinstance(b, dict) and b.get("why") in AQ_BREACH and isinstance(b.get("pos"), (list, tuple)) and len(b["pos"]) == 3}
    span = known_aquifer(snap, manifest)
    local: dict[int, list] = {}
    for q in (manifest or {}).get("caverns", []):
        if isinstance(q, (list, tuple)) and len(q) == 3 and not (tuple(int(v) for v in q) in wet and int(q[2]) in span):
            x, y, z = (int(v) for v in q)
            label = f"cavern breach at {x},{y},{z}"
            if z in span:                    # BUG-633: an aquifer level: flooded rooms of ours, local (a revealed mark still makes the level whole)
                local.setdefault(z, []).append((x, y, label + " on the aquifer level z%d" % z))
            else:
                lv.setdefault(z, label)
    return CavernLevels(lv, zcap, {z: v for z, v in local.items() if z not in lv})


def shaft_depth_auto(snap: dict, manifest: dict | None, top: int) -> int | None:
    """BUG-432 (Run 16c i3 Yawninggilt: `bp sites aqshaft` refused all 1271 columns for a cavern/warm level, every column ran the
    default 20 levels down from z127, far below the core): the depth that takes a shaft from `top` to the core's top level,
    AQ_REACH levels under the shallowest known aquifer level (no deeper: every level more is one more to keep cavern-free); None when no aquifer level is known (the default stays)."""
    aq = known_aquifer(snap, manifest)
    if not aq:
        return None
    return max(2, min(60, top - (min(aq) - AQ_REACH) + 1))


def shaft_why(at, x: int, y: int, top: int, z_lo: int, avoid, keep_out, wet: bool = True) -> tuple[str, str] | None:
    """BUG-432/433: the one safety check of a shaft column (the ranking and `bp.place aqshaft` with p.x/p.y/p.top): (kind, reason
    naming the level / coordinate) for the first rule it breaks, None when it is safe. The shaft's own levels z_lo..top and the one
    level right below its bottom hold no cavern/warm level (never open into one); deeper ones do not matter. The column and its 4
    side tiles on every level below the top are rock or unknown; no keep-out box; no open water within WATER_KEEP tiles on any
    level it passes (`wet` False skips this slow scan)."""
    hit = avoid.hits(z_lo - 1, top, x, y) if avoid else []       # BUG-633: x/y, so a local flood only refuses the columns beside it
    if hit:
        return "avoid", (f"{x},{y}: cavern/warm level z{hit[-1][0]} ({hit[-1][1]}) lies within the shaft's z{top}-z{z_lo} "
                         "or the level below it")
    for z in range(top - 1, z_lo - 1, -1):
        for dx, dy in ((0, 0),) + AQ_ORTH:
            c = at(x + dx, y + dy, z)
            if c is not None and c not in GOOD:
                return "rock", f"{x + dx},{y + dy} z{z} is '{c}', not rock"
    col = (x, y, z_lo, x, y, top)
    for b in keep_out:
        if _overlap(col, b):
            return "keep", f"{x},{y} z{z_lo}-z{top} overlaps an attack zone or the military stair {tuple(b)}"
    if wet:
        w = next(((x + dx, y + dy, z) for z in range(z_lo, top + 1)
                  for dx in range(-WATER_KEEP, WATER_KEEP + 1) for dy in range(-WATER_KEEP, WATER_KEEP + 1)
                  if at(x + dx, y + dy, z) in WET), None)
        if w:
            return "water", f"{x},{y}: open water at {w[0]},{w[1]} z{w[2]} (within {WATER_KEEP} tiles)"
    return None


def check_column(snap: dict, manifest: dict | None, x: int, y: int, top: int, depth: int) -> None:
    """BUG-433: `bp.place aqshaft` with an explicit column p.x/p.y/p.top: the ranking's safety rules (shaft_why); ValueError with the
    level / coordinate of the reason."""
    at = _At(snap)
    if at(x, y, top) in WET:
        raise ValueError(f"aqshaft {x},{y} z{top}: the top tile is open water")
    z_lo = top - depth + 1
    got = shaft_why(at, x, y, top, z_lo, shaft_avoid(snap, manifest), _keep_out(manifest or {}))
    if got:
        raise ValueError(f"aqshaft {x},{y} z{top} depth {depth} (z{top}-z{z_lo}): {got[1]}")


def _aqshaft(snap: dict, p: dict, manifest: dict) -> list[dict]:
    """BUG-292 (Run 15 Inkintense: `bp sites aqshaft` proposed nothing, every column tried by hand was refused): the shaft
    columns, ranked. The top is a public Z4 floor tile (`.`, not a stair: the miners reach it, it opens no private room),
    never on or below the refuge level; on each level below (p.depth levels in all) the column and its 4 orthogonal tiles
    (the seal: lua/dfllm/aqshaft.lua smooths or walls them) are rock or unknown, levels below the snapshot count as unknown;
    the column keeps off the attack zones, killboxes, bridges and the military stair (keep-out boxes), off a revealed cavern or
    warm level or a recorded cavern breach on its own levels and the one below its bottom (BUG-432: level-wide, a cavern is a
    volume; deeper levels do not matter) and off open water (BUG-433). Without p.depth the shaft goes down to the core level under the known aquifer
    (shaft_depth_auto), else 20. Score: 1000 - 5 per step to a stair - 2 per unknown column tile + AQ_SPAN when it passes a
    known aquifer level (manifest aquifer_levels). ValueError with the reason (first 3 examples per rule: level / coordinate)
    when no column is left."""
    rw = ring_wall_stops(manifest)
    if len(rw) >= RING_STOP_MAX:
        zs = ", ".join(f"z{b['pos'][2]} ({b.get('proj', '?')})" for b in rw[:4] if isinstance(b.get("pos"), (list, tuple)) and len(b["pos"]) == 3)
        raise ValueError(f"aqshaft: {len(rw)} shafts stopped at a ring wall nobody built ({zs}); that is a missing-material stop, not water "
                         "(AQ_RING_STOP, flow 0/7), and the next shaft would stop the same way. No column is offered until a ring wall stands: "
                         "get wall material the builders accept (hard stone boulders or blocks: a stone dig, trade.want stone/block) and a "
                         "mason, check `dfllm cmd inspect what=workload`, or place a shaft with `p.heavy=off` where no ring is needed")
    g = Graph(snap)
    steps_of = _stair_steps(g)
    keep_out = _keep_out(manifest)
    at = _At(snap)
    ref = manifest.get("refuge")
    zr = ref["anchor"][2] if ref else None
    avoid = shaft_avoid(snap, manifest)
    aq = aquifer_levels(manifest)
    auto = bool(p.get("depth_auto"))
    out = []
    why: dict[str, list] = {"rock": [0], "avoid": [0], "keep": [0], "water": [0]}
    for i in _anchor_tiles(g, "aqshaft", p, manifest):
        ax, ay, az = g.pos(i)
        if g.t[i] != "." or (zr is not None and az <= zr):
            continue
        reach = shaft_depth_auto(snap, manifest, az) if auto else None
        depth = reach or p["depth"]
        z_lo = az - depth + 1
        got = shaft_why(at, ax, ay, az, z_lo, avoid, keep_out, wet=False)
        if got is None:
            got = shaft_why(at, ax, ay, az, z_lo, (), (), wet=True)          # the slow water scan, only for the survivors
        if got:
            why[got[0]][0] += 1
            if len(why[got[0]]) < 4:
                why[got[0]].append(got[1])
            continue
        unknown = sum(1 for z in range(az - 1, z_lo - 1, -1) if at(ax, ay, z) in (None, "?"))
        steps = min(steps_of.get(i, 99), 99)
        span = sorted(z for z in aq if z_lo <= z < az)
        score = 1000 - 5 * steps - 2 * unknown + (AQ_SPAN if span else 0)
        out.append({"anchor": [ax, ay, az], "rot": 0, "score": max(0, score), "depth": depth,
                    "box": (ax - 1, ay - 1, z_lo, ax + 1, ay + 1, az),
                    "why": f"column {ax},{ay} z{az}-z{z_lo}, {steps} steps to a stair, {unknown} unknown column tiles"
                           + (f", passes aquifer level z{span[-1]}" if span else "")
                           + (f", p.depth {depth} (down to the core level)" if reach else "")})
    if not out:
        def ex(k):
            return f" [{'; '.join(why[k][1:])}]" if len(why[k]) > 1 else ""
        raise ValueError(f"aqshaft: no column of depth {'auto' if auto else p['depth']} from public Z4 floor (rock or unknown below "
                         f"with rock on its 4 sides: {why['rock'][0]} refused{ex('rock')}; an avoided cavern/warm level: "
                         f"{why['avoid'][0]}{ex('avoid')}; attack zone or military stair: {why['keep'][0]}{ex('keep')}; open "
                         f"water within {WATER_KEEP} tiles: {why['water'][0]}{ex('water')}): give a smaller p.depth or name the "
                         "column (p.x, p.y, p.top, p.depth: checked by the same rules)")
    return out


CORE_BOX_R = 6                    # BUG-602: tiles round a waiting fortcore's anchor that an open-ground column keeps off (its stage 1 box)
OPEN_COLS = 24                    # BUG-602: open-ground aqshaft columns offered at most (the caller drops the ones a placed project holds)


def open_columns(snap: dict, params: dict | None, manifest: dict | None, near=None, want: int = OPEN_COLS) -> list[dict]:
    """BUG-602 (Run 16c i3 Wallfree y372: the fortcore with p.aquifer=pass waited for an aqshaft and `bp sites aqshaft` refused all 40-143
    columns 'start on the floor of a placed room'; Run 16a i1 Basementflew 917 columns the same: the public Z4 floor of a fort that
    has no corridor yet is the floor of its first placed rooms): the shaft columns on OPEN GROUND, the ranking `_aqshaft` falls back to
    when every public-floor column is held. The top is an open surface floor tile (`.` with open sky `_` above) in the citizens' walk
    group, nearest to `near` (x, y: the waiting fortcore; default the depot / the middle of the snapshot); the column's rock rules
    are `_aqshaft`'s (shaft_why), the depth is its own (p.depth, else down to the core under the known aquifer). Same dicts as
    `_aqshaft` (anchor, rot, score, depth, box, why); [] when nothing fits. The caller tests the placed projects."""
    if len(ring_wall_stops(manifest)) >= RING_STOP_MAX:             # BUG-662: the same refusal as `_aqshaft`
        return []
    p = check_params("aqshaft", params)
    p["depth_auto"] = "depth" not in (params or {})
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    at = _At(snap)
    cx, cy = (int(near[0]), int(near[1])) if near else ((x0 + x1) // 2, (y0 + y1) // 2)
    dep = (manifest or {}).get("depot")
    if not near and isinstance(dep, (list, tuple)) and len(dep) == 3 and all(isinstance(v, int) for v in dep):
        cx, cy = dep[0], dep[1]
    avoid = shaft_avoid(snap, manifest)
    keep_out = _keep_out(manifest or {})
    aq = aquifer_levels(manifest)
    ref = (manifest or {}).get("refuge")
    zr = ref["anchor"][2] if ref else None
    tops = []
    step = 2 if (x1 - x0 + 1) * (y1 - y0 + 1) > 2500 else 1
    for z in range(z0, z1):
        if zr is not None and z <= zr:
            continue
        cur, up = snap["rows"][f"z{z}"], snap["rows"][f"z{z + 1}"]
        for yy in range(0, len(cur), step):
            for xx in range(0, len(cur[yy]), step):
                if cur[yy][xx] == "." and up[yy][xx] == "_":
                    tops.append((max(abs(x0 + xx - cx), abs(y0 + yy - cy)), -z, x0 + xx, y0 + yy, z))
    tops.sort()
    out = []
    for d, _, ax, ay, az in tops[:PROBE_TRIES]:
        if near and len(near) > 2 and az == int(near[2]) and max(abs(ax - int(near[0])), abs(ay - int(near[1]))) <= CORE_BOX_R:
            continue                                  # the waiting fortcore's own box: its entrance, tunnel and shops
        if walk_at(snap, (ax, ay, az)) == "0":
            continue
        reach = shaft_depth_auto(snap, manifest, az) if p["depth_auto"] else None
        depth = reach or p["depth"]
        z_lo = az - depth + 1
        got = shaft_why(at, ax, ay, az, z_lo, avoid, keep_out, wet=False)
        if got is None:
            got = shaft_why(at, ax, ay, az, z_lo, (), (), wet=True)
        if got:
            continue
        unknown = sum(1 for z in range(az - 1, z_lo - 1, -1) if at(ax, ay, z) in (None, "?"))
        span = sorted(z for z in aq if z_lo <= z < az)
        out.append({"anchor": [ax, ay, az], "rot": 0, "score": max(0, 1000 - d - 2 * unknown + (AQ_SPAN if span else 0)),
                    "depth": depth, "box": (ax - 1, ay - 1, z_lo, ax + 1, ay + 1, az),
                    "why": f"BUG-602: open-ground column {ax},{ay} z{az}-z{z_lo}, {d} tiles from {'the waiting fortcore' if near else 'the entrance'}, "
                           f"{unknown} unknown column tiles"
                           + (f", passes aquifer level z{span[-1]}" if span else "")
                           + (f", p.depth {depth} (down to the core level)" if reach else "")})
        if len(out) >= want:
            break
    return out


PROBE_WATER_KEEP = 4                  # BUG-441: the probe shaft keeps one tile more from open water than any aqshaft (WATER_KEEP)
PROBE_TRIES = 600                     # BUG-441: surface tiles probe_column checks, nearest to the embark centre first


def probe_column(snap: dict, manifest: dict | None, depth: int, near=None) -> dict:
    """BUG-441 (review of round 28: a fresh embark has no fort manifest with zones.Z4, so `bp sites aqshaft` ranked nothing and the
    probe could never be placed): the aquifer probe's column from the open surface, needing no core and no Z4. The top is an open
    surface floor tile (`.` with open sky `_` above) in the citizens' walk group, nearest to `near` (x, y: the wagon / the depot;
    default the middle of the snapshot = the embark); on each level below (`depth` in all) the column and its 4 orthogonal tiles are
    rock or unknown, off every cavern/warm level, no keep-out box, and no open water within PROBE_WATER_KEEP tiles on any of them
    (the top level included). {x, y, top, depth, why}; ValueError with the first reasons when no tile fits."""
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    at = _At(snap)
    cx, cy = (int(near[0]), int(near[1])) if near else ((x0 + x1) // 2, (y0 + y1) // 2)
    dep = (manifest or {}).get("depot")
    if not near and isinstance(dep, (list, tuple)) and len(dep) == 3 and all(isinstance(v, int) for v in dep):
        cx, cy = dep[0], dep[1]
    avoid = shaft_avoid(snap, manifest)
    keep_out = _keep_out(manifest or {})
    cands = []
    step = 2 if (x1 - x0 + 1) * (y1 - y0 + 1) > 2500 else 1
    for z in range(z0, z1):
        cur, up = snap["rows"][f"z{z}"], snap["rows"][f"z{z + 1}"]
        for yy in range(0, len(cur), step):
            for xx in range(0, len(cur[yy]), step):
                if cur[yy][xx] == "." and up[yy][xx] == "_":
                    cands.append((max(abs(x0 + xx - cx), abs(y0 + yy - cy)), -z, x0 + xx, y0 + yy, z))
    cands.sort()
    why: list[str] = []
    for _, _, x, y, z in cands[:PROBE_TRIES]:
        if walk_at(snap, (x, y, z)) == "0":
            continue
        z_lo = z - depth + 1
        got = shaft_why(at, x, y, z, z_lo, avoid, keep_out, wet=False)
        if got is None:
            w = next(((x + dx, y + dy, zz) for zz in range(z_lo, z + 1)
                      for dx in range(-PROBE_WATER_KEEP, PROBE_WATER_KEEP + 1) for dy in range(-PROBE_WATER_KEEP, PROBE_WATER_KEEP + 1)
                      if at(x + dx, y + dy, zz) in WET), None)
            if w is None:
                return {"x": x, "y": y, "top": z, "depth": depth,
                        "why": f"probe column {x},{y} z{z}-z{z_lo} on open surface floor, {max(abs(x - cx), abs(y - cy))} tiles from the "
                               f"embark centre, no water within {PROBE_WATER_KEEP}"}
            got = ("water", f"{x},{y}: open water at {w[0]},{w[1]} z{w[2]} (within {PROBE_WATER_KEEP} tiles)")
        if len(why) < 3:
            why.append(got[1])
    raise ValueError(f"aqshaft probe: no open surface floor column of depth {depth} fits ({len(cands)} surface tile(s) read"
                     + (f"; first refusals: {'; '.join(why)}" if why else "") + ")")


# BUG-412 (Gordon 04.11.2026: "ich moechte generell dass durch aquifier gegraben wird, so sicher wie moeglich"): the fort belongs
# under the aquifer. The shaft that passes it stands at the chosen fortcore site: on open surface floor beside the entrance
# (local u -3 / +3, v 0..2: two tiles from the 3-wide entrance channel and tunnel, so the shaft's own seal walls (its 4 orthogonal
# tiles) never touch a fortcore tile), straight down through the aquifer levels
CORE_SHAFT_AT = ((-3, 1), (3, 1), (-3, 2), (3, 2), (-3, 0), (3, 0), (-4, 1), (4, 1), (-4, 2), (4, 2))


def core_shaft(snap: dict, manifest: dict, anchor, rot: int, depth: int, n_levels: int | None = None) -> dict:
    """BUG-412: the aqshaft column for a fortcore at `anchor`/`rot` with core depth `depth`: {x, y, top, depth, why}. The top is
    open surface floor (`.`) in the citizens' walk group; on every level down to the core's deepest one the column and its 4
    side tiles are rock or unknown; no open water (`~`, `w`, magma) within WATER_KEEP tiles on any of those levels; no revealed
    cavern/warm level and no keep-out box in its way. ValueError with the reason for every offset when none fits."""
    ax, ay, az = (int(c) for c in anchor)
    zc = fortcore.ZE - int(depth)
    zr = zc - fortcore.PARAMS["refuge"][0]
    z_lo = az + zr
    at = _At(snap)
    xf = Xform((ax, ay, az), rot)
    keep_out = _keep_out(manifest)
    avoid = shaft_avoid(snap, manifest)
    shaft_depth = n_levels or max(2, min(60, az - (az + zc) + 1))
    # the core levels (Kern+ at zc down to the refuge) keep off every known aquifer level and the level right below one (water
    # drips from an aquifer ceiling): the shaft is worth building only when the core ends up under all of them
    forbidden = {z for a in known_aquifer(snap, manifest) for z in (a, a - 1)}
    meet = sorted(z for z in range(z_lo, az + zc + 1) if z in forbidden)
    if meet:
        raise ValueError(f"the core levels z{z_lo}-z{az + zc} meet the aquifer (z{', z'.join(str(z) for z in meet[::-1])}): a "
                         "deeper core (p.depth) is needed")
    why: list[str] = []
    for u, v in CORE_SHAFT_AT:
        x, y, _ = xf.pos(u, v, 0)
        tag = f"{x},{y}"
        if at(x, y, az) != ".":
            why.append(f"{tag}: top tile is not open floor ({at(x, y, az) or 'outside the snapshot'})")
            continue
        if walk_at(snap, (x, y, az)) == "0":
            why.append(f"{tag}: not in the citizens' walk group")
            continue
        hit = avoid.hits(z_lo - 1, az, x, y) if avoid else []     # BUG-432: the shaft's levels and the one below its bottom, level-wide (BUG-633: a flood of ours: local)
        if hit:
            why.append(f"{tag}: cavern/warm level z{hit[-1][0]} ({hit[-1][1]}) within the shaft's z{az}-z{z_lo} or the level below it")
            continue
        bad = None
        for z in range(az - 1, z_lo - 1, -1):
            for dx, dy in ((0, 0),) + AQ_ORTH:
                c = at(x + dx, y + dy, z)
                if c is not None and c not in GOOD:
                    bad = f"{x + dx},{y + dy} z{z} is '{c}', not rock"
                    break
            if bad:
                break
        if bad:
            why.append(f"{tag}: {bad}")
            continue
        wet = next(((x + dx, y + dy, z) for z in range(z_lo, az + 1)
                    for dx in range(-WATER_KEEP, WATER_KEEP + 1) for dy in range(-WATER_KEEP, WATER_KEEP + 1)
                    if at(x + dx, y + dy, z) in WET), None)
        if wet:
            why.append(f"{tag}: open water at {wet[0]},{wet[1]} z{wet[2]} (within {WATER_KEEP} tiles)")
            continue
        col = (x, y, z_lo, x, y, az)
        if any(_overlap(col, b) for b in keep_out):
            why.append(f"{tag}: attack zone or military stair")
            continue
        return {"x": x, "y": y, "top": az, "depth": shaft_depth,
                "why": f"shaft column {x},{y} z{az}-z{z_lo} beside the entrance (local {u},{v}), no water within {WATER_KEEP}"}
    raise ValueError("aqshaft beside the fortcore: " + "; ".join(why[:4]) + (f" (+{len(why) - 4} more)" if len(why) > 4 else ""))


def _fortcore(snap, rects, bad, hid, mk, wet_above=None):
    rows = snap["rows"]
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    rough = _Pref(snap, lambda c: c != ".")
    wet = _Pref(snap, lambda c: c in WET)
    under = {w: lst for w, lst in rects.items() if w < 0}
    g = Graph(snap)
    bodies = _water_bodies(snap, 8, edge=True)             # a brook, river or lake, not a puddle
    ice = ice_tiles(snap)
    wsteps = water_steps(g, bodies, ice, other_group(snap, g))      # BUG-400: not over ice, on the citizens' walk group
    nwet = sum(row.count(c) for z in range(z0, z1 + 1) for row in rows[f"z{z}"] for c in "~w")
    none = _no_water(snap, bodies, nwet, ice)                   # BUG-360: why there is no water to walk to
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
                    res = _check(under, ax, ay, z, rot, bad, hid, mk, True, wet_above)
                    if res is None:
                        continue
                    _, missing, box = res
                    uneven = rough.count(box[0], box[1], box[3], box[4], z) or 0
                    water = wet.count(box[0], box[1], box[3], box[4], z) or 0
                    margin = min(ax - x0, x1 - ax, ay - y0, y1 - ay)
                    steps = wsteps.get(g.idx((ax, ay, z)))
                    score = 1000 - uneven // 4 - 40 * water - 30 * missing - (100 if margin < 5 else 0) \
                        + water_bonus(steps)
                    near = f"water {steps} steps" if steps is not None else none
                    out.append({"anchor": [ax, ay, z], "rot": rot, "score": max(score, 0),
                                "box": (ax - 6, ay - 6, z, ax + 6, ay + 6, z), "dig": box,
                                "why": f"rot{rot}, {near}, {uneven} uneven and {water} water surface tiles, "
                                       f"{missing} levels below the snapshot"})
    return out


BREACH_R = 10               # BUG-130: tiles (x/y) a fortcore's dig keeps from a recorded breach on its levels (+-1)
LAYER_MIN = 2               # BUG-130: damp/water breaches of this many projects on one level make it a wet layer (aquifer)
LAYER_R = 16                # BUG-388: tiles (x/y) around a stop on a wet layer that count as that layer's wet area (not the level)
SURFACE_AQ = 3              # BUG-387: an aquifer level this close (or closer) under a fortcore anchor: the core goes on the surface
SURFACE_DIG = 8             # BUG-387: a fortcore digs this deep under its anchor (depth 3 reaches az-8): a breach-recorded wet level inside


RING_WALL = "ring_wall"          # BUG-662: manifest breach why of an aqshaft stopped by a ring wall nobody built (AQ_RING_STOP; no water)
RING_STOP_MAX = 2               # ... this many such stops (and no ring wall standing since): `bp sites aqshaft` offers no column


def ring_wall_stops(manifest: dict | None) -> list[dict]:
    """BUG-662 (Run 16c i3 Wallfree y400-y402: five aqshafts in a row stopped at the ring wall of the next level, each reported as a heavy
    aquifer at flow 0/7; the cause was no wall material the builders accept): the manifest `breaches` rows of shafts that stopped at an
    unbuilt ring wall. The kernel drops them all once any ring wall stands (runner Q.ring_ok)."""
    return [b for b in (manifest or {}).get("breaches") or [] if isinstance(b, dict) and b.get("why") == RING_WALL]


def breach_points(manifest: dict | None) -> list[tuple[tuple[int, int, int], str]]:
    """BUG-130: the tiles where a dig was stopped by a breach (manifest `breaches`: damp, water, warm, cavern seepage) and
    the cavern breaches (manifest `caverns`), each with a short label for the reason line."""
    out = []
    for b in (manifest or {}).get("breaches") or []:
        pos = b.get("pos") if isinstance(b, dict) else None
        if isinstance(b, dict) and b.get("why") == RING_WALL:       # BUG-662: a shaft that stopped at an unbuilt ring wall met no water
            continue
        if isinstance(pos, (list, tuple)) and len(pos) == 3:
            out.append((tuple(int(v) for v in pos), f"{b.get('why', 'breach')} {_pos(pos)}"
                        + (f" {b['proj']}" if b.get("proj") else "")))
    for q in (manifest or {}).get("caverns") or []:
        if isinstance(q, (list, tuple)) and len(q) == 3:
            out.append((tuple(int(v) for v in q), f"cavern {_pos(q)}"))
    return out


def _breach_layers(manifest: dict | None) -> dict[int, str]:
    """BUG-130/359: {z: label} of the levels the recorded breaches show as a wet layer (an aquifer spans the whole
    level): damp or water stops of LAYER_MIN projects, or one heavy_aquifer stop (Run 16c: its label is `heavy_aquifer
    x,y,z`, which the old first-word test never took for a wet layer, so a new core a few tiles away dug into it again)."""
    stops: dict[int, int] = {}
    heavy: dict[int, str] = {}
    for (_, _, z), lbl in breach_points(manifest):
        why = lbl.split()[0]
        if why in ("damp", "water"):
            stops[z] = stops.get(z, 0) + 1
        elif why == "heavy_aquifer":
            heavy.setdefault(z, lbl)
    out = {z: f"wet level z{z} ({n} damp/water stops)" for z, n in stops.items() if n >= LAYER_MIN}
    for z, lbl in heavy.items():
        out[z] = f"wet level z{z} (heavy aquifer: breach {lbl})"
    return out


FLOOD_R = 4                 # BUG-359: tiles around a deep dug rect in which revealed water or a revealed cavern counts
FLOOD_W = -3                # BUG-359: dug levels this deep below the anchor or deeper (a brook bed lies at -1/-2)
AQ_PENALTY = 250            # BUG-359: score per known aquifer level the dig passes (light: it can still be dug damp)
CAV_PENALTY = 150           # BUG-359: score per level with a revealed cavern within FLOOD_R of the dig


PASS_HINT = "`bp sites fortcore aquifer=pass` puts the aqshaft first and the core under the aquifer"      # BUG-603


def _flooded(cands: list, snap: dict, manifest: dict | None, p: dict, rects: dict) -> list:
    """BUG-359 (Run 16c i3: every fortcore site broke into water, 'breach:heavy_aquifer' at A74_92_125_3, 'breach:cavern_lake'
    at A88_92_125_3, the ranking only said 'light aquifer'): the levels under the anchor down to the core are rated from
    the snapshot and the manifest, like `_dry` rates the recorded breaches. A site is dropped when revealed water lies
    within FLOOD_R of a deep dug rect (a lake or pool beside the shaft); it is penalized (AQ_PENALTY per level) for each
    known aquifer level the dig passes (`known_aquifer`) and (CAV_PENALTY) for a revealed cavern near it. The reason line
    names them (`aquifer at z120,z122`, `cavern near z120`) or says that nothing is known (hidden rock is unknown).
    p.aquifer above/pass chooses its levels itself (aquifer_ok); ValueError when every site meets water."""
    if not cands or p.get("aquifer", ""):
        return cands
    x0, y0, _, x1, y1, _ = snap["bbox"]
    wmin, wmax = min(rects), max(rects)
    light = known_aquifer(snap, manifest)
    wet = _Pref(snap, lambda c: c in WET)
    cav = _Pref(snap, points=[tuple(q) for q in (snap.get("marks") or {}).get("cavern", [])])
    deep = [(w, lst) for w, lst in rects.items() if w <= FLOOD_W]
    heavy = heavy_breach_levels(manifest)               # BUG-484: levels a dig of ours met a heavy aquifer on
    out, hit = [], []
    for c in cands:
        ax, ay, az = c["anchor"]
        hv = sorted((z for z in heavy if az + wmin <= z <= az + wmax), reverse=True)
        if hv:
            # BUG-484 (Run 16a i1 Basementflew y388: plan propose drew fortcore @A46_61_131 stage 1 without p.aquifer, its dig met the
            # heavy z116 again, AQ_HEAVY): a stage 1 with no p.aquifer never digs through a level a dig of ours met a heavy aquifer on;
            # only p.aquifer=pass (the aqshaft with its heavy ring first, the core under the aquifer) or above (the fort over it) does
            lbl = f"heavy aquifer known at z{','.join(str(z) for z in hv)}"
            if lbl not in hit:
                hit.append(lbl)
            continue
        wat, cvz = set(), set()
        for w, lst in deep:
            for r in lst:
                a, b, d, e = _rot_rect(r, ax, ay, c["rot"])
                a, b, d, e = max(a - FLOOD_R, x0), max(b - FLOOD_R, y0), min(d + FLOOD_R, x1), min(e + FLOOD_R, y1)
                if a > d or b > e:
                    continue
                if wet.count(a, b, d, e, az + w):
                    wat.add(az + w)
                if cav.count(a, b, d, e, az + w):
                    cvz.add(az + w)
        if wat:
            lbl = f"water below at z{','.join(str(z) for z in sorted(wat))}"
            if lbl not in hit:
                hit.append(lbl)
            continue
        aq = sorted(z for z in light if az + wmin <= z <= az + wmax)
        notes = []
        if aq:
            # BUG-603 (Run 16c i3 Wallfree y372: the embark panel said 'light aquifer', the site was ranked without a word, the dig met a
            # heavy level and sat parked 30 d): a site the dig of which meets a known aquifer level says so and names the way past it
            notes.append("aquifer at " + ",".join(f"z{z}" for z in aq)
                         + f" MEETS the dig (a heavy level stops it for 30 days, AQ_HEAVY; {PASS_HINT})")
        if cvz:
            notes.append("cavern near " + ",".join(f"z{z}" for z in sorted(cvz)))
        if not notes:
            notes.append(f"no aquifer or water known on z{az + wmin}-{az + wmax} (hidden rock is unknown; an embark whose panel shows "
                         f"an aquifer hides its levels until they are dug: {PASS_HINT})")
        out.append({**c, "score": max(c["score"] - AQ_PENALTY * len(aq) - CAV_PENALTY * len(cvz), 0),
                    "why": c["why"] + "; " + "; ".join(notes)})
    if not out:
        raise ValueError(f"fortcore: no site clear of water below: every site's dig lies within {FLOOD_R} tiles of "
                         f"revealed water or meets a heavy aquifer ({'; '.join(hit[:3])}{' +more' if len(hit) > 3 else ''}); another "
                         "part of the map, or p.aquifer=pass (the aqshaft with its ring first, the core under the aquifer: "
                         "`bp sites fortcore aquifer=pass`, p.depth is chosen for it)")
    return out


def _dry(cands: list, manifest: dict | None) -> list:
    """BUG-130 (Run 9, Run 14 y707: the fortcore stopped as breach:damp and was never re-sited): the fortcore candidates
    whose dig (the full box over all its levels, `dig`) stays more than BREACH_R tiles (x/y) away from every recorded
    breach on a level from one above to one below it, and whose dig reaches no wet area: BUG-388 (Run 16 region1, aquifer
    nearly everywhere: 'no dry fortcore site ... within 10 tiles of a recorded breach (wet level z130)' at every depth, so a
    single stop blacklisted every site of the map): a level with damp or water breaches of LAYER_MIN projects (a light aquifer
    is a layer: a second stop on the same level shows it is no pocket), or one heavy_aquifer stop, rules out only the dig
    that reaches that level within LAYER_R tiles (x/y) of one of the stops on it, never the whole level. Beyond that radius
    the known-aquifer rating (`_flooded`, `aquifer_ok`) still judges the levels.
    ValueError ("no dry fortcore site") when candidates existed and every one comes too close: the caller drafts the
    closure instead (plan propose), or, when the whole map is wet, the surface core (BUG-387)."""
    pts = breach_points(manifest)
    if not pts or not cands:
        return cands
    R = BREACH_R
    layers = _breach_layers(manifest)

    def near(c):
        x0, y0, z0, x1, y1, z1 = c["dig"]
        for z in sorted(layers):                # BUG-388: the wet layer's area around its own stops
            if z0 <= z <= z1 and any(pz == z and x0 - LAYER_R <= x <= x1 + LAYER_R and y0 - LAYER_R <= y <= y1 + LAYER_R
                                     for (x, y, pz), _ in pts):
                return layers[z]
        return next((lbl for (x, y, z), lbl in pts
                     if z0 - 1 <= z <= z1 + 1 and x0 - R <= x <= x1 + R and y0 - R <= y <= y1 + R), None)
    out, hit = [], []
    for c in cands:
        lbl = near(c)
        if lbl is None:
            out.append(c)
        elif lbl not in hit:
            hit.append(lbl)
    if not out:
        raise ValueError(f"fortcore: no dry fortcore site: every site's dig lies within {R} tiles of a recorded breach "
                         f"({'; '.join(hit[:3])}{' +more' if len(hit) > 3 else ''})")
    return out


def surface_core_why(snap: dict, manifest: dict | None, site: dict | None, p: dict | None = None) -> str | None:
    """BUG-387 (Run 16 region1: aquifer almost everywhere; i1 depth=1 breached heavy_aquifer at 4 %, i3 sites 1-6 steps from
    water): why the fort's core goes on the surface (bp/surfacecore.py), or None when a dug fortcore is fine. `site` = the best
    fortcore site the ranking offered (None: it offered none). A known aquifer level within SURFACE_AQ levels under the anchor
    (the dig would meet it: `known_aquifer`), or a wet level a recorded breach shows at or under it, says the same."""
    if site is None:
        return "no dry fortcore site on the snapshot"
    az = site["anchor"][2]
    lo = az - SURFACE_AQ
    near = sorted((z for z in known_aquifer(snap, manifest) if z >= lo), reverse=True)
    if near:
        return f"aquifer known at z{near[0]}, {max(az - near[0], 0)} level(s) under the fortcore anchor (z{az})"
    # BUG-429 (Run 16b i2 Glendagger: the core at z137 dug to z129, aquifer z123-129 known; 'within 3 levels' never said so): a known
    # aquifer level inside the whole dig (the core digs SURFACE_DIG levels under its anchor, or down to its recorded dig box)
    dig_lo = az - SURFACE_DIG
    if site.get("dig"):
        dig_lo = min(dig_lo, int(site["dig"][2]))
    inside = sorted((z for z in known_aquifer(snap, manifest) if dig_lo <= z < lo), reverse=True)
    if inside:
        return (f"aquifer known at z{inside[0]}, {max(az - inside[0], 0)} level(s) under the fortcore anchor (z{az}), inside its "
                f"dig (z{dig_lo}..z{az})")
    # a wet layer a breach recorded (heavy_aquifer, damp stops) inside the whole dig range: `_dry` only rules out digs near its
    # stops, a farther site would dig into the same aquifer (Run 16 i1/i3), so the core goes on the surface
    reach = az - SURFACE_DIG
    if site.get("dig"):
        reach = min(reach, int(site["dig"][2]))
    wet = sorted((z for z in _breach_layers(manifest) if reach <= z <= az), reverse=True)
    if wet:
        return f"wet level z{wet[0]} recorded by a breach, {max(az - wet[0], 0)} level(s) under the fortcore anchor (z{az}), inside its dig"
    return None


def water_bonus(steps: int | None) -> int:
    """+60..+30 within WATER_NEAR walking steps of revealed water, -1 per step beyond, -80 at worst or none."""
    if steps is None:
        return -80
    if steps <= WATER_NEAR:
        return 60 - steps
    return max(-80, WATER_NEAR - steps)


def ice_tiles(snap: dict | None) -> set[tuple[int, int, int]]:
    """BUG-400: the revealed ice tiles of a sites export (snapshot `ice`: a frozen river or lake)."""
    return {(int(q[0]), int(q[1]), int(q[2])) for q in ((snap or {}).get("ice") or []) if isinstance(q, (list, tuple)) and len(q) == 3}


def other_group(snap: dict, g: Graph) -> bytearray | None:
    """BUG-400: the nodes of g that lie in another walk group than the citizens' (snapshot wg '0'); None when the
    snapshot carries no walk groups (an audit or debug export, an older kernel)."""
    wg = snap.get("wg")
    if not isinstance(wg, dict):
        return None
    out = bytearray(g.N)
    z0 = g.bbox[2]
    for k, rows in (wg.get("rows") or {}).items():
        try:
            base = (int(k[1:]) - z0) * g.WH
        except ValueError:
            continue
        if base < 0 or base >= g.N:
            continue
        for yy, row in enumerate(rows[:g.H]):
            for xx in range(min(len(row), g.W)):
                if row[xx] == "0":
                    out[base + yy * g.W + xx] = 1
    return out


def water_steps(g: Graph, water=None, ice=None, other=None) -> dict[int, int]:
    """Walking steps (no climbing) from every reachable node to the nearest tile a dwarf can fill a bucket at:
    a walkable tile with revealed drinkable water on it, beside it, or one level below it (a brook bed under
    the walkable brook top). `water`: the water tiles that count (default every revealed one).
    BUG-400 (Run 16a Mansionlauded and Bachwald, 'water 1 steps' over a frozen river, the fort died of thirst): `ice`
    = the ice tiles; water with ice right above it (the ice floor is no brook top) gives no bank above it. `other` =
    nodes in another walk group than the citizens': never a bank and never walked through, so a step count is a
    path the citizens can take."""
    if water is None:
        wet = [i for i, c in enumerate(g.t) if c in WATER]
    else:
        wet = [i for i in (g.idx(t) for t in water) if i is not None]
    iced = {i for i in (g.idx(t) for t in (ice or ())) if i is not None}
    src = set()
    W, H, WH = g.W, g.H, g.WH
    for i in wet:
        x, y, z = i % W, (i // W) % H, i // WH
        for dz in (0, 1):
            if z + dz >= g.D or (dz == 1 and i + WH in iced):
                continue
            for dx, dy in ((0, 0),) + N8:
                if 0 <= x + dx < W and 0 <= y + dy < H:
                    j = i + dz * WH + dy * W + dx
                    if g.walk[j] and not (other and other[j]):
                        src.add(j)
    dist = {i: 0 for i in src}
    dq = deque(src)
    while dq:
        i = dq.popleft()
        for j in g.adj.get(i, ()):
            if j not in dist and not (other and other[j]):
                dist[j] = dist[i] + 1
                dq.append(j)
    return dist


# ---------------------------------------------------------------- cistern planner (live L3)
DIRS4 = ((1, 0), (-1, 0), (0, 1), (0, -1))
SIDE_OF = {v: k for k, v in rooms.SIDES.items()}
WATERTIGHT = frozenset("#?SC")        # what holds water beside a pipe (fortifications, doors, floors do not)


def _ring_ok(at, marks, x, y, z, wet_above=True) -> bool:
    """The tile and its 8-ring at z are rock or unknown, unmarked, with no revealed liquid on the ring above
    (the `_check` rule for one tile)."""
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            if at(x + dx, y + dy, z) not in GOOD or (x + dx, y + dy, z) in marks:
                return False
            if wet_above and (at(x + dx, y + dy, z + 1) or "?") in WET:
                return False
    return True


def _water_bodies(snap: dict, min_tiles: int, edge: bool = False) -> set:
    """Revealed drinkable water tiles that belong to a body of at least `min_tiles` tiles (8-connected per level,
    and across levels): a brook, river or lake, never a 2-tile well sump. `edge` (BUG-360): a smaller body that touches
    the snapshot's x/y border counts too (the box cuts it off, it goes on outside)."""
    return {t for comp in _water_components(snap, min_tiles, edge) for t in comp}


def _no_water(snap: dict, bodies: set, nwet: int, ice=None) -> str:
    """BUG-360 (Run 16b Ostgate: 'no water reachable, 0 water surface tiles' with a brook in the embark rectangle): the
    fortcore reason line when no walkable tile reaches revealed water. The sites box is the fort's pieces plus a margin
    (or the surface around the map centre), not the embark: it said nothing about where the brook lay. Now it names
    the box and whether any water was inside it at all."""
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    box = f"x{x0}-{x1} y{y0}-{y1} z{z0}-{z1}"
    if bodies and ice and any((x, y, z + 1) in ice for x, y, z in bodies):
        n = sum(1 for x, y, z in bodies if (x, y, z + 1) in ice)
        return (f"no water reachable ({n} of {len(bodies)} water tile(s) in the snapshot box {box} lie under ice: a frozen "
                "river or lake is no drink until it thaws)")
    if not bodies and not nwet and ice:
        return (f"no water reachable ({len(ice)} ice tile(s) in the snapshot box {box}: the river or lake is frozen, "
                "no drink until it thaws)")
    if bodies:
        return f"no water reachable (revealed water in the snapshot box {box}, but no walking route to it)"
    if nwet:
        return f"no water reachable (only {nwet} water tile(s) in the snapshot box {box}: a puddle, not a brook)"
    return (f"no water reachable (none revealed inside the snapshot box {box}; a brook beyond it is not seen: "
            "dfllm cmd snapshot purpose=sites with a bbox that covers the embark)")


def _water_components(snap: dict, min_tiles: int, edge: bool = False) -> list[list]:
    """The bodies of _water_bodies one by one (each a list of tiles, in a stable order)."""
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    wet = set()
    for z in range(z0, z1 + 1):
        for j, row in enumerate(snap["rows"][f"z{z}"]):
            for i, c in enumerate(row):
                if c in WATER:
                    wet.add((x0 + i, y0 + j, z))
    keep, seen = [], set()
    for t in sorted(wet):
        if t in seen:
            continue
        comp, dq = [t], deque([t])
        seen.add(t)
        while dq:
            x, y, z = dq.popleft()
            for dz in (-1, 0, 1):
                for dx, dy in ((0, 0),) + N8:
                    n = (x + dx, y + dy, z + dz)
                    if n in wet and n not in seen:
                        seen.add(n)
                        comp.append(n)
                        dq.append(n)
        if len(comp) >= min_tiles or (edge and any(t[0] in (x0, x1) or t[1] in (y0, y1) for t in comp)):
            keep.append(comp)
    return keep


def _intake_targets(at, snap: dict, near=None, radius: int | None = None, manifest: dict | None = None,
                    min_tiles: int = 8, rock: bool = False, marks=()) -> dict:
    """{(x, y): [((dx, dy), T, kind)]}: shaft columns B two tiles from revealed water W with the breach tile
    G between them (B -> G -> W along (dx, dy)), as `intake_ok` wants them. Only water of a body of at least
    `min_tiles` tiles counts, and nothing inside the fort's own geometry (a sump or a cistern is no source).
    `rock` (BUG-424): also the sealed rock intakes (B and G rock or unknown, `_rock_top_ok`) of water that lies in a gully."""
    fort = [(b[0] - 1, b[1] - 1, b[2] - 1, b[3] + 1, b[4] + 1, b[5] + 1) for b in topo.fort_boxes(manifest or {})]

    def inside(x, y, z):
        return any(b[0] <= x <= b[3] and b[1] <= y <= b[4] and b[2] <= z <= b[5] for b in fort)
    out: dict = {}
    for x, y, z in sorted(_water_bodies(snap, min_tiles)):
        if near is not None and radius is not None and                 max(abs(x - near[0]), abs(y - near[1]), abs(z - near[2])) > radius:
            continue
        for dx, dy in DIRS4:
            gx, gy, bx, by = x - dx, y - dy, x - 2 * dx, y - 2 * dy
            for kind, t in (("bed", z + 1), ("bank", z)):
                if at(bx, by, t) == "." and at(gx, gy, t) == "." and at(gx, gy, t - 1) in GOOD                         and not inside(x, y, z) and not inside(gx, gy, t) and not inside(bx, by, t):
                    out.setdefault((bx, by), []).append(((dx, dy), t, kind))
                elif rock and at(gx, gy, t - 1) in GOOD and not inside(x, y, z) and not inside(gx, gy, t) \
                        and not inside(bx, by, t) and (bx, by, t) not in marks and (gx, gy, t) not in marks \
                        and _rock_top_ok(at, (bx, by, t), (gx, gy, t)):
                    out.setdefault((bx, by), []).append(((dx, dy), t, kind))     # BUG-424: the brook in a rock gully
    return out


def _bfs4(starts, ok) -> dict:
    dist = {s: 0 for s in starts}
    dq = deque(starts)
    while dq:
        x, y = dq.popleft()
        for dx, dy in DIRS4:
            n = (x + dx, y + dy)
            if n not in dist and ok(n):
                dist[n] = dist[(x, y)] + 1
                dq.append(n)
    return dist


def _waypoints(tiles) -> list[tuple[int, int]]:
    pts = [tiles[0]]
    for a, b, c in zip(tiles, tiles[1:], tiles[2:]):
        if (b[0] - a[0], b[1] - a[1]) != (c[0] - b[0], c[1] - b[1]):
            pts.append(b)
    pts.append(tiles[-1])
    return pts


def plan_cistern(snap: dict, manifest: dict, level: str = "refuge", near=None, radius: int | None = None,
                 burrow: str | None = None, max_tiles: int = 400, safe: bool = True, rock: bool | None = None) -> dict:
    """Route a cistern pipe on `snap` from a well room (refuge room or public Z4) to revealed water, the way
    a player designates it: only revealed tiles decide, hidden rock is diggable unknown. `safe` (default) takes
    only water whose level is not above the well room: pressure lifts water at most to one level below its
    source, so the well room stays dry even if the breaker failed (a pond above the fort is refused; pass
    safe=False to rely on the breaker alone). Returns {params, site:{id, anchor, rot}, tiles, cost, why};
    raises ValueError when no route exists (export a 'sites' snapshot over well room, route and water first).
    BUG-424: `rock` None = bank intakes first, then (when none fits) sealed rock intakes for water in a gully, the result says
    `rock` 1 for the latter; True / False take only that kind."""
    if rock is None:
        try:
            return plan_cistern(snap, manifest, level, near, radius, burrow, max_tiles, safe, rock=False)
        except ValueError as first:
            try:
                return plan_cistern(snap, manifest, level, near, radius, burrow, max_tiles, safe, rock=True)
            except ValueError:
                raise first from None
    if level not in rooms.LEVELS:
        raise ValueError(f"level {level!r} not one of {list(rooms.LEVELS)}")
    if not ((manifest or {}).get("zones") or {}).get("Z4"):
        raise ValueError("cistern: the planner needs the fort manifest with zones.Z4")
    at = _At(snap)
    marks = {tuple(q) for k in MARKS for q in snap.get("marks", {}).get(k, [])}
    keep_out = _keep_out(manifest)
    ref = manifest.get("refuge")
    zr = ref["anchor"][2] if ref else None
    targets = _intake_targets(at, snap, near, radius, manifest, rock=bool(rock), marks=marks)
    if not targets:
        raise ValueError("no revealed water with two tiles of revealed bank floor beside it in the snapshot")
    base = check_params("cistern", {"level": level, **({"burrow": burrow} if burrow else {})})
    core_rects = footprint("cistern", base)
    bad = _Pref(snap, lambda c: c not in GOOD)
    hid = _Pref(snap, lambda c: c == "?")
    mk = _Pref(snap, points=list(marks))
    wet = _Pref(snap, lambda c: c in WET)
    g = Graph(snap)
    by_level: dict = {}

    def level_data(P):
        if P not in by_level:
            cache: dict = {}

            def ok(n):
                if n not in cache:
                    x, y = n
                    cache[n] = (_ring_ok(at, marks, x, y, P) and (at(x, y, P + 1) or "?") not in OPEN_UP
                                and not any(_overlap((x - 1, y - 1, P, x + 1, y + 1, P), b) for b in keep_out))
                return cache[n]

            def shaft_ok(b, t):
                return all(_ring_ok(at, marks, b[0], b[1], z) for z in range(P + 1, t))

            def level_ok(e):                   # water z = T - 1 (bed) or T (bank); safe: not above the well room
                return not safe or (e[1] - (1 if e[2] == "bed" else 0)) <= P + 1
            goals = {b: [e for e in lst if e[1] > P and level_ok(e) and shaft_ok(b, e[1])]
                     for b, lst in targets.items() if ok(b)}
            goals = {b: lst for b, lst in goals.items() if lst}
            by_level[P] = (ok, goals, _bfs4(list(goals), ok))
        return by_level[P]

    best = None
    tried = 0
    for i in _anchor_tiles(g, "cistern", base, manifest):
        ax, ay, az = g.pos(i)
        for rot in range(4):
            du, dv = rot_uv(0, 1, rot)
            if at(ax + du, ay + dv, az) not in GOOD:
                continue
            res = _check(core_rects, ax, ay, az, rot, bad, hid, mk, False, wet)
            if res is None or any(_overlap(res[2], b) for b in keep_out):
                continue
            if zr is not None and res[2][2] <= zr <= res[2][5] and level != "refuge":
                continue
            X = Xform((ax, ay, az), rot)
            P = az - 1
            ok, goals, dist = level_data(P)
            S = X.pos(*rooms.CISTERN_START, -1)[:2]
            if S not in dist:
                continue
            tried += 1
            near_core = {X.pos(u, v, -1)[:2] for u, v in rooms.cistern_layout(base)["cistern"]} | \
                {X.pos(*rooms.CISTERN_SPILL, -1)[:2]}
            blocked = {(x + dx, y + dy) for x, y in near_core for dx in (-1, 0, 1) for dy in (-1, 0, 1)} - {S}
            found = _astar(at, S, P, goals, dist, ok, blocked, 10 * max_tiles + 1)
            if found is None:
                continue
            cost, tiles, (d, t, kind) = found
            local = [rot_uv(x - ax, y - ay, (4 - rot) % 4) for x, y in tiles]
            side = SIDE_OF[rot_uv(d[0], d[1], (4 - rot) % 4)]
            p = {**base, "path": rooms.format_path(_waypoints(local)), "rise": t - P, "side": side, "water": kind}
            try:
                p = check_params("cistern", p)
                rooms.cistern_layout(p)
            except ValueError:
                continue                                   # the route touches itself or is too long to encode
            if best is None or cost < best["cost"]:
                best = {"params": p, "site": {"id": "S1", "anchor": [ax, ay, az], "rot": rot},
                        "tiles": len(tiles), "cost": cost,
                        "why": f"pipe {len(tiles)} tiles at z{P}, intake {kind} water, rise {t - P}, side {side}"}
                if rock:                                   # BUG-424: shaft top and breach are dug in rock
                    best["rock"] = 1
                    best["why"] += ", sealed rock intake (the brook lies in a gully)"
    if best is None:
        raise ValueError(f"no pipe route from a {level} well room to revealed water ({tried} anchors tried)")
    return best


def cistern_access(snap: dict, manifest: dict, near=None, radius: int | None = 20, level: str | None = None) -> dict:
    """BUG-424 (Run 16a i1 Manorsubtle, Mansionlauded, Bachwald: three forts died of thirst with a brook 8-15 tiles away behind
    rock): the safe way to water the cistern template offers, no free digging at the water: its pipe with the breaker, fortification
    and floodgate does the last tiles (a bank intake, else a sealed rock intake). `near` = the water tile nearest to the fort
    (water_sources `at`), the well room on the core level (the refuge level when the manifest has a refuge). Tries the safe plan first
    (no water above the well room); a plan that only exists for water above the well room is returned as `unsafe` and is never
    placed by itself. Returns {plan: plan_cistern's dict | None, unsafe, level, site (the explicit A<x>_<y>_<z>_<rot> label of its
    anchor), why (the refusal)}."""
    lv = level or ("refuge" if (manifest or {}).get("refuge") else "core")
    burrow = "Tiefe+" if lv == "refuge" else None
    out: dict = {"plan": None, "unsafe": False, "level": lv, "site": None, "why": ""}
    errs: list[str] = []
    for safe in (True, False):
        try:
            plan = plan_cistern(snap, manifest, lv, near, radius if near else None, burrow, safe=safe)
        except ValueError as e:
            errs.append(str(e))
            continue
        a = plan["site"]
        out.update(plan=plan, unsafe=not safe, site=f"A{a['anchor'][0]}_{a['anchor'][1]}_{a['anchor'][2]}_{a['rot']}")
        return out
    out["why"] = errs[0] if errs else "no plan"
    return out


def _astar(at, S, P, goals, dist, ok, blocked, max_cost):
    """Cheapest 1-wide orthogonal pipe S -> shaft column: 10 per tile, +1 unknown, +4 per bend; the pipe may not
    arrive from the breach side. Returns (cost, tiles S..B, (d, T, kind)) or None."""
    start = (S[0], S[1], -1)
    best = {start: 0}
    parent: dict = {}
    pq = [(10 * dist[S], 0, start)]
    while pq:
        _, cost, st = heapq.heappop(pq)
        if cost > best.get(st, 1 << 60):
            continue
        x, y, k = st
        if k >= 0 and (x, y) in goals:
            ax_, ay_ = DIRS4[k]
            for d, t, kind in goals[(x, y)]:
                if d != (-ax_, -ay_):
                    path = [(x, y)]
                    while st in parent:
                        st = parent[st]
                        path.append(st[:2])
                    return cost, path[::-1], (d, t, kind)
        for nk, (dx, dy) in enumerate(DIRS4):
            if k >= 0 and (dx, dy) == (-DIRS4[k][0], -DIRS4[k][1]):
                continue
            n = (x + dx, y + dy)
            if n in blocked or n not in dist or not ok(n):
                continue
            c = cost + 10 + (1 if at(n[0], n[1], P) == "?" else 0) + (4 if k >= 0 and nk != k else 0)
            ns = (n[0], n[1], nk)
            if c <= max_cost and c < best.get(ns, 1 << 60):
                best[ns] = c
                parent[ns] = st
                heapq.heappush(pq, (c + 10 * dist[n], c, ns))
    return None


# ---------------------------------------------------------------- cistern checks (offline, as built)
def _plain(doc: dict) -> dict:
    """Copy of a bp document with the dig markers (md/mw/mb) removed, so render simulates those tiles."""
    st = []
    for s in doc["stages"]:
        chunks = []
        for ch in s["chunks"]:
            cells = []
            for dx, dy, dz, text in ch["cells"]:
                if s["mode"] == "dig":
                    while text[:2] in ("md", "mw", "mb") and len(text) > 2:
                        text = text[2:]
                cells.append([dx, dy, dz, text])
            chunks.append({**ch, "cells": cells})
        st.append({**s, "chunks": chunks})
    return {**doc, "stages": st}


def _shut_in(snap: dict, doc: dict, L: dict, X: Xform) -> list:
    """Cistern and pipe tiles that no walker reaches, neither from the anchor nor from the shaft top, once the
    wells and closed floodgates of `doc` stand (both impassable; render leaves them open): whoever works there
    is shut in, and the water drowns him. Review: the ramps under the holes of a dug-out cistern lead nowhere
    (a DF ramp climbs only onto the floor above an adjacent wall), and a floodgate at the cistern end sealed
    the pipe between itself and the fortification."""
    from .render import cell_rects
    x0, y0 = snap["bbox"][0], snap["bbox"][1]
    rows = {k: list(v) for k, v in snap["rows"].items()}
    for st, k, _, bx, by, _, _, bz in cell_rects(doc):
        r = rows.get(f"z{bz}")
        if st["mode"] == "build" and k in ("l", "x") and r is not None and 0 <= by - y0 < len(r) \
                and 0 <= bx - x0 < len(r[0]):
            line = r[by - y0]
            r[by - y0] = line[:bx - x0] + "B" + line[bx - x0 + 1:]
    g = topo.Graph({**snap, "rows": rows})
    src = [g.idx(tuple(doc["anchor"]))]
    if L["intake"]:
        src.append(g.idx(X.pos(*L["shaft"], L["w_top"])))
    seen, _ = g.bfs([i for i in src if i is not None], climb=False)
    out = []
    for u, v in L["cistern"] + L["pipe"]:
        i = g.idx(X.pos(u, v, -1))
        if i is None or (g.walk[i] and not seen[i]):         # floodgate 'B' and fortification 'F' hold nobody
            out.append(X.pos(u, v, -1))
    return out


def cistern_findings(docs, base=None, live: bool = False) -> list:
    """Water rules for cistern documents on the as-built result of `docs` (markers simulated; `base` = a
    snapshot dict, default the synthetic terrain of render.as_built):
    water_leak (a pipe/cistern/shaft tile beside an open tile outside the water network: water would run
    there, diagonals included), water_rise (an open tile right above a pipe or cistern tile other than the
    well hole, the pond hole and the stair: pressurized water would rise into it), breaker (the spill step is
    not a diagonal between two rock tiles), intake_open (a walker reaches the cistern or the well room from the
    shaft top: no fortification), parts (no floodgate, fortification or lever), shut_in (a cistern or dry pipe
    tile a walker from the anchor cannot reach once the well and the closed floodgate stand), build_order (the
    floodgate is not built after the fortification, whose only access is the floodgate tile), pressure
    (warning: the water level is not below the well room, only the breaker keeps it out), and with fortcore in
    `docs` the worst-case audit (bypass, refuge separation).
    live=True: `base` is a fresh snapshot of the dug and built cistern, checked as it is (no simulation): the
    check before the lever is pulled. Digging revealed every tile around the pipe, so a cave or an old tunnel
    the planner could not see shows up as water_leak now; coverage (the snapshot misses a pipe tile) and
    unbuilt (no floodgate 'B' or fortification 'F' on the map yet) are errors there."""
    from .render import as_built, cell_rects
    from .validate import Finding
    docs = [docs] if isinstance(docs, dict) else list(docs)
    if live:
        if not isinstance(base, dict):
            raise ValueError("cistern_findings(live=True) needs the fresh snapshot as base")
        snap, out, world = base, [], None
    else:
        world = as_built([_plain(d) for d in docs], base=base)
        out = [Finding("build_tile", e) for e in world.errors]
        snap = world.snapshot()
    at = _At(snap)
    g = None
    for d in docs:
        if d["tpl"] != "cistern":
            continue
        L = rooms.cistern_layout(d["params"])
        X = Xform(d["anchor"], d["rot"])
        name = f"cistern {d['anchor']}"
        shut = _shut_in(snap, d, L, X)
        if shut:
            out.append(Finding("shut_in", f"{name}: {len(shut)} tiles below the well room (first {shut[0]}) are cut "
                                          "off once the well and the closed floodgate stand: nobody gets out"))
        if not L["intake"]:
            continue
        pipe = [X.pos(u, v, -1) for u, v in L["pipe"]]
        cist = [X.pos(u, v, -1) for u, v in L["cistern"]]
        shaft = [X.pos(*L["shaft"], w) for w in range(-1, L["w_top"] + 1)]
        G = X.pos(*L["breach"])
        net = set(pipe) | set(cist) | set(shaft) | {G, (G[0], G[1], G[2] - 1)}
        holes = {X.pos(*L[k], 0)[:2] for k in ("well", "stair", "pond") if L[k]}   # meant to be open above
        if live:
            miss = [t for t in pipe + cist + shaft if at(*t) is None]
            if miss:
                out.append(Finding("coverage", f"{name}: {len(miss)} pipe/cistern/shaft tiles lie outside the "
                                               f"snapshot (first {miss[0]}): export one over the whole pipe"))
            for pos, want, what in ((X.pos(*L["gate"], -1), "B", "floodgate"),
                                    (X.pos(*L["barrier"], -1), "F", "fortification")):
                if at(*pos) not in (want, None):
                    out.append(Finding("unbuilt", f"{name}: no {what} at {pos} yet ({at(*pos)!r})"))
        for t in pipe + cist + shaft[:-2]:
            for dx, dy in N8:
                n = (t[0] + dx, t[1] + dy, t[2])
                c = at(*n)
                if n not in net and c is not None and c not in WATERTIGHT:
                    out.append(Finding("water_leak", f"{name}: {t} touches open tile {n} ({c!r})"))
        for t in pipe + cist:
            c = at(t[0], t[1], t[2] + 1)
            if (t[0], t[1]) not in holes and c is not None and c in OPEN_UP:
                out.append(Finding("water_rise", f"{name}: open tile {c!r} right above {t}"))
        (su, sv), (bu, bv) = rooms.CISTERN_SPILL, rooms.CISTERN_START
        corners = [X.pos(bu, sv, -1), X.pos(su, bv, -1)]
        if abs(bu - su) != 1 or abs(bv - sv) != 1 or any(at(*c) not in WATERTIGHT for c in corners):
            out.append(Finding("breaker", f"{name}: the spill step is no diagonal between rock tiles"))
        built, stage_of = set(), {}
        for n, st in enumerate(d["stages"]):
            if st["mode"] != "build":
                continue
            for _, k, _, x0, y0, _, _, z in cell_rects({"stages": [st]}):
                built.add((k, (x0, y0, z)))
                stage_of.setdefault(k, n)
        for key, pos, what in (("x", X.pos(*L["gate"], -1), "floodgate"),
                               ("CF", X.pos(*L["barrier"], -1), "fortification"),
                               ("Tl", X.pos(*L["lever"], 0), "lever")):
            if (key, pos) not in built:
                out.append(Finding("parts", f"{name}: no {what} at {pos}"))
        if "x" in stage_of and "CF" in stage_of and stage_of["x"] <= stage_of["CF"]:
            out.append(Finding("build_order", f"{name}: the floodgate is not built after the fortification; a "
                                              "closed floodgate leaves the fortification site unreachable"))
        g = g or topo.Graph(snap)
        room = [X.pos(u, v, 0) for v in range(L["room"][1], L["room"][3] + 1)
                for u in range(L["room"][0], L["room"][2] + 1)]
        inner = g.mask_pts(cist + room)
        through = g.mask_pts(list(net) + room + [X.pos(0, 1, 0)])     # only the pipe's own way in
        outside = bytearray(1 - b for b in through)
        top = g.idx(shaft[-1])
        if top is not None and g.node(top) and g.bfs([top], blocked=outside, stop=inner)[1] is not None:
            out.append(Finding("intake_open", f"{name}: a walker gets from the shaft top through the pipe into "
                                              "the cistern (no fortification)"))
        level = d["anchor"][2] + L["water"][0][2]
        if level - 1 >= d["anchor"][2]:
            out.append(Finding("pressure", f"{name}: water level z{level} is not below the well room "
                                           f"z{d['anchor'][2]}; only the breaker keeps it out", "warning"))
    if world and any(d["tpl"] == "fortcore" for d in docs) and world.manifest.get("zones", {}).get("Z2"):
        res = topo.audit(snap, world.manifest, g)
        if res["bypass"]:
            out.append(Finding("bypass", "with the cistern built an edge->Z3/Z4 path avoids the trap hall"))
        if world.manifest.get("refuge") and not res["refuge_sep"]:
            out.append(Finding("refuge", "with the cistern built the refuge is not separated: "
                                         + "; ".join(f for f in res["fails"] if f.startswith("refuge"))))
    return out


# ---------------------------------------------------------------- CLI
def main(argv=None) -> int:
    """python -m dfpilot.bp.sites cistern [--save NAME | --snap FILE --manifest FILE] [--level refuge]
    [--near x,y,z --radius N] [--burrow NAME]: route a cistern pipe, check it, print the bp.place command.
    python -m dfpilot.bp.sites cistern-check [--save NAME] [--snap FILE] [--bp ID]: the live water rules
    on the dug and built cistern before the lever is pulled (exit 1 = do not pull).
    Read only: it reads snapshots, the manifest and bp/*.json and writes nothing."""
    import argparse
    import json
    from pathlib import Path
    ap = argparse.ArgumentParser(prog="python -m dfpilot.bp.sites")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cistern", help="route a pipe from a well room to revealed water and print the plan")
    c.add_argument("--save", help="runtime save folder (default: ACTIVE); newest 'sites' snapshot + fort manifest")
    c.add_argument("--snap", help="snapshot file instead of the save's newest")
    c.add_argument("--manifest", help="manifest file instead of the save's fort manifest")
    c.add_argument("--level", default="refuge", choices=list(rooms.LEVELS))
    c.add_argument("--near", help="x,y,z of the water to use (with --radius)")
    c.add_argument("--radius", type=int, default=12)
    c.add_argument("--burrow", help="burrow of the well room (default: Tiefe+ on the refuge level, else Kern+)")
    c.add_argument("--unsafe", action="store_true", help="also water above the well room (the breaker alone "
                                                         "keeps it out)")
    k = sub.add_parser("cistern-check", help="check the dug and built cistern(s) of bp/ on a fresh snapshot "
                                             "before the lever is pulled")
    k.add_argument("--save", help="runtime save folder (default: ACTIVE); its newest snapshot and bp/*.json")
    k.add_argument("--snap", help="snapshot file instead of the save's newest")
    k.add_argument("--bp", help="project id (default: every cistern project with a pipe)")
    a = ap.parse_args(argv)
    from .. import cmd as dcmd, files, paths
    sd = paths.save_dir(a.save)
    if a.cmd == "cistern-check":
        return _check_main(a, sd, dcmd, files)
    snap = files.read_snapshot(Path(a.snap)) if a.snap else dcmd.sites_snapshot(sd)
    man = json.loads(Path(a.manifest).read_text(encoding="utf-8")) if a.manifest else dcmd.fort_manifest(sd)
    if not snap:
        print("no snapshot: export one over well room, route and water, e.g. "
              "dfllm cmd snapshot '{\"bbox\":[x0,y0,z0,x1,y1,z1],\"purpose\":\"sites\"}'")
        return 2
    near = [int(v) for v in a.near.split(",")] if a.near else None
    burrow = a.burrow or ("Tiefe+" if a.level == "refuge" else None)
    try:
        plan = plan_cistern(snap, man, a.level, near, a.radius if near else None, burrow, safe=not a.unsafe)
    except ValueError as e:
        print(f"no plan: {e}")
        ref = (man.get("refuge") or {}).get("anchor")
        if ref:                                        # where a Water Source zone could go by hand meanwhile
            body = sorted(_water_bodies(snap, 8), key=lambda t: max(abs(t[0] - ref[0]), abs(t[1] - ref[1])))
            print("nearest revealed water (bodies >= 8 tiles) to the refuge: "
                  + (", ".join("%d,%d,%d" % t for t in body[:3]) or "none in this snapshot"))
        return 1
    from .emit import emit as emit_doc
    doc = emit_doc("cistern", plan["params"], plan["site"])
    found = cistern_findings(doc, base=snap)
    ranked = rank(snap, "cistern", plan["params"], manifest=man, n=dcmd.RANK_N)
    # review: cmd.place reads S<k> as the k-th ranked site free of other projects, not the k-th ranked one; a
    # label counted the other way placed the same pipe from another anchor
    occ, free, label = dcmd.occupancy(sd), 0, None
    for s in ranked:
        try:
            if occ.clash(emit_doc("cistern", plan["params"], s)):
                continue
        except ValueError:
            continue
        free += 1
        if s["anchor"] == plan["site"]["anchor"] and s["rot"] == plan["site"]["rot"]:
            label = f"S{free}"
            break
    print(json.dumps({"plan": plan, "ranked": ranked[:3], "findings": [str(f) for f in found]}, indent=1))
    if label is None:
        print("no bp.place line: the planned site is not among the free ranked sites (another project's tiles?)")
        return 1
    arg = json.dumps({"tpl": "cistern", "site": label, "p": plan["params"]}, separators=(",", ":"))
    print(f"dfllm cmd bp.place '{arg}'")
    print("after the gate stage: link the well room's lever to the floodgate (lever sheet); after the breach: "
          "python -m dfpilot.bp.sites cistern-check on a fresh snapshot over the pipe, make sure nobody is "
          "in the dry pipe, then pull the lever once (the pipe floods under pressure)")
    return 0 if not [f for f in found if f.level == "error"] else 1


def _check_main(a, sd, dcmd, files) -> int:
    """cistern-check: the live water rules (cistern_findings live=True) for the cistern projects in bp/."""
    from pathlib import Path
    snap = files.read_snapshot(Path(a.snap)) if a.snap else files.latest_snapshot(sd)
    if not snap:
        print("no snapshot: export one over the well room, the pipe and the intake (dfllm cmd snapshot ...)")
        return 2
    docs = []
    for p in dcmd.bp_files(sd):
        d = files.read_json(p)
        if not isinstance(d, dict) or d.get("tpl") != "cistern" or (a.bp and d.get("id", p.stem) != a.bp):
            continue
        try:
            if rooms.cistern_layout(d["params"])["intake"]:
                docs.append(d)
        except (KeyError, ValueError):
            continue
    if not docs:
        print(f"no cistern project with a pipe in {sd / 'bp'}" + (f" (id {a.bp})" if a.bp else ""))
        return 2
    found = cistern_findings(docs, base=snap, live=True)
    for f in found:
        print(f)
    bad = [f for f in found if f.level == "error"]
    print(f"{len(docs)} cistern(s) on snapshot {snap.get('id')}: "
          + (f"{len(bad)} error(s): do not pull the lever" if bad else "no error: the lever may be pulled once "
                                                                       "nobody is in the dry pipe"))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
