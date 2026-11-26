"""Neuausrichtung 15b (BUG-907): the switches of the third review. reach / player_lever / station_clear are off in the code when the key is absent (the gate of main)
and set in the shipped config/reflex.json; the old tests keep their assertions for the gate of main (test_alarm.py, test_neu1_notausgang.py)."""
import json
import re

from dfpilot import fairplay, schema


def _doc():
    return json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))


def test_shipped_config_sets_the_switches():
    doc = _doc()
    g = doc["gate"]
    assert g["reach"] is True and g["player_lever"] is True and g["station_clear"] == 4
    assert "clear" not in doc["stations"]
    assert fairplay.reflex_errors(fairplay.REPO / "config" / "reflex.json") == []


def test_code_defaults_are_the_gate_of_main():
    mil = (fairplay.REPO / "lua" / "dfllm" / "military.lua").read_text(encoding="utf-8")
    assert int(re.search(r"^M\.CLEAR = (\d+)", mil, re.M).group(1)) == 0
    gate = (fairplay.REPO / "lua" / "dfllm" / "gate.lua").read_text(encoding="utf-8")
    assert "local reach = r.reach == true" in gate
    assert schema.VERBS["lever"] == ("gate", ["PEACE"], False)
    con = (fairplay.REPO / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "C.VERB_CFG_MODES = {lever = {key = 'player_lever', modes = {ALERT = true, SIEGE = true}}}" in con


def test_switch_validation(tmp_path):
    doc = _doc()
    doc["gate"].update({"reach": "yes", "player_lever": 1, "station_clear": 1})
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    errs = " ".join(fairplay.reflex_errors(p))
    assert "gate.reach" in errs and "gate.player_lever" in errs and "gate.station_clear" in errs
    doc["gate"].update({"reach": False, "player_lever": False, "station_clear": 12})
    p.write_text(json.dumps(doc), encoding="utf-8")
    assert fairplay.reflex_errors(p) == []
