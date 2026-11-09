"""Round 38 (BUG-587 to BUG-589; offline, live-untested). The Lua sides are tested in tests/lua/test_bug587_siege_hold.lua (the siege traffic
test: citizens milling beside the bridges while a hostile closes in) and tests/lua/test_bug588_589_refuge_destroyers.lua (the refuge latch, the
early plug, a building destroyer vs the refuge access). Here: the config keys of the bounded hold and the contract of REFUGE_PLUG."""
import json

from dfpilot import fairplay, schema


def _gate(tmp_path, g):
    rp = tmp_path / "reflex.json"
    rp.write_text(json.dumps({"v": 2, "gate": g}), encoding="utf-8")
    return [e for e in fairplay.reflex_errors(rp) if "gate." in e]


def test_gate_approach_keys_are_linted(tmp_path):
    assert _gate(tmp_path, {"approach_near": 30, "approach_hold": 300, "approach_close": 12}) == []
    assert _gate(tmp_path, {"approach_near": 0, "approach_hold": 0, "approach_close": 0}) == []
    errs = _gate(tmp_path, {"approach_near": 81, "approach_hold": -1, "approach_close": "x"})
    assert len(errs) == 3
    assert any("approach_near" in e for e in errs) and any("approach_hold" in e for e in errs) and any("approach_close" in e for e in errs)


def test_shipped_reflex_json_carries_the_defaults():
    doc = json.loads(fairplay.REFLEX_PATH.read_text(encoding="utf-8")) if hasattr(fairplay.REFLEX_PATH, "read_text") else None
    assert doc is not None
    assert doc["gate"]["approach_near"] == 30 and doc["gate"]["approach_hold"] == 300 and doc["gate"]["approach_close"] == 12
    assert fairplay.reflex_errors() == []


def test_refuge_plug_event_has_the_early_flag():
    d = {"proj": "rp1", "n": 8, "pos": [6, 6, 5], "closer": "hatch", "breach": 0, "early": 1}
    assert schema.validate_event_d("REFUGE_PLUG", d) == []
    assert schema.validate_event_d("REFUGE_PLUG", {**d, "early": "yes"}) != []
