"""`traps 0` beside an armed trap hall (Run 9: 46 traps, Run 10: 41 stone-fall traps x=112..121 z122): the audit's
min_traps was the minimum over every route, and the bypass the same audit found meets no trap. With a bypass it now
counts the route once the walls the findings name stand; a side way into the hall's trap-free end still reads 0
and says where it enters the hall."""
from dfpilot import bp, wake

from bp_fixtures import FORT, L, dig, fort_docs, mutation, terrain

ZR = -2 - 3 - 3


def run10_route():
    """A stair from the surface and a tunnel into the refuge room: attackers reach the refuge and Z4 up the civilian
    stair (139,128,117 in Run 10 is the stair tile one level above the refuge)."""
    tun = [L(u, 45, ZR) for u in range(-16, -4)]
    col = [L(-17, 45, w) for w in range(ZR, 1)]
    cells = [(x, y, z, "u" if z == FORT[2] + ZR else "j" if z == FORT[2] else "i") for x, y, z in col]
    return mutation([dig(tun), ("m.st", "dig", cells)])


def audit(extra, base=None):
    w = bp.as_built(fort_docs() + extra, base=base)
    info = {}
    return bp.audit(w.snapshot(), w.manifest, info=info), info


def test_run10_bypass_no_longer_zeroes_the_trap_count():
    res, info = audit([run10_route()], base=terrain().snapshot())
    assert res["bypass"] and not res["refuge_sep"]
    assert res["min_traps"] == 35                       # was 0: the minimum took the bypass
    assert info["traps"]["armed"] == info["traps"]["hall"] == 41
    assert info["traps"]["any_route"] == 0 and info["traps"]["walls"] == 1
    note = wake.trap_note(info, res)
    assert "41 of 41 armed traps in the trap hall" in note and "the bypass itself meets 0" in note


def test_side_way_into_the_hall_end_reads_zero_and_says_where():
    """No bypass (every route touches Z2) but a tunnel from the bailey reaches the hall's last, trap-free tiles."""
    tun = [L(u, 16, -2) for u in range(-8, -4)] + [L(-8, v, -2) for v in range(17, 25)] + \
        [L(u, 24, -2) for u in range(-7, 0)]
    res, info = audit([mutation([dig(tun)])])
    assert res["ok"] and not res["bypass"] and res["min_traps"] == 0   # R2 traps<30 stays red: correct
    assert info["traps"]["enters"] == list(L(0, 25, -2))
    assert "enters the hall at %d,%d,%d" % L(0, 25, -2) in wake.trap_note(info, res)


def test_plain_fort_counts_the_hall():
    res, info = audit([])
    assert res["ok"] and res["min_traps"] == 35 and info["traps"]["enters"] == list(L(0, 17, -2))
    assert wake.trap_note(info, res) == " (41 of 41 armed traps in the trap hall)"
