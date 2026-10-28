"""M3 (BUG-111 .. BUG-114; notes 77, 94, 96, 97 of bugs/RUN11-offene-bugs-und-FR.md), Python side: the contract of the new
fields and events, the config ranges, the wake hints and the status/brief lines. The kernel side is tests/lua/test_m3_*.lua."""
import json
from types import SimpleNamespace

from dfpilot import brief, fairplay, schema, wake

_STATE = {"v": 2, "seq": 1, "t": {"y": 3, "tick": 10, "season": 0, "tps": 100, "paused": False}, "mode": "BREACH",
          "k": {"ms_s": 1, "gap_max_ms": 1, "slow": [], "faults": 0}, "ev": 1}
AL = {"defcon": 1, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:invader"}


def state(**kw):
    s = json.loads(json.dumps(_STATE))
    s.update(kw)
    return s


def test_state_fields_validate():
    ok = dict(AL, ben=["39230:child"], ln={"age": 5000, "n": 1, "rel": 7000, "kill": "kill order on 39230"})
    assert schema.validate("state", state(alarm=ok)) == []
    assert schema.validate("state", state(alarm=dict(AL, ben=["x"] * 6))) != []
    assert schema.validate("state", state(alarm=dict(AL, ln={"age": 5, "n": 1, "kill": "x" * 81}))) != []
    assert schema.validate("state", state(alarm=dict(AL, ln={"n": 1}))) != []
    assert schema.validate("state", state(wave={"ph": "idle", "n": 0, "ba": 48000, "bw": "waiting for X25718 up: soldier 5 on "
                                                "the footprint; quiet clock: 1 invader in sight"})) == []
    assert schema.validate("state", state(wave={"ph": "idle", "n": 0, "bw": "x" * 101})) != []


def test_events_validate():
    sortie = {"n": 1, "tick": 5, "type": "SORTIE", "cls": "B", "msg": "m",
              "d": {"phase": "dead", "squad": "A", "why": "killed", "units": [39230], "pos": [77, 67, 128], "ticks": 300}}
    assert schema.validate("event", sortie) == []
    assert schema.EVENTS["SORTIE"][:2] == ("B", "any")
    gf = {"n": 2, "tick": 5, "type": "GATE_FAIL", "cls": "A", "msg": "m",
          "d": {"bridge": "X25718", "want": "up", "why": "no_effect", "pulls": 15, "wait": 7200, "lever": 25729}}
    assert schema.validate("event", gf) == []
    assert schema.validate("event", dict(gf, d=dict(gf["d"], pulls="x"))) != []
    assert schema.EVENTS["PATIENTS_OUT"][:2] == ("A", "water")
    dn = {"n": 3, "tick": 5, "type": "DECISION_NEEDED", "cls": "A", "msg": "m",
          "d": {"id": "kill_lone_intruder", "q": "q", "unit": 39230, "pos": [77, 67, 128], "hl": 1, "age": 4000, "mode": "BREACH",
                "inside": 1, "squad": "A", "cmd": "dfllm cmd squad.sortie '{}'", "kill": "squad A worn 40% < 80%"}}
    assert schema.validate("event", dn) == []


def test_config_ranges(tmp_path):
    def errs(doc):
        p = tmp_path / "reflex.json"
        p.write_text(json.dumps(dict({"v": 2}, **doc)), encoding="utf-8")
        return fairplay.reflex_errors(p)
    assert errs({"confine": {"ask_days": 3, "kill_hours": 24, "siege_release": True},
                 "sortie": {"kill_near": 5, "idle_ticks": 1200, "hold_ticks": 4800},
                 "breach": {"stuck_ticks": 2400}, "gate": {"pull_cap": 15, "giveup_wait": 7200}}) == []
    for bad in ({"confine": {"ask_days": 400}}, {"confine": {"kill_hours": -1}}, {"confine": {"siege_release": 1}},
                {"sortie": {"kill_near": 51}}, {"sortie": {"idle_ticks": 10}}, {"sortie": {"hold_ticks": 10}},
                {"breach": {"stuck_ticks": -5}}, {"breach": {"zap": 1}}, {"gate": {"pull_cap": 2}}, {"gate": {"pull_cap": 101}},
                {"gate": {"giveup_wait": 100}}):
        assert errs(bad), bad
    real = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    assert real["confine"]["ask_days"] == 3 and real["confine"]["kill_hours"] == 24 and real["confine"]["siege_release"] is True
    assert real["breach"]["stuck_ticks"] == 2400 and real["gate"]["pull_cap"] == 15 and real["sortie"]["kill_near"] == 5
    assert fairplay.reflex_errors() == []


def test_wake_hints():
    cmd = 'dfllm cmd squad.sortie \'{"squad":"A","target":[77,67,128],"approve":true}\''
    e = {"n": 9, "tick": 5, "type": "DECISION_NEEDED", "cls": "A", "msg": "m",
         "d": {"id": "kill_lone_intruder", "q": "q", "unit": 39230, "squad": "A", "cmd": cmd, "kill": "squad A worn 40% < 80%"}}
    h = wake.next_hint("DECISION_NEEDED", e)
    assert cmd in h and "Gordon" in h and "worn 40%" in h and "confine.max_days" in h and "not_attackable" in h, h
    e["d"] = {"id": "kill_lone_intruder", "q": "q", "unit": 39230}
    assert "no squad to send" in wake.next_hint("DECISION_NEEDED", e)
    po = {"n": 1, "tick": 5, "type": "PATIENTS_OUT", "cls": "A", "msg": "m",
          "d": {"n": 2, "patients": 3, "burrow": "Tiefe+", "units": [4, 5], "mode": "BREACH", "hosp_out": 1}}
    h = wake.next_hint("PATIENTS_OUT", po)
    assert "bp sites hospital" in h and "inside Kern+" in h and "2 of 3 patients" in h, h
    assert wake.PRIO.index("PATIENTS_OUT") > wake.PRIO.index("PATIENT_DYING")


def test_brief_lines():
    s = {"alarm": dict(AL, ben=["39230:child"], ln={"age": 4800, "n": 1, "rel": 9600, "kill": "kill order on 39230"}),
         "threat": {"vis": 1, "armed": 0}, "t": {"tps": 100},
         "wave": {"ph": "idle", "n": 0, "ba": 48000, "bw": "waiting for X25718 up: soldier 39052 on the footprint (squad 111); "
                                                          "quiet clock: 0 visible"}}
    txt = brief.line_alarm(SimpleNamespace(s=s))
    assert "lone harmless intruder x1 for 4.0 d, released in 8.0 d; kernel kill order: kill order on 39230" in txt, txt
    assert "not counted as hostile (id:why): 39230:child" in txt, txt
    core, _ = brief.def_parts(SimpleNamespace(s=s))
    assert any(x.startswith("BREACH since 40.0 d: waiting for X25718 up: soldier 39052") for x in core), core
    assert not any(x.startswith("intake idle") for x in core), core
    s["alarm"]["ln"] = {"age": 100, "n": 2}
    assert "no release (confine.siege_release off)" in brief.line_alarm(SimpleNamespace(s=s))
