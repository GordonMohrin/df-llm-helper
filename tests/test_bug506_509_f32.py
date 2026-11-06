"""Round 32 (fix32-water): BUG-506 the forbidden stock's age and cause in status, BUG-507 the verb water.unstick and the job_stalled
wake line, BUG-508 the water config keys, BUG-509 the mood_thirst wake line. (The Lua side: tests/lua/test_bug507_509_water.lua,
test_economy_supply.lua.)"""
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, schema, wake

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        for k, v in parts.items():
            doc[k] = dict(doc.get(k) or {}, **v)
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")


# ---------------------------------------------------------------- BUG-506
def test_status_names_how_long_the_stock_stood_and_what_holds_the_unforbid_back(save):
    put_state(save, stock={"drink_d": 4, "dforb": 2015, "dfd": 60, "dfwhy": "mode ALERT"})
    out = brief.status_text(save)
    assert "2015 drink items forbidden for 60 days, NOT in the days above" in out, out
    assert "the unforbid is held back: mode ALERT" in out, out
    assert "kernel unforbids them" not in out, out


def test_status_without_a_cause_and_a_young_stock(save):
    put_state(save, stock={"drink_d": 4, "dforb": 2015, "dfd": 5})
    assert "for 5 days, NOT in the days above" in brief.status_text(save)
    assert "the kernel has not freed them" in brief.status_text(save)
    put_state(save, stock={"dfd": 1})
    assert "(not in the days above; the kernel unforbids them)" in brief.status_text(save)


def test_the_stock_keys_are_in_the_state_schema(save):
    doc = json.loads((save / "state.a.json").read_text("utf-8"))
    doc["stock"] = dict(doc.get("stock") or {}, dforb=5, dfd=4, dfwhy="mode SIEGE")
    assert schema.validate("state", doc) == []
    doc["stock"]["dfd"] = -1
    assert schema.validate("state", doc) != []
    doc["stock"]["dfd"] = 1
    doc["stock"]["dfwhy"] = "x" * 41
    assert schema.validate("state", doc) != []


# ---------------------------------------------------------------- BUG-507 / 508
def test_the_verb_is_in_the_registry():
    assert schema.VERBS["water.unstick"] == ("water", None, False)
    assert schema.validate_args("water.unstick", {}) == []
    assert schema.validate_args("water.unstick", {"unit": 26505}) == []
    assert schema.validate_args("water.unstick", {"unit": "x"}) != []
    assert schema.validate_args("water.unstick", {"zone": 1}) != []


def test_the_contract_lua_lists_the_verb_and_the_config_mirrors_the_defaults():
    src = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "['water.unstick'] = {mod = 'water'}" in src
    water = (ROOT / "lua" / "dfllm" / "water.lua").read_text(encoding="utf-8")
    block = water.split("M.DEFAULTS = {", 1)[1].split("\n}", 1)[0]
    keys = set(re.findall(r"(?<![\w.])([a-z_]+) = ", re.sub(r"--[^\n]*", "", block)))
    for k in ("stall", "stall_days", "stall_need", "stall_every", "stall_max", "stall_hosp", "stall_dying"):
        assert k in keys and k in fairplay.WATER_LIM, k
    assert fairplay.water_errors() == []


def test_job_stalled_wake_line_names_the_command():
    d = {"id": "job_stalled", "q": "1 water job(s) stalled", "units": [26505],
         "cmds": ["dfllm cmd water.unstick unit=26505", "dfllm cmd inspect what=unit key=26505"]}
    hint = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "dfllm cmd water.unstick unit=26505" in hint and "stalled" in hint, hint
    assert "job_stalled" in wake.URGENT_DECISIONS


# ---------------------------------------------------------------- BUG-509
def test_mood_thirst_wake_line_sends_the_material_commands_not_a_food_command():
    cmds = ["dfllm cmd trade.want '{\"add\":[\"gems\"]}'", "dfllm cmd inspect what=unit key=26786"]
    d = {"id": "mood_thirst", "q": "mood unit 26786 (Fey, child)", "days": 20, "cmds": cmds}
    hint = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "~20 days" in hint and cmds[0] in hint, hint
    assert "food" not in hint.replace("from food", ""), hint
    none = wake.next_hint("DECISION_NEEDED", {"d": {"id": "mood_thirst", "days": 3, "cmds": [cmds[1]]}})
    assert "nothing to send" in none, none
    assert "mood_thirst" in wake.URGENT_DECISIONS
