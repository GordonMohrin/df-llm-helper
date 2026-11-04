"""BUG-407 (Run 16a i1 Bachwald: a mountain fort with no fortcore, `bp.place farms surface=1` refused 'only 0 free site(s)', 13
citizens died of thirst) and BUG-406/408 (follow places the farm plot the kernel asks for when its brewable seeds fit no plot).
The ranking offered soil only inside Z4 or within 12 tiles of the fort's entrance: a fort with no entrance got nothing, rock
ground got no reason, a muddy floor (quickfort's has_mud) was no ground. The tests below fail on 503bb8b."""
from __future__ import annotations

import pytest

from dfpilot.bp import sites

X0, Y0, Z = 100, 100, 50


def _snap(soil=(), mud=(), w=60, h=40, water=(), wg=None) -> dict:
    rows = [["."] * w for _ in range(h)]
    for (x, y) in water:
        rows[y - Y0][x - X0] = "~"
    snap = {"v": 2, "id": "s407", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z, X0 + w - 1, Y0 + h - 1, Z],
            "rows": {f"z{Z}": ["".join(r) for r in rows]},
            "marks": {k: [list(p) for p in v] for k, v in (("soil", soil), ("mud", mud)) if v}}
    if wg:
        snap["wg"] = wg
    return snap


def _block(x0, y0, x1, y1):
    return [(x, y, Z) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


def test_a_fort_without_entrance_gets_soil_anywhere_on_the_map():
    snap = _snap(soil=_block(120, 110, 140, 125))              # no manifest at all: no Z4, no edge
    out = sites.rank(snap, "farms", {"surface": 1, "plots": 1}, None)
    assert out and out[0]["score"] <= sites.FAR_SCORE
    assert "surface farm on soil floor" in out[0]["why"] and "middle of the snapshot" in out[0]["why"]


def test_near_the_entrance_still_wins_over_far_soil():
    man = {"v": 2, "zones": {"Z4": []}, "edge": [[125, 104, Z]], "rooms": [], "bridges": {}, "killboxes": [], "stairs": {},
           "stations": {}, "workshops": []}
    snap = _snap(soil=_block(120, 106, 140, 125) + _block(150, 125, 158, 137))
    out = sites.rank(snap, "farms", {"surface": 1, "plots": 1}, man)
    assert out[0]["score"] > sites.FAR_SCORE and "tiles from the entrance" in out[0]["why"]


def test_a_muddy_rock_floor_takes_a_plot():
    snap = _snap(mud=_block(120, 110, 140, 125))
    out = sites.rank(snap, "farms", {"surface": 1, "plots": 1}, {})
    assert out and "muddy floor" in out[0]["why"]


def test_mud_beside_water_is_not_offered_irrigation_is_risky():
    snap = _snap(mud=_block(125, 110, 135, 125), water=[(130, y) for y in range(100, 140)])
    assert sites.rank(snap, "farms", {"surface": 1, "plots": 1}, {}) == []
    msg = sites.farm_ground_why(snap, {})
    assert "mud floor tiles" in msg and "DECISION" in msg
    # soil beside water is as before
    snap2 = _snap(soil=_block(120, 110, 140, 125), water=[(130, 118)])
    assert sites.rank(snap2, "farms", {"surface": 1, "plots": 1}, {})


def test_rock_ground_says_why_and_what_to_decide():
    snap = _snap()                                              # a mountain: no soil, no mud
    assert sites.rank(snap, "farms", {"surface": 1, "plots": 1}, {"zones": {"Z4": [[1, 1, 1, 2, 2, 1]]}}) == []
    msg = sites.farm_ground_why(snap, {})
    assert "no soil and no mud floor" in msg and "DECISION" in msg and "trade.want" in msg and "irrigation" in msg


def test_the_refusal_of_bp_place_carries_the_reason(monkeypatch, tmp_path):
    from dfpilot import cmd
    snap = _snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: {})
    hint = cmd.farm_hint(tmp_path, "farms", {"surface": 1}, snap, 0)
    assert "no soil and no mud floor" in hint and "DECISION" in hint
    assert cmd.farm_hint(tmp_path, "farms", {"surface": 1}, snap, 2) == ""


def test_the_other_walk_group_is_not_offered():
    wg = {"home": 1, "rows": {f"z{Z}": ["0" * 60 for _ in range(40)]}}
    snap = _snap(soil=_block(120, 110, 140, 125), wg=wg)
    assert sites.rank(snap, "farms", {"surface": 1, "plots": 1}, {}) == []


def test_the_dug_farms_room_still_needs_the_manifest():
    snap = _snap(soil=_block(120, 110, 140, 125))
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "farms", {"plots": 1}, None)
    assert "zones.Z4" in str(e.value)


def test_render_counts_mud_as_ground():
    from dfpilot.bp import render
    snap = _snap(mud=_block(120, 110, 140, 125))
    w = render.World.from_snapshot(snap)
    assert (125, 115, Z) in w.soil
