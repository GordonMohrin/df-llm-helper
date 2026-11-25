"""NEU11 BUG-880: the ladder names the player's order.add MakeBarrel command only when the kernel's container reserve cannot do it itself
(state stock.rsv = 1: a batch stands or was ordered < 3 game days ago and a material exists). Lua side: tests/lua/test_bug878_880_stein.lua."""
import pytest
from test_neu1_wertung_leiter import cfg_dir, run_dir, state  # noqa: F401  (fixtures and helpers of the ladder tests)

from dfpilot import leiter

DWHY = "DF cancels Brew 412x in 7 d: Needs empty food storage item"


def test_ladder_does_not_repeat_the_order_add_while_the_reserve_orders_itself(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(stock={"drink_d": 0, "dwhy": DWHY, "wood": 0, "woodt": 25, "rsv": 1})
    t = leiter.compute(d, s)["tracks"]["versorgung"]
    assert "MakeBarrel" not in t["cmd"] and "Behaelter-Reserve" in t["cmd"], t["cmd"]


def test_ladder_names_the_order_add_when_the_reserve_cannot(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(stock={"drink_d": 0, "dwhy": DWHY, "wood": 0, "woodt": 25})
    cmd = leiter.compute(d, s)["tracks"]["versorgung"]["cmd"]
    assert "MakeBarrel" in cmd and '"mat":"rock"' in cmd, cmd
