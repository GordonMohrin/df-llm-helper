"""Round 31 (wild animals at water): BUG-494 WATER_PREDATOR (a Hibbertopterus pack at the brook drowned five citizens, threat 0),
BUG-495 PREDATOR / INTRUDER name race, size and reach, BUG-496 DROWNED. The Lua side is tests/lua/test_bug494_water_beast.lua,
test_reflex.lua (BUG-495), test_economy_food.lua (the fishers) and test_care_deaths.lua (DROWNED)."""
import json
import re
from pathlib import Path

from dfpilot import schema, wake

ROOT = Path(__file__).resolve().parent.parent


def test_water_predator_validates():
    d = {"n": 1, "id": 300, "race": "HIBBERTOPTERUS", "pos": [70, 20, 10], "dc": 10, "wet": "water 3/7", "sz": 150000,
         "stream": "brook", "reach": 2, "fish": 1, "cmd": "dfllm cmd squad.sortie '{\"squad\":\"A\"}'", "killer": 1}
    assert schema.validate_event_d("WATER_PREDATOR", d) == []
    assert schema.EVENTS["WATER_PREDATOR"][:2] == ("A", "sense")
    assert schema.validate_event_d("WATER_PREDATOR", {"n": 1, "id": 300}), "race, pos, dc and wet are required"


def test_drowned_validates():
    d = {"unit": 26275, "cause": "wild", "pos": [70, 20, 10], "tile": "water 5/7", "stream": "brook",
         "near": [{"id": 300, "race": "HIBBERTOPTERUS", "sz": 150000, "d": 2, "tame": False}], "revised": 1}
    assert schema.validate_event_d("DROWNED", d) == []
    assert schema.EVENTS["DROWNED"][:2] == ("A", "care")
    assert schema.validate_event_d("DROWNED", {"unit": 1}), "cause is required"


def test_predator_and_intruder_carry_race_size_reach_cmd():
    for t in ("PREDATOR", "INTRUDER"):
        assert schema.validate_event_d(t, {"n": 1, "id": 400, "pos": [1, 2, 3], "race": "MAMMOTH", "sz": 4000000, "reach": 1,
                                           "cmd": "dfllm cmd squad.sortie '{}'"}) == []
        assert schema.validate_event_d(t, {"n": 1, "id": 400, "pos": [1, 2, 3]}) == [], "an older kernel's line stays valid"


def test_wake_knows_the_new_events():
    for t in ("WATER_PREDATOR", "DROWNED"):
        assert t in wake.WAKE_TYPES and t in wake.PRIO and t in wake.NEXT and t in wake.URGENT
    assert wake.PRIO.index("PREDATOR") < wake.PRIO.index("WATER_PREDATOR") < wake.PRIO.index("LOCKDOWN")
    assert wake.view_target("WATER_PREDATOR", {"id": 300, "pos": [70, 20, 10]}) == "300"
    assert wake.view_target("DROWNED", {"unit": 26275, "pos": [70, 20, 10]}) == "70,20,10", "the dead unit cannot be viewed"


def test_contract_lua_registers_them():
    text = (ROOT / "lua/dfllm/util/contract.lua").read_text(encoding="utf-8")
    assert re.search(r"WATER_PREDATOR = \{cls = 'A', by = 'sense'\}", text)
    assert re.search(r"DROWNED = \{cls = 'A', by = 'care'\}", text)


def test_only_sense_walks_units_and_reads_tiles():
    # the lint contract (python -m dfpilot lint): care asks sense for the scene and the water at the body
    care = (ROOT / "lua/dfllm/care.lua").read_text(encoding="utf-8")
    assert "K.call('sense', 'scene'" in care and "K.call('sense', 'water_at'" in care
