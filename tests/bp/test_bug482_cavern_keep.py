"""BUG-482 (Run 16b i2 Roadvises y398-y400: the refuge room z107 lay beside a cavern lake at 91,110,107; refuge_beds was drafted there twice and
`plan check` demanded it again): a room or refuge-level site keeps CAV_KEEP tiles from known cavern water (the manifest's recorded cavern stops
and cavern_lake breaches, revealed water with a cavern mark); with no site left the ranking says so, and the refuge bed gate warns instead of
demanding a template nobody can place."""
import copy

import pytest

from dfpilot import bp
from dfpilot.bp import sites

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def world():
    w, _ = fort_world()
    return w.snapshot(purpose="sites"), w.manifest


def _near(box, pt, r):
    return (box[0] - r <= pt[0] <= box[3] + r and box[1] - r <= pt[1] <= box[4] + r and box[2] - 1 <= pt[2] <= box[5] + 1)


def test_cavern_water_lists_recorded_stops_lake_breaches_and_revealed_cavern_water(world):
    snap, man = world
    assert sites.cavern_water(snap, man) == []
    m = {**man, "caverns": [[91, 110, 107]], "breaches": [{"pos": [5, 6, 7], "why": "cavern_lake", "proj": "p"},
                                                          {"pos": [8, 9, 10], "why": "heavy_aquifer", "proj": "q"}]}
    assert sites.cavern_water(snap, m) == [(5, 6, 7), (91, 110, 107)]
    s = copy.deepcopy(snap)
    x0, y0, z0 = s["bbox"][:3]
    row = list(s["rows"][f"z{z0}"][2])
    row[3] = "~"
    s["rows"][f"z{z0}"][2] = "".join(row)
    s["marks"] = {**(s.get("marks") or {}), "cavern": [[x0 + 3, y0 + 2, z0], [x0 + 5, y0 + 2, z0]]}
    assert (x0 + 3, y0 + 2, z0) in sites.cavern_water(s, man) and (x0 + 5, y0 + 2, z0) not in sites.cavern_water(s, man)


@pytest.mark.parametrize("tpl,p", [("refuge_beds", {"n": 6}), ("refuge_drink", {"n": 6})])
def test_refuge_rooms_keep_off_cavern_water(world, tpl, p):
    snap, man = world
    base = bp.rank(snap, tpl, p, manifest=man, n=6)
    assert base
    pt = list(base[0]["anchor"])
    wet = {**man, "caverns": [pt]}
    got = bp.rank(snap, tpl, p, manifest=wet, n=6)
    for s in got:
        doc = bp.emit(tpl, p, s)
        box = doc["manifest"]["rooms"][0]["bbox"] if doc["manifest"].get("rooms") else None
        assert s["anchor"] != base[0]["anchor"], "old code: the site on the cavern water stays first"
        assert box is None or not _near(box, pt, sites.CAV_KEEP), (s, box)


def test_no_site_left_says_why(world):
    snap, man = world
    zr = man["refuge"]["anchor"][2]
    x0, y0, _, x1, y1, _ = snap["bbox"]
    wet = {**man, "caverns": [[x, y, zr] for x in range(x0, x1 + 1, 3) for y in range(y0, y1 + 1, 3)]}
    with pytest.raises(ValueError, match=r"within 4 tiles of known cavern water.*another quadrant"):
        bp.rank(snap, "refuge_beds", {"n": 6}, manifest=wet)


def test_far_cavern_water_changes_nothing(world):
    snap, man = world
    base = bp.rank(snap, "refuge_beds", {"n": 6}, manifest=man, n=4)
    far = {**man, "caverns": [[snap["bbox"][3], snap["bbox"][4], snap["bbox"][2]]]}
    assert [s["anchor"] for s in bp.rank(snap, "refuge_beds", {"n": 6}, manifest=far, n=4)] == [s["anchor"] for s in base]
