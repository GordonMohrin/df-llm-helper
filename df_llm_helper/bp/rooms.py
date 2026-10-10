"""Room templates (DESIGN §5.6, §5.9, §5.10, §5.2): dining, bedrooms, tombs, hospital, temple, tavern,
workshops, farms.

Local frame (rot 0): the anchor (0,0,0) is an *existing* walkable tile (a corridor of the core); the room
is dug south of it. (0,1) is the doorway (door or open corridor start), the interior starts at v=2.
Walls are the surrounding natural rock; `sites.rank` checks that rock is not already open.
Locations use the quickfort zone `location=` property (quickfort-user-guide.txt:1678; library examples in
hack/data/blueprints/dreamfort.csv). Zones and stockpiles always carry explicit extents.
emit adds every room's dug bbox to manifest Z4, so later rooms can open from its public tiles.
"""
from __future__ import annotations

from .primitives import Plan

# quickfort build keys (build.lua:850-931) -> df.workshop_type / df.furnace_type names (manifest `workshops`)
MOODABLE = [("wc", "Carpenters"), ("wm", "Masons"), ("wr", "Craftsdwarfs"), ("wj", "Jewelers"),
            ("wf", "MetalsmithsForge"), ("wb", "Bowyers"), ("wk", "Clothiers"), ("we", "Leatherworks"),
            ("wn", "Tanners"), ("wo", "Loom"), ("eg", "GlassFurnace"), ("wt", "Mechanics")]
MOODABLE_TYPES = [n for _, n in MOODABLE]

COMMON = {"burrow": ("Kern+", None, None)}
PARAMS = {
    "dining": {"seats": (20, 4, 60), "tavern": (False, None, None), "tier": (2500, 0, 100000)},
    "bedrooms": {"n": (10, 1, 40), "tier": (500, 0, 100000)},
    "tombs": {"n": (10, 1, 60), "tier": (0, 0, 100000)},
    "hospital": {"beds": (4, 1, 10)},
    "temple": {"size": (7, 5, 11), "tier": (2000, 0, 100000)},
    "tavern": {"seats": (12, 4, 40)},
    "workshops": {"skip": ("", None, None)},
    "farms": {"plots": (2, 1, 4)},
}
USE = {"dining": "used", "bedrooms": "used", "tombs": "used", "temple": "used"}
# rooms nobody should walk through: sites.rank opens no new room from their tiles behind a door
NO_THROUGH = frozenset({"bedrooms", "tombs", "hospital", "temple"})


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
    return P


def tavern(p: dict) -> Plan:
    """Tavern: dining-hall zone with location=tavern, seats and goblet chests (keeper is a UI assignment)."""
    P = Plan("tavern", "living")
    cols, W, H = _seat_box(p["seats"], 8)
    box = _box(P, W, H)
    _seats(P, box, p["seats"], cols)
    P.stage("build", "build", orders=1).tile(box[0], box[1], 0, "h").tile(box[2], box[1], 0, "h")
    _finish(P, p, box, "h", "location=tavern name=Tavern desired_goblets=10")
    return P


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
    return P


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
    """Beds, traction bench, chests and its own well spot (well + pond hole over a sump below)."""
    P = Plan("hospital", "living")
    box = _box(P, 7, 5)
    u0, v0, u1, v1 = box
    P.stage("dig", "dig").tile(2, v0 + 1, 0, "h").tile(3, v0 + 1, 0, "h")
    b = P.stage("build", "build", orders=1)
    for i in range(p["beds"]):
        b.tile(u0 + i if i < 7 else u0 + i - 7, v1 if i < 7 else v1 - 1, 0, "b")
    b.tile(u0, v0 + 2, 0, "R").tile(u0, v0, 0, "h").tile(u0 + 1, v0, 0, "h").tile(2, v0 + 1, 0, "l")
    P.stage("zone", "zone").ent(3, v0 + 1, 3, v0 + 1, 0, "p", "pond=true")
    _finish(P, p, box, "m", "location=hospital name=Hospital allow=residents")
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
    """All 12 moodable workshop types (DESIGN §5.9), minus `skip` (comma-separated df type names)."""
    skip = {s.strip() for s in p["skip"].split(",") if s.strip()}
    bad = skip - set(MOODABLE_TYPES)
    if bad:
        raise ValueError(f"workshops: unknown skip types {sorted(bad)}; known: {MOODABLE_TYPES}")
    todo = [(k, n) for k, n in MOODABLE if n not in skip]
    if not todo:
        raise ValueError("workshops: nothing left to build")
    P = Plan("workshops", "infra")
    cols, rows = min(len(todo), 6), -(-len(todo) // 6)
    box = _box(P, 4 * cols + 1, 4 if rows == 1 else 8)
    b = P.stage("build", "build", orders=1)
    for i, (key, name) in enumerate(todo):
        r, c = divmod(i, 6)
        u, v = box[0] + 1 + 4 * c, box[1] + 1 + 4 * r
        b.ent(u, v, u + 2, v + 2, 0, key)
        P.workshops.append((name, (u + 1, v + 1, 0)))
    _finish(P, p, box)
    return P


def farms(p: dict) -> Plan:
    """Underground farm: `plots` 5x7 farm plots (need soil or mud) beside a centre aisle.
    quickfort skips non-soil tiles (build.lua:102-104), so sites.rank prefers soil marks and shallow levels."""
    P = Plan("farms", "infra")
    n = p["plots"]
    cols, rows = min(n, 2), -(-n // 2)
    box = _box(P, 5 if cols == 1 else 11, 8 * rows - 1)
    b = P.stage("build", "build")
    for i in range(n):
        r, c = divmod(i, cols)
        u, v = box[0] + 6 * c, box[1] + 8 * r
        b.ent(u, v, u + 4, v + 6, 0, "p")
    _finish(P, p, box)
    return P


BUILD = {"dining": dining, "bedrooms": bedrooms, "tombs": tombs, "hospital": hospital, "temple": temple,
         "tavern": tavern, "workshops": workshops, "farms": farms}


def plot_rects(p: dict) -> list[tuple[int, int, int, int, int]]:
    """Local (u0, v0, u1, v1, w) of the farm plots of a farms plan (sites.rank counts soil marks there)."""
    return [(it.u0, it.v0, it.u1, it.v1, it.w) for st in farms(p).stages if st.mode == "build"
            for it in st.items if it.key == "p"]
