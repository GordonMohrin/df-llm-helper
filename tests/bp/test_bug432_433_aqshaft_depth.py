"""BUG-432/433 (Run 16c i3 Yawninggilt, fix round 25: aquifer z120-127, a cavern breach recorded below, `plan propose` still drafted no
aqshaft and `bp sites aqshaft` (also depth=5..20) refused all 1271 columns with 'avoided cavern/warm level'): a shaft only has to
reach the core's refuge level under the aquifer, so a cavern/warm level deeper than that (more than 1 level below the shaft's
bottom) must not refuse a column; without p.depth the ranking goes down to that level, not 20; every refusal names the level /
coordinate; `bp.place aqshaft` with an explicit column p.x/p.y/p.top/p.depth is checked by the same rules.
The fixture is the sites fort (public floor z5, rock z4-z3, unknown below) with the aquifer on z5: the shaft reaches
z5 - AQ_REACH = z0 (depth 6). Fails on ad01acb (the cavern at z-10 refused every column of the default depth 20)."""
import copy

import pytest

from dfpilot import bp, cmd
from dfpilot.bp import sites

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _man(man, caverns=(), aq=(5,)):
    return {**man, "aquifer_levels": list(aq), "caverns": [list(c) for c in caverns]}


def _tile(snap, x, y, z, ch):
    s = copy.deepcopy(snap)
    x0, y0 = s["bbox"][0], s["bbox"][1]
    row = s["rows"][f"z{z}"][y - y0]
    s["rows"][f"z{z}"][y - y0] = row[:x - x0] + ch + row[x - x0 + 1:]
    return s


def test_auto_depth_reaches_the_refuge_level_under_the_aquifer(fort):
    snap, man = fort
    assert sites.shaft_depth_auto(snap, man, 5) is None                      # no aquifer known: the default stays
    assert sites.shaft_depth_auto(snap, _man(man), 5) == 5 - (5 - sites.AQ_REACH) + 1 == 6


def _best(snap, man):
    return bp.rank(snap, "aqshaft", {}, manifest=_man(man))[0]["anchor"]


def test_a_cavern_far_below_the_refuge_level_refuses_no_column(fort):
    snap, man = fort
    x, y, _ = _best(snap, man)
    m = _man(man, caverns=[(x, y, -10)])                                     # right under the best column, far below its bottom
    got = bp.rank(snap, "aqshaft", {}, manifest=m)                           # old code: depth 20 from z5 reaches z-10, all refused
    assert len(got) == 3 and all(g["depth"] == 6 and "p.depth 6" in g["why"] for g in got), got
    z = got[0]["anchor"][2]
    assert got[0]["why"].startswith(f"column {got[0]['anchor'][0]},{got[0]['anchor'][1]} z{z}-z{z - 5}")
    # a named depth is checked as given: depth 20 does reach the cavern next to the column, the refusal names the level and a column
    with pytest.raises(ValueError, match=r"a cavern/warm tile near the column: \d+ \[\d+,\d+: cavern/warm tile within \d+ tiles on z-10, inside the shaft's z5-z-14"):
        bp.rank(snap, "aqshaft", {"depth": 20}, manifest={**m, "caverns": [[bx, by, -10] for bx in range(0, 120, 8) for by in range(0, 120, 8)]})
    assert bp.rank(snap, "aqshaft", {"depth": 6}, manifest=m)[0]["depth"] == 6


def test_the_level_right_below_the_bottom_still_refuses(fort):
    snap, man = fort
    x, y, _ = _best(snap, man)
    with pytest.raises(ValueError, match=r"cavern/warm tile within \d+ tiles on z-1, inside the shaft's z5-z0 or the level below"):
        bp.rank(snap, "aqshaft", {}, manifest=_man(man, caverns=[(bx, by, -1) for bx in range(0, 120, 8) for by in range(0, 120, 8)]))
    # bottom z0: z-1 right below it refuses the column next to it, z-2 does not
    m1 = _man(man, caverns=[(x, y, -1)])
    assert [x, y, 5] not in [g["anchor"] for g in bp.rank(snap, "aqshaft", {}, manifest=m1, n=500)]
    m2 = _man(man, caverns=[(x, y, -2)])
    assert [x, y, 5] in [g["anchor"] for g in bp.rank(snap, "aqshaft", {}, manifest=m2, n=500)]


def test_i3_cavern_breach_inside_the_aquifer_span_blocks_only_its_neighbourhood(fort):
    """The live i3 case: the aquifer z0..5 and a cavern breach recorded at z3 inside it. The old level-wide rule refused every
    column (each passes z3); now only the columns within AQ_CAV_R tiles of the breach are refused."""
    snap, man = fort
    ranked = bp.rank(snap, "aqshaft", {}, manifest=_man(man, aq=(0, 1, 2, 3, 4, 5)), n=500)
    far = ranked[0]["anchor"]

    m = _man(man, caverns=[(far[0], far[1], 3)], aq=(0, 1, 2, 3, 4, 5))
    got = [g["anchor"] for g in bp.rank(snap, "aqshaft", {}, manifest=m, n=500)]
    assert got, "the level-wide rule refused every column"
    assert far not in got and all(max(abs(a[0] - far[0]), abs(a[1] - far[1])) > sites.AQ_CAV_R for a in got)
    with pytest.raises(ValueError, match=rf"{far[0]},{far[1]}: cavern/warm tile within {sites.AQ_CAV_R} tiles on z3"):
        sites.check_column(snap, m, far[0], far[1], far[2], 6)
    c = got[0]
    sites.check_column(snap, m, c[0], c[1], c[2], 6)                         # an explicit column far from the breach is accepted


def test_refusals_name_at_most_three_examples_per_reason(fort):
    snap, man = fort
    cav = {**snap, "marks": {**snap.get("marks", {}), "cavern": [[bx, by, 3] for bx in range(0, 120, 8) for by in range(0, 120, 8)]}}
    with pytest.raises(ValueError) as e:
        bp.rank(cav, "aqshaft", {}, manifest=_man(man))
    msg = str(e.value)
    ex = msg.split("a cavern/warm tile near the column:")[1].split("]")[0]
    assert ex.count("cavern/warm tile within") == 3, msg                     # first 3 examples of many
    assert "p.x, p.y, p.top, p.depth" in msg


def test_water_near_the_shaft_refuses_the_column(fort):
    snap, man = fort
    m = _man(man)
    best = bp.rank(snap, "aqshaft", {}, manifest=m)[0]["anchor"]
    wet = _tile(snap, best[0] + 3, best[1], 3, "~")                          # 3 tiles beside the column on a level it passes
    assert [b["anchor"] for b in bp.rank(wet, "aqshaft", {}, manifest=m, n=40) if b["anchor"] == best] == []
    with pytest.raises(ValueError, match=rf"open water at {best[0] + 3},{best[1]} z3 \(within 3 tiles\)"):
        sites.check_column(wet, m, best[0], best[1], best[2], 6)
    sites.check_column(snap, m, best[0], best[1], best[2], 6)                # the dry map: accepted


def test_check_column_refuses_rock_side_cavern_and_water_top(fort):
    snap, man = fort
    x, y, z = _best(snap, man)
    m = _man(man, caverns=[(x, y, -10)])
    sites.check_column(snap, m, x, y, z, 6)
    with pytest.raises(ValueError, match=rf"{x},{y} z{z} depth 20 .*cavern/warm tile within \d+ tiles on z-10"):
        sites.check_column(snap, m, x, y, z, 20)
    with pytest.raises(ValueError, match=rf"{x + 1},{y} z{z - 1} is '\.', not rock"):
        sites.check_column(_tile(snap, x + 1, y, z - 1, "."), m, x, y, z, 6)
    with pytest.raises(ValueError, match="top tile is open water"):
        sites.check_column(_tile(snap, x, y, z, "~"), m, x, y, z, 6)


def test_bp_place_checks_an_explicit_column_and_uses_the_refuge_depth(fort, tmp_path, monkeypatch):
    snap, man = fort
    x, y, z = _best(snap, man)
    m = _man(man, caverns=[(x, y, -10)])
    monkeypatch.setattr(cmd, "sites_snapshot", lambda d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda d: m)
    col = [x, y, z]
    got = cmd.column_checked(tmp_path, "aqshaft", {"x": x, "y": y, "top": z}, col, None)
    assert got["depth"] == 6                                                 # no p.depth: down to the core's refuge level
    with pytest.raises(cmd.BpError, match=r"cavern/warm tile within \d+ tiles on z-10"):
        cmd.column_checked(tmp_path, "aqshaft", {"x": x, "y": y, "top": z, "depth": 20}, col, None)
    assert cmd.column_checked(tmp_path, "workshops", {"a": 1}, col, None) == {"a": 1}
    # a ranked site carries its depth into the emitted shaft
    site = bp.rank(snap, "aqshaft", {}, manifest=m)[0]
    doc = cmd.emit_at("aqshaft", cmd.site_params("aqshaft", {}, site), site, "S1", "t")
    assert len(doc["stages"]) == 6
    assert cmd.site_params("aqshaft", {"depth": 4}, site) == {"depth": 4}
