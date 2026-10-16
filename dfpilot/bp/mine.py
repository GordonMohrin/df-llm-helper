"""Ore search (Run 10, Handlelock: iron stuck at 8 bars for years, three caravans a year never brought any, the soldiers
wore 38-53 %): `explore` = a 1-wide stair shaft `depth` levels down from a public core floor, with short side tunnels
every `every` levels and at the bottom, so the miners reveal the stone (and its ore veins) below the fort.

Local frame (rot 0, as the room templates): the anchor (0,0,0) is an existing walkable core floor; (0,1,0) is the shaft
top, a down stair dug into the rock beside it; the shaft runs down at (0,1,w) to the up stair at w = -depth. A tunnel
level w has arms of `arm` tiles west (-u), east (+u) and south (+v) of the shaft tile.
Fair play: nothing here reads the map. `sites.rank` places it on revealed tiles only (a footprint ring of rock or
unknown, no revealed open, wet or marked tile), never with a shaft that reaches a level in `avoid` (absolute z: levels
the player knows to be aquifer, e.g. from the embark info or damp stone the miners reported) or a level with a revealed
cavern, damp or warm mark; the runner stops the dig at a damp, warm or cavern report (BREACH_STOP) as for every dig.
"""
from __future__ import annotations

from .primitives import Plan

PARAMS = {"explore": {"depth": (12, 2, 40), "arm": (6, 0, 12), "every": (3, 1, 10), "avoid": ("", None, None)}}
AVOID_SPAN = 400                      # one avoid range covers at most this many levels


def parse_avoid(text) -> set[int]:
    """'113,95-97' -> {95, 96, 97, 113}; raises ValueError on a bad token."""
    out: set[int] = set()
    for tok in str(text or "").replace(" ", "").split(","):
        if not tok:
            continue
        a, sep, b = tok.partition("-")
        try:
            lo, hi = int(a), int(b) if sep else int(a)
        except ValueError:
            raise ValueError(f"explore.avoid: bad level {tok!r} (want z or z1-z2, comma-separated)") from None
        lo, hi = min(lo, hi), max(lo, hi)
        if lo < 0 or hi - lo > AVOID_SPAN:
            raise ValueError(f"explore.avoid: bad range {tok!r}")
        out.update(range(lo, hi + 1))
    return out


def tunnel_levels(p: dict) -> list[int]:
    """Local w of the side-tunnel levels: every `every` levels below the top and always the bottom."""
    ws = [-k for k in range(p["every"], p["depth"] + 1, p["every"])]
    return ws if -p["depth"] in ws else ws + [-p["depth"]]


def explore(p: dict) -> Plan:
    """Ore search: a 1-wide stair shaft `depth` levels down with side tunnels (W, E, S, `arm` tiles) every `every` levels."""
    parse_avoid(p["avoid"])                         # a bad avoid list is refused at emit, not at ranking time
    P = Plan("explore", "infra")
    d = P.stage("dig", "dig")
    d.stair(0, 1, -p["depth"], 0)
    a = p["arm"]
    if a:
        for w in tunnel_levels(p):
            d.rect(-a, 1, -1, 1, w).rect(1, 1, a, 1, w).rect(0, 2, 0, 1 + a, w)
    return P


BUILD = {"explore": explore}
