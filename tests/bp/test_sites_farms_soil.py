"""BUG-257 (Run 15 Inkintense, Drillchamber): every farms site was 'soil 0/70 plot tiles' (stone), the farms project
ended build_lost 'missing p' and was re-dug on the same site for 8 seasons. quickfort builds farm plots only on soil or
mud: with the soil known (the snapshot's soil marks) a farms site needs soil under at least half its plot tiles; with no
soil mark at all (an older snapshot) the soil stays unknown and is not filtered (plan check warns). Fails on 2b9c009."""
import pytest

from dfpilot import bp
from dfpilot.bp import render

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _plots(doc):
    return [(x, y, z) for st, k, _, x0, y0, x1, y1, z in render.cell_rects(doc) if k == "p"
            for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


def test_farms_need_soil_under_half_the_plots_once_soil_is_known(fort):
    snap, man = fort
    plain = bp.rank(snap, "farms", manifest=man, n=40)
    assert plain and all("soil unknown" in s["why"] for s in plain), "no soil marks: unknown, not filtered"
    best = plain[0]
    tiles = _plots(bp.emit("farms", {}, best))
    # soil under 30 of 70 plot tiles of the best site, nowhere else: the live 'soil 0/70' sites are refused
    few = {**snap, "marks": {"soil": [list(t) for t in tiles[:30]]}}
    ranked = bp.rank(few, "farms", manifest=man, n=40)
    assert ranked == [], [s["why"] for s in ranked][:3]               # 30 soil tiles in all: no site has half
    half = {**snap, "marks": {"soil": [list(t) for t in tiles[:35]]}}
    top = bp.rank(half, "farms", manifest=man, n=40)
    assert top and any(s["anchor"] == best["anchor"] and s["rot"] == best["rot"] for s in top), "35/70 is enough"
    assert all(int(s["why"].split("soil ")[1].split("/")[0]) * 2 >= 70 for s in top)
