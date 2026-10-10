"""Emit blueprint project documents (CONTRACTS §9.8) from templates.

`emit(tpl, params, site)` returns a bp document without `id` (the caller sets it). Cells are quickfort text
for `apply_blueprint{mode, data[z][y][x]=text, pos}` (hack/docs/docs/tools/quickfort.txt:156-210).

Chunk rule (runner slice budget, DESIGN §4): every chunk has <= 40 cells and <= 40 work tiles, where a dig
or burrow cell weighs its footprint area (dig runs are compressed to `d(Nx1)`, N <= 40; burrow rects are
split into <= 40-tile pieces) and a build/place/zone cell weighs 1 (one building, stockpile or zone).
Within a stage the last item wins per tile; key "" deletes a tile.
"""
from __future__ import annotations

import re

from . import fortcore, rooms
from .primitives import BRIDGE_KEYS, Plan, Xform, transform_manifest

MAX_W = 40
# name -> (build(params) -> Plan, {param: (default, lo, hi)}, one-line description)
TEMPLATES = {"fortcore": (fortcore.build, fortcore.PARAMS, "doctrine fortress core, stages 1-3 (DESIGN §5.2)"),
             **{n: (f, {**rooms.PARAMS[n], **rooms.COMMON}, (f.__doc__ or n).strip().split("\n")[0])
                for n, f in rooms.BUILD.items()}}
_BURROW_RE = r"^[A-Za-z0-9_+-]{0,20}$"

# build keys -> materials list names (quickfort build.lua:760-1000)
MATERIAL = {"b": "bed", "f": "cabinet", "h": "chest", "t": "table", "c": "chair", "n": "coffin", "d": "door",
            "Tl": "lever", "Tw": "weapon_trap", "Ts": "stonefall_trap", "Tc": "cage_trap", "R": "traction_bench",
            "l": "well", "r": "weapon_rack", "a": "armor_stand", "~a": "offering_place", "D": "trade_depot",
            "Cw": "wall", "CF": "fortification", "p": "farm_plot", "g": "drawbridge"}


def list_templates() -> list[dict]:
    return [{"tpl": n, "params": {k: v[0] for k, v in spec.items()}, "about": about}
            for n, (_, spec, about) in sorted(TEMPLATES.items())]


def check_params(tpl: str, params: dict | None) -> dict:
    """Fill defaults and validate types/ranges; raises ValueError with a readable message."""
    if tpl not in TEMPLATES:
        raise ValueError(f"unknown template {tpl!r}; known: {sorted(TEMPLATES)}")
    spec = TEMPLATES[tpl][1]
    params = dict(params or {})
    unknown = sorted(set(params) - set(spec))
    if unknown:
        raise ValueError(f"{tpl}: unknown params {unknown}; known: {sorted(spec)}")
    out = {}
    for k, (default, lo, hi) in spec.items():
        v = params.get(k, default)
        if isinstance(default, bool):
            if not isinstance(v, bool):
                raise ValueError(f"{tpl}.{k}: expected true/false, got {v!r}")
        elif isinstance(default, int):
            if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
                raise ValueError(f"{tpl}.{k}: expected an integer {lo}..{hi}, got {v!r}")
        elif not isinstance(v, str) or len(v) > 200:
            raise ValueError(f"{tpl}.{k}: expected a string, got {v!r}")
        out[k] = v
    if "burrow" in out:
        if not re.fullmatch(_BURROW_RE, out["burrow"]):
            raise ValueError(f"{tpl}.burrow: bad burrow name {out['burrow']!r}")
    return out


def parse_site(site) -> tuple[list[int], int, str]:
    """site = {'id': 'S1', 'anchor': [x,y,z], 'rot': 0..3} (a sites.rank entry) or (anchor, rot[, id])."""
    if isinstance(site, dict):
        anchor, rot, sid = site.get("anchor"), site.get("rot", 0), site.get("id", "S1")
    elif isinstance(site, (list, tuple)) and len(site) in (2, 3) and isinstance(site[0], (list, tuple)):
        anchor, rot, sid = site[0], site[1], site[2] if len(site) == 3 else "S1"
    else:
        raise ValueError(f"bad site {site!r}: want {{'id', 'anchor':[x,y,z], 'rot'}}")
    if not (isinstance(anchor, (list, tuple)) and len(anchor) == 3 and all(isinstance(c, int) for c in anchor)):
        raise ValueError(f"bad site anchor {anchor!r}")
    if rot not in (0, 1, 2, 3):
        raise ValueError(f"bad site rot {rot!r}")
    return [int(c) for c in anchor], int(rot), str(sid)


def emit(tpl: str, params: dict | None = None, site=None) -> dict:
    p = check_params(tpl, params)
    anchor, rot, sid = parse_site(site if site is not None else ([0, 0, 0], 0))
    if any(c < 0 for c in anchor):
        raise ValueError(f"anchor {anchor} outside the map")
    plan: Plan = TEMPLATES[tpl][0](p)
    X = Xform(anchor, rot)
    stages = [s for s in (_stage(st, X) for st in plan.stages) if s["chunks"]]
    lo = min_corner(stages)
    if min(lo) < 0:
        raise ValueError(f"{tpl}: site {anchor} rot {rot} puts tiles outside the map (min x,y,z = {lo})")
    man = transform_manifest(plan.manifest, X)
    if tpl in rooms.BUILD:              # the room joins the civilian core: later rooms may open from it
        man.setdefault("zones", {}).setdefault("Z4", []).append(X.bbox(dug_bbox(plan)))
    prefix = f"{tpl[:8]}{anchor[0]}_{anchor[1]}_{anchor[2]}r{rot}"      # two rooms may share an anchor
    if plan.rooms:
        man["rooms"] = [{"id": prefix + (f"_{r['sfx']}" if r["sfx"] else ""), "tpl": r["tpl"], "use": r["use"],
                         "bbox": X.bbox(r["bbox"]), "tier": r["tier"]} for r in plan.rooms]
    if plan.workshops:
        man["workshops"] = [{"type": n, "pos": list(X.pos(*q))} for n, q in plan.workshops]
    return {"v": 2, "tpl": tpl, "site": sid, "class": plan.klass, "params": p, "anchor": anchor, "rot": rot,
            "stages": stages, "manifest": man, "materials": materials(stages)}


def dug_bbox(plan: Plan) -> tuple[int, int, int, int, int, int]:
    """Local (u0, v0, w0, u1, v1, w1) around every tile the plan excavates."""
    pts = [(u, v, w) for w, tiles in plan.dug().items() for u, v in tiles]
    return (min(p[0] for p in pts), min(p[1] for p in pts), min(p[2] for p in pts),
            max(p[0] for p in pts), max(p[1] for p in pts), max(p[2] for p in pts))


def emit_all(tpl: str, params: dict | None = None, site=None) -> list[dict]:
    """fortcore: the stage projects 1..params.stage (default all 3) in order, same site; else [emit(...)]."""
    if tpl != "fortcore":
        return [emit(tpl, params, site)]
    last = (params or {}).get("stage", 3)
    return [emit(tpl, {**(params or {}), "stage": s}, site) for s in range(1, int(last) + 1)]


def _stage(st, X: Xform) -> dict:
    tiles: dict[tuple[int, int, int], str] = {}
    cells: list[tuple[int, int, int, str, int]] = []      # x, y, z, text, weight
    for it in st.items:
        if not it.ent:
            for u, v, w in it.tiles():
                tiles[X.pos(u, v, w)] = it.key
            continue
        x0, y0, x1, y1 = X.rect(it.u0, it.v0, it.u1, it.v1)
        z = X.az + it.w
        key = BRIDGE_KEYS[X.dir(it.dir)] if it.key == "g" else it.key
        props = "{" + it.props + "}" if it.props else ""
        if st.mode == "burrow":
            for (a, b, c, d) in _split(x0, y0, x1, y1):
                cells.append((a, b, z, f"{key}{props}({c - a + 1}x{d - b + 1})", (c - a + 1) * (d - b + 1)))
        else:
            cells.append((x0, y0, z, f"{key}{props}({x1 - x0 + 1}x{y1 - y0 + 1})", 1))
    tiles = {k: v for k, v in tiles.items() if v}
    if st.mode == "dig":
        cells += _runs(tiles)
    else:
        cells += [(x, y, z, k, 1) for (x, y, z), k in tiles.items()]
    return {"label": st.label, "mode": st.mode, "orders": st.orders, "defense": st.defense,
            "chunks": _chunks(cells)}


def min_corner(stages: list[dict]) -> list[int]:
    """Smallest x, y, z any cell touches; a channel (`h`) also opens the tile below it."""
    lo = [1 << 30] * 3
    for st in stages:
        for ch in st["chunks"]:
            for dx, dy, dz, text in ch["cells"]:
                below = st["mode"] == "dig" and cell_key(text) == "h"
                p = (ch["pos"][0] + dx, ch["pos"][1] + dy, ch["pos"][2] + dz - below)
                lo = [min(a, b) for a, b in zip(lo, p)]
    return lo


def _split(x0, y0, x1, y1):
    """Split a rect into pieces of <= MAX_W tiles (full-width strips, or row pieces if wider than MAX_W)."""
    w = x1 - x0 + 1
    if w > MAX_W:
        return [(a, y, min(a + MAX_W - 1, x1), y) for y in range(y0, y1 + 1) for a in range(x0, x1 + 1, MAX_W)]
    rows = max(1, MAX_W // w)
    return [(x0, y, x1, min(y + rows - 1, y1)) for y in range(y0, y1 + 1, rows)]


def _runs(tiles):
    out = []
    for (x, y, z), k in sorted(tiles.items(), key=lambda t: (t[0][2], t[0][1], t[0][0])):
        if out and out[-1][3][0] == k and out[-1][2] == z and out[-1][1] == y and \
                out[-1][0] + out[-1][4] == x and out[-1][4] < MAX_W:
            out[-1][4] += 1
            continue
        out.append([x, y, z, (k,), 1])
    return [(x, y, z, k[0] if n == 1 else f"{k[0]}({n}x1)", n) for x, y, z, k, n in out]


def _chunks(cells):
    cells = sorted(cells, key=lambda c: (c[2], c[1], c[0], c[3]))
    groups, cur, wsum = [], [], 0
    for c in cells:
        if cur and (len(cur) == MAX_W or wsum + c[4] > MAX_W):
            groups.append(cur)
            cur, wsum = [], 0
        cur.append(c)
        wsum += c[4]
    if cur:
        groups.append(cur)
    out = []
    for g in groups:
        px, py, pz = min(c[0] for c in g), min(c[1] for c in g), min(c[2] for c in g)
        out.append({"pos": [px, py, pz], "cells": [[c[0] - px, c[1] - py, c[2] - pz, c[3]] for c in g]})
    return out


def cell_key(text: str) -> str:
    """Leading key of a cell text: up to '{', '(', ':' or '/'."""
    for i, ch in enumerate(text):
        if ch in "{(:/":
            return text[:i]
    return text


def materials(stages: list[dict]) -> dict:
    out: dict[str, int] = {}
    for st in stages:
        if st["mode"] != "build":
            continue
        for ch in st["chunks"]:
            for *_, text in ch["cells"]:
                k = cell_key(text)
                name = "drawbridge" if k in BRIDGE_KEYS.values() else MATERIAL.get(k)
                if name is None and len(k) == 2 and k[0] in "we":
                    name = "workshop"
                if name:
                    out[name] = out.get(name, 0) + 1
    mech = out.get("lever", 0) * 3 + out.get("weapon_trap", 0) + out.get("stonefall_trap", 0) \
        + out.get("cage_trap", 0)
    if mech:
        out["mechanism"] = mech     # 1 per trap/lever + 2 per lever->bridge link (linking is a UI job)
    return dict(sorted(out.items()))
