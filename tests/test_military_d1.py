"""Package D1 (military): FR-79 the militia rotation (config military.rotation with its lint --config validation, the Lua
defaults it mirrors, the event MILITIA_ROTATED, the state mil.rot and the status line) and BUG-076 (the squad refill)."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_config_rotation_defaults_and_validation(tmp_path):
    assert fairplay.military_errors() == []
    doc = json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))
    assert doc["military"]["rotation"] == {"on": True, "per_day": 3, "worn_min": 40}
    p = tmp_path / "baseline.json"
    bad = {"v": 2, "military": {"rotation": {"on": "yes", "per_day": 0, "worn_min": 101, "x": 1}}}
    p.write_text(json.dumps(bad), encoding="utf-8")
    errs = fairplay.military_errors(p)
    for needle in ("rotation.on: true or false", "rotation.per_day: int 1..10", "rotation.worn_min: int 0..100",
                   "rotation.x: unknown key"):
        assert any(needle in e for e in errs), (needle, errs)
    p.write_text(json.dumps({"v": 2, "military": {"rotation": {"on": False, "per_day": 10, "worn_min": 0}}}), encoding="utf-8")
    assert fairplay.military_errors(p) == []
    p.write_text(json.dumps({"v": 2, "military": {"rotation": []}}), encoding="utf-8")
    assert fairplay.military_errors(p) == ["config/baseline.json: military.rotation must be an object"]
    p.write_text(json.dumps({"v": 2, "military": {"rotation": {"per_day": True}}}), encoding="utf-8")
    assert any("per_day: int 1..10" in e for e in fairplay.military_errors(p))


def test_lua_defaults_match_the_shipped_config():
    """military.lua M.ROT_DEF / M.ROT_LIM and the squad-refill constants are the config values and the ranges lint --config
    checks."""
    src = (fairplay.REPO / "lua" / "dfllm" / "military.lua").read_text("utf-8")
    cfg = json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))["military"]["rotation"]
    assert f"M.ROT_DEF = {{on = true, per_day = {cfg['per_day']}, worn_min = {cfg['worn_min']}}}" in src
    lim = fairplay.MILITARY_ROTATION_LIM
    assert (f"M.ROT_LIM = {{per_day = {{{lim['per_day'][0]}, {lim['per_day'][1]}}}, worn_min = {{{lim['worn_min'][0]}, "
            f"{lim['worn_min'][1]}}}}}") in src
    assert lim["on"] == "bool"


def test_event_militia_rotated():
    d = {"squad": "B", "out": 3, "into": 3, "size": 4, "eligible": 45, "lo": 0, "hi": 1, "win": "9-11", "left": 0,
         "worn": 61, "edge": 0}
    assert schema.EVENTS["MILITIA_ROTATED"][:2] == ("B", "military")
    assert schema.validate_event_d("MILITIA_ROTATED", d) == []
    assert schema.validate_event_d("MILITIA_ROTATED", {"squad": "B", "out": 1, "into": 1}) == []
    assert schema.validate_event_d("MILITIA_ROTATED", {"squad": "B", "out": 1}) != []        # into is required
    assert schema.validate_event_d("MILITIA_ROTATED", dict(d, out="three")) != []
    lua = (fairplay.REPO / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "MILITIA_ROTATED = {cls = 'B', by = 'military'}" in lua


def test_state_mil_rot(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mil"]["rot"] = {"B": {"w": "9-11", "on": 0, "n": 4, "z": 4, "e": 45, "lo": 0, "hi": 1, "nx": 98, "rt": 3, "mv": 9,
                              "why": "last: rotated"}}
    assert schema.validate("state", st) == []
    st["mil"]["rot"]["D"] = {}
    assert schema.validate("state", st) != [], "only the squad keys A, B, C"
    del st["mil"]["rot"]["D"]
    st["mil"]["rot"]["B"]["nx"] = -1
    assert schema.validate("state", st) != []
    st["mil"]["rot"]["B"]["nx"] = 5
    st["mil"]["rot"]["B"]["names"] = [1, 2]
    assert schema.validate("state", st) != [], "counts only, no unit lists"


def test_status_line_names_the_window_the_cohort_and_what_holds_it(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mil"]["rot"] = {"B": {"w": "9-11", "on": 0, "n": 4, "z": 4, "e": 45, "lo": 0, "hi": 1, "nx": 0,
                              "why": "held: lockdown"}}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert ("militia B 9-11 off duty: 4/4 sit, 45 eligible, served 0-1, turnover due; held: lockdown") in out
    assert brief.est_tokens(out) <= brief.STATUS_TOKENS
    assert brief.line_rot("B", {"w": "9-11", "on": 1, "n": 4, "z": 4, "e": 3, "lo": 2, "hi": 2, "nx": 61}) == \
        "militia B 9-11 on duty: 4/4 sit, 3 eligible, served 2-2, turnover in 61 d"
