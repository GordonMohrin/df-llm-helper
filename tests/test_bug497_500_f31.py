"""Round 31 (material): BUG-497 the dig to hard stone is drafted first while the fort has no boulder, BUG-500 propose leaves out the temple and the
cistern while stone is out of reach and the applied plan may end before a cancelled tail, BUG-499 `inspect what=manager` is a schema verb. The
Lua sides are tests/lua/test_bug497_500_material.lua and test_economy_food.lua (BUG-498)."""
import copy

import pytest

from dfpilot import plan, schema


def _doc(seasons, year=400):
    return {"year": year, "seasons": [{"build": copy.deepcopy(b)} for b in seasons], "notes": "n"}


EX = {"tpl": "explore", "site": "S1"}
SEAL = {"tpl": "seal", "site": "S1"}
BED = {"tpl": "bedrooms", "site": "S1", "p": {"n": 4}}
TAV = {"tpl": "tavern", "site": "S1"}
TEM = {"tpl": "temple", "site": "S1"}
CIS = {"tpl": "cistern", "site": "S1"}


@pytest.fixture
def state(monkeypatch):
    box = {"s": {"stock": {"rock": 0}}}
    monkeypatch.setattr(plan.files, "read_state", lambda sd: box["s"])
    return box


def test_bug497_stone_first_moves_the_new_dig_before_the_other_new_builds(state, tmp_path):
    doc = _doc([[TAV, BED, SEAL, EX], [], [], []])
    note = plan.stone_first(tmp_path, doc, None)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["seal", "bedrooms", "explore", "tavern"], doc
    assert "BUG-497" in note and "BUG-497" in doc["notes"]


def test_bug497_applied_builds_keep_their_index(state, tmp_path):
    prev = _doc([[TAV, BED], [], [], []])
    doc = _doc([[TAV, BED, TEM, EX], [], [], []])
    plan.stone_first(tmp_path, doc, prev)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["tavern", "bedrooms", "explore", "temple"]


def test_bug497_nothing_moves_with_stone_or_in_order(state, tmp_path):
    state["s"] = {"stock": {"rock": 12}}
    doc = _doc([[TAV, EX], [], [], []])
    assert plan.stone_first(tmp_path, doc, None) == "" and [b["tpl"] for b in doc["seasons"][0]["build"]] == ["tavern", "explore"]
    state["s"] = {"stock": {"rock": 0}}
    ok = _doc([[SEAL, EX, TAV], [], [], []])
    assert plan.stone_first(tmp_path, ok, None) == ""


def test_bug497_a_soil_fort_counts_too(state, tmp_path):
    state["s"] = {"stock": {"rock": 3, "rsoil": 1}}
    doc = _doc([[TAV, EX], [], [], []])
    assert plan.stone_first(tmp_path, doc, None) and doc["seasons"][0]["build"][0]["tpl"] == "explore"


def test_bug500_nostone_reason():
    assert plan.nostone_reason({"stock": {"rock": 5, "rsoil": 1}}, {}) != ""
    assert plan.nostone_reason({"stock": {"rock": 0}}, {"short": True, "rock0": True}) != ""
    assert plan.nostone_reason({"stock": {"rock": 0}}, {}) == "", "no current MATERIAL_SHORT: a moment of zero"
    assert plan.nostone_reason({"stock": {"rock": 9}}, {"short": True, "rock0": False}) == ""


def test_bug500_propose_leaves_out_temple_and_cistern_and_says_why():
    fort = {"nostone": "no free boulder and a current MATERIAL_SHORT", "cancelled": []}
    doc = _doc([[TAV, TEM], [CIS, BED], [], []])
    note = plan.drop_impossible(doc, None, fort)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["tavern"]
    assert [b["tpl"] for b in doc["seasons"][1]["build"]] == ["bedrooms"]
    assert "BUG-500" in note and "temple" in note and "cistern" in note and "altar" in note and "mechanisms" in note
    assert plan.drop_impossible(_doc([[TEM], [], [], []]), None, {"nostone": ""}) == ""


def test_bug500_a_cancelled_tail_of_the_applied_plan_is_dropped_and_check_accepts_the_shorter_plan():
    prev = _doc([[TAV, TEM, CIS], [], [], []])
    fort = {"nostone": "the stone digs found only soil", "cancelled": ["y400s0b1", "y400s0b2"]}
    doc = copy.deepcopy(prev)
    note = plan.drop_impossible(doc, prev, fort)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["tavern"], doc
    assert "cancelled" in note
    assert plan.stable_ids(doc, prev, set(fort["cancelled"])) == []
    assert plan.stable_ids(doc, prev) != [], "without the cancelled ids the plan still cannot shrink"


def test_bug500_a_cancelled_build_in_the_middle_stays_and_a_live_one_stays():
    prev = _doc([[TEM, TAV, CIS], [], [], []])
    doc = copy.deepcopy(prev)
    plan.drop_impossible(doc, prev, {"nostone": "x", "cancelled": ["y400s0b0", "y400s0b2"]})
    # the cistern at the end is cancelled and goes; the temple in front of the tavern would shift the tavern's id: it stays
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["temple", "tavern"]
    live = copy.deepcopy(prev)
    plan.drop_impossible(live, prev, {"nostone": "x", "cancelled": []})
    assert [b["tpl"] for b in live["seasons"][0]["build"]] == ["temple", "tavern", "cistern"], "a project that lives is not dropped"


def test_bug500_check_warns_for_a_new_temple_or_cistern_without_stone():
    prev = _doc([[TAV], [], [], []])
    doc = _doc([[TAV, TEM], [CIS], [], []])
    w = plan.stone_gate(doc, prev, {"nostone": "no hard stone yet"})
    assert len(w) == 2 and "altar" in w[0] and "mechanisms" in w[1], w
    assert plan.stone_gate(doc, prev, {"nostone": ""}) == []


def test_bug499_inspect_manager_is_a_verb_arg():
    enum = schema.VERB_ARGS["inspect"].req["what"].enum
    assert "manager" in enum
    assert schema.json_schema("inbox.args.inspect")["properties"]["what"]["enum"].count("manager") == 1


def test_bug498_animal_marked_event_is_in_the_schema():
    c, by, spec = schema.EVENTS["ANIMAL_MARKED"]
    assert (c, by) == ("B", "economy")
