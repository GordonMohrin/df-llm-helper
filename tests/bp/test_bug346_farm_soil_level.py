"""BUG-346 (Run 15 Guildcleans y381, Inkintense, Earthboat, Drillchamber y395): `only 0 free site(s) for farms` for years.
The snapshot marks soil on revealed floor only (snapshot.lua scan_span), never on the rock or hidden tiles a farm room is
dug from, so the BUG-257 rule counted 'soil 0/70' for every room site once any surface soil was known. Live: Guildcleans'
z128 fort floor was 499/499 soil, Earthboat's z138 583/583, Inkintense's z131 339/525; Drillchamber's 0 (stone). A soil
level (the fort's dug Z4 floor there is soil) now counts the undug plot tiles as soil; a stone fort names why.
Fails on 14ff5a3."""
import pytest

from dfpilot import bp, cmd
from dfpilot.bp import sites

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _z4_floor(snap, man, z):
    at = sites._At(snap)
    return sorted({(x, y, b[2]) for b in man["zones"]["Z4"] if b[2] == z == b[5]
                   for x in range(b[0], b[3] + 1) for y in range(b[1], b[4] + 1) if at(x, y, z) == "."})


def _surface_soil(snap):
    x0, y0, _, x1, y1, z1 = snap["bbox"]
    at = sites._At(snap)
    return [[x, y, 10] for x in range(x0, x1 + 1) for y in range(y0, y1 + 1) if at(x, y, 10) == "."][:3000]


def test_room_sites_on_a_soil_level_with_only_floor_marks(fort):
    snap, man = fort
    floor = _z4_floor(snap, man, 5)
    assert len(floor) >= 2 * sites.SOIL_LEVEL_MIN
    live = {**snap, "marks": {"soil": _surface_soil(snap) + [list(t) for t in floor]}}
    assert sites.soil_level_set(sites.soil_levels(live, man)) == {5}
    ranked = bp.rank(live, "farms", manifest=man, n=5)
    assert ranked, "the fort's z5 floor is soil: farm rooms dug there get soil floor"
    assert all(s["anchor"][2] == 5 and "by the soil level" in s["why"] for s in ranked), [s["why"] for s in ranked]
    assert "soil 70/70" in ranked[0]["why"]


def test_stone_fort_no_room_site_and_the_reason(fort):
    snap, man = fort
    live = {**snap, "marks": {"soil": _surface_soil(snap)}}       # soil on the surface only, the fort's floor is stone
    assert bp.rank(live, "farms", manifest=man, n=5) == []
    why = sites.farm_soil_why(live, man)
    assert "no soil level in the fort" in why and "p.surface=1" in why


def test_a_level_with_little_soil_floor_is_no_soil_level(fort):
    snap, man = fort
    floor = _z4_floor(snap, man, 5)
    few = floor[:len(floor) // 2 - 1]                                 # below half of the level's fort floor
    live = {**snap, "marks": {"soil": _surface_soil(snap) + [list(t) for t in few]}}
    assert 5 not in sites.soil_level_set(sites.soil_levels(live, man))
    assert all(s["anchor"][2] != 5 or "by the soil level" not in s["why"]
               for s in bp.rank(live, "farms", manifest=man, n=40))
    assert sites.soil_level_set({7: (sites.SOIL_LEVEL_MIN - 1, sites.SOIL_LEVEL_MIN - 1)}) == set()


def test_cached_ranking_of_older_rules_is_ranked_again(tmp_path, monkeypatch, fort):
    snap, man = fort
    calls = []
    monkeypatch.setattr(cmd, "fort_manifest", lambda sd: man)
    monkeypatch.setattr(cmd, "water_ctx", lambda sd, tpl: None)
    monkeypatch.setattr(cmd, "rank_sites", lambda sd, tpl, params, s, manifest=None: calls.append(1) or ([], s["id"]))
    old = {"v": 2, "tpl": "farms", "snap": snap["id"], "n": cmd.RANK_N, "params": {}, "man": cmd._digest(man),
           "water": cmd._digest(None), "sites": []}                 # written before RANK_V: the old soil rule's []
    cmd.files.write_json_atomic(cmd._sites_cache(tmp_path, "farms"), old)
    cmd.ranking(tmp_path, "farms", None, snap)
    assert calls == [1], "a cache without the ranking version is ranked again"
    cmd.files.write_json_atomic(cmd._sites_cache(tmp_path, "farms"), {**old, "rv": sites.RANK_V})
    cmd.ranking(tmp_path, "farms", None, snap)
    assert calls == [1], "the current version's cache is used"


def test_farm_hint_replaces_the_fortcore_hint(tmp_path, monkeypatch, fort):
    snap, man = fort
    live = {**snap, "marks": {"soil": _surface_soil(snap)}}
    monkeypatch.setattr(cmd, "fort_manifest", lambda sd: man)
    assert "no soil level in the fort" in cmd.farm_hint(tmp_path, "farms", {}, live, 0)
    assert cmd.farm_hint(tmp_path, "farms", {"surface": 1}, live, 0) == ""
    assert cmd.farm_hint(tmp_path, "farms", {}, live, 2) == ""
    assert cmd.farm_hint(tmp_path, "dining", {}, live, 0) == ""
