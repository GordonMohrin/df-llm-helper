"""Round 43 (trade): BUG-669 a player screen over the trade, BUG-670 stale Leaving caravans, BUG-671 PREDATOR sortie offers and the lockdown
clock. The Lua halves are in tests/lua/test_bug669_670_trade_screen.lua, tests/lua/test_bug671_sortie_offer.lua and tests/lua/test_reflex.lua
(BUG-671); here the contract (schema) and the brief."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from cli_v2_helpers import make_runtime, reset_paths                           # noqa: E402

from dfpilot import brief, files, schema                                       # noqa: E402


@pytest.fixture
def rt(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _ctx(save, **over):
    st = files.read_state(save)
    st.update(over)
    ctx = type("C", (), {})()
    ctx.s, ctx.dir = st, save
    return ctx


def test_predator_and_intruder_carry_the_offer_expiry():
    d = {"n": 1, "id": 31428, "pos": [20, 58, 131], "race": "PERMIAN_DIMETRODON", "sz": 8897, "reach": 1, "exp": 185603969,
         "cmd": "dfllm cmd squad.sortie '{\"squad\":\"A\"}'"}
    assert schema.validate_event_d("PREDATOR", d) == []
    assert schema.validate_event_d("INTRUDER", {"n": 1, "id": 5, "pos": [1, 2, 3], "k": "inv", "dist": 4, "far": 0, "exp": 5}) == []
    assert schema.validate_event_d("LOCKDOWN_CLOCK", {"why": "unacked:PREDATOR", "days": 3}) == []
    assert schema.validate_event_d("LOCKDOWN_CLOCK", {"why": "x"}) != []          # days is required


def test_a_stale_caravan_is_told_in_the_defense_line(rt):
    on = brief.line_def(_ctx(rt, trade={"caravan": 1, "ratio": 0, "done": 1}))
    assert "CARAVAN on map" in on and "caravan stale" not in on, on
    stale = brief.line_def(_ctx(rt, trade={"caravan": 0, "ratio": 0, "done": 1, "stale": 1}))
    assert "CARAVAN on map" not in stale, stale
    assert "caravan stale (1 listed Leaving over 36 d, not counted)" in stale, stale
    none = brief.line_def(_ctx(rt, trade={"caravan": 0, "ratio": 0, "done": 1}))
    assert "stale" not in none and "CARAVAN" not in none, none
