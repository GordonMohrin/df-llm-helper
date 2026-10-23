"""Package B3 (Run 14, 2026): care's tomb zone lock (BUG-062), mood deaths (BUG-063), toppled-by reports (BUG-064) and
the stress response / population diagnosis (FR-74) on the file contracts.

tests/lua/care_b3_scenario.lua boots lua/dfllm/kern.lua with care and a fake snapshot on k_mock's fake DF and the repo's
config files; every event, outbox reply and state slot must validate against dfpilot/schema.py. The schema, config and
wake parts run without Lua.
"""
import json
from pathlib import Path

import pytest

import sys

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import fairplay, schema, wake  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


# ---------------------------------------------------------------- contract tables
def test_new_events_validate():
    ok = {"n": 1, "tick": 5, "type": "MOOD_CRITICAL", "cls": "A", "msg": "mood unit 3",
          "d": {"unit": 3, "why": "thirst", "kind": "Fey", "thirst": 51000, "hunger": 41000, "ws": "Masons",
                "name": "Urist", "pos": [20, 20, 5], "missing": [], "nook": "drink nook queued at 19,20,5 (mdr1)"}}
    assert schema.validate("event", ok) == []
    assert schema.validate("event", {**ok, "cls": "B"}) != []
    assert schema.validate("event", {**ok, "d": {"why": "thirst"}}) != []              # unit is required
    assert "MOOD_CRITICAL" in wake.WAKE_TYPES and "MOOD_CRITICAL" in wake.NEXT
    top = {"n": 2, "tick": 5, "type": "BUILDING_TOPPLED", "cls": "B", "msg": "x toppled by y",
           "d": {"what": "Mason's Workshop", "by": "Kel", "unit": 2, "ghost": 0, "stress": 61000, "cat": 0,
                 "tantrum": 1, "n": 2, "pos": [1, 2, 3]}}
    assert schema.validate("event", top) == []
    assert schema.validate("event", {**top, "d": {"by": "Kel"}}) != []                 # what is required
    lock = {"n": 3, "tick": 5, "type": "TOMBS_LOCKED", "cls": "B", "msg": "tomb zones closed",
            "d": {"closed": 4, "free": 4, "usable": 4, "owned": 0, "inactive": 0, "opened": 4, "left": 0,
                  "again_free": 1, "again_owned": 2, "by_entomb": 1, "unburied": 3}}
    assert schema.validate("event", lock) == []
    g = {"n": 4, "tick": 5, "type": "GHOSTS", "cls": "A", "msg": "1 ghost(s)",
         "d": {"ghosts": 1, "corpses": 1, "old": 0, "units": [6], "causes": ["6:corpse_far"], "far": 1}}
    assert schema.validate("event", g) == []
    bd = {"n": 5, "tick": 5, "type": "BRIDGE_DESTROYED", "cls": "A", "msg": "O1 destroyed",
          "d": {"bridge": "O1", "tby": "Kel", "tunit": 2, "tcat": 0, "tghost": 1}}
    assert schema.validate("event", bd) == []


def test_state_and_config():
    care = {"stressed_pct": 52, "naked": 0, "ghosts": 3, "corpses_old": 1, "tombs_free": 2, "moods": 0,
            "tombs_locked": 4}
    assert schema.validate("state", {**_state(), "care": care}) == []
    assert schema.validate("state", {**_state(), "care": {**care, "tombs_locked": -1}}) != []
    assert fairplay.care_errors() == []


def _state():
    return {"v": 2, "seq": 1, "t": {"y": 1, "tick": 0, "season": 0, "tps": 0, "paused": False}, "mode": "PEACE",
            "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [], "faults": 0}, "ev": 0}


def test_care_config_is_checked(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"care": {"tomb_open_per_run": 5000, "far_check": "x"}}), encoding="utf-8")
    errs = fairplay.care_errors(p)
    assert len(errs) == 2 and "tomb_open_per_run" in errs[0] and "far_check" in errs[1]
    p.write_text(json.dumps({"care": {"mood_nook": 1, "mood_take": "a b", "stress_high": 0, "mood_crit": 99999999}}),
                 encoding="utf-8")
    assert len(fairplay.care_errors(p)) == 4
    p.write_text(json.dumps({"care": {"tomb_open_per_run": 0, "mood_nook": False, "mood_take": "my-pile"}}), encoding="utf-8")
    assert fairplay.care_errors(p) == [] and fairplay.care_errors(tmp_path / "none.json") == []


# ---------------------------------------------------------------- the real kernel
@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("careb3")
    r = luahost.run_file(LUA_TESTS / "care_b3_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out / "dfllm-runtime" / "region1"


def events(sd: Path) -> list[dict]:
    return [json.loads(line) for line in (sd / "events.jsonl").read_text(encoding="utf-8").splitlines() if line]


@needs_lua
def test_events_validate_and_the_new_ones_come(run):
    evs = events(run)
    for e in evs:
        assert schema.validate("event", e) == [], e
    by = {}
    for e in evs:
        by.setdefault(e["type"], []).append(e)
    assert {"TOMBS_LOCKED", "MOOD_CRITICAL", "MOOD_RISK", "BUILDING_TOPPLED", "GHOSTS"} <= set(by)
    lock = by["TOMBS_LOCKED"][0]["d"]
    assert (lock["closed"], lock["opened"], lock["left"]) == (4, 3, 0)          # one zone went to the unburied citizen 7
    crit = by["MOOD_CRITICAL"][0]
    assert crit["cls"] == "A" and crit["d"]["unit"] == 3 and crit["d"]["ws"] == "Masons" and crit["d"]["pos"] == [20, 20, 5]
    risk = by["MOOD_RISK"][-1]["d"]
    assert risk["thirst"] == 51000 and risk["hunger"] == 41000
    top = by["BUILDING_TOPPLED"][0]["d"]
    assert (top["by"], top["unit"], top["cat"], top["tantrum"]) == ("Kel Becordastot", 2, 0, 1)
    g = by["GHOSTS"][0]["d"]
    assert g["far"] == 1 and g["causes"] == ["6:corpse_far"]
    fails = [e for e in by.get("ACT_FAIL", []) if e["d"]["fn"] in ("run", "tomb_zone")]
    assert fails == []


@needs_lua
def test_inspect_reply_and_state_slots(run):
    r = json.loads((run / "outbox" / "c1.json").read_text(encoding="utf-8"))
    assert schema.validate("outbox", r) == [] and r["ok"] is True
    assert len(json.dumps(r["data"], separators=(",", ":"))) <= 8192
    d = r["data"]
    assert d["far_n"] == 1 and d["locked"] == 0 and (d["lock"]["closed"], d["lock"]["owned"]) == (1, 1)
    assert d["unusable"]["unbuilt"] == 0
    for s in ("a", "b"):
        st = json.loads((run / f"state.{s}.json").read_text(encoding="utf-8"))
        assert schema.validate("state", st) == [], st
