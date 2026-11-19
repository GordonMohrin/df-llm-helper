"""Round 51 (BUG-774 to BUG-776; offline, live-untested). The Lua sides are tested in tests/lua/test_bug774_776_lever_home.lua (siege traffic: the
y544 replay) and tests/lua/test_bug577_580_audit_siege.lua / test_bug587_siege_hold.lua (the hold of a raise). Here: the config key
gate.approach_now (BUG-775), the shipped default, the act and state names the contract carries (BUG-774, BUG-776)."""
import json

from dfpilot import fairplay, schema


def _gate(tmp_path, g):
    rp = tmp_path / "reflex.json"
    rp.write_text(json.dumps({"v": 2, "gate": g}), encoding="utf-8")
    return [e for e in fairplay.reflex_errors(rp) if "gate." in e]


def test_approach_now_is_linted(tmp_path):
    assert _gate(tmp_path, {"approach_now": 20}) == []
    assert _gate(tmp_path, {"approach_now": 0}) == []
    assert _gate(tmp_path, {"approach_now": 80}) == []
    for bad in (81, -1, "x", 2.5):
        errs = _gate(tmp_path, {"approach_now": bad})
        assert len(errs) == 1 and "approach_now" in errs[0], (bad, errs)


def test_shipped_reflex_json_carries_approach_now():
    doc = json.loads(fairplay.REFLEX_PATH.read_text(encoding="utf-8"))
    assert doc["gate"]["approach_now"] == 20
    assert fairplay.reflex_errors() == []


def test_lever_build_is_a_gate_act():
    assert schema.ACT["lever_build"] == ["gate"]


def test_ready_state_carries_the_lever_and_hold_keys():
    ready = schema.STATE.opt["ready"] if "ready" in schema.STATE.opt else schema.STATE.req["ready"]
    assert "lo" in ready.opt and "uh" in ready.opt
