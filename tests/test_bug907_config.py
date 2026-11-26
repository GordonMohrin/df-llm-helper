"""Neuausrichtung 15b (BUG-907, final rule): reach / player_lever / station_clear are safety switches that are ON in the code when the key is absent; the shipped
config/reflex.json names them and `lint --config` requires them. The old tests of the gate of main run with the keys switched off through the mock flag
KMOCK_LEGACY_15B (their assertions are unchanged)."""
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


def test_code_defaults_are_the_safe_ones():
    mil = (fairplay.REPO / "lua" / "dfllm" / "military.lua").read_text(encoding="utf-8")
    assert int(re.search(r"^M\.CLEAR = (\d+)", mil, re.M).group(1)) == 4
    gate = (fairplay.REPO / "lua" / "dfllm" / "gate.lua").read_text(encoding="utf-8")
    assert "local reach = r.reach ~= false" in gate and "r.reach == true" not in gate
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


def test_lint_config_requires_the_switches(tmp_path):
    assert fairplay.reflex_required() == []
    doc = _doc()
    for k in ("reach", "player_lever", "station_clear"):
        d = json.loads(json.dumps(doc))
        del d["gate"][k]
        p = tmp_path / "reflex.json"
        p.write_text(json.dumps(d), encoding="utf-8")
        assert any(f"gate.{k}: required" in e for e in fairplay.reflex_required(p)), k
        assert fairplay.reflex_errors(p) == [], "the plain validator accepts a config without the key (the kernel's default is ON)"
