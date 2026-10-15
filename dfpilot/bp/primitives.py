"""Geometry primitives for blueprint templates (WP3).

Templates describe a building in *local* coordinates (u, v, w): u grows east, v grows south (like DF y),
w is the z offset from the anchor (0 = anchor level, negative = deeper). `Xform` maps local to absolute
map coordinates for an anchor and a rotation (0-3 quarter turns clockwise). A `Plan` is the template output
before emission: ordered stages of tile items and rect entities plus a manifest fragment in local coords.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

DIRS = "NESW"
# quickfort bridge keys by raise direction (hack/scripts/internal/quickfort/build.lua:480-483)
BRIDGE_KEYS = {"N": "gw", "E": "gd", "S": "gx", "W": "ga"}
BRIDGE_DIR = {v: k for k, v in BRIDGE_KEYS.items()}
MODES = ("dig", "build", "place", "zone", "burrow")


def rot_uv(u: int, v: int, rot: int) -> tuple[int, int]:
    """Rotate a local offset clockwise by `rot` quarter turns (screen axes, y down): N -> E -> S -> W."""
    for _ in range(rot % 4):
        u, v = -v, u
    return u, v


def rot_dir(d: str, rot: int) -> str:
    return DIRS[(DIRS.index(d) + rot) % 4]


class Xform:
    """Local (u, v, w) -> absolute (x, y, z) for one anchor and rotation."""

    def __init__(self, anchor, rot: int = 0):
        self.ax, self.ay, self.az = (int(c) for c in anchor)
        self.rot = int(rot) % 4

    def pos(self, u: int, v: int, w: int = 0) -> tuple[int, int, int]:
        du, dv = rot_uv(u, v, self.rot)
        return self.ax + du, self.ay + dv, self.az + w

    def rect(self, u0: int, v0: int, u1: int, v1: int) -> tuple[int, int, int, int]:
        """Absolute (x0, y0, x1, y1), normalized, for a local rect (same w)."""
        xa, ya, _ = self.pos(u0, v0)
        xb, yb, _ = self.pos(u1, v1)
        return min(xa, xb), min(ya, yb), max(xa, xb), max(ya, yb)

    def bbox(self, b) -> list[int]:
        u0, v0, w0, u1, v1, w1 = b
        x0, y0, x1, y1 = self.rect(u0, v0, u1, v1)
        return [x0, y0, self.az + min(w0, w1), x1, y1, self.az + max(w0, w1)]

    def dir(self, d: str) -> str:
        return rot_dir(d, self.rot)


@dataclass
class Item:
    """One blueprint element. `ent=False`: every tile of the rect gets `key` (dig strips, 1x1 furniture,
    walls, traps). `ent=True`: one quickfort cell with an explicit (WxH) extent (zones, stockpiles, burrows,
    bridges, workshops, depot, farm plots); explicit extents keep adjacent entities separate
    (quickfort-user-guide.txt:323, building.lua:67)."""
    u0: int
    v0: int
    u1: int
    v1: int
    w: int
    key: str
    props: str = ""
    ent: bool = False
    dir: str = ""          # bridges: local raise direction N/E/S/W

    def tiles(self) -> Iterator[tuple[int, int, int]]:
        for v in range(min(self.v0, self.v1), max(self.v0, self.v1) + 1):
            for u in range(min(self.u0, self.u1), max(self.u0, self.u1) + 1):
                yield u, v, self.w


@dataclass
class Stage:
    label: str
    mode: str
    orders: int = 0
    defense: int = 0
    items: list[Item] = field(default_factory=list)

    def add(self, u0, v0, u1, v1, w, key, props="", ent=False, dir=""):
        self.items.append(Item(u0, v0, u1, v1, w, key, props, ent, dir))
        return self

    def tile(self, u, v, w, key, props=""):
        return self.add(u, v, u, v, w, key, props)

    def rect(self, u0, v0, u1, v1, w, key="d"):
        return self.add(u0, v0, u1, v1, w, key)

    def ent(self, u0, v0, u1, v1, w, key, props="", dir=""):
        return self.add(u0, v0, u1, v1, w, key, props, True, dir)

    def stair(self, u, v, w_bottom, w_top):
        """Stair column: up stair at the bottom, up/down between, down stair at the top (quickfort u/i/j)."""
        for w in range(w_bottom, w_top + 1):
            self.tile(u, v, w, "u" if w == w_bottom else "j" if w == w_top else "i")
        return self

    def path(self, pts, w, key="d"):
        """Dig a 1-wide orthogonal polyline through the waypoints (inclusive)."""
        for (ua, va), (ub, vb) in zip(pts, pts[1:]):
            if ua != ub and va != vb:
                raise ValueError(f"path segment {ua},{va}->{ub},{vb} is not orthogonal")
            self.rect(ua, va, ub, vb, w, key)
        return self


class Plan:
    """Template output in local coordinates."""

    def __init__(self, tpl: str, klass: str):
        self.tpl, self.klass = tpl, klass
        self.stages: list[Stage] = []
        self.manifest: dict = {"v": 2}
        self.rooms: list[dict] = []          # {sfx, tpl, use, bbox(local), tier}
        self.workshops: list[tuple[str, tuple[int, int, int]]] = []

    def stage(self, label: str, mode: str, orders: int = 0, defense: int = 0) -> Stage:
        for s in self.stages:
            if s.label == label:
                return s
        if mode not in MODES:
            raise ValueError(f"bad mode {mode!r}")
        s = Stage(label, mode, orders, defense)
        self.stages.append(s)
        return s

    def room(self, sfx: str, tpl: str, use: str, bbox, tier: int = 0):
        self.rooms.append({"sfx": sfx, "tpl": tpl, "use": use, "bbox": list(bbox), "tier": int(tier)})

    def dug(self) -> dict[int, set[tuple[int, int]]]:
        """Local tiles that will be excavated, per w (dig keys d/h/u/j/i/r)."""
        out: dict[int, set[tuple[int, int]]] = {}
        for s in self.stages:
            if s.mode != "dig":
                continue
            for it in s.items:
                if it.key in DIG_EXCAVATE:
                    for u, v, w in it.tiles():
                        out.setdefault(w, set()).add((u, v))
        return out


DIG_EXCAVATE = frozenset("dhujir")


def merge_manifest(base: dict, frag: dict) -> dict:
    """CONTRACTS §11 merge rule: maps per key, id-arrays per id, workshops per pos, plain arrays appended
    without duplicates, scalars replaced. Returns a new dict."""
    out = {k: (dict(v) if isinstance(v, dict) else list(v) if isinstance(v, list) else v) for k, v in base.items()}
    for k, v in frag.items():
        if k in ("bridges", "stations", "burrows"):
            out[k] = {**out.get(k, {}), **v}
        elif k in ("killboxes", "rooms"):
            ids = {e["id"] for e in v}
            out[k] = [e for e in out.get(k, []) if e["id"] not in ids] + list(v)
        elif k == "workshops":
            ps = {tuple(e["pos"]) for e in v}
            out[k] = [e for e in out.get(k, []) if tuple(e["pos"]) not in ps] + list(v)
        elif k == "edge":
            out[k] = out.get(k, []) + [p for p in v if p not in out.get(k, [])]
        elif k in ("stairs", "zones"):
            cur = {kk: list(vv) for kk, vv in out.get(k, {}).items()}
            for kk, vv in v.items():
                cur[kk] = cur.get(kk, []) + [e for e in vv if e not in cur.get(kk, [])]
            out[k] = cur
        else:
            out[k] = v
    return out


def transform_manifest(m: dict, X: Xform) -> dict:
    """Map a local manifest fragment to absolute coordinates (rooms/workshops are added by emit)."""
    P = lambda p: list(X.pos(*p))  # noqa: E731
    out: dict = {"v": 2}
    for k, v in m.items():
        if k == "v":
            continue
        if k == "bridges":
            out[k] = {n: {"role": b["role"], "fp": X.bbox(b["fp"]), "levers": [P(p) for p in b["levers"]]}
                      for n, b in v.items()}
        elif k == "stations":
            out[k] = {n: P(p) for n, p in v.items()}
        elif k == "killboxes":
            out[k] = [{"id": e["id"], "bbox": X.bbox(e["bbox"])} for e in v]
        elif k == "edge":
            out[k] = [P(p) for p in v]
        elif k == "refuge":
            out[k] = {"anchor": P(v["anchor"]), "burrow": v["burrow"]}
        elif k == "stairs":
            out[k] = {n: [list(X.pos(s[0], s[1])[:2]) + [X.az + min(s[2], s[3]), X.az + max(s[2], s[3])]
                          for s in lst] for n, lst in v.items()}
        elif k == "zones":
            out[k] = {n: [X.bbox(b) for b in lst] for n, lst in v.items()}
        elif k in ("pit", "depot"):
            out[k] = P(v)
        else:
            out[k] = v
    return out


_KEY_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_~+-")


def parse_cell(text: str):
    """Split quickfort cell text `key{props}(WxH)` (ported from v1 planners/blueprint.py, simplified to the
    syntax we emit). Returns (key, props or None, (w, h) or None, error or None)."""
    i, n = 0, len(text)
    while i < n and text[i] not in "{(":
        i += 1
    key = text[:i]
    if not key or any(c not in _KEY_OK for c in key):
        return key, None, None, f"bad key {key!r}"
    props = ext = None
    while i < n:
        if text[i] == "{":
            j = text.find("}", i)
            if j < 0 or props is not None:
                return key, props, ext, "unbalanced or repeated {}"
            props, i = text[i + 1:j], j + 1
        elif text[i] == "(":
            j = text.find(")", i)
            if j < 0 or ext is not None:
                return key, props, ext, "unbalanced or repeated ()"
            a, x, b = text[i + 1:j].partition("x")
            try:
                ext = (int(a), int(b))
            except ValueError:
                return key, props, None, f"bad extent {text[i:j + 1]!r}"
            if x != "x" or ext[0] < 1 or ext[1] < 1:
                return key, props, None, f"bad extent {text[i:j + 1]!r}"
            i = j + 1
        else:
            return key, props, ext, f"unexpected {text[i]!r}"
    return key, props, ext, None


def props_dict(props: str | None) -> dict[str, str]:
    out = {}
    for tok in (props or "").split():
        k, _, v = tok.partition("=")
        out[k] = v
    return out
