"""BUG-661 .. BUG-664 (Run 16 round 19, 10.11.2026; offline, live-untested).
BUG-661: stranded drink alarms (Lua: tests/lua/test_stranded.lua, test_economy.lua, test_bug615_617_water_deaths.lua); the cistern command
         the alarm suggests must be one `bp sites` answers (the nearest site, however far).
BUG-662: a shaft stopped at an unbuilt ring wall (no water) is no heavy aquifer (Lua: tests/lua/test_bug662_ring_wall.lua).
BUG-677: instead of a lockout after two such stops, a live wall-material gate (cmd.aq_wall_gate, state.stock.wall) on ranking / place.
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


def test_ring_wall_stops_never_lock_a_column_out_in_the_site_ranking():
    """BUG-677: the first attempt refused every column for good after two stops; the ranking itself no longer reads them."""
    snap = _snap()
    two = _man(_ring("a", Z - 3), _ring("b", Z - 4))
    try:
        sites.rank(snap, "aqshaft", {"depth": 6}, two)
    except ValueError as e:                                  # the fixture may offer none for other reasons: never this one
        assert "ring wall" not in str(e), str(e)


def _state(wall):
    return {"stock": {"wall": wall}} if wall is not None else {"stock": {}}


def test_the_wall_gate_refuses_without_wall_material_and_clears_with_it(tmp_path, monkeypatch):
    from dfpilot import cmd, files
    from dfpilot.cmd import BpError
    monkeypatch.setattr(files, "read_state", lambda d: _state(0))
    monkeypatch.setattr(cmd, "fort_manifest", lambda d: _man(_ring("a", Z - 3), _ring("b", Z - 4)))
    with pytest.raises(BpError, match=r"no wall material.*usable blocks.*0, need 3.*2 earlier shaft.*not water.*trade.want"):
        cmd.aq_wall_gate(tmp_path, "aqshaft", {})
    with pytest.raises(BpError, match="need 2"):
        cmd.aq_wall_gate(tmp_path, "aqshaft", {"heavy": "off"})
    monkeypatch.setattr(files, "read_state", lambda d: _state(3))           # stone now available: no lockout, nothing to clear by hand
    cmd.aq_wall_gate(tmp_path, "aqshaft", {})
    monkeypatch.setattr(files, "read_state", lambda d: _state(None))        # an older kernel: unknown stock is no refusal
    cmd.aq_wall_gate(tmp_path, "aqshaft", {})
    monkeypatch.setattr(files, "read_state", lambda d: _state(0))
    cmd.aq_wall_gate(tmp_path, "fortcore", {})                              # other templates are not gated


def test_the_wall_gate_stops_the_ranking_and_place_of_an_aqshaft(tmp_path, monkeypatch):
    from dfpilot import cmd, files
    from dfpilot.cmd import BpError
    monkeypatch.setattr(files, "read_state", lambda d: _state(1))
    for call in (lambda: cmd.ranking(tmp_path, "aqshaft", {}), lambda: cmd.rank_sites(tmp_path, "aqshaft", {}),
                 lambda: cmd.place(tmp_path, "aqshaft", {}, "S1", "x")):
        with pytest.raises(BpError, match="no wall material"):
            call()


def test_the_ring_stop_event_is_in_the_contract():
    assert "AQ_RING_STOP" in schema.EVENTS
    cls, by, _ = schema.EVENTS["AQ_RING_STOP"]
    assert (cls, by) == ("A", "runner")
