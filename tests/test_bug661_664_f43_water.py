"""BUG-661 .. BUG-664 (Run 16 round 19, 10.11.2026; offline, live-untested).
BUG-661: stranded drink alarms (Lua: tests/lua/test_stranded.lua, test_economy.lua, test_bug615_617_water_deaths.lua); the cistern command
         the alarm suggests must be one `bp sites` answers (the nearest site, however far).
BUG-662: a shaft stopped at an unbuilt ring wall (no water) is no heavy aquifer: after two such stops `bp sites aqshaft` offers no column
         until a ring wall stands (Lua: tests/lua/test_bug662_ring_wall.lua).
BUG-663 / BUG-664: Lua tests (a new shaft starts clean; an unchanged stall is announced once)."""
from __future__ import annotations

import pytest
from test_bug412_413_aquifer_default import X0, Y0, Z, _snap  # noqa: F401

from dfpilot import schema
from dfpilot.bp import sites


def _man(*rows):
    return {"v": 2, "aquifer_levels": [Z - 3, Z - 4], "breaches": list(rows),
            "zones": {"Z4": [[X0 + 36, Y0 + 36, Z, X0 + 60, Y0 + 44, Z]]}}


def _ring(proj, z, x=X0 + 40, y=Y0 + 40):
    return {"pos": [x, y, z], "why": "ring_wall", "proj": proj, "tpl": "aqshaft"}


def test_a_ring_wall_stop_is_no_wet_layer_and_no_breach_point():
    man = _man(_ring("a", Z - 3), _ring("b", Z - 4))
    assert sites.breach_points(man) == []
    assert sites._breach_layers(man) == {}
    assert len(sites.ring_wall_stops(man)) == 2


def test_the_fortcore_ranking_ignores_ring_wall_stops():
    cands = [{"dig": (X0 + 38, Y0 + 38, Z - 3, X0 + 42, Y0 + 42, Z)}]
    assert sites._dry(cands, _man(_ring("a", Z - 3), _ring("b", Z - 3))) == cands


def test_one_ring_wall_stop_still_offers_columns_two_refuse_with_the_cause():
    snap = _snap()
    one = _man(_ring("a", Z - 3))
    try:
        got = sites.rank(snap, "aqshaft", {"depth": 6}, one)
    except ValueError as e:                                  # the fixture may offer none for other reasons: never this one
        assert "ring wall" not in str(e), str(e)
    else:
        assert got is not None
    two = _man(_ring("a", Z - 3), _ring("b", Z - 4))
    with pytest.raises(ValueError, match=r"2 shafts stopped at a ring wall nobody built .*not water.*No column is offered until a ring wall stands"):
        sites.rank(snap, "aqshaft", {"depth": 6}, two)
    assert sites.open_columns(snap, {"depth": 6}, two) == []


def test_the_ring_stop_event_is_in_the_contract():
    assert "AQ_RING_STOP" in schema.EVENTS
    cls, by, _ = schema.EVENTS["AQ_RING_STOP"]
    assert (cls, by) == ("A", "runner")
