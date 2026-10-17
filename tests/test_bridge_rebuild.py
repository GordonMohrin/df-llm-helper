"""BUG-030 rebuild policy (Run 11 site98: cave dragons destroyed the outer drawbridge O1 in all five sieges and the
perimeter keeper rebuilt it every time): the contract pieces on the Python side. The verb bridge.rebuild (the player's
answer), the new event fields (BRIDGE_DESTROYED n/bd/destroyers/races, PERIMETER_BROKEN wait/held, DECISION_NEEDED
bridge_rebuild), config/reflex.json perimeter.stop_after, the wake line's next move and the brief's R0 blocker
lost:<B>. The kernel side is tests/lua/test_bridge_rebuild.lua."""
import json
import re
from types import SimpleNamespace

from dfpilot import brief, fairplay, schema, wake
from dfpilot.events import est_tokens

DECISION = {"id": "bridge_rebuild", "q": "O1 destroyed 2x by building destroyers (DRAGON; y437,y438), rebuilt 1x",
            "bridge": "O1", "n": 2, "bd": 2, "reb": 1, "items": 3, "mat": "granite blocks", "links": 1,
            "races": ["DRAGON"], "years": [437, 438], "stop": 2,
            "opts": ['rebuild: dfllm cmd bridge.rebuild {"bridge":"O1"}',
                     "wall: walls on its footprint + a door entrance (plan)",
                     "gate: a second outer gate further out (plan, by hand)",
                     "leave: no rebuild (default); the deep defense holds"]}


def event(t, d, msg="m"):
    return {"n": 7, "tick": 5, "type": t, "cls": "A", "msg": msg, "d": d}


def test_verb_and_event_fields():
    assert schema.VERBS["bridge.rebuild"] == ("seal", None, False)
    assert schema.validate_args("bridge.rebuild", {"bridge": "O1"}) == []
    assert schema.validate_args("bridge.rebuild", {}) != []
    assert schema.validate_args("bridge.rebuild", {"bridge": "o1; lua"}) != []
    assert schema.validate_args("bridge.rebuild", {"bridge": "O1", "force": True}) != []
    assert schema.validate("event", event("DECISION_NEEDED", DECISION)) == []
    assert all(len(o.encode()) <= 60 for o in DECISION["opts"])
    assert schema.validate("event", event("BRIDGE_DESTROYED", {"bridge": "O1", "n": 3, "bd": 2, "destroyers": 1,
                                                               "races": ["DRAGON"]})) == []
    assert schema.validate("event", event("BRIDGE_DESTROYED", {"bridge": "O1", "n": "3"})) != []
    assert schema.validate("event", event("PERIMETER_BROKEN", {"n": 2, "requeued": 1, "wait": ["O1"]})) == []
    assert schema.validate("event", event("PERIMETER_BROKEN", {"n": 1, "requeued": 0, "held": ["O1"]})) == []
    lua = (fairplay.REPO / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "['bridge.rebuild'] = {mod = 'seal'}" in lua


def test_reflex_config_perimeter(tmp_path):
    """perimeter.stop_after: the shipped value is seal.lua's default (CFG.stop_after) within the kernel's limits."""
    shipped = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    lua = (fairplay.REPO / "lua" / "dfllm" / "seal.lua").read_text(encoding="utf-8")
    assert shipped["perimeter"] == {"stop_after": int(re.search(r"\bstop_after = (\d+),", lua).group(1))} \
        == {"stop_after": 2}
    assert "v >= 0 and v <= 20" in lua and fairplay.PERIMETER_LIM == {"stop_after": (0, 20)}
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps({"v": 2, "perimeter": {"stop_after": 21, "zap": 1}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for needle in ("perimeter.stop_after: int 0..20", "perimeter.zap: unknown key"):
        assert any(needle in e for e in errs), (needle, errs)
    p.write_text(json.dumps({"v": 2, "perimeter": {"stop_after": 0}}), encoding="utf-8")
    assert fairplay.reflex_errors(p) == []


def test_wake_line_names_the_answer():
    e = dict(event("DECISION_NEEDED", DECISION, DECISION["q"]), n=9200)
    hint = wake.next_hint("DECISION_NEEDED", e)
    assert "dfllm cmd bridge.rebuild '{\"bridge\":\"O1\"}'" in hint and "leave it (default)" in hint
    line = wake.wake_line({"DECISION_NEEDED": {"c": 1, "n0": 9200, "e": e}}, None)
    assert "DECISION_NEEDED O1: O1 destroyed 2x" in line and "bridge.rebuild" in line
    assert est_tokens(line) <= wake.WAKE_TOKENS
    other = wake.next_hint("DECISION_NEEDED", event("DECISION_NEEDED", {"id": "food_low"}))
    assert other == wake.NEXT["DECISION_NEEDED"]
    assert "quiet PEACE" in wake.NEXT["BRIDGE_DESTROYED"]


def test_brief_lost_bridge_is_not_a_fortcore_piece():
    def unready(fails):
        ctx = SimpleNamespace(s={"ready": {"lvl": 0, "fail": fails, "open": 0, "audit": {"age": 10, "min_traps": 0}}})
        return brief.line_unready(ctx)
    line = unready(["lost:O1"])
    assert "SIEGE UNREADY (R0): lost:O1" in line and "O1 lost to building destroyers" in line
    assert "bridge.rebuild" in line and "fortcore pieces" not in line
    assert "fortcore pieces" in unready(["bridge:O1"])
