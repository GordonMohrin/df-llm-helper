"""Round 44 (start): BUG-690 an embark with no trees and no stone near the surface is a hard reject that --accept trees cannot clear, and a
fort that starts with not one free usable boulder drafts the stone dig first (and asks the caravan for wood and blocks) before the shaft and
the depot. The Lua side is tests/lua/test_embark_bug690.lua."""
import copy
import importlib.util
from pathlib import Path

import pytest

from dfpilot import plan

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("embark_drv", ROOT / "tools" / "embark" / "embark.py")
drv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drv)


def test_bug690_timber_is_a_hard_reject_in_both_lists():
    assert "timber" in drv.HARD_REJECT and "timber" not in drv.ACCEPTABLE and "timber" not in drv.WAIVABLE
    lua = (ROOT / "tools" / "embark" / "checklist.lua").read_text(encoding="utf-8")
    assert "timber = '" in lua and "BUG-690" in lua
    with pytest.raises(ValueError, match="timber"):
        drv.make_spec("embark", site=[28, 13], accept=["timber"], reason="x" * 5)


def test_bug690_accepting_trees_alone_is_still_a_spec_but_the_gate_refuses_the_site():
    """the spec is valid (trees is acceptable); site.gate refuses it because the 'timber' fail is not in `accept` (tests/lua)"""
    spec = drv.make_spec("embark", site=[28, 13], accept=["trees"], reason="bad trees")
    assert [a["id"] for a in spec["accept"]] == ["trees"]


def _state(rock, phase="P0", need=0):
    return {"phase": phase, "stock": {"rock": rock, "rock_need": need}}


def test_bug690_start_dry_only_with_zero_usable_boulders_in_the_first_phases():
    assert plan.start_dry(_state(0)).startswith("start: no free usable boulder")
    assert plan.start_dry(_state(0, "P2"))
    assert plan.start_dry(_state(0, "P3")) == ""
    assert plan.start_dry(_state(5)) == ""
    assert plan.start_dry({"phase": "P0", "stock": {}}) == "" and plan.start_dry(None) == ""


PH = {"phases": [{"id": "P0", "approve": False, "deliver": []}, {"id": "P1", "approve": True, "deliver": []}]}


def _propose(state, fort=None):
    return plan.propose(state, PH, None, decisions={}, tinfo=None, applied=set(), fort=fort or {})


def test_bug690_propose_drafts_the_stone_dig_and_asks_wood_and_blocks_at_a_dry_start():
    doc = _propose({**_state(0), "t": {"y": 414, "season": 0}})
    tpls = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
    assert "bedrooms" in tpls, doc["seasons"]
    assert doc["trade"]["want"][:2] == ["wood", "block"], doc["trade"]
    assert "BUG-691" in doc["notes"]


def test_bug690_propose_changes_nothing_with_stone_in_the_fort():
    doc = _propose({**_state(12), "t": {"y": 414, "season": 0}})
    assert "BUG-691" not in doc["notes"] and doc["trade"]["want"][:2] != ["wood", "block"]
    assert all(b["tpl"] != "bedrooms" for se in doc["seasons"] for b in se["build"])


def test_bug690_propose_leaves_a_dig_under_way_alone():
    doc = _propose({**_state(0), "t": {"y": 414, "season": 0}}, fort={"stone_dig": True})
    assert all(b["tpl"] != "bedrooms" for se in doc["seasons"] for b in se["build"])


def test_bug690_quarry_fallback_runs_at_a_dry_start_without_a_logged_shortage(tmp_path, monkeypatch):
    monkeypatch.setattr(plan.files, "read_state", lambda sd: _state(0))
    monkeypatch.setattr(plan, "material_famine", lambda sd, s: {})
    monkeypatch.setattr(plan, "fit_explore", lambda *a, **k: "explore: depth 4")
    monkeypatch.setattr(plan, "load_bp", lambda name: (_ for _ in ()).throw(plan.BpUnavailable("none")))
    doc = {"year": 414, "seasons": [{"build": [{"tpl": "aqshaft", "site": "S1"}]}, {"build": []}, {"build": []}, {"build": []}],
           "notes": ""}
    note = plan.quarry_fallback(tmp_path, copy.deepcopy(doc), None, 0)
    assert "quarry explore" in note
    monkeypatch.setattr(plan.files, "read_state", lambda sd: _state(7))
    assert plan.quarry_fallback(tmp_path, copy.deepcopy(doc), None, 0) == ""


def test_bug690_the_dig_goes_before_the_shaft_and_the_depot(monkeypatch, tmp_path):
    monkeypatch.setattr(plan.files, "read_state", lambda sd: _state(0))
    dig = {"tpl": "bedrooms", "site": "S1", "p": {"n": 4}}
    doc = {"year": 414, "seasons": [{"build": [{"tpl": "aqshaft", "site": "S1"}, {"tpl": "depot", "site": "S1"}, dig]}, {"build": []},
                                    {"build": []}, {"build": []}], "notes": ""}
    plan.stone_first(tmp_path, doc, None)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["bedrooms", "aqshaft", "depot"]
