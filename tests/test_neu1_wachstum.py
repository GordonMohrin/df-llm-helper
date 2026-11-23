"""NEU1 P4 (decision E1, docs/v2/NEU1-wachstum.md): the growth ladder and the small-fight sortie: config knobs (on by default,
range-checked), the event / state contracts (POPCAP halt, GROWTH_HALT, ready.gh, SORTIE small) on both sides."""
import json
from pathlib import Path

from dfpilot import fairplay, schema

ROOT = Path(__file__).resolve().parent.parent


def test_config_ships_both_switches_on_and_valid(tmp_path):
    doc = json.loads((ROOT / "config" / "reflex.json").read_text("utf-8"))
    assert doc["growth"]["on"] is True and doc["small_fight"]["on"] is True
    assert (doc["growth"]["base"], doc["growth"]["armed_cap"], doc["growth"]["ready_cap"], doc["growth"]["top_cap"]) == (30, 50, 80, 100)
    assert doc["growth"]["share"] == 70 and doc["small_fight"]["max"] == 3
    assert fairplay.reflex_errors() == []
    # the Lua defaults are the shipped ones
    lua = (ROOT / "lua" / "dfllm" / "readiness.lua").read_text("utf-8")
    assert ("M.GROWTH = {on = true, base = 30, armed_cap = 50, ready_cap = 80, top_cap = 100, armed_min = 3, full_ready = 6, "
            "full_top = 10, share = 70,") in lua
    mil = (ROOT / "lua" / "dfllm" / "military.lua").read_text("utf-8")
    assert "M.SMALL = {on = true, max = 3, armed = 2}" in mil
    bad = dict(doc, growth=dict(doc["growth"], share=101, on="yes"), small_fight={"max": 0, "x": 1})
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps(bad), "utf-8")
    errs = fairplay.reflex_errors(p)
    assert any("growth.share" in e for e in errs) and any("growth.on" in e for e in errs)
    assert any("small_fight.max" in e for e in errs) and any("small_fight.x: unknown key" in e for e in errs)
    p.write_text(json.dumps(dict(doc, growth=dict(doc["growth"], armed_cap=90))), "utf-8")
    assert any("base <= armed_cap <= ready_cap <= top_cap" in e for e in fairplay.reflex_errors(p))


def test_event_and_state_contracts():
    assert schema.EVENTS["GROWTH_HALT"][:2] == ("B", "readiness")
    e = {"n": 4, "tick": 9, "type": "GROWTH_HALT", "cls": "B", "msg": "growth ladder: cap 50, 80 held by share",
         "d": {"cap": 50, "next": 80, "halt": "share", "need": "3 of 8 soldiers fully equipped (37 % < 70 %)"}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, d={"cap": 50})) != []
    pc = {"n": 5, "tick": 9, "type": "POPCAP", "cls": "B", "msg": "max-pop 40 (freeze)",
          "d": {"cap": 40, "why": "freeze", "halt": "squad", "need": "first squad: 1 of 3"}}
    assert schema.validate("event", pc) == []
    so = {"n": 6, "tick": 9, "type": "SORTIE", "cls": "B", "msg": "sortie A: kill", "d": {"phase": "go", "small": 1}}
    assert schema.validate("event", so) == []
    gh = schema.STATE.opt["ready"].opt["gh"]
    assert set(gh.req) == {"cap", "next", "halt"} and "need" in gh.opt
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "GROWTH_HALT = {cls = 'B', by = 'readiness'}" in lua
    assert "gh = obj({cap = NAT, next = NAT, halt = str(12)}, {need = str(100)})" in lua
