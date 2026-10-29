"""FR-96/FR-97 (goal G14 "everything secured with traps"): the `traps` template (cage lanes outside the doors of the ways
in, the hall's missing stone-fall traps), `traps at=ways|hall` filled in by cmd from the newest snapshot, plan propose /
check from P5, the status line `traps N/M`, fortcore stage 4's manifest entry Z2. Fails on 64df679 (no traps template)."""
import copy
import json
import os
import time

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import bp, brief, cmd, files, plan, schema, traps
from dfpilot.bp import traps as T

# one level: an open surface (rows 0-1, the snapshot border is the outside), a wall with a door at 4,2, the fort room (Z4)
# behind it, and an inner room behind a second door 4,4 (no way in: both sides are the fort)
ROWS = ["..........",
        "..........",
        "####+#####",
        "#........#",
        "####+#####",
        "#........#",
        "##########"]
MAN = {"v": 2, "zones": {"Z4": [[1, 3, 0, 8, 3, 0], [1, 5, 0, 8, 5, 0]]}}


def snap(rows=ROWS, sid="s900", purpose="sites"):
    return {"v": 2, "id": sid, "tick": 0, "purpose": purpose, "bbox": [0, 0, 0, len(rows[0]) - 1, len(rows) - 1, 0],
            "rows": {"z0": list(rows)}, "bridges": {}, "traps": []}


def put(rows, x, y, c):
    rows = list(rows)
    rows[y] = rows[y][:x] + c + rows[y][x + 1:]
    return rows


# ---------------------------------------------------------------- the template
def test_explicit_lane_emits_cage_traps_with_their_manifest_entry():
    d = bp.emit("traps", {"at": "4,2,100:0,-1 -1,-1 1,-1"}, {"id": "S1", "anchor": [4, 1, 100], "rot": 0})
    assert schema.validate("bp", {**d, "id": "c1"}) == [] and bp.check_doc(d) == []
    cells = [t for st in d["stages"] for ch in st["chunks"] for *_, t in ch["cells"]]
    assert cells == ["Tc", "Tc", "Tc"] and d["stages"][0]["orders"] == 1
    assert d["materials"] == {"cage": 3, "cage_trap": 3, "mechanism": 3}
    (e,) = d["manifest"]["traps"]
    assert e["id"] == "T4_2_100" and e["way"] == [4, 2, 100] and e["kind"] == "cage"
    assert sorted(e["tiles"]) == [[3, 1, 100], [4, 1, 100], [5, 1, 100]]
    assert schema.validate("manifest", d["manifest"]) == []


def test_rotation_keeps_the_absolute_tiles():
    for rot in range(4):
        d = bp.emit("traps", {"at": "4,2,100:0,-1 1,-1"}, {"id": "S1", "anchor": [4, 1, 100], "rot": rot})
        assert sorted(d["manifest"]["traps"][0]["tiles"]) == [[4, 1, 100], [5, 1, 100]], rot


def test_hall_is_stone_only_and_has_no_way_entry():
    with pytest.raises(ValueError, match="no cage traps in the trap hall"):
        bp.emit("traps", {"at": "hall:5,5,9 6,5,9"}, {"id": "S1", "anchor": [5, 5, 9], "rot": 0})
    d = bp.emit("traps", {"at": "hall:5,5,9 6,5,9", "kind": "stone"}, {"id": "S1", "anchor": [5, 5, 9], "rot": 0})
    assert [t for st in d["stages"] for ch in st["chunks"] for *_, t in ch["cells"]] == ["Ts", "Ts"]
    assert "traps" not in d["manifest"] and "cage" not in d["materials"]


@pytest.mark.parametrize("at, why", [("ways", "filled in by dfllm cmd"), ("hall", "filled in by dfllm cmd"),
                                     ("4,2,1:0,0", "not on the door"), ("4,2,1:9,0", "at most 4 away"),
                                     ("4,2,1:0,-1;5,2,1:-1,-1", "named twice"),
                                     ("hall:" + " ".join(f"{x},1,1" for x in range(17)), "> 16")])
def test_bad_at_is_refused(at, why):
    with pytest.raises(ValueError, match=why):
        T.pieces({"at": at, "kind": "stone" if at.startswith("hall:") else "cage"})


def test_format_at_keeps_whole_lanes_and_cuts_the_hall():
    lanes = [{"way": [100 + i, 200, 150], "tiles": [[100 + i, 199, 150], [99 + i, 199, 150], [101 + i, 199, 150]]}
             for i in range(0, 30, 3)]
    at = T.format_at(lanes)
    assert len(at) <= T.AT_MAX and all(len(p["tiles"]) == 3 for p in T.parse_at(at))
    hall = T.format_at([{"way": None, "tiles": [[100 + i, 200, 150] for i in range(30)]}])
    assert len(hall) <= T.AT_MAX and 1 <= len(T.parse_at(hall)[0]["tiles"]) <= T.TRAP_MAX


def test_fortcore_stage4_lists_the_hall_traps_as_z2():
    docs = bp.emit_all("fortcore", {}, {"id": "S1", "anchor": [70, 70, 100], "rot": 2})
    assert all("traps" not in d["manifest"] for d in docs[:3])
    (e,) = docs[3]["manifest"]["traps"]
    built = {tuple(t[:3]) for t in bp.as_built(docs).snapshot()["traps"]}
    assert e["id"] == "Z2" and e["kind"] == "stone" and {tuple(t) for t in e["tiles"]} == built and len(built) == 41


# ---------------------------------------------------------------- the ways in
def test_ways_in_finds_the_perimeter_door_only():
    ws = T.ways_in(snap(), MAN, 1)
    assert [w["way"] for w in ws] == [[4, 2, 0]]                       # 4,4 joins two fort rooms
    assert sorted(ws[0]["tiles"]) == [[3, 1, 0], [4, 1, 0], [5, 1, 0]] and not ws[0]["partial"]
    deep = T.ways_in(snap(), MAN, 2)[0]["tiles"]
    assert [4, 0, 0] in deep and len(deep) == 4                        # straight out from the front tile


def test_trapped_and_covered_tiles_are_left_out_and_a_ramp_is_partial():
    rows = put(put(ROWS, 3, 1, "^"), 4, 1, "^")
    (w,) = T.ways_in(snap(rows), MAN, 1, covered={(5, 1, 0)})
    assert w["tiles"] == [] and w["trapped"]
    rows = put(ROWS, 5, 1, "r")
    (w,) = T.ways_in(snap(rows), MAN, 1)
    assert w["partial"] and sorted(w["tiles"]) == [[3, 1, 0], [4, 1, 0]]


def test_an_open_way_in_makes_the_room_behind_it_outside():
    """A gap without a door (8,2) is an open way in: `seal` closes it first; the door behind it (4,4) is then the way in."""
    ws = T.ways_in(snap(put(ROWS, 8, 2, ".")), MAN, 1)
    assert [w["way"] for w in ws] == [[4, 4, 0]]


def test_no_fort_geometry_no_ways():
    assert T.ways_in(snap(), {"v": 2}, 1) == []


# ---------------------------------------------------------------- the CLI: at=ways / at=hall
@pytest.fixture
def fort(tmp_path):
    d = tmp_path / "save"
    (d / "snap").mkdir(parents=True)
    (d / "bp").mkdir()
    (d / "manifest.json").write_text(json.dumps(MAN), encoding="utf-8")
    (d / "snap" / "s900.json").write_text(json.dumps(snap()), encoding="utf-8")
    return d


def test_place_ways_fills_the_lanes_then_says_nothing_is_left(fort):
    doc = cmd.place(fort, "traps", {"at": "ways"}, "S1", "c901")
    assert T.parse_at(doc["params"]["at"]) == [{"way": [4, 2, 0], "tiles": [[3, 1, 0], [4, 1, 0], [5, 1, 0]]}]
    assert doc["anchor"] == [3, 1, 0] and doc["manifest"]["traps"][0]["id"] == "T4_2_0"
    cmd.write_bp(fort, doc)
    with pytest.raises(cmd.SealClosed, match="no way in left to trap"):     # the project under way covers the lane
        cmd.place(fort, "traps", {"at": "ways"}, "S1", "c902")
    assert traps.facts(fort) == {"doors": 1, "open": 0, "trapped": 1, "partial": 0, "ways": []}


def test_place_hall_needs_a_done_stage4_and_takes_the_missing_tiles(fort, monkeypatch):
    with pytest.raises(cmd.BpError, match="fortcore stage 4"):
        cmd.place(fort, "traps", {"at": "hall"}, "S1", "c903")
    s4 = {"v": 2, "id": "c800", "tpl": "fortcore", "site": "S1", "class": "defense", "params": {"stage": 4},
          "anchor": [0, 0, 0], "rot": 0, "manifest": {"v": 2}, "materials": {},
          "stages": [{"label": "s4.build", "mode": "build", "orders": 1, "defense": 1,
                      "chunks": [{"pos": [1, 1, 0], "cells": [[0, 0, 0, "Ts"], [1, 0, 0, "Ts"], [2, 0, 0, "Ts"]]}]}]}
    files.write_json_atomic(fort / "bp" / "c800.json", s4)
    monkeypatch.setattr(cmd, "done_ticks", lambda save_dir: {"c800": 5})
    rows = put(ROWS, 2, 1, "^")                                         # 2,1 still stands; 1,1 and 3,1 are gone
    (fort / "snap" / "s900.json").write_text(json.dumps(snap(rows)), encoding="utf-8")
    p = {"at": "hall"}
    at, _ = traps.expand(fort, p, None)
    assert p["kind"] == "stone" and T.parse_at(at) == [{"way": None, "tiles": [[1, 1, 0], [3, 1, 0]]}]


# ---------------------------------------------------------------- plan propose / check
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "traps")
OPEN = {"traps": {"doors": 2, "open": 2, "trapped": 0, "partial": 0, "ways": ["4,2,0", "9,9,0"]}}


def test_propose_drafts_traps_at_ways_from_p5_once(save):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    state = files.read_state(save)
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s = copy.deepcopy(state)
    s["phase"] = "P5"
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort=OPEN)
    builds = [b for se in doc["seasons"] for b in se["build"]]
    assert builds.count(traps.TRAPS_WAYS) == 1 and "FR-96: 2 way(s) in without a trap lane" in doc["notes"]
    assert schema.validate("plan", doc) == []
    again = plan.propose(s, phases, doc, decisions={}, tinfo=tinfo, fort=OPEN)     # same year: not twice
    assert sum(b["tpl"] == "traps" for se in again["seasons"] for b in se["build"]) == 1
    s["phase"] = "P2"
    early = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort=OPEN, upto="P3")
    assert not any(b["tpl"] == "traps" for se in early["seasons"] for b in se["build"])
    s["phase"] = "P5"
    none = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={"traps": {"open": 0}})
    assert "FR-96" not in none["notes"]


def test_check_warns_without_a_traps_build_from_p5(save):
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    state = files.read_state(save)
    d = copy.deepcopy(doc)
    d["phase_target"] = "P5"
    w = [x for x in plan.check(d, state, decisions={}, banned=plan.BANNED, fort=OPEN)[1] if x.startswith("traps:")]
    assert len(w) == 1 and '{"tpl":"traps","site":"S1","p":{"at":"ways"}}' in w[0] and "4,2,0" in w[0]
    d["seasons"][3]["build"].append(copy.deepcopy(traps.TRAPS_WAYS))
    assert not [x for x in plan.check(d, state, decisions={}, banned=plan.BANNED, fort=OPEN)[1] if x.startswith("traps:")]
    d["phase_target"] = "P4"
    d["seasons"][3]["build"].pop()
    assert not [x for x in plan.check(d, state, decisions={}, banned=plan.BANNED, fort=OPEN)[1] if x.startswith("traps:")]


def test_traps_are_a_defense_build():
    assert plan.build_kind(traps.TRAPS_WAYS) == "defense"


# ---------------------------------------------------------------- status / brief
def test_status_and_brief_show_traps_n_of_m(save):
    st = files.read_state(save)
    st["traps"] = {"n": 38, "m": 44, "b": 42, "w": 2, "wn": 3, "f": 1, "c": 0, "l": 2, "lh": 1,
                   "ord": "MakeCage x3 ordered"}
    assert schema.validate("state", st) == []
    for n in ("a", "b"):
        (save / f"state.{n}.json").write_text(json.dumps(st), encoding="utf-8")
    line = "traps 38/44 ways 2/3, 1 full, cages 0 (MakeCage x3 ordered), lost 2 (bp.place traps at=hall)"
    assert traps.status_line(st) == line
    assert line in brief.brief_text(save)
    assert "traps 38/44" in brief.status_text(save)
    assert traps.status_line({"traps": {"n": 3, "m": 3}}) == "traps 3/3" and traps.status_line({}) == ""
