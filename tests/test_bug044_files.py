"""BUG-044..046 (Run 11 y483-y497, notes 16/21/22/23/32/47) and DECISIONS 4, Python and file side: the new event and field
of the contract, the config keys of the wall fallback, the plan's view of the ore search (an open seal pauses no
explore), the workshops template that puts the food shops first, and the baseline file. The kernel side is
tests/lua/test_runner_seal_door.lua, test_economy_build_state.lua and test_seal_ways.lua. Every test fails on f17e2b3."""
import json
from pathlib import Path

from dfpilot import bp, fairplay, plan, schema

ROOT = Path(__file__).resolve().parent.parent
SITE = {"id": "S1", "anchor": [40, 32, 120], "rot": 0}


def test_seal_walled_is_a_class_b_event_of_the_runner():
    assert schema.EVENTS["SEAL_WALLED"][:2] == ("B", "runner")
    d = {"proj": "c1a14b92909f3d7801", "at": "115,73,143", "was": "door", "days": 5, "why": "door 115,73,143: job 4711"}
    ev = {"n": 1, "tick": 5, "type": "SEAL_WALLED", "cls": "B", "msg": "x", "d": d}
    assert schema.validate("event", ev) == []
    bad = {**ev, "d": {k: v for k, v in d.items() if k != "at"}}
    assert schema.validate("event", bad) != []
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "SEAL_WALLED = {cls = 'B', by = 'runner'}" in lua


def test_project_blocked_carries_the_parts_that_wait():
    d = {"proj": "c1", "tpl": "workshops", "stage": "build", "why": "stalled", "ticks": 9000,
         "parts": "MetalsmithsForge 72,61,129: job 22236 suspended by buildingplan: waits for building material x1"}
    ev = {"n": 1, "tick": 5, "type": "PROJECT_BLOCKED", "cls": "A", "msg": "x", "d": d}
    assert schema.validate("event", ev) == []
    assert schema.validate("event", {**ev, "d": {**d, "parts": ["a list"]}}) != []


def test_wall_fallback_config_keys_are_validated(tmp_path):
    assert fairplay.RUNNER_LIM["seal_first"]["wall"] == "bool"
    assert fairplay.RUNNER_LIM["seal_first"]["wall_days"] == (0, 60)
    base = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert base["runner"]["seal_first"]["wall"] is True and base["runner"]["seal_first"]["wall_days"] == 2
    assert fairplay.runner_errors() == []
    for bad, frag in (({"wall": "yes"}, "runner.seal_first.wall: true or false expected"),
                      ({"wall_days": 61}, "runner.seal_first.wall_days: int 0..60 expected"),
                      ({"wall_days": -1}, "runner.seal_first.wall_days: int 0..60 expected"),
                      ({"walls": True}, "runner.seal_first.walls: unknown key")):
        doc = {"runner": {"seal_first": bad}}
        p = tmp_path / "baseline.json"
        p.write_text(json.dumps(doc), encoding="utf-8")
        errs = fairplay.runner_errors(p)
        assert len(errs) == 1 and frag in errs[0], errs


def test_an_open_seal_pauses_no_explore_in_the_plan_view():
    """DECISIONS 4 (post-mortem Run 11: 'explore never rests'): runner.kind_of and plan.build_kind agree."""
    assert plan.build_kind({"tpl": "explore", "site": "S1"}) == "explore"
    assert "explore" not in plan.SEAL_PAUSES and "explore" not in plan.REBUILD_KINDS
    assert plan.build_kind({"tpl": "bedrooms", "site": "S1"}) in plan.SEAL_PAUSES
    doc = {"year": 3, "phase_target": "P3", "seasons": [{"build": [{"tpl": "explore", "site": "S1"}]},
                                                       {"build": []}, {"build": []}, {"build": []}]}
    fort = {"seals": [{"proj": "c1", "n": 1, "stuck": False, "days": 0}]}
    assert plan.seal_gate(doc, {"t": {"y": 3, "season": 0}}, fort, None) == []
    doc["seasons"][0]["build"].append({"tpl": "bedrooms", "site": "S1"})
    warn = plan.seal_gate(doc, {"t": {"y": 3, "season": 0}}, fort, None)
    assert len(warn) == 1 and "the runner pauses bedrooms in PEACE" in warn[0] and "explore" not in warn[0]


def test_workshops_put_the_food_shops_first():
    """BUG-046 (Run 12 note 32): kitchens 0, food 10 days, because the forge before it was never built. The food shops are
    the first planned buildings of the room (buildingplan gives the first planned its materials first)."""
    d = bp.emit("workshops", {"add": "Still,Kitchen,Butchers"}, SITE)
    types = [w["type"] for w in d["manifest"]["workshops"]]
    assert types[:3] == ["Still", "Kitchen", "Butchers"] and types[3] == "Carpenters", types
    only = bp.emit("workshops", {"skip": ",".join(bp.MOODABLE_TYPES), "add": "Kitchen"}, SITE)
    assert [w["type"] for w in only["manifest"]["workshops"]] == ["Kitchen"]
    plain = bp.emit("workshops", {}, SITE)
    assert [w["type"] for w in plain["manifest"]["workshops"]][0] == "Carpenters"
