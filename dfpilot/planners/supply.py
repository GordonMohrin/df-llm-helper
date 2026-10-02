"""Supply forecast (SPEC F11.4): days until shortage for drinks/food etc., pure function.

Day-by-day simulation: stock(d) = stock(d-1) + production - consumption per head * population(d).
population(d) = pop + growth (steady per day or as waves (day, count)).
Assumption (from ``lua/claude/status.lua``): food 2 and drinks 5 per dwarf per season (84 days); verify live.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping, Optional, Sequence, Union

__all__ = ["DEFAULT_CONSUMPTION", "Forecast", "forecast"]

SEASON_DAYS = 84
# assumption (status.lua), verify live: consumption per dwarf per day
DEFAULT_CONSUMPTION: dict[str, float] = {"food": 2 / SEASON_DAYS, "drink": 5 / SEASON_DAYS}

Growth = Union[None, int, float, Sequence[tuple[int, float]]]


@dataclass
class Forecast:
    days_left: dict[str, Optional[float]]            # per resource: days until stock 0; None = no shortage within the horizon
    curve: dict[str, list[float]]                    # stock at the end of days 0..horizon (never below 0)
    warn: list[str] = field(default_factory=list)
    pop_curve: list[float] = field(default_factory=list)

    @property
    def soonest(self) -> Optional[float]:
        vals = [v for v in self.days_left.values() if v is not None]
        return min(vals) if vals else None


def _pop_on_day(pop: float, growth: Growth, day: int) -> float:
    if growth is None:
        return pop
    if isinstance(growth, (int, float)):
        return pop + growth * day
    return pop + sum(n for d, n in growth if d <= day)


def forecast(stock: Mapping[str, float], pop: float, consumption: Optional[Mapping[str, float]] = None,
             production: Optional[Mapping[str, float]] = None, growth: Growth = None, horizon_days: int = 336,
             warn_days: float = 20) -> Forecast:
    """Forecast per resource. ``consumption``: per head and day (default ``DEFAULT_CONSUMPTION``), ``production``: per day,
    ``growth``: number = immigrants per day, list = waves (day, count). ``horizon_days`` defaults to 336 (one game year)."""
    if horizon_days < 0:
        raise ValueError("horizon_days must not be negative")
    if pop < 0:
        raise ValueError("pop must not be negative")
    cons = DEFAULT_CONSUMPTION if consumption is None else consumption
    prod = production or {}
    for name, val in list(stock.items()) + list(cons.items()) + list(prod.items()):
        if val < 0:
            raise ValueError(f"negative value for {name}")
    pops = [max(0.0, _pop_on_day(pop, growth, d)) for d in range(horizon_days + 1)]
    days_left: dict[str, Optional[float]] = {}
    curve: dict[str, list[float]] = {}
    warn: list[str] = []
    for res in sorted(stock):
        level = float(stock[res])
        per_head = cons.get(res, 0.0)
        make = prod.get(res, 0.0)
        pts = [level]
        left: Optional[float] = None
        for d in range(1, horizon_days + 1):
            net = make - per_head * pops[d]
            if left is None and net < 0 and level + net <= 0:
                left = (d - 1) + level / -net
            level = max(0.0, level + net)
            pts.append(level)
        days_left[res] = None if left is None else round(left, 2)
        curve[res] = pts
        if left is not None and left < warn_days:
            warn.append(f"{res}: shortage in {left:.1f} days (warning threshold {warn_days:g})")
    unknown = sorted(set(cons) - set(stock)) if consumption is not None else []
    if unknown:
        warn.append("without a stock figure: " + ", ".join(unknown))
    return Forecast(days_left=days_left, curve=curve, warn=warn, pop_curve=pops)
