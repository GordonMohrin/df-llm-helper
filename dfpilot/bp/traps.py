"""FR-96 (goal G14 "everything secured with traps"): trap lanes at the ways in, and the trap hall re-armed.

Before, the only traps were fortcore stage 4's 41 stone-fall traps in the Z2 hall (P6); every side way in (a seal door,
a door the player built in the perimeter) had none, and a trap of the hall that was destroyed was never put back.

Template `traps` (absolute tiles like `seal`; the CLI fills them in, dfpilot/traps.py):
  at = 'ways' (default '' too): one lane in front of every door that separates the outside from the fort (doors,
       hatches and bridges closed, as in a lockdown): every walkable floor tile of the outside among the door's 8
       neighbours on its level (an attacker must step on one of them to reach the door) plus, with depth 2-3, the tiles
       straight out from the door; a way whose tiles are all trapped (or planned by a traps project under way) is left
       out;
     'hall': the tiles of a finished fortcore stage 4 that show no trap on the newest snapshot (stone-fall, restock);
     resolved: 'x,y,z:dx,dy dx,dy;...' (a way and the offsets of its lane tiles on its level) and
       'hall:x,y,z x,y,z' (absolute hall tiles).
  kind = cage (default, ways) | stone; the hall is stone only (DOCTRINE: no cage traps on the main path, the comrades free
       the caged; topo.audit fails `cage trap on the main path`).
  depth = 1..3 (tiles straight out from the door).
Safety (citizens): the lanes lie OUTSIDE a door the arrival lockdown forbids (reflex door_forbid), never on the door, on a
stair, ramp or bridge, in the fort's own geometry (the manifest zones Z1-Z4 with the bailey, depot and trap hall, rooms,
killboxes, stations, stairs, the refuge) or on a manifest edge tile; DF's traps do not fire on citizens or their animals,
and in a fight the closed door is the citizens' bypass. A way without a door (an open way in) gets no lane: `seal` closes
it first. The kernel's siege/lockdown logic is unchanged; lua/dfllm/traps.lua only reads and, in PEACE, orders cages.
Manifest: `traps` [{id 'T<x>_<y>_<z>' (the way), kind, way, tiles}] (merged per id); fortcore stage 4 writes id 'Z2'.
"""
from __future__ import annotations

from . import topo
from .primitives import Plan, rot_uv

KINDS = {"cage": "Tc", "stone": "Ts"}
HALL = "hall"
WAYS = ("", "ways")
TRAP_MAX = 16          # trap tiles per project (one build stage, one manager order per piece)
WAY_MAX = 6            # ways per project
OFF_MAX = 4            # a lane tile lies at most this far (Chebyshev) from its way
AT_MAX = 200           # bp.emit check_params: a string param holds at most 200 characters
PARAMS = {"traps": {"at": ("", None, None), "kind": ("cage", None, None), "depth": (1, 1, 3)}}
PASS_IN = frozenset(topo.PASS) - {"+"}
N8 = topo.N8


def way_id(pos) -> str:
    return "T%d_%d_%d" % tuple(pos)


def _xyz(text: str, what: str) -> list[int]:
    try:
        v = [int(c) for c in text.split(",")]
        if len(v) != 3:
            raise ValueError
    except ValueError:
        raise ValueError(f"traps.at: bad {what} {text!r} (want 'x,y,z:dx,dy dx,dy;...' or 'hall:x,y,z ...')") from None
    return v


def parse_at(text) -> list[dict]:
    """'x,y,z:dx,dy ...;hall:x,y,z ...' -> [{way: [x, y, z] | None (hall), tiles: [[x, y, z], ...]}]. Raises ValueError
    on a word the CLI resolves (ways, hall without tiles), bad syntax, more than WAY_MAX ways or TRAP_MAX tiles, a tile
    named twice, a lane tile on its way or farther than OFF_MAX from it."""
    out, seen, n = [], set(), 0
    for part in str(text or "").split(";"):
        part = part.strip()
        if not part:
            continue
        head, sep, rest = part.partition(":")
        if not sep or not rest.strip():
            raise ValueError(f"traps.at: {part!r} names no tiles (at=ways and at=hall are filled in by dfllm cmd and plan "
                             "apply from the newest snapshot)")
        if head.strip().lower() == HALL:
            tiles = [_xyz(t, "hall tile") for t in rest.split()]
            way = None
        else:
            way = _xyz(head.strip(), "way")
            tiles = []
            for t in rest.split():
                try:
                    dx, dy = (int(c) for c in t.split(","))
                except ValueError:
                    raise ValueError(f"traps.at: bad offset {t!r} of way {head.strip()} (want dx,dy)") from None
                if (dx, dy) == (0, 0) or max(abs(dx), abs(dy)) > OFF_MAX:
                    raise ValueError(f"traps.at: offset {t} of way {head.strip()}: not on the door, at most {OFF_MAX} away")
                tiles.append([way[0] + dx, way[1] + dy, way[2]])
        for t in tiles:
            if tuple(t) in seen:
                raise ValueError("traps.at: tile %d,%d,%d named twice" % tuple(t))
            seen.add(tuple(t))
        n += len(tiles)
        out.append({"way": way, "tiles": tiles})
    if sum(1 for p in out if p["way"]) > WAY_MAX:
        raise ValueError(f"traps.at: more than {WAY_MAX} ways; split them over several traps projects")
    if n > TRAP_MAX:
        raise ValueError(f"traps.at: {n} trap tiles > {TRAP_MAX}; split them over several traps projects")
    return out


def format_at(parts: list[dict]) -> str:
    """The inverse of parse_at; a way whose lane would pass AT_MAX characters, WAY_MAX ways or TRAP_MAX tiles is left
    out whole (a half lane is walked around; the next traps project takes it), a hall part is cut to what fits."""
    out, n, nw = [], 0, 0
    for p in parts:
        if p.get("way") is None:
            tiles = list(p["tiles"])[:max(0, TRAP_MAX - n)]
            while tiles and len(";".join(out + ["hall:" + " ".join("%d,%d,%d" % tuple(t) for t in tiles)])) > AT_MAX:
                tiles.pop()
            if not tiles:
                continue
            p = {"way": None, "tiles": tiles}
            txt = "hall:" + " ".join("%d,%d,%d" % tuple(t) for t in tiles)
        else:
            w = p["way"]
            txt = "%d,%d,%d:" % tuple(w) + " ".join("%d,%d" % (t[0] - w[0], t[1] - w[1]) for t in p["tiles"])
        nw2 = nw + (1 if p.get("way") is not None else 0)
        if len(";".join(out + [txt])) > AT_MAX or n + len(p["tiles"]) > TRAP_MAX or nw2 > WAY_MAX:
            continue
        out.append(txt)
        n, nw = n + len(p["tiles"]), nw2
    return ";".join(out)


def pieces(p: dict, anchor=None) -> list[dict]:
    """[{pos, key, way}] for the params (raises ValueError). at '' without CLI resolution (bp preview, an explicit
    site): one trap on the site's own tile."""
    kind = p.get("kind", "cage")
    if kind not in KINDS:
        raise ValueError(f"traps.kind: {kind!r} not one of {sorted(KINDS)}")
    at = str(p.get("at", "") or "")
    if at.strip().lower() in WAYS + (HALL,):
        if at.strip() == "" and anchor is not None:
            return [{"pos": list(anchor), "key": KINDS[kind], "way": None}]
        raise ValueError(f"traps.at={at or 'ways'}: filled in by dfllm cmd bp.place and plan apply from the newest "
                         "snapshot; name tiles here")
    out = []
    for part in parse_at(at):
        if part["way"] is None and kind == "cage":
            raise ValueError("traps: no cage traps in the trap hall (the main path: comrades free the caged, DOCTRINE); "
                             "kind=stone")
        for t in part["tiles"]:
            out.append({"pos": t, "key": KINDS[kind], "way": part["way"], "hall": part["way"] is None})
    if not out:
        raise ValueError("traps: no trap tile (at=ways|hall|x,y,z:dx,dy ...)")
    return out


def traps(p: dict, anchor, rot: int) -> Plan:
    """Trap lanes in front of the doors of the ways in (cage) or the trap hall re-armed (stone); absolute tiles from
    dfllm cmd (at=ways|hall), one build stage with its quickfort orders (mechanism, wooden cage)."""
    P = Plan("traps", "defense")
    ax, ay, az = anchor
    back = (4 - rot) % 4

    def local(t):
        u, v = rot_uv(t[0] - ax, t[1] - ay, back)       # emit rotates by rot: the piece lands on (x, y)
        return [u, v, t[2] - az]
    b = P.stage("traps.build", "build", orders=1, defense=1)
    ways: dict = {}
    for pc in pieces(p, anchor):
        u, v, w = local(pc["pos"])
        b.tile(u, v, w, pc["key"])
        if pc.get("hall"):
            continue                                      # the hall's manifest entry is fortcore stage 4's (id Z2)
        key = tuple(pc["way"]) if pc["way"] else ("site",)
        ways.setdefault(key, []).append(local(pc["pos"]))
    kind = p.get("kind", "cage")
    ents = []
    for key, tiles in ways.items():
        if key == ("site",):
            ents.append({"id": way_id(anchor), "kind": kind, "tiles": tiles})
        else:
            ents.append({"id": way_id(key), "kind": kind, "way": local(key), "tiles": tiles})
    if ents:
        P.manifest["traps"] = ents
    return P


def anchor_of(p: dict):
    """bp preview: the site is the first trap tile (None without explicit tiles)."""
    try:
        pcs = pieces(p)
    except ValueError:
        return None
    return pcs[0]["pos"] if pcs else None


def preview_tiles(p: dict) -> dict:
    """{(x, y, z): char}: floor under every trap, a door on every way (a preview base instead of rock)."""
    out = {}
    try:
        for part in parse_at(p.get("at", "")):
            for t in part["tiles"]:
                out[tuple(t)] = "."
            if part["way"]:
                out[tuple(part["way"])] = "+"
    except ValueError:
        pass
    return out


traps.sited = True
traps.anchor_of = anchor_of
traps.preview_tiles = preview_tiles
BUILD = {"traps": traps}
FREE = frozenset({"traps"})        # builds only on open floor tiles beside existing doors / in the dug hall


def site(snap: dict, p: dict, at) -> list[dict]:
    """sites.rank: the one site is the first trap tile; every tile must be revealed open floor on the snapshot (a tile
    outside it is taken as given). `at(x, y, z)` = snapshot char or None."""
    pcs = pieces(p)
    for pc in pcs:
        c = at(*pc["pos"])
        if c == "?":
            raise ValueError("traps: %d,%d,%d is not revealed (look at it in the game, then dfllm bp sites traps --fresh)"
                             % tuple(pc["pos"]))
        if c is not None and c not in ". ":              # ' ': a union export did not read it (taken as given)
            raise ValueError("traps: %d,%d,%d shows %r, not open floor (a trap stands there already?)"
                             % (*pc["pos"], c))
    nw = len({tuple(pc["way"]) for pc in pcs if pc["way"]})
    return [{"id": "S1", "anchor": list(pcs[0]["pos"]), "rot": 0, "score": 1000,
             "why": f"{len(pcs)} {p.get('kind', 'cage')} trap(s)" + (f" at {nw} way(s) in" if nw else " in the trap hall")}]


# ---------------------------------------------------------------- the ways in (snapshot)
def ways_in(snap: dict, manifest: dict | None, depth: int = 1, covered=frozenset()) -> list[dict]:
    """Every door that separates the outside from the fort, read on revealed tiles only (fair play): with doors,
    hatches and bridges closed, a door tile with an outside walkable tile (reached from the attacker sources,
    topo.sources) and an inside walkable tile (reached from the fort's own geometry) among its 8 neighbours on its level.
    [{way, tiles (the lane tiles still to trap), trapped (every lane tile is a trap or covered), partial (an outside
    neighbour takes no trap: a ramp, stair or other building)}], ordered by position. `covered`: tiles a traps project
    under way builds."""
    m = manifest or {}
    g = topo.Graph(snap, closed="+=H")
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    raw = "".join("".join(snap["rows"][f"z{z}"]) for z in range(z0, z1 + 1))
    src = topo.sources(g, m)
    if not src:
        return []
    out_seen, _ = g.bfs(src)
    own = g.mask(topo.fort_boxes(m))
    inner_src = [i for i in g.nodes_in(own) if not out_seen[i]]
    if not inner_src:
        return []
    in_seen, _ = g.bfs(inner_src, climb=False)
    edge = {tuple(p) for p in m.get("edge", [])}
    W, H = g.W, g.H
    res = []
    for i, c in enumerate(raw):
        if c != "+":
            continue
        x, y = i % W, (i // W) % H
        outs, ins = [], False
        for dx, dy in N8:
            if not (0 <= x + dx < W and 0 <= y + dy < H):
                continue
            j = i + dy * W + dx
            if out_seen[j] and g.walk[j]:
                outs.append((dx, dy, j))
            elif in_seen[j] and raw[j] in PASS_IN:
                ins = True
        if not outs or not ins:
            continue
        way = g.pos(i)
        lane, partial, trapped = [], False, True

        def ok(j) -> bool:
            return raw[j] in ".^" and not own[j] and g.pos(j) not in edge
        for dx, dy, j in outs:
            if not ok(j):
                partial = True
                continue
            lane.append(j)
        for dx, dy, j in outs:                     # depth 2-3: straight out from an orthogonal front tile
            if (dx == 0) == (dy == 0) or j not in lane:
                continue
            for k in range(2, depth + 1):
                xx, yy = x + k * dx, y + k * dy
                if not (0 <= xx < W and 0 <= yy < H):
                    break
                q = i + k * (dy * W + dx)
                if not (out_seen[q] and g.walk[q] and ok(q)):
                    break
                lane.append(q)
        want = []
        for j in lane:
            p = g.pos(j)
            if raw[j] == "^" or p in covered:
                continue
            want.append(list(p))
            trapped = False
        if not lane:
            trapped = False
        want.sort(key=lambda p: (p[2], p[1], p[0]))
        res.append({"way": list(way), "tiles": want, "trapped": trapped and bool(lane), "partial": partial,
                    "lane": len(lane)})
    return res
