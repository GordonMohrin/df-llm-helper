"""Package A3 (military): config/baseline.json "military" (BUG-050 uniform-unstick, FR-71 militia windows, BUG-051 early
squads, BUG-052 station radius) with its lint --config validation, the Lua limits it mirrors, and the event fields of
BUG-052 (SIEGE_END, SIEGE_STATUS)."""
from __future__ import annotations

import json
import re

from dfpilot import fairplay, schema


def test_config_military_defaults_and_validation(tmp_path):
    assert fairplay.military_errors() == []
    doc = json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))
    assert doc["military"] == {
        "unstick": {"on": True, "drop": False, "every": 33600, "below": 100, "drop_after": 2},
        "militia": {"B": [9, 10, 11]}, "free_months": [9, 10, 11],
        "rotation": {"on": True, "per_day": 3, "worn_min": 40}, "early_pop": 40, "station_r": 3}
    p = tmp_path / "baseline.json"
    bad = {"v": 2, "military": {
        "unstick": {"on": 1, "drop": "no", "every": 5, "below": 0, "drop_after": 99, "x": 1},
        "militia": {"B": [9, 12], "D": [1], "C": "x"}, "free_months": [-1], "early_pop": 999, "station_r": 0, "y": 2}}
    p.write_text(json.dumps(bad), encoding="utf-8")
    errs = fairplay.military_errors(p)
    for needle in ("unstick.on: true or false", "unstick.drop: true or false", "unstick.every: int 1200..403200",
                   "unstick.below: int 1..100", "unstick.drop_after: int 0..12", "unstick.x: unknown key",
                   "militia.B: a list of months 0..11", "militia.D: not a squad key", "militia.C: a list of months",
                   "free_months: a list of months 0..11", "early_pop: int 0..250", "station_r: int 1..10",
                   "military.y: unknown key"):
        assert any(needle in e for e in errs), (needle, errs)
    p.write_text(json.dumps({"v": 2, "military": {"militia": {}, "free_months": []}}), encoding="utf-8")
    assert fairplay.military_errors(p) == []                   # an empty militia / no free months is a valid choice
    p.write_text(json.dumps({"v": 2, "military": []}), encoding="utf-8")
    assert fairplay.military_errors(p) == ["config/baseline.json: military must be an object"]
    assert fairplay.military_errors(tmp_path / "none.json") == []


def test_lua_defaults_match_the_shipped_config():
    """military.lua M.UNSTICK_DEF / M.MILITIA / M.FREE_MONTHS / M.EARLY_POP / M.STATION_R and their limits are the
    config/baseline.json values and the ranges lint --config checks."""
    src = (fairplay.REPO / "lua" / "dfllm" / "military.lua").read_text("utf-8")
    cfg = json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))["military"]
    u = cfg["unstick"]
    assert f"M.UNSTICK_DEF = {{on = true, drop = false, every = M.UNSTICK, below = {u['below']}, drop_after = {u['drop_after']}}}" in src
    assert f"M.UNSTICK = {u['every']} " in src
    assert "M.MILITIA = {B = {9, 10, 11}}" in src and "M.FREE_MONTHS = {9, 10, 11}" in src
    assert f"M.EARLY_POP, M.EARLY_LIM = {cfg['early_pop']}, {{0, 250}}" in src
    assert f"M.STATION_R = {cfg['station_r']} " in src
    lim = fairplay.MILITARY_UNSTICK_LIM
    assert (f"M.UNSTICK_LIM = {{every = {{{lim['every'][0]}, {lim['every'][1]}}}, below = {{{lim['below'][0]}, "
            f"{lim['below'][1]}}}, drop_after = {{{lim['drop_after'][0]}, {lim['drop_after'][1]}}}}}") in src
    assert "M.STATION_R_LIM = {1, 10}" in src
    assert re.search(r"M\.SQUADS = \{\{key = 'A'.*\{key = 'B'.*\{key = 'C'", src)
    assert fairplay.MILITARY_KEYS == ("A", "B", "C")


def test_siege_events_carry_the_station_numbers():
    """BUG-052: SIEGE_END reports the soldiers at the start and end, the best on-station count and when half stood;
    SIEGE_STATUS says why soldiers are off their station."""
    end = {"hostiles": 9, "killed": 9, "lost": 24, "captures": 0, "sealed_ticks": 3000, "sol0": 16, "soldiers": 6,
           "on_station": 9, "on_t": -1}
    assert schema.validate_event_d("SIEGE_END", end) == []
    assert schema.validate_event_d("SIEGE_END", {"hostiles": 9}) == []          # the old shape stays valid
    assert schema.validate_event_d("SIEGE_STATUS", {"vis": 3, "worn": 36, "on_station": 0, "deaths": 1, "captures": 0,
                                                    "off": "equip 5, far 2"}) == []
    assert schema.validate_event_d("SIEGE_END", {"on_t": "never"}) != []


def test_config_economy_tools_pile(tmp_path):
    """BUG-053: economy.tools stale_days / pile_* (lua/dfllm/economy.lua M.DEFAULTS.tools) are in the shipped config and
    checked by lint --config."""
    assert fairplay.economy_errors() == []
    t = json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))["economy"]["tools"]
    assert (t["stale_days"], t["pile"], t["pile_days"], t["pile_w"], t["pile_h"], t["pile_r"], t["pile_reads"],
            t["pile_every"]) == (14, True, 7, 3, 2, 12, 300, 28)
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "economy": {"tools": {"stale_days": 0, "pile": "yes", "pile_days": 999,
                                                           "pile_w": 6, "pile_h": 0, "pile_r": 1, "pile_reads": 5,
                                                           "pile_every": True}}}), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    for needle in ("tools.stale_days: int 1..400", "tools.pile: true or false", "tools.pile_days: int 1..400",
                   "tools.pile_w: int 1..5", "tools.pile_h: int 1..5", "tools.pile_r: int 2..40",
                   "tools.pile_reads: int 20..2000", "tools.pile_every: int 1..400"):
        assert any(needle in e for e in errs), (needle, errs)
    src = (fairplay.REPO / "lua" / "dfllm" / "economy.lua").read_text("utf-8")
    assert ("stale_days = 14, pile = true, pile_days = 7, pile_w = 3, pile_h = 2, pile_r = 12, pile_reads = 300,\n"
            "           pile_every = 28,") in src


def test_tool_pile_act_and_event_field():
    """BUG-053: act.tool_pile belongs to economy (contract.lua and schema.py agree); TOOL_BLOCKED carries `pile`."""
    assert schema.ACT["tool_pile"] == ["economy"]
    lua = (fairplay.REPO / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "tool_pile = {'economy'}" in lua
    d = {"detail": "Miners", "tool": "pick", "n": 5, "pile": "dfllm-tools placed at 61,40,5 (3x2)",
         "bk": "off_group,jobs"}
    assert schema.validate_event_d("TOOL_BLOCKED", d) == []
    assert schema.validate_event_d("TOOL_BLOCKED", dict(d, pile=5)) != []
