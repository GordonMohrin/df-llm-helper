"""Room templates (DESIGN §5.6, §5.9, §5.10, §5.2): dining, bedrooms, tombs, hospital, temple, tavern,
workshops, farms; since live L1 also furnaces (smelter + wood furnace), office (a noble's office with a
chair) and captives (pit zone over a 1-tile drop, manifest `pit`); since live L3 the `cistern` (a well over
real water: well room, cistern, optional pipe from a revealed brook or river; see `cistern`); since Run 10 the refuge's
own rooms (REFUGE_LEVEL): `refuge_beds` and (FR-69) `refuge_drink`, a drink store dug from the refuge room.

Local frame (rot 0): the anchor (0,0,0) is an *existing* walkable tile (a corridor of the core); the room
is dug south of it. (0,1) is the doorway (door or open corridor start), the interior starts at v=2.
Walls are the surrounding natural rock; `sites.rank` checks that rock is not already open.
Locations use the quickfort zone `location=` property (quickfort-user-guide.txt:1678; library examples in
hack/data/blueprints/dreamfort.csv). Zones and stockpiles always carry explicit extents.
emit adds every room's dug bbox to manifest Z4, so later rooms can open from its public tiles.
"""
from __future__ import annotations

import re

from .primitives import Plan

# quickfort build keys (build.lua:850-931) -> df.workshop_type / df.furnace_type names (manifest `workshops`)
MOODABLE = [("wc", "Carpenters"), ("wm", "Masons"), ("wr", "Craftsdwarfs"), ("wj", "Jewelers"),
            ("wf", "MetalsmithsForge"), ("wb", "Bowyers"), ("wk", "Clothiers"), ("we", "Leatherworks"),
            ("wn", "Tanners"), ("wo", "Loom"), ("eg", "GlassFurnace"), ("wt", "Mechanics")]
MOODABLE_TYPES = [n for _, n in MOODABLE]
# non-moodable shops a phase may ask for (`workshops` deliverable; live L6: year-1 P0 wants a still and a butcher's
# shop, fortcore stage 1 builds both; `add` lets an older fort get the missing ones). Run 11: raw fish lay uncleaned
# with no fishery (food fell to 5 days); economy asks `workshops why=fishery`, follow adds only the fishery
# FR-73 (Run 14: no Farmer's Workshop in the whole fort, ProcessPlants and SpinThread waited for months): the farmer's
# shop (quickfort `ww`) is the plan's, P1 builds it with the moodable shops
# BUG-118 (Run 14 note 83: `only=Millstone` / `only=Quern` were refused as unknown types): the other shops df.workshop_type
# offers that quickfort places (build.lua: wq Quern and wM Millstone are exactly 1x1, wy Ashery, wd Dyer's Shop, wv Magma
# Forge, k Kennels and ws Siege Workshop exactly 5x5). Not here: Soap Maker (wS) and Screw Press (wp), Custom workshops with
# no df.workshop_type name of their own (the manifest and the kernel's census know shops by that name)
EXTRA = [("wl", "Still"), ("wz", "Kitchen"), ("wu", "Butchers"), ("wh", "Fishery"), ("ww", "Farmers"),
         ("wq", "Quern"), ("wM", "Millstone"), ("wy", "Ashery"), ("wd", "Dyers"), ("wv", "MagmaForge"),
         ("k", "Kennels"), ("ws", "Siege")]
EXTRA_TYPES = [n for _, n in EXTRA]
# BUG-356 (Run 16a-d: the first year hung on the fortcore, drink 3 d -> 0, no still, kitchen or carpenter until stage 1 was
# dug): workshops p.surface = 1 without skip/add builds exactly these four on the surface floor of the embark
STARTUP = ("Still", "Kitchen", "Carpenters", "Masons")
SHOP_SIZE = {"Quern": 1, "Millstone": 1, "Kennels": 5, "Siege": 5}      # side of the footprint; 3 for every other shop

COMMON = {"burrow": ("Kern+", None, None)}
PARAMS = {
    # BUG-387: surface = 1 on dining, bedrooms, tavern and office is the same room on open surface floor inside constructed walls
    # (no dig, no Z4 core needed, no burrow): the fort whose core stands on the surface (bp/surfacecore.py) has no rock to dig
    "dining": {"seats": (20, 4, 60), "tavern": (False, None, None), "tier": (2500, 0, 100000), "surface": (0, 0, 1)},
    "bedrooms": {"n": (10, 1, 40), "tier": (500, 0, 100000), "surface": (0, 0, 1)},
    "tombs": {"n": (10, 1, 60), "tier": (0, 0, 100000)},
    # BUG-384: surface = 1 is a hospital on open surface floor beside the wagon and the water (no fortcore needed): no dig,
    # no door, no burrow, no well; the sites follow the kernel's accepted water as the dug one does
    "hospital": {"beds": (4, 1, 10), "surface": (0, 0, 1)},
    "temple": {"size": (7, 5, 11), "tier": (2000, 0, 100000)},
    "tavern": {"seats": (12, 4, 40), "surface": (0, 0, 1)},
    # BUG-356: surface = 1 is the startup set: the shops stand on open surface floor beside the wagon, no dig, no door, no burrow
    # BUG-562: rebuild = 1 builds ONE shop type (only=<Type>) again where manifest.gone says it stood (no dig, no door, no room)
    "workshops": {"skip": ("", None, None), "add": ("", None, None), "surface": (0, 0, 1), "rebuild": (0, 0, 1)},
    "depot": {},                      # BUG-368: SURFACE, not BUILD: no room (nothing dug, no Z4, no burrow)
    "tradepost": {},                  # BUG-488: SURFACE too: the trade pile beside the depot (no fortcore needed)
    # BUG-297: surface = 1 builds the plots on soil floor that stands already (no dig, no door, no burrow): sites.rank
    # offers such sites on soil-marked floor inside the fort or next to its entrance when no room site lies on soil
    "farms": {"plots": (2, 1, 4), "surface": (0, 0, 1)},
    "furnaces": {"wood": (1, 0, 2)},
    # BUG-396: surface = 1 is the office on open surface floor beside the wagon (no fortcore, nothing dug, no door, no burrow)
    "office": {"role": ("manager", None, None), "surface": (0, 0, 1)},
    "captives": {},
    # Gordon 11.10.2026: stately rooms, guild halls, trained soldiers. tier = the room value the kernel aims at
    "hall": {"seats": (16, 8, 48), "tier": (5000, 0, 1000000)},
    "guildhall": {"profession": ("MINER", None, None), "tier": (3000, 0, 1000000)},
    "barracks": {"racks": (6, 2, 12), "tier": (1000, 0, 1000000)},
    # path "" = a dry cistern filled by buckets (pond zone); else the pipe waypoints (see cistern_layout)
    "cistern": {"path": ("", None, None), "rise": (1, 1, 40), "side": ("S", None, None),
                "water": ("bed", None, None), "level": ("core", None, None)},
    # BUG-028 (Run 10: 60 days of drink inside the core, 3093 units outside O1): food and drink storage behind B2
    "stockroom": {"w": (9, 5, 15), "h": (6, 4, 10), "still": (1, 0, 1), "barrels": (0, 0, 200)},
    # Run 10 (Tiefe+ beds 8 < 27, no safe room at pop 110): a dormitory dug from the refuge room, in the refuge burrow
    "refuge_beds": {"n": (8, 2, 30), "burrow": ("Tiefe+", None, None)},
    # FR-69 (Run 11 y477: Tiefe+ drink 0, 1199 of 1493 drinks in the Kern+ pile dfllm-stock): a drink store dug from the
    # refuge room; n = barrels (refuge_drink_n), take = the stockpile it takes drink from ('' none)
    # BUG-572 (Run 16b i2 Brotherarrow y406: the refuge held drink and 23 beds but food 1 for 95 citizens, ~26 dead): food = 1 makes the
    # store a food AND drink pile (no booze preset), sized by refuge_store_n (up to REFUGE_STORE_MAX barrels)
    "refuge_drink": {"n": (12, 2, 40), "take": ("dfllm-stock", None, None), "burrow": ("Tiefe+", None, None),
                     "food": (0, 0, 1)},
}
# templates that sit on the refuge level (anchors in the fortcore refuge room, sites.rank): they never join Z4 (the
# civilian core; a Z4 box beside the refuge would let the audit's core -> refuge check start next to it)
REFUGE_LEVEL = frozenset({"refuge_beds", "refuge_drink"})
# quickfort `assigned_unit=` roles (preserve-rooms noble codes) an office may be reserved for
OFFICE_ROLES = ("manager", "bookkeeper", "broker", "expedition_leader", "mayor", "chief_medical_dwarf")
USE = {"dining": "used", "bedrooms": "used", "tombs": "used", "temple": "used", "hall": "used",
       "guildhall": "used", "barracks": "used"}
# rooms nobody should walk through: sites.rank opens no new room from their tiles behind a door
NO_THROUGH = frozenset({"bedrooms", "tombs", "hospital", "temple", "office", "captives", "hall", "guildhall",
                        "barracks", "refuge_beds", "suites", "grand_temple"})      # FR-102: bp/grand.py


def _box(P: Plan, W: int, H: int, door: bool = True):
    """Dig a W x H interior south of the doorway; returns (u0, v0, u1, v1)."""
    u0, v0 = -(W // 2), 2
    u1, v1 = u0 + W - 1, v0 + H - 1
    P.stage("dig", "dig").rect(u0, v0, u1, v1, 0).tile(0, 1, 0, "d")
    if door:
        P.stage("build", "build", orders=1).tile(0, 1, 0, "d")
    return u0, v0, u1, v1


def _finish(P: Plan, p: dict, box, zkey: str = "", zprops: str = "", sfx: str = "", tier: int = 0):
    u0, v0, u1, v1 = box
    if zkey:
        P.stage("zone", "zone").ent(u0, v0, u1, v1, 0, zkey, zprops)
    if p.get("burrow"):
        P.stage("burrow", "burrow").ent(u0, v0, u1, v1, 0, "a", f"name={p['burrow']} create=true") \
            .ent(0, 1, 0, 1, 0, "a", f"name={p['burrow']} create=true")
    if sfx is not None:
        P.room(sfx, P.tpl, USE.get(P.tpl, "utility"), (u0, v0, 0, u1, v1, 0), tier)


SURFACE_ROOMS = ("dining", "bedrooms", "tavern", "office")      # BUG-387: the room templates with a surface variant


def _surface(P: Plan, p: dict) -> Plan:
    """BUG-387 (Run 16 region1: no fort got a dug core, so no office, dining room, tavern or bedrooms in years): the same room
    on open surface floor. The dug tiles stay the room's floor, doorway and corridors; the dig stage goes, every other tile of the
    room's bbox grown by one (the rock the dig would have left) becomes a constructed wall `Cw`, built first. The anchor stays
    the walkable tile in front of the doorway, so the geometry (and the furniture) is the dug room's. No burrow: the room is
    not inside the surface core's walls. `P.surface_rect` = the local rect that must be open floor (sites.rank)."""
    tiles = P.dug().get(0, set())
    P.stages = [s for s in P.stages if s.mode not in ("dig", "burrow")]
    us, vs = [t[0] for t in tiles], [t[1] for t in tiles]
    u0, u1, v0, v1 = min(us) - 1, max(us) + 1, max(1, min(vs) - 1), max(vs) + 1
    w = P.stage("walls", "build", orders=1)
    for v in range(v0, v1 + 1):
        for u in range(u0, u1 + 1):
            if (u, v) not in tiles:
                w.tile(u, v, 0, "Cw")
    P.stages.remove(w)
    P.stages.insert(0, w)
    P.surface_rect = (u0, 0, u1, v1)
    return P


def _seats(P: Plan, box, seats: int, cols: int):
    """Chair row, table row, aisle row per set; the centre column stays free as the aisle."""
    u0, v0, u1, _ = box
    b = P.stage("build", "build", orders=1)
    us = [u for u in range(u0, u1 + 1) if u != 0][:cols]
    for i in range(seats):
        k, c = divmod(i, cols)
        b.tile(us[c], v0 + 1 + 3 * k, 0, "c").tile(us[c], v0 + 2 + 3 * k, 0, "t")


def _seat_box(seats: int, wide: int):
    cols = wide if seats <= wide * 4 else wide + 4
    sets = -(-seats // cols)
    return cols, cols + 1, 3 * sets


def dining(p: dict) -> Plan:
    """Dining hall: table+chair pairs in rows with a centre aisle; optional tavern location (DESIGN §5.6)."""
    P = Plan("dining", "living")
    cols, W, H = _seat_box(p["seats"], 8)
    box = _box(P, W, H)
    _seats(P, box, p["seats"], cols)
    _finish(P, p, box, "h", "name=Dining" + (" location=tavern" if p["tavern"] else ""), "", p["tier"])
    return _surface(P, p) if p.get("surface") else P


def tavern(p: dict) -> Plan:
    """Tavern: dining-hall zone with location=tavern, seats and goblet chests (keeper is a UI assignment)."""
    P = Plan("tavern", "living")
    cols, W, H = _seat_box(p["seats"], 8)
    box = _box(P, W, H)
    _seats(P, box, p["seats"], cols)
    P.stage("build", "build", orders=1).tile(box[0], box[1], 0, "h").tile(box[2], box[1], 0, "h")
    _finish(P, p, box, "h", "location=tavern name=Tavern desired_goblets=10")
    return _surface(P, p) if p.get("surface") else P


def bedrooms(p: dict) -> Plan:
    """3x3 rooms (bed, cabinet, chest, door) on both sides of a 1-wide corridor, one rock tile between.
    One manifest room for the whole block (the inspect reply that carries the manifest is <= 8 KB); the
    validator checks each bedroom zone for closure."""
    P = Plan("bedrooms", "living")
    n = p["n"]
    rows = -(-n // 2)
    d = P.stage("dig", "dig").rect(0, 1, 0, 4 * rows, 0)
    b = P.stage("build", "build", orders=1)
    z = P.stage("zone", "zone")
    for i in range(n):
        k, side = divmod(i, 2)
        s = -1 if side == 0 else 1
        va = 4 * k + 2                  # rooms start at v=2: only the corridor mouth touches the anchor row
        ua, ub = (-4, -2) if s < 0 else (2, 4)
        far = -4 if s < 0 else 4
        d.rect(ua, va, ub, va + 2, 0).tile(s, va + 1, 0, "d")
        b.tile(s, va + 1, 0, "d").tile(far, va + 1, 0, "b").tile(far, va, 0, "f").tile(far, va + 2, 0, "h")
        z.ent(ua, va, ub, va + 2, 0, "b")
    _finish(P, p, (-4, 1, 4, 4 * rows), tier=p["tier"])
    return _surface(P, p) if p.get("surface") else P


def tombs(p: dict) -> Plan:
    """Coffins along aisles, one 1x1 tomb zone per coffin (DESIGN §5.10)."""
    P = Plan("tombs", "living")
    n = p["n"]
    cols = [-1, 1] if n <= 20 else [-3, -1, 1, 3]
    rows = -(-n // len(cols))
    front = 0 if len(cols) == 2 else 1            # cross aisle so the door reaches every aisle
    box = _box(P, 3 if len(cols) == 2 else 7, rows + front)
    b = P.stage("build", "build", orders=1)
    z = P.stage("zone", "zone")
    for i in range(n):
        r, c = divmod(i, len(cols))
        u, v = cols[c], box[1] + front + r
        b.tile(u, v, 0, "n")
        z.ent(u, v, u, v, 0, "T")
    _finish(P, p, box, tier=p["tier"])
    return P


def hospital(p: dict) -> Plan:
    """Beds, traction bench, a table, chests and its own well spot (well + pond hole over a sump below)."""
    P = Plan("hospital", "living")
    if p.get("surface"):
        return _surface_hospital(P, p)
    box = _box(P, 7, 5)
    u0, v0, u1, v1 = box
    P.stage("dig", "dig").tile(2, v0 + 1, 0, "h").tile(3, v0 + 1, 0, "h")
    b = P.stage("build", "build", orders=1)
    for i in range(p["beds"]):
        b.tile(u0 + i if i < 7 else u0 + i - 7, v1 if i < 7 else v1 - 1, 0, "b")
    b.tile(u0, v0 + 2, 0, "R").tile(u0, v0, 0, "h").tile(u0 + 1, v0, 0, "h").tile(2, v0 + 1, 0, "l")
    b.tile(u1, v0, 0, "t")                         # BUG-537: the table of surgery and suturing (inspect hospital: no_table)
    P.stage("zone", "zone").ent(3, v0 + 1, 3, v0 + 1, 0, "p", "pond=true")
    _finish(P, p, box, "m", "location=hospital name=Hospital allow=residents")
    return P


HOSPITAL_SURFACE = (7, 5)            # BUG-384: the surface hospital's block (the dug one's interior)


def _surface_hospital(P: Plan, p: dict) -> Plan:
    """BUG-384 (Run 16c i3: 'hospital: 0 sites without a fortcore', 7 hurt, a patient's thirst up to 23,500 with no hospital):
    the hospital on open surface floor, anchor = the block's north-west corner (as farms surface and the BUG-368 depot).
    Nothing is dug, no door, no burrow, no well and pond (the kernel's accepted water is what the site is ranked by, as for
    the dug hospital); beds in the bottom rows, the traction bench and chests as in the dug one, the meeting zone
    location=hospital over the whole block. The manifest lists it as a hospital room."""
    W, H = HOSPITAL_SURFACE
    b = P.stage("build", "build", orders=1)
    for i in range(p["beds"]):
        b.tile(i if i < 7 else i - 7, H - 1 if i < 7 else H - 2, 0, "b")
    b.tile(0, 2, 0, "R").tile(0, 0, 0, "h").tile(1, 0, 0, "h")
    b.tile(W - 1, 0, 0, "t")                       # BUG-537: the table of surgery and suturing
    P.stage("zone", "zone").ent(0, 0, W - 1, H - 1, 0, "m", "location=hospital name=Hospital allow=residents")
    P.room("", "hospital", USE.get("hospital", "utility"), (0, 0, 0, W - 1, H - 1, 0), 0)
    return P


def temple(p: dict) -> Plan:
    """General temple (no deity): meeting-area zone with location=temple and an offering place."""
    P = Plan("temple", "living")
    s = p["size"] | 1
    box = _box(P, s, s)
    P.stage("build", "build", orders=1).tile(0, box[3], 0, "~a")
    _finish(P, p, box, "m", "location=temple name=Temple allow=residents", "", p["tier"])
    return P


def workshops(p: dict) -> Plan:
    """All 12 moodable workshop types (DESIGN §5.9), minus `skip` (comma-separated df type names), plus the
    non-moodable `add` types (EXTRA_TYPES: Still, Kitchen, Butchers, Fishery, Farmers)."""
    skip = {s.strip() for s in p["skip"].split(",") if s.strip()}
    add = {s.strip() for s in p.get("add", "").split(",") if s.strip()}
    if p.get("surface") and not skip and not add:              # BUG-356: the startup set
        add = {n for n in STARTUP if n in EXTRA_TYPES}
        skip = {n for n in MOODABLE_TYPES if n not in STARTUP}
    bad = skip - set(MOODABLE_TYPES)
    if bad:
        raise ValueError(f"workshops: unknown skip types {sorted(bad)}; known: {MOODABLE_TYPES}")
    bad = add - set(EXTRA_TYPES)
    if bad:
        raise ValueError(f"workshops: unknown add types {sorted(bad)}; known: {EXTRA_TYPES}")
    # BUG-046 (Run 12 note 32: the kitchen waited behind a forge that was never built, kitchens 0, food 10 days): the food
    # shops (Still, Kitchen, Butchers, Fishery) come first, the first planned building gets buildingplan's materials first
    todo = [(k, n) for k, n in EXTRA if n in add] + [(k, n) for k, n in MOODABLE if n not in skip]
    if not todo:
        raise ValueError("workshops: nothing left to build")
    P = Plan("workshops", "infra")
    if p.get("rebuild"):
        return _rebuild_shop(P, todo)
    if p.get("surface"):
        return _surface_shops(P, todo)
    # BUG-118: 3x3 cells in rows of six, 4 apart; a 1x1 shop sits in the middle of its cell; the 5x5 shops (Kennels, Siege)
    # follow in a strip of their own below the rows (6 apart), so the layout of the usual 3x3 shops does not change
    small = [(k, n) for k, n in todo if SHOP_SIZE.get(n, 3) < 5]
    big = [(k, n) for k, n in todo if SHOP_SIZE.get(n, 3) == 5]
    cols, rows = min(len(small), 6), -(-len(small) // 6)
    h_small = 0 if not small else 4 if rows == 1 else 4 * rows       # FR-73: a third row of shops gets its own 4 rows
    width = max(4 * cols + 1 if small else 0, 6 * len(big) + 1 if big else 0)
    box = _box(P, width, h_small + (6 if big else 0))
    b = P.stage("build", "build", orders=1)
    for i, (key, name) in enumerate(small):
        r, c = divmod(i, 6)
        u, v = box[0] + 1 + 4 * c, box[1] + 1 + 4 * r
        if SHOP_SIZE.get(name, 3) == 1:
            b.tile(u + 1, v + 1, 0, key)
        else:
            b.ent(u, v, u + 2, v + 2, 0, key)
        P.workshops.append((name, (u + 1, v + 1, 0)))
    for i, (key, name) in enumerate(big):
        u, v = box[0] + 1 + 6 * i, box[1] + h_small + 1
        b.ent(u, v, u + 4, v + 4, 0, key)
        P.workshops.append((name, (u + 2, v + 2, 0)))
    _finish(P, p, box)
    return P


SURFACE_COLS = 4


def _rebuild_shop(P: Plan, todo: list) -> Plan:
    """BUG-562 (Run 16b i2 Brotherarrow: Craftsdwarfs 99,119,134 and Clothiers 107,116,134 'no longer stands', the places free, mood_ws
    417 days, `bp sites workshops` '0 free sites' because it ranks room sites only): the shop again where it stood. One type, its
    footprint centred on the anchor (the old position of manifest.gone); nothing dug, no door, no burrow, no room."""
    if len(todo) != 1:
        raise ValueError("workshops rebuild=1: exactly one shop type (only=<Type>): a shop is rebuilt where it stood, "
                         f"{len(todo)} types asked")
    key, name = todo[0]
    side = SHOP_SIZE.get(name, 3)
    h = side // 2
    b = P.stage("build", "build", orders=1)
    if side == 1:
        b.tile(0, 0, 0, key)
    else:
        b.ent(-h, -h, h, h, 0, key)
    P.workshops.append((name, (0, 0, 0)))
    return P


def surface_block(n: int) -> tuple[int, int]:
    """BUG-356: (width, height) of the surface block for n shops of 3x3: SURFACE_COLS cells a row, 4 apart, 1 tile margin."""
    return 4 * min(n, SURFACE_COLS) + 1, 4 * -(-n // SURFACE_COLS) + 1


def _surface_shops(P: Plan, todo: list) -> Plan:
    """BUG-356 (Run 16a-d: every new fort hung on the fortcore for its first year, no still, kitchen or carpenter until
    stage 1 was dug, drink 3 d -> 0, a door that only a carpenter makes): the shops stand on open surface floor, anchor =
    the block's north-west corner. Nothing is dug, no door, no burrow; a 3x3 cell per shop (the 1x1 Quern and Millstone in
    its middle), SURFACE_COLS a row. The manifest lists them, so the later `workshops` project skips what stands."""
    big = [n for _, n in todo if SHOP_SIZE.get(n, 3) == 5]
    if big:
        raise ValueError(f"workshops surface=1: no 5x5 shops on the startup block ({', '.join(big)})")
    b = P.stage("build", "build", orders=1)
    for i, (key, name) in enumerate(todo):
        r, c = divmod(i, SURFACE_COLS)
        u, v = 1 + 4 * c, 1 + 4 * r
        if SHOP_SIZE.get(name, 3) == 1:
            b.tile(u + 1, v + 1, 0, key)
        else:
            b.ent(u, v, u + 2, v + 2, 0, key)
        P.workshops.append((name, (u + 1, v + 1, 0)))
    return P


DEPOT_SIDE = 5


def depot(p: dict) -> Plan:
    """Trade depot (5x5) on open surface floor, no fortcore needed (BUG-368)."""
    # BUG-368 (Run 16b i2 Ostgate: DEPOT_MISSING 'no known depot site (no fortcore depot)' every year, no caravan ever traded,
    # no metal or leather): until now only fortcore stage 1 built a depot (in its bailey). The anchor is the north-west
    # corner of the 5x5 block; the manifest names its middle (`depot`), so the depot keeper rebuilds it there after a siege.
    # Nothing is dug, no door, no burrow; sites.rank offers flat open surface floor on the citizens' walk group.
    P = Plan("depot", "infra")
    P.stage("build", "build").ent(0, 0, DEPOT_SIDE - 1, DEPOT_SIDE - 1, 0, "D")   # orders=0: buildingplan, like the keeper's depot
    P.manifest["depot"] = (DEPOT_SIDE // 2, DEPOT_SIDE // 2, 0)
    return P


TRADEPOST = (4, 2)       # BUG-488: the trade pile's block (width, height)


def tradepost(p: dict) -> Plan:
    """Trade pile (4x2 stockpile dfllm-trade) beside the depot on open surface floor, no fortcore needed (BUG-488)."""
    # BUG-488 (Run 16a i1 Basementflew: 'nothing_listed' for four years, no stone or iron ever bought): the stockpile `dfllm-trade` was
    # only made by fortcore stage 1 (s1.place) and the surface core, so a fort with a depot and no (finished) core had no pile that
    # logistics could send to the depot (baseline: 'no trade pile yet'). This is that pile alone: nothing dug, no door, no burrow;
    # sites.rank offers open surface floor beside the manifest depot; autotrade=true, and baseline registers it by name (logistics add trade).
    P = Plan("tradepost", "infra")
    P.stage("place", "place").ent(0, 0, TRADEPOST[0] - 1, TRADEPOST[1] - 1, 0, "g", "name=dfllm-trade autotrade=true")
    return P


def farms(p: dict) -> Plan:
    """Underground farm: `plots` 5x7 farm plots (need soil or mud) beside a centre aisle.
    quickfort skips non-soil tiles (build.lua:102-104), so sites.rank prefers soil marks and shallow levels."""
    P = Plan("farms", "infra")
    n = p["plots"]
    cols, rows = min(n, 2), -(-n // 2)
    if p.get("surface"):
        # BUG-297 (Run 15c Inkintense: no room site on soil, one plot for 50 citizens, a famine): plots on soil floor
        # that is already there, anchor = the plot block's north-west corner; nothing is dug, no door, no burrow paint
        W, H = 5 if cols == 1 else 11, 8 * rows - 1
        b = P.stage("build", "build")
        for i in range(n):
            r, c = divmod(i, cols)
            b.ent(6 * c, 8 * r, 6 * c + 4, 8 * r + 6, 0, "p")
        P.room("", "farms", USE.get("farms", "utility"), (0, 0, 0, W - 1, H - 1, 0), 0)
        return P
    box = _box(P, 5 if cols == 1 else 11, 8 * rows - 1)
    b = P.stage("build", "build")
    for i in range(n):
        r, c = divmod(i, cols)
        u, v = box[0] + 6 * c, box[1] + 8 * r
        b.ent(u, v, u + 4, v + 6, 0, "p")
    _finish(P, p, box)
    return P


def furnaces(p: dict) -> Plan:
    """Smelter plus `wood` wood furnaces (charcoal): metal from ore without magma (STATUS §6.5)."""
    P = Plan("furnaces", "infra")
    todo = [("es", "Smelter")] + [("ew", "WoodFurnace")] * p["wood"]
    box = _box(P, 4 * len(todo) + 1, 4)
    b = P.stage("build", "build", orders=1)
    for i, (key, name) in enumerate(todo):
        u, v = box[0] + 1 + 4 * i, box[1]
        b.ent(u, v, u + 2, v + 2, 0, key)
        P.workshops.append((name, (u + 1, v + 1, 0)))
    _finish(P, p, box)
    return P


def office(p: dict) -> Plan:
    """A noble's office: chair + table + office zone reserved for `role` (preserve-rooms). Live L1: the manager
    validates work orders only from an office once the fort reaches a population threshold. BUG-042 (Run 11, y471):
    an office zone without its chair and table validated nothing for months; a table and a chair side by side made the
    manager take ManageWorkOrders at once (economy's office check keeps them: sieges destroy furniture)."""
    role = str(p["role"]).lower()
    if role not in OFFICE_ROLES:
        raise ValueError(f"office: unknown role {role!r}; known: {', '.join(OFFICE_ROLES)}")
    P = Plan("office", "living")
    box = _box(P, 3, 3)
    P.stage("build", "build", orders=1).tile(0, box[1] + 1, 0, "c").tile(1, box[1] + 1, 0, "t")
    _finish(P, p, box, "o", f"assigned_unit={role} name=Office")
    # BUG-232 (live Guildcleans y373: the zone stage waited behind the chair and table the unvalidated orders never made):
    # the office zone comes right after the dig, before the door and the furniture
    zone = next(s for s in P.stages if s.label == "zone")
    P.stages.remove(zone)
    P.stages.insert(1, zone)
    return _surface(P, p) if p.get("surface") else P


OFFICE_SURFACE = (3, 3)              # BUG-396: the surface office's block


def _surface_office(P: Plan, role: str) -> Plan:
    """BUG-396 (Run 16a i1 Bachwald: no office for 294 days, so the manager validated nothing: 7 brews and 18 orders waited,
    drink 0; every office hung on the dug Z4 floor of a fortcore): the office on open surface floor, anchor = the block's
    north-west corner (as the surface hospital and the BUG-368 depot). Nothing is dug, no door, no burrow; chair and table
    side by side (a table and a chair made the manager take ManageWorkOrders at once, BUG-042), the Office zone over the
    whole block first (BUG-232: before the furniture the unvalidated orders never make)."""
    W, H = OFFICE_SURFACE
    P.stage("zone", "zone").ent(0, 0, W - 1, H - 1, 0, "o", f"assigned_unit={role} name=Office")
    P.stage("build", "build", orders=1).tile(0, 1, 0, "c").tile(1, 1, 0, "t")
    P.room("", "office", USE.get("office", "utility"), (0, 0, 0, W - 1, H - 1, 0), 0)
    P.surface_rect = (0, 0, W - 1, H - 1)     # merge21: sites.rank sizes every BUG-387 surface room by it
    return P


def hall(p: dict) -> Plan:
    """Festhalle for feasts and occasions: a 13-wide hall with a centre aisle, banquet tables on both sides and
    a dais with a throne seat at the far end (meeting-area zone `Festhalle`)."""
    P = Plan("hall", "living")
    rows = -(-p["seats"] // 4)                      # 4 seats per row: two tables on each side of the aisle
    box = _box(P, 13, 3 * rows + 5)
    u0, v0, u1, v1 = box
    b = P.stage("build", "build", orders=1)
    for k in range(rows):
        for u in (-5, -3, 3, 5):
            b.tile(u, v0 + 1 + 3 * k, 0, "c").tile(u, v0 + 2 + 3 * k, 0, "t")
    b.tile(0, v1, 0, "c").tile(-1, v1 - 1, 0, "t").tile(0, v1 - 1, 0, "t").tile(1, v1 - 1, 0, "t")   # the dais
    b.tile(u0, v1, 0, "h").tile(u1, v1, 0, "h")                                                      # chests
    _finish(P, p, box, "m", "name=Festhalle allow=residents", "", p["tier"])
    return P


def guildhall(p: dict) -> Plan:
    """Guildhall for one profession (quickfort `location=guildhall profession=...`): a 7x7 hall with two tables,
    chairs and two chests; the guild keeps its members and rewards their work."""
    prof = str(p["profession"]).upper()
    if not prof.replace("_", "").isalpha():
        raise ValueError(f"guildhall: bad profession {prof!r}")
    P = Plan("guildhall", "living")
    box = _box(P, 7, 7)
    u0, v0, u1, v1 = box
    b = P.stage("build", "build", orders=1)
    for u in (-2, 2):
        b.tile(u, v0 + 1, 0, "c").tile(u, v0 + 2, 0, "t").tile(u, v0 + 4, 0, "c").tile(u, v0 + 5, 0, "t")
    b.tile(u0, v1, 0, "h").tile(u1, v1, 0, "h")
    _finish(P, p, box, "m", f"location=guildhall profession={prof}", "", p["tier"])
    return P


def barracks(p: dict) -> Plan:
    """Kaserne with a training floor: a 9x9 room, weapon racks and armor stands along the walls, beds for the
    watch; soldiers spar here (barracks zone `Kaserne`)."""
    P = Plan("barracks", "defense")
    box = _box(P, 9, 9)
    u0, v0, u1, v1 = box
    b = P.stage("build", "build", orders=1)
    n = p["racks"]
    for i in range(n):
        v = v0 + 1 + i // 2 * 2                         # one rack and one armor stand per wall side and row
        b.tile(u0 if i % 2 == 0 else u1, v, 0, "r")
        b.tile(u0 + 1 if i % 2 == 0 else u1 - 1, v, 0, "a")
    for u in (-2, 0, 2):
        b.tile(u, v1, 0, "b")
    _finish(P, p, box, "B", "name=Kaserne", "", p["tier"])
    return P


STOCK_PILE = "dfllm-stock"


def stockroom(p: dict) -> Plan:
    """Core stockroom: a food stockpile (drink and food, in barrels and pots) and an optional still behind the core
    seal, so a siege that cuts off the outer stock does not (BUG-028)."""
    P = Plan("stockroom", "infra")
    W, H = p["w"] | 1, p["h"]
    box = _box(P, W, H)
    u0, v0, u1, v1 = box
    piles = [(u0, v0, u1, v1)]
    if p["still"]:
        if H < 4 or W < 5:
            raise ValueError("stockroom: a still needs w >= 5 and h >= 4")
        P.stage("build", "build", orders=1).ent(-1, v1 - 2, 1, v1, 0, "wl")      # at the far end, centred
        P.workshops.append(("Still", (0, v1 - 1, 0)))
        piles = [(u0, v0, u1, v1 - 3), (u0, v1 - 2, -2, v1), (2, v1 - 2, u1, v1)]
    pl = P.stage("place", "place")
    for a, b, c, d in piles:
        n = (c - a + 1) * (d - b + 1)
        pl.ent(a, b, c, d, 0, "f", f"name={STOCK_PILE} barrels={p['barrels'] or n}")
    _finish(P, p, box)
    return P


REFUGE_BED_COLS = (-3, -2, -1, 1, 2, 3)        # beds beside the centre aisle u = 0


def refuge_beds(p: dict) -> Plan:
    """Refuge dormitory: `n` beds in a room dug from the refuge room, a dormitory zone, in the refuge burrow."""
    # Run 10: the civ alert refused Tiefe+ for beds 8 < 27 (25 % of the citizens asleep at once, refuge.bed_pct), and
    # nothing in the plans could add beds there (rooms stay off the refuge level). The room is dug from a refuge floor
    # tile into rock (sites.rank: the footprint and its wall ring rock or unknown, nothing open beside it), so it opens
    # no way in: its only opening is the doorway into the refuge. Bed rows alternate with aisle rows, the centre
    # column is the aisle from the doorway: every bed has a free tile beside it. BUG-320 (Run 15b Earthboat y384: the
    # project y384s1b2 waited months for its door, buildingplan 'waits for door x1 (1 free, 5 ordered)', its beds never
    # placed): no door, like the drink store. The doorway opens into the refuge only (the room is dug into rock), so a
    # door closes nothing the refuge's own hatch and doors do not; it was one more item the refuge waited for.
    P = Plan("refuge_beds", "living")
    n, cols = p["n"], len(REFUGE_BED_COLS)
    rows = -(-n // cols)
    box = _box(P, 7, 2 * rows - 1, door=False)
    u0, v0, u1, v1 = box
    b = P.stage("build", "build", orders=1)
    for i in range(n):
        r, c = divmod(i, cols)
        b.tile(REFUGE_BED_COLS[c], v0 + 2 * r, 0, "b")
    _finish(P, p, box, "D", "name=RefugeBeds")
    return P


# FR-69 refuge drink store (Run 11, Kilrudrabed y477: Tiefe+ held 0 of the fort's 1493 drinks, 1199 lay in the one
# Kern+ stockpile dfllm-stock; readiness R0 refuge_dry; the cistern sites lay far from the refuge). Sizing: the kernel
# calls the refuge dry below citizens x DRINK_PER_CIT drink units (seal.CFG.drink_per_cit, readiness refuge_dry); the
# deep defense holds the citizens there for breach_days (7, config/reflex.json refuge) at economy's DRINK_MILLI per
# citizen and day (config/baseline.json economy.seed_milli.drink, x1000; a dwarf drinks about every 19 days). A barrel
# is counted as DRINKS_PER_BARREL drinks, conservatively: one brew job fills an empty barrel with 5 (economy per_job)
# and DF stores later brews of that drink in it (live Run 11: 1199 drinks on the 54 tiles of dfllm-stock), so a full
# store holds more than it was sized for. At most REFUGE_DRINK_MAX barrels: a 5x5 room beside a dead-end refuge.
DRINK_PILE = "dfllm-drink"            # the store's stockpile name (seal.CFG.store finds it on the refuge's tiles)
DRINK_PER_CIT, DRINK_MILLI, BREACH_DAYS = 1, 53, 7
DRINKS_PER_BARREL = 5
REFUGE_DRINK_MAX = 24
FOOD_PER_CIT, REFUGE_STORE_MAX = 1, 40   # BUG-572: seal.CFG.food_per_cit; a 5x8 room beside the refuge room
CELL_MAX = 64                         # schema CHUNK cell text bytes (CONTRACTS §9.8)
_PILE_NAME = re.compile(r"[A-Za-z0-9_+-]{0,20}")


def refuge_drink_n(cit: int, days: int = BREACH_DAYS, milli: int = DRINK_MILLI) -> int:
    """Barrels for the refuge drink store: max(citizens x DRINK_PER_CIT, citizens x days x milli / 1000) drinks at
    DRINKS_PER_BARREL a barrel, 2..REFUGE_DRINK_MAX."""
    cit = max(0, int(cit or 0))
    units = max(cit * DRINK_PER_CIT, -(-cit * max(0, days) * max(0, milli) // 1000))
    return min(REFUGE_DRINK_MAX, max(2, -(-units // DRINKS_PER_BARREL)))


def refuge_store_n(cit: int, days: int = BREACH_DAYS, milli: int = DRINK_MILLI) -> int:
    """BUG-572: barrels for the refuge FOOD and drink store (refuge_drink food=1): the drink units of refuge_drink_n plus
    citizens x FOOD_PER_CIT food units (the SIEGE level's food need, seal.refuge_fit) at DRINKS_PER_BARREL a barrel,
    2..REFUGE_STORE_MAX."""
    cit = max(0, int(cit or 0))
    drink = max(cit * DRINK_PER_CIT, -(-cit * max(0, days) * max(0, milli) // 1000))
    units = drink + cit * FOOD_PER_CIT
    return min(REFUGE_STORE_MAX, max(2, -(-units // DRINKS_PER_BARREL)))


def drink_room(n: int) -> tuple[int, int]:
    """(W, H) of the store's interior for n barrels: 3 wide up to 9, else 5 wide; one barrel per tile."""
    w = 3 if n <= 9 else 5
    return w, -(-n // w)


def refuge_drink(p: dict) -> Plan:
    """Refuge drink store: a drink-only stockpile with barrels in a room dug from the refuge room, in the refuge burrow."""
    # The room is dug from a refuge floor tile into rock like refuge_beds (sites.rank: footprint and wall ring rock or
    # unknown, nothing open beside it): its only opening is the doorway into the refuge, so it lies inside the refuge's
    # region and adds no way in (the separation `sep`, the deep defense). No door: nothing to build, nothing to forbid.
    # The pile is a food stockpile set to drink only (quickfort `:=booze`, the stockpiles library preset) with one
    # barrel per tile, linked to take from `take` (quickfort take_from: the haulers move drink barrels from that pile
    # into this one, up to its tiles; a name no stockpile has only prints a quickfort error, the pile is made anyway)
    take = p["take"]
    if not _PILE_NAME.fullmatch(take):
        raise ValueError(f"refuge_drink.take: bad stockpile name {take!r}")
    P = Plan("refuge_drink", "infra")
    n = p["n"]
    box = _box(P, *drink_room(n), door=False)
    u0, v0, u1, v1 = box
    props = f"name={DRINK_PILE} barrels={n}" + (f" take_from={take}" if take else "")
    # BUG-572: food = 1 leaves the pile at its food default (drink and prepared food, as the stockroom's), no booze preset
    cfg = "" if p.get("food") else "=booze"
    cell = f"f{{{props}}}" + (f":{cfg}" if cfg else "") + f"({u1 - u0 + 1}x{v1 - v0 + 1})"
    if len(cell.encode("utf-8")) > CELL_MAX:
        raise ValueError(f"refuge_drink.take: {take!r} makes the stockpile cell {len(cell)} > {CELL_MAX} bytes "
                         f"(a name of at most {CELL_MAX - len(cell) + len(take)} characters)")
    P.stage("place", "place").ent(u0, v0, u1, v1, 0, "f", props, cfg=cfg)
    _finish(P, p, box, sfx="food" if p.get("food") else "")      # BUG-572: the manifest room id ends in _food (plan finds it)
    return P


def captives(p: dict) -> Plan:
    """Captive pit: a 3x3 room with a 1-tile channel; the pit zone sits on the drop (manifest `pit`), away
    from traps. Care assigns caged invaders to it."""
    P = Plan("captives", "defense")
    box = _box(P, 3, 3)
    P.stage("dig", "dig").tile(0, box[1] + 1, 0, "h")
    P.stage("zone", "zone").ent(0, box[1] + 1, 0, box[1] + 1, 0, "p")
    P.manifest["pit"] = [0, box[1] + 1, 0]
    _finish(P, p, box)
    return P


# ---------------------------------------------------------------- cistern (live L3: patients died of thirst)
# Local frame like every room: anchor (0,0,0) = an existing walkable tile, doorway (0,1), well room u -1..1,
# v 2..4 at w=0, the 3x3 cistern right below it (w=-1) with the well over a channel at (0,3). A stair (-1,4)
# (down stair in the room, up stair in the cistern) is the way down and back up. Review: the first version had
# only the channel ramps under the well (and pond) hole. A DF ramp leads up only onto the floor above an
# adjacent wall, and a dug-out cistern leaves those ramps without such a wall, so the miner who dug the last
# cistern tile was shut in; the well building then closed its hole for good, and the floodgate, the
# fortification and the lever link below could never be built. The stair keeps everything below (the cistern,
# and the pipe while it is dry) reachable: nobody is shut in, builders and the lever linker get there. The
# dry cistern keeps a pond hole (1,3) with a pond zone: bucket carriers fill it.
# With a `path` the cistern is fed from a revealed brook or river through a pipe at w=-1:
#   cistern -(0,5)- diagonal -(1,6)- ... pipe ... -floodgate- -fortification- shaft (B) -breach (G)- water (W)
# * the diagonal step (0,5)->(1,6) is the pressure breaker: DF moves no pressure diagonally, so water downstream
#   is never pressurized and cannot rise above the cistern level w=-1; this is the overflow: whatever the
#   cistern cannot hold stays in the pipe and the shaft at the brook's own level. Second line: pressure lifts
#   water at most one level below its source, so with the water not above the well room (sites.plan_cistern's
#   default `safe`) the room stays dry even without the breaker;
# * the floodgate stands on the pipe tile right before the fortification (review: a floodgate at the cistern
#   end left a pipe segment sealed at both ends; whoever hauled a boulder in it when the second seal was built
#   drowned at the breach). DF installs floodgates closed (item-descriptions.lua FLOODGATE); the lever in the
#   well room opens it once linked on the lever sheet. Closed, it stops the inflow at the intake: only the
#   shaft outside the fortification ever holds water before the lever is pulled. The pull floods the dry pipe
#   under pressure within moments, so nobody may be in the pipe then (the pull is a deliberate act: look first);
# * a constructed fortification on the last pipe tile passes water but no creature (the intake is open to the
#   surface: without it the pipe is a tunnel from the bank into the fort). It is built (stage `build`) before
#   the floodgate (stage `gate`): its only access is through the floodgate tile;
# * the shaft is dug top-down from the bank (damp-dig markers `md`, it is 2 tiles from the water), the breach
#   (a damp-dig channel on the bank tile G between shaft and water) is the last stage, after floodgate and
#   fortification are built; with water='bed' (a brook: water at w_top-1 under the walkable brook top) the
#   channel tile itself stays dry, so the runner's water probe does not stop the project;
# * a 'w' Water Source zone on the water tile is the first stage: caregivers fill buckets there for patients
#   at once, long before the pipe is done (the bucket-delivery fallback of lua/dfllm/water.lua).
# dug() (what emit adds to Z4) is only the doorway, the well room and the cistern: the pipe and the intake lie
# outside the fort, and a Z4 box over the brook bank would read as an attacker reaching the core (topo.audit).
CISTERN_ROOM = (-1, 2, 1, 4)          # well room (w=0) and cistern (w=-1)
CISTERN_WELL, CISTERN_POND, CISTERN_LEVER, CISTERN_STAIR = (0, 3), (1, 3), (-1, 2), (-1, 4)
CISTERN_SPILL, CISTERN_START = (0, 5), (1, 6)     # the breaker: diagonal from the spill tile to the pipe start
SIDES = {"N": (0, -1), "E": (1, 0), "S": (0, 1), "W": (-1, 0)}
# bed: water one level below the bank (brook); bank: water at bank level (both with a `path`). BUG-262 (Run 15 Inkintense:
# no brook, a light aquifer, the hospital held back for good): aquifer = no path and no pond: the basin (w=-1) is dug into
# an aquifer level, the runner keeps its rough aquifer walls (lua/dfllm/aqshaft.lua A.basin) and the aquifer seeps into it
# under the well; sites.rank puts the basin on a known aquifer level below a dry room level (a heavy one is refused)
WATER_KINDS = ("bed", "bank", "aquifer")
LEVELS = ("core", "refuge")


def parse_path(text: str) -> list[tuple[int, int]]:
    """'u,v;u,v;...' -> waypoints."""
    out = []
    for part in str(text or "").split(";"):
        part = part.strip()
        if not part:
            continue
        a, sep, b = part.partition(",")
        try:
            if not sep:
                raise ValueError
            out.append((int(a), int(b)))
        except ValueError:
            raise ValueError(f"cistern.path: bad waypoint {part!r} (want 'u,v;u,v;...')") from None
    return out


def format_path(pts) -> str:
    return ";".join(f"{u},{v}" for u, v in pts)


def _expand(pts) -> list[tuple[int, int]]:
    out = [pts[0]]
    for (ua, va), (ub, vb) in zip(pts, pts[1:]):
        if (ua != ub) == (va != vb):
            raise ValueError(f"cistern.path: segment {ua},{va}->{ub},{vb} is not orthogonal (or has length 0)")
        du, dv = (ub > ua) - (ub < ua), (vb > va) - (vb < va)
        u, v = ua, va
        while (u, v) != (ub, vb):
            u, v = u + du, v + dv
            out.append((u, v))
    return out


def _cheb(a, b) -> int:
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))


def _straight_runs(tiles) -> list[tuple[tuple[int, int], tuple[int, int]]]:
    """An orthogonal tile chain as (first, last) of its straight runs, no tile in two runs."""
    runs: list[list] = []
    for t in tiles:
        if runs:
            a, b = runs[-1]
            if a == b and _cheb(b, t) == 1:
                runs[-1][1] = t
                continue
            if a != b and (t[0] - b[0], t[1] - b[1]) == ((b[0] > a[0]) - (b[0] < a[0]),
                                                         (b[1] > a[1]) - (b[1] < a[1])):
                runs[-1][1] = t
                continue
        runs.append([t, t])
    return [(a, b) for a, b in runs]


def cistern_layout(p: dict) -> dict:
    """Local geometry of a cistern (validated). Keys: intake (bool), room, well, stair (down stair in the room
    over the up stair in the cistern: the way down), pond (dry only), lever (intake only), cistern (tiles at
    w=-1), pipe (ordered tiles at w=-1 from the spill tile to the barrier), gate (floodgate, the pipe tile
    before the barrier), barrier, shaft (B), w_top, side, breach (G, at w_top), water (W tiles that get the
    water-source zone)."""
    for k, ok in (("side", SIDES), ("water", WATER_KINDS), ("level", LEVELS)):
        if p[k] not in ok:
            raise ValueError(f"cistern.{k}: {p[k]!r} not one of {list(ok)}")
    u0, v0, u1, v1 = CISTERN_ROOM
    cist = [(u, v) for v in range(v0, v1 + 1) for u in range(u0, u1 + 1)]
    L = {"intake": False, "room": CISTERN_ROOM, "well": CISTERN_WELL, "stair": CISTERN_STAIR, "cistern": cist,
         "pond": CISTERN_POND, "lever": None, "pipe": [], "gate": None, "barrier": None, "shaft": None,
         "w_top": None, "side": None, "breach": None, "water": [], "aquifer": False}
    pts = parse_path(p["path"])
    if p["water"] == "aquifer":
        if pts:
            raise ValueError("cistern.water aquifer takes no path: the aquifer fills the basin (path is a brook pipe)")
        L.update(pond=None, aquifer=True)        # BUG-262: no pond zone (a bucket loop), the aquifer is the source
        return L
    if not pts:
        return L
    if pts[0] != CISTERN_START:
        raise ValueError(f"cistern.path must start at {CISTERN_START[0]},{CISTERN_START[1]} (after the breaker)")
    tiles = _expand(pts)
    if len(tiles) < 3:
        raise ValueError("cistern.path: needs at least 3 tiles (floodgate, fortification, shaft)")
    if len(set(tiles)) != len(tiles):
        raise ValueError("cistern.path crosses itself")
    seq = [CISTERN_SPILL] + tiles
    for i, a in enumerate(seq):
        for b in seq[i + 3:]:               # i+2 is the diagonal across a bend: the pipe's own corner
            if _cheb(a, b) < 2:
                raise ValueError(f"cistern.path: {a} and {b} touch (a leak around the floodgate/breaker)")
        if i > 0 and any(_cheb(a, c) < 2 for c in cist):
            raise ValueError(f"cistern.path: {a} touches the cistern (only the spill tile may)")
    corners = {(CISTERN_START[0], CISTERN_SPILL[1]), (CISTERN_SPILL[0], CISTERN_START[1])}
    if corners & set(tiles):
        raise ValueError("cistern.path: a corner of the breaker step is pipe (the step must stay diagonal)")
    du, dv = SIDES[p["side"]]
    B = tiles[-1]
    G, W = (B[0] + du, B[1] + dv), (B[0] + 2 * du, B[1] + 2 * dv)
    if any(_cheb(G, t) < 2 for t in seq[:-1]) or any(_cheb(W, t) < 2 for t in seq):
        raise ValueError(f"cistern.side {p['side']}: the breach {G} or the water {W} touches the pipe")
    wt = -1 + p["rise"]
    if wt >= 0 and any(_cheb(B, c) < 3 or _cheb(G, c) < 3 for c in cist):
        raise ValueError("cistern: the intake shaft rises next to the well room")
    ww = [(W[0], W[1], wt - 1), (W[0], W[1], wt)] if p["water"] == "bed" else [(W[0], W[1], wt)]
    L.update(intake=True, pond=None, lever=CISTERN_LEVER, pipe=[CISTERN_SPILL] + tiles[:-1], gate=tiles[-3],
             barrier=tiles[-2], shaft=B, w_top=wt, side=(du, dv), breach=(G[0], G[1], wt), water=ww)
    return L


class CisternPlan(Plan):
    """dug() = the tiles that join the civilian core (doorway, well room, cistern; emit adds them to Z4). The
    pipe and the intake shaft are checked per tile by sites.footprint/intake_tiles."""

    def __init__(self, layout: dict):
        super().__init__("cistern", "infra")
        self.layout = layout

    def dug(self) -> dict[int, set[tuple[int, int]]]:
        u0, v0, u1, v1 = self.layout["room"]
        return {w: {(u, v) for u, v in t if u0 <= u <= u1 and v0 - 1 <= v <= v1}
                for w, t in Plan.dug(self).items() if w in (0, -1)}


def cistern(p: dict) -> Plan:
    """Well room over a 3x3 cistern with a stair down; with `path` fed from a brook/river (breaker, floodgate,
    fortification). Stages: water (zone), dig, build, gate (floodgate), shaft, breach, burrow."""
    L = cistern_layout(p)
    P = CisternPlan(L)
    if L["intake"]:
        z = P.stage("water", "zone")                     # first: buckets for patients long before the pipe
        for u, v, w in L["water"]:
            z.ent(u, v, u, v, w, "w", "name=dfllm-water")
    box = _box(P, 3, 3)
    u0, v0, u1, v1 = box
    d = P.stage("dig", "dig")
    d.rect(u0, v0, u1, v1, -1)                           # the cistern below the well room
    d.stair(*CISTERN_STAIR, -1, 0)                       # the way down and back up (no ramp: see above)
    d.tile(*CISTERN_WELL, 0, "h")                        # well hole
    b = P.stage("build", "build", orders=1)
    b.tile(*CISTERN_WELL, 0, "l")
    if not L["intake"]:
        if L["pond"]:                                    # BUG-262: an aquifer cistern has none
            d.tile(*CISTERN_POND, 0, "h")                # pond hole: bucket carriers fill the cistern
    else:
        for u, v in L["pipe"]:
            d.tile(u, v, -1, "d")
        b.tile(*CISTERN_LEVER, 0, "Tl")
        b.tile(*L["barrier"], -1, "CF")                  # fortification: water passes, creatures do not
        P.stage("gate", "build", orders=1).tile(*L["gate"], -1, "x")    # floodgate, installed closed, after it
        s = P.stage("shaft", "dig")
        bu, bv = L["shaft"]
        for w in range(-1, L["w_top"] + 1):
            s.tile(bu, bv, w, "mdu" if w == -1 else "mdj" if w == L["w_top"] else "mdi")
        # review: the burrow plugin grows every '+' burrow over each dug tile beside it, so the pipe and the shaft
        # bottom (outside the fortification) joined Kern+/Tiefe+. A wild animal at the shaft bottom then counts
        # as a hostile inside Kern+ (sense: BREACH, civ alert; live L3 a false BREACH held the fort 40 days), and
        # civilians kept in the burrow during an alert wander down the dry pipe the lever pull floods. Both
        # leave every burrow as soon as the shaft is dug ('e' without a name: all burrows).
        e = P.stage("unburrow", "burrow")
        for (ua, va), (ub, vb) in _straight_runs(L["pipe"][1:] + [L["shaft"]]):
            e.ent(min(ua, ub), min(va, vb), max(ua, ub), max(va, vb), -1, "e")
        for w in range(0, L["w_top"] + 1):
            e.ent(bu, bv, bu, bv, w, "e")
        P.stage("breach", "dig").tile(*L["breach"], "mdh")
    if not L["intake"] and L["pond"]:
        P.stage("zone", "zone").ent(*CISTERN_POND, *CISTERN_POND, 0, "p", "pond=true")
    _finish(P, p, box)
    return P


BUILD = {"dining": dining, "bedrooms": bedrooms, "tombs": tombs, "hospital": hospital, "temple": temple,
         "tavern": tavern, "workshops": workshops, "farms": farms, "furnaces": furnaces, "office": office,
         "captives": captives, "cistern": cistern, "hall": hall, "guildhall": guildhall, "barracks": barracks,
         "stockroom": stockroom, "refuge_beds": refuge_beds, "refuge_drink": refuge_drink}

SURFACE = {"depot": depot, "tradepost": tradepost}            # BUG-368: templates that build on open surface floor and join no room set


def plot_rects(p: dict) -> list[tuple[int, int, int, int, int]]:
    """Local (u0, v0, u1, v1, w) of the farm plots of a farms plan (sites.rank counts soil marks there)."""
    return [(it.u0, it.v0, it.u1, it.v1, it.w) for st in farms(p).stages if st.mode == "build"
            for it in st.items if it.key == "p"]
