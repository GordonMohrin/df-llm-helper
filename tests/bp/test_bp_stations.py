"""BUG-032 (Run 11, Kilrudrabed y432: GATE_FAIL B2 'not up after 908 ticks', the squads at fortcore's stations.b2, one
tile behind B2's footprint, held the BREACH raise): fortcore never puts a squad station on a bridge footprint or within
gate's margin + the squad's spread of one, and the validator rejects a manifest that does."""
import copy

import pytest

from dfpilot.bp import fortcore
from dfpilot.bp.primitives import merge_manifest
from dfpilot.bp.render import as_built
from dfpilot.bp.validate import STATION_CLEAR, check_world, fp_dist

from bp_fixtures import L, fort_docs


def manifest(docs):
    m = docs[0]["manifest"]
    for d in docs[1:]:
        m = merge_manifest(m, d["manifest"])
    return m


def inside(p, b):
    return b[0] <= p[0] <= b[3] and b[1] <= p[1] <= b[4] and b[2] <= p[2] <= b[5]


@pytest.mark.parametrize("rot", range(4))
def test_fortcore_stations_lie_clear_of_every_bridge(rot):
    docs = fort_docs(rot)
    world = as_built(docs)
    for k in (2, 3, 4):
        m = manifest(docs[:k])
        for name, p in m["stations"].items():
            for b, spec in m["bridges"].items():
                d = fp_dist(spec["fp"], p)
                assert d is None or d > STATION_CLEAR, f"stage {k}: station {name} {p} {d} tiles from {b}"
            assert world.get(*p) == ".", f"station {name} {p} is no plain floor: {world.get(*p)!r}"
    m = manifest(docs)
    assert STATION_CLEAR == 2
    # melee: inside the gatehouse Z3; b2: behind B2 on the core level (Z4), next to the civilians' stair, not core
    assert inside(m["stations"]["melee"], m["zones"]["Z3"][0])
    b2, core, civ = m["stations"]["b2"], m["stations"]["core"], m["stairs"]["civ"][0]
    assert any(inside(b2, z) for z in m["zones"]["Z4"])
    assert max(abs(b2[0] - civ[0]), abs(b2[1] - civ[1])) <= 2 and b2[2] == core[2] and b2 != core
    assert all(b2[2] != spec["fp"][2] for spec in m["bridges"].values())


def test_fortcore_station_offsets():
    """The local offsets the live forts know: melee (0, 36) and b2 (1, 44, ze) moved (2 and 1 tiles from B1 / B2)."""
    m = fortcore._manifest(3, -5, -8)
    assert m["stations"] == {"melee": [0, 38, -2], "gallery": [5, 29, -2], "b2": [-2, 45, -5], "core": [2, 45, -5]}


def with_station(name, pos):
    docs = copy.deepcopy(fort_docs())
    docs[-1]["manifest"]["stations"][name] = list(pos)          # fragments are cumulative: the last one wins
    return [f for f in check_world(docs) if f.code == "station_bridge"]


def test_validator_rejects_a_station_on_or_next_to_a_bridge():
    assert with_station("b2", L(-2, 45, -5)) == [], "fortcore's own"
    f = with_station("b2", L(1, 44, -2))                         # Run 11: one tile behind B2's footprint
    assert len(f) == 1 and f[0].level == "error", f
    assert "station b2 51,64,8 lies 1 tile from bridge B2's footprint (needs > 2: gate margin 1 + squad spread 1)" \
        in f[0].msg, f[0].msg
    f = with_station("melee", L(0, 36, -2))                      # the old melee station, 2 tiles from B1
    assert len(f) == 1 and "lies 2 tiles from bridge B1's footprint" in f[0].msg, f
    f = with_station("bailey", L(0, 7, -2))                      # on O1
    assert len(f) == 1 and "station bailey 50,27,8 lies on bridge O1's footprint" in f[0].msg, f
    assert with_station("bailey", L(0, 7, -1)) == [], "another level"

