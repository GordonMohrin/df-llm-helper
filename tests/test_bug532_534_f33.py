"""Round 33 (threats): BUG-533 a held ceiling leaves room for a migrant wave while every defence gap is soft, and the status says
what holds max-pop (migrant_cap_note); BUG-534 state trade.nb and the status line that trade cannot supply a want. BUG-532 (Lua,
tests/lua/test_bug439_big_wild.lua) has its own tests."""
import copy

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, files, plan, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def fort(pop, **ready):
    r = {"lvl": 0, "worn": 90, "cv": 20, "drill_age": -1, "fail": [], "audit": {"ok": 1, "age": 900, "min_traps": 30}}
    r.update(ready)
    return {"pop": {"cit": pop, "soldiers": 10}, "ready": r, "mil": {"soldiers": 10, "worn": 90, "kit": {"n": 10, "armor": 5}},
            "traps": {"n": 30}}


def test_growth_room_and_soft_gaps():
    assert plan.growth_room(30) == 4 and plan.growth_room(100) == 10
    assert plan.gap_soft("traps short 16<29") and not plan.gap_soft("traps short 8<29")
    assert plan.gap_soft("armor worn 40 %") and not plan.gap_soft("armor worn 39 %")
    assert not plan.gap_soft("traps 0") and not plan.gap_soft("refuge_dry") and not plan.gap_soft("armor 0")


def test_defense_cap_soft_gap_leaves_room_hole_holds_on_citizens():
    soft = fort(33, tt=29, audit={"ok": 1, "age": 1, "min_traps": 16})
    assert plan.defense_gaps(soft) == ["traps short 16<29"]
    assert plan.defense_cap(soft, 100) == 37, "33 citizens + 4 room"
    assert plan.defense_cap(soft, 35) == 35, "never above the policy cap"
    hole = fort(33, tt=29, audit={"ok": 1, "age": 1, "min_traps": 8})
    assert plan.defense_cap(hole, 100) == 33, "a thin shortfall holds the ceiling ON the citizens (old behaviour)"
    mixed = fort(33, tt=29, audit={"ok": 1, "age": 1, "min_traps": 16}, fail=["refuge_dry"])
    assert plan.defense_cap(mixed, 100) == 33, "one hard gap (refuge_dry) keeps the hold"


class FakeCtx:
    def __init__(self, s, full=True):
        self.s, self.full = s, full


def test_migrant_cap_note_names_the_hold_or_clears_max_pop():
    on = brief.migrant_cap_note(FakeCtx({"pop": {"cap": 33, "hold": "plan 33"}}), 33)
    assert "migrants blocked: max-pop 33 on 33 citizens (plan 33)" in on
    room = brief.migrant_cap_note(FakeCtx({"pop": {"cap": 37, "hold": "defense_short 37+"}}), 33)
    assert "room for 4 (defense_short 37+)" in room
    free = brief.migrant_cap_note(FakeCtx({"pop": {"cap": 100}}), 44)
    assert "is not what keeps migrants out" in free and "44 citizens" in free
    assert brief.migrant_cap_note(FakeCtx({}), 44) == ""
    assert brief.migrant_cap_note(FakeCtx({"pop": {"cap": 100}}, full=False), 44) == "", "status stays short unless blocked"
    assert "blocked" in brief.migrant_cap_note(FakeCtx({"pop": {"cap": 33}}, full=False), 33)


def test_trade_nb_note_names_tokens_and_alternatives():
    t = brief.trade_nb_note(["mechanism", "stone"])
    assert "trade cannot supply mechanism, stone" in t and "liaison" in t
    assert "mechanism: mechanic's workshop" in t and "stone: dig it" in t


def test_trade_nb_in_the_supply_items_and_the_schema(save):
    s = copy.deepcopy(files.read_state(save))
    s["trade"] = {"caravan": 0, "ratio": 0, "done": 3, "nb": ["bar:iron", "stone"]}
    assert not schema.validate("state", s), schema.validate("state", s)
    txt = " ".join(t for _, t in brief.supply_items(FakeCtx({"trade": s["trade"]})))
    assert "trade cannot supply bar:iron, stone" in txt
    bad = copy.deepcopy(s)
    bad["trade"]["nb"] = ["x"] * 6
    assert schema.validate("state", bad), "at most 5 tokens"
