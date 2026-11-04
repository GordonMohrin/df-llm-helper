"""BUG-327 (Run 15c Inkintense y378: '8 soldiers released (tools)', squad B never refilled, mil 0 at pop 53): the tools no
longer release soldiers (tests/lua/test_military.lua, test_military_refill.lua); any release left is the event
SOLDIERS_RELEASED, the state mil.rel and a status line."""
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


def test_event_soldiers_released():
    assert schema.EVENTS["SOLDIERS_RELEASED"][:2] == ("B", "military")
    assert schema.validate_event_d("SOLDIERS_RELEASED", {"n": 8, "why": "phase", "squads": ["A", "B"]}) == []
    assert schema.validate_event_d("SOLDIERS_RELEASED", {"n": 1, "why": "over_target"}) == []
    assert schema.validate_event_d("SOLDIERS_RELEASED", {"n": 1}) != []                 # why is required
    lua = (fairplay.REPO / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "SOLDIERS_RELEASED = {cls = 'B', by = 'military'}" in lua


def test_lua_has_no_tools_release_left():
    src = (fairplay.REPO / "lua" / "dfllm" / "military.lua").read_text("utf-8")
    assert "release(K, 'tools'" not in src
    assert "zero or 'tools'" not in src


def _now(st):
    t = st.get("t") or {}
    return t.get("abs", t.get("y", 0) * schema.TICKS["YEAR"] + t.get("tick", 0))


def test_state_and_status_line(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    now = _now(st)
    st["mil"]["rel"] = {"n": 8, "why": "phase", "t": max(0, now - 2520), "sq": "AB"}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "soldiers released: 8 (phase) from AB" in out
    bad = dict(st)
    bad["mil"] = dict(st["mil"], rel={"n": 8, "why": "phase"})
    assert schema.validate("state", bad) != [], "t and sq are required"
