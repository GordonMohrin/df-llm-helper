"""NEU16 (holz) BUG-910..915: the status text of the wood that counts, the WOOD_DISBELIEVED event, the stock fields, the wood_pile act and its quiet decision
(the Lua side: tests/lua/test_bug910_915_holz.lua, tests/lua/test_neu1_jobwhy.lua)."""
import json
import pathlib

from test_neu1_wertung_leiter import state  # noqa: F401

from dfpilot import brief, schema, session


class FakeCtx:
    def __init__(self, s, full=True):
        self.s, self.full = s, full


def text(st):
    return " ".join(t for _, t in brief.supply_items(FakeCtx({"stock": st})))


def test_status_line_names_near_far_loose_and_built_in():
    txt = text({"drink_d": 50, "food_d": 50, "wood": 7, "woodf": 9, "woodt": 22, "woodb": 4})
    assert "wood 7 usable (9 far, 6 loose unusable; 4 built in)" in txt, txt
    only_far = text({"drink_d": 50, "food_d": 50, "wood": 0, "woodf": 192, "woodt": 192})
    assert "wood 0 usable (192 far)" in only_far, only_far
    built_only = text({"drink_d": 50, "food_d": 50, "wood": 3, "woodf": 5, "woodt": 8, "woodb": 2})
    assert "wood 3 usable (5 far; 2 built in)" in built_only, built_only


def test_status_line_names_the_disbelieved_count():
    txt = text({"drink_d": 50, "food_d": 50, "wood": 0, "woodd": 30, "woodt": 50, "woodf": 20})
    assert "wood 0 usable (20 far, 30 loose unusable)" in txt, txt
    assert "the count of 30 is disbelieved" in txt, txt


def test_old_status_texts_are_unchanged_without_the_new_fields():
    assert "wood 0 (25 loose unusable; 336 built in)" in text({"drink_d": 50, "food_d": 50, "wood": 0, "woodt": 25, "woodb": 336})
    assert "wood 0 usable of 204" in text({"drink_d": 50, "food_d": 50, "wood": 0, "woodt": 204})


def test_wood_disbelieved_event_and_stock_fields_are_in_the_schema():
    cls, by, spec = schema.EVENTS["WOOD_DISBELIEVED"]
    assert (cls, by) == ("B", "economy")
    assert "n" in spec.req and "w" in spec.req and "d" in spec.req
    assert schema.ACT["wood_pile"] == ["economy"]
    lua = (pathlib.Path(__file__).resolve().parent.parent / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "wood_pile = {'economy'}" in lua
    assert "WOOD_DISBELIEVED = {cls = 'B', by = 'economy'}" in lua
    assert "['stock.woodf'] = 'economy'" in lua and "['stock.woodd'] = 'economy'" in lua


def test_wood_pile_decision_is_quiet():
    assert "wood_pile" in session.QUIET_DECISIONS
