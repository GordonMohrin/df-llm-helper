"""Round 35 (perimeter): the bypass over a stair that zeroed every trap, a fresh dig opening that refused the phase raise.
BUG-564 (Run 16c i3 Sealcertain y388-y406): `traps 0` beside 61 armed traps, because the bypass over the hatch 54,132,137 is no tile a
        wall can stand on; min_traps (and with it traps_short and the pop cap held at 40) counted the bypass as a free way.
BUG-567 (Run 16c i3 y372-y375): every gallery / explore dig opened 3-10 ways in; `plan check` refused the raise to P5 with an ERROR that
        named no tile.
(BUG-565 is tests/lua/test_bug565_seal_on_a_building.lua, BUG-566 tests/lua/test_bug566_vegetation_perimeter.lua.)"""
import copy
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import make_runtime, reset_paths                           # noqa: E402

from dfpilot import bp, files, plan, schema, wake                              # noqa: E402


# ---------------------------------------------------------------- BUG-564
def _world(bypass_door="stair"):
    """Route A: the edge tile 0,3,0 over two armed traps (the trap hall Z2) to the core tile 5,3,0. Route B (the bypass): the edge
    stair 1,1,0 up to 1,1,1 and the core tile 2,1,1; no floor tile of it takes a wall."""
    z0 = ["#######", "#<#####" if bypass_door == "stair" else "#+#####", "#######", "......#", "#######"]
    z1 = ["#######", "#>.####", "#######", "#######", "#######"]
    snap = tiny([z0, z1])
    snap["traps"] = [[3, 3, 0, "W", 3, 1], [4, 3, 0, "W", 3, 1]]
    man = {"v": 2, "zones": {"Z2": [[3, 3, 0, 4, 3, 0]], "Z4": [[2, 1, 1, 2, 1, 1], [5, 3, 0, 5, 3, 0]]},
           "edge": [[1, 1, 0], [0, 3, 0]]}
    return snap, man


def test_bug564_a_bypass_over_a_stair_does_not_zero_the_traps_of_the_other_way():
    snap, man = _world()
    info = {}
    res = bp.audit(snap, man, info=info)
    assert [f for f in res["fails"] if f.startswith("bypass: via stair")], res["fails"]    # the bypass stays its own finding
    assert res["bypass"] is True
    assert res["min_traps"] == 2, res["min_traps"]                  # old: 0 (the bypass meets no trap)
    t = info["traps"]
    assert t["via"] == 1 and t["any_route"] == 0 and t["hall"] == 2, t
    note = wake.trap_note(info, {"min_traps": res["min_traps"]})
    assert "counted with 1 bypass tile(s) of a stair, hatch, door or bridge shut" in note and "R0 bypass" in note, note


def test_bug564_without_the_other_way_nothing_is_credited():
    """The only way in is the bypass (no trap on any route that avoids it): still 0, nothing is invented."""
    snap, man = _world()
    snap["traps"] = []
    res = bp.audit(snap, man)
    assert res["min_traps"] == 0


def test_bug564_a_wall_fix_is_unchanged():
    """A bypass a wall closes keeps the old reading (walls, not vias)."""
    z0 = ["#######", "#.....#", "#######", "......#", "#######"]
    snap = tiny([z0])
    snap["traps"] = [[3, 3, 0, "W", 3, 1], [4, 3, 0, "W", 3, 1]]
    man = {"v": 2, "zones": {"Z2": [[3, 3, 0, 4, 3, 0]], "Z4": [[5, 1, 0, 5, 1, 0], [5, 3, 0, 5, 3, 0]]},
           "edge": [[1, 1, 0], [0, 3, 0]]}
    info = {}
    res = bp.audit(snap, man, info=info)
    assert info["traps"].get("via", 0) == 0, info
    assert any(f.startswith("bypass: wall") for f in res["fails"]), res["fails"]
    assert res["min_traps"] == 2


# ---------------------------------------------------------------- BUG-567
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _open(save, pd, ents=None, phase="P3"):
    st = json.loads((save / "state.a.json").read_text("utf-8"))
    base = json.loads((save / "state.a.json").read_text("utf-8"))
    st["phase"] = phase
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 1, "age": 9000, "min_traps": 35},
                   "fail": ["open_perimeter"], "open": 3, "pd": pd, "pw": "3 ways in"}
    if ents is not None:
        st["ready"]["ents"] = ents
    st = dict(st, seq=base["seq"] + 10)
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    return st


def _raise(save, to="P5"):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["phase_target"] = to
    return prev, doc


def _perim(errs, warn):
    return [e for e in errs if e.startswith("perimeter")], [w for w in warn if w.startswith("perimeter")]


ENTS = ["58,64,142 floor", "73,89,142 floor", "71,90,142 pebbles"]


def test_bug567_a_fresh_dig_opening_is_a_warning_naming_the_tiles(save):
    st = _open(save, 1, ENTS)
    prev, doc = _raise(save)
    e, w = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == [], e                                               # old: the ERROR 'raising ... while the perimeter is open'
    assert len(w) == 1 and "a fresh opening" in w[0] and "58,64,142 floor, 73,89,142 floor, 71,90,142 pebbles" in w[0], w
    assert "BUG-567" in w[0] and "seal first" in w[0]


def test_bug567_an_older_opening_still_refuses_and_names_the_tiles(save):
    st = _open(save, 5, ENTS)
    prev, doc = _raise(save)
    e, _ = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert len(e) == 1 and e[0].startswith("perimeter: raising phase_target P3 -> P5 while the perimeter is open for 5 days"), e
    assert "3 ways in at 58,64,142 floor, 73,89,142 floor, 71,90,142 pebbles" in e[0], e[0]       # old: '3 ways in', no tile


def test_bug567_a_fresh_opening_before_the_gate_phase_and_a_plan_that_keeps_the_phase_are_unchanged(save):
    st = _open(save, 1, ENTS, phase="P1")
    prev, doc = _raise(save, "P2")
    e, w = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == [] and w and "by design until B1 stands" in w[0], (e, w)
    st = _open(save, 1, ENTS)
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["phase_target"] = "P3"
    e, w = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == [] and w and "58,64,142 floor" in w[0], (e, w)
