"""Hospital supply planner (FEATURE-004): splints, crutches and plaster powder - pure function, no DF call.

Plaster casts need plaster powder (kiln reaction MAKE_PLASTER_POWDER), and that needs gypsum-class stone: gypsum,
alabaster, selenite or satinspar. Run 5's rock had none of them, so the planner checks the raw material (stone types in
stock / on visible tiles, from `claude/pilot_hospital status` field `gypsum` or `claude/material`) BEFORE it proposes a
plaster order; without it there is no such order and the reason names the alternatives (wooden splints, trade).
The result is a list of proposals for the existing orders flow (`claude/orders` / the manager); nothing is sent.
Cloth and thread are not ordered here (farm/loom chain): a shortage is a note.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping, Union

__all__ = ["GYPSUM_STONES", "DEFAULT_TARGETS", "MedicalOrder", "MedicalPlan", "gypsum_count", "plan_medical",
           "PLASTER_IMPOSSIBLE"]

GYPSUM_STONES = ("GYPSUM", "ALABASTER", "SELENITE", "SATINSPAR")
PLASTER_IMPOSSIBLE = ("plaster powder impossible: no gypsum/alabaster/selenite/satin spar in stock or on the map "
                      "(alternatives: splints from wood, trade)")
# stock targets (assumption, adjust per fort): enough for a few patients at once
DEFAULT_TARGETS = {"splint": 4, "crutch": 2, "plaster": 4, "cloth": 10, "thread": 10, "soap": 2}
WOOD_PER_ITEM = 1


@dataclass(frozen=True)
class MedicalOrder:
    key: str
    job: str            # job / reaction for the order (workorder name)
    workshop: str
    qty: int
    material: str
    reason: str


@dataclass
class MedicalPlan:
    orders: list[MedicalOrder] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    plaster_possible: bool = False

    def lines(self) -> list[str]:
        out = [f"order {o.qty}x {o.job} ({o.workshop}, {o.material}): {o.reason}" for o in self.orders]
        return out + self.notes


def gypsum_count(gypsum: Union[None, int, Mapping]) -> int:
    """Number of gypsum-class boulders: int, {'total': n}, {'by_mat': {...}} or a plain {STONE: n} map
    (claude/material stone list); only the four plaster stones count in a plain map."""
    if gypsum is None:
        return 0
    if isinstance(gypsum, (int, float)):
        return max(0, int(gypsum))
    if "total" in gypsum:
        return max(0, int(gypsum.get("total") or 0))
    src = gypsum.get("by_mat") if isinstance(gypsum.get("by_mat"), Mapping) else gypsum
    return sum(max(0, int(v or 0)) for k, v in src.items() if str(k).upper().replace(" ", "") in GYPSUM_STONES)


def plan_medical(stock: Mapping[str, int], gypsum: Union[None, int, Mapping] = None, *, patients: int = 0,
                 targets: Mapping[str, int] | None = None) -> MedicalPlan:
    """stock: available counts {'splint', 'crutch', 'plaster', 'cloth', 'thread', 'soap', 'wood'}; gypsum: see
    gypsum_count. Returns proposals; a plaster order only when gypsum-class stone exists."""
    t = {**DEFAULT_TARGETS, **(targets or {})}
    st = {k: max(0, int(v or 0)) for k, v in stock.items() if isinstance(v, (int, float))}
    plan = MedicalPlan()
    wood = st.get("wood", 0)
    for key, job, many in (("splint", "ConstructSplint", "splints"), ("crutch", "ConstructCrutch", "crutches")):
        need = t[key] - st.get(key, 0)
        if need <= 0:
            continue
        if wood >= need * WOOD_PER_ITEM:
            plan.orders.append(MedicalOrder(key, job, "Carpenter", need, "wood", f"{many} {st.get(key, 0)} < {t[key]}"))
            wood -= need * WOOD_PER_ITEM
        else:
            plan.notes.append(f"{many} {st.get(key, 0)} < {t[key]} but no wood: buy {many} or wood from a caravan")
    need = t["plaster"] - st.get("plaster", 0)
    g = gypsum_count(gypsum)
    plan.plaster_possible = g > 0
    if need > 0:
        if g > 0:
            n = min(need, g)
            plan.orders.append(MedicalOrder("plaster", "MAKE_PLASTER_POWDER", "Kiln", n, "gypsum-class stone",
                                            f"plaster powder {st.get('plaster', 0)} < {t['plaster']} "
                                            f"({g} gypsum-class boulders, a bag is needed too)"))
        else:
            plan.notes.append(PLASTER_IMPOSSIBLE)
    for key in ("cloth", "thread"):
        if st.get(key, 0) < t[key] and (patients > 0 or st.get(key, 0) == 0):
            plan.notes.append(f"{key} {st.get(key, 0)} < {t[key]} (dressing/suturing): loom/farm chain or trade")
    if st.get("soap", 0) < t["soap"] and patients > 0:
        plan.notes.append(f"soap {st.get('soap', 0)} < {t['soap']}: soapmaker (lye + tallow) or trade")
    return plan
