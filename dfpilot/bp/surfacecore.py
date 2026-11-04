"""Surface core (BUG-387): the fort's core on open ground above the aquifer, built from constructed walls.

Run 16 / region1 (aquifer almost everywhere): no fort got a dug fortcore ('no dry fortcore site', depth=1 breached
heavy_aquifer at 4 %, sites 1-6 steps from water), so every room template that hangs on the dug Z4 core stood still for
years. This template needs no dig: a walled compound on flat open surface floor on the citizens' walk group, with the same
manifest roles as the fortcore, so seal, gate, readiness, the depot keeper and the rooms' sites work on it.

Local frame (rot 0): the anchor is the north-west corner of the block (like the surface depot and farms). The block is
`w` wide and `h + APRON` tall:

    v 0..4         trade depot (5x5) in front of the gate, a caravan's wagon reaches it
    v APRON        north wall with the gate (a door), the only way in
    v APRON+1..    interior (Kern+): dormitory beds, stockpiles (food, wood, stone, furniture, refuse)
    south-east     the refuge (Tiefe+): a 7x5 room inside its own walls, one door to Kern+, beds

Everything is a constructed wall (`Cw`) on existing floor, one door each: no rock to dig, no breach to meet. It is a weaker
shell than the dug core (no bridge, no trap hall: the fort defends with its squads and the doors); the manifest says so by
listing no bridge. The rooms that hang on a core (dining, bedrooms, tavern, office) get a surface variant (`surface=1`,
bp/rooms.py) that sites.rank places beside this block.
"""
from __future__ import annotations

from .primitives import Plan

PARAMS = {"w": (21, 20, 31), "h": (15, 12, 21), "beds": (8, 2, 16)}
APRON = 6               # rows north of the compound: the depot (5 rows) and one free row before the gate
DEPOT_SIDE = 5
REFUGE_W, REFUGE_H = 7, 5


def block(p: dict) -> tuple[int, int]:
    """(width, height) of the whole block, apron included (sites.rank looks for this much open floor)."""
    return p["w"], p["h"] + APRON


def surfacecore(p: dict) -> Plan:
    """Walled compound on open surface floor: gate, Kern+ with dormitory and stockpiles, a walled refuge Tiefe+, a depot."""
    W, H = p["w"], p["h"]
    T, B = APRON, APRON + H - 1                        # north (gate) wall row, south wall row
    gate = W // 2
    rx0, ry0 = W - 2 - REFUGE_W + 1, B - REFUGE_H     # refuge interior north-west corner
    P = Plan("surfacecore", "infra")
    w = P.stage("s1.walls", "build", orders=1)                             # walls first: quickfort refuses a door beside none
    w.rect(0, T, W - 1, T, 0, "Cw").rect(0, B, W - 1, B, 0, "Cw")          # north and south walls
    w.rect(0, T, 0, B, 0, "Cw").rect(W - 1, T, W - 1, B, 0, "Cw")          # west and east walls
    w.rect(rx0 - 1, ry0 - 1, W - 2, ry0 - 1, 0, "Cw").rect(rx0 - 1, ry0, rx0 - 1, B - 1, 0, "Cw")   # the refuge's own walls
    door = rx0 - 1, ry0 + REFUGE_H // 2
    w.tile(gate, T, 0, "").tile(*door, 0, "")                              # the doorways stay open for the doors
    b = P.stage("s1.build", "build", orders=1)
    b.tile(gate, T, 0, "d").tile(*door, 0, "d")     # the gate; the refuge's door to Kern+
    b.ent(gate - 2, 0, gate + 2, DEPOT_SIDE - 1, 0, "D")                   # the trade depot in front of the gate
    for i in range(p["beds"]):                                             # dormitory: two rows of beds in the interior
        b.tile(1 + i % 8, T + 1 if i < 8 else T + 3, 0, "b")
    for i in range(min(p["beds"], 8)):                                     # the refuge's beds along its north wall
        b.tile(rx0 + i % REFUGE_W, ry0 + i // REFUGE_W, 0, "b")
    pl = P.stage("s1.place", "place")
    pl.ent(1, T + 5, 5, T + 7, 0, "f").ent(6, T + 5, 10, T + 7, 0, "w")
    pl.ent(1, T + 8, 5, T + 10, 0, "s").ent(6, T + 8, 10, T + 10, 0, "u")
    pl.ent(W - 8, T + 2, W - 4, T + 4, 0, "yr")
    pl.ent(gate + 3, 0, gate + 6, 1, 0, "g", "name=dfllm-trade autotrade=true")   # the trade pile beside the depot
    z = P.stage("s1.zone", "zone")
    z.ent(1, T + 1, 8, T + 3, 0, "D")                                      # dormitory zone over the bed rows
    k = P.stage("s1.burrow", "burrow")
    kern = "name=Kern+ create=true"
    k.ent(1, T + 1, rx0 - 2, B - 1, 0, "a", kern)                          # west part of the interior
    k.ent(rx0 - 1, T + 1, W - 2, ry0 - 2, 0, "a", kern)                    # the strip north of the refuge
    k.ent(gate, T, gate, T, 0, "a", kern)                                  # the gate tile
    k.ent(rx0 - 1, ry0, W - 2, B - 1, 0, "a", "name=Tiefe+ create=true")  # the refuge room and its door
    P.room("refuge", "surfacecore", "utility", (rx0, ry0, 0, W - 2, B - 1, 0))
    P.manifest = {"v": 2,
                  "burrows": {"Kern+": {"role": "kern"}, "Tiefe+": {"role": "refuge"}},
                  "edge": [[gate, T - 1, 0]],
                  "zones": {"Z4": [[1, T + 1, 0, W - 2, B - 1, 0]]},
                  "refuge": {"anchor": [rx0 + REFUGE_W // 2, ry0 + REFUGE_H // 2, 0], "burrow": "Tiefe+"},
                  "depot": [gate, DEPOT_SIDE // 2, 0]}
    return P
