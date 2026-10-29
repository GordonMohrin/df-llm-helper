"""Large rooms and the deep core (G15, FR-102 / FR-103; docs/v2/FR-fr-rooms-relocate-G15.md).

FR-102 room tiers: `suites` (bedrooms), `grand_dining`, `grand_tavern` and `grand_temple` in two sizes, `large` and
`grand`, each in two stages: stage 1 (class living) digs, furnishes and zones the room like the small templates of
rooms.py; stage 2 (class beauty: the runner runs it only in PEACE with R1 and plan policy beauty used_rooms, CONTRACTS
§9.8) smooths the floor and the walls of the used room, then engraves them (quickfort dig `s`, then `e`; a tile under
furniture or a door is skipped by quickfort). Only these used rooms get the beauty stage, never corridors or shafts.
`tier` 0 = the size's room-value target (TIERS). grand adds statues (render: they block their tile; every layout
keeps a free aisle beside each one). Furniture quality is not set: quickfort places whatever buildingplan finds.

FR-103 `deepcore`: a second civilian core `depth` levels below a public core floor, reached by its own stair shaft,
in three stages: s1 dig (shaft, hub, dorm, workshop hall, store room), s2 furnish (doors, beds, six workshops, hub
tables), s3 move (the stockpiles of the store room, the dormitory and dining zones, Kern+ over the shaft and the
rooms: the beds and the stores of the fort move over). Local frame (rot 0, like explore): the anchor (0,0,0) is a
public core floor, (0,1,0) a vestibule with a door, (0,2,0) the shaft top (down stair), the shaft runs down at (0,2,w)
to the up stair at w = -depth; the deep rooms lie south of it on that level. The site is ranked by bp/deep.py (dry, hard stone,
never into a revealed cavern, damp, warm or aquifer level, off the refuge level).
"""
from __future__ import annotations

from . import rooms
from .primitives import Plan

SIZES = ("large", "grand")
# room-value targets per template and size (DOCTRINE: 0/100/250/500/1000/1500/2500/10000 Meager .. Royal)
TIERS = {"suites": {"large": 1000, "grand": 2500}, "grand_dining": {"large": 2500, "grand": 10000},
         "grand_tavern": {"large": 2500, "grand": 10000}, "grand_temple": {"large": 2000, "grand": 10000}}
CLASS = {1: "living", 2: "beauty"}
SUITE = {"large": (4, 4), "grand": (5, 5)}          # bedroom interior (width away from the corridor, depth along it)
TEMPLE = {"large": 9, "grand": 11}
_ROOM = {"size": ("large", None, None), "stage": (1, 1, 2), "tier": (0, 0, 100000), "burrow": ("Kern+", None, None)}
PARAMS = {
    "suites": {"n": (8, 1, 30), **_ROOM},
    "grand_dining": {"seats": (40, 8, 80), **_ROOM},
    "grand_tavern": {"seats": (24, 8, 60), **_ROOM},
    "grand_temple": {**_ROOM},
    "deepcore": {"stage": (1, 1, 3), "depth": (8, 3, 40), "beds": (12, 4, 18), "burrow": ("Kern+", None, None)},
}
ROOMS = ("suites", "grand_dining", "grand_tavern", "grand_temple")     # join Z4 when they dig (emit)
DEEP = "deepcore"
DEEP_STAGES = 3
USE = {"suites": "used", "grand_dining": "used", "grand_tavern": "used", "grand_temple": "used"}


def _size(tpl: str, p: dict) -> str:
    if p["size"] not in SIZES:
        raise ValueError(f"{tpl}.size: {p['size']!r} is not one of {', '.join(SIZES)} (FR-102)")
    return p["size"]


def _tier(tpl: str, p: dict) -> int:
    return p["tier"] or TIERS[tpl][_size(tpl, p)]


def _beauty(P: Plan, rects) -> None:
    """Stage 2: smooth floor and walls (the interior grown by its wall ring), then engrave them."""
    for label, key in (("beauty.smooth", "s"), ("beauty.engrave", "e")):
        st = P.stage(label, "dig")
        for u0, v0, u1, v1 in rects:
            st.rect(u0 - 1, v0 - 1, u1 + 1, v1 + 1, 0, key)


def _room(P: Plan, tpl: str, p: dict, box, zkey: str = "", zprops: str = "") -> None:
    """Stage 1 zone + burrow + manifest room; the room entry comes with stage 2 too (same id: the merge keeps one)."""
    if p["stage"] == 1:
        rooms._finish(P, p, box, zkey, zprops, None)
    P.room("", tpl, USE[tpl], (box[0], box[1], 0, box[2], box[3], 0), _tier(tpl, p))


def _new(tpl: str, p: dict) -> Plan:
    return Plan(tpl, CLASS[p["stage"]])


# ---------------------------------------------------------------- suites
def suite_rooms(p: dict) -> list[tuple[int, int, int, int, int]]:
    """(side, u0, v0, u1, v1) of every bedroom: side -1 west, +1 east of the 1-wide corridor u=0."""
    rw, rh = SUITE[_size("suites", p)]
    out = []
    for i in range(p["n"]):
        k, side = divmod(i, 2)
        s = -1 if side == 0 else 1
        va = (rh + 1) * k + 2
        ua, ub = (-(1 + rw), -2) if s < 0 else (2, 1 + rw)
        out.append((s, ua, va, ub, va + rh - 1))
    return out


def suites(p: dict) -> Plan:
    """Large or grand bedrooms (FR-102): rooms of 4x4 / 5x5 with bed, chest, cabinet, table and chair (grand: a statue)
    on both sides of a corridor behind a door; one bedroom zone each; stage 2 smooths and engraves them."""
    P = _new("suites", p)
    rw, rh = SUITE[_size("suites", p)]
    rs = suite_rooms(p)
    bottom = max(r[4] for r in rs)
    box = (-(1 + rw), 2, 1 + rw, bottom)
    if p["stage"] == 2:
        _beauty(P, [r[1:] for r in rs])
        _room(P, "suites", p, box)
        return P
    d = P.stage("dig", "dig").rect(0, 1, 0, bottom, 0)
    b = P.stage("build", "build", orders=1).tile(0, 1, 0, "d")
    z = P.stage("zone", "zone")
    grand = p["size"] == "grand"
    for s, ua, va, ub, vb in rs:
        mid = va + rh // 2
        d.rect(ua, va, ub, vb, 0).tile(s, mid, 0, "d")

        def at(i, j):                                # column i from the door side, row j
            return s * (2 + i), va + j
        b.tile(s, mid, 0, "d")
        for (i, j), key in (((rw - 1, 0), "b"), ((rw - 2, 0), "h"), ((rw - 1, rh - 1), "f"),
                            ((0, rh - 1), "t"), ((1, rh - 1), "c")):
            b.tile(*at(i, j), 0, key)
        if grand:
            b.tile(*at(rw - 1, rh // 2), 0, "s")    # statue in the far wall's middle: the bed side stays free
        z.ent(ua, va, ub, vb, 0, "b")
    _room(P, "suites", p, box)
    return P


# ---------------------------------------------------------------- grand dining hall / tavern
def _hall(tpl: str, p: dict, zprops: str) -> Plan:
    """A dining hall wider all round than rooms.dining by a margin ring (large 1 tile: a walking lane; grand 2 tiles:
    statues along the outer ring, the lane inside it), table + chair rows beside a centre aisle; large: cabinets in the
    far corners."""
    P = _new(tpl, p)
    m = 1 if _size(tpl, p) == "large" else 2
    cols, W, H = rooms._seat_box(p["seats"], 8)
    u0, v0 = -((W + 2 * m) // 2), 2
    box = (u0, v0, u0 + W + 2 * m - 1, v0 + H + 2 * m - 1)
    if p["stage"] == 2:
        _beauty(P, [box])
        _room(P, tpl, p, box)
        return P
    rooms._box(P, W + 2 * m, H + 2 * m)
    inner = (box[0] + m, box[1] + m, box[2] - m, box[3] - m)
    rooms._seats(P, inner, p["seats"], cols)
    b = P.stage("build", "build", orders=1)
    far = [(box[0], box[3]), (box[2], box[3])]
    if m == 2:
        for v in range(box[1] + 1, box[3] + 1, 3):
            b.tile(box[0], v, 0, "s").tile(box[2], v, 0, "s")
    else:
        for u, v in far:
            b.tile(u, v, 0, "f")
    if tpl == "grand_tavern":
        b.tile(box[0] + 1, box[3], 0, "h").tile(box[2] - 1, box[3], 0, "h")     # goblet chests
    _room(P, tpl, p, box, "h", zprops)
    return P


def grand_dining(p: dict) -> Plan:
    """Grand dining hall (FR-102): 40 seats in a hall with a walking ring, cabinets or statues; stage 2 = beauty."""
    return _hall("grand_dining", p, "name=GrandDining")


def grand_tavern(p: dict) -> Plan:
    """Grand tavern (FR-102): the grand hall as a tavern location with goblet chests; stage 2 = beauty."""
    return _hall("grand_tavern", p, "location=tavern name=GrandTavern desired_goblets=20")


# ---------------------------------------------------------------- grand temple
def grand_temple(p: dict) -> Plan:
    """Grand temple (FR-102): a 9x9 / 11x11 general temple, offering place at the far wall, statues; stage 2 = beauty."""
    P = _new("grand_temple", p)
    s = TEMPLE[_size("grand_temple", p)]
    u0, v0 = -(s // 2), 2
    box = (u0, v0, u0 + s - 1, v0 + s - 1)
    if p["stage"] == 2:
        _beauty(P, [box])
        _room(P, "grand_temple", p, box)
        return P
    rooms._box(P, s, s)
    b = P.stage("build", "build", orders=1).tile(0, box[3], 0, "~a")
    spots = [(box[0] + 1, box[3] - 1), (box[2] - 1, box[3] - 1)]
    if p["size"] == "grand":
        mid = (box[1] + box[3]) // 2
        spots += [(box[0] + 1, box[1] + 1), (box[2] - 1, box[1] + 1), (box[0] + 1, mid), (box[2] - 1, mid)]
    for u, v in spots:
        b.tile(u, v, 0, "s")
    _room(P, "grand_temple", p, box, "m", "location=temple name=GrandTemple allow=residents")
    return P


# ---------------------------------------------------------------- deep core (FR-103)
# the vestibule (0,1) gets a door (a stair opening a room of the old core would leave that room unclosed), the shaft
# runs at (0,2); the deep rooms lie south of the shaft's bottom
SHAFT = (0, 2)
HUB = (-3, 3, 3, 9)
DORM = (-13, 3, -5, 9)
WSHOP = (5, 3, 19, 9)
STORE = (-5, 11, 5, 17)
DEEP_DOORS = ((-4, 6), (4, 6), (0, 10))
DEEP_SHOPS = [("wc", "Carpenters", 6, 3), ("wm", "Masons", 10, 3), ("wr", "Craftsdwarfs", 14, 3),
              ("wl", "Still", 6, 7), ("wz", "Kitchen", 10, 7), ("wt", "Mechanics", 14, 7)]
DEEP_PILES = [((-5, 11, -1, 13), "f", "dfllm-deep-food"), ((1, 11, 5, 13), "u", "dfllm-deep-furn"),
              ((-5, 15, -1, 17), "s", "dfllm-deep-stone"), ((1, 15, 5, 17), "w", "dfllm-deep-wood")]
DEEP_BOX = (-13, 3, 19, 17)                     # the deep level's rooms (Z4 box)


def deep_rects(depth: int) -> dict[int, list[tuple[int, int, int, int]]]:
    """Local check rects of a deep core (bp/deep.py): the shaft tile with its ring on every level (the anchor level not
    toward the anchor row, as rooms), the deep rooms with their ring at the bottom."""
    out: dict[int, list] = {0: [(-1, 1, 1, 3)]}
    for w in range(-depth + 1, 0):
        out[w] = [(-1, 1, 1, 3)]
    u0, v0, u1, v1 = DEEP_BOX
    out[-depth] = [(u0 - 1, 1, u1 + 1, v1 + 1)]
    return out


def deepcore(p: dict) -> Plan:
    """Deep core (FR-103): a stair shaft `depth` levels down to a second core (hub, dorm, workshops, stores); stages
    1 dig, 2 furnish, 3 move (stockpiles, dormitory, dining zone, Kern+)."""
    k, D = p["stage"], p["depth"]
    W = -D
    P = Plan(DEEP, "living")
    if k == 1:
        d = P.stage("s1.dig", "dig").tile(0, 1, 0, "d")
        d.stair(*SHAFT, W, 0)
        for r in (HUB, DORM, WSHOP, STORE):
            d.rect(*r, W)
        for u, v in DEEP_DOORS:
            d.tile(u, v, W, "d")
        P.stage("s1.build", "build", orders=1).tile(0, 1, 0, "d")
        P.manifest["zones"] = {"Z4": [[0, 1, 0, 0, 2, 0], [*SHAFT, W, *SHAFT, -1], [*DEEP_BOX[:2], W, *DEEP_BOX[2:], W]]}
        return P
    if k == 2:
        b = P.stage("s2.build", "build", orders=1)
        for u, v in DEEP_DOORS:
            b.tile(u, v, W, "d")
        for i in range(p["beds"]):
            b.tile(DORM[0] + i % 9, DORM[1] if i < 9 else DORM[3], W, "b")
        for u in (-2, 2):
            b.tile(u, 4, W, "c").tile(u, 5, W, "t").tile(u, 7, W, "c").tile(u, 8, W, "t")
        for key, name, u, v in DEEP_SHOPS:
            b.ent(u, v, u + 2, v + 2, W, key)
            P.workshops.append((name, (u + 1, v + 1, W)))
        for sfx, r in (("dorm", DORM), ("wshop", WSHOP), ("store", STORE)):
            P.room(sfx, DEEP, "utility", (r[0], r[1], W, r[2], r[3], W))
        return P
    pl = P.stage("s3.place", "place")
    for (a, b_, c, e), key, name in DEEP_PILES:
        pl.ent(a, b_, c, e, W, key, f"name={name}")
    P.stage("s3.zone", "zone").ent(*DORM, W, "D", "name=DeepDorm").ent(*HUB, W, "h", "name=DeepDining")
    bu = P.stage("s3.burrow", "burrow")
    kern = f"name={p['burrow']} create=true"
    bu.ent(0, 1, 0, 1, 0, "a", kern)
    for w in range(W, 1):
        bu.ent(*SHAFT, *SHAFT, w, "a", kern)
    for r in (HUB, DORM, WSHOP, STORE):
        bu.ent(*r, W, "a", kern)
    for u, v in DEEP_DOORS:
        bu.ent(u, v, u, v, W, "a", kern)
    P.room("hall", DEEP, "used", (HUB[0], SHAFT[1], W, HUB[2], HUB[3], W))
    return P


BUILD = {"suites": suites, "grand_dining": grand_dining, "grand_tavern": grand_tavern, "grand_temple": grand_temple,
         "deepcore": deepcore}
