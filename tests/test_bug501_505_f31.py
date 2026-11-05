"""BUG-501 .. BUG-505, Python side (Run 16a i1 Basementflew, 16b i2 Roadvises, 05.11.2026; offline, live-untested). The Lua side
(tree-crown roof in the entrance check, the reach check of runner.repair, the seal question naming the way that stays) is in
tests/lua/test_bug503_505_sealreach.lua.
BUG-501: a hand-placed fortcore stage 1 that follow's BUG-441 re-site would cancel is refused by bp.place at once, with the reason.
BUG-502: an explicit anchor passes the ranking's tests (aqshaft top tile, hospital water), the aqshaft ranking names its holders and
         a finished aqshaft holds only the levels it dug.
BUG-504: `traps at=ways` counts the doors a finished seal project built."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths
from test_bug412_413_aquifer_default import Z, _snap  # noqa: F401
from test_bug441_445_f28 import _bp, world  # noqa: F401  (the aquifer world fixture)

from dfpilot import cmd, files, plan, traps


# ---------------------------------------------------------------- BUG-501
def _core(anchor, **p):
    return {"tpl": "fortcore", "anchor": list(anchor), "params": {"stage": 1, "depth": 3, "refuge": 3, **p}}


def test_core_refusal_is_the_test_follow_makes_later(world):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    why = plan.core_refusal(save, _core((110, 110, 125)))
    assert "BUG-501" in why and "z112" in why and "p.aquifer" in why, why
    # what follow lets stand: p.aquifer, a retrofit, a later stage, a core whose deepest level lies under the lowest level
    assert plan.core_refusal(save, _core((110, 110, 125), aquifer="pass")) == ""
    assert plan.core_refusal(save, _core((110, 110, 125), retrofit=2)) == ""
    assert plan.core_refusal(save, _core((110, 110, 125), stage=2)) == ""
    assert plan.core_refusal(save, _core((110, 110, 112))) == ""
    assert plan.core_refusal(save, {"tpl": "hospital", "anchor": [1, 2, 3], "params": {}}) == ""
    box["man"] = {"v": 2}                                           # no aquifer known: the probe decides
    assert plan.core_refusal(save, _core((110, 110, 125))) == ""
    # the same anchor core_over_aquifer cancels later is the one refused now
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "depth": 3, "refuge": 3})
    hit = plan.core_over_aquifer(save, {"proj": [["c1a1core", "s1.dig", 0]]})
    assert hit and hit["proj"] == "c1a1core"


def test_bp_place_refuses_a_core_follow_would_cancel_and_writes_nothing(world):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [118]}
    with pytest.raises(cmd.BpError, match=r"BUG-501.*z118"):
        cmd.send(save, "bp.place", {"tpl": "fortcore", "site": "A110_110_130_0"}, wait_s=0)
    assert not list((save / "bp").glob("c1a1*.json"))
    # p.aquifer=pass is placed (its own gate), the aquifer level is no objection
    cmd.send(save, "bp.place", {"tpl": "fortcore", "site": "A110_110_130_0", "p": {"aquifer": "pass"}}, wait_s=0)


# ---------------------------------------------------------------- BUG-502
def test_aqshaft_top_test_is_one_function_for_the_ranking_and_the_anchor():
    assert cmd.aq_top_ok(None) and cmd.aq_top_ok(("y1", "fortcore")) and cmd.aq_top_ok(("y2", "aqshaft"))
    assert cmd.aq_top_ok(("y3", "explore"))
    assert not cmd.aq_top_ok(("y4", "hospital")) and not cmd.aq_top_ok(("y5", "tombs"))


def test_an_explicit_aqshaft_anchor_on_a_placed_rooms_floor_is_refused_like_the_ranking(world):
    save, box = world
    occ = cmd.Occupancy()
    occ.owner[(100, 100, 129)] = ("y9s0b1", "hospital")
    with pytest.raises(cmd.BpError, match=r"y9s0b1.*BUG-502"):
        cmd.anchor_checked(save, "aqshaft", {}, [100, 100, 129], None, occ)
    cmd.anchor_checked(save, "aqshaft", {}, [101, 100, 129], None, occ)          # open ground: fine


def test_the_aqshaft_ranking_names_the_holder_of_a_top_tile_and_the_reason(world, monkeypatch):
    save, box = world
    occ = cmd.Occupancy()
    occ.owner[(105, 105, 129)] = ("y9s0b1", "hospital")
    monkeypatch.setattr(cmd, "occupancy", lambda *a, **k: occ)
    free = cmd._free_of_projects(save, "aqshaft", {"depth": 4})
    assert free({"anchor": [105, 105, 129], "rot": 0}) is False
    assert free.held == {"y9s0b1"} and free.why == {"top": 1}, (free.held, free.why)


def test_a_finished_aqshaft_holds_only_the_levels_it_dug(world):
    save, box = world
    doc = cmd.emit_at("aqshaft", {"x": 120, "y": 120, "top": 129, "depth": 12}, {"id": "S0", "anchor": [120, 120, 129], "rot": 0},
                      "S0", "c1a1shaft")
    files.write_json_atomic(save / "bp" / "c1a1shaft.json", doc)
    full = cmd.occupancy(save)
    assert (120, 120, 118) in full.owner, "unfinished: the whole plan is reserved"
    append_events(save, [ev(900, "AQ_PASS_DONE", "x", {"proj": "c1a1shaft", "top": 129, "bot": 125, "lv": [127], "n": 1}, tick=900)])
    occ = cmd.occupancy(save)
    assert (120, 120, 129) in occ.owner and (120, 120, 125) in occ.owner, "the dug levels stay held"
    assert (120, 120, 124) not in occ.owner and (120, 120, 118) not in occ.owner, "the planned rest is released"


def test_a_hospital_anchor_the_ranking_would_not_offer_is_refused(world, monkeypatch):
    save, box = world
    monkeypatch.setattr(cmd, "water_ctx", lambda _d, _t, state=None: {"src": [[120, 113, 130]], "near": 30})
    seen = {}

    def refuse(_d, tpl, params, snap, n=3, manifest=None, where=None):
        seen["where"] = where
        raise cmd.BpError("hospital: no site within 30 tiles of accepted water")
    monkeypatch.setattr(cmd, "rank_sites", refuse)
    with pytest.raises(cmd.BpError, match=r"hospital@A112_100_131.*BUG-502.*no site within 30 tiles"):
        cmd.anchor_checked(save, "hospital", {}, [112, 100, 131], box["snap"])
    assert seen["where"] == {"at": [112, 100, 131]}
    monkeypatch.setattr(cmd, "rank_sites", lambda *a, **k: [{"id": "S1"}])
    cmd.anchor_checked(save, "hospital", {}, [112, 100, 131], box["snap"])         # the ranking offers it: placed
    monkeypatch.setattr(cmd, "water_ctx", lambda *a, **k: None)                    # no water state: unchecked, as before
    monkeypatch.setattr(cmd, "rank_sites", refuse)
    cmd.anchor_checked(save, "hospital", {}, [112, 100, 131], box["snap"])


def test_the_near_water_error_points_at_the_surface_variant_and_the_anchor_test():
    from dfpilot.bp import sites
    cand = {"anchor": [0, 0, 0], "rot": 0, "score": 1, "why": "x", "box": [0, 0, 0, 1, 1, 1]}
    with pytest.raises(ValueError, match=r"surface=1.*BUG-502"):
        sites._near_water([cand], "hospital", sites.check_params("hospital", {}), {"src": [[500, 500, 0]], "near": 30})


# ---------------------------------------------------------------- BUG-504: traps at=ways counts the seal's doors
YARD = ["...........",
        ".#########.",
        ".#.......#.",
        ".#.......#.",
        ".#.......#.",
        ".#########.",
        "..........."]
ROOF = ["_" * 11] + ["#" * 11] * 5 + ["_" * 11]       # the yard is roofed (rock above): no climbing over its walls


def _yard(door_in_snapshot: bool):
    rows = [list(r) for r in YARD]
    rows[3][9] = "+" if door_in_snapshot else "."         # the east wall's door; a snapshot read before it was built shows a gap
    rows[3][9] = "+" if door_in_snapshot else "#"
    return {"v": 2, "id": "s504", "tick": 100, "purpose": "sites", "bbox": [0, 0, 0, 10, 6, 1],
            "rows": {"z0": ["".join(r) for r in rows], "z1": ROOF}, "marks": {}}


@pytest.fixture
def seal_world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    (d / "events.1.jsonl").unlink(missing_ok=True)
    box = {"snap": _yard(True)}
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: {"v": 2})
    yield d, box
    reset_paths()


def _seal_doc(pid, x=9, y=3, z=0):
    return {"tpl": "seal", "id": pid, "anchor": [x, y, z], "rot": 0, "v": 2, "class": "defense", "site": "S1",
            "params": {"at": f"{x},{y},{z} floor", "close": "auto"}, "manifest": {"v": 2}, "materials": {"door": 1},
            "stages": [{"label": "seal.build", "mode": "build", "orders": 1, "defense": 1,
                        "chunks": [{"pos": [x, y, z], "cells": [[0, 0, 0, "d"]]}]}]}


def test_traps_at_ways_counts_the_door_a_finished_seal_built(seal_world):
    save, box = seal_world
    # the yard is no manifest box: before the fix ways_in found nothing ('0 door(s) between the outside and the fort')
    files.write_json_atomic(save / "bp" / "c1a1seal.json", _seal_doc("c1a1seal"))
    append_events(save, [ev(500, "PROJECT_DONE", "x", {"proj": "c1a1seal"}, tick=500)])
    ws = traps.lanes(save, box["snap"])
    assert [w["way"] for w in ws] == [[9, 3, 0]], ws
    assert ws[0]["tiles"], "its outside neighbours want a lane"
    at, notes = traps.expand(save, {"at": "ways"}, box["snap"])
    assert at.startswith("9,3,0:") and "1,0" in at, at          # the lane: the door and its outside neighbours


def test_a_snapshot_read_before_the_seal_door_stood_is_patched_with_the_door(seal_world):
    save, box = seal_world
    box["snap"] = _yard(False)                                 # the sites snapshot (tick 100) shows the wall's gap as a wall
    snap = _yard(False)
    rows = [list(r) for r in YARD]
    rows[3][9] = "."
    snap["rows"]["z0"] = ["".join(r) for r in rows]            # floor where the door will be
    box["snap"] = snap
    files.write_json_atomic(save / "bp" / "c1a1seal.json", _seal_doc("c1a1seal"))
    append_events(save, [ev(500, "PROJECT_DONE", "x", {"proj": "c1a1seal"}, tick=500)])
    doors, patched = traps.seal_doors(save, snap)
    assert doors == {(9, 3, 0)} and patched["rows"]["z0"][3][9] == "+"
    assert snap["rows"]["z0"][3][9] == ".", "the snapshot itself is not changed"
    assert [w["way"] for w in traps.lanes(save, snap)] == [[9, 3, 0]]
    # a snapshot NEWER than the door that shows floor: the door is gone, nothing is patched
    snap["tick"] = 900
    assert traps.seal_doors(save, snap)[1]["rows"]["z0"][3][9] == "."


def test_no_finished_seal_no_change(seal_world):
    save, box = seal_world
    files.write_json_atomic(save / "bp" / "c1a1seal.json", _seal_doc("c1a1seal"))      # placed, not done
    assert traps.seal_doors(save, box["snap"])[0] == set()
    with pytest.raises(cmd.SealClosed, match="no way in left"):
        traps.expand(save, {"at": "ways"}, box["snap"])
