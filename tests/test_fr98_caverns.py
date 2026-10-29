"""FR-98/FR-99 (Gordon's goal G16, "the military clears the caverns of beasts"): the cavern sweep's contracts, the plan
key `caverns.sweep` (propose drafts it with P6, check gates it), the P6 deliverable `sweep`, the status/brief line, the wake
hint and the RULES rows. The kernel side is tests/lua/test_fr98_cavern.lua and test_fr98_cavern_runner.lua."""
import json
from pathlib import Path
from types import SimpleNamespace

from dfpilot import brief, plan, schema, wake

ROOT = Path(__file__).resolve().parents[1]


def _ev(etype, cls, d):
    return {"n": 1, "tick": 10, "type": etype, "cls": cls, "msg": "cavern sweep", "d": d}


def test_events_and_state_validate():
    assert schema.EVENTS["CAVERN_SWEEP_END"][0] == "A" and schema.EVENTS["CAVERN_SWEEP_START"][0] == "B"
    assert schema.EVENTS["CAVERN_SWEEP_STEP"][0] == "C"
    assert schema.validate("event", _ev("CAVERN_SWEEP_START", "B", {"acc": "e1", "n": 2, "pos": [10, 10, 100], "bot": 95,
                                                                     "sol": 4, "worn": 90, "ids": [201, 202]})) == []
    assert schema.validate("event", _ev("CAVERN_SWEEP_STEP", "C", {"phase": "kill", "why": "kill order on 2"})) == []
    end = {"why": "done", "acc": "e1", "killed": 2, "lost": 0, "left": 0, "sealed": 1, "ticks": 5000, "pos": [10, 10, 100],
           "plug": "pl1"}
    assert schema.validate("event", _ev("CAVERN_SWEEP_END", "A", end)) == []
    assert schema.validate("event", _ev("CAVERN_SWEEP_END", "A", {"killed": 2})) != []        # why is required
    st = {"v": 2, "seq": 1, "t": {"y": 3, "tick": 0, "season": 0, "tps": 0, "paused": False}, "mode": "PEACE",
          "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [], "faults": 0}, "ev": 0,
          "cav": {"st": "kill", "why": "kill order on 2", "n": 2, "k": 1, "l": 0, "acc": 1, "clr": 0}}
    assert schema.validate("state", st) == []
    st["cav"]["st"] = "dance"
    assert schema.validate("state", st) != []
    assert schema.STATE_OWNERS["cav.*"] == "cavern"
    assert ("cavern", "WP6", False, {"ticks": 100}) in schema.MODULES
    assert "cavern" in schema.ACT["door_forbid"]
    assert schema.validate_args("inspect", {"what": "cavern"}) == []


def test_plan_key_and_the_p6_deliverable():
    doc = json.loads((ROOT / "plans" / "year1.json").read_text("utf-8"))
    p6 = next(p for p in doc["phases"] if p["id"] == "P6")
    assert {"k": "sweep"} in p6["deliver"] and "cavern sweep" in p6["title"]
    assert schema.validate("phases", doc) == []
    assert schema.DELIVER_KEYS["sweep"] == []
    pl = plan.propose(None, None, None, decisions={})
    pl["caverns"] = {"sweep": True}
    assert schema.validate("plan", pl) == []
    pl["caverns"] = {"sweep": "yes"}
    assert schema.validate("plan", pl) != []


def _state(phase, lvl=2, worn=90, cav=None):
    s = {"t": {"y": 3, "season": 0}, "phase": phase, "ready": {"lvl": lvl, "worn": worn}, "pop": {"cit": 40},
         "mil": {"worn": worn}}
    if cav is not None:
        s["cav"] = cav
    return s


def test_propose_drafts_the_sweep_with_p6_and_keeps_it():
    phases = plan.load_phases()
    doc = plan.propose(_state("P6"), phases, None, decisions={})
    assert doc["caverns"] == {"sweep": True}
    assert "FR-98: caverns.sweep on" in doc["notes"]
    low = plan.propose(_state("P5"), phases, None, decisions={})
    assert "caverns" not in low and "set caverns.sweep true" in low["notes"], low["notes"]
    kept = plan.propose(_state("P5"), phases, {**low, "caverns": {"sweep": True}, "year": 3}, decisions={})
    assert kept["caverns"] == {"sweep": True}, "once a plan had it, it stays"


def test_check_gates_the_sweep():
    phases = plan.load_phases()
    doc = plan.propose(_state("P6"), phases, None, decisions={})
    errs, warn = plan.sweep_gate(doc, _state("P6"))
    assert errs == [] and warn == []
    early = dict(doc, phase_target="P5")
    errs, _ = plan.sweep_gate(early, _state("P5"))
    assert errs == ["caverns.sweep needs phase_target P6 or later (FR-99, RULES section 11)"]
    _, warn = plan.sweep_gate(doc, _state("P6", lvl=0, worn=60, cav={"st": "wait", "acc": 0}))
    assert warn == ["caverns.sweep waits for R1 (now R0)",
                    "caverns.sweep waits for squad A worn >= 80 % (the army is at 60 %)",
                    "caverns.sweep: no plugged cavern shaft known: nothing to sweep (the deliverable passes)"]
    off = {k: v for k, v in doc.items() if k != "caverns"}
    _, warn = plan.sweep_gate(off, _state("P6", cav={"st": "off", "n": 3, "acc": 1}))
    assert warn and "caverns.sweep is off with 3 cavern beasts in sight" in warn[0]
    errs, warn = plan.check(early, _state("P5"), decisions={}, banned=[])
    assert "caverns.sweep needs phase_target P6 or later (FR-99, RULES section 11)" in errs


def test_status_line():
    ctx = SimpleNamespace(s={"cav": {"st": "kill", "why": "kill order on 2", "n": 2, "k": 1, "l": 0, "acc": 1, "clr": 0}})
    assert brief.line_cavern(ctx) == "caverns: sweep kill (killed 1, lost 0): kill order on 2; 2 beasts in sight at 1 plugged shaft"
    wait = SimpleNamespace(s={"cav": {"st": "wait", "why": "squad A worn 70% < 80%", "n": 1, "acc": 2, "clr": 0}})
    assert brief.line_cavern(wait) == "caverns: sweep wait: squad A worn 70% < 80%; 1 beast in sight at 2 plugged shafts"
    assert brief.line_cavern(SimpleNamespace(s={"cav": {"st": "off", "n": 0, "acc": 1}})) == ""
    assert brief.line_cavern(SimpleNamespace(s={})) == ""
    assert brief.est_tokens(brief.line_cavern(ctx)) < 40


def test_wake_and_rules():
    assert "CAVERN_SWEEP_END" in wake.WAKE_TYPES and "seal_failed" in wake.NEXT["CAVERN_SWEEP_END"]
    rules = (ROOT / "RULES.md").read_text("utf-8")
    sec7 = rules.split("## 7.")[1].split("## 8.")[0]
    assert "CAVERN_SWEEP_END" in sec7
    p6 = next(line for line in rules.splitlines() if line.startswith("| P6"))
    assert "caverns.sweep" in p6
    assert len(rules.splitlines()) <= 300
    note = (ROOT / "docs" / "v2" / "FR-fr-caverns-G16.md").read_text("utf-8")
    assert "FR-98" in note and "FR-99" in note
