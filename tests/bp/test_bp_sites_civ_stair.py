"""BUG-157 (live i4, y717): `bp sites hospital` put S1 at [77,68,126] on the civilians' stair to the refuge (`0 steps to a
stair`), tombs at its stair head 77,68,125 (the hatch tile the seal must close) and the Quern project anchored there too.
No room is anchored on a civilian stair column or on the refuge's hatch tile. Fails on main (dec5132): every ranked site of
the fort fixture stood on the stair column 50,65."""
import pytest

from dfpilot import bp
from dfpilot.bp import rooms

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _column(m):
    return {(c[0], c[1], z) for c in m["stairs"]["civ"] for z in range(c[2], c[3] + 1)}


@pytest.mark.parametrize("tpl", ["hospital", "tombs", "workshops", "dining", "bedrooms", "office"])
def test_no_room_is_anchored_on_the_civilian_stair_or_the_hatch_tile(fort, tpl):
    snap, m = fort
    col = _column(m)
    zr = m["refuge"]["anchor"][2]
    hatch = {(x, y, z) for x, y, z in col if z == zr + 1}
    assert hatch, "the fixture's civilian stair reaches the refuge"
    sites = bp.rank(snap, tpl, manifest=m, n=10)
    assert sites, f"{tpl}: still sites next to the stair"
    for s in sites:
        assert tuple(s["anchor"]) not in col, (tpl, s)


def test_rooms_still_open_next_to_the_stair(fort):
    """The ranking keeps its preference for a short way to a stair: the best hospital is one step from it."""
    snap, m = fort
    best = bp.rank(snap, "hospital", manifest=m)[0]
    assert "1 steps to a stair" in best["why"], best


def test_refuge_level_rooms_keep_their_sites(fort):
    snap, m = fort
    for tpl in sorted(rooms.REFUGE_LEVEL):
        sites = bp.rank(snap, tpl, manifest=m)
        assert all(tuple(s["anchor"]) not in _column(m) for s in sites), (tpl, sites)
