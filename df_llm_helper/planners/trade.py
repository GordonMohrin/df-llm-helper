"""Trade planner (SPEC F11.1): pure functions, no DF calls.

Model
- ``own``: own sale candidates (quantity ``qty`` per entry, ``value`` = sale value per piece).
- ``offer``: the merchant's offer (``value`` = purchase value per piece, ``weight`` per piece).
- Constraint: sum of sale value >= ``ratio`` * sum of purchase value (default 2.3; computed exactly with Fraction).
- ``reserves``: minimum stock per item ID or category (value = pieces that must remain);
  a list/set of keys means "never sell".
- ``priorities``: purchasable categories (``TradeItem.priority_category`` or ``category``) in priority order;
  categories not listed are never bought. Weight per category = 2 * (n - index) (integer).
- ``max_weight``: weight limit for the purchased goods ("Excess Weight").

Objective (lexicographic): 1. maximum weighted purchase value (sum of priority weight * value * quantity),
2. minimum purchase value, 3. minimum sale value (sell only as much as necessary).
Two-stage exact: stage 1 chooses the purchase (branch-and-bound, cost cap = maximum sellable value / ratio),
stage 2 chooses the cheapest sale that covers the purchase (monotone in purchase value, hence jointly optimal).
With many items (> ``exact_limit``) or an exhausted node limit the greedy heuristic is used (see notes).
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Iterable, Mapping, Optional, Sequence

__all__ = ["TradeItem", "TradeLine", "TradePlan", "plan_trade", "DEFAULT_RATIO", "DEFAULT_PRIORITIES",
           "priority_weights"]

DEFAULT_RATIO = 2.3
DEFAULT_PRIORITIES: tuple[str, ...] = ("food", "wood", "metal", "cloth", "other")
EXACT_MAX_ITEMS = 24      # exact up to here (branch-and-bound), greedy above
MAX_RECURSION_ITEMS = 500  # limit the recursion depth of the exact search
NODE_LIMIT = 200_000      # search nodes per stage; afterwards the best result so far
NEVER = 10 ** 9           # reserve "never sell"
_EPS = 1e-9


@dataclass(frozen=True)
class TradeItem:
    """A trade item. ``value`` integer per piece; ``priority_category`` overrides ``category`` for the priority list."""
    id: str
    name: str
    category: str
    value: int
    weight: float
    qty: int = 1
    priority_category: Optional[str] = None

    @property
    def prio_cat(self) -> str:
        return self.priority_category or self.category


@dataclass(frozen=True)
class TradeLine:
    id: str
    name: str
    category: str
    qty: int
    value: int      # per piece
    weight: float   # per piece

    @property
    def total_value(self) -> int:
        return self.qty * self.value

    @property
    def total_weight(self) -> float:
        return self.qty * self.weight


@dataclass
class TradePlan:
    buy: list[TradeLine]
    sell: list[TradeLine]
    buy_value: int
    sell_value: int
    ratio: Optional[float]      # achieved ratio sale/purchase (None without a purchase)
    weight: float               # total weight of the purchases
    notes: list[str] = field(default_factory=list)
    benefit: int = 0            # weighted purchase value (objective)
    method: str = ""            # "exact" | "greedy" | "exact-truncated"


def priority_weights(priorities: Sequence[str]) -> dict[str, int]:
    """Priority weight per category: first = 2*n, last = 2 (integer so that it is exactly comparable)."""
    out: dict[str, int] = {}
    n = len(priorities)
    for i, cat in enumerate(priorities):
        out.setdefault(cat, 2 * (n - i))
    return out


def _as_int(v, what: str) -> int:
    if isinstance(v, bool):
        raise ValueError(f"{what}: bool instead of a number")
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    raise ValueError(f"{what}: integer expected, got {v!r}")


def _check_items(items: Iterable[TradeItem], label: str) -> list[TradeItem]:
    out: list[TradeItem] = []
    seen: set[str] = set()
    for it in items:
        if it.id in seen:
            raise ValueError(f"{label}: duplicate ID {it.id!r}")
        seen.add(it.id)
        v = _as_int(it.value, f"{label} {it.id} value")
        q = _as_int(it.qty, f"{label} {it.id} qty")
        if v < 0 or q < 0 or it.weight < 0:
            raise ValueError(f"{label} {it.id}: negative values are not allowed")
        out.append(it if (v == it.value and q == it.qty) else
                   TradeItem(it.id, it.name, it.category, v, it.weight, q, it.priority_category))
    return out


def _norm_reserves(reserves) -> dict[str, int]:
    if not reserves:
        return {}
    if isinstance(reserves, Mapping):
        out = {}
        for k, v in reserves.items():
            n = _as_int(v, f"reserve {k}")
            if n < 0:
                raise ValueError(f"reserve {k}: negative minimum stock")
            out[str(k)] = n
        return out
    return {str(k): NEVER for k in reserves}


# ---------------------------------------------------------------- sell side

@dataclass
class _Sell:
    item: TradeItem
    groups: list[str]       # reserve keys that affect this item
    cap: int = 0            # individually sellable quantity (minimum of qty and group caps)


def _sell_structures(own: list[TradeItem], reserves: dict[str, int], notes: list[str]):
    """Sorted sale list (value descending), group caps, maximum sellable value (laminar greedy is exact)."""
    group_cap: dict[str, int] = {}
    for key, minimum in reserves.items():
        members = [it for it in own if it.id == key or it.category == key]
        if not members:
            notes.append(f"reserve {key!r} matches no sale item")
            continue
        group_cap[key] = max(0, sum(it.qty for it in members) - minimum)
    sells = []
    for it in sorted(own, key=lambda i: (-i.value, i.id)):
        groups = [k for k in group_cap if it.id == k or it.category == k]
        s = _Sell(it, groups)
        s.cap = min([it.qty] + [group_cap[k] for k in groups])
        sells.append(s)
    # maximum sellable value: take pieces by descending value as long as all groups allow it
    rem = dict(group_cap)
    max_counts: list[int] = []
    s_max = 0
    for s in sells:
        m = min([s.item.qty] + [rem[k] for k in s.groups])
        for k in s.groups:
            rem[k] -= m
        max_counts.append(m)
        s_max += m * s.item.value
    return sells, group_cap, max_counts, s_max


def _cover_greedy(sells: list[_Sell], max_counts: list[int], need: int) -> list[int]:
    """Greedy cover within the allowed amount ``max_counts``: large items that do not overshoot, then the smallest covering item."""
    counts = [0] * len(sells)
    remaining = need
    for i, s in enumerate(sells):           # value descending
        if remaining <= 0:
            break
        v = s.item.value
        if v <= 0:
            continue
        k = min(max_counts[i], remaining // v)
        counts[i] += k
        remaining -= k * v
    while remaining > 0:
        # smallest single item that covers the remainder; otherwise the largest remaining one (smaller than the remainder)
        cover = None
        biggest = None
        for i, s in enumerate(sells):
            if counts[i] >= max_counts[i] or s.item.value <= 0:
                continue
            v = s.item.value
            if v >= remaining and (cover is None or v < sells[cover].item.value):
                cover = i
            if biggest is None or v > sells[biggest].item.value:
                biggest = i
        pick = cover if cover is not None else biggest
        if pick is None:
            break  # pragma: no cover - an uncoverable remainder cannot occur with a correct upper bound
        counts[pick] += 1
        remaining -= sells[pick].item.value
    return counts


def _cover_exact(sells: list[_Sell], group_cap: dict[str, int], need: int, incumbent: list[int],
                 node_limit: int) -> tuple[list[int], bool]:
    """Cheapest sale amount with sum >= need (branch-and-bound, group caps). Returns (amounts, proven?)."""
    n = len(sells)
    suffix = [0] * (n + 1)
    for p in range(n - 1, -1, -1):
        suffix[p] = suffix[p + 1] + sells[p].cap * sells[p].item.value
    best = [sum(c * s.item.value for c, s in zip(incumbent, sells))]
    best_counts = list(incumbent)
    counts = [0] * n
    state = {"nodes": 0, "truncated": False}

    def dfs(p: int, cur: int, rem: dict[str, int]) -> None:
        state["nodes"] += 1
        if state["nodes"] > node_limit:
            state["truncated"] = True
            return
        if cur >= need:
            if cur < best[0]:
                best[0] = cur
                best_counts[:] = counts
            return
        if p == n or cur + suffix[p] < need or max(cur, need) >= best[0]:
            return
        s = sells[p]
        kmax = min([s.item.qty] + [rem[k] for k in s.groups])
        for k in range(kmax, -1, -1):
            cur2 = cur + k * s.item.value
            if cur2 >= best[0]:
                continue
            counts[p] = k
            if k:
                rem2 = dict(rem)
                for g in s.groups:
                    rem2[g] -= k
            else:
                rem2 = rem
            dfs(p + 1, cur2, rem2)
            if best[0] == need or state["truncated"]:
                break
        counts[p] = 0

    dfs(0, 0, dict(group_cap))
    return best_counts, not state["truncated"]


# ---------------------------------------------------------------- buy side

@dataclass
class _Buy:
    item: TradeItem
    pw: int   # priority weight

    @property
    def v(self) -> int:
        return self.item.value

    @property
    def w(self) -> float:
        return self.item.weight

    @property
    def q(self) -> int:
        return self.item.qty


def _kmax(b: _Buy, cost_left: Optional[int], w_left: Optional[float]) -> int:
    k = b.q
    if cost_left is not None:
        k = min(k, cost_left // b.v)
    if w_left is not None and b.w > 0:
        k = min(k, int((w_left + _EPS) // b.w))
    return max(0, k)


def _greedy_buy(order: list[_Buy], cost_cap: Optional[int], weight_cap: Optional[float]) -> list[int]:
    counts = []
    cost_left, w_left = cost_cap, weight_cap
    for b in order:
        k = _kmax(b, cost_left, w_left)
        counts.append(k)
        if cost_left is not None:
            cost_left -= k * b.v
        if w_left is not None:
            w_left -= k * b.w
    return counts


def _bound(order: list[_Buy], order_w: list[int], p: int, cost_left: Optional[int], w_left: Optional[float]):
    """Upper bound of the benefit still attainable (fractional relaxation per constraint, minimum)."""
    n = len(order)
    ub_c = None
    if cost_left is not None:
        rem = cost_left
        ub_c = 0
        for j in range(p, n):
            b = order[j]
            take = min(b.q * b.v, rem)
            ub_c += b.pw * take
            rem -= take
            if rem <= 0:
                break
    ub_w = None
    if w_left is not None:
        rem_w = w_left + _EPS
        ub_w = 0.0
        for j in order_w:
            if j < p:
                continue
            b = order[j]
            full = b.q * b.w
            if b.w == 0 or full <= rem_w:
                ub_w += b.pw * b.q * b.v
                rem_w -= full
            else:
                ub_w += b.pw * b.v * (rem_w / b.w)
                break
        ub_w += 1e-6
    if ub_c is None:   # (both None does not occur: without a constraint there is no search)
        return ub_w
    if ub_w is None:
        return ub_c
    return min(ub_c, ub_w)


def _bnb_buy(order: list[_Buy], cost_cap: Optional[int], weight_cap: Optional[float],
             incumbent: list[int], node_limit: int) -> tuple[list[int], bool]:
    n = len(order)
    order_w = sorted(range(n), key=lambda j: (-(math.inf if order[j].w == 0 else order[j].pw * order[j].v / order[j].w), j))
    best_counts = list(incumbent)
    best_key = [(sum(c * b.pw * b.v for c, b in zip(incumbent, order)),
                 -sum(c * b.v for c, b in zip(incumbent, order)))]
    counts = [0] * n
    state = {"nodes": 0, "truncated": False}

    def dfs(p: int, cost_left, w_left, benefit: int, cost_used: int) -> None:
        state["nodes"] += 1
        if state["nodes"] > node_limit:
            state["truncated"] = True
            return
        key = (benefit, -cost_used)
        if key > best_key[0]:
            best_key[0] = key
            best_counts[:] = counts
        if p == n:
            return
        ub = _bound(order, order_w, p, cost_left, w_left)
        if (benefit + ub, -cost_used) <= best_key[0]:
            return
        b = order[p]
        for k in range(_kmax(b, cost_left, w_left), -1, -1):
            counts[p] = k
            dfs(p + 1,
                None if cost_left is None else cost_left - k * b.v,
                None if w_left is None else w_left - k * b.w,
                benefit + k * b.pw * b.v, cost_used + k * b.v)
            if state["truncated"]:
                break
        counts[p] = 0

    dfs(0, cost_cap, weight_cap, 0, 0)
    return best_counts, not state["truncated"]


# ---------------------------------------------------------------- public function

def plan_trade(own: Sequence[TradeItem], offer: Sequence[TradeItem], ratio: float = DEFAULT_RATIO,
               reserves=None, priorities: Sequence[str] = DEFAULT_PRIORITIES, max_weight: Optional[float] = None,
               *, method: str = "auto", exact_limit: int = EXACT_MAX_ITEMS, node_limit: int = NODE_LIMIT) -> TradePlan:
    """Optimal purchase/sale selection (see the module docs). ``method``: "auto" | "exact" | "greedy"."""
    if method not in ("auto", "exact", "greedy"):
        raise ValueError(f"unknown method {method!r}")
    if ratio < 0:
        raise ValueError("ratio must not be negative")
    if max_weight is not None and max_weight < 0:
        raise ValueError("max_weight must not be negative")
    notes: list[str] = []
    own_l = _check_items(own, "own")
    offer_l = _check_items(offer, "offer")
    rat = Fraction(str(ratio))
    num, den = rat.numerator, rat.denominator
    res = _norm_reserves(reserves)

    # sell side: how much value can be sold at most?
    sells, group_cap, max_counts, s_max = _sell_structures(own_l, res, notes)
    cost_cap: Optional[int] = None if num == 0 else (s_max * den) // num

    # buy side: only purchasable, valuable, non-empty items in listed categories
    pw = priority_weights(priorities)
    skipped_cat = skipped_zero = 0
    buys: list[_Buy] = []
    for it in offer_l:
        if it.qty == 0:
            continue
        if it.prio_cat not in pw:
            skipped_cat += 1
            continue
        if it.value == 0:
            skipped_zero += 1
            continue
        buys.append(_Buy(it, pw[it.prio_cat]))
    if skipped_cat:
        notes.append(f"{skipped_cat} offer items in unlisted categories are not bought")
    if skipped_zero:
        notes.append(f"{skipped_zero} offer items with value 0 skipped")
    order = sorted(buys, key=lambda b: (-b.pw, -b.v, b.item.id))

    counts = [0] * len(order)
    truncated = heuristic = False
    if not order:
        notes.append("nothing to buy")
    elif cost_cap is not None and cost_cap <= 0:
        notes.append("no sellable value for the price ratio: nothing to buy")
    else:
        counts = _greedy_buy(order, cost_cap, max_weight)
        unconstrained = cost_cap is None and max_weight is None
        want_exact = method == "exact" or (method == "auto" and len(order) <= exact_limit)
        if want_exact and len(order) > MAX_RECURSION_ITEMS:
            want_exact = False
            notes.append(f"too many items for the exact search (> {MAX_RECURSION_ITEMS}), greedy used")
        if unconstrained:
            pass   # buying everything is optimal
        elif want_exact:
            counts, proven = _bnb_buy(order, cost_cap, max_weight, counts, node_limit)
            if not proven:
                truncated = True
                notes.append("node limit reached: purchase not proven optimal")
        else:
            heuristic = True
            notes.append(f"greedy heuristic ({len(order)} items): result not guaranteed optimal")

    buy_lines: list[TradeLine] = []
    buy_value = 0
    weight = 0.0
    benefit = 0
    for c, b in zip(counts, order):
        if c <= 0:
            continue
        it = b.item
        buy_lines.append(TradeLine(it.id, it.name, it.category, c, it.value, it.weight))
        buy_value += c * it.value
        weight += c * it.weight
        benefit += c * b.pw * it.value

    # note on what limited the purchase
    left = [(c, b) for c, b in zip(counts, order) if c < b.q]
    if left:
        cost_bound = any(cost_cap is not None and b.v > cost_cap - buy_value for _, b in left)
        weight_bound = any(max_weight is not None and b.w > 0 and b.w > max_weight - weight + _EPS for _, b in left)
        if cost_bound:
            notes.append("purchase limited by the sale volume (price ratio/reserves)")
        if weight_bound:
            notes.append("purchase limited by the weight limit")

    # stage 2: cheapest sale that covers the purchase
    need = -((-num * buy_value) // den) if buy_value else 0
    sell_counts = [0] * len(sells)
    if need > 0:
        sell_counts = _cover_greedy(sells, max_counts, need)
        n_sellable = sum(1 for s in sells if s.cap > 0)
        want_exact = method == "exact" or (method == "auto" and n_sellable <= exact_limit)
        if want_exact and n_sellable > MAX_RECURSION_ITEMS:
            want_exact = False
        if want_exact:
            sell_counts, proven = _cover_exact(sells, group_cap, need, sell_counts, node_limit)
            if not proven:
                truncated = True
                notes.append("node limit reached: sale not proven minimal")
        else:
            heuristic = True
            notes.append(f"sale via greedy ({n_sellable} items): possibly slightly above the minimum")
    used = "greedy" if heuristic else ("exact-truncated" if truncated else "exact")
    sell_lines: list[TradeLine] = []
    sell_value = 0
    for c, s in zip(sell_counts, sells):
        if c > 0:
            it = s.item
            sell_lines.append(TradeLine(it.id, it.name, it.category, c, it.value, it.weight))
            sell_value += c * it.value
    if not buy_lines:
        notes.append("no purchase planned, nothing is sold")
    elif sell_value * den < num * buy_value:  # pragma: no cover - self-check, must never happen
        raise AssertionError("price ratio violated")

    ratio_out = (sell_value / buy_value) if buy_value else None
    return TradePlan(buy=buy_lines, sell=sell_lines, buy_value=buy_value, sell_value=sell_value, ratio=ratio_out,
                     weight=weight, notes=notes, benefit=benefit, method=used)
