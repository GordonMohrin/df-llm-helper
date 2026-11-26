"""NEU1 P7 (decision E5, docs/v2/NEU1-notausgang.md): the player's verbs and the emergency exit in the contract (schema, contract.lua,
the hook), the config part `player`, the EMERGENCY wake and the status line. The Lua side: tests/lua/test_neu1_notausgang.lua,
tests/lua/test_neu1_acts.lua."""
import json
import shlex
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from dfpilot import brief, fairplay, lint, schema, wake
from dfpilot.cmd import parse_kv

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

NEW = ["zone.remove", "building.remove", "labor.set", "workdetail.set", "lever.link", "furniture.place", "room.assign",
       "squad.station", "burrow.unit", "door.lock"]


def test_the_verbs_are_in_the_registry_with_the_player_module():
    for v in NEW:
        assert schema.VERBS[v] == ("player", None, False), v
        assert v in schema.VERB_ARGS
    assert schema.VERBS["lever"] == ("gate", ["PEACE", "ALERT", "SIEGE"], False)     # the open exit lifts the mode list (kern), gate takes only up; 15b: ALERT / SIEGE for the inner bridges
    assert set(schema.VERB_EMG) <= set(schema.VERBS) and set(schema.VERB_HOLD) <= set(schema.VERBS)
    assert "appoint" in schema.VERB_HOLD and "lever" in schema.VERB_EMG
    assert schema.ACT["building_remove"] == ["player"]
    for fn in ("link_lever", "burrow_units", "labor_set", "door_forbid", "quickfort", "work_detail", "zone_assign"):
        assert "player" in schema.ACT[fn], fn
    assert schema.STATE_OWNERS["emg"] == "player"
    assert ("player", "NEU1", False, {"ticks": 1200}) in schema.MODULES
    assert schema.EVENTS["EMERGENCY"][:2] == ("A", "player") and schema.EVENTS["EMERGENCY_END"][:2] == ("C", "player")


@pytest.mark.parametrize("verb,args,ok", [
    ("zone.remove", {"id": 300}, True), ("zone.remove", {}, False),
    ("building.remove", {"id": 9, "approve": True}, True),
    ("labor.set", {"unit": 41, "labor": "clean_fish", "on": True}, True), ("labor.set", {"unit": 41, "labor": "mason", "on": True}, False),
    ("workdetail.set", {"detail": "Fisherdwarves", "unit": 4, "on": True}, True), ("workdetail.set", {"detail": "X", "unit": 4, "on": True}, False),
    ("lever.link", {"lever": 5, "target": 6}, True), ("lever.link", {"lever": 5, "bridge": "B1"}, True),
    ("lever.link", {"lever": 5}, False), ("lever.link", {"lever": 5, "target": 6, "bridge": "B1"}, False),
    ("furniture.place", {"kind": "table", "pos": [1, 2, 3]}, True), ("furniture.place", {"kind": "throne", "pos": [1, 2, 3]}, False),
    ("room.assign", {"zone": 5, "unit": 6}, True),
    ("squad.station", {"squad": "A", "pos": [1, 2, 3]}, True), ("squad.station", {"squad": "A", "release": True}, True),
    ("squad.station", {"squad": "D"}, False),
    ("burrow.unit", {"burrow": "Kern+", "unit": 5, "on": False}, True), ("burrow.unit", {"burrow": "a;b", "unit": 5, "on": False}, False),
    ("door.lock", {"door": 77, "on": True}, True), ("door.lock", {"door": 77}, False),
])
def test_args(verb, args, ok):
    assert (schema.validate_args(verb, args) == []) is ok, schema.validate_args(verb, args)


@pytest.mark.parametrize("line", [
    "dfllm cmd zone.remove id=300", "dfllm cmd building.remove id=9 approve=true",
    "dfllm cmd labor.set unit=41 labor=clean_fish on=true", "dfllm cmd workdetail.set detail=Fisherdwarves unit=4 on=true",
    "dfllm cmd lever.link lever=5 bridge=B1", "dfllm cmd furniture.place kind=table pos=[1,2,3]",
    "dfllm cmd room.assign zone=5 unit=6", "dfllm cmd squad.station squad=A pos=[10,11,12]",
    "dfllm cmd burrow.unit burrow=Kern+ unit=5 on=true", "dfllm cmd door.lock door=77 on=true",
])
def test_the_commands_parse_and_pass_the_hook(line):
    w = shlex.split(line)
    assert schema.validate_args(w[2], parse_kv(w[3:])) == []
    ok, why = lint.cmd(line, dev=False, shell=True)
    assert ok, why


@pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")
def test_contract_lua_lists_the_same_emergency_and_hold_verbs():
    r = luahost.run_file(ROOT / "tests" / "lua" / "dump_contract.lua", timeout=30)
    assert r.ok, r.out + r.err
    d = json.loads(r.out)
    assert d["verb_emg"] == sorted(schema.VERB_EMG)
    assert d["verb_hold"] == sorted(schema.VERB_HOLD)
    player = (ROOT / "lua" / "dfllm" / "player.lua").read_text(encoding="utf-8")
    for kind, key in schema.FURNITURE.items():
        assert f"{kind} = '{key}'" in player, kind
    for k in fairplay.PLAYER_LIM:
        assert f"{k} = " in player, k


def test_the_config_part_is_on_and_checked(tmp_path):
    base = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8-sig"))
    p = base["player"]
    assert p["exit"] is True and p["verbs"] is True and p["hold"] is True and p["slow"] is True
    assert fairplay.player_errors() == []
    f = tmp_path / "b.json"
    f.write_text(json.dumps({"player": {"exit": "yes", "exit_days": 99, "nope": 1, "hold_days": 28}}), encoding="utf-8")
    errs = fairplay.player_errors(f)
    assert len(errs) == 3 and any("player.exit:" in e for e in errs) and any("exit_days" in e for e in errs)
    assert fairplay.player_errors(tmp_path / "none.json") == []


def test_emergency_wakes_at_once_and_names_the_verbs():
    assert "EMERGENCY" in wake.WAKE_TYPES and "EMERGENCY" in wake.URGENT
    hint = wake.next_hint("EMERGENCY", {"d": {"why": "thirst", "verbs": ["squad.station"], "until": 5}})
    for v in ("lever", "squad.station", "burrow.unit", "door.lock", "water.unstick"):
        assert v in hint, v


def test_status_keeps_the_open_exit_line():
    items = brief.alarm_items(SimpleNamespace(s={"emg": {"o": 1, "why": "inside gate", "left": 2}}))
    assert items[0][0] == 1 and items[0][1].startswith("NOTAUSGANG open (inside gate, 2 d left)")
    assert brief.alarm_items(SimpleNamespace(s={})) == []
    assert schema.validate("state", {"v": 2, "seq": 1, "ev": 0, "mode": "PEACE",
                                     "t": {"y": 1, "tick": 0, "season": 0, "tps": 0, "paused": False},
                                     "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [], "faults": 0},
                                     "emg": {"o": 1, "why": "thirst", "left": 3}}) == []
