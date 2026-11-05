"""BUG-414 / BUG-415 (Round 23, Gordon 04.11.2026: every fort under the aquifer, a heavy layer too; Run 16c i3 Yawninggilt).
BUG-414: the aqshaft rings a known heavy level from above (lua/dfllm/aqshaft.lua, tests/lua/test_bug414_heavy_ring.lua); here the
Python side: the template param `heavy`, the heavy levels read from the manifest breaches, the draft's note.
BUG-415: a running stage 1 on an anchor where a later stage stopped is the running core (no second `fortcore@S1` stage 1-3);
a fort with no fortcore and no way to build one stays below the refuge phase; the fresh sites export is a bounded box and its
wait follows the box."""
from __future__ import annotations

import copy
import json

import pytest
from cli_v2_helpers import RUNTIME, SAVE, make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


# ---------------------------------------------------------------- BUG-414
def test_aqshaft_param_heavy_defaults_to_ring_and_is_validated():
    doc = cmd.emit_at("aqshaft", {"x": 50, "y": 50, "top": 130, "depth": 6}, {"id": "S1", "anchor": [50, 50, 130], "rot": 0},
                      "aq", "t1")
    assert doc["params"]["heavy"] == "ring"
    doc = cmd.emit_at("aqshaft", {"x": 50, "y": 50, "top": 130, "depth": 6, "heavy": "all"},
                      {"id": "S1", "anchor": [50, 50, 130], "rot": 0}, "aq", "t2")
    assert doc["params"]["heavy"] == "all"
    with pytest.raises(Exception, match="aqshaft.heavy"):
        cmd.emit_at("aqshaft", {"x": 50, "y": 50, "top": 130, "depth": 6, "heavy": "bogus"},
                    {"id": "S1", "anchor": [50, 50, 130], "rot": 0}, "aq", "t3")


def test_heavy_levels_are_the_z_of_the_manifests_heavy_breaches():
    man = {"v": 2, "breaches": [{"pos": [10, 10, 127], "why": "heavy_aquifer", "proj": "a", "tpl": "fortcore"},
                                {"pos": [10, 10, 125], "why": "damp", "proj": "b", "tpl": "fortcore"},
                                {"pos": [20, 20, 120], "why": "heavy_aquifer", "proj": "c", "tpl": "aqshaft"},
                                {"pos": [20, 20], "why": "heavy_aquifer", "proj": "d", "tpl": "fortcore"}]}
    assert plan.heavy_levels(man) == [127, 120]
    assert plan.heavy_levels({}) == [] and plan.heavy_levels(None) == []


def test_the_aquifer_draft_names_the_ring_for_recorded_heavy_levels():
    af = {"ok": True, "depth": 5, "aquifers": [127, 126], "heavy": [127],
          "site": {"anchor": [60, 60, 130], "rot": 0, "label": "A60_60_130_0"},
          "col": {"x": 57, "y": 61, "top": 130, "depth": 9, "why": "x"}}
    builds = [{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}]
    out, note = plan.aquifer_core_swap(builds, af, False)
    assert [b["tpl"] for b in out] == ["aqshaft", "fortcore"]
    assert "BUG-414" in note and "z127" in note and "from above" in note, note
    out, note = plan.aquifer_core_swap(builds, {**af, "heavy": []}, False)
    assert "BUG-414" not in note


# ---------------------------------------------------------------- BUG-415: the running core
A = (76, 34, 127)


def _core(save, pid, stage, anchor, rot=0):
    doc = json.loads((RUNTIME / SAVE / "bp" / "y3s0b0.json").read_text("utf-8"))
    doc.update(id=pid, tpl="fortcore", site="S1", anchor=list(anchor), rot=rot, params={"stage": stage}, manifest={"v": 2})
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), "utf-8")


def _no_bp(save):
    for p in (save / "bp").glob("*.json"):
        p.unlink()


def _state(save, rows, phase="P2"):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = phase
    s["proj"] = rows
    s["ready"] = {"lvl": 0, "fail": ["no_inner", "no_outer"]}
    s["bridges"] = {}
    return s


def _facts(save, monkeypatch, st):
    def fake(save_dir, tpl, params=None, snap=None, n=3, where=None, taken=None):
        return [{"id": "S1", "anchor": [10, 10, 130], "rot": 0}], "c201", 3
    monkeypatch.setattr(cmd, "free_sites", fake)
    return plan.fort_facts(save, st)


def _cores(doc):
    return [(b["site"], b["p"]["stage"]) for se in doc["seasons"] for b in se["build"] if b["tpl"] == "fortcore"]


def test_a_later_stage_stopped_on_a_running_core_does_not_resite_it(save, monkeypatch):
    """Run 16c i3 y388: y387s2b2 (stage 3) breach:water, y387s2b0 (stage 1) digging at 4 %: propose drafted fortcore@S1 stage 1-3
    again and the check refused it ('y387s2b0 is the fort's fortcore already')."""
    _no_bp(save)
    files.write_json_atomic(save / "manifest.json", {"v": 2, "breaches": [
        {"pos": [78, 36, 126], "why": "water", "proj": "y387s2b2", "tpl": "fortcore"}]})
    _core(save, "y387s2b0", 1, A)
    _core(save, "y387s2b1", 2, A)
    _core(save, "y387s2b2", 3, A)
    st = _state(save, [["y387s2b0", "s1.dig", 4, "set aside, no runner slot"], ["y387s2b1", "s2.dig", 0, ""],
                       ["y387s2b2", "s3.dig", 0, "parked: breach:water"]])
    fort = _facts(save, monkeypatch, st)
    core = fort["core"]
    assert core and core["moved"]["proj"] == "y387s2b0" and core["moved"]["stages"] == [1, 2], core
    assert core["moved"]["stuck"] == [3] and core["ids"] == ["y387s2b2"], "only the stopped stage is to cancel"
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)
    assert ("S1", 1) not in _cores(doc), _cores(doc)
    assert all(site != "S1" for site, _ in _cores(doc))
    assert "BUG-415" in doc["notes"] and "y387s2b0" in doc["notes"], doc["notes"]
    assert all(k != 3 for _, k in _cores(doc)), "the stage that stopped on this anchor is not drafted there again"
    errs, _ = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if "fortcore" in e], errs


def test_a_stopped_stage_1_still_resites_the_core(save, monkeypatch):
    _no_bp(save)
    files.write_json_atomic(save / "manifest.json", {"v": 2, "breaches": [
        {"pos": [78, 36, 126], "why": "heavy_aquifer", "proj": "y387s2b0", "tpl": "fortcore"}]})
    _core(save, "y387s2b0", 1, A)
    st = _state(save, [["y387s2b0", "s1.dig", 4, "parked: breach:heavy_aquifer"]])
    fort = _facts(save, monkeypatch, st)
    assert fort["core"]["moved"] is None and fort["core"]["resite"] is True
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)
    assert ("S1", 1) in _cores(doc), "BUG-130 still re-sites a core whose own stage 1 stopped"


# ---------------------------------------------------------------- BUG-415: the target without a core
def _nocore_fort(**sf):
    return {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True,
            "surface": {"have": False, "need": True, "why": "the core would cut an aquifer", "site": None, "p": None, **sf}}


def test_no_core_and_no_way_to_build_one_keeps_the_target_below_the_refuge_phase(save):
    st = _state(save, [], phase="P2")
    fort = _nocore_fort(aq={"ok": False, "why": "no fortcore site with a safe shaft column below the aquifer"})
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert doc["phase_target"] < plan.REFUGE_PHASE, doc["phase_target"]
    assert "BUG-415" in doc["notes"] and "safe shaft column" in doc["notes"], doc["notes"]
    errs, _ = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if "no refuge" in e], errs


def test_the_target_is_kept_when_a_core_route_exists_or_a_core_stands(save):
    st = _state(save, [], phase="P2")
    ok = {"ok": True, "depth": 4, "aquifers": [120], "heavy": [], "site": {"anchor": [60, 60, 130], "rot": 0, "label": "A60_60_130_0"},
          "col": {"x": 57, "y": 61, "top": 130, "depth": 9, "why": "x"}}
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=set(), fort=_nocore_fort(aq=ok))
    assert "BUG-415" not in doc["notes"]
    fort = _nocore_fort(aq={"ok": False, "why": "none"})
    fort["core_any"] = True
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)}, fort=fort)
    assert "BUG-415" not in doc["notes"]


# ---------------------------------------------------------------- BUG-415: the bounded sites export
def test_the_fresh_wait_follows_the_box_and_the_default_box_is_bounded(save):
    assert cmd.fresh_wait(None, 60) == 60.0
    small = [0, 0, 100, 99, 99, 107]
    big = [0, 0, 100, 299, 299, 109]
    assert cmd.box_tiles(small) == 80000 and 83.0 < cmd.fresh_wait(small, 60) < 84.0
    assert cmd.fresh_wait(big, 60) > 60 and cmd.fresh_wait(big, 60) <= cmd.SNAP_WAIT_MAX_S
    assert cmd.fresh_wait(big, 500) == 500.0, "the flag is a minimum"
    assert cmd.CORE_TILES <= 150000


def test_wait_snapshot_reports_progress_while_it_waits(save, monkeypatch):
    seen = []
    t = {"now": 0.0}
    monkeypatch.setattr(cmd.time, "monotonic", lambda: t["now"])
    monkeypatch.setattr(cmd.time, "sleep", lambda s: t.__setitem__("now", t["now"] + 5.0))
    assert cmd.wait_snapshot(save, "nosuch", 40, progress=seen.append, every=15.0) is None
    assert seen and seen[0] >= 15.0 and len(seen) >= 2, seen
