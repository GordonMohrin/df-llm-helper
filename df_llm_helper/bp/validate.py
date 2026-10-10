"""Offline validators for bp documents (DESIGN §5.2 validator; replaces v1 planners/blueprint.py).

`check_doc(doc)`: schema, cell syntax and keys per mode, text length, chunk weight.
`check_world(docs)`: simulates the documents (render.as_built) and applies the doctrine rules on the
as-built snapshot: single stair, shortcut bridge, refuge on the attack path, doors as barriers, diagonal
leaks, unclosed rooms, plus trap hall / killing field / gallery / lever / burrow / refuge-well rules.
`validate(docs)` = both. Findings are (code, msg, level); level 'error' rejects.
"""
from __future__ import annotations

from dataclasses import dataclass

from .. import schema as S
from . import topo
from .emit import MAX_W
from .primitives import parse_cell
from .render import World, as_built, marks_of

DIG_KEYS = set("dhujirztpseFTvMnx") | {"bc", "bf", "bm", "bM", "bd", "bD", "bh", "bH",
                                                        "oh", "on", "ol", "or"}
BUILD_KEYS = set("a b c n d x H W G B f h r s t g l y Y D R N F I S m v j A p o O k".split()) | {
    "~b", "~s", "~h", "~a", "~c", "gs", "gw", "gd", "gx", "ga", "Tl", "Tw", "Ts", "Tp", "Tc", "TS",
    "Cw", "CW", "Cf", "Cr", "Cu", "Cd", "Cx", "CF", "we", "wq", "wM", "wo", "wk", "wb", "wc", "wf", "wv",
    "wj", "wm", "wu", "wn", "wr", "ws", "wt", "wl", "ww", "wz", "wh", "wy", "wd", "wS", "wp", "ew", "es",
    "el", "eg", "ea", "ek", "en"}
ZONE_KEYS = set("mbhnpwjfsoDBadtTgc")          # quickfort zone.lua / user guide #zone reference
PLACE_CHARS = set("afunyrswebhlzSgpdc")
BURROW_KEYS = {"a", "e"}
EXTENT_MODES = {"place", "zone", "burrow"}     # every cell must carry an explicit extent


@dataclass(frozen=True)
class Finding:
    code: str
    msg: str
    level: str = "error"

    def __str__(self) -> str:
        return f"{self.level} {self.code}: {self.msg}"


def errors(findings) -> list[Finding]:
    return [f for f in findings if f.level == "error"]


def _key_ok(mode: str, key: str) -> bool:
    if mode == "dig":
        k = key
        while k[:2] in ("mb", "mw", "md"):
            k = k[2:]
        k = k.rstrip("1234567")
        return k in DIG_KEYS or k.startswith("track")
    if mode == "build":
        return key in BUILD_KEYS or key.startswith("track")
    if mode == "zone":
        return key in ZONE_KEYS
    if mode == "place":
        return bool(key) and set(key.rstrip("0123456789")) <= PLACE_CHARS
    return key in BURROW_KEYS


def check_doc(doc: dict) -> list[Finding]:
    out = [Finding("schema", e) for e in S.validate("bp", {**doc, "id": doc.get("id", "check")})]
    if out:
        return out
    for st in doc["stages"]:
        for n, ch in enumerate(st["chunks"]):
            weight = 0
            for dx, dy, dz, text in ch["cells"]:
                key, props, ext, err = parse_cell(text)
                where = f"{st['label']} chunk {n} cell {dx},{dy},{dz} {text!r}"
                if err:
                    out.append(Finding("cell", f"{where}: {err}"))
                    continue
                if not _key_ok(st["mode"], key):
                    out.append(Finding("cell", f"{where}: key {key!r} not valid in #{st['mode']}"))
                if st["mode"] in EXTENT_MODES and ext is None:
                    out.append(Finding("cell", f"{where}: needs an explicit (WxH) extent"))
                if min(dx, dy, dz) < 0:
                    out.append(Finding("cell", f"{where}: negative offset"))
                w, h = ext or (1, 1)
                weight += w * h if st["mode"] in ("dig", "burrow") else 1
            if weight > MAX_W:
                out.append(Finding("chunk", f"{st['label']} chunk {n}: weight {weight} > {MAX_W}"))
    return out


# ---------------------------------------------------------------- world checks
def _flood(world: World, start, bbox, diag: bool) -> bool:
    """Horizontal flood from room tiles; doors stop it. True if it escapes the room bbox."""
    x0, y0, z, x1, y1, _ = bbox
    seen, stack = set(), [p for p in start]
    nb = topo.N8 if diag else ((1, 0), (-1, 0), (0, 1), (0, -1))
    while stack:
        x, y = stack.pop()
        if (x, y) in seen:
            continue
        seen.add((x, y))
        if not (x0 <= x <= x1 and y0 <= y <= y1):
            return True
        for dx, dy in nb:
            c = world.get(x + dx, y + dy, z)
            if c is not None and c != "+" and (c in topo.PASS or c == "_") and (x + dx, y + dy) not in seen:
                stack.append((x + dx, y + dy))
    return False


def _rooms(world: World, man: dict) -> list[Finding]:
    """Closure of every manifest room; a bedrooms block (one manifest room with an open corridor) is checked
    per bedroom zone instead."""
    boxes = [(r["id"], r["bbox"]) for r in man.get("rooms", []) if r["tpl"] != "bedrooms"]
    boxes += [(f"bedroom {x0},{y0},{z}", [x0, y0, z, x1, y1, z])
              for x0, y0, x1, y1, z in marks_of(world, "zone", "b")]
    out = []
    for rid, b in boxes:
        start = [(x, y) for y in range(b[1], b[4] + 1) for x in range(b[0], b[3] + 1)
                 if (world.get(x, y, b[2]) or "#") in topo.PASS]
        if not start:
            out.append(Finding("unclosed_room", f"room {rid}: no floor inside its bbox"))
        elif _flood(world, start, b, True):
            code = "unclosed_room" if _flood(world, start, b, False) else "diagonal_leak"
            out.append(Finding(code, f"room {rid} opens outside its walls other than through doors"))
    return out


def _bypass_kind(snap: dict, man: dict) -> list[Finding]:
    """Classify a worst-case bypass: diagonal leak, door used as barrier, shortcut bridge or plain bypass."""
    g = topo.Graph(snap)
    Z2 = g.mask(man.get("zones", {}).get("Z2", []))
    T = g.mask(man.get("zones", {}).get("Z3", []) + man.get("zones", {}).get("Z4", []))
    src = topo.sources(g, man)
    par: dict = {}
    _, hit = g.bfs(src, blocked=Z2, stop=T, parents=par)
    if hit is None:
        return []
    path = [g.pos(i) for i in g.path(par, hit)]
    fps = {n: b for n, b in man.get("bridges", {}).items()}
    on_br = {n for n, b in fps.items() for p in path
             if b["fp"][0] <= p[0] <= b["fp"][3] and b["fp"][1] <= p[1] <= b["fp"][4] and p[2] == b["fp"][2]}
    unlisted = any(g.t[g.idx(p)] in "=H" and not any(
        b["fp"][0] <= p[0] <= b["fp"][3] and b["fp"][1] <= p[1] <= b["fp"][4] and p[2] == b["fp"][2]
        for b in fps.values()) for p in path)
    end = "%d,%d,%d" % path[-1]
    if not _still(snap, man, diag=False):
        return [Finding("diagonal_leak", f"the trap hall is bypassed through a diagonal gap (to {end})")]
    if not _still(snap, man, closed="+"):
        return [Finding("door_barrier", f"only a door separates the attack path from {end}; doors are never "
                                        "barriers")]
    if unlisted or any(fps[n]["role"] != "outer" for n in on_br):
        return [Finding("shortcut_bridge", f"a bridge opens a path around the trap hall to {end}")]
    return [Finding("bypass", f"edge->Z3/Z4 path avoids the trap hall (to {end})")]


def _still(snap, man, diag=True, closed="") -> bool:
    g = topo.Graph(snap, diag=diag, closed=closed)
    Z2 = g.mask(man.get("zones", {}).get("Z2", []))
    T = g.mask(man.get("zones", {}).get("Z3", []) + man.get("zones", {}).get("Z4", []))
    return g.bfs(topo.sources(g, man), blocked=Z2, stop=T)[1] is not None


def _trap_hall(world: World, man: dict) -> list[Finding]:
    tiles = {(x, y, b[2]) for b in man.get("zones", {}).get("Z2", [])
             for y in range(b[1], b[4] + 1) for x in range(b[0], b[3] + 1)}
    if not tiles:
        return [Finding("trap_hall", "no Z2 trap hall in the manifest")]
    out = []
    if len(tiles) < 40:
        out.append(Finding("trap_hall", f"trap hall has {len(tiles)} tiles (< 40)"))
    bends = 0
    for x, y, z in tiles:
        nb = [(dx, dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)) if (x + dx, y + dy, z) in tiles]
        side = [(dx, dy) for dx, dy in topo.N8 if (x + dx, y + dy, z) not in tiles
                and (world.get(x + dx, y + dy, z) or "#") in topo.PASS]
        if len(nb) > 2:
            out.append(Finding("trap_hall", f"trap hall is wider than 1 at {x},{y},{z}"))
        if len(nb) == 2 and nb[0][0] != -nb[1][0]:
            bends += 1
        if side and len(nb) == 2:
            out.append(Finding("trap_hall", f"trap hall tile {x},{y},{z} opens to the side"))
    if bends < 3:
        out.append(Finding("trap_hall", f"trap hall has {bends} bends (< 3)"))
    return out


def check_world(docs, final: bool | None = None) -> list[Finding]:
    """Doctrine checks on the as-built result of `docs` (applied in order). `final` (default: the last
    document is fortcore stage 3) also requires O1, B2, refuge, Tiefe+ and the refuge well."""
    docs = [docs] if isinstance(docs, dict) else list(docs)
    world = as_built(docs)
    out = [Finding("build_tile", e) for e in world.errors]
    out += [Finding("farm_soil", w, "warning") for w in world.warnings]
    man, snap = world.manifest, world.snapshot()
    out += _rooms(world, man)
    if not any(d["tpl"] == "fortcore" for d in docs):
        return out
    last = docs[-1]
    final = final if final is not None else (last["tpl"] == "fortcore" and last["params"]["stage"] == 3)
    res = topo.audit(snap, man)
    if res["bypass"]:
        out += _bypass_kind(snap, man)
    for f in res["fails"]:
        if f.startswith("stairs"):
            out.append(Finding("single_stair", f))
        elif f.startswith("refuge: on"):
            out.append(Finding("refuge_on_attack_path", f))
        elif f.startswith(("refuge", "civ")):
            if final:
                out.append(Finding("refuge", f))
        elif f.startswith("levers") or f.startswith("bridge"):
            out.append(Finding("levers", f))
        elif f.startswith("no attack"):
            out.append(Finding("no_attack_path", f))
        elif f.startswith("cage trap"):
            out.append(Finding("cage_trap", f))
        elif f.startswith(("gallery", "caverns", "edge", "manifest")):
            out.append(Finding(f.split(":")[0], f))
    out += _trap_hall(world, man)
    br = man.get("bridges", {})
    if any(b["role"] == "inner" for b in br.values()):
        kb = man.get("killboxes", [])
        if not kb or any(k["bbox"][3] - k["bbox"][0] < 6 or k["bbox"][4] - k["bbox"][1] < 6 for k in kb):
            out.append(Finding("killing_field", "killing field must be at least 7x7"))
        if "gallery" not in man.get("stations", {}):
            out.append(Finding("gallery", "no gallery station"))
    if final:
        out += _final(world, man, br)
    return out


def _final(world: World, man: dict, br: dict) -> list[Finding]:
    out = []
    roles = {b["role"]: n for n, b in br.items()}
    for role in ("outer", "inner", "core"):
        if role not in roles:
            out.append(Finding("bridges", f"no {role} bridge"))
    if "outer" in roles:
        fp = br[roles["outer"]]["fp"]
        if max(fp[3] - fp[0], fp[4] - fp[1]) < 2:
            out.append(Finding("bridges", "O1 must be 3 wide"))
    burrows = {b["role"]: n for n, b in man.get("burrows", {}).items()}
    for role in ("kern", "refuge"):
        if role not in burrows or not list(marks_of(world, "burrow", "a", burrows[role])):
            out.append(Finding("burrows", f"no {role} burrow"))
    ref = man.get("refuge")
    z4 = [b for b in man.get("zones", {}).get("Z4", []) if b[0] != b[3] or b[1] != b[4]]
    if ref and z4:
        core_z = max(z4, key=lambda b: (b[3] - b[0] + 1) * (b[4] - b[1] + 1))[2]
        if ref["anchor"][2] > core_z - 3:
            out.append(Finding("refuge", f"refuge z{ref['anchor'][2]} is not >= 3 below the core z{core_z}"))
        tiefe = list(marks_of(world, "burrow", "a", ref["burrow"]))
        wells = [b for b in world.buildings if b[0] == "l"]
        if not any(x0 <= w[1] <= x1 and y0 <= w[2] <= y1 and w[5] == z for w in wells
                   for x0, y0, x1, y1, z in tiefe):
            out.append(Finding("refuge_well", "no well inside the refuge burrow"))
    return out


def validate(docs, final: bool | None = None) -> list[Finding]:
    docs = [docs] if isinstance(docs, dict) else list(docs)
    out = [f for d in docs for f in check_doc(d)]
    return out + check_world(docs, final)
