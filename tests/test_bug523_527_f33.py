"""Round 33 (phases): BUG-523 P3+ without a fortcore (Run 16a i1 Basementflew: aquifer z114-z127, stone 0, plan check refused every P3+
plan for O1 and B2 that no stage 3 could build), BUG-526 the verb orders.cancel (schema side), BUG-527 Still and Kitchen drafted whenever
the manifest lacks them (Run 16b i2 Brotherarrow). The Lua sides are tests/lua/test_bug524_orders_held.lua, test_bug525_gear_metal.lua,
test_bug526_orders_cancel.lua and test_bug527_essential_shops.lua."""
import pytest

from dfpilot import cmd, plan, schema

DOC = {"phase_target": "P3", "seasons": [{"build": []}] * 4, "year": 1}
ST = {"bridges": {}, "alert": {"ref": {"ex": True}}}


@pytest.fixture(autouse=True)
def _no_surface_core(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)      # BUG-413: the default, the fort goes under the aquifer


NOCORE = {"surface": {"need": True, "have": False, "why": "aquifer z114-z127",
                      "aq": {"ok": False, "why": "no core fits under these layers from here (depth 12)"}}}


def test_a_fort_with_no_possible_core_is_not_held_for_o1_and_b2():
    errs, warn = plan.stage3_gate(DOC, ST, NOCORE, None)
    assert errs == [], "BUG-523: O1 and B2 cannot stand where no fortcore can be built"
    assert len(warn) == 1 and "no fortcore can be built" in warn[0] and "no core fits under these layers" in warn[0]
    assert "separated refuge with beds" in warn[0] and "seal at=last" in warn[0], "the warning says what P3+ requires instead"


def test_a_fort_that_can_still_build_a_core_is_held_as_before():
    can = {"surface": {"need": True, "aq": {"ok": True, "why": ""}}}
    assert plan.stage3_gate(DOC, ST, can, None)[0], "a route through the aquifer exists: stage 3 is asked for"
    assert plan.stage3_gate(DOC, ST, {}, None)[0]
    assert plan.stage3_gate(DOC, ST, {"surface": {"need": False}}, None)[0]
    # a stage 3 under way or a lost-gate fort is the old branches
    under = {**NOCORE, "refuge": {"stage3": True}}
    assert plan.stage3_gate(DOC, ST, under, None) == ([], [])
    lost = plan.stage3_gate(DOC, ST, {**NOCORE, "o1": True}, None)
    assert lost[0] == [] and "rebuilds it" in lost[1][0]


def test_no_core_why_is_the_one_reason_no_core_route_uses():
    assert plan.no_core_why(NOCORE).startswith("no core fits")
    assert plan.no_core_why({}) == "" and plan.no_core_why({"surface": {"need": True, "have": True}}) == ""
    s = {"alert": {"ref": {"ex": False}}}
    f = {**NOCORE, "core_any": False}
    assert plan.no_core_route(f, s, set()) == plan.no_core_why(NOCORE)
    assert plan.no_core_route(f, {"alert": {"ref": {"ex": True}}}, set()) == "", "a refuge burrow stands: BUG-415 caps nothing"


def test_the_verb_orders_cancel_takes_one_order_or_the_stuck_ones():
    assert schema.validate_args("orders.cancel", {"id": 300}) == []
    assert schema.validate_args("orders.cancel", {"stuck": True}) == []
    assert schema.validate_args("orders.cancel", {"id": 300, "force": True}) == []
    assert schema.validate_args("orders.cancel", {}), "one of id and stuck"
    assert schema.validate_args("orders.cancel", {"id": 3, "stuck": True}), "not both"
    assert schema.validate_args("orders.cancel", {"id": -1})
    assert schema.validate_args("orders.cancel", {"id": 3, "x": 1})
    assert schema.VERBS["orders.cancel"] == ("economy", None, False)


def _doc(builds_by_season):
    return {"year": 5, "phase_target": "P2", "notes": "", "seasons": [{"build": list(b)} for b in builds_by_season]}


def test_still_and_kitchen_are_drafted_when_the_manifest_lacks_them(monkeypatch, tmp_path):
    monkeypatch.setattr(cmd, "workshops_missing", lambda save_dir, types=None: [t for t in (types or []) if t in ("Still", "Kitchen")])
    doc = _doc([[], [], [], []])
    lines = plan.essential_shops(tmp_path, doc, None)
    assert doc["seasons"][0]["build"] == [{"tpl": "workshops", "site": "S1", "p": {"only": "Still,Kitchen"}}]
    assert len(lines) == 1 and "BUG-527" in lines[0] and "Still,Kitchen" in doc["notes"]
    assert plan.essential_shops(tmp_path, doc, None) == [], "a workshops build of the draft that makes them is not drafted twice"


def test_a_draft_workshops_build_that_makes_one_leaves_the_other(monkeypatch, tmp_path):
    monkeypatch.setattr(cmd, "workshops_missing", lambda save_dir, types=None: ["Still", "Kitchen"])
    doc = _doc([[{"tpl": "workshops", "site": "S1", "p": {"only": "Still"}}], [], [], []])
    plan.essential_shops(tmp_path, doc, None)
    assert doc["seasons"][0]["build"][-1]["p"] == {"only": "Kitchen"}


def test_nothing_is_drafted_when_the_manifest_has_them_or_cannot_tell(monkeypatch, tmp_path):
    monkeypatch.setattr(cmd, "workshops_missing", lambda save_dir, types=None: [])
    doc = _doc([[], [], [], []])
    assert plan.essential_shops(tmp_path, doc, None) == [] and doc["seasons"][0]["build"] == []

    def boom(save_dir, types=None):
        raise cmd.BpUnavailable("no bp package")
    monkeypatch.setattr(cmd, "workshops_missing", boom)
    assert plan.essential_shops(tmp_path, doc, None) == []


def test_an_applied_workshops_build_of_this_year_counts(monkeypatch, tmp_path):
    monkeypatch.setattr(cmd, "workshops_missing", lambda save_dir, types=None: ["Still"])
    prev = {"year": 5, "seasons": [{"build": [{"tpl": "workshops", "site": "S1", "p": {"only": "Still"}}]}, {"build": []},
                                   {"build": []}, {"build": []}]}
    doc = _doc([[{"tpl": "workshops", "site": "S1", "p": {"only": "Still"}}], [], [], []])
    assert plan.essential_shops(tmp_path, doc, prev) == []
