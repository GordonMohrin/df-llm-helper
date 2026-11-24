"""BUG-826 (Neuausrichtung 2, docs/v2/NEU2-tempo.md): clock.gfps / clock.peace_fps and deadman.min_s are linted, Lua and JSON
defaults agree, the schema takes the two status fields and the status clock line names them."""
from __future__ import annotations

import json
import re
import types

from dfpilot import brief, fairplay

LUA = (fairplay.REPO / "lua" / "dfllm" / "arbiter.lua").read_text(encoding="utf-8")
CONTRACT_LUA = (fairplay.REPO / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")


def _doc():
    return json.loads(fairplay.REFLEX_PATH.read_text(encoding="utf-8"))


def _errs(tmp_path, doc):
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    return fairplay.reflex_errors(p)


def test_defaults_lua_equals_json_equals_lint():
    assert fairplay.reflex_errors() == []
    clock = _doc()["clock"]
    assert clock["gfps"] == 10 and clock["peace_fps"] == 1000
    assert re.search(r"gfps = 10, peace_fps = 1000\}", LUA)
    lim = re.search(r"M\.CLOCK_LIM = \{(.*?)\}\n", LUA, re.S).group(1)
    got = {k: (int(a), int(b)) for k, a, b in re.findall(r"(\w+) = \{(\d+), (\d+)\}", lim)}
    assert got == fairplay.CLOCK_LIM == {"siege_cap": (10, 1000), "alert_cap": (10, 1000), "trade_cap": (10, 1000),
                                         "gfps": (1, 100), "peace_fps": (100, 1000)}
    assert "PEACE = 1000" in LUA
    dm = _doc()["deadman"]
    assert dm["min_s"] == 45 and fairplay.DEADMAN_LIM["min_s"] == (0, 3600)
    assert "min_s = {0, 3600}" in LUA


def test_lint_flags_bad_clock_values(tmp_path):
    for k, bad in (("gfps", 0), ("gfps", 101), ("gfps", "10"), ("peace_fps", 99), ("peace_fps", 1001), ("peace_fps", True),
                   ("gfps", 10.5)):
        doc = _doc()
        doc["clock"][k] = bad
        assert any(f"clock.{k}" in e for e in _errs(tmp_path, doc)), (k, bad)
    doc = _doc()
    doc["clock"]["warp"] = 5
    assert any("clock.warp" in e for e in _errs(tmp_path, doc))
    doc = _doc()
    doc["clock"].update(gfps=1, peace_fps=100)
    assert _errs(tmp_path, doc) == []
    doc["clock"].update(gfps=100, peace_fps=1000)
    assert _errs(tmp_path, doc) == []


def test_lint_flags_bad_min_s(tmp_path):
    for bad in (-1, 3601, "45", False):
        doc = _doc()
        doc["deadman"]["min_s"] = bad
        assert any("deadman.min_s" in e for e in _errs(tmp_path, doc)), bad
    doc = _doc()
    doc["deadman"]["min_s"] = 0
    assert _errs(tmp_path, doc) == []


def test_state_clock_schema_takes_gfps_and_pt():
    assert "gfps = int(0, 1000), pt = int(0, 1000)" in CONTRACT_LUA
    src = (fairplay.REPO / "dfpilot" / "schema.py").read_text(encoding="utf-8")
    assert '"gfps": Int(0, 1000), "pt": Int(0, 1000)' in src


def test_status_clock_line_names_gfps():
    def items(c):
        return [t for _, t in brief.alarm_items(types.SimpleNamespace(s={"clock": c}))]
    free = items({"cap": 250, "orig": 250, "ts": 1000, "held": 0, "why": "", "gfps": 10, "pt": 1000})
    assert free == ["clock: free (cap 250, timestream 1000, gfps 10)"]
    held = items({"cap": 30, "orig": 250, "ts": -1, "held": 1, "why": "siege", "gfps": 10, "pt": 1000})
    assert held == ["clock: held 30 t/s, reason siege, gfps 10"]
    old = items({"cap": 500, "orig": 500, "ts": 500, "held": 0, "why": ""})          # an older kernel: no gfps field
    assert old == ["clock: free (cap 500, timestream 500)"]
    off = items({"cap": 250, "orig": 250, "ts": -1, "held": 0, "why": "", "gfps": 0, "pt": 1000})
    assert off == ["clock: free (cap 250)"]
