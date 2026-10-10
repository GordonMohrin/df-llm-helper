"""WP8: baseline, economy and care on the real Lua kernel write only schema-valid files.

tests/lua/wp8_scenario.lua boots lua/dfllm/kern.lua with the three WP8 modules and the repo's config
files on k_mock's fake DF, drives eventful callbacks (cancel loop, migrants, deaths), stops, and dumps
the persistent site data. Every event line and both state slots must validate (CONTRACTS §9.3, §9.4).
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from df_llm_helper import schema  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("wp8")
    r = luahost.run_file(LUA_TESTS / "wp8_scenario.lua", [str(out)], timeout=120, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out


def sd(out: Path) -> Path:
    return out / "dfllm-runtime" / "region1"


def events(out: Path) -> list[dict]:
    return [json.loads(line) for line in (sd(out) / "events.jsonl").read_text(encoding="utf-8").splitlines() if line]


def test_every_event_validates(run):
    evs = events(run)
    assert evs
    for e in evs:
        assert schema.validate("event", e) == [], e


def test_wp8_events_emitted(run):
    types = {e["type"] for e in events(run)}
    for t in ("STOCK_LOW", "MIGRANTS", "CANCEL_LOOP", "MOOD_START", "MOOD_NEED", "DEATH", "DEATHS_3PLUS",
              "CAPTURE", "PROJECT_REQUEST"):
        assert t in types, t
    fails = [e for e in events(run) if e["type"] == "ACT_FAIL"]
    assert not [e for e in fails if e["d"]["fn"] == "run"], fails      # every command was allowlisted


def test_state_slots_validate_and_carry_wp8_keys(run):
    docs = [json.loads((sd(run) / f"state.{s}.json").read_text(encoding="utf-8")) for s in ("a", "b")]
    for d in docs:
        assert schema.validate("state", d) == [], d
    best = max(docs, key=lambda d: d["seq"])
    assert set(best["stock"]) == {"drink_d", "food_d", "meals", "hosp_water"}
    assert set(best["labor"]) == {"starving", "idle"}
    assert set(best["care"]) == {"stressed_pct", "naked", "ghosts", "corpses_old", "tombs_free", "moods"}
    assert len(json.dumps(best, separators=(",", ":"))) <= 4096


def test_persist_module_keys(run):
    raw = json.loads((run / "persist_dump.json").read_text(encoding="utf-8"))
    for key in ("dfllm.m.baseline", "dfllm.m.economy", "dfllm.m.care"):
        doc = json.loads(raw[key])
        assert doc["v"] == 2, key
    base = json.loads(raw["dfllm.m.baseline"])
    assert base["done"] == 1 and base["lm"] == "monitor"           # DESIGN §5.5: monitor first, A/B later
    assert base["ab"]["stage"] == "A"
    eco = json.loads(raw["dfllm.m.economy"])
    assert "library/basic" in eco["imported"]          # migrants arrived -> staged import


def test_captive_and_migrant_flow(run):
    evs = events(run)
    assert [e["d"]["n"] for e in evs if e["type"] == "MIGRANTS"] == [2]   # new ids, deaths do not count
    rows = [ln.split(chr(9))[3:] for ln in (sd(run) / "commands.log").read_text(encoding="utf-8").splitlines()]
    assert ["act.item_flag", '[4444,"melt",false]', "ok"] in rows      # melt-safe cage
    assert ["act.item_flag", '[4444,"dump",true]', "ok"] in rows       # no pit: the cage leaves the trap


def _orders(name: str) -> list[dict]:
    p = Path(luahost.dll_path()).parent / "data" / "orders" / f"{name}.json"
    if not p.is_file():
        pytest.skip(f"orders library not installed: {p}")
    return json.loads(p.read_text(encoding="utf-8"))


def _cond(order: dict, cond: str, item_type: str, material: str | None = None) -> int | None:
    for c in order.get("item_conditions", []):
        if c.get("condition") == cond and c.get("item_type") == item_type and c.get("material") == material:
            return c["value"]
    return None


def test_autochop_target_lets_the_charcoal_and_smelting_imports_run():
    """config/baseline.json autochop vs hack/data/orders: smelting needs COAL bars, charcoal needs logs."""
    base = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    chop = base["baseline"]["autochop"]
    smelt = [o for lib in ("smelting", "military") for o in _orders(lib) if o["job"] == "SmeltOre"]
    assert smelt
    coal_need = max(_cond(o, "AtLeast", "BAR", "COAL") or 0 for o in smelt)
    # a MakeCharcoal order that can push COAL up to what SmeltOre needs, and its log condition
    feeders = [o for o in _orders("furnace") if o["job"] == "MakeCharcoal"
               and (_cond(o, "AtMost", "BAR", "COAL") or 0) >= coal_need]
    assert feeders, "no library charcoal order reaches the SmeltOre coal condition"
    wood_need = min(_cond(o, "AtLeast", "WOOD") or 0 for o in feeders)
    assert chop["max"] > wood_need, (chop, wood_need)              # logs reach the WOOD condition
    assert chop["min"] > 14 * 2, chop                               # chopping resumes far above the mood reserve
    assert chop["min"] < chop["max"]


def test_commands_log_has_only_wp8_owners(run):
    lines = (sd(run) / "commands.log").read_text(encoding="utf-8").splitlines()
    origins = {ln.split("\t")[2] for ln in lines}
    assert origins <= {"baseline", "economy", "care"}, origins
    acts = {ln.split("\t")[3] for ln in lines}
    assert "act.run" in acts and "act.item_flag" in acts and "act.kitchen_exclude" in acts
