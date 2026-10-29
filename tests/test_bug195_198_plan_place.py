"""Live test round 3 (y728 Trussroads; fresh fort Earthboat), plan propose vs plan check:
BUG-195: propose drafted fortcore@same stage 2 that check refused ('overlaps project(s) y721s3b2'); a later core stage also
clashed with a seal wall on its own stage-1 tiles.
BUG-196: the anchor exemption of Occupancy.clash was one-sided: a room that opened off a fortcore corridor blocked the
core's later stage that re-emits the corridor.
BUG-197: on a fresh fort (no fortcore, no Z4) propose drafted room builds check could never site, ran no placement dry
run, core_order_note said 'not dug yet' for s1.build and the hospital note tripped the fair-play word 'source'.
BUG-198: propose took order libraries from every phase up to the target (P3 libs for a P0 fort)."""
import argparse
import copy
import json
import sys
import types

import pytest
from cli_v2_helpers import install_fake_bp, make_runtime, reset_paths

from dfpilot import cmd, files, plan

A = [10, 10, 5]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for p in cmd.bp_files(d):
        p.unlink()
    yield d
    reset_paths()


def _doc(bid, anchor, cells, tpl="tombs", mode="dig", params=None):
    return {"v": 2, "id": bid, "tpl": tpl, "site": "S1", "class": "living", "params": dict(params or {}),
            "anchor": list(anchor), "rot": 0,
            "stages": [{"label": "s1.dig", "mode": mode, "orders": 0, "defense": 0,
                        "chunks": [{"pos": list(anchor), "cells": cells}]}],
            "manifest": {"v": 2}, "materials": {}}


def _core_cells(stage):
    """Stage 1: the corridor y=0 (x 0..9); stage 2: a new row y=-3; stage 3: the corridor again plus a row y=-6."""
    return {1: [[0, 0, 0, "d(10x1)"]], 2: [[0, -3, 0, "d(10x1)"]],
            3: [[0, 0, 0, "d(10x1)"], [0, -6, 0, "d(10x1)"]]}[stage]


def _fake_core_bp(monkeypatch):
    install_fake_bp(monkeypatch)
    em = sys.modules["dfpilot.bp.emit"]

    def emit(tpl, params, site):
        st = params.get("stage", 1)
        if tpl == "fortcore" and st > 3:
            raise ValueError("past the last stage")
        d = _doc("x", site["anchor"], _core_cells(st) if tpl == "fortcore" else [[0, 0, 0, "d"]], tpl=tpl,
                 params=params)
        d.pop("id")
        d["site"] = site["id"]
        return d
    em.emit = emit
    em.FREE = ("seal",)


def _write(save, doc):
    (save / "bp" / f"{doc['id']}.json").write_text(json.dumps(doc), "utf-8")


def _placed_core(save):
    _write(save, _doc("y372s0b0", A, _core_cells(1), tpl="fortcore", params={"stage": 1}))
    files.write_json_atomic(save / "bp" / ".placed-fortcore.json", {"anchor": A, "rot": 0, "bp": "y372s0b0"})


# ---------------------------------------------------------------- BUG-196: the anchor exemption holds both ways
def test_a_room_off_the_corridor_does_not_block_the_cores_later_stage():
    occ = cmd.Occupancy()
    A0 = [0, 0, 5]
    occ.add(_doc("core1", A0, [[0, 0, 0, "d(10x1)"]], tpl="fortcore"))
    occ.add(_doc("r1", [4, 0, 5], [[0, 1, 0, "d"], [-1, 2, 0, "d(3x3)"]]))          # opens off the corridor at (4,0)
    st3 = _doc("core3", A0, [[0, 0, 0, "d(10x1)"], [0, -2, 0, "d(10x1)"]], tpl="fortcore")
    assert occ.clash(st3, ignore_tpl="fortcore") == []          # (3..5,0) touch r1's doorway next to r1's anchor
    far = _doc("core4", A0, [[6, 3, 0, "d"]], tpl="fortcore")     # (6,3) touches r1's (5,3): far from r1's anchor
    assert occ.clash(far, ignore_tpl="fortcore") == ["r1"]
    occ.add(_doc("cis", [8, 0, 5], [[0, 1, 0, "d"]], tpl="cistern"))               # a basin is never a room
    assert occ.clash(_doc("core5", A0, [[7, 1, 0, "d"]], tpl="fortcore"), ignore_tpl="fortcore") == ["cis"]


# ---------------------------------------------------------------- BUG-195: own tiles and the propose dry run
def test_same_stage_ignores_tiles_its_own_placed_stages_dig(save, monkeypatch):
    _fake_core_bp(monkeypatch)
    _placed_core(save)
    _write(save, _doc("c1a185ed14e27ebd07", [15, 10, 5], [[0, 0, 0, "Cw"]], tpl="seal", mode="build"))  # wall on the corridor
    _write(save, _doc("c1a185e68ea2802c02", [14, 10, 5], [[0, 1, 0, "d"], [-1, 2, 0, "d(3x1)"]], tpl="workshops"))
    d = cmd.place(save, "fortcore", {"stage": 3}, cmd.SAME, "y372s1b0")
    assert d["anchor"] == A


def test_propose_leaves_a_blocked_core_stage_out_and_names_the_cancel(save, monkeypatch):
    _fake_core_bp(monkeypatch)
    _placed_core(save)
    _write(save, _doc("y721s3b2", [13, 6, 5], [[0, 0, 0, "d(2x1)"]], tpl="refuge_beds"))   # touches stage 2 row
    doc = {"v": 2, "year": 728, "notes": "draft", "seasons": [
        {"build": [{"tpl": "seal", "site": "S1", "p": {"at": "audit"}},
                   {"tpl": "fortcore", "site": "same", "p": {"stage": 2}},
                   {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]}, {"build": []}, {"build": []}, {"build": []}]}
    out = plan.fit_core(save, doc, None)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["seal"]
    assert "dfllm cmd bp.cancel proj=y721s3b2" in out[0] and "stage 2" in out[0] and "with stage 2" in out[1]
    assert "BUG-195" in doc["notes"]
    ok = copy.deepcopy(doc)
    ok["seasons"][0]["build"].append({"tpl": "fortcore", "site": "same", "p": {"stage": 3}})
    (save / "bp" / "y721s3b2.json").unlink()
    assert plan.fit_core(save, ok, None) == [] and len(ok["seasons"][0]["build"]) == 2


def test_propose_prints_the_placement_dry_run(save, monkeypatch, capsys):
    monkeypatch.setattr(plan, "check", lambda *a, **k: ([], []))
    monkeypatch.setattr(plan, "fit_explore", lambda *a, **k: None)
    monkeypatch.setattr(plan, "fit_core", lambda *a, **k: [])

    def boom(*a, **k):
        raise cmd.BpError("fortcore@same [100, 82, 140] overlaps project(s) c1a185e68ea2802c02")
    monkeypatch.setattr(plan, "place_all", boom)
    args = argparse.Namespace(action="propose", file=str(save / "d.json"), phases=None)
    assert plan.run(args, save) == 0
    assert "ERROR blueprint: fortcore@same [100, 82, 140] overlaps project(s) c1a185e68ea2802c02" in capsys.readouterr().out


# ---------------------------------------------------------------- BUG-197: a fresh fort
def _p0_state(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P0"
    s["proj"] = []
    return s


def test_a_fresh_fort_drafts_only_the_core_first(save):
    s = _p0_state(save)
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort={"z4": False, "core_any": False})
    built = [b for se in doc["seasons"] for b in se["build"]]
    assert built and all(b["tpl"] in ("fortcore", "seal") for b in built), built
    assert {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}} in built
    assert doc["phase_target"] == "P0" and "apply, wait for s1.dig, propose again" in doc["notes"]
    # with a Z4 floor (or a fortcore project) the draft is the usual one
    full = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort={"z4": True})
    assert any(b["tpl"] not in ("fortcore", "seal") for se in full["seasons"] for b in se["build"])


def test_core_order_note_needs_the_dig_and_speaks_without_a_core():
    doc = {"seasons": [{"build": [{"tpl": "farms", "site": "S1"}]}, {"build": []}, {"build": []}, {"build": []}]}
    assert plan.core_order_note(doc, {"proj": [["y372s0b0", "s1.build", 28, ""]]}) is None    # the dig is done
    assert plan.core_order_note(doc, {"proj": [["y372s0b0", "s1.dig", 28, ""]]})
    note = plan.core_order_note(doc, {"proj": []}, {"z4": False, "core_any": False})
    assert note and "no fortcore project" in note and "wait for s1.dig, propose again" in note
    assert plan.core_order_note(doc, {"proj": []}, {"z4": True}) is None


def test_the_hospital_water_note_has_no_blocked_word():
    import inspect
    src = inspect.getsource(plan.propose)
    assert "Water Source" not in src


# ---------------------------------------------------------------- BUG-198: order libraries
def test_order_libraries_come_from_the_next_phase_at_most():
    phases = {"phases": [{"id": f"P{i}", "approve": False, "deliver": [{"k": "orders", "lib": f"library/l{i}"}]}
                         for i in range(5)]}
    s = {"t": {"y": 5, "season": 0}, "phase": "P1", "pop": {"cit": 7}}
    doc = plan.propose(s, phases, None, decisions={}, tinfo={}, applied=set(), fort={})
    assert doc["phase_target"] == "P4" and doc["orders"]["import"] == ["library/l1", "library/l2"]
