"""FR-90 (Run 14 note 98): contracts of the garbage dump zone: zone.place type dump, inspect what=items, CANCEL_LOOP d.why,
the config key zones.dump_path_gap, and the Lua type list matching the schema."""
import json
from pathlib import Path

import pytest

from dfpilot import fairplay, schema

ROOT = Path(__file__).resolve().parent.parent


def inbox(verb, args):
    return schema.validate("inbox", {"id": "c1", "verb": verb, "args": args, "by": "llm"})


def test_zone_place_accepts_dump_and_inspect_accepts_items():
    assert "dump" in schema.ZONE_TYPES
    assert inbox("zone.place", {"type": "dump", "bbox": [10, 20, 5, 12, 22, 5], "name": "trash"}) == []
    assert inbox("zone.place", {"type": "garbage", "bbox": [10, 20, 5, 12, 22, 5]}) != []
    assert inbox("inspect", {"what": "items", "key": "trash"}) == []


def test_cancel_loop_carries_the_reason():
    e = {"n": 1, "tick": 5, "type": "CANCEL_LOOP", "cls": "B", "msg": "Dump item cancelled 5 times today: no dump zone",
         "d": {"order": -1, "job": "Dump item", "n": 5, "why": "no_zone"}}
    assert schema.validate("event", e) == []
    e["d"]["why"] = 7
    assert schema.validate("event", e) != []


def test_dump_path_gap_is_validated(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["zones"]["dump_path_gap"] == 2 and fairplay.zones_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "zones": {"dump_path_gap": 9}}), encoding="utf-8")
    assert fairplay.zones_errors(p) == ["config/baseline.json: zones.dump_path_gap: int 0..8 expected, got 9"]
    p.write_text(json.dumps({"v": 2, "zones": {"dump_path_gap": 0}}), encoding="utf-8")
    assert fairplay.zones_errors(p) == []


def test_rules_and_contract_name_the_dump_zone():
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    assert "meeting or dump zone" in rules and "`zones.dump_path_gap`" in rules and "what=items key=trash" in rules
    assert len(rules.splitlines()) <= 300
