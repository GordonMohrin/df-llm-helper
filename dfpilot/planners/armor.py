"""Armor requirement calculator (SPEC F11.3): soldier quota, bar demand, missing pieces -> forge orders.

All numbers are configurable tables. Whatever is marked "assumption, verify live" does NOT come from measured
game data (compare with the forge recipes in the game before use).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Mapping, Optional, Sequence, Union

__all__ = ["SLOTS", "BARS_PER_PIECE", "QUOTA_TIERS", "Soldier", "ForgeOrder", "ArmorPlan", "soldier_quota", "plan_armor",
           "SLOT_ALIASES"]

# order of the forge orders (weapon, breastplate, helm, shield, greaves, boots, gauntlets)
SLOTS: tuple[str, ...] = ("weapon", "breastplate", "helm", "shield", "greaves", "boots", "gauntlets")
# German slot names (as used by the companion scripts) are accepted as aliases
SLOT_ALIASES = {"waffe": "weapon", "brust": "breastplate", "helm": "helm", "schild": "shield",
                "beine": "greaves", "stiefel": "boots", "handschuhe": "gauntlets"}

# assumption, verify live: bars per piece (check the forge recipe in the game)
BARS_PER_PIECE: dict[str, int] = {"weapon": 3, "breastplate": 3, "helm": 1, "shield": 2,
                                  "greaves": 2, "boots": 1, "gauntlets": 1}

# assumption (project rule): pop < 15: 0 soldiers, from 15: 2, from 40: 4, from 60: 6, above that 10 % of the population
QUOTA_TIERS: tuple[tuple[int, int], ...] = ((15, 2), (40, 4), (60, 6))
QUOTA_PERCENT = 10

# metal order when choosing bars (assumption, verify live; further metals alphabetically afterwards)
METAL_ORDER: tuple[str, ...] = ("steel", "iron", "bronze", "copper")


@dataclass
class Soldier:
    id: Union[int, str]
    name: str = ""
    equipped: Iterable[str] = ()   # slots already worn (English or German)


@dataclass(frozen=True)
class ForgeOrder:
    slot: str
    qty: int
    bars_each: int
    metal: str
    bars_total: int


@dataclass
class ArmorPlan:
    quota: int                                   # target number of soldiers
    soldiers_now: int
    recruits_needed: int                         # soldiers missing up to the quota
    orders: list[ForgeOrder] = field(default_factory=list)       # affordable forge orders in slot order
    deferred: list[ForgeOrder] = field(default_factory=list)     # bars missing (metal == "")
    from_stock: list[tuple[Union[int, str], str]] = field(default_factory=list)   # (soldier, slot) to assign from stock
    bars_needed: int = 0                         # bars for all forged pieces (affordable + deferred)
    bars_available: int = 0
    bars_missing: int = 0
    notes: list[str] = field(default_factory=list)


def soldier_quota(pop: int, tiers: Sequence[tuple[int, int]] = QUOTA_TIERS, percent: int = QUOTA_PERCENT) -> int:
    """Target number of soldiers. 0 below the first tier; above the last tier at least its value, otherwise percent % (rounded up)."""
    if pop < 0:
        raise ValueError("pop must not be negative")
    ordered = sorted(tiers)
    value = 0
    for threshold, n in ordered:
        if pop >= threshold:
            value = n
    if ordered and pop > ordered[-1][0]:
        value = max(value, -(-pop * percent // 100))
    elif not ordered:
        value = -(-pop * percent // 100)
    return value


def _slot(name: str, notes: list[str]) -> Optional[str]:
    n = str(name).strip().lower()
    n = SLOT_ALIASES.get(n, n)
    if n in SLOTS:
        return n
    notes.append(f"unknown slot {name!r} ignored")
    return None


def _as_soldier(s) -> Soldier:
    if isinstance(s, Soldier):
        return s
    if isinstance(s, Mapping):
        return Soldier(s.get("id", ""), s.get("name", ""), s.get("equipped", ()))
    return Soldier(s)


def plan_armor(pop: int, soldiers: Sequence, stock: Mapping[str, int], bars: Mapping[str, int], *,
               tiers: Sequence[tuple[int, int]] = QUOTA_TIERS, percent: int = QUOTA_PERCENT,
               bars_per_piece: Mapping[str, int] = BARS_PER_PIECE, metal_order: Sequence[str] = METAL_ORDER) -> ArmorPlan:
    """Compute the demand. ``soldiers``: Soldier/dict with ``equipped``; ``stock``: free finished pieces per slot;
    ``bars``: bars per metal. Missing pieces come from stock first, the rest as a forge order."""
    notes: list[str] = []
    quota = soldier_quota(pop, tiers, percent)
    people = [_as_soldier(s) for s in soldiers]
    recruits = max(0, quota - len(people))
    if len(people) > quota:
        notes.append(f"{len(people)} soldiers > quota {quota}")

    avail: dict[str, int] = {}
    for k, v in stock.items():
        slot = _slot(k, notes)
        if slot is not None:
            if v < 0:
                raise ValueError(f"stock[{k}] negative")
            avail[slot] = avail.get(slot, 0) + v
    for k, v in bars.items():
        if v < 0:
            raise ValueError(f"bars[{k}] negative")

    ids_seen: set = set()
    needs: list[tuple[Union[int, str], list[str]]] = []
    for p in people:
        if p.id in ids_seen:
            notes.append(f"duplicate soldier ID {p.id!r}")
        ids_seen.add(p.id)
        have = {s for s in (_slot(e, notes) for e in p.equipped) if s}
        needs.append((p.id, [s for s in SLOTS if s not in have]))
    for i in range(recruits):
        needs.append((f"recruit#{i + 1}", list(SLOTS)))

    forge: dict[str, int] = {s: 0 for s in SLOTS}
    from_stock: list[tuple[Union[int, str], str]] = []
    for sid, missing in needs:
        for slot in missing:
            if avail.get(slot, 0) > 0:
                avail[slot] -= 1
                from_stock.append((sid, slot))
            else:
                forge[slot] += 1

    # bars: available per metal; an order uses the first metal in metal_order that suffices for at least one piece
    pool = {m: int(n) for m, n in bars.items()}
    ordered_metals = [m for m in metal_order if m in pool] + sorted(m for m in pool if m not in metal_order)
    orders: list[ForgeOrder] = []
    deferred: list[ForgeOrder] = []
    needed_total = 0
    for slot in SLOTS:
        qty = forge[slot]
        if qty == 0:
            continue
        cost = bars_per_piece[slot]
        needed_total += qty * cost
        left = qty
        for m in ordered_metals:
            if left == 0:
                break
            can = pool[m] // cost if cost > 0 else left
            take = min(left, can)
            if take > 0:
                orders.append(ForgeOrder(slot, take, cost, m, take * cost))
                pool[m] -= take * cost
                left -= take
        if left:
            deferred.append(ForgeOrder(slot, left, cost, "", left * cost))
    available_total = sum(int(n) for n in bars.values())
    missing_bars = max(0, needed_total - available_total)
    if deferred:
        notes.append(f"{sum(o.qty for o in deferred)} pieces deferred (bars missing: {missing_bars})")
        if missing_bars == 0:
            notes.append("bars spread over several metals: no single metal suffices for a whole piece")
    if recruits:
        notes.append(f"{recruits} soldiers missing up to the quota {quota} (their equipment is included)")
    return ArmorPlan(quota=quota, soldiers_now=len(people), recruits_needed=recruits, orders=orders, deferred=deferred,
                     from_stock=from_stock, bars_needed=needed_total, bars_available=available_total,
                     bars_missing=missing_bars, notes=notes)
