"""FR-95: the aquifer pass on the blueprint side. `aqshaft` = a lined stair shaft, one stage per level (the runner digs,
seals and watches each level before the next, lua/dfllm/aqshaft.lua); the manifest's `aquifer_levels` (levels the kernel saw
damp or wet on revealed tiles) keep rooms off those levels and off the level right below them (one dry solid level
between an aquifer and a room under it); fortcore p.aquifer = above keeps the whole fort above them, = pass puts its
deepest level at least one dry level below them (it digs once an aqshaft passed)."""
import pytest

from dfpilot import bp, schema
from dfpilot.bp import sites

from bp_fixtures import fort_world, terrain


def test_aqshaft_document():
    d = bp.emit("aqshaft", {"x": 40, "y": 41, "top": 100, "depth": 4})
    assert (d["tpl"], d["class"], d["anchor"], d["rot"]) == ("aqshaft", "infra", [40, 41, 100], 0)
    assert [s["label"] for s in d["stages"]] == ["l0.dig", "l1.dig", "l2.dig", "l3.dig"]
    assert all(s["mode"] == "dig" and len(s["chunks"]) == 1 for s in d["stages"])
    cells = [(s["chunks"][0]["pos"], s["chunks"][0]["cells"]) for s in d["stages"]]
    assert cells[0] == ([40, 41, 100], [[0, 0, 0, "j"]])
    assert cells[1] == ([40, 41, 99], [[0, 0, 0, "i"]]) and cells[3] == ([40, 41, 97], [[0, 0, 0, "i"]])
    assert d["params"] == {"x": 40, "y": 41, "top": 100, "dry_levels": 2, "depth": 4, "mode": "auto"}
    assert d["materials"] == {} and "zones" not in d["manifest"]          # a shaft is no room
    assert schema.validate("bp", {**d, "id": "aq1"}) == []


def test_aqshaft_on_a_site_anchor_and_refusals():
    d = bp.emit("aqshaft", {"depth": 3, "dry_levels": 1, "mode": "soil"}, {"id": "S1", "anchor": [10, 11, 50], "rot": 0})
    assert d["anchor"] == [10, 11, 50] and d["stages"][2]["chunks"][0]["pos"] == [10, 11, 48]
    assert d["params"]["mode"] == "soil" and d["params"]["dry_levels"] == 1
    with pytest.raises(ValueError, match="mode"):
        bp.emit("aqshaft", {"mode": "magic"})
    with pytest.raises(ValueError, match="x, y and top"):
        bp.emit("aqshaft", {"x": 5})
    with pytest.raises(ValueError):
        bp.emit("aqshaft", {"dry_levels": 0})
    with pytest.raises(ValueError, match="aqshaft"):
        bp.rank(terrain().snapshot(purpose="sites"), "aqshaft", {})      # BUG-292: ranked from Z4, needs the manifest


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _levels(site, tpl="bedrooms"):
    d = bp.emit(tpl, {}, site)
    return sorted({ch["pos"][2] + c[2] for st in d["stages"] for ch in st["chunks"] for c in ch["cells"]})


def test_rooms_keep_off_aquifer_levels_and_the_level_below(fort):
    snap, man = fort
    best = bp.rank(snap, "bedrooms", {}, manifest=man)[0]
    z = _levels(best)[0]
    for aq in ([z], [z + 1]):                      # on the level, or the aquifer right above the room (drips)
        got = bp.rank(snap, "bedrooms", {}, manifest={**man, "aquifer_levels": aq})
        assert all(_levels(s)[0] not in (aq[0], aq[0] - 1) for s in got), (aq, got)
        assert best["anchor"] not in [s["anchor"] for s in got]
    under = bp.rank(snap, "bedrooms", {}, manifest={**man, "aquifer_levels": [z - 2]})   # the aquifer below the room
    assert best["anchor"] in [s["anchor"] for s in under]
    assert schema.validate("manifest", {**man, "aquifer_levels": [z - 2, z + 5]}) == []
    assert schema.validate("manifest", {**man, "aquifer_levels": ["z9"]}) != []


def test_shafts_may_pass_aquifer_levels(fort):
    snap, man = fort
    best = bp.rank(snap, "explore", {"depth": 4}, manifest=man)[0]
    aq = {**man, "aquifer_levels": [best["anchor"][2] - 2]}
    assert best["anchor"] in [s["anchor"] for s in bp.rank(snap, "explore", {"depth": 4}, manifest=aq)]


def test_fortcore_aquifer_above_and_pass():
    land = terrain().snapshot(purpose="sites")
    low = 10 + min(sites.footprint("fortcore", bp.check_params("fortcore", {})))   # its deepest level
    assert bp.check_params("fortcore", {})["aquifer"] == ""
    plain = bp.rank(land, "fortcore", {}, manifest={"v": 2, "aquifer_levels": [low]})
    assert plain, "without p.aquifer the ranking is as before"
    assert bp.rank(land, "fortcore", {"aquifer": "above"}, manifest={"v": 2, "aquifer_levels": [low]}) == []
    assert bp.rank(land, "fortcore", {"aquifer": "above"}, manifest={"v": 2, "aquifer_levels": [low - 1]})
    assert bp.rank(land, "fortcore", {"aquifer": "pass"}, manifest={"v": 2, "aquifer_levels": [low + 1]}) == []
    assert bp.rank(land, "fortcore", {"aquifer": "pass"}, manifest={"v": 2, "aquifer_levels": [low + 2]})
    with pytest.raises(ValueError, match="aquifer"):
        bp.emit("fortcore", {"aquifer": "below"}, {"id": "S1", "anchor": [50, 50, 10], "rot": 0})
    d = bp.emit("fortcore", {"aquifer": "pass"}, {"id": "S1", "anchor": [50, 50, 10], "rot": 0})
    assert d["params"]["aquifer"] == "pass"
