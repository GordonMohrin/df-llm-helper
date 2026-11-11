"""BUG-763 (Run 16a i1 Basementflew y530-y534: `bp sites hospital` 'no valid site (1201 anchors, 4804 placements: 3842 no open door tile, 962 room meets
rock/wall/liquid, 0 fit; nearest water zone 23 tiles from Tiefe+)'; patient 27129 died of thirst with the water 91 tiles away): when no 7x5 hospital
room fits, the compact 5x4 room is ranked (the site carries `compact` = 1, cmd.site_params puts it into the document); `hospital carry=1` also ranks
sites farther from accepted water than water.near with a water carrier route; the refusal names the best near-miss."""
import copy
import sys
from pathlib import Path

import pytest

from dfpilot import cmd
from dfpilot.bp import rooms, sites

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402

WELL = [90, 66, 5]                                # near the fixture fort (tests/test_hospital_sites.py)


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _only_small(monkeypatch, limit=8):
    """No room wider than `limit` tiles (ring included) fits: the 7x5 room (9 wide) has no site, the compact one (7 wide) has."""
    orig = sites._check

    def chk(rects, *a, **k):
        if max(r[2] - r[0] + 1 for lst in rects.values() for r in lst) > limit:
            return None
        return orig(rects, *a, **k)
    monkeypatch.setattr(sites, "_check", chk)


def test_the_compact_plan_is_a_5x4_room_with_its_well_and_pond_inside():
    big = rooms.hospital(sites.check_params("hospital", {}))
    small = rooms.hospital(sites.check_params("hospital", {"compact": 1, "beds": 8}))
    bb, sb = big.rooms[0]["bbox"], small.rooms[0]["bbox"]
    assert (bb[3] - bb[0] + 1, bb[4] - bb[1] + 1) == (7, 5)
    assert (sb[3] - sb[0] + 1, sb[4] - sb[1] + 1) == (5, 4), sb
    beds = [it for st in small.stages for it in st.items if st.mode == "build" and it.key == "b"]
    assert len(beds) == 5, "the compact room holds at most one row of beds"
    for st in small.stages:                                       # every tile of the plan lies inside the room (door column aside)
        for it in st.items:
            assert sb[0] <= it.u0 and it.u1 <= sb[3] and (it.v0 >= sb[1] or it.v1 < sb[1]), (st.mode, it.key, it.u0, it.v0)
    assert [it.u0 for st in big.stages for it in st.items if st.mode == "zone" and it.key == "p"] == [3]    # the 7x5 room is as before


def test_no_room_fits_the_compact_room_is_ranked_and_says_so(fort, monkeypatch):
    snap, man = fort
    water = {"src": [WELL], "near": 30}
    assert sites.rank(snap, "hospital", manifest=man, water=water), "the fixture has 7x5 sites to begin with"
    _only_small(monkeypatch)
    got = sites.rank(snap, "hospital", manifest=man, water=water, n=3)
    assert got and all(s.get("compact") == 1 for s in got), got
    assert "compact room 5x4" in got[0]["why"] and "BUG-763" in got[0]["why"], got[0]["why"]
    assert cmd.site_params("hospital", {"beds": 6}, got[0]) == {"beds": 6, "compact": 1}
    assert cmd.site_params("hospital", {"compact": 0}, got[0]) == {"compact": 0}, "p.compact given stays"
    assert cmd.site_params("hospital", None, {"anchor": [1, 2, 3]}) is None, "a 7x5 site changes nothing"
    # p.compact = 0 given: the player wants the big room, no fallback
    with pytest.raises(ValueError):
        sites.rank(snap, "hospital", {"compact": 0}, manifest=man, water=water)


def _far_well(snap, man):
    """A source whose distance to the nearest hospital site lies between water.near and HOSPITAL_CARRY_MAX."""
    plain = sites.rank(snap, "hospital", manifest=man, n=40)
    zbs = [sites.zone_box("hospital", {}, s["anchor"], s["rot"]) for s in plain]
    x0 = min(z[0] for z in zbs)
    for dx in range(40, 78, 4):
        src = [x0 - dx, zbs[0][1], zbs[0][2]]
        d = min(sites.box_dist(src, z) for z in zbs)
        if 30 < d <= sites.HOSPITAL_CARRY_MAX:
            return src
    raise AssertionError("no far well found")


def test_a_far_well_is_refused_unless_a_carrier_route_is_asked_for(fort):
    snap, man = fort
    water = {"src": [_far_well(snap, man)], "near": 30}
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", manifest=man, water=water)
    assert "no site within 30 tiles of accepted water" in str(e.value), str(e.value)
    assert "hospital carry=1" in str(e.value), str(e.value)
    got = sites.rank(snap, "hospital", {"carry": 1}, manifest=man, water=water, n=3)
    assert got and all(s["water"].get("carry") == 1 and 30 < s["water"]["d"] <= sites.HOSPITAL_CARRY_MAX for s in got), got
    assert "WATER CARRIER ROUTE" in got[0]["why"], got[0]["why"]
    # a site within water.near stays a plain site (no carrier route) even with carry = 1
    near = sites.rank(snap, "hospital", {"carry": 1}, manifest=man, water={"src": [WELL], "near": 30}, n=1)
    assert near and "carry" not in near[0]["water"], near


def test_a_dead_end_names_the_nearest_miss(fort, monkeypatch):
    snap, man = fort
    man = copy.deepcopy(man)
    monkeypatch.setattr(sites, "_check", lambda *a, **k: None)                        # nothing fits, compact included
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", manifest=man, water={"src": [WELL], "near": 30})
    msg = str(e.value)
    assert "nearest miss: anchor " in msg and "blocked tile(s) in its room" in msg, msg
    assert "compact 5x4 room was tried too" in msg or "also tried" in msg, msg
