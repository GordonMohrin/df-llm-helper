"""The aquifer pass (FR-95; Runs 2, 4, 6, 9 and 14: every fort that met an aquifer parked at breach:damp or flooded).

`aqshaft` = a lined 1-tile stair shaft through an aquifer, one stage per level (`l<i>.dig`: a down stair `j` at the top,
up/down stairs `i` below). The runner (lua/dfllm/aqshaft.lua) works it one level at a time: DIG (the DFHack dig tool's
damp marker on, so DF's "damp stone located" no longer cancels it) -> SEAL (stone: the 4 orthogonal walls smoothed at
priority 1, a smoothed wall is no aquifer source any more; soil: a plus shape dug and constructed walls on its 4 arms) ->
WATCH (the centre tile's flow for a game day); the next level only once the seal stands and the flow is <= 1/7. A level
with no damp report, no revealed aquifer wall and no water is dry and needs no seal. The shaft is passed after
`dry_levels` dry levels below the last aquifer level, or at `depth`. Water >= 4/7 or a rising flow in its own tiles is a
heavy aquifer: stopped for good (breach:heavy_aquifer) and plugged (CAVERN_PLUG).

Params: x, y, top = the shaft column (absolute; -1: the site anchor), dry_levels, depth (levels at most), mode = auto (seal
per wall: stone smoothed, soil walled) | stone | soil (every wall that way) | all (seal every level, damp or not).
Fair play: nothing here reads the map; the player (or the orchestrator) names the column, a revealed tile the miners
reach, or `bp sites aqshaft` ranks the columns on the revealed snapshot (BUG-292: public Z4 floor, rock with rock on its
4 sides below). The kernel reads the aquifer flag of revealed tiles only (DECISIONS 2026-10-28).
"""
from __future__ import annotations

from .primitives import Plan

MODES = ("auto", "stone", "soil", "all")
PARAMS = {"aqshaft": {"x": (-1, -1, 9999), "y": (-1, -1, 9999), "top": (-1, -1, 9999), "dry_levels": (2, 1, 6),
                      "depth": (20, 2, 60), "mode": ("auto", None, None)}}


def column(p: dict) -> list[int] | None:
    """The shaft column [x, y, top] from the params, None when they leave it to the site anchor; ValueError when only
    some of them are given."""
    xyz = [p["x"], p["y"], p["top"]]
    if all(v < 0 for v in xyz):
        return None
    if any(v < 0 for v in xyz):
        raise ValueError(f"aqshaft: give x, y and top together (got {xyz}) or none of them (the site anchor)")
    return xyz


def aqshaft(p: dict) -> Plan:
    """Aquifer pass: a lined stair shaft, one level per stage, each sealed and watched before the next (FR-95)."""
    if p["mode"] not in MODES:
        raise ValueError(f"aqshaft.mode: {p['mode']!r} is not one of {', '.join(MODES)}")
    column(p)
    P = Plan("aqshaft", "infra")
    for i in range(p["depth"]):
        P.stage(f"l{i}.dig", "dig").tile(0, 0, -i, "j" if i == 0 else "i")
    return P


aqshaft.anchor_of_params = column       # bp.emit: p.x/p.y/p.top name the column instead of the site anchor
BUILD = {"aqshaft": aqshaft}
