"""BUG-447 (Run 16c i3 Castletongs: `refuge_drink` 'none (0 ranked, 0 projects hold them)' for years, `refuge_dry` held the population at 29-38):
the refuge room stands on aquifer level z119 and right under z120, it was dug there and holds, and `aquifer_ok` dropped all 27 sites of
every refuge-level room for those very levels. A refuge-level room (refuge_beds, refuge_drink) may use the levels the refuge room itself
stands on; a refusal for the aquifer says so instead of ranking nothing."""
import pytest

from dfpilot import bp

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def world():
    w, _ = fort_world()
    snap, man = w.snapshot(purpose="sites"), w.manifest
    return snap, man, man["refuge"]["anchor"][2]


@pytest.mark.parametrize("tpl,p", [("refuge_drink", {"n": 6}), ("refuge_beds", {"n": 6})])
def test_refuge_level_rooms_rank_on_the_refuge_levels_when_they_are_aquifer_levels(world, tpl, p):
    snap, man, zr = world
    wet = {**man, "aquifer_levels": [zr, zr + 1]}
    ranked = bp.rank(snap, tpl, p, manifest=wet)
    assert ranked, f"{tpl}: old code: every site dropped for the aquifer levels the refuge room stands on"
    assert all(s["anchor"][2] == zr for s in ranked)


def test_a_level_the_refuge_does_not_stand_on_still_rules_the_room_out(world):
    snap, man, zr = world
    wet = {**man, "aquifer_levels": [zr + 1, zr + 2, zr + 3]}         # the level right above the refuge room's ceiling
    ranked = bp.rank(snap, "refuge_drink", {"n": 6}, manifest=wet)
    assert ranked                                                     # zr+1 is the refuge's own, zr+2 / zr+3 are not touched by its rooms
    allwet = {**man, "aquifer_levels": list(range(0, 40))}
    with pytest.raises(ValueError, match="known aquifer level"):
        bp.rank(snap, "bedrooms", {}, manifest=allwet)


def test_a_room_that_is_not_refuge_level_gets_no_exemption(world):
    snap, man, zr = world
    allwet = {**man, "aquifer_levels": [zr, zr + 1]}
    ranked = bp.rank(snap, "bedrooms", {}, manifest=allwet)
    assert all(not (s["anchor"][2] in (zr, zr + 1)) for s in ranked) or ranked == []
