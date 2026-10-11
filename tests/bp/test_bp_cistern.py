"""Live L3 water package: the `cistern` template (well room over a cistern, optional pipe from a revealed brook or
river with floodgate, pressure breaker and fortification), the route planner, the offline water checks and the
water preference of the fortcore site ranking."""
import copy
import json

import pytest

from df_llm_helper import bp, schema as S
from df_llm_helper.bp import rooms, sites, topo
from df_llm_helper.bp.primitives import Xform, merge_manifest, parse_cell
from df_llm_helper.bp.render import World, cell_rects

from bp_fixtures import SITE, fort_docs, terrain

PIPE = {"path": "1,6;1,12;8,12", "rise": 3, "side": "E", "water": "bed"}


def cells(doc, mode=None):
    return [(st["label"], st["mode"], k, (x0, y0, z), (x1 - x0 + 1, y1 - y0 + 1))
            for st, k, _, x0, y0, x1, y1, z in cell_rects(doc) if mode is None or st["mode"] == mode]


def brook_fort():
    """The synthetic fort (fortcore 1-4, refuge z2) with a brook at x=20: bed water z9 under the walkable
    brook top z10 (the live Castlerisen brook: water in the bed, brook top '.' above)."""
    t = terrain(river=False, trees=False)
    for y in range(30, 100):
        t.set(20, y, 9, "~")
    land = t.snapshot(purpose="sites")
    docs = fort_docs()
    w = bp.as_built(docs, base=land)
    return land, docs, w.snapshot(purpose="sites"), w.manifest


@pytest.fixture(scope="module")
def planned():
    land, docs, snap, man = brook_fort()
    plan = sites.plan_cistern(snap, man, "refuge", burrow="Tiefe+", safe=False)
    return land, docs, snap, man, plan


def valley():
    """Castlerisen's case: the well room on a level whose floor is the brook bed's level (refuge z116, brook
    bed z116, brook top z117). Rock below z6, the surface z6, a brook bed at z5/x=10 under its brook top,
    a corridor at z5 (Z4) under the surface."""
    w = World([0, 0, 0, 59, 29, 8], fill="?")
    for z in (7, 8):
        for y in range(30):
            for x in range(60):
                w.set(x, y, z, "_")
    for y in range(30):
        for x in range(60):
            w.set(x, y, 6, ".")
        w.set(10, y, 5, "~")
    for x in range(40, 51):
        w.set(x, 15, 5, ".")
    man = {"v": 2, "zones": {"Z4": [[40, 15, 5, 50, 15, 5]]}}
    return w.snapshot(purpose="sites"), man


# ---------------------------------------------------------------- template
def test_dry_cistern_is_a_bucket_filled_well_room():
    d = bp.emit("cistern", {}, SITE)
    assert [s["label"] for s in d["stages"]] == ["dig", "build", "zone", "burrow"]
    assert d["materials"] == {"door": 1, "well": 1}
    assert ("zone", "zone", "p", (71, 73, 100), (1, 1)) in cells(d)            # pond hole: bucket carriers fill it
    assert d["manifest"]["rooms"][0]["tpl"] == "cistern" and d["manifest"]["rooms"][0]["use"] == "utility"
    assert d["manifest"]["zones"]["Z4"] == [[69, 71, 99, 71, 74, 100]]          # doorway, room and cistern
    w = bp.as_built(d)
    assert w.errors == [] and w.get(70, 73, 100) == "_" and w.get(70, 73, 99) == "."
    assert sites.cistern_findings(d) == []                                    # no intake: nothing to check


def test_intake_stages_parts_and_markers():
    d = bp.emit("cistern", PIPE, SITE)
    assert S.validate("bp", {**d, "id": "c1"}) == [] and bp.check_doc(d) == []
    labels = [s["label"] for s in d["stages"]]
    # the water source zone first; the floodgate (stage gate) after the fortification (stage build); pipe and
    # shaft leave every burrow before the breach
    assert labels == ["water", "dig", "build", "gate", "shaft", "unburrow", "breach", "burrow"]
    builds = {k for _, m, k, *_ in cells(d, "build")}
    assert {"x", "CF", "Tl", "l", "d"} <= builds
    assert [c[2] for c in cells(d) if c[0] == "gate"] == ["x"]
    assert "x" not in {c[2] for c in cells(d) if c[0] == "build"}
    assert d["materials"]["fortification"] == 1 and d["materials"]["mechanism"] == 3
    shaft = sorted(cells(d), key=lambda c: c[3][2])
    keys = [c[2] for c in shaft if c[0] == "shaft"]
    assert keys == ["mdu", "mdi", "mdi", "mdj"]                                # dug top-down, damp-dig markers
    assert [c[2] for c in cells(d) if c[0] == "breach"] == ["mdh"]
    zones = [c for c in cells(d) if c[0] == "water"]
    assert [c[2] for c in zones] == ["w", "w"]                                 # brook bed and brook top
    L = rooms.cistern_layout(bp.check_params("cistern", PIPE))
    X = Xform(SITE["anchor"], 0)
    assert {c[3] for c in zones} == {X.pos(*L["water"][0][:2], L["water"][0][2]), X.pos(*L["water"][1][:2],
                                                                                         L["water"][1][2])}
    # the floodgate sits right before the fortification: no pipe segment between two seals
    assert L["gate"] == (6, 12) and L["barrier"] == (7, 12) and L["shaft"] == (8, 12)
    assert L["breach"] == (9, 12, 2) and L["water"] == [(10, 12, 1), (10, 12, 2)]
    assert L["pond"] is None and ("dig", "dig", "h", X.pos(*rooms.CISTERN_POND, 0), (1, 1)) not in cells(d)


@pytest.mark.parametrize("params", [{}, PIPE])
def test_a_stair_is_the_way_down_and_back_up(params):
    """Review: a DF ramp climbs only onto the floor above an adjacent wall; the ramps under the holes of a dug-out
    3x3 cistern have none, so the miner who dug the last tile was shut in, and the well closed its hole for good
    (nobody could build the floodgate, the fortification or the lever link below)."""
    d = bp.emit("cistern", params, SITE)
    X = Xform(SITE["anchor"], 0)
    u, v = rooms.CISTERN_STAIR
    assert ("dig", "dig", "j", X.pos(u, v, 0), (1, 1)) in cells(d)
    assert ("dig", "dig", "u", X.pos(u, v, -1), (1, 1)) in cells(d)
    w = bp.as_built([sites._plain(d)])
    assert w.get(*X.pos(u, v, 0)) == ">" and w.get(*X.pos(u, v, -1)) == "<"
    assert "shut_in" not in {f.code for f in sites.cistern_findings(d)}
    ramps_only = _without(_without(d, "u"), "j")
    found = [f for f in sites.cistern_findings(ramps_only) if f.code == "shut_in"]
    assert found and found[0].level == "error"


def test_a_floodgate_at_the_cistern_end_would_seal_the_pipe(planned):
    """Review: with the floodgate on the first pipe tile, the pipe between it and the fortification has no way
    out; whoever hauled a boulder there when the second seal was built drowned at the breach."""
    land, docs, snap, man, plan = planned
    doc = bp.emit("cistern", plan["params"], plan["site"])
    assert "shut_in" not in {f.code for f in sites.cistern_findings(docs + [doc], base=land)}
    X = Xform(plan["site"]["anchor"], plan["site"]["rot"])
    old = copy.deepcopy(doc)
    (gate,) = [s for s in old["stages"] if s["label"] == "gate"]
    gate["chunks"][0]["pos"] = list(X.pos(*rooms.CISTERN_START, -1))
    found = [f for f in sites.cistern_findings(docs + [old], base=land) if f.code == "shut_in"]
    assert found and "cut off" in found[0].msg


@pytest.mark.parametrize("path", ["1,6;1,12;8,12", "1,6;1,9;4,9;4,14;9,14"])
def test_pipe_and_shaft_leave_every_burrow(path):
    """Review: the burrow plugin grows '+' burrows over each dug tile beside them; a pipe dug out of the cistern
    joined Kern+ up to the shaft bottom outside the fortification, where any wild animal would count as a
    hostile inside Kern+ (BREACH)."""
    p = {**PIPE, "path": path}
    d = bp.emit("cistern", p, SITE)
    assert bp.check_doc(d) == [] and bp.errors(bp.validate(d)) == []
    L = rooms.cistern_layout(bp.check_params("cistern", p))
    X = Xform(SITE["anchor"], 0)
    erased = []
    for st, k, props, x0, y0, x1, y1, z in cell_rects(d):
        if st["label"] == "unburrow":
            assert st["mode"] == "burrow" and k == "e" and not props        # no name: every burrow
            erased += [(x, y, z) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
    assert len(erased) == len(set(erased))                                  # no cell twice
    want = {X.pos(u, v, -1) for u, v in L["pipe"][1:] + [L["shaft"]]}
    want |= {X.pos(*L["shaft"], w) for w in range(0, L["w_top"] + 1)}
    assert set(erased) == want
    assert X.pos(*rooms.CISTERN_SPILL, -1) not in erased                   # the spill is the cistern's own
    labels = [s["label"] for s in d["stages"]]
    assert labels.index("shaft") < labels.index("unburrow") < labels.index("breach")


def test_the_floodgate_comes_after_the_fortification():
    d = bp.emit("cistern", PIPE, SITE)
    assert "build_order" not in {f.code for f in sites.cistern_findings(d)}
    one = copy.deepcopy(d)
    (build,) = [s for s in one["stages"] if s["label"] == "build"]
    (gate,) = [s for s in one["stages"] if s["label"] == "gate"]
    build["chunks"] += gate["chunks"]
    one["stages"].remove(gate)
    assert "build_order" in {f.code for f in sites.cistern_findings(one)}


def test_the_pipe_never_joins_z4():
    """Z4 counts as the fort's interior in the audit: a Z4 box over the brook bank would read as a bypass."""
    d = bp.emit("cistern", PIPE, SITE)
    (z4,) = d["manifest"]["zones"]["Z4"]
    assert z4 == [69, 71, 99, 71, 74, 100]
    far = [c for c in cells(d) if c[0] in ("shaft", "breach", "water")]
    assert far and all(not (z4[0] <= p[0] <= z4[3] and z4[1] <= p[1] <= z4[4]) for *_, p, _ in far)


@pytest.mark.parametrize("rot", range(4))
def test_intake_rotates(rot):
    d = bp.emit("cistern", PIPE, {**SITE, "rot": rot})
    assert bp.errors(bp.validate(d)) == []
    assert sites.cistern_findings(d) == [] or {f.code for f in sites.cistern_findings(d)} <= {"pressure"}
    assert d["materials"] == bp.emit("cistern", PIPE, SITE)["materials"]


@pytest.mark.parametrize("bad,msg", [
    ({"path": "0,6;0,12"}, "start at 1,6"),
    ({"path": "1,6;3,9"}, "not orthogonal"),
    ({"path": "1,6;1,7"}, "at least 3"),
    ({"path": "1,6;1,12;3,12;3,8;2,8"}, "touch"),                 # loops back beside its own start
    ({"path": "1,6;2,6;2,4"}, "touches the cistern"),
    ({"path": "1,6;1,12;8,12", "side": "W"}, "touches the pipe"),  # the breach would be the barrier tile
    ({"path": "1,6;1,12;8,12", "side": "Q"}, "side"),
    ({"path": "1,6;1,12;8,12", "water": "lake"}, "water"),
    ({"path": "1,6;1,12;8,12", "level": "attic"}, "level"),
    ({"path": "1,6;x"}, "bad waypoint"),
    ({"path": "1,6;3,6;3,4", "side": "N", "rise": 1}, "next to the well room"),
    ({"path": "1,6;0,6;0,9"}, "corner of the breaker"),
])
def test_layout_rejects(bad, msg):
    with pytest.raises(ValueError, match=msg):
        bp.emit("cistern", bad, SITE)


# ---------------------------------------------------------------- planner and checks on a fort
def test_planner_routes_the_refuge_well_to_the_brook(planned):
    land, docs, snap, man, plan = planned
    p, site = plan["params"], plan["site"]
    assert p["level"] == "refuge" and p["burrow"] == "Tiefe+" and p["water"] == "bed"
    x0, y0, x1, y1 = sites.refuge_rooms(man)[0][0], sites.refuge_rooms(man)[0][1], \
        sites.refuge_rooms(man)[0][3], sites.refuge_rooms(man)[0][4]
    ax, ay, az = site["anchor"]
    assert az == man["refuge"]["anchor"][2] and x0 <= ax <= x1 and y0 <= ay <= y1
    assert p["rise"] == 10 - (az - 1)                              # pipe below the refuge up to the bank z10
    doc = bp.emit("cistern", p, site)
    L = rooms.cistern_layout(p)
    X = Xform(site["anchor"], site["rot"])
    assert X.pos(*L["water"][0][:2], az + L["water"][0][2])[0] == 20     # the zone sits on the brook
    assert bp.errors(bp.validate(doc)) == []
    found = sites.cistern_findings(docs + [doc], base=land)
    assert [f.code for f in found] == ["pressure"]                 # brook z9 above the refuge: breaker only
    ranked = bp.rank(snap, "cistern", p, manifest=man)
    assert ranked and (ranked[0]["anchor"], ranked[0]["rot"]) == (site["anchor"], site["rot"])
    assert "pipe" in ranked[0]["why"]


def test_cistern_keeps_the_fort_sealed_and_the_refuge_separate(planned):
    land, docs, snap, man, plan = planned
    doc = bp.emit("cistern", plan["params"], plan["site"])
    w = bp.as_built([sites._plain(d) for d in docs + [doc]], base=land)
    res = topo.audit(w.snapshot(), merge_manifest(w.manifest, {}))
    assert res["ok"], res["fails"]
    assert res["refuge_sep"] and not res["bypass"]


def _without(doc, key):
    d = copy.deepcopy(doc)
    for st in d["stages"]:
        for ch in st["chunks"]:
            ch["cells"] = [c for c in ch["cells"] if parse_cell(c[3])[0] != key]
        st["chunks"] = [ch for ch in st["chunks"] if ch["cells"]]
    d["stages"] = [s for s in d["stages"] if s["chunks"]]
    return d


def test_checks_catch_missing_parts_leaks_and_rises(planned):
    land, docs, snap, man, plan = planned
    doc = bp.emit("cistern", plan["params"], plan["site"])
    codes = lambda ds, base=land: {f.code for f in sites.cistern_findings(ds, base=base) if f.level == "error"}  # noqa
    assert codes(docs + [_without(doc, "CF")]) == {"parts", "intake_open", "bypass"}
    assert codes(docs + [_without(doc, "x")]) == {"parts"}
    L = rooms.cistern_layout(plan["params"])
    X = Xform(plan["site"]["anchor"], plan["site"]["rot"])
    mid = L["pipe"][len(L["pipe"]) // 2]
    side = X.pos(mid[0], mid[1] + 1, -1) if X.pos(mid[0], mid[1] + 1, -1) not in \
        {X.pos(u, v, -1) for u, v in L["pipe"]} else X.pos(mid[0] + 1, mid[1], -1)
    leaky = World.from_snapshot(land)
    leaky.set(*side, ".")                                          # an old tunnel beside the pipe
    assert "water_leak" in codes(docs + [doc], leaky.snapshot())
    rise = World.from_snapshot(land)
    rise.set(*X.pos(*mid, 0), "_")                                 # a hole right above the pipe
    assert "water_rise" in codes(docs + [doc], rise.snapshot())
    corner = World.from_snapshot(land)
    corner.set(*X.pos(rooms.CISTERN_START[0], rooms.CISTERN_SPILL[1], -1), ".")   # the breaker's corner open
    assert {"breaker", "water_leak"} <= codes(docs + [doc], corner.snapshot())


def test_planner_needs_revealed_water_and_the_manifest():
    land, docs, snap, man = brook_fort()
    dry = World.from_snapshot(snap)
    for y in range(30, 100):
        dry.set(20, y, 9, "?")
    with pytest.raises(ValueError, match="no revealed water"):
        sites.plan_cistern(dry.snapshot(), man)
    with pytest.raises(ValueError, match="no pipe route"):
        sites.plan_cistern(snap, man)                              # safe: the brook z9 lies above the refuge z2
    with pytest.raises(ValueError, match="manifest"):
        sites.plan_cistern(snap, {"v": 2})
    with pytest.raises(ValueError, match="level"):
        sites.plan_cistern(snap, man, "attic")


def test_planner_detours_around_revealed_open_tiles(planned):
    land, docs, snap, man, plan = planned
    L = rooms.cistern_layout(plan["params"])
    X = Xform(plan["site"]["anchor"], plan["site"]["rot"])
    mid = X.pos(*L["pipe"][len(L["pipe"]) // 2], -1)
    w = World.from_snapshot(snap)
    for d in range(-12, 13):                                       # a revealed cave across every straight route
        w.set(mid[0], mid[1] + d, mid[2], ".")
    again = sites.plan_cistern(w.snapshot(), man, "refuge", burrow="Tiefe+", safe=False)
    doc = bp.emit("cistern", again["params"], again["site"])
    assert again["tiles"] > plan["tiles"]
    ok = World.from_snapshot(land)
    for d in range(-12, 13):
        ok.set(mid[0], mid[1] + d, mid[2], ".")
    assert [f.code for f in sites.cistern_findings(docs + [doc], base=ok.snapshot())] == ["pressure"]


def test_valley_brook_at_the_well_room_level_needs_no_breaker_trust():
    """The live case: brook bed at the well room's own level. Pressure can lift water only to one level below
    the source, i.e. into the cistern level: the well room stays dry even without the breaker."""
    snap, man = valley()
    plan = sites.plan_cistern(snap, man, "core")
    p = plan["params"]
    assert p["water"] == "bed" and p["rise"] == 2 and p["level"] == "core"
    doc = bp.emit("cistern", p, plan["site"])
    assert sites.cistern_findings(doc, base=snap) == []
    assert bp.rank(snap, "cistern", p, manifest=man)[0]["anchor"] == plan["site"]["anchor"]
    assert len(json.dumps(doc)) < S.BP_MAX_BYTES


def test_river_at_bank_level_uses_the_bank_kind():
    snap, man = valley()
    w = World.from_snapshot(snap)
    for y in range(30):
        w.set(10, y, 5, "?")
        w.set(10, y, 6, "~")                                       # water at the bank level, open air above
    with pytest.raises(ValueError, match="no pipe route"):
        sites.plan_cistern(w.snapshot(), man, "core")              # river z6 above the well room z5
    plan = sites.plan_cistern(w.snapshot(), man, "core", safe=False)
    assert plan["params"]["water"] == "bank" and plan["params"]["rise"] == 2
    doc = bp.emit("cistern", plan["params"], plan["site"])
    assert [f.code for f in sites.cistern_findings(doc, base=w.snapshot())] == ["pressure"]


# ---------------------------------------------------------------- CLI (read only)
def _save(tmp_path, monkeypatch, snap, man):
    from df_llm_helper import files
    monkeypatch.setenv("DFLLM_RUNTIME", str(tmp_path))
    sd = tmp_path / "s1"
    (sd / "snap").mkdir(parents=True)
    files.write_json_atomic(sd / "snap" / "sites1.json", snap)
    files.write_json_atomic(sd / ".manifest.json", man)
    return sd


def test_cli_prints_the_label_cmd_place_resolves_to_the_planned_site(planned, tmp_path, monkeypatch, capsys):
    """Review: cmd.place reads S<k> as the k-th ranked site that is free of other projects."""
    from df_llm_helper import cmd as dcmd, files
    land, docs, snap, man, plan = planned
    assert not S.validate("snapshot", snap) and not S.validate("manifest", man)
    sd = _save(tmp_path, monkeypatch, snap, man)
    assert sites.main(["cistern", "--save", "s1", "--unsafe"]) in (0, 1)
    out = capsys.readouterr().out
    line = [ln for ln in out.splitlines() if ln.startswith("dfllm cmd bp.place ")]
    assert line, out
    arg = json.loads(line[0].split(" ", 3)[3].strip("'"))
    doc = dcmd.place(sd, "cistern", arg["p"], arg["site"], "c1")
    assert (doc["anchor"], doc["rot"]) == (plan["site"]["anchor"], plan["site"]["rot"])
    assert "pull the lever" in out
    # the planned site taken by another project: no bp.place line for another anchor
    files.write_json_atomic(sd / "bp" / "old.json", {**bp.emit("cistern", arg["p"], plan["site"]), "id": "old"})
    assert sites.main(["cistern", "--save", "s1", "--unsafe"]) == 1
    out = capsys.readouterr().out
    assert "no bp.place line" in out and "dfllm cmd bp.place" not in out


def _live(land, docs, doc):
    """The map after the cistern is dug and built, as a snapshot shows it: the well and the closed floodgate
    are 'B' (snapshot.lua dynamic_char), render leaves them open."""
    w = bp.as_built([sites._plain(d) for d in docs + [doc]], base=land)
    L = rooms.cistern_layout(doc["params"])
    X = Xform(doc["anchor"], doc["rot"])
    w.set(*X.pos(*L["well"], 0), "B")
    w.set(*X.pos(*L["gate"], -1), "B")
    return w, L, X


def test_live_check_before_the_lever_pull(planned, tmp_path, monkeypatch, capsys):
    """Digging reveals every tile around the pipe: a tunnel the planner could not see is a leak the lever pull
    would flood. cistern-check runs the water rules on the map as it is."""
    from df_llm_helper import files
    land, docs, snap, man, plan = planned
    doc = bp.emit("cistern", plan["params"], plan["site"])
    w, L, X = _live(land, docs, doc)
    codes = lambda s: {f.code for f in sites.cistern_findings(doc, base=s, live=True) if f.level == "error"}  # noqa
    assert codes(w.snapshot()) == set()
    mid = L["pipe"][len(L["pipe"]) // 2]
    tunnel = World.from_snapshot(w.snapshot())
    side = next(X.pos(mid[0] + du, mid[1] + dv, -1) for du, dv in ((0, 1), (1, 0), (0, -1), (-1, 0))
                if (mid[0] + du, mid[1] + dv) not in L["pipe"])
    tunnel.set(*side, ".")
    assert "water_leak" in codes(tunnel.snapshot())
    nogate = World.from_snapshot(w.snapshot())
    nogate.set(*X.pos(*L["gate"], -1), ".")                         # not built yet, or already open
    assert "unbuilt" in codes(nogate.snapshot())
    small = World.from_snapshot(w.snapshot())
    cut = small.snapshot()
    x0, y0, z0, x1, y1, z1 = cut["bbox"]
    cut = {**cut, "bbox": [x0, y0, z0, x0 + 30, y1, z1], "rows": {k: [r[:31] for r in v] for k, v in cut["rows"].items()}}
    assert "coverage" in codes(cut)
    # the CLI on a save folder: exit 0 on the sound map, 1 with the tunnel
    monkeypatch.setenv("DFLLM_RUNTIME", str(tmp_path))
    sd = tmp_path / "s1"
    (sd / "snap").mkdir(parents=True)
    files.write_json_atomic(sd / "bp" / "c1.json", {**doc, "id": "c1"})
    files.write_json_atomic(sd / "snap" / "live.json", {**w.snapshot(sid="live")})
    assert sites.main(["cistern-check", "--save", "s1"]) == 0
    assert "the lever may be pulled" in capsys.readouterr().out
    files.write_json_atomic(sd / "snap" / "live.json", {**tunnel.snapshot(sid="live")})
    assert sites.main(["cistern-check", "--save", "s1", "--bp", "c1"]) == 1
    assert "do not pull the lever" in capsys.readouterr().out


# ---------------------------------------------------------------- fortcore prefers water nearby
def test_water_bonus():
    assert sites.water_bonus(0) == 60 and sites.water_bonus(30) == 30
    assert sites.water_bonus(31) == -1 and sites.water_bonus(200) == -80 and sites.water_bonus(None) == -80


def test_fortcore_prefers_sites_near_revealed_water():
    land = terrain().snapshot(purpose="sites")
    best = bp.rank(land, "fortcore")
    assert "water" in best[0]["why"] and "steps" in best[0]["why"]
    steps = int(best[0]["why"].split("water ")[1].split(" steps")[0])
    assert steps <= sites.WATER_NEAR
    dry = bp.rank(terrain(river=False).snapshot(purpose="sites"), "fortcore")
    assert "no water reachable" in dry[0]["why"]
    assert best[0]["score"] > dry[0]["score"]
