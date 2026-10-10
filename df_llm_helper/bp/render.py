"""As-built simulation of bp documents, snapshot export (CONTRACTS §9.10 legend) and ASCII previews.

`as_built(docs)` applies the stages of one or more bp documents, in order, to a synthetic base terrain
(rock below the surface, the surface floor at the anchor z of a fortcore, open air above; room templates get
an all-rock base with the access tile open). It approximates DF: `d` mines a wall to floor, `h` removes the
floor (ramp below if the tile below is a wall, the channelled tile becomes the ramp top), `u/j/i` carve
stairs, `s` smooths walls, constructions and furniture need floor (quickfort build.lua:49-60, :151).
Bridges are simulated lowered (`=`). The validators and tests audit this snapshot.
"""
from __future__ import annotations

from .primitives import BRIDGE_DIR, merge_manifest, parse_cell, props_dict

FLOORISH = set(".")
WALLISH = set("#?S")
TRAP = {"Tw": "W", "Ts": "S", "Tc": "C", "Tp": "P"}
STAIR = {"u": "<", "j": ">", "i": "X"}
DIGX = frozenset("dhujir")
CONSTRUCT = {"Cw": "C", "CW": "C", "CF": "F", "Cf": ".", "Cu": "<", "Cd": ">", "Cx": "X"}


def cell_rects(doc: dict):
    """Yield (stage, key, props, x0, y0, x1, y1, z) for every cell of a bp document."""
    for st in doc["stages"]:
        for ch in st["chunks"]:
            px, py, pz = ch["pos"]
            for dx, dy, dz, text in ch["cells"]:
                key, props, ext, _ = parse_cell(text)
                w, h = ext or (1, 1)
                x, y = px + dx, py + dy
                yield st, key, props, x, y, x + w - 1, y + h - 1, pz + dz


def docs_bbox(docs, pad: int = 2) -> list[int]:
    xs, ys, zs = [], [], []
    for d in docs:
        xs.append(d["anchor"][0]); ys.append(d["anchor"][1]); zs.append(d["anchor"][2])
        for _, _, _, x0, y0, x1, y1, z in cell_rects(d):
            xs += [x0, x1]; ys += [y0, y1]; zs.append(z)
    return [min(xs) - pad, min(ys) - pad, min(zs) - 2, max(xs) + pad, max(ys) + pad, max(zs) + 1]


class World:
    def __init__(self, bbox, surface: int | None = None, fill: str = "#"):
        self.bbox = [int(c) for c in bbox]
        x0, y0, z0, x1, y1, z1 = self.bbox
        self.W, self.H, self.D = x1 - x0 + 1, y1 - y0 + 1, z1 - z0 + 1
        self.t = bytearray(fill.encode() * (self.W * self.H * self.D))
        if surface is not None:
            for z in range(z0, z1 + 1):
                c = "_" if z > surface else "." if z == surface else None
                if c:
                    i = self._i(x0, y0, z)
                    self.t[i:i + self.W * self.H] = c.encode() * (self.W * self.H)
        self.traps: list[list] = []
        self.buildings: list[tuple] = []        # (key, x0, y0, x1, y1, z)
        self.marks: list[tuple] = []            # (mode, key, props, x0, y0, x1, y1, z) zones/stockpiles/burrows
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.occupied: set[tuple[int, int, int]] = set()
        self.manifest: dict = {"v": 2}
        self.soil: set[tuple[int, int, int]] = set()     # snapshot marks.soil (farm plots need soil or mud)

    @classmethod
    def from_snapshot(cls, snap: dict) -> "World":
        w = cls(snap["bbox"])
        x0, y0, z0 = snap["bbox"][:3]
        for z in range(z0, snap["bbox"][5] + 1):
            for j, row in enumerate(snap["rows"][f"z{z}"]):
                i = w._i(x0, y0 + j, z)
                w.t[i:i + w.W] = row.encode()
        w.traps = [list(t) for t in snap.get("traps", [])]
        w.soil = {tuple(p) for p in snap.get("marks", {}).get("soil", [])}
        return w

    def _i(self, x, y, z):
        x0, y0, z0 = self.bbox[:3]
        return ((z - z0) * self.H + (y - y0)) * self.W + (x - x0)

    def inside(self, x, y, z) -> bool:
        b = self.bbox
        return b[0] <= x <= b[3] and b[1] <= y <= b[4] and b[2] <= z <= b[5]

    def get(self, x, y, z) -> str | None:
        return chr(self.t[self._i(x, y, z)]) if self.inside(x, y, z) else None

    def set(self, x, y, z, c: str) -> None:
        if self.inside(x, y, z):
            self.t[self._i(x, y, z)] = ord(c)

    # ------------------------------------------------------------ apply
    def apply(self, doc: dict) -> "World":
        for st, key, props, x0, y0, x1, y1, z in cell_rects(doc):
            mode = st["mode"]
            if mode == "dig":
                for y in range(y0, y1 + 1):
                    for x in range(x0, x1 + 1):
                        self._dig(key, x, y, z)
            elif mode == "build":
                self._build(key, props, x0, y0, x1, y1, z)
            else:
                self.marks.append((mode, key, props, x0, y0, x1, y1, z))
        self.manifest = merge_manifest(self.manifest, doc["manifest"])
        return self

    def _reveal(self, x, y, z):
        """Digging reveals the 26 neighbours (hidden rock becomes known rock)."""
        for dz in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if self.get(x + dx, y + dy, z + dz) == "?":
                        self.set(x + dx, y + dy, z + dz, "#")

    def _dig(self, key, x, y, z):
        c = self.get(x, y, z)
        if c is None:
            self.errors.append(f"dig {key} at {x},{y},{z} outside the world")
            return
        if key in DIGX:
            self._reveal(x, y, z)
            c = "#" if c == "?" else c
        if key == "d":
            if c in WALLISH:
                self.set(x, y, z, ".")
        elif key == "h":
            below = self.get(x, y, z - 1)
            if below in WALLISH:
                self.set(x, y, z - 1, "r")
                self.set(x, y, z, "v")
            else:
                self.set(x, y, z, "_")
        elif key in STAIR:
            if c in WALLISH or c == ".":
                self.set(x, y, z, STAIR[key])
        elif key == "s":
            if c == "#":
                self.set(x, y, z, "S")
        elif key == "F":
            if c in WALLISH:
                self.set(x, y, z, "F")

    def _build(self, key, props, x0, y0, x1, y1, z):
        tiles = [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
        for x, y in tiles:
            c = self.get(x, y, z)
            if key == "l":                                   # well: open tile next to floor (build.lua:194)
                ok = c in "_v"
            elif key in BRIDGE_DIR or key in CONSTRUCT:     # bridges/constructions: floor or open space
                ok = c in FLOORISH or c in "_v"
            else:
                ok = c in FLOORISH
            if not ok:
                self.errors.append(f"build {key} at {x},{y},{z} on {c!r}")
            if (x, y, z) in self.occupied and key not in CONSTRUCT:  # one building per tile (build.lua:46)
                self.errors.append(f"build {key} at {x},{y},{z}: tile already has a building")
            self.occupied.add((x, y, z))
        if key == "p":          # quickfort drops non-soil plot tiles as build_unsuitable (build.lua:102, :1340)
            bare = sum((x, y, z) not in self.soil for x, y in tiles)
            if bare:
                self.warnings.append(f"farm plot at {x0},{y0},{z}: {bare} of {len(tiles)} tiles not known as soil")
        self.buildings.append((key, x0, y0, x1, y1, z))
        for x, y in tiles:
            if key in CONSTRUCT:
                self.set(x, y, z, CONSTRUCT[key])
            elif key in ("d", "H"):
                self.set(x, y, z, "+")
            elif key in TRAP:
                self.set(x, y, z, "^")
                self.traps.append([x, y, z, TRAP[key], 1 if key == "Tw" else 0, 1])
            elif key in BRIDGE_DIR:
                self.set(x, y, z, "=")
            elif key == "s":
                self.set(x, y, z, "B")             # statues block movement

    # ------------------------------------------------------------ export
    def raise_bridges(self, names=None) -> "World":
        for n, b in self.manifest.get("bridges", {}).items():
            if names is None or n in names:
                x0, y0, z, x1, y1, _ = b["fp"]
                for y in range(y0, y1 + 1):
                    for x in range(x0, x1 + 1):
                        if self.get(x, y, z) == "=":
                            self.set(x, y, z, "H")
        return self

    def snapshot(self, sid: str = "sim", purpose: str = "audit", tick: int = 0) -> dict:
        x0, y0, z0, x1, y1, z1 = self.bbox
        rows = {}
        for z in range(z0, z1 + 1):
            base = self._i(x0, y0, z)
            rows[f"z{z}"] = [self.t[base + j * self.W: base + (j + 1) * self.W].decode() for j in range(self.H)]
        bridges = {}
        for n, b in self.manifest.get("bridges", {}).items():
            c = self.get(b["fp"][0], b["fp"][1], b["fp"][2])
            bridges[n] = "up" if c == "H" else "down" if c == "=" else "unknown"
        out = {"v": 2, "id": sid, "tick": tick, "purpose": purpose, "bbox": list(self.bbox), "rows": rows,
               "bridges": bridges, "traps": [list(t) for t in self.traps]}
        if self.soil:
            out["marks"] = {"soil": [list(p) for p in sorted(self.soil)[:500]]}
        return out


def as_built(docs, base=None, pad: int = 2) -> World:
    """Simulate `docs` (one bp document or a list, applied in order) on a base World or snapshot."""
    docs = [docs] if isinstance(docs, dict) else list(docs)
    if isinstance(base, World):
        w = base
    elif isinstance(base, dict):
        w = World.from_snapshot(base)
    else:
        a = docs[0]["anchor"]
        fort = docs[0]["tpl"] == "fortcore"
        w = World(docs_bbox(docs, pad), surface=a[2] if fort else None)
        if not fort:
            w.set(*a, ".")
    for d in docs:
        w.apply(d)
    return w


# preview-only overlay of buildings (snapshots keep the pure §9.10 legend)
OVERLAY = {"b": "b", "f": "f", "h": "h", "t": "t", "c": "c", "n": "n", "l": "l", "r": "k", "a": "a",
           "Tl": "L", "R": "R", "~a": "A", "D": "D", "p": "p"}
OVERLAY_LEGEND = ("overlay: b bed  f cabinet  h chest  t table  c chair  n coffin  l well  k weapon rack  "
                  "a armor stand  L lever  R traction bench  A altar  D depot  p farm plot  W workshop")


def overlay(world: World, snap: dict) -> dict:
    """Copy of `snap` with furniture and workshops drawn in (for previews only)."""
    x0, y0 = snap["bbox"][:2]
    rows = {k: [list(r) for r in v] for k, v in snap["rows"].items()}
    for key, bx0, by0, bx1, by1, z in world.buildings:
        ch = OVERLAY.get(key) or ("W" if len(key) == 2 and key[0] in "we" else None)
        if ch is None or f"z{z}" not in rows:
            continue
        for y in range(by0, by1 + 1):
            for x in range(bx0, bx1 + 1):
                if world.inside(x, y, z):
                    rows[f"z{z}"][y - y0][x - x0] = ch
    return {**snap, "rows": {k: ["".join(r) for r in v] for k, v in rows.items()}}


def ascii(snap: dict, zs=None, legend: bool = True) -> str:
    """Text rendering, top level first; `zs` limits the levels."""
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    out = []
    for z in range(z1, z0 - 1, -1):
        if zs is not None and z not in zs:
            continue
        rows = snap["rows"][f"z{z}"]
        if zs is None and (all(set(r) <= set("#?") for r in rows) or all(set(r) <= {"_"} for r in rows)):
            continue                                  # solid rock or open sky only
        out.append(f"z{z}  (x {x0}..{x1}, y {y0}..{y1})")
        out += rows
    if legend:
        out.append("legend: # rock  S smoothed  C wall  F fortification  . floor  _ open  < > X stairs  "
                   "r/v ramp  + door  = bridge  H raised  ^ trap  ? hidden")
    return "\n".join(out)


def preview(tpl: str, params=None, site=None) -> str:
    """`dfllm bp preview`: as-built ASCII per level plus stages and materials (no DF calls)."""
    from .emit import emit_all, min_corner, parse_site
    anchor, rot, sid = parse_site(site if site is not None else ([0, 0, 0], 0))
    far = 1000                                    # probe far from the map edge, then shift into the map
    lo = min_corner([s for d in emit_all(tpl, params, ([far] * 3, rot)) for s in d["stages"]])
    shifted = [max(a, far - m) for a, m in zip(anchor, lo)]
    docs = emit_all(tpl, params, {"id": sid, "anchor": shifted, "rot": rot})
    w = as_built(docs, pad=1)
    lines = [f"{tpl} {docs[-1]['params']} anchor {docs[0]['anchor']} rot {docs[0]['rot']}"
             + ("" if shifted == anchor else f" (shifted from {anchor} to fit the map)")]
    for d in docs:
        st = ", ".join(f"{s['label']}({sum(len(c['cells']) for c in s['chunks'])})" for s in d["stages"])
        lines.append(f"  {d['class']}: {st}")
        lines.append(f"  materials: {d['materials']}")
    if w.errors:
        lines.append(f"  simulation errors: {w.errors[:5]}")
    lines.append(ascii(overlay(w, w.snapshot(purpose="debug"))))
    lines.append(OVERLAY_LEGEND)
    return "\n".join(lines)


def marks_of(world: World, mode: str, key: str | None = None, name: str | None = None):
    """Recorded zone/stockpile/burrow rects of `mode` (optionally key and props name)."""
    for m, k, props, x0, y0, x1, y1, z in world.marks:
        if m == mode and (key is None or k == key) and (name is None or props_dict(props).get("name") == name):
            yield x0, y0, x1, y1, z
