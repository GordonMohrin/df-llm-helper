"""F11 planners as pure functions: trade, dig, armor, supply, blueprint validator (offline, deterministic)."""
from __future__ import annotations

import bisect
import itertools
import random
from fractions import Fraction
from pathlib import Path

import pytest

from df_llm_helper.planners import (Area, DigTarget, Finding, Soldier, TradeItem, forecast, has_errors, parse_area, plan_armor,
                              plan_dig, plan_trade, soldier_quota, validate_blueprint)
from df_llm_helper.planners import armor, blueprint, dig, supply, trade
from df_llm_helper.planners.dig import batch_to_csv

HOME = Path(__file__).resolve().parent.parent
FIX = HOME / "fixtures" / "run5"
BAD = HOME / "tests" / "blueprints_bad"
OK = FIX / "blueprints_ok"
MAP = (192, 192, 153)


# =====================================================================================================================
# Trade planner
# =====================================================================================================================

def I(id_, cat, value, weight=1, qty=1, **kw):  # noqa: E743 - kurzer Testhelfer
    return TradeItem(id_, id_.upper(), cat, value, weight, qty, **kw)


def pw(priorities):
    """Independent reference of the priority weights (2*(n-i), first mention wins)."""
    out = {}
    for i, c in enumerate(priorities):
        out.setdefault(c, 2 * (len(priorities) - i))
    return out


def check_plan(plan, own, offer, ratio, reserves, priorities, max_weight):
    """Independent constraint check of a TradePlan."""
    own_by = {i.id: i for i in own}
    offer_by = {i.id: i for i in offer}
    weights = pw(priorities)
    sold = {}
    for ln in plan.sell:
        assert ln.qty > 0 and ln.id in own_by
        sold[ln.id] = sold.get(ln.id, 0) + ln.qty
        assert ln.value == own_by[ln.id].value
    for k, q in sold.items():
        assert q <= own_by[k].qty
    for key, minimum in reserves.items():
        members = [i for i in own if i.id == key or i.category == key]
        if members:
            # minimum stock greater than the stock: then nothing from the group may be sold
            assert sum(i.qty - sold.get(i.id, 0) for i in members) >= min(minimum, sum(i.qty for i in members)), \
                f"Reserve {key} verletzt"
    bought = {}
    for ln in plan.buy:
        assert ln.qty > 0 and ln.id in offer_by
        bought[ln.id] = bought.get(ln.id, 0) + ln.qty
        assert (offer_by[ln.id].priority_category or offer_by[ln.id].category) in weights
    for k, q in bought.items():
        assert q <= offer_by[k].qty
    buy_value = sum(q * offer_by[k].value for k, q in bought.items())
    sell_value = sum(q * own_by[k].value for k, q in sold.items())
    assert (plan.buy_value, plan.sell_value) == (buy_value, sell_value)
    assert Fraction(str(ratio)) * buy_value <= sell_value
    wt = sum(q * offer_by[k].weight for k, q in bought.items())
    assert abs(plan.weight - wt) < 1e-6
    if max_weight is not None:
        assert wt <= max_weight + 1e-6
    return buy_value, sell_value, sum(q * weights[(offer_by[k].priority_category or offer_by[k].category)] * offer_by[k].value
                                      for k, q in bought.items())


def brute_force(own, offer, ratio, reserves, priorities, max_weight):
    """Reference: all purchase and sale vectors; objective (max benefit, then min sale value). Returns (benefit, sale) or (0, 0)."""
    weights = pw(priorities)
    buyable = [i for i in offer if i.qty > 0 and i.value > 0 and (i.priority_category or i.category) in weights]
    sells = []
    for vec in itertools.product(*[range(i.qty + 1) for i in own]):
        ok = True
        for key, minimum in reserves.items():
            members = [j for j, i in enumerate(own) if i.id == key or i.category == key]
            if members and sum(own[j].qty - vec[j] for j in members) < min(minimum, sum(own[j].qty for j in members)):
                ok = False
                break
        if ok:
            sells.append(sum(v * i.value for v, i in zip(vec, own)))
    sells.sort()
    best = (0, 0)   # (benefit, -sale): doing nothing is always permissible
    num = Fraction(str(ratio))
    for vec in itertools.product(*[range(i.qty + 1) for i in buyable]):
        cost = sum(v * i.value for v, i in zip(vec, buyable))
        wt = sum(v * i.weight for v, i in zip(vec, buyable))
        if max_weight is not None and wt > max_weight:
            continue
        need = num * cost
        k = bisect.bisect_left(sells, need)
        if k >= len(sells):
            continue
        benefit = sum(v * weights[i.priority_category or i.category] * i.value for v, i in zip(vec, buyable))
        key = (benefit, -sells[k])
        if key > best:
            best = key
    return best[0], -best[1]


def test_trade_basic_plan_respects_ratio():
    own = [I("becher", "other", 100, 1, 5)]
    offer = [I("mehl", "food", 20, 3, 10)]
    p = plan_trade(own, offer)
    assert p.buy_value == 200 and p.sell_value == 500          # 200 * 2.3 = 460 -> 5 mugs (500)
    assert p.sell[0].qty == 5 and p.buy[0].qty == 10
    assert p.ratio == pytest.approx(2.5)
    assert p.method == "exact"
    check_plan(p, own, offer, 2.3, {}, trade.DEFAULT_PRIORITIES, None)


def test_trade_minimal_sale_only():
    own = [I("a", "other", 50, 1, 10)]
    offer = [I("x", "food", 10, 1, 1)]
    p = plan_trade(own, offer)
    assert p.sell_value == 50 and p.sell[0].qty == 1       # 10 * 2.3 = 23 -> one piece (50) suffices
    assert p.buy_value == 10


def test_trade_exact_ratio_boundary():
    # a purchase value of 100 needs exactly 230 (equality permitted), 229 is not enough
    offer = [I("x", "food", 100, 1, 1)]
    assert plan_trade([I("a", "other", 230, 1)], offer).buy_value == 100
    p = plan_trade([I("a", "other", 229, 1)], offer)
    assert p.buy == [] and p.sell == []
    assert any("nothing is sold" in n for n in p.notes)


def test_trade_nothing_to_sell_buys_nothing():
    p = plan_trade([], [I("x", "food", 10)])
    assert p.buy == [] and p.sell == [] and p.ratio is None
    assert any("nothing to buy" in n for n in p.notes)


def test_trade_empty_offer():
    p = plan_trade([I("a", "other", 10)], [])
    assert p.buy == [] and p.sell == []


def test_trade_reserve_by_item_id_blocks_sale():
    own = [I("gold", "other", 1000, 1, 3), I("trinket", "other", 10, 1, 5)]
    offer = [I("x", "food", 100, 1, 5)]
    p = plan_trade(own, offer, reserves={"gold": 3})
    assert all(s.id != "gold" for s in p.sell)
    check_plan(p, own, offer, 2.3, {"gold": 3}, trade.DEFAULT_PRIORITIES, None)
    assert p.buy == [] and p.sell == []     # only trinkets (5 * 10 = 50) sellable -> max 21 purchase value, piece value 100


def test_trade_reserve_by_category_min_stock():
    own = [I("b1", "cloth", 40, 1, 3), I("b2", "cloth", 30, 1, 3), I("m", "other", 5, 1, 1)]
    offer = [I("x", "food", 10, 1, 100)]
    res = {"cloth": 4}
    p = plan_trade(own, offer, reserves=res)
    sold_cloth = sum(s.qty for s in p.sell if s.category == "cloth")
    assert sold_cloth <= 2                       # 6 pieces - 4 minimum stock
    check_plan(p, own, offer, 2.3, res, trade.DEFAULT_PRIORITIES, None)
    assert p.buy_value > 0


def test_trade_reserve_list_means_never_sell():
    own = [I("a", "other", 100, 1, 2), I("b", "metal", 100, 1, 2)]
    offer = [I("x", "food", 10, 1, 100)]
    p = plan_trade(own, offer, reserves=["metal"])
    assert {s.id for s in p.sell} <= {"a"}
    assert p.sell_value <= 200


def test_trade_reserve_without_match_is_noted():
    p = plan_trade([I("a", "other", 100)], [I("x", "food", 10)], reserves={"nomatch": 2})
    assert any("nomatch" in n for n in p.notes)
    assert p.buy_value == 10


def test_trade_priority_food_before_wood_when_budget_limited():
    own = [I("a", "other", 230, 1, 1)]                       # suffices for a purchase value of 100
    offer = [I("timber", "wood", 100, 1, 1), I("bread", "food", 100, 1, 1)]
    p = plan_trade(own, offer)
    assert [b.id for b in p.buy] == ["bread"]
    p2 = plan_trade(own, offer, priorities=("wood", "food"))
    assert [b.id for b in p2.buy] == ["timber"]


def test_trade_unlisted_category_not_bought():
    p = plan_trade([I("a", "other", 1000)], [I("gem", "gem", 10, 1, 5), I("bread", "food", 10, 1, 1)])
    assert [b.id for b in p.buy] == ["bread"]
    assert any("unlisted" in n for n in p.notes)


def test_trade_priority_category_override():
    own = [I("a", "other", 1000)]
    offer = [I("ingots", "bars", 10, 1, 2, priority_category="metal"), I("bread", "food", 10, 1, 1)]
    p = plan_trade(own, offer, priorities=("metal", "food"))
    assert p.buy[0].id == "ingots" and p.buy[0].qty == 2
    assert offer[0].prio_cat == "metal" and offer[1].prio_cat == "food"


def test_trade_weight_limit_binds():
    own = [I("a", "other", 10_000, 1, 1)]
    offer = [I("stein", "other", 10, 5, 100), I("bread", "food", 10, 1, 100)]
    p = plan_trade(own, offer, max_weight=50)
    assert p.weight <= 50
    assert p.buy[0].id == "bread" and p.buy[0].qty == 50       # food first, full up to the weight limit
    assert any("weight limit" in n for n in p.notes)


def test_trade_weight_zero_limit_allows_only_weightless():
    own = [I("a", "other", 10_000)]
    offer = [I("fl", "food", 10, 0, 3), I("sw", "food", 10, 2, 3)]
    p = plan_trade(own, offer, max_weight=0)
    assert [b.id for b in p.buy] == ["fl"] and p.weight == 0


def test_trade_ratio_zero_buys_everything_sells_nothing():
    p = plan_trade([], [I("x", "food", 10, 1, 4), I("y", "wood", 5, 1, 2)], ratio=0)
    assert p.buy_value == 50 and p.sell == [] and p.sell_value == 0


def test_trade_ratio_below_one_and_float_ratio_exact():
    p = plan_trade([I("a", "other", 50)], [I("x", "food", 100)], ratio=0.5)
    assert p.buy_value == 100 and p.sell_value == 50
    # 2.3 is computed exactly as 23/10 (no float error at 100 * 2.3)
    assert plan_trade([I("a", "other", 230)], [I("x", "food", 100)], ratio=2.3).buy_value == 100


def test_trade_zero_value_and_zero_qty_items_skipped():
    p = plan_trade([I("a", "other", 100)], [I("n", "food", 0, 1, 5), I("q", "food", 10, 1, 0), I("ok", "food", 10)])
    assert [b.id for b in p.buy] == ["ok"]
    assert any("value 0" in n for n in p.notes)


def test_trade_input_validation():
    with pytest.raises(ValueError):
        plan_trade([I("a", "x", 1), I("a", "x", 2)], [])
    with pytest.raises(ValueError):
        plan_trade([I("a", "x", -1)], [])
    with pytest.raises(ValueError):
        plan_trade([I("a", "x", 1.5)], [])
    with pytest.raises(ValueError):
        plan_trade([I("a", "x", True)], [])
    with pytest.raises(ValueError):
        plan_trade([], [], ratio=-1)
    with pytest.raises(ValueError):
        plan_trade([], [], max_weight=-1)
    with pytest.raises(ValueError):
        plan_trade([], [], method="magie")
    with pytest.raises(ValueError):
        plan_trade([I("a", "x", 1)], [], reserves={"a": -1})
    # integer floats are allowed
    assert plan_trade([I("a", "other", 100.0)], [I("x", "food", 10.0)]).buy_value == 10


def test_trade_line_totals_and_dataclass_defaults():
    p = plan_trade([I("a", "other", 100, 2, 5)], [I("x", "food", 10, 1.5, 4)])
    ln = p.buy[0]
    assert ln.total_value == ln.qty * 10 and ln.total_weight == pytest.approx(ln.qty * 1.5)
    item = TradeItem("i", "Name", "food", 5, 1.0)
    assert item.qty == 1 and item.priority_category is None and item.prio_cat == "food"


def test_trade_deterministic():
    rng = random.Random(7)
    own = [I(f"o{i}", rng.choice(["other", "metal", "cloth"]), rng.randint(5, 60), rng.randint(0, 4), rng.randint(1, 4))
           for i in range(8)]
    offer = [I(f"f{i}", rng.choice(["food", "wood", "metal", "other"]), rng.randint(5, 60), rng.randint(0, 4),
               rng.randint(1, 4)) for i in range(8)]
    a = plan_trade(own, offer, max_weight=30)
    b = plan_trade(list(reversed(own)), list(reversed(offer)), max_weight=30)
    assert (a.benefit, a.buy_value, a.sell_value) == (b.benefit, b.buy_value, b.sell_value)
    assert [(x.id, x.qty) for x in a.buy] == [(x.id, x.qty) for x in b.buy]


def test_trade_greedy_for_many_items_stays_valid():
    rng = random.Random(11)
    own = [I(f"o{i}", "other", rng.randint(5, 80), 1, rng.randint(1, 5)) for i in range(40)]
    offer = [I(f"f{i}", rng.choice(["food", "wood", "metal"]), rng.randint(5, 80), rng.randint(0, 5), rng.randint(1, 5))
             for i in range(60)]
    p = plan_trade(own, offer, max_weight=120)
    assert p.method == "greedy"
    assert any("greedy" in n for n in p.notes)
    check_plan(p, own, offer, 2.3, {}, trade.DEFAULT_PRIORITIES, 120)
    e = plan_trade(own[:6], offer[:6], max_weight=20, method="greedy")
    assert e.method == "greedy"
    check_plan(e, own[:6], offer[:6], 2.3, {}, trade.DEFAULT_PRIORITIES, 20)


def test_trade_exact_never_worse_than_greedy():
    rng = random.Random(5)
    for _ in range(25):
        own = [I(f"o{i}", "other", rng.randint(5, 60), 1, rng.randint(1, 3)) for i in range(5)]
        offer = [I(f"f{i}", rng.choice(["food", "wood", "metal"]), rng.randint(5, 60), rng.randint(0, 5), rng.randint(1, 4))
                 for i in range(6)]
        ex = plan_trade(own, offer, max_weight=15)
        gr = plan_trade(own, offer, max_weight=15, method="greedy")
        assert ex.benefit >= gr.benefit


def test_trade_node_limit_is_reported():
    rng = random.Random(3)
    own = [I(f"o{i}", "other", rng.randint(20, 90), 1, 4) for i in range(10)]
    offer = [I(f"f{i}", rng.choice(["food", "wood"]), rng.randint(7, 61), rng.randint(1, 9), 6) for i in range(14)]
    p = plan_trade(own, offer, max_weight=60, node_limit=3)
    assert p.method == "exact-truncated"
    assert any("node limit" in n for n in p.notes)
    check_plan(p, own, offer, 2.3, {}, trade.DEFAULT_PRIORITIES, 60)


def test_trade_exact_method_with_too_many_items_falls_back():
    own = [I(f"o{i}", "other", 100, 1, 10) for i in range(3)]
    offer = [I(f"f{i}", "food", 10 + i, 1, 2) for i in range(trade.MAX_RECURSION_ITEMS + 5)]
    p = plan_trade(own, offer, max_weight=100, method="exact")
    assert p.method == "greedy" and any("too many items" in n for n in p.notes)


def test_trade_float_weights():
    own = [I("a", "other", 10_000)]
    offer = [I("x", "food", 10, 0.5, 100), I("y", "wood", 10, 1.5, 100)]
    p = plan_trade(own, offer, max_weight=12.5)
    check_plan(p, own, offer, 2.3, {}, trade.DEFAULT_PRIORITIES, 12.5)
    assert p.buy[0].id == "x" and p.buy[0].qty == 25


def test_trade_ratio_zero_with_weight_limit_uses_search_without_cost_cap():
    offer = [I("a", "food", 10, 3, 5), I("b", "food", 7, 2, 5), I("c", "wood", 9, 4, 5)]
    p = plan_trade([], offer, ratio=0, max_weight=17)
    check_plan(p, [], offer, 0, {}, trade.DEFAULT_PRIORITIES, 17)
    ref = brute_force([], offer, 0, {}, trade.DEFAULT_PRIORITIES, 17)
    assert p.benefit == ref[0] and p.sell == []


def test_trade_zero_value_own_items_are_never_sold():
    own = [I("nix", "other", 0, 1, 5), I("a", "other", 100, 1, 2)]
    p = plan_trade(own, [I("x", "food", 10, 1, 3)])
    assert all(s.id != "nix" for s in p.sell)


def test_trade_exact_with_too_many_sell_items_falls_back_to_greedy_sale():
    own = [I(f"o{i}", "other", 10 + i, 1, 1) for i in range(trade.MAX_RECURSION_ITEMS + 10)]
    p = plan_trade(own, [I("x", "food", 50, 1, 3)], method="exact")
    check_plan(p, own, [I("x", "food", 50, 1, 3)], 2.3, {}, trade.DEFAULT_PRIORITIES, None)
    assert p.method == "greedy" and any("sale via greedy" in n for n in p.notes)


def test_trade_priority_weights_helper():
    assert trade.priority_weights(("a", "b", "c")) == {"a": 6, "b": 4, "c": 2}
    assert trade.priority_weights(("a", "a")) == {"a": 4}


def _random_case(seed):
    rng = random.Random(seed)
    cats = ["food", "wood", "metal", "cloth", "other", "gem"]
    own = [TradeItem(f"o{i}", f"Own{i}", rng.choice(cats), rng.randint(1, 60), rng.randint(0, 6), rng.randint(1, 3))
           for i in range(rng.randint(0, 6))]
    offer = [TradeItem(f"f{i}", f"Off{i}", rng.choice(cats), rng.randint(1, 60), rng.randint(0, 6), rng.randint(1, 3),
                       rng.choice([None, None, None, rng.choice(cats)]))
             for i in range(rng.randint(1, 6))]
    ratio = rng.choice([2.3, 2.3, 1.0, 1.5, 3.0, 0.5])
    reserves = {}
    for _ in range(rng.randint(0, 2)):
        key = rng.choice([i.id for i in own] + cats) if own else rng.choice(cats)
        reserves[key] = rng.randint(0, 4)
    priorities = rng.choice([trade.DEFAULT_PRIORITIES, ("wood", "food"), ("metal", "cloth", "food", "wood", "other")])
    max_weight = rng.choice([None, None, 0, 5, 12, 25, 60])
    return own, offer, ratio, reserves, priorities, max_weight


@pytest.mark.parametrize("seed", range(300))
def test_trade_property_optimal_against_bruteforce(seed):
    own, offer, ratio, reserves, priorities, max_weight = _random_case(seed)
    assert len(own) + len(offer) <= 12
    plan = plan_trade(own, offer, ratio=ratio, reserves=reserves, priorities=priorities, max_weight=max_weight)
    _, sell_value, benefit = check_plan(plan, own, offer, ratio, reserves, priorities, max_weight)
    ref_benefit, ref_sell = brute_force(own, offer, ratio, reserves, priorities, max_weight)
    assert plan.method == "exact"
    assert benefit == plan.benefit
    assert (benefit, -sell_value) == (ref_benefit, -ref_sell), f"seed {seed}"


# =====================================================================================================================
# Dig planner
# =====================================================================================================================

def check_order(area, plan, walkable=dig.WALKABLE):
    """Invariant: every designated tile borders walkable/planned area; no duplicates/unreachable targets."""
    opened = {(x + area.x0, y + area.y0) for y, row in enumerate(area.rows) for x, ch in enumerate(row)
              if ch in walkable or ch == "d"}
    seen = set()
    for t in plan.order:
        assert t not in seen, f"Duplikat {t}"
        assert t not in plan.unreachable
        x, y = t
        assert area.get(x, y) in dig.DIGGABLE
        assert any(n in opened for n in [(x, y - 1), (x - 1, y), (x + 1, y), (x, y + 1)]), f"{t} not reachable"
        opened.add(t)
        seen.add(t)


ROOM = [
    "##########",
    "#........#",
    "#........#",
    "##########",
    "##########",
    "##########",
]


def test_parse_area_real_fixture():
    a = parse_area((FIX / "area_z130.txt").read_text(encoding="utf-8"))
    assert (a.z, a.x0, a.y0, a.width, a.height) == (130, 80, 90, 40, 28)
    assert a.map_size == (192, 192, 153)
    assert a.get(80, 90) == "?" and a.get(99, 96) == "." and a.get(119, 101) == "D"
    assert a.get(79, 90) is None and a.get(80, 118) is None and a.get(120, 100) is None


def test_parse_area_second_fixture_with_trailing_spaces():
    a = parse_area((FIX / "area_z133.txt").read_text(encoding="utf-8"))
    assert (a.z, a.width, a.height) == (133, 45, 25)
    assert all(len(r) == 45 for r in a.rows)
    assert a.get(100, 92) == " " or a.get(97, 92) == "C"


def test_parse_area_errors():
    with pytest.raises(ValueError):
        parse_area("text only")
    with pytest.raises(ValueError):
        parse_area("z=1 x=5..2 y=0..1\n")
    with pytest.raises(ValueError):
        parse_area("z=1 x=0..3 y=0..2\n     0123\n   0 ####\n")


def test_dig_orders_by_distance_from_open_area():
    # open area at the top (y=1,2); targets in a column below -> from top to bottom
    targets = [(4, 5), (4, 3), (4, 4)]
    p = plan_dig(ROOM, targets)
    assert p.order == [(4, 3), (4, 4), (4, 5)]
    assert p.unreachable == []


def test_dig_unreachable_enclosed_target():
    g = ["#####", "#...#", "#####", "#####", "#####"]
    p = plan_dig(g, [(2, 4)])
    assert p.unreachable == [(2, 4)] and p.batches == []
    assert p.reasons[(2, 4)] == "not_adjacent"


def test_dig_unknown_and_not_diggable_and_outside():
    g = ["#?#", "#.#", "#C#", "###"]
    p = plan_dig(g, [(1, 0), (1, 2), (9, 9), (-1, 0)])
    assert p.reasons[(1, 0)] == "unknown"
    assert p.reasons[(1, 2)].startswith("not_diggable")
    assert p.reasons[(9, 9)] == "outside" and p.reasons[(-1, 0)] == "outside"
    assert p.order == []


def test_dig_chain_through_targets_becomes_reachable():
    # (4,3) borders the room, (4,4) only via (4,3): both reachable, in chain order
    p = plan_dig(ROOM, [(4, 4), (4, 3)])
    assert p.order == [(4, 3), (4, 4)]
    p2 = plan_dig(ROOM, [(4, 4)])
    assert p2.unreachable == [(4, 4)]          # not reachable without the intermediate tile


def test_dig_duplicates_open_and_designated_skipped():
    g = ["#####", "#.d.#", "#####", "#####"]
    p = plan_dig(g, [(1, 2), (1, 2, 5), (1, 1), (2, 1), (2, 2)])
    assert p.order == [(1, 2), (2, 2)] or p.order == [(2, 2), (1, 2)]
    reasons = dict((t, r) for t, r in p.skipped)
    assert reasons[(1, 2)] == "duplicate" and reasons[(1, 1)] == "already_open" and reasons[(2, 1)] == "already_designated"
    assert len(p.order) == len(set(p.order))


def test_dig_batch_size_limits():
    g = ["#" * 30, "." * 30] + ["#" * 30] * 10
    targets = [(x, 2) for x in range(30)]
    p = plan_dig(g, targets, picks=1, max_open=150)
    assert [len(b) for b in p.batches] == [10, 10, 10]               # 10 * picks
    p = plan_dig(g, targets, picks=5, max_open=12)
    assert [len(b) for b in p.batches] == [12, 12, 6]                # limited by max_open
    p = plan_dig(g, targets, picks=3, max_open=150)
    assert max(len(b) for b in p.batches) == 30 and len(p.order) == 30


def test_dig_open_jobs_reduce_first_batch():
    g = ["#" * 30, "." * 30] + ["#" * 30] * 10
    targets = [(x, 2) for x in range(30)]
    p = plan_dig(g, targets, picks=1, open_jobs=4)
    assert [len(b) for b in p.batches] == [6, 10, 10, 4]
    p = plan_dig(g, targets, picks=1, open_jobs=10)
    assert [len(b) for b in p.batches][0] == 10 and any("open jobs" in n for n in p.notes)
    assert len(p.order) == 30


def test_dig_open_jobs_default_counts_existing_designations():
    g = ["d.d" + "." * 27, "#" * 30, "#" * 30]
    p = plan_dig(g, [(x, 1) for x in range(1, 30)], picks=1)
    assert [len(b) for b in p.batches] == [8, 10, 10, 1]        # 10 - 2 existing 'd'


def test_dig_no_picks_means_no_batches():
    p = plan_dig(ROOM, [(4, 3)], picks=0)
    assert p.batches == [] and p.unreachable == []
    assert any("pick carriers" in n for n in p.notes)
    assert plan_dig(ROOM, [], picks=2).batches == []


def test_dig_priority_order_and_inheritance():
    g = ["#########", "#.......#", "#########", "#########", "#########"]
    # (1,2) near/unimportant (prio 9), (7,2) near/medium (5); (4,2)->(4,3)->(4,4): target (4,4) has prio 1
    targets = [(1, 2, 9), (7, 2, 5), (4, 2, 9), (4, 3, 9), (4, 4, 1)]
    p = plan_dig(g, targets)
    assert p.order[:3] == [(4, 2), (4, 3), (4, 4)]          # access inherits prio 1
    p2 = plan_dig(g, targets, inherit_priority=False)
    assert p2.order[0] == (7, 2)                                # without inheritance prio 5 first
    check_order(Area(0, 0, 0, g), p)
    check_order(Area(0, 0, 0, g), p2)


def test_dig_access_adds_corridor():
    g = ["#####", "#...#", "#####", "#####", "#####", "##?##"]
    area = Area(0, 0, 0, g)
    p0 = plan_dig(area, [(2, 4)])
    assert p0.unreachable == [(2, 4)]
    p = plan_dig(area, [(2, 4)], access=True)
    assert p.unreachable == [] and set(p.access) == {(2, 2), (2, 3)}
    assert p.order == [(2, 2), (2, 3), (2, 4)]
    assert any("access tiles" in n for n in p.notes)
    check_order(area, p)
    # no access through unknown tiles
    p = plan_dig(area, [(2, 5)], access=True)
    assert p.reasons[(2, 5)] == "unknown"
    g2 = ["#####", "#...#", "?????", "#####"]
    p = plan_dig(Area(0, 0, 0, g2), [(2, 3)], access=True)
    assert p.unreachable == [(2, 3)] and p.reasons[(2, 3)] == "not_adjacent"


def test_dig_starts_restrict_region():
    g = ["#####.#####", "#.........#", "###########", "###########"]
    # the open area consists of one room; without starts every walkable tile counts
    p = plan_dig(g, [(5, 2)], starts=[(1, 1)])
    assert p.order == [(5, 2)]
    g2 = ["###.###", "###.###", "#######", "#.....#", "#######", "#######"]
    # two separate rooms: only the first is a start
    p = plan_dig(g2, [(3, 2), (3, 4)], starts=[(3, 0)])
    assert p.order == [(3, 2)] and p.unreachable == [(3, 4)]
    p = plan_dig(g2, [(3, 2), (3, 4)])           # without starts: both rooms count
    assert set(p.order) == {(3, 2), (3, 4)}
    p = plan_dig(g2, [(3, 2)], starts=[(0, 0), (9, 9)])
    assert p.order == [] and any("start point" in n for n in p.notes) and any("no valid start point" in n for n in p.notes)


def test_dig_origin_offset_and_tuple_inputs():
    p = plan_dig(ROOM, [DigTarget(104, 53), (104, 54, 2)], origin=(100, 50))
    assert p.order == [(104, 53), (104, 54)]
    with pytest.raises(ValueError):
        plan_dig(ROOM, [(1, 2, 3, 4)])


def test_dig_deterministic_and_input_order_independent():
    rng = random.Random(1)
    g = ["#" * 20, "." * 20] + ["#" * 20] * 8
    targets = [(rng.randrange(20), rng.randrange(2, 10), rng.randrange(1, 4)) for _ in range(40)]
    a = plan_dig(g, targets, picks=2)
    b = plan_dig(g, targets, picks=2)
    c = plan_dig(g, list(reversed(targets)), picks=2)
    assert a == b
    assert a.order == c.order and a.unreachable == c.unreachable
    check_order(Area(0, 0, 0, g), a)


@pytest.mark.parametrize("seed", range(40))
def test_dig_property_never_unreachable_and_stable(seed):
    rng = random.Random(seed)
    w, h = 24, 14
    chars = "##########,*.?"
    g = ["".join(rng.choice(chars) for _ in range(w)) for _ in range(h)]
    g[1] = "." * w                                    # a corridor as the start area
    area = Area(0, 0, 0, g)
    targets = [(rng.randrange(-2, w + 2), rng.randrange(-2, h + 2), rng.randrange(0, 4)) for _ in range(60)]
    picks, max_open, access = rng.randrange(1, 4), rng.choice([7, 15, 150]), bool(seed % 2)
    p1 = plan_dig(area, targets, picks=picks, max_open=max_open, access=access)
    p2 = plan_dig(area, targets, picks=picks, max_open=max_open, access=access)
    assert p1 == p2                                   # stable
    check_order(area, p1)
    for b in p1.batches:
        assert 0 < len(b) <= min(max_open, 10 * picks)
    # every target is either planned, skipped or unreachable (nothing gets lost)
    skipped = {t for t, _ in p1.skipped}
    assert {(t[0], t[1]) for t in targets} <= set(p1.order) | set(p1.unreachable) | skipped


def test_dig_real_fixture_ore_line():
    area = parse_area((FIX / "area_z130.txt").read_text(encoding="utf-8"))
    targets = [(x, 110, 1) for x in range(103, 115)] + [(x, 110, 2) for x in range(100, 103)] + [(110, 112, 3)]
    p = plan_dig(area, targets, picks=2, max_open=150)
    check_order(area, p)
    assert {t for t in p.order} == {(x, 110) for x in range(103, 115)}
    assert set(p.unreachable) == {(100, 110), (101, 110), (102, 110), (110, 112)}
    assert p.reasons[(101, 110)] == "unknown"
    assert [len(b) for b in p.batches] == [12]
    again = plan_dig(area, targets, picks=2, max_open=150)
    assert again == p
    # ore tiles in the rock that only border undiscovered area: not reachable
    p = plan_dig(area, [(100, 110), (103, 108), (80, 96)], picks=1)
    assert (100, 110) in p.unreachable and (80, 96) in p.unreachable       # borders only workshop/undiscovered
    check_order(area, p)


def test_dig_real_fixture_access_to_deep_ore():
    area = parse_area((FIX / "area_z130.txt").read_text(encoding="utf-8"))
    # ore vein (103,107..109) behind the rock x=99/103: reachable via access tiles, never via '?'
    p = plan_dig(area, [(103, 108, 1)], access=True)
    check_order(area, p)
    assert p.unreachable == [] or p.reasons[p.unreachable[0]] in ("not_adjacent", "unknown")


def test_dig_batch_to_csv_validates():
    text, origin = batch_to_csv([(5, 7), (7, 7), (6, 8)])
    assert origin == (5, 7)
    assert text.splitlines() == ["#dig label(dig)", "d,,d", ",d,"]
    assert not validate_blueprint(text, MAP)
    with pytest.raises(ValueError):
        batch_to_csv([])


def test_dig_plan_roundtrip_to_blueprint():
    area = parse_area((FIX / "area_z130.txt").read_text(encoding="utf-8"))
    p = plan_dig(area, [(x, 110) for x in range(104, 114)], picks=1)
    for batch in p.batches:
        text, _ = batch_to_csv(batch)
        assert not has_errors(validate_blueprint(text, MAP))


# =====================================================================================================================
# Armor requirement
# =====================================================================================================================

@pytest.mark.parametrize("pop,expected", [(0, 0), (1, 0), (14, 0), (15, 2), (39, 2), (40, 4), (59, 4), (60, 6), (61, 7),
                                          (70, 7), (80, 8), (100, 10), (101, 11), (200, 20)])
def test_armor_quota_staffel(pop, expected):
    assert soldier_quota(pop) == expected


def test_armor_quota_configurable_and_invalid():
    assert soldier_quota(30, tiers=((10, 1), (20, 3)), percent=20) == 6        # 30 > 20 -> max(3, 20 %)
    assert soldier_quota(20, tiers=((10, 1), (20, 3))) == 3
    assert soldier_quota(50, tiers=(), percent=10) == 5
    with pytest.raises(ValueError):
        soldier_quota(-1)


def test_armor_pop_below_threshold_needs_nothing():
    p = plan_armor(10, [], {}, {"iron": 100})
    assert p.quota == 0 and p.recruits_needed == 0 and p.orders == [] and p.deferred == [] and p.bars_needed == 0


def test_armor_recruits_full_sets_in_slot_order():
    p = plan_armor(20, [], {}, {"iron": 1000})
    assert p.quota == 2 and p.recruits_needed == 2 and p.soldiers_now == 0
    assert [o.slot for o in p.orders] == list(armor.SLOTS)
    assert all(o.qty == 2 for o in p.orders)
    per_set = sum(armor.BARS_PER_PIECE.values())
    assert p.bars_needed == 2 * per_set == sum(o.bars_total for o in p.orders)
    assert p.bars_missing == 0 and p.deferred == []
    assert any("missing up to the quota" in n for n in p.notes)


def test_armor_missing_parts_per_soldier():
    soldiers = [Soldier(1, "Urist", {"weapon", "breastplate", "helm"}), Soldier(2, "Bomrek", ["Waffe", "Schild"])]
    p = plan_armor(20, soldiers, {}, {"iron": 1000})
    forge = {o.slot: o.qty for o in p.orders}
    assert forge == {"shield": 1, "greaves": 2, "boots": 2, "gauntlets": 2, "breastplate": 1, "helm": 1}
    assert p.recruits_needed == 0 and p.soldiers_now == 2


def test_armor_stock_used_before_forging():
    soldiers = [{"id": 7, "equipped": ["weapon"]}]
    stock = {"breastplate": 1, "helm": 1, "boots": 5}
    p = plan_armor(15, soldiers, stock, {"iron": 1000})        # quota 2 -> 1 recruit
    assert (7, "breastplate") in p.from_stock and (7, "helm") in p.from_stock and (7, "boots") in p.from_stock
    assert ("recruit#1", "boots") in p.from_stock
    forge = {o.slot: o.qty for o in p.orders}
    assert "boots" not in forge and forge["breastplate"] == 1 and forge["weapon"] == 1


def test_armor_bars_shortage_defers_later_slots():
    p = plan_armor(20, [], {}, {"iron": 7})
    assert p.bars_missing == p.bars_needed - 7 > 0
    assert sum(o.bars_total for o in p.orders) <= 7
    assert p.deferred and all(o.metal == "" for o in p.deferred)
    # order: weapons paid first, later slots deferred
    assert p.orders[0].slot == "weapon"
    assert any("deferred" in n for n in p.notes)


def test_armor_metal_choice_steel_before_iron_and_split():
    p = plan_armor(20, [], {}, {"iron": 100, "steel": 3, "adamantine": 5})
    first = p.orders[0]
    assert first.slot == "weapon" and first.metal == "steel" and first.qty == 1       # 3 bars = 1 weapon
    assert {o.metal for o in p.orders} <= {"steel", "iron", "adamantine"}
    assert sum(o.bars_total for o in p.orders if o.metal == "steel") <= 3
    # further metals come alphabetically after the fixed order
    p = plan_armor(20, [], {}, {"zinn": 100, "adamantine": 100, "bronze": 100})
    assert p.orders[0].metal == "bronze"


def test_armor_fragmented_bars_noted():
    # 4 bars in total, but spread over two metals: one weapon (3 bars) fits no metal
    p = plan_armor(15, [Soldier(1, "x", set(armor.SLOTS) - {"weapon"}), Soldier(2, "y", set(armor.SLOTS))], {},
                   {"iron": 2, "copper": 2})
    assert [o.slot for o in p.deferred] == ["weapon"] and p.bars_missing == 0
    assert any("several metals" in n for n in p.notes)


def test_armor_unknown_slot_and_duplicate_ids_noted():
    soldiers = [Soldier(1, "a", ["cloak"]), Soldier(1, "b", [])]
    p = plan_armor(15, soldiers, {"doorknob": 3}, {"iron": 100})
    assert any("cloak" in n for n in p.notes)
    assert any("doorknob" in n for n in p.notes)
    assert any("duplicate" in n for n in p.notes)


def test_armor_more_soldiers_than_quota():
    soldiers = [Soldier(i, f"s{i}", armor.SLOTS) for i in range(5)]
    p = plan_armor(20, soldiers, {}, {})
    assert p.orders == [] and p.deferred == [] and any("> quota" in n for n in p.notes)


def test_armor_validation_and_plain_ids():
    with pytest.raises(ValueError):
        plan_armor(20, [], {"helm": -1}, {})
    with pytest.raises(ValueError):
        plan_armor(20, [], {}, {"iron": -1})
    p = plan_armor(20, [101, 102], {}, {"iron": 500})       # bare IDs = soldiers without equipment
    assert p.soldiers_now == 2 and {o.qty for o in p.orders} == {2}


def test_armor_custom_table():
    table = {s: 1 for s in armor.SLOTS}
    p = plan_armor(20, [], {}, {"iron": 14}, bars_per_piece=table)
    assert p.bars_needed == 14 and p.bars_missing == 0 and sum(o.qty for o in p.orders) == 14


# =====================================================================================================================
# Supply forecast
# =====================================================================================================================

def test_supply_simple_depletion():
    f = forecast({"drink": 100}, pop=10, consumption={"drink": 1.0})
    assert f.days_left["drink"] == pytest.approx(10.0)
    assert f.curve["drink"][0] == 100 and f.curve["drink"][10] == 0 and f.curve["drink"][-1] == 0
    assert f.soonest == pytest.approx(10.0)
    assert len(f.curve["drink"]) == 337 and len(f.pop_curve) == 337


def test_supply_fractional_day():
    f = forecast({"food": 25}, pop=10, consumption={"food": 1.0}, horizon_days=10)
    assert f.days_left["food"] == pytest.approx(2.5)


def test_supply_production_covers_consumption_none():
    f = forecast({"drink": 5}, 10, {"drink": 1.0}, {"drink": 12}, horizon_days=100)
    assert f.days_left["drink"] is None and f.warn == [] and f.soonest is None
    assert f.curve["drink"][-1] > 5


def test_supply_production_extends_time():
    f = forecast({"drink": 100}, 10, {"drink": 1.0}, {"drink": 5})
    assert f.days_left["drink"] == pytest.approx(20.0)


def test_supply_growth_continuous_shortens():
    base = forecast({"drink": 100}, 10, {"drink": 1.0})
    grown = forecast({"drink": 100}, 10, {"drink": 1.0}, growth=1.0)
    assert grown.days_left["drink"] < base.days_left["drink"]
    assert grown.pop_curve[5] == 15


def test_supply_growth_waves():
    f = forecast({"drink": 100}, 10, {"drink": 1.0}, growth=[(2, 10)], horizon_days=20)
    # day 1: -10 (90), from day 2: -20 per day -> 70, 50, 30, 10, day 6: end after half of the day
    assert f.days_left["drink"] == pytest.approx(5.5)
    assert f.pop_curve[1] == 10 and f.pop_curve[2] == 20


def test_supply_warn_threshold_and_stock_zero():
    f = forecast({"drink": 100, "food": 0}, 10, {"drink": 1.0, "food": 1.0}, warn_days=20)
    assert f.days_left["food"] == 0.0
    assert any("drink" in w for w in f.warn) and any("food" in w for w in f.warn)
    f = forecast({"drink": 100}, 10, {"drink": 1.0}, warn_days=5)
    assert f.warn == []


def test_supply_horizon_limits_detection():
    f = forecast({"drink": 1000}, 10, {"drink": 1.0}, horizon_days=50)
    assert f.days_left["drink"] is None           # 100 days of supply > horizon
    f0 = forecast({"drink": 10}, 10, {"drink": 1.0}, horizon_days=0)
    assert f0.days_left["drink"] is None and f0.curve["drink"] == [10.0]


def test_supply_default_consumption_matches_status_lua():
    # status.lua: days = floor(stock * 84 / (pop * per_season)); food 2, drinks 5
    f = forecast({"drink": 115, "food": 46}, pop=23)
    assert f.days_left["drink"] == pytest.approx(115 * 84 / (23 * 5), rel=1e-3)
    assert f.days_left["food"] == pytest.approx(46 * 84 / (23 * 2), rel=1e-3)
    assert supply.DEFAULT_CONSUMPTION["drink"] == pytest.approx(5 / 84)


def test_supply_unknown_consumption_resource_warned_only_when_explicit():
    f = forecast({"drink": 10}, 1, {"drink": 0.1, "food": 0.1})
    assert any("food" in w and "stock figure" in w for w in f.warn)
    f = forecast({"drink": 10}, 1)
    assert not any("stock figure" in w for w in f.warn)


def test_supply_zero_population_and_missing_consumption():
    f = forecast({"drink": 10, "wood": 5}, pop=0, consumption={"drink": 1.0})
    assert f.days_left == {"drink": None, "wood": None}
    f = forecast({"wood": 5}, pop=3, consumption={"drink": 1.0})
    assert f.days_left["wood"] is None


def test_supply_validation():
    with pytest.raises(ValueError):
        forecast({"drink": -1}, 1)
    with pytest.raises(ValueError):
        forecast({"drink": 1}, -1)
    with pytest.raises(ValueError):
        forecast({"drink": 1}, 1, horizon_days=-1)
    with pytest.raises(ValueError):
        forecast({"drink": 1}, 1, {"drink": -0.1})


def test_supply_monotone_in_stock():
    prev = -1.0
    for stock in range(0, 200, 10):
        d = forecast({"drink": stock}, 10, {"drink": 1.0}, horizon_days=100).days_left["drink"]
        d = 100.0 if d is None else d
        assert d >= prev
        prev = d


# =====================================================================================================================
# Blueprint validator
# =====================================================================================================================

def codes(text, **kw):
    return {f.code for f in validate_blueprint(text, **kw)}


def test_blueprint_all_ten_bad_files_found():
    expected = [line.split(";") for line in (BAD / "EXPECTED.txt").read_text().split() if line]
    assert len(expected) == 10 and len({c for _, c in expected}) == 10      # ten different errors
    for name, code in expected:
        findings = validate_blueprint((BAD / name).read_text(encoding="utf-8"), map_size=MAP)
        assert code in {f.code for f in findings}, f"{name}: {code} not found ({findings})"
        assert has_errors(findings)
    on_disk = {p.name for p in BAD.glob("*.csv")}
    assert on_disk == {n for n, _ in expected}


def test_blueprint_ok_files_accepted():
    files = sorted(OK.glob("*.csv"))
    assert len(files) >= 5
    for f in files:
        findings = validate_blueprint(f.read_text(encoding="utf-8"), map_size=MAP)
        assert findings == [], f"{f.name}: {findings}"


def test_blueprint_real_project_blueprints_have_no_errors():
    repo = HOME.parent
    files = sorted((repo / "blueprints-bau").glob("*.csv")) + sorted((repo / "tools" / "out").glob("dorm_*.csv"))
    if not files:
        pytest.skip("no project blueprints in the repo")
    for f in files:
        assert not has_errors(validate_blueprint(f.read_text(encoding="utf-8"), map_size=MAP)), f.name


def test_blueprint_empty_inputs():
    for text in ("", "   \n", ",,,\n,,\n", "﻿\n"):
        assert codes(text) == {"E_EMPTY"}


def test_blueprint_header_variants_accepted():
    ok = "#build label(x) workshops (origin 1,2)\nwm\n"
    assert validate_blueprint(ok) == []
    assert validate_blueprint("#dig,,,\nd,,\n") == []                 # spreadsheet export with commas
    assert validate_blueprint("#BUILD\nCw\n") == []                   # case does not matter
    assert validate_blueprint("#place\nf(2x2)\n") == []
    assert validate_blueprint("#dig\r\nd\r\n") == []                  # CRLF
    assert validate_blueprint("﻿#dig\nd\n") == []                # BOM


def test_blueprint_comment_line_is_error_not_section_reset():
    f = validate_blueprint("#dig\nd\n# expected: nothing\nd\n")
    assert [x.code for x in f] == ["E_HEAD"] and f[0].line == 3


def test_blueprint_unknown_head_still_checks_cells():
    f = validate_blueprint("#bild\nCw(5x\n")
    assert {x.code for x in f} == {"E_HEAD", "E_PAREN"}


def test_blueprint_head_balance():
    assert "E_PAREN" in codes("#build label(x\nCw\n")
    assert "E_BRACE" in codes("#build {x\nCw\n")


def test_blueprint_cell_syntax_errors():
    assert "E_PAREN" in codes("#build\nCw)\n")
    assert "E_PAREN" in codes("#build\nCw(5x5\n")
    assert "E_BRACE" in codes("#zone\nm}\n")
    assert "E_BRACE" in codes("#zone\nm{location=hospital\n")
    assert "E_QUOTE" in codes('#place\nf{name="Food}\n')
    assert "E_CELL" in codes("#build\n{name=x}\n")
    assert "E_CELL" in codes("#build\nb{a=1}{b=2}\n")
    assert "E_CELL" in codes("#build\nCw(2x2)(3x3)\n")
    assert "E_CELL" in codes("#build\nCw(2x2)x\n")
    assert "E_CELL" in codes("#build\nw m\n")
    assert "E_PAREN" in codes("#build\nCw(2x2))\n")
    assert "E_BRACE" in codes("#zone\nm{a=1}}\n")


@pytest.mark.parametrize("ext", ["(5x)", "(x5)", "(0x3)", "(3x0)", "(abc)", "()", "(5x5x)", "(3x3x0)", "(99999x1)", "(1x1x5000)"])
def test_blueprint_broken_sizes(ext):
    assert "E_SIZE" in codes(f"#build\nCw{ext}\n"), ext


@pytest.mark.parametrize("ext", ["(5x5)", "(1x1)", "(-3x2)", "(3x-2)", "( 5 x 5 )", "(2x2x3)", "(2x2x-2)"])
def test_blueprint_valid_sizes(ext):
    assert validate_blueprint(f"#build\nCw{ext}\n") == [], ext


def test_blueprint_zone_keys():
    for k in "mbhDBoTd":
        assert validate_blueprint(f"#zone\n{k}(2x2)\n") == []
    assert validate_blueprint("#zone\nm{location=hospital allow=residents}(7x7)\n") == []
    assert validate_blueprint('#zone\nm{name="Meine Halle" location=tavern}\n') == []
    assert "E_ZONEKEY" in codes("#zone\nq\n")
    assert "E_ZONEKEY" in codes("#zone\nmm\n")
    assert validate_blueprint("#zone\nt(2x2)\n") == []     # BUG-109: t = animal training in quickfort's zone table
    for k in "npwjfsgc":                                   # BUG-109: the rest of quickfort's zone keys
        assert validate_blueprint(f"#zone\n{k}\n") == []
    assert validate_blueprint("#zone\nX\n", zone_keys="X") == []
    # the same letter in #build is not a zone key
    assert validate_blueprint("#build\nD(5x5)\n") == []


def test_blueprint_overlaps():
    assert "E_OVERLAP" in codes("#build\nwm,wr\n")                       # 3x3 centered: x-1..x+1 overlaps
    assert validate_blueprint("#build\n,wm,,,wr\n") == []                # exactly adjacent is ok
    assert "E_OVERLAP" in codes("#build\nCw(3x3),,,\n,,,\n,,Cw\n")      # wall inside the block
    assert "E_OVERLAP" in codes("#build\nD(5x5)\n,,,,,wm\n")
    assert "E_OVERLAP" in codes("#build\n,,,D\n,,,\n,,,,wm\n")           # centered depot (5x5) with a workshop
    assert "E_OVERLAP" in codes("#place\nf(3x3),,\n,,\n,,g\n")
    assert validate_blueprint("#place\nf(3x3),,,g\n") == []
    assert "E_OVERLAP" in codes("#build\nCw(3x3),,\n,,Cw(3x3)\n")      # corner overlaps
    assert validate_blueprint("#build\nCw(3x1)\nCw(1x3)\n") == []        # L shape without a shared tile
    f = validate_blueprint("#build\nwm,wr,wt\n")
    assert len([x for x in f if x.code == "E_OVERLAP"]) == 2             # one message per later building


def test_blueprint_overlap_levels_independent():
    # identical tiles on different levels are no conflict, with (WxHxD) they are
    assert validate_blueprint("#build\nwm\n#>\nwm\n") == []
    assert "E_OVERLAP" in codes("#build\nCw(2x2x2)\n#>\nCw\n")
    assert validate_blueprint("#build\nCw(2x2x2)\n#>\n#>\nCw\n") == []
    assert validate_blueprint("#build\nCw(2x2x-2)\n#<\n#<\nCw\n") == []


def test_blueprint_overlap_not_checked_across_sections_and_dig():
    assert validate_blueprint("#build\nwm\n#build\nwm\n") == []
    assert validate_blueprint("#dig\nd(5x5),,\n,,d\n") == []
    assert validate_blueprint("#zone\nm(3x3),,\n,,b\n") == []             # different zone types may overlap


def test_blueprint_zone_same_key_overlap_warns():
    f = validate_blueprint("#zone\nT(3x3),,\n,,T\n")
    assert [x.code for x in f] == ["W_ZONE_OVERLAP"] and f[0].level == "warning"
    assert not has_errors(f)


def test_blueprint_bounds():
    assert "E_BOUNDS" in codes("#build\nCw(200x1)\n", map_size=(192, 192))
    assert "E_BOUNDS" in codes("#dig\nd(1x200)\n", map_size=(192, 192))
    assert validate_blueprint("#build\nCw(192x1)\n", map_size=(192, 192)) == []
    assert validate_blueprint("#build\nCw(200x1)\n") == []                 # no check without a map size
    assert "E_BOUNDS" in codes("#build\nCw(10x1)\n", map_size=(192, 192, 153), origin=(185, 0))
    assert validate_blueprint("#build\nCw(10x1)\n", map_size=(192, 192), origin=(182, 5)) == []
    assert "E_BOUNDS" in codes("#build\nCw\n", map_size=(192, 192), origin=(-1, 0))
    # centered workshop in column 0: check against the lower bound only with origin
    assert validate_blueprint("#build\nwm\n", map_size=(192, 192)) == []
    assert "E_BOUNDS" in codes("#build\nwm\n", map_size=(192, 192), origin=(0, 5))
    assert validate_blueprint("#build\nwm\n", map_size=(192, 192), origin=(1, 1)) == []


def test_blueprint_section_errors():
    f = validate_blueprint("Cw\n#dig\nd\n")
    assert f[0].code == "E_NOSECTION" and f[0].line == 1
    assert [x.code for x in validate_blueprint("#>\n#dig\nd\n")] == ["E_NOSECTION"]
    assert len([x for x in validate_blueprint("Cw\nCw\nCw\n") if x.code == "E_NOSECTION"]) == 1


def test_blueprint_order_warning():
    f = validate_blueprint("#build\nwm\n#dig\nd(3x3)\n")
    assert [x.code for x in f] == ["W_ORDER"] and f[0].line == 3 and "dig first" in f[0].msg
    assert validate_blueprint("#dig\nd(3x3)\n#build\nb\n") == []
    assert not has_errors(f)


def test_blueprint_column_count_warning():
    # BUG-109: ragged/filler rows (fewer columns, trailing commas) are normal quickfort CSV
    assert validate_blueprint("#build\nb,,b\nb,b\n,,,\n") == []
    f = validate_blueprint("#build\nb,b\nb,,b\n")             # content beyond the first row's width
    assert [x.code for x in f] == ["W_COLS"]
    assert not has_errors(f)
    # a level change resets the expectation, blank lines do not count
    assert validate_blueprint("#dig\nd,d\n\nd,d\n#>\nd\n") == []


def test_blueprint_empty_section_and_prop_warnings():
    f = validate_blueprint("#dig\n,,\n,,\n#build\nb\n")
    assert [x.code for x in f] == ["W_EMPTY_SECTION"]
    f = validate_blueprint("#place\nf{wheelbarrows}(2x2)\n")
    assert [x.code for x in f] == ["W_PROP"]
    assert validate_blueprint('#place\nf{name="a b" wheelbarrows=0}\n') == []
    assert validate_blueprint('#place\nf{name="Food, Core" wheelbarrows=0}\n') == []     # comma in quotation marks


def test_blueprint_passive_sections_ignored():
    text = "#notes irgendwas\nBeliebig (( ,{ \n#meta label(x)\n  \n#query\n{Right}\n#dig\nd\n"
    assert validate_blueprint(text) == []
    assert "E_NOSECTION" not in codes("#ignore\nCw\n")
    # "#>" in passive sections is not reported as a missing section
    assert validate_blueprint("#notes x\n#>\n#dig\nd\n") == []


def test_blueprint_z_markers_with_numbers():
    assert validate_blueprint("#dig\nj\n#> 2\nu\n#< 1\nd\n") == []


def test_blueprint_findings_sorted_and_formatted():
    f = validate_blueprint("#build\nb,t$\nCw(\n#bild\n")
    assert [(x.line, x.col) for x in f] == sorted((x.line, x.col) for x in f)
    assert isinstance(f[0], Finding) and str(f[0]).startswith(f"{f[0].line}:{f[0].col} ")
    assert all(x.level in ("error", "warning") for x in f)
    assert set(blueprint.CODES) >= {x.code for x in f}


def test_blueprint_leading_blank_rows_shift_y_not_columns():
    # blank lines in the grid shift y (here: workshop in line 2 -> footprint y1..3) -> no conflict with y=0
    assert validate_blueprint("#build\nCw,\n\n,wm\n") == []
    assert "E_OVERLAP" in codes("#build\nCw(3x3),\n\n,wm\n")


def test_blueprint_large_file_performance():
    cells = [",".join("b" if (x % 2 == 0 and y % 2 == 0) else "" for x in range(100)) for y in range(100)]
    text = "#build\n" + "\n".join(cells) + "\n"
    assert validate_blueprint(text, map_size=(192, 192)) == []
