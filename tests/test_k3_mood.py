"""K3 (BUG-100, Run 14 note 72): the mood report names the open slots with their filter, counts and real blocker.
The Lua suite (tests/lua/test_care_mood_slots.lua) proves the behaviour; this file proves the contract side: the
event fields are typed, a slot text is held to the 200-byte rule, the documents carry the vocabulary."""
import re
from pathlib import Path

from dfpilot import schema

ROOT = Path(__file__).resolve().parent.parent
VOCAB = ("none in the fort", "none free", "none reachable", "enough exist")


def ev(type_, cls, d, msg="x"):
    return {"n": 1, "tick": 10, "type": type_, "cls": cls, "msg": msg, "d": d}


def test_slots_are_typed_and_held_to_200_bytes():
    ok = ["blocks(metal) x2: none in the fort [0/0/0 of 225]", "cloth x2: none in the fort [0/0/0, thread 0]"]
    assert schema.validate("event", ev("MOOD_RISK", "A", {"unit": 1, "why": "missing", "slots": ok})) == []
    assert schema.validate("event", ev("MOOD_NEED", "B", {"unit": 1, "slots": ok})) == []
    bad = schema.validate("event", ev("MOOD_RISK", "A", {"unit": 1, "why": "missing", "slots": ["x" * 201]}))
    assert bad and "bytes" in bad[0]
    assert schema.validate("event", ev("MOOD_NEED", "B", {"unit": 1, "slots": "not a list"}))


def test_documents_carry_the_vocabulary_and_not_the_old_phrase():
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    contracts = (ROOT / "docs/v2/CONTRACTS.md").read_text(encoding="utf-8")
    row = next(x for x in contracts.splitlines() if x.startswith("| MOOD_RISK |"))
    for w in VOCAB:
        assert w in row, w
    assert "no source in the fort" not in row
    assert "none in the fort" in next(x for x in rules.splitlines() if x.startswith("| MOOD_RISK /"))
    assert len(rules.splitlines()) <= 300
    # care no longer prints the old phrase (comments may quote it)
    care = (ROOT / "lua/dfllm/care.lua").read_text(encoding="utf-8")
    live = [x for x in care.splitlines() if "no source in the fort" in x and not x.strip().startswith("--")]
    assert live == []
    assert re.search(r"BK_FORT, BK_FREE, BK_REACH, BK_HAVE = 'none in the fort', 'none free', 'none reachable', 'enough exist'", care)
