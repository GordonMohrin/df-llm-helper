"""Fortcore: the doctrine geometry of DESIGN §5.2 as a parametric template (anchor, rotation, depth).

Local frame (rot 0): the anchor is the surface tile at the top of the 3-wide entrance ramp; attackers come
from the north (v < 0), the fort extends south. Levels: w=0 surface, w=-1 gallery level, w=-2 defense level
(ze), core zc = ze - depth, refuge zr = zc - refuge (>= 3 below the core).

Attack path at ze: ramps -> tunnel -> O1 (3x1 drawbridge) -> Z1 bailey with depot -> Z2 trap hall (1 wide,
45 tiles, 8 bends) -> K1 killing field 7x7 (roofed) -> B1 (3x1) -> Z3 gatehouse/barracks (levers of O1 and B1,
military stair alcove) -> B2 (3x1) -> Z4 landing with the civilian stair (levers of B2) -> core level zc ->
refuge zr. The gallery runs at ze along the east side of the field behind constructed fortifications and is
reachable only through a corridor from the military stair alcove in Z3. Live L2: it used to sit at w=-1 above
the field, but that level is reached only by digging upward through the military stair, and DF never digs a
hidden tile above an up stair (the gallery stayed solid rock for three years). Everything is underground, so
walls are natural rock and every area is roofed (the bailey's walls/overhang requirement).

Each doctrine stage is its own project (params.stage 1..4) so the gate gets B1 when stage 2 is done
(CONTRACTS §9.8: split defense geometry). Manifest fragments are cumulative (the §11 merge is idempotent).
Stage 1 digs the future trap-hall route as the entrance tunnel, so no shortcut ever has to be walled off.
Stage 4 arms it with 41 stone-fall traps. Live L2: with the traps inside stages 2-3, buildingplan gave the
scarce mechanisms to the traps and none to the six levers, so the bridges never reached the manifest; bridges,
levers and links now come first and the traps are a project of their own. Live L2/L3: a weapon trap takes any
free weapon (buildingplan's ANY_WEAPON filter: a spare pick, battle axe or crossbow sat in the traps) and
quickfort orders 'iron battle axe' for it (28 MakeWeapon orders a fort without bars never runs); a stone-fall
trap needs only a mechanism (rock), so stage 4 builds no weapon traps. Farm plots (DESIGN §5.2 stage 1) are a
separate `farms` room project: a farm plot needs soil or mud, which the core level usually is not.

Lever rooms (live L3, the S3 fallback): `dfllm-levers` (stage 2, the Z3 strip with the O1 and B1 levers) and
`dfllm-levers-b2` (stage 3, the Z4 landing strip with the B2 levers) are small burrows; gate assigns lever
pullers to them in SIEGE/DRILL/BREACH and siege keeps them in the civ-alert list. Every bridge also gets a
lever inside the refuge (Tiefe+, stage 3, built after the main levers): in BREACH the civ alert holds everybody
in Tiefe+, and with the levers only in Kern+ no civilian could raise B2 (GATE_FAIL no_worker x3 in L3).
"""
from __future__ import annotations

from .primitives import Plan

STAGES = 4
PARAMS = {"stage": (1, 1, STAGES), "depth": (3, 2, 12), "refuge": (3, 3, 8), "beds": (8, 4, 16),
          "retrofit": (0, 0, 2)}     # 1: only the lever rooms up to `stage`; 2: + the refuge levers (_lever_retrofit)
CLASS = {1: "infra", 2: "defense", 3: "defense", 4: "defense"}
ZE, ZG = -2, -1
# trap hall waypoints at ze (1 wide, 45 tiles, 8 bends; parallel runs keep one rock row between them)
HALL = [(0, 17), (0, 18), (6, 18), (6, 20), (-6, 20), (-6, 22), (6, 22), (6, 24), (0, 24), (0, 25)]
FIELD = (-3, 26, 3, 32)               # K1 killing field (u0, v0, u1, v1) at ze
CIV, MIL = (0, 45), (5, 38)            # stair columns
LEVERS = {"O1": [(-4, 36, ZE), (-4, 37, ZE)], "B1": [(-4, 39, ZE), (-4, 40, ZE)],
          "B2": [(-2, 44, ZE), (-2, 46, ZE)]}
FP = {"O1": (-1, 7, 1, 7), "B1": (-1, 34, 1, 34), "B2": (-1, 43, 1, 43)}
ROLE = {"O1": "outer", "B1": "inner", "B2": "core"}
WORKSHOPS = [("wc", "Carpenters", 6, 42), ("wm", "Masons", 10, 42), ("wr", "Craftsdwarfs", 14, 42),
             ("wl", "Still", 6, 46), ("wz", "Kitchen", 10, 46),
             ("wt", "Mechanics", 14, 46),   # live L1: the well needs a mechanism; nothing else makes one in stage 1
             ("wu", "Butchers", 17, 42)]    # live L6: a famine beside grazers and no butcher's shop (year-1 P0)
DOORS = ((-4, 45), (4, 45), (0, 41), (6, 37))         # core hub -> dorm, workshops, stores; stores -> refuse
CORE = (-13, 34, 19, 48)                              # core level rect (u0, v0, u1, v1): Z4 and Kern+


def hall_tiles() -> list[tuple[int, int]]:
    """Ordered trap-hall tiles from the bailey exit to the field entry."""
    out = [HALL[0]]
    for (ua, va), (ub, vb) in zip(HALL, HALL[1:]):
        du, dv = (ub > ua) - (ub < ua), (vb > va) - (vb < va)
        u, v = ua, va
        while (u, v) != (ub, vb):
            u, v = u + du, v + dv
            out.append((u, v))
    return out


def hall_segments() -> list[list[int]]:
    """Z2 = one exact 1-wide bbox per segment (corner tiles counted once)."""
    segs = []
    for i, ((ua, va), (ub, vb)) in enumerate(zip(HALL, HALL[1:])):
        if i > 0:                      # drop the shared corner tile
            du, dv = (ub > ua) - (ub < ua), (vb > va) - (vb < va)
            ua, va = ua + du, va + dv
        segs.append([min(ua, ub), min(va, vb), ZE, max(ua, ub), max(va, vb), ZE])
    return segs


def levels(p: dict) -> tuple[int, int]:
    zc = ZE - p["depth"]
    return zc, zc - p["refuge"]


def build(p: dict) -> Plan:
    stage = p["stage"]
    zc, zr = levels(p)
    if p.get("retrofit"):
        return _lever_retrofit(stage, zc, zr, p["retrofit"])
    plan = Plan("fortcore", CLASS[stage])
    full = Plan("fortcore", CLASS[stage])      # all stages; we keep only the requested one
    _stage1(full, p, zc, zr)
    _stage2(full)
    _stage3(full, zr)
    _stage4(full)
    _lever_rooms(full, zr)
    plan.stages = [s for s in full.stages if s.label.startswith(f"s{stage}.")]
    plan.manifest = _lever_manifest(_manifest(stage, zc, zr), stage, zr)
    plan.rooms = [r for r in full.rooms if r["stage"] <= stage]
    plan.workshops = full.workshops
    return plan


def _stage1(P: Plan, p: dict, zc: int, zr: int) -> None:
    d = P.stage("s1.dig", "dig")
    d.rect(-1, 0, 1, 0, 0, "h")                          # surface channel -> ramps at w=-1
    d.rect(-1, 1, 1, 2, -1).rect(-1, 3, 1, 3, -1, "h")   # tunnel at w=-1, channel -> ramps at ze
    d.rect(-1, 4, 1, 7, ZE)                              # tunnel + O1 footprint
    d.rect(-4, 8, 4, 16, ZE)                             # Z1 bailey
    d.path(HALL, ZE)                                     # Z2 route (armed in stages 2-3)
    d.rect(0, FIELD[1], 0, FIELD[3], ZE)                 # 1-wide path through the future field
    d.rect(-1, 33, 1, 34, ZE)                            # passage + B1 footprint
    d.rect(-4, 35, 4, 41, ZE)                            # Z3 gatehouse
    d.stair(*MIL, ZE, ZG)                                # military stair (alcove at ze)
    d.rect(-1, 42, 1, 43, ZE)                            # passage + B2 footprint
    d.rect(-2, 44, 2, 46, ZE)                            # Z4 landing
    d.stair(*CIV, zr, ZE)                                # civilian stair down to the refuge level
    # core level; farms are their own `farms` project: quickfort builds farm plots only on soil or mud
    # (build.lua:102-104) and counts every other tile as build_unsuitable, which would block this stage
    d.rect(-3, 42, 3, 48, zc)                            # hub (its south wall stays rock for a farms room)
    for u, v in DOORS:
        d.tile(u, v, zc, "d")                            # doorways
    d.rect(-13, 42, -5, 48, zc).rect(5, 42, 19, 48, zc)  # dorm, workshops
    d.rect(-5, 34, 5, 40, zc)                            # stores
    d.rect(7, 35, 11, 39, zc)                            # refuse/corpses (behind a door, away from the dorm)
    d.tile(*CIV, zc, "i")
    d.tile(-2, 43, zc, "h").tile(-1, 43, zc, "h")        # well spot: well + pond hole over a 2-tile sump
    b = P.stage("s1.build", "build", orders=1)
    b.ent(-2, 10, 2, 14, ZE, "D")                        # trade depot in the bailey
    for key, name, u, v in WORKSHOPS:
        b.ent(u, v, u + 2, v + 2, zc, key)
        P.workshops.append((name, (u + 1, v + 1, zc)))
    for i in range(p["beds"]):
        b.tile(-13 + i % 8, 42 if i < 8 else 48, zc, "b")
    for u, v in DOORS:
        b.tile(u, v, zc, "d")
    b.tile(-2, 43, zc, "l")
    pl = P.stage("s1.place", "place")
    pl.ent(-5, 34, -1, 36, zc, "f").ent(1, 34, 5, 36, zc, "w")
    pl.ent(-5, 38, -1, 40, zc, "s").ent(1, 38, 5, 40, zc, "u")
    pl.ent(7, 35, 11, 39, zc, "yr")
    # live L1 (STATUS §6.4/§6.6): the trade pile next to the depot feeds caravans (autotrade, baseline
    # registers it by name too); the melt pile takes goblinite (automelt)
    pl.ent(-4, 15, 4, 16, ZE, "g", "name=dfllm-trade autotrade=true")
    pl.ent(-4, 8, 4, 8, ZE, "pd", "name=dfllm-melt automelt=true")
    z = P.stage("s1.zone", "zone")
    z.ent(-13, 42, -5, 48, zc, "D").ent(-3, 42, 3, 48, zc, "m")
    z.ent(-1, 43, -1, 43, zc, "p", "pond=true")
    k = P.stage("s1.burrow", "burrow")
    kern = "name=Kern+ create=true"
    k.ent(-4, 35, 5, 41, ZE, "a", kern).ent(-1, 42, 1, 43, ZE, "a", kern).ent(-2, 44, 2, 46, ZE, "a", kern)
    for w in range(zr + 1, ZE):
        k.ent(*CIV, *CIV, w, "a", kern)
    k.ent(*CORE, zc, "a", kern)
    for sfx, bb in (("dorm", (-13, 42, -5, 48)), ("wshop", (5, 42, 19, 48)),
                    ("store", (-5, 34, 5, 40)), ("refuse", (7, 35, 11, 39))):
        P.room(sfx, "fortcore", "utility", (bb[0], bb[1], zc, bb[2], bb[3], zc))
        P.rooms[-1]["stage"] = 1


def _stage2(P: Plan) -> None:
    u0, v0, u1, v1 = FIELD
    d = P.stage("s2.dig", "dig", defense=1)
    d.rect(u0, v0, -1, v1, ZE).rect(1, v0, u1, v1, ZE)                       # full killing field
    for u in (-3, -2, -1, 1, 2, 3):
        d.tile(u, v0 - 1, ZE, "s")                                            # smooth north wall
    for u in (-3, -2, 2, 3):
        d.tile(u, v1 + 1, ZE, "s")                                            # smooth south wall
    d.rect(u0 - 1, v0, u0 - 1, v1, ZE, "s")                                   # smooth west wall
    d.rect(u1 + 1, v0, u1 + 2, v1, ZE)                                        # F line + gallery (same level)
    d.rect(5, v1 + 1, 5, MIL[1] - 1, ZE)                                      # gallery corridor to the alcove
    b = P.stage("s2.build", "build", orders=1, defense=1)
    b.ent(*FP["B1"], ZE, "g", dir="N")
    for u, v, w in LEVERS["B1"]:
        b.tile(u, v, w, "Tl")
    b.rect(u1 + 1, v0, u1 + 1, v1, ZE, "CF")                                  # fortifications toward K1
    for key, u, v in (("r", 4, 35), ("r", 4, 36), ("a", 4, 40), ("a", 4, 41), ("h", -3, 41), ("h", 3, 41)):
        b.tile(u, v, ZE, key)
    P.stage("s2.zone", "zone").ent(-4, 35, 4, 41, ZE, "B")


def _stage3(P: Plan, zr: int) -> None:
    d = P.stage("s3.dig", "dig", defense=1)
    d.rect(-4, 42, 4, 48, zr).tile(*CIV, zr, "u")
    d.tile(-2, 43, zr, "h").tile(-1, 43, zr, "h")                             # refuge well spot
    b = P.stage("s3.build", "build", orders=1, defense=1)
    b.ent(*FP["O1"], ZE, "g", dir="N").ent(*FP["B2"], ZE, "g", dir="N")
    for n in ("O1", "B2"):
        for u, v, w in LEVERS[n]:
            b.tile(u, v, w, "Tl")
    for u in range(-4, 4):
        b.tile(u, 48, zr, "b")
    b.tile(-2, 43, zr, "l")
    P.stage("s3.place", "place").ent(2, 46, 4, 47, zr, "f")
    z = P.stage("s3.zone", "zone")
    z.ent(-4, 42, 4, 48, zr, "D").ent(-1, 43, -1, 43, zr, "p", "pond=true")
    P.stage("s3.burrow", "burrow").ent(-4, 42, 4, 48, zr, "a", "name=Tiefe+ create=true")
    P.room("refuge", "fortcore", "utility", (-4, 42, zr, 4, 48, zr))
    P.rooms[-1]["stage"] = 3


def _stage4(P: Plan) -> None:
    """Arm the trap hall: a stone-fall trap on every trap tile (41). No weapon traps: buildingplan fills a weapon
    trap with any free weapon (picks, battle axes, crossbows; live L2) and quickfort's orders for them are iron
    battle axes; the stage's only orders are mechanisms (rock)."""
    b = P.stage("s4.build", "build", orders=1, defense=1)
    for u, v in _trap_tiles(2) + _trap_tiles(3):
        b.tile(u, v, ZE, "Ts")


def _trap_tiles(stage: int) -> list[tuple[int, int]]:
    t = hall_tiles()[2:-2]                      # keep the bailey exit and the field entry free
    first = [x for i, x in enumerate(t) if i % 3 == 0]
    return first if stage == 2 else [x for i, x in enumerate(t) if i % 3 != 0]


def _manifest(stage: int, zc: int, zr: int) -> dict:
    u0, v0, u1, v1 = FIELD
    m: dict = {"v": 2,
               "burrows": {"Kern+": {"role": "kern"}},
               "edge": [[u, -2, 0] for u in (-1, 0, 1)],
               "stairs": {"civ": [[*CIV, zr, ZE]], "mil": [[*MIL, ZE, ZG]]},
               "zones": {"Z1": [[-4, 8, ZE, 4, 16, ZE]], "Z2": hall_segments(),
                         "Z3": [[-4, 35, ZE, 4, 41, ZE], [*MIL, ZE, *MIL, ZE]],
                         "Z4": [[-2, 44, ZE, 2, 46, ZE], [*CIV, zr + 1, *CIV, ZE - 1],
                                [CORE[0], CORE[1], zc, CORE[2], CORE[3], zc], [-2, 43, zc - 1, -1, 43, zc - 1]]},
               "depot": [0, 12, ZE]}
    bridges = []
    if stage >= 2:
        bridges.append("B1")
        m["stations"] = {"melee": [0, 36, ZE], "gallery": [5, 29, ZE]}
        m["killboxes"] = [{"id": "K1", "bbox": [u0, v0, ZE, u1, v1, ZE]}]
    if stage >= 3:
        bridges += ["O1", "B2"]
        m["stations"]["b2"] = [1, 44, ZE]
        m["burrows"]["Tiefe+"] = {"role": "refuge"}
        m["refuge"] = {"anchor": [2, 45, zr], "burrow": "Tiefe+"}
    if bridges:
        m["bridges"] = {n: {"role": ROLE[n], "fp": [FP[n][0], FP[n][1], ZE, FP[n][2], FP[n][3], ZE],
                            "levers": [list(x) for x in LEVERS[n]]} for n in sorted(bridges)}
    return m


# ---------------------------------------------------------------- lever rooms and refuge levers (live L3)
# Lever rooms: name -> (stage, (u0, v0, u1, v1)) at ze. gate assigns lever pullers (the burrow screen's unit
# assignment) to the rooms whose bridges the mode raises and pulls a lever in a room with a puller present
# first; siege keeps the rooms in the civ-alert list (in BREACH only the rooms behind the core seal B2).
LEVER_ROOMS = {"dfllm-levers": (2, (-4, 35, -3, 41)),        # Z3 strip west of the gate road: O1 + B1 levers
               "dfllm-levers-b2": (3, (-2, 44, -1, 46))}     # Z4 landing strip west of the civ stair: B2 levers
# one more lever per bridge on the refuge level (zr), inside Tiefe+, east of the civilian stair: BREACH holds
# every civilian in Tiefe+ (live L3: GATE_FAIL no_worker for O1, B1 and B2). Their own build stage, the last of
# stage 3, so buildingplan gives the first mechanisms to the main levers (live L2); the runner merges the stage-3
# manifest (O1, B2) when the project is done, i.e. after these three levers (one mechanism each; their links,
# two mechanisms each, are gate's later jobs).
REFUGE_LEVERS = {"B2": (4, 43), "O1": (4, 44), "B1": (4, 45)}


def refuge_levers(zr: int) -> dict[str, tuple[int, int, int]]:
    return {n: (u, v, zr) for n, (u, v) in REFUGE_LEVERS.items()}


def _lever_rooms(P: Plan, zr: int) -> None:
    for name, (stage, (u0, v0, u1, v1)) in LEVER_ROOMS.items():
        P.stage(f"s{stage}.burrow", "burrow").ent(u0, v0, u1, v1, ZE, "a", f"name={name} create=true")
    lv = P.stage("s3.lever", "build", orders=1, defense=1)
    for u, v, w in refuge_levers(zr).values():
        lv.tile(u, v, w, "Tl")


def _lever_manifest(m: dict, stage: int, zr: int) -> dict:
    for name, (st, _) in LEVER_ROOMS.items():
        if stage >= st:
            m["burrows"][name] = {"role": "other"}
    if stage >= 3:
        for n, p in refuge_levers(zr).items():
            m["bridges"][n]["levers"].append(list(p))
        ps = sorted(refuge_levers(zr).values())
        m["zones"]["Z4"].append([min(p[0] for p in ps), min(p[1] for p in ps), zr,
                                 max(p[0] for p in ps), max(p[1] for p in ps), zr])    # levers lie in Z4 (audit)
    return m


def _lever_retrofit(stage: int, zc: int, zr: int, kind: int) -> Plan:
    """For a fort whose stages up to `stage` are done and were placed before live L3 (Castlerisen); the runner
    records the project as fortcore stage `stage` reached. Re-placing whole stages would re-apply their zone
    stages (barracks, refuge dormitory, pond).
    `retrofit=1` (stage 2 or 3): only the lever rooms of the stages up to `stage`, a burrow-only project that is
    done in one runner pass; its manifest fragment is just the rooms (`burrows`), so it never replaces a bridge's
    lever list whatever order the projects finish in. Place it first: gate sees the rooms (pullers, the B2 room as
    the BREACH fallback) at once instead of after three mechanisms.
    `retrofit=2` (stage 3): the rooms again (idempotent) plus the refuge levers; its fragment is the stage's full
    one with the refuge levers (the §11 merge is idempotent), merged when the levers are built."""
    if stage not in (2, 3) or (kind == 2 and stage != 3):
        # stage 4 would mark the trap stage as reached (runner history: params.stage, labels)
        raise ValueError("fortcore retrofit: 1 = lever rooms (stage 2 or 3), 2 = rooms + refuge levers (stage 3)")
    plan = Plan("fortcore", CLASS[stage])
    k = plan.stage(f"s{stage}.lrooms", "burrow")
    for name, (st, (u0, v0, u1, v1)) in LEVER_ROOMS.items():
        if st <= stage:
            k.ent(u0, v0, u1, v1, ZE, "a", f"name={name} create=true")
    if kind == 1:
        plan.manifest = {"v": 2, "burrows": {n: {"role": "other"} for n, (st, _) in LEVER_ROOMS.items() if st <= stage}}
        return plan
    lv = plan.stage("s3.lever", "build", orders=1, defense=1)
    for u, v, w in refuge_levers(zr).values():
        lv.tile(u, v, w, "Tl")
    plan.manifest = _lever_manifest(_manifest(stage, zc, zr), stage, zr)
    return plan
