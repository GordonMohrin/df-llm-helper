"""Defense add-ons placed against an existing fortcore (DESIGN §5.2): `gallery_o1`, the outward crossbow gallery
over the O1 approach.

Run 10 (2026-10-16): in a siege the fortcore keeps the outer drawbridge O1 up and the army (47 goblins) waited in
front of it for weeks; nobody could reach it and nothing could hit it. The inner gallery only covers the killing
field behind the trap hall. `gallery_o1` gives the crossbow squad a firing line over the tiles in front of O1 that
needs no opening: fortifications let bolts through but no walker.

Local frame (rot 0, the fortcore's rotation): the anchor (0,0,0) is the centre tile of the O1 footprint at the
defense level ze; attackers come from v < 0 (the 3x3 tunnel u -1..1, v -3..-1 and the ramp at v -4), the bailey
starts at v = 1. Fortcore local (u, v, ZE) = gallery local (u, v - 7, 0).
- F line: the tunnel's east wall u = 2, v -3..-1, becomes constructed fortifications (`CF`): dug from the tunnel
  side, built from the tunnel side (the tiles behind it are still rock, so no builder is shut in).
- Gallery: the strip u = 3, v -3..-1 behind the F line (station: the middle tile), roofed by the rock of w = -1.
- Corridor: from the strip east to u = 8, south along u = 8 (one rock column beside the trap hall, whose widest
  run is u = 6, as between the hall's own parallel runs) to the killing field's north row and west into the north
  end of the inner gallery (u = 5): the outer gallery is reached only through the inner gallery, i.e. from the
  military stair alcove in Z3, like the inner one (live L2: no z+1 gallery, DF never digs the hidden tile above an
  up stair).
Stage order is the safety argument: 1. dig the F line (outside, from the tunnel), 2. build the fortifications,
3. dig the strip and the corridor from inside. At no time does an open tile join the tunnel to the corridor; a
fortification stage that never finishes leaves the corridor undug. The corridor and the strip leave every burrow
once dug (the burrow plugin grows `Kern+` over tiles dug beside it): civilians on alert never idle where goblin
bowmen outside can shoot through the fortifications. Soldiers on station orders ignore burrows.
Manifest: one room {tpl: gallery_o1, use: utility, bbox: the strip}; topo.audit checks it (reachable only through
Z3, roofed, a fortification faces the O1 approach). Use in a siege: `squad.sortie` of the crossbow squad with the
strip's middle tile as target (DESIGN §5.2).
"""
from __future__ import annotations

from . import fortcore
from .primitives import Plan, rot_uv

O1_V = fortcore.FP["O1"][1]                              # O1 row in the fortcore frame (7)
FLINE = [(2, v) for v in (-3, -2, -1)]                   # fortifications in the tunnel's east wall
STRIP = [(3, v) for v in (-3, -2, -1)]                   # the gallery floor behind them
STATION = (3, -2)
COL = max(u for u, _ in fortcore.HALL) + 2               # corridor column: one rock tile east of the trap hall (8)
INNER_U = fortcore.FIELD[2] + 2                          # the inner gallery column (5)
INNER = [(INNER_U, v - O1_V) for v in range(fortcore.FIELD[1], fortcore.FIELD[3] + 1)]   # inner gallery tiles
JUNCTION = INNER[0]                                      # the inner gallery's north end (5, 19)
CORRIDOR_PTS = [(4, -2), (COL, -2), (COL, JUNCTION[1]), (JUNCTION[0] + 1, JUNCTION[1])]
TUNNEL = [(u, v) for v in (-3, -2, -1) for u in (-1, 0, 1)]
INNER_STATION = (INNER_U, (fortcore.FIELD[1] + fortcore.FIELD[3]) // 2 - O1_V)    # fortcore stations.gallery (5, 22)
Z1_LOCAL = (-4, 8 - O1_V, 0, 4, 16 - O1_V, 0)            # the fortcore bailey in this frame
O1_LOCAL = tuple(c - o for c, o in zip(fortcore.FP["O1"], (0, O1_V, 0, O1_V)))        # (-1, 0, 1, 0)

PARAMS: dict = {"gallery_o1": {}}       # per template: {param: (default, lo, hi)}


def corridor() -> list[tuple[int, int]]:
    """Corridor tiles from the strip to the tile next to the inner gallery, in order."""
    out = [CORRIDOR_PTS[0]]
    for (ua, va), (ub, vb) in zip(CORRIDOR_PTS, CORRIDOR_PTS[1:]):
        du, dv = (ub > ua) - (ub < ua), (vb > va) - (vb < va)
        u, v = ua, va
        while (u, v) != (ub, vb):
            u, v = u + du, v + dv
            out.append((u, v))
    return out


def inside_tiles() -> list[tuple[int, int]]:
    """Strip + corridor: dug from inside in the last dig stage."""
    return STRIP + corridor()


def gallery_o1(p: dict) -> Plan:
    """Outward crossbow gallery over the O1 approach: fortifications in the tunnel wall, reached only from Z3
    (DESIGN §5.2; place at site S1, which sites.rank derives from the fortcore manifest)."""
    P = Plan("gallery_o1", "defense")
    d1 = P.stage("g1.dig", "dig", defense=1)
    for u, v in FLINE:
        d1.tile(u, v, 0, "d")                                # an alcove of the tunnel, outside O1
    b = P.stage("g1.build", "build", orders=1, defense=1)
    for u, v in FLINE:
        b.tile(u, v, 0, "CF")
    d2 = P.stage("g2.dig", "dig", defense=1)
    for u, v in inside_tiles():
        d2.tile(u, v, 0, "d")
    e = P.stage("g2.unburrow", "burrow")
    e.ent(STRIP[0][0], STRIP[0][1], STRIP[-1][0], STRIP[-1][1], 0, "e")
    pts = CORRIDOR_PTS
    for (ua, va), (ub, vb) in zip(pts, pts[1:]):
        e.ent(min(ua, ub), min(va, vb), max(ua, ub), max(va, vb), 0, "e")
    P.room("", "gallery_o1", "utility", (STRIP[0][0], STRIP[0][1], 0, STRIP[-1][0], STRIP[-1][1], 0))
    return P


BUILD = {"gallery_o1": gallery_o1}
ATTACHED = {"gallery_o1": "fortcore"}     # built against that template's tiles (occupancy ignores them)


# ---------------------------------------------------------------- site (sites.rank)
def frame(manifest: dict | None) -> tuple[list[int], int]:
    """(anchor, rot) of the O1 frame from the fortcore manifest: the inner gallery station (stage 2) and the bailey
    Z1 (stage 1) fix it; an outer bridge (stage 3), if listed, must match it. Raises ValueError otherwise."""
    from .primitives import Xform
    m = manifest or {}
    gal = (m.get("stations") or {}).get("gallery")
    z1 = [list(b) for b in (m.get("zones") or {}).get("Z1", [])]
    if not gal or not z1:
        raise ValueError("gallery_o1: needs the fortcore manifest with the bailey Z1 and the inner gallery station "
                         "(fortcore stages 1-2)")
    outer = [b["fp"] for b in (m.get("bridges") or {}).values() if b.get("role") == "outer"]
    for rot in range(4):
        su, sv = INNER_STATION
        X = Xform((0, 0, 0), rot)
        du, dv, _ = X.pos(su, sv, 0)
        anchor = [gal[0] - du, gal[1] - dv, gal[2]]
        X = Xform(anchor, rot)
        if X.bbox(Z1_LOCAL) not in z1:
            continue
        fp = X.bbox((O1_LOCAL[0], O1_LOCAL[1], 0, O1_LOCAL[2], O1_LOCAL[3], 0))
        if outer and fp not in outer:
            continue
        return anchor, rot
    raise ValueError("gallery_o1: the manifest's bailey, inner gallery and O1 do not form the fortcore layout")


OPEN_OK = frozenset("#?S")      # rock (hidden, known or smoothed): may be dug


def site_problem(at, X) -> str:
    """'' if the gallery fits the revealed tiles at this frame, else the reason. `at(x, y, z)` = snapshot char."""
    for u, v in TUNNEL:
        if at(*X.pos(u, v, 0)) not in (".", "^"):
            return "the O1 tunnel in front of the bridge is not dug (fortcore stage 1)"
    if at(*X.pos(*JUNCTION, 0)) != ".":
        return "the inner gallery is not dug (fortcore stage 2)"
    own = set(FLINE) | set(inside_tiles())
    for u, v in FLINE:
        if at(*X.pos(u, v, 0)) not in OPEN_OK:
            return "the tunnel's east wall is open at %d,%d,%d" % X.pos(u, v, 0)
    allowed = own | set(INNER)
    for u, v in inside_tiles():
        if at(*X.pos(u, v, 0)) not in OPEN_OK:
            return "%d,%d,%d is not rock" % X.pos(u, v, 0)
        if at(*X.pos(u, v, 1)) not in OPEN_OK:
            return "no rock roof over %d,%d,%d" % X.pos(u, v, 0)
        for du in (-1, 0, 1):
            for dv in (-1, 0, 1):
                n = (u + du, v + dv)
                if n not in allowed and at(*X.pos(*n, 0)) not in OPEN_OK | {"F"}:
                    return "open tile %d,%d,%d beside the corridor" % X.pos(*n, 0)
    return ""


# ---------------------------------------------------------------- seal: close the open ways in (Run 10)
# `inspect entrances` and SIEGE_UNREADY list the ways in that have neither a door nor a bridge (`x,y,z kind`, kind =
# the tile shape: floor, ramp, stair_up ...). A seal project closes each with one piece, built by the player's own
# means (a quickfort #build, buildingplan materials):
# * floor-like tile: a door (`d`; the arrival lockdown forbids it like every entrance door), or with close=wall a
#   constructed wall, close=grate a wall grate, close=bars vertical bars (walkers blocked, water and air pass);
# * ramp: a ramp carries no door or wall (quickfort builds constructions on floor, open space and ramp tops only,
#   build.lua is_valid_tile_construction): the piece goes on the ramp top above it, a constructed wall (auto), a floor
#   grate (grate) or floor bars (bars); it cuts the ramp's way up and down;
# * stair: a hatch on the stair tile (it closes the stair's floor, i.e. the way down from it; a way up is closed by
#   naming the tile above). Walls cannot stand on stairs.
# Run 11 (Kilrudrabed): a tree tile the route crosses (branch, trunk_branch, twig) gets the chop designation (`t`,
# stage seal.clear): the felled tree takes the walkable branches with it, no piece. BUG-041 (Run 11 y461: the seal door
# 59,62,146 on a shrub waited 220 days for a gather designation nobody did; the plant gathering detail is filled only
# below 30 food days): a shrub's piece goes on the shrub in seal.build. quickfort builds doors and constructions on
# SHRUB and SAPLING tiles as on floors (internal/quickfort/build.lua is_valid_tile_generic, DFHack 53.16-r2: FLOOR,
# BOULDER, PEBBLES, TWIG, SAPLING, SHRUB; doors: is_tile_generic_and_wall_adjacent), the in-game rule it enforces.
# A sapling is no tree yet (quickfort's `t` marks tree tiles only, and no player designation removes a sapling), a
# door or hatch already stands on its opening, or another building does: the CLI (cmd.seal_openings) puts the piece on
# the neighbouring tile that closes the same route (bp.topo.SealGeo) and names the opening with `for=x,y,z:kind`; an
# open route without a roofed tile (SEAL_LEAK) gets a wall on the route's first tile that cuts it from the map edge.
# Doors and hatches only matter to the lockdown (seal's entrance check counts them); the worst-case audit counts
# only walls and raised bridges, so a bypass the audit names gets `wall` (topo.audit says where).
# Run 11 (site98 y435): the seal door 128,121,143 beside the door 127,121,143 stayed build_lost with stone and wood in
# stock; quickfort said 'Unsuitable tiles for building: 1', a `Cw` on the same tile went in at once. A door needs a
# wall beside it (door_stands); where the snapshot shows none the opening carries `nodoor` and its door becomes a
# constructed wall (cmd.seal_openings marks it; the runner walls a door quickfort refuses all the same).
# Params: at = 'x,y,z[ kind[ piece]][ for=x,y,z:kind][ nodoor];...' (absolute tiles, at most SEAL_MAX openings and
# AT_MAX characters), close = the default piece. The CLI fills missing kinds from the newest snapshot and expands
# at=last (cmd.seal_openings). Site: the first tile (any rot).
FLOORISH_KINDS = frozenset({"floor", "boulder", "pebbles", "brook_top", "passable"})
SHRUB_KINDS = frozenset({"shrub"})                       # BUG-041: the piece on the shrub (no gather first)
SHRUB_WHY = "on the shrub (quickfort builds on shrub tiles; no gather job)"
CHOP_KINDS = frozenset({"branch", "trunk_branch", "twig"})   # chop the tree (`t`): its branches go, no piece
STAIR_KINDS = frozenset({"stair", "stair_up", "stair_down", "stair_updown"})
CLOSER_KINDS = frozenset({"door", "hatch", "floodgate", "gratewall", "barsvertical"})   # closed already (lockdown)
NO_PIECE = frozenset({"none", "empty", "wall", "fortification", "ramp_top", "brook_bed", "endless_pit", "bridge",
                      "hidden", "?", ""})
OPEN_ROUTE = "open"                                       # SEAL_LEAK: an open route without a roofed tile
PIECES = ("door", "wall", "hatch", "grate", "bars")
CLOSE = ("auto",) + PIECES
SEAL_MAX = 6
AT_MAX = 200                    # bp.emit check_params: a string param holds at most 200 characters
NODOOR = "nodoor"               # at token: no door stands on the piece's tile (door_stands False): a wall instead
NODOOR_WHY = "no wall or fortification beside it"
CHAR_KIND = {".": "floor", "r": "ramp", "<": "stair_up", ">": "stair_down", "X": "stair_updown", "^": "floor"}
# piece -> quickfort #build key on a floor tile / on a ramp top
FLOOR_KEY = {"door": "d", "wall": "Cw", "grate": "W", "bars": "B"}
RAMP_KEY = {"wall": "Cw", "grate": "G", "bars": "~b"}
FOR_WHY = {"sapling": "no piece and no player designation takes a sapling",
           OPEN_ROUTE: "the first tile that cuts the route from the map edge"}
# The door rule (Run 11, site98 y435), as quickfort enforces it: internal/quickfort/build.lua builds a door (`d`) only
# where is_tile_generic_and_wall_adjacent holds: the tile itself generic (floor, boulder, pebbles, twig, sapling,
# shrub; revealed, no building, flow <= 1) and at least one of its four orthogonal neighbours on the same z of tile
# shape WALL or FORTIFICATION. Snapshot chars of those shapes (§9.10): `#` rough and `S` smoothed natural wall, `C`
# constructed wall, `F` fortification, `T` tree trunk (shape WALL, material tree). They do not count: a door or hatch
# beside it (`+`, a floor under a building: the live 127,121,143), bridges, other buildings (`B`), open space, ramps,
# stairs, diagonal neighbours, and a wall only planned (a piece of the same seal stage is no wall yet when quickfort
# places the stage). Hatches (`H`), wall grates (`W`), vertical bars (`B`) and floodgates need no support there.
# Uncertain: quickfort reads the neighbour's real tile type even where it is hidden; DF's own build menu may accept
# more or less than quickfort (quickfort's header says it enforces the in-game rule: "doors have to be adjacent to a
# wall"). So a door stays wherever the snapshot cannot tell (a neighbour hidden or outside it) and quickfort decides;
# the runner walls a door quickfort refuses (lua/dfllm/runner.lua door_walls).
DOOR_SUPPORT = frozenset("#SCFT")
N4 = ((1, 0), (-1, 0), (0, 1), (0, -1))


def door_stands(char_at, pos) -> bool | None:
    """Can a door stand on `pos` by the door rule above? `char_at(x, y, z)` = snapshot char or None (outside it).
    True: a wall or fortification lies orthogonally beside it; False: all four neighbours are revealed and none is;
    None: the snapshot cannot tell (a neighbour hidden or outside it)."""
    x, y, z = pos
    unknown = False
    for dx, dy in N4:
        c = char_at(x + dx, y + dy, z)
        if c in DOOR_SUPPORT:
            return True
        if c is None or c == "?":
            unknown = True
    return None if unknown else False


def door_piece(o: dict, close: str = "auto") -> bool:
    """Would the opening `o` (parse_openings) get a door with this `close`: a floor-like or shrub tile whose piece is
    auto, door or hatch (a hatch on a floor is a door, seal_pieces)?"""
    kind = o.get("kind") or "floor"
    want = o.get("piece") or close
    return (kind in FLOORISH_KINDS or kind in SHRUB_KINDS) and want in ("auto", "door", "hatch")


def for_why(kind: str) -> str:
    """Why a neighbour carries the piece for an opening of this kind (the seal:piece line)."""
    if kind == OPEN_ROUTE:
        return FOR_WHY[OPEN_ROUTE]
    why = FOR_WHY.get(kind) or (f"the route passes beside the {kind}" if kind in CLOSER_KINDS
                                else f"a {kind} stands on the opening")
    return "the neighbour on the same route: " + why


def piece_kind(kind: str) -> bool:
    """A tile kind a seal piece is built on (or cleared for) directly."""
    return kind in FLOORISH_KINDS or kind in SHRUB_KINDS or kind in CHOP_KINDS or kind in STAIR_KINDS \
        or kind == "ramp"


def needs_neighbour(kind: str) -> bool:
    """An opening whose own tile takes no piece but whose route a neighbour can close: a sapling, a door/hatch the
    route passes beside, another building on it, an open route (SEAL_LEAK)."""
    return not piece_kind(kind) and kind not in NO_PIECE


def _pos(text: str, what: str) -> list[int]:
    try:
        pos = [int(c) for c in text.split(",")]
        if len(pos) != 3:
            raise ValueError
    except ValueError:
        raise ValueError(f"seal.at: bad {what} {text!r} (want 'x,y,z[ kind[ piece]][ for=x,y,z:kind][ nodoor];...')") \
            from None
    return pos


def parse_openings(text: str) -> list[dict]:
    """'x,y,z[ kind[ piece]][ for=x,y,z:kind][ nodoor];...' -> [{pos, kind, piece, of, of_kind, nodoor}] (kind/piece
    '' when not given; of = the opening a neighbour's piece closes, None for the opening's own tile; nodoor = no door
    stands on the piece's tile, door_stands)."""
    out = []
    for part in str(text or "").split(";"):
        toks = part.split()
        if not toks:
            continue
        pos = _pos(toks[0], "tile")
        rest, of, of_kind, nodoor = [], None, "", False
        for t in toks[1:]:
            if t.lower().startswith("for="):
                tile, _, of_kind = t[4:].partition(":")
                of, of_kind = _pos(tile, "for= tile"), of_kind.lower()
            elif t.lower() == NODOOR:
                nodoor = True
            else:
                rest.append(t.lower())
        kind = rest[0] if rest else ""
        piece = rest[1] if len(rest) > 1 else ""
        if piece and piece not in PIECES:
            raise ValueError(f"seal.at: {toks[0]}: piece {piece!r} not one of {list(PIECES)}")
        out.append({"pos": pos, "kind": kind, "piece": piece, "of": of, "of_kind": of_kind, "nodoor": nodoor})
    if len(out) > SEAL_MAX:
        raise ValueError(f"seal.at: {len(out)} openings > {SEAL_MAX}; split them over several seal projects")
    return out


def format_openings(ops) -> str:
    def one(o):
        of = o.get("of")
        tail = "for=%d,%d,%d:%s" % (tuple(of) + (o.get("of_kind") or "?",)) if of else ""
        return " ".join(x for x in ("%d,%d,%d" % tuple(o["pos"]), o.get("kind", ""), o.get("piece", ""), tail,
                                    NODOOR if o.get("nodoor") else "") if x)
    return ";".join(one(o) for o in ops)


def seal_pieces(p: dict, anchor=None) -> list[dict]:
    """[{pos (opening or the neighbour), at (the piece's tile), key (#build key, '' for none), piece, kind, clear (the
    #dig key that clears the tile first: `p` gather a shrub, `t` chop a tree; ''), of (the opening a neighbour closes,
    or None), why}] for the seal params (raises ValueError)."""
    ops = parse_openings(p.get("at", ""))
    if not ops:
        if anchor is None:
            raise ValueError("seal: name the openings (at=x,y,z;...) or at=last")
        ops = [{"pos": list(anchor), "kind": "floor", "piece": "", "of": None, "of_kind": ""}]
    close = p.get("close", "auto")
    if close not in CLOSE:
        raise ValueError(f"seal.close: {close!r} not one of {list(CLOSE)}")
    out, seen = [], set()
    for o in ops:
        x, y, z = o["pos"]
        kind = o["kind"] or "floor"
        want = o["piece"] or ("auto" if close == "auto" else close)
        where = "%d,%d,%d %s" % (x, y, z, kind)
        clear, note, nodoor = "", "", ""
        if kind in CHOP_KINDS:
            piece, at, key, clear = "chop", (x, y, z), "", "t"
        elif kind in FLOORISH_KINDS or kind in SHRUB_KINDS:
            piece = "door" if want in ("auto", "hatch") else want
            if piece == "door" and o.get("nodoor"):          # Run 11: no wall beside it, so no door (door_stands)
                piece, nodoor = "wall", f"door unsuitable at {x},{y},{z} ({NODOOR_WHY}): wall instead"
            at, key = (x, y, z), FLOOR_KEY[piece]
            if kind in SHRUB_KINDS:                          # BUG-041: on the shrub, no gather designation first
                note = " " + SHRUB_WHY
        elif kind == "ramp":
            if want == "door":
                raise ValueError(f"seal: {where}: a ramp cannot carry a door; use wall, grate or bars (on the ramp top)")
            piece = "wall" if want in ("auto", "hatch") else want
            at, key = (x, y, z + 1), RAMP_KEY[piece]
        elif kind in STAIR_KINDS:
            if want not in ("auto", "hatch"):
                raise ValueError(f"seal: {where}: a stair takes only a hatch (name the floor beside it for a "
                                 f"{want})")
            piece, at, key = "hatch", (x, y, z), "H"
        elif needs_neighbour(kind):
            raise ValueError(f"seal: {where}: no piece stands there; name the neighbouring tile that closes the "
                             "route (dfllm cmd bp.place tpl=seal at=last finds it on the snapshot)")
        else:
            raise ValueError(f"seal: {where}: no piece for this tile kind (a floor, ramp or stair tile)")
        if at in seen:
            continue
        seen.add(at)
        if piece == "chop":
            why = f"{where}: chop the tree there (its branches go with it; no piece)"
        elif nodoor:
            why = f"{where}: {nodoor}" + (" (on the shrub)" if note else "")
        else:
            why = f"{where}: {piece} at {at[0]},{at[1]},{at[2]}{note}" + (" (the ramp top)" if kind == "ramp" else "")
        of = o.get("of")
        if of:
            ok = o.get("of_kind") or "?"
            why = "%d,%d,%d %s: %s at %d,%d,%d (%s)" % (*of, "open route" if ok == OPEN_ROUTE else ok, piece, *at,
                                                       for_why(ok))
            if nodoor:
                why += "; " + nodoor
        out.append({"pos": [x, y, z], "at": list(at), "key": key, "piece": piece, "kind": kind, "clear": clear,
                    "of": list(of) if of else None, "why": why})
    return out


def seal(p: dict, anchor, rot: int) -> Plan:
    """Close open ways in: a door on a floor, a wall on a ramp top, a hatch on a stair (or wall/grate/bars;
    absolute tiles from `inspect entrances`, SIEGE_UNREADY, SEAL_LEAK or the audit; at=last in dfllm cmd). Stages:
    seal.build (every piece, shrubs included: BUG-041), seal.clear (the chop designations of tree tiles, Run 11),
    seal.plant (a piece seal.clear clears the tile for; none since BUG-041, kept for the stage's meaning)."""
    P = Plan("seal", "defense")
    ax, ay, az = anchor
    pcs = seal_pieces(p, anchor)

    def put(stage, pc, key):
        x, y, z = pc["at"]
        u, v = rot_uv(x - ax, y - ay, (4 - rot) % 4)      # emit rotates by rot: the piece lands on (x, y)
        stage.tile(u, v, z - az, key)
    b = P.stage("seal.build", "build", orders=1, defense=1)
    for pc in pcs:
        if pc["key"] and not pc["clear"]:
            put(b, pc, pc["key"])
    if any(pc["clear"] for pc in pcs):
        c = P.stage("seal.clear", "dig", defense=1)
        for pc in pcs:
            if pc["clear"]:
                put(c, pc, pc["clear"])
        b2 = P.stage("seal.plant", "build", orders=1, defense=1)
        for pc in pcs:
            if pc["clear"] and pc["key"]:
                put(b2, pc, pc["key"])
    return P


def seal_anchor(p: dict):
    """The seal's own site anchor: its first opening (None without openings)."""
    ops = parse_openings(p.get("at", ""))
    return ops[0]["pos"] if ops else None


def seal_preview_tiles(p: dict) -> dict:
    """{(x, y, z): char} of the openings as the entrance check saw them (a preview base: floor, ramp + open top,
    stair), so `bp preview seal` builds on them instead of on rock."""
    out = {}
    for o in parse_openings(p.get("at", "")):
        x, y, z = o["pos"]
        k = o["kind"] or "floor"
        if k == "ramp":
            out[(x, y, z)], out[(x, y, z + 1)] = "r", "v"
        else:
            out[(x, y, z)] = {"stair_up": "<", "stair_down": ">", "stair_updown": "X", "stair": "X"}.get(k, ".")
    return out


seal.sited = True                       # bp.emit calls it with the site's anchor and rotation
seal.anchor_of = seal_anchor            # bp preview: the site is the first opening
seal.preview_tiles = seal_preview_tiles
PARAMS["seal"] = {"at": ("", None, None), "close": ("auto", None, None)}
BUILD["seal"] = seal
FREE = frozenset({"seal"})              # builds only on existing open tiles: never refused for touching a project
