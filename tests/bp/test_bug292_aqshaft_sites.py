"""BUG-292 (Run 15 Inkintense round 2): `bp sites aqshaft` proposed nothing ("no ranking; name the shaft column") and the
columns tried by hand were refused ('overlaps project(s) y372s0b0': the fortcore's tiles beside the 1-tile column, the
8-neighbour touch rule). Now the columns are ranked (public Z4 floor, rock or unknown below with rock on its 4 sides, off
cavern/warm levels and the keep-out boxes, a known aquifer level passed scores higher) and an aqshaft keeps one rock tile
to other projects orthogonally only (its seal is its 4 orthogonal walls). BUG-289/290: `bp sites hospital` names the best
way to water the kernel's scan found (state water.wsc) when no accepted water exists. Fails on 05dc764."""
import pytest

from dfpilot import bp, cmd
from dfpilot.bp import sites

from bp_fixtures import fort_world

GOOD = set("#?")


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _at(snap, x, y, z):
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    if not (x0 <= x <= x1 and y0 <= y <= y1 and z0 <= z <= z1):
        return None
    return snap["rows"][f"z{z}"][y - y0][x - x0]


def test_aqshaft_columns_are_ranked(fort):
    snap, man = fort
    got = bp.rank(snap, "aqshaft", {"depth": 4}, manifest=man)          # old code: ValueError "no ranking"
    assert len(got) == 3, got
    for s in got:
        x, y, z = s["anchor"]
        assert _at(snap, x, y, z) == "."
        for zz in range(z - 3, z):
            for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
                assert _at(snap, x + dx, y + dy, zz) in GOOD | {None}, (s, zz, dx, dy)
        assert s["why"].startswith(f"column {x},{y} z{z}-z{z - 3}")
    # a shaft placed by its rank: bp.emit puts it on the site anchor
    doc = bp.emit("aqshaft", {"depth": 4}, {"id": "S1", "anchor": got[0]["anchor"], "rot": 0})
    assert doc["anchor"] == got[0]["anchor"] and len(doc["stages"]) == 4


def test_aqshaft_prefers_a_column_through_a_known_aquifer_level_and_says_why_none_is_left(fort):
    snap, man = fort
    plain = bp.rank(snap, "aqshaft", {"depth": 4}, manifest=man)
    z = plain[0]["anchor"][2]
    aq = bp.rank(snap, "aqshaft", {"depth": 4}, manifest={**man, "aquifer_levels": [z - 2]})
    assert aq[0]["why"].endswith(f"passes aquifer level z{z - 2}") and aq[0]["score"] == plain[0]["score"] + sites.AQ_SPAN
    x0, y0, z0, x1, y1, z1 = snap["bbox"]
    cav = {**snap, "marks": {**snap.get("marks", {}), "cavern": [[x0, y0, zz] for zz in range(z0, z1 + 1)]}}
    with pytest.raises(ValueError, match="an avoided cavern/warm level"):
        bp.rank(cav, "aqshaft", {"depth": 4}, manifest=man)


def _doc(pid, tpl, anchor, cells):
    return {"id": pid, "tpl": tpl, "anchor": list(anchor),
            "stages": [{"label": "dig", "mode": "dig", "chunks": [{"pos": [0, 0, 0], "cells": [[*c, "d"] for c in cells]}]}]}


def test_aqshaft_touches_other_projects_only_diagonally():
    occ = cmd.Occupancy()
    occ.add(_doc("room1", "bedrooms", (10, 10, 5), [(10, 10, 5)]))
    shaft = cmd.emit_at("aqshaft", {"x": 11, "y": 11, "top": 6, "depth": 3}, {"id": "S1", "anchor": [11, 11, 6], "rot": 0},
                        "S1", "aq1")
    assert occ.clash(shaft) == [], "old code: ['room1'] (the diagonal neighbour on z5)"
    occ.add(_doc("room2", "bedrooms", (11, 10, 5), [(11, 10, 5)]))
    assert occ.clash(shaft) == ["room2"], "an orthogonal neighbour breaks the seal"
    other = _doc("new", "tombs", (11, 11, 9), [(11, 11, 5)])
    assert cmd.Occupancy.clash(occ, other) == ["room1", "room2"], "every other template keeps the 8-neighbour rule"


def test_hospital_sites_name_the_best_way_to_water_the_scan_found(tmp_path):
    with pytest.raises(ValueError, match=r"the water scan found: water 77,57,130 \(7/7\): a well at 77,57,131"):
        sites._near_water([], "hospital", {}, {"src": [], "cand": "water 77,57,130 (7/7): a well at 77,57,131 over it"})
    st = {"water": {"patients": 0, "thirst_max": 0, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 0, "hosp": 0, "src": [],
                    "wsc": "water 1,2,3 (5/7): dig 2 wall(s) from 4,5,6", "wst": 99}}
    assert cmd.water_ctx(tmp_path, "hospital", st)["cand"] == "water 1,2,3 (5/7): dig 2 wall(s) from 4,5,6"


def test_review_shaft_top_on_a_corridor_floor_and_ranking_keeps_free_columns(fort):
    """Review (Inkintense bp files replayed: all 53 ranked columns lay on placed project floor, `bp.place aqshaft S1` found
    none free): the shaft's own top tile on a corridor project's floor is no clash (a water project's still is), and the
    ranking keeps only the columns `free` accepts."""
    occ = cmd.Occupancy()
    occ.add(_doc("fc", "fortcore", (10, 11, 6), [(10, 11, 6), (11, 11, 6), (12, 11, 6)]))
    shaft = cmd.emit_at("aqshaft", {"x": 11, "y": 11, "top": 6, "depth": 3}, {"id": "S1", "anchor": [11, 11, 6], "rot": 0},
                        "S1", "aq1")
    assert occ.clash(shaft) == [], "old code: ['fc'] (its own top tile on the corridor)"
    wet = cmd.Occupancy()
    wet.add(_doc("cis", "cistern", (11, 11, 6), [(11, 11, 6)]))
    assert wet.clash(shaft) == ["cis"], "a basin under the top still clashes"
    snap, man = fort
    got = bp.rank(snap, "aqshaft", {"depth": 4}, manifest=man)
    first = got[0]["anchor"]
    rest = bp.rank(snap, "aqshaft", {"depth": 4}, manifest=man, free=lambda c: c["anchor"] != first)
    assert first not in [s["anchor"] for s in rest] and rest
    with pytest.raises(ValueError, match="lie on or beside placed projects"):
        bp.rank(snap, "aqshaft", {"depth": 4}, manifest=man, free=lambda c: False)
