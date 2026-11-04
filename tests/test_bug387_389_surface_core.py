"""Run 16 (04.11.2026, fix round 21).
BUG-387: in region1 (aquifer almost everywhere) no fort got a usable fortcore, so every room template that hangs on the dug Z4 core
(office, dining, tavern, bedrooms) stood still for years. The `surfacecore` template builds the core on open ground from constructed
walls (Kern+, refuge Tiefe+, depot, gate) with the manifest roles of the fortcore; dining, bedrooms, tavern and office take
p.surface = 1 (same room inside constructed walls, no dig, no Z4 needed).
BUG-388: a wet layer ruled out the whole level for every site; now only the dig near the stops on it ('no dry fortcore site ...
(wet level z130)' at every depth).
BUG-389: `plan propose` drafts the surface core in place of the fortcore when none can be dug (fort.surface.need), instead of
fortcore stages with 0 sites and the refuge ERROR."""
from __future__ import annotations

import copy
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema
from dfpilot.bp import sites

X0, Y0, Z = 100, 100, 130
W, H = 70, 50


def _snap(wet_row=None, sid="s387") -> dict:
    rows = [["." for _ in range(W)] for _ in range(H)]
    snap = {"v": 2, "id": sid, "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["".join(r) for r in rows],
                     f"z{Z + 1}": ["_" * W for _ in range(H)]}, "marks": {}}
    return snap


SITE = {"id": "S1", "anchor": [110, 110, Z], "rot": 0}


# ---------------------------------------------------------------- the template
@pytest.mark.parametrize("rot", range(4))
def test_surfacecore_is_walls_doors_and_the_manifest_roles_of_a_core(rot):
    doc = bp.emit("surfacecore", {}, {**SITE, "rot": rot})
    assert [st["mode"] for st in doc["stages"]] == ["build", "build", "place", "zone", "burrow"] and doc["class"] == "infra"
    assert [st["label"] for st in doc["stages"]][:2] == ["s1.walls", "s1.build"], "walls first: a door needs a wall beside it"
    assert all(st["mode"] != "dig" for st in doc["stages"]), "nothing is dug"
    m = doc["manifest"]
    assert m["burrows"] == {"Kern+": {"role": "kern"}, "Tiefe+": {"role": "refuge"}}
    assert m["refuge"]["burrow"] == "Tiefe+" and m["depot"] and m["edge"] and m["zones"]["Z4"]
    assert "bridges" not in m and doc["materials"]["wall"] > 60 and doc["materials"]["door"] == 2
    assert doc["materials"]["trade_depot"] == 1 and doc["materials"]["bed"] >= 8
    assert schema.validate("manifest", m) == [] and schema.validate("bp", dict(doc, id="y1s0b1")) == []
    assert bp.validate(dict(doc, id="y1s0b1")) == [], "doors beside walls, the refuge room closed"
    rid = [r["id"] for r in m["rooms"]]
    assert any(i.endswith("_refuge") for i in rid)


def test_surfacecore_params_make_a_smaller_compound():
    big = bp.emit("surfacecore", {}, SITE)
    small = bp.emit("surfacecore", {"w": 20, "h": 12}, SITE)
    assert small["materials"]["wall"] < big["materials"]["wall"]
    assert bp.validate(dict(small, id="y1s0b1")) == []
    with pytest.raises(ValueError):
        bp.emit("surfacecore", {"w": 10}, SITE)


@pytest.mark.parametrize("tpl,prm", [("dining", {}), ("tavern", {}), ("bedrooms", {"n": 6}), ("office", {})])
def test_surface_rooms_are_the_dug_rooms_inside_constructed_walls(tpl, prm):
    dug = bp.emit(tpl, prm, SITE)
    doc = bp.emit(tpl, {**prm, "surface": 1}, SITE)
    assert any(st["mode"] == "dig" for st in dug["stages"]) and all(st["mode"] not in ("dig", "burrow") for st in doc["stages"])
    assert doc["stages"][0]["label"] == "walls" and doc["materials"]["wall"] > 10 and "zones" not in doc["manifest"]
    assert doc["materials"].get("door", 0) == dug["materials"].get("door", 0), "the doors stay where the dug room had them"
    assert bp.validate(dict(doc, id="y1s0b1")) == [], tpl
    assert schema.validate("bp", dict(doc, id="y1s0b1")) == []


# ---------------------------------------------------------------- the sites
def test_surfacecore_sites_need_no_manifest_and_a_flat_block():
    found = bp.rank(_snap(), "surfacecore", {}, n=3)
    assert found and "open surface floor for the surface core" in found[0]["why"]
    box = sites.surfacecore.block(sites.check_params("surfacecore", {}))
    assert box == (21, 21)
    rows = [list(r) for r in _snap()["rows"][f"z{Z}"]]
    snap = _snap()
    for y in range(0, H, 6):                                    # trees every 6 rows: no 21x21 block of floor
        rows[y] = ["T"] * W
    snap["rows"][f"z{Z}"] = ["".join(r) for r in rows]
    assert bp.rank(snap, "surfacecore", {}, n=3) == []          # the callers turn this into the no-site hint
    assert "flat block of open surface floor" in cmd.no_site_hint(Path("."), "surfacecore", "s1", 0, [], {})


def test_surface_room_sites_stand_beside_the_surface_cores_depot():
    man = {"v": 2, "depot": [150, 125, Z], "zones": {"Z4": [[141, 130, Z, 158, 142, Z]]},
           "rooms": [{"id": "surfacec1_refuge", "tpl": "surfacecore", "use": "utility", "bbox": [150, 135, Z, 156, 139, Z], "tier": 0}]}
    found = bp.rank(_snap(), "dining", {"surface": 1}, manifest=man, n=3)
    assert found and "surface dining" in found[0]["why"]
    for s in found:                                             # never inside the compound
        assert sites.box_dist([s["anchor"][0], s["anchor"][1], Z], (141, 130, Z, 158, 142, Z)) > 0
    d0 = max(abs(found[0]["anchor"][0] - 150), abs(found[0]["anchor"][1] - 125))
    assert d0 < 30, "the room stands near the depot"
    with pytest.raises(ValueError, match="room sites need the fort manifest"):
        bp.rank(_snap(), "dining", {}, n=3)                     # the dug dining room still needs Z4


# ---------------------------------------------------------------- BUG-388: the wet layer is an area
def _breach(pos, why="heavy_aquifer", proj="p1"):
    return {"pos": list(pos), "why": why, "proj": proj, "tpl": "fortcore"}


def test_a_stop_rules_out_the_dig_near_it_not_the_level():
    # Run 16 region1: one wet stop on z130 made every site of the map 'within 10 tiles of a recorded breach (wet level z130)'
    cands = [{"anchor": [10, 10, 135], "rot": 0, "score": 1, "why": "", "dig": (0, 0, 130, 20, 20, 134)},
             {"anchor": [100, 10, 135], "rot": 0, "score": 1, "why": "", "dig": (90, 0, 130, 110, 20, 134)}]
    man = {"v": 2, "breaches": [_breach([30, 10, 130])]}
    assert sites._breach_layers(man) == {130: "wet level z130 (heavy aquifer: breach heavy_aquifer 30,10,130 p1)"}
    left = sites._dry(cands, man)
    assert [c["anchor"] for c in left] == [[100, 10, 135]], "the far site keeps"
    near = {"v": 2, "breaches": [_breach([30, 10, 130]), _breach([105, 10, 130], proj="p2")]}
    with pytest.raises(ValueError, match=r"no dry fortcore site.*wet level z130"):
        sites._dry(cands, near)                                  # stops beside both: nothing dry


def test_surface_core_why_names_a_known_aquifer_within_three_levels_of_the_anchor():
    snap = _snap()
    site = {"anchor": [110, 110, Z]}
    assert sites.surface_core_why(snap, {"v": 2}, None) == "no dry fortcore site on the snapshot"
    assert sites.surface_core_why(snap, {"v": 2}, site) is None
    assert "z128" in sites.surface_core_why(snap, {"v": 2, "aquifer_levels": [128]}, site)
    assert sites.surface_core_why(snap, {"v": 2, "aquifer_levels": [120]}, site) is None       # deep enough
    heavy = {"v": 2, "breaches": [_breach([5, 5, Z - 1])]}
    assert "z129" in sites.surface_core_why(snap, heavy, site)
    deep = {"v": 2, "breaches": [_breach([5, 5, Z - 5])]}          # recorded wet level inside the dig (depth 1-3 reaches az-8)
    assert "z125" in sites.surface_core_why(snap, deep, site)
    assert sites.surface_core_why(snap, {"v": 2, "breaches": [_breach([5, 5, Z - 9])]}, site) is None
    assert "z121" in sites.surface_core_why(snap, {"v": 2, "breaches": [_breach([5, 5, Z - 9])]},
                                            {"anchor": [110, 110, Z], "dig": (100, 100, Z - 9, 120, 120, Z)})


# ---------------------------------------------------------------- BUG-389: plan propose
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = _snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    yield d
    reset_paths()


def _state(save, phase="P1"):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = phase
    s["proj"] = []
    return s


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


FORT = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True,
        "surface": {"have": False, "need": True, "why": "no dry fortcore site on the snapshot", "site": True, "p": None}}


def test_propose_drafts_the_surface_core_instead_of_the_fortcore(save):
    s = _state(save)
    plain = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort={**FORT, "surface": {}})
    assert any(b["tpl"] == "fortcore" for b in _builds(plain)), "the plain draft asks for the fortcore"
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=FORT)
    bs = _builds(doc)
    assert all(b["tpl"] != "fortcore" for b in bs), bs
    assert bs[0] == {"tpl": "surfacecore", "site": "S1"} and "BUG-387/389" in doc["notes"], doc["notes"]
    assert all((b.get("p") or {}).get("surface") == 1 for b in bs if b["tpl"] in (*plan.SURFACE_ROOMS, "hospital"))
    assert not {b["tpl"] for b in bs} & set(plan.SURFACE_DUG_ONLY), "builds that dig rock wait for a dug core"
    assert "tombs" in doc["notes"] and "wait for a dug core" in doc["notes"]
    assert schema.validate("plan", doc) == []
    # the draft is applicable: every build finds its site on the snapshot, the core first, nothing overlaps
    docs, _, _ = plan.place_all(save, doc, None, [])
    assert [d["tpl"] for d in docs][:2] == ["surfacecore", "dining"] and len({tuple(d["anchor"]) for d in docs}) == len(docs)
    assert all(bp.validate(d) == [] for d in docs) and all(schema.validate("bp", d) == [] for d in docs)
    # a surface core placed already is not drafted again; the fortcore stays out
    have = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("surfacecore", None)},
                        fort={**FORT, "surface": {**FORT["surface"], "have": True}})
    assert all(b["tpl"] not in ("fortcore", "surfacecore") for b in _builds(have))
    # no free block: the core is not drafted (it could not be placed) and the notes say why
    none = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(),
                        fort={**FORT, "surface": {**FORT["surface"], "site": False}})
    assert all(b["tpl"] not in ("fortcore", "surfacecore") for b in _builds(none)) and "BUT no open block" in none["notes"]
    small = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(),
                         fort={**FORT, "surface": {**FORT["surface"], "p": {"w": 20, "h": 12}}})
    assert _builds(small)[0] == {"tpl": "surfacecore", "site": "S1", "p": {"w": 20, "h": 12}}


def test_the_surface_core_is_the_refuge_the_gates_ask_for():
    sc = {"tpl": "surfacecore", "site": "S1"}
    assert plan._refuge_stage(sc) and plan._refuge_fix(sc) and plan.build_kind(sc) == "work"
    assert not plan._refuge_stage({"tpl": "fortcore", "site": "S1", "p": {"stage": 1}})
    doc = {"phase_target": "P3", "seasons": [{"build": []}] * 4, "year": 1}
    st = {"bridges": {}, "alert": {"ref": {"ex": True}}}
    assert plan.stage3_gate(doc, st, {"surface": {"have": True}}, None) == ([], [])      # no O1/B2 on a surface core
    assert plan.stage3_gate(doc, st, {"surface": {"need": True}}, None) == ([], [])
    assert plan.stage3_gate(doc, st, {}, None)[0], "a dug fort still needs O1 and B2"


def test_fort_facts_say_need_when_no_fortcore_ranks_or_the_aquifer_is_near(save, monkeypatch):
    def none(save_dir, tpl, params=None, snap=None, n=3, **kw):
        if tpl == "fortcore":
            raise cmd.BpError("bp.sites.rank(fortcore): fortcore: no dry fortcore site: every site's dig lies within 10 tiles "
                              "of a recorded breach (wet level z130 (heavy aquifer))")
        return [{"anchor": [110, 110, Z], "rot": 0}], "s", 1
    monkeypatch.setattr(plan, "free_sites", none)
    f = plan.surface_facts(save, _state(save), set(), None)
    assert f["need"] is True and "no dry fortcore site" in f["why"] and f["site"] is True and f["p"] is None
    # a fortcore under way: nothing to replace
    assert plan.surface_facts(save, _state(save), {("fortcore", 1)}, None)["need"] is False
    # a fortcore stopped on a breach that cannot move: the surface core
    core = {"resite": False, "ok": False, "why": "stage 1 y1s0b1 is dug there", "br": []}
    assert plan.surface_facts(save, _state(save), {("fortcore", 1)}, core)["need"] is True

    def ok(save_dir, tpl, params=None, snap=None, n=3, **kw):
        return [{"anchor": [110, 110, Z], "rot": 0}], "s", 1
    monkeypatch.setattr(plan, "free_sites", ok)
    assert plan.surface_facts(save, _state(save), set(), None)["need"] is False         # a site and no aquifer near
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: {"v": 2, "aquifer_levels": [Z - 2]})
    near = plan.surface_facts(save, _state(save), set(), None)
    assert near["need"] is True and "aquifer known at z128" in near["why"]

    def small_only(save_dir, tpl, params=None, snap=None, n=3, **kw):
        if tpl == "surfacecore" and not params:
            return [], "s", 0
        return ok(save_dir, tpl, params)
    monkeypatch.setattr(plan, "free_sites", small_only)
    assert plan.surface_facts(save, _state(save), set(), None)["p"] == plan.SURFACE_SMALL
