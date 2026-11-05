"""BUG-412 / BUG-413 (Gordon 04.11.2026: "ich moechte generell dass durch aquifier gegraben wird, so sicher wie moeglich.
oberflaechenfort finde ich doof"): the fort belongs under the aquifer.
BUG-412: whenever the core would cut an aquifer level, `plan propose` drafts an aqshaft first (the column beside the chosen core
site, on the citizens' walk group, never within 3 tiles of open water), then the fortcore with p.aquifer=pass below the aquifer.
BUG-413: the surface core and the surface variants of office/dining/bedrooms/tavern/hospital/farms are drafted only with the config
switch plan.surface_core (default false); the startup workshops and the depot stay."""
from __future__ import annotations

import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, fairplay, files, plan, schema, wake
from dfpilot.bp import sites

X0, Y0, Z = 100, 100, 130
W, H = 130, 110
AQ = [Z - 3, Z - 4]


def _snap(water=None, sid="s412") -> dict:
    """A surface of open floor at Z, rock under it down to Z-16, open sky above; water = (x, y, z) one open water tile."""
    rows = {f"z{Z + 1}": ["_" * W for _ in range(H)], f"z{Z}": ["." * W for _ in range(H)]}
    for z in range(Z - 16, Z):
        rows[f"z{z}"] = ["#" * W for _ in range(H)]
    if water:
        wx, wy, wz = water
        r = list(rows[f"z{wz}"][wy - Y0])
        r[wx - X0] = "~"
        rows[f"z{wz}"][wy - Y0] = "".join(r)
    return {"v": 2, "id": sid, "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 16, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": rows, "marks": {}}


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    box = {"snap": _snap(), "man": {"v": 2, "aquifer_levels": list(AQ)}}
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    yield d, box
    reset_paths()


def _state(save, phase="P1"):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = phase
    s["proj"] = []
    return s


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def _fort(save):
    f = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True}
    f["surface"] = plan.surface_facts(save, _state(save), set(), None)
    return f


# ---------------------------------------------------------------- BUG-412: the aquifer route
def test_an_aquifer_world_drafts_the_aqshaft_then_the_fortcore_below_it(world):
    save, _ = world
    fort = _fort(save)
    sf = fort["surface"]
    assert sf["need"] is True and "aquifer known" in sf["why"], sf
    aq = sf["aq"]
    assert aq["ok"] is True and aq["aquifers"] == sorted(AQ), aq
    assert aq["depth"] >= 4, "the core level (anchor - 2 - depth) lies two levels under the shallowest aquifer level"
    s = _state(save)
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    bs = _builds(doc)
    assert not any(b["tpl"] in ("surfacecore",) for b in bs), "BUG-413: no surface core"
    tpls = [b["tpl"] for b in bs]
    assert "aqshaft" in tpls and "fortcore" in tpls and tpls.index("aqshaft") < tpls.index("fortcore"), tpls
    shaft = next(b for b in bs if b["tpl"] == "aqshaft")
    core = next(b for b in bs if b["tpl"] == "fortcore")
    col = aq["col"]
    assert shaft["p"] == {"x": col["x"], "y": col["y"], "top": Z, "depth": col["depth"], "dry_levels": 2}
    assert core["p"]["aquifer"] == "pass" and core["p"]["depth"] == aq["depth"] and core["site"] == aq["site"]["label"]
    assert "BUG-412" in doc["notes"] and "PASSED shaft" in doc["notes"], doc["notes"]
    assert schema.validate("plan", doc) == []
    # applicable: both place, in that order, neither touches the other, both validate
    docs, _, _ = plan.place_all(save, doc, None, [])
    order = [d["tpl"] for d in docs]
    assert order.index("aqshaft") < order.index("fortcore")
    a = next(d for d in docs if d["tpl"] == "aqshaft")
    f = next(d for d in docs if d["tpl"] == "fortcore")
    assert a["anchor"] == [col["x"], col["y"], Z] and f["anchor"] == aq["site"]["anchor"]
    assert all(bp.validate(d) == [] for d in (a, f)) and all(schema.validate("bp", d) == [] for d in (a, f))
    occ = cmd.Occupancy()
    occ.add(a)
    assert occ.clash(f) == [], "the shaft stands apart from the core's dug tiles"
    # the shaft goes down through the aquifer: one stage per level, the first a down stair on the surface floor
    assert [st["label"] for st in a["stages"]][:2] == ["l0.dig", "l1.dig"] and len(a["stages"]) == col["depth"]


def test_the_core_below_the_shaft_is_deeper_than_every_aquifer_level(world):
    save, _ = world
    aq = plan.surface_facts(save, _state(save), set(), None)["aq"]
    ze = Z - 2
    zc = ze - aq["depth"]
    assert zc <= min(AQ) - 2, "Kern+ lies two levels under the shallowest aquifer level"
    assert zc - 3 > min(AQ) - 20


def test_a_shaft_already_placed_is_not_drafted_twice_but_the_core_keeps_its_route(world):
    save, _ = world
    fort = _fort(save)
    fort["aqshaft"] = True
    doc = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied={("aqshaft", None)}, fort=fort)
    bs = _builds(doc)
    assert not [b for b in bs if b["tpl"] == "aqshaft"]
    core = next(b for b in bs if b["tpl"] == "fortcore")
    assert core["p"]["aquifer"] == "pass"


def test_no_safe_shaft_column_leaves_the_core_out_and_says_why(world):
    save, box = world
    # open water two tiles beside every surface tile: no column keeps 3 tiles away
    snap = _snap()
    for y in range(0, H, 3):
        rows = [list(r) for r in snap["rows"][f"z{Z}"]]
        for x in range(0, W, 3):
            rows[y][x] = "~"
        snap["rows"][f"z{Z}"][y] = "".join(rows[y])
    box["snap"] = snap
    sf = plan.surface_facts(save, _state(save), set(), None)
    assert sf["need"] is True and sf["aq"]["ok"] is False
    fort = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True, "surface": sf}
    doc = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    bs = _builds(doc)
    assert not [b for b in bs if b["tpl"] in ("fortcore", "aqshaft", "surfacecore")]
    assert "nothing is dug blind" in doc["notes"], doc["notes"]


def test_core_shaft_keeps_off_water_non_rock_unreachable_ground_and_the_aquifer_core_levels(world):
    snap = _snap()
    man = {"v": 2, "aquifer_levels": list(AQ)}
    anchor = [150, 140, Z]
    col = sites.core_shaft(snap, man, anchor, 0, 5)
    assert (col["x"], col["y"], col["top"]) == (147, 141, Z) and col["depth"] == 8, col       # u -3, v 1 beside the entrance
    # open water within 3 tiles on any level the shaft passes: the next offset
    near = _snap(water=(144, 141, Z - 6))
    col2 = sites.core_shaft(near, man, anchor, 0, 5)
    assert (col2["x"], col2["y"]) != (147, 141)
    # a side tile that is not rock on a level below
    rows = [list(r) for r in snap["rows"][f"z{Z - 3}"]]
    rows[141 - Y0][148 - X0] = "."
    bad = copy.deepcopy(snap)
    bad["rows"][f"z{Z - 3}"] = ["".join(r) for r in rows]
    assert sites.core_shaft(bad, man, anchor, 0, 5)["x"] != 147
    # BUG-432: a cavern breach recorded inside the aquifer span (live i3: caverns [[50,63,122]] in aquifer z120-127) refuses only
    # the offsets next to it; far from the column it changes nothing
    far = {**man, "caverns": [[20, 20, Z - 2]]}
    assert sites.core_shaft(snap, far, anchor, 0, 5)["x"] == 147
    hit = {**man, "caverns": [[150, 141, Z - 2]]}
    with pytest.raises(ValueError, match="cavern/warm tile within"):
        sites.core_shaft(snap, hit, anchor, 0, 5)
    # a core that would still meet the aquifer is refused with the depth to ask for
    with pytest.raises(ValueError, match="meet the aquifer"):
        sites.core_shaft(snap, man, anchor, 0, 1)
    # a top tile in another walk group
    walled = copy.deepcopy(snap)
    walled["wg"] = {"home": 7, "rows": {f"z{Z}": ["0" * W for _ in range(H)]}}
    with pytest.raises(ValueError, match="walk group"):
        sites.core_shaft(walled, man, anchor, 0, 5)


# ---------------------------------------------------------------- BUG-413: no surface core by default
def test_the_surface_core_and_its_room_variants_are_not_drafted_by_default(world):
    save, _ = world
    assert plan.surface_core_on() is False
    fort = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True,
            "surface": {"have": False, "need": True, "why": "no dry fortcore site", "site": True, "p": None}}
    doc = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    bs = _builds(doc)
    assert not [b for b in bs if b["tpl"] == "surfacecore"], bs
    assert not [b for b in bs if (b.get("p") or {}).get("surface") == 1], "no surface variant of any room"
    assert "BUG-387/389" not in doc["notes"]
    # the temporary startup workshops beside the wagon and the depot are not surface cores: they stay
    fort2 = dict(fort, startup=False, depot=False)
    doc2 = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied=set(), fort=fort2)
    b2 = _builds(doc2)
    assert any(b["tpl"] == "workshops" and (b.get("p") or {}).get("surface") == 1 for b in b2), b2


def test_the_config_switch_brings_the_surface_core_back(world, tmp_path):
    save, _ = world
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / "baseline.json").write_text(json.dumps({"v": 2, "baseline": {}, "plan": {"surface_core": True}}))
    assert plan.surface_core_on() is True
    fort = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True,
            "surface": {"have": False, "need": True, "why": "no dry fortcore site", "site": True, "p": None}}
    doc = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert _builds(doc)[0]["tpl"] == "surfacecore"
    (cfg / "baseline.json").write_text(json.dumps({"v": 2, "baseline": {}, "plan": {"surface_core": "yes"}}))
    assert plan.surface_core_on() is False, "a bad value keeps the default"
    assert any("plan.surface_core" in e for e in fairplay.plan_errors(cfg / "baseline.json"))


def test_the_shipped_baseline_has_the_switch_off_and_lint_accepts_it():
    from dfpilot import paths
    doc = json.loads((paths.repo_dir() / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert doc["plan"]["surface_core"] is False
    assert fairplay.plan_errors() == []


def test_surface_variants_of_hospital_office_and_farms_are_off_by_default(world, monkeypatch):
    save, _ = world
    fort = {"office": {"site": [1, 2, Z], "have": False}, "hosp": {"surface": True, "site": [1, 2, Z]}}
    assert plan.office_surface_due(fort, set()) is False
    st = {"water": {"patients": 3, "hosp": 0}}
    assert plan.hospital_surface_due(st, fort, set()) is False
    assert [k for k, _ in plan._farm_kinds()] == ["room"]
    assert [p.get("surface") for p in wake.farm_tries({"plots": 2}, "PEACE")] == [None, None]
    monkeypatch.setattr(plan, "surface_core_on", lambda: True)
    assert plan.office_surface_due(fort, set()) is True and plan.hospital_surface_due(st, fort, set()) is True
    assert [k for k, _ in plan._farm_kinds()] == ["room", "surface"]
    assert wake.farm_tries({"plots": 2}, "PEACE")[-1].get("surface") == 1
