"""FR-103 deep anchor search: where the deep core (grand.deepcore) may go, on revealed tiles only (fair play, DESIGN §11).

An anchor is a public core floor (sites._anchor_tiles: Z4, not behind a private room's door, not on a civilian stair),
above the refuge level. Its shaft (0,1,w) runs `depth` levels down; the deep level holds the rooms. A site is refused when
* a check rect (grand.deep_rects: the shaft ring per level, the rooms' ring at the bottom) holds a revealed open, wet or
  marked tile (damp, warm, cavern, water), a soil mark at the bottom (hard stone only), revealed liquid right above, or
  leaves the snapshot sideways (levels below the snapshot count as unknown rock, as for explore);
* the shaft reaches a level with a revealed cavern, damp or warm mark or a recorded cavern breach (sites.avoid_levels), an
  aquifer level or the level below one (FR-95), a level within BREACH_DZ of a recorded breach, or the deep level lies within
  CAVERN_GAP levels above such a cavern level, or on the refuge level or next to it;
* a rect overlaps the attack path, the military pieces (sites._keep_out), the refuge rooms or a civilian stair grown by
  KEEP (the second shaft never opens into the refuge or the citizens' stair).
`floors` (the plan's known dry levels: tunnel levels of finished explore shafts without a breach) pins the deep level: only
those absolute levels count, the depth follows from the anchor. Score: 1000 - 5 per step to a stair + 10 per level down
+ KNOWN when the deep level is known dry - 1 per 20 unknown tiles.
"""
from __future__ import annotations

from . import grand, sites
from .primitives import rot_uv
from .topo import Graph

DEPTH_MIN, DEPTH_MAX = 3, 40
CAVERN_GAP = 3            # levels of rock kept between the deep level and a cavern level below it
BREACH_DZ = 1
KEEP = 2                  # tiles kept from the refuge rooms and the civilian stairs (x/y, z +-1)
KNOWN = 100


def blocked_levels(snap: dict, manifest: dict | None) -> tuple[set[int], set[int]]:
    """(levels no shaft or room may touch, levels the deep floor may not sit on)."""
    m = manifest or {}
    shaft = set(sites.avoid_levels(snap, {"avoid": ""}, m))
    caverns = {int(q[2]) for q in (snap.get("marks") or {}).get("cavern", []) if isinstance(q, (list, tuple)) and len(q) == 3}
    caverns |= {int(q[2]) for q in m.get("caverns") or [] if isinstance(q, (list, tuple)) and len(q) == 3}
    for z in sites.aquifer_levels(m):
        shaft |= {z, z - 1}
    for (_, _, z), _lbl in sites.breach_points(m):
        shaft |= set(range(z - BREACH_DZ, z + BREACH_DZ + 1))
    floor = set(shaft)
    for z in caverns:
        floor |= set(range(z, z + CAVERN_GAP + 1))
    ref = m.get("refuge")
    if ref:
        zr = ref["anchor"][2]
        floor |= {zr - 1, zr, zr + 1}
    return shaft, floor


def _guard_boxes(m: dict) -> list[tuple]:
    out = []
    for b in sites.refuge_rooms(m):
        out.append((b[0] - KEEP, b[1] - KEEP, b[2] - 1, b[3] + KEEP, b[4] + KEEP, b[5] + 1))
    for c in (m.get("stairs") or {}).get("civ") or []:
        if isinstance(c, (list, tuple)) and len(c) == 4:
            out.append((c[0] - KEEP, c[1] - KEEP, min(c[2], c[3]) - 1, c[0] + KEEP, c[1] + KEEP, max(c[2], c[3]) + 1))
    return out


def candidates(snap: dict, manifest: dict, depth: int | None = None, floors=None) -> tuple[list[dict], str]:
    """Valid placements [{anchor, rot, depth, score, box, why}] and, when there is none, why."""
    if not ((manifest or {}).get("zones") or {}).get("Z4"):
        return [], "deepcore: no core floor yet (zones.Z4: fortcore stage 1 first)"
    g = Graph(snap)
    steps_of = sites._stair_steps(g)
    keep_out = sites._keep_out(manifest) + _guard_boxes(manifest)
    ref = manifest.get("refuge")
    zr = ref["anchor"][2] if ref else None
    bad = sites._Pref(snap, lambda c: c not in sites.GOOD)
    hid = sites._Pref(snap, lambda c: c == "?")
    marks = [tuple(q) for k in sites.MARKS for q in (snap.get("marks") or {}).get(k, [])]
    mk = sites._Pref(snap, points=marks)
    soil = sites._Pref(snap, points=[tuple(q) for q in (snap.get("marks") or {}).get("soil", [])])
    wet = sites._Pref(snap, lambda c: c in sites.WET)
    shaft_bad, floor_bad = blocked_levels(snap, manifest)
    known = {int(z) for z in floors} if floors is not None else set()
    rects = {}
    out, why = [], {}
    for i in sites._anchor_tiles(g, grand.DEEP, {}, manifest):
        ax, ay, az = g.pos(i)
        if zr is not None and az <= zr:
            continue
        if depth is not None:
            ds = [depth]
        elif floors is not None:
            ds = sorted((az - z for z in known if DEPTH_MIN <= az - z <= DEPTH_MAX), reverse=True)
        else:
            ds = list(range(DEPTH_MAX, DEPTH_MIN - 1, -1))
        for D in ds:
            zf = az - D
            if floors is not None and zf not in known:
                continue
            if zf in floor_bad or any(z in shaft_bad for z in range(zf, az + 1)):
                why.setdefault("level", f"z{zf}")
                continue
            r = rects.setdefault(D, grand.deep_rects(D))
            hit = None
            for rot in range(4):
                du, dv = rot_uv(0, 1, rot)
                top = g.idx((ax + du, ay + dv, az))
                if top is None or g.t[top] not in sites.GOOD:
                    continue
                res = sites._check(r, ax, ay, az, rot, bad, hid, mk, True, wet)
                if res is None:
                    why.setdefault("rock", f"{ax},{ay},{az}")
                    continue
                unknown, missing, box = res
                parts = list(sites._rect_boxes(r, ax, ay, az, rot))
                if any(sites._overlap(p, k) for p in parts for k in keep_out):
                    why.setdefault("keep", f"{ax},{ay},{az}")
                    continue
                low = [p for p in parts if p[2] == zf]
                if any(soil.count(p[0], p[1], p[3], p[4], zf) for p in low):
                    why.setdefault("soil", f"z{zf}")
                    continue
                steps = min(steps_of.get(i, 99), 99)
                k = zf in known
                score = 1000 - 5 * steps + 10 * D + (KNOWN if k else 0) - unknown // 20
                hit = {"anchor": [ax, ay, az], "rot": rot, "depth": D, "box": box, "score": max(0, score),
                       "why": f"rot{rot}, deep level z{zf} ({D} down{', known dry' if k else ''}), {steps} steps to a "
                              f"stair, {unknown} unknown tiles, {missing} levels below the snapshot"}
                out.append(hit)
            if hit and depth is None:
                break                                     # the deepest valid level of this anchor is enough
    if out:
        return out, ""
    if floors is not None and not known:
        return [], "deepcore: no known dry deep level (no finished explore shaft without a breach: explore first)"
    parts = [f"{k} ({v})" for k, v in why.items()]
    return [], "deepcore: no site: " + (", ".join(parts) if parts else "no public core floor above the refuge level") \
        + " (blocked: level = cavern/damp/warm/wet layer/breach/refuge, rock = revealed open or wet tile, keep = attack path, " \
          "refuge or civilian stair, soil = not hard stone)"


def rank(snap: dict, p: dict, manifest: dict, n: int = 3, near=None, within=None, at=None, floors=None) -> list[dict]:
    """sites.rank for deepcore (p.depth fixed): top n non-overlapping sites, best first; ValueError with the reason."""
    cands, why = candidates(snap, manifest, depth=p["depth"], floors=floors)
    if not cands:
        raise ValueError(why)
    if near is not None or at is not None:
        cands = sites._near_point(cands, grand.DEEP, near, within, at)
    return _top(cands, n)


def _top(cands: list[dict], n: int) -> list[dict]:
    cands = sorted(cands, key=lambda c: (c.get("_d", 0), -c["score"], c["anchor"][2], c["anchor"][1], c["anchor"][0],
                                         c["rot"]))
    out: list[dict] = []
    for c in cands:
        if all(not sites._overlap(c["box"], o["box"]) for o in out):
            out.append(c)
            if len(out) == n:
                break
    return [{"id": f"S{i + 1}", "anchor": c["anchor"], "rot": c["rot"], "score": c["score"], "why": c["why"],
             "depth": c["depth"]} for i, c in enumerate(out)]


def pick(snap: dict, manifest: dict, floors) -> dict:
    """The plan's deep site: the best candidate on a known dry level -> {anchor, rot, depth, z, why}; {why} when none."""
    cands, why = candidates(snap, manifest, floors=floors)
    if not cands:
        return {"why": why}
    c = _top(cands, 1)[0]
    return {"anchor": c["anchor"], "rot": c["rot"], "depth": c["depth"], "z": c["anchor"][2] - c["depth"], "why": c["why"]}
