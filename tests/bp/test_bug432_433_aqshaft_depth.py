"""BUG-432/433 (Run 16c i3 Yawninggilt, fix round 25: aquifer z120-127, a cavern breach recorded below, `plan propose` still drafted no
aqshaft and `bp sites aqshaft` (also depth=5..20) refused all 1271 columns with 'avoided cavern/warm level'): a shaft only has to
reach the core's top level under the aquifer (AQ_REACH = 2 under the shallowest aquifer level), so a cavern/warm level deeper than that (more than 1 level below the shaft's
bottom) must not refuse a column; without p.depth the ranking goes down to that level, not 20; every refusal names the level /
coordinate; `bp.place aqshaft` with an explicit column p.x/p.y/p.top/p.depth is checked by the same rules.
The fixture is the sites fort (public floor z5, rock z4-z3, unknown below) with the aquifer on z5: the shaft reaches
z5 - AQ_REACH = z3 (depth 3). Fails on ad01acb (the cavern at z-10 refused every column of the default depth 20)."""
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
    assert sites.shaft_depth_auto(snap, _man(man), 5) == 5 - (5 - sites.AQ_REACH) + 1 == 3


def test_a_cavern_far_below_the_refuge_level_refuses_no_column(fort):
    snap, man = fort
    m = _man(man, caverns=[(50, 63, -10)])
    got = bp.rank(snap, "aqshaft", {}, manifest=m)                           # old code: depth 20 from z5 reaches z-10, all refused
    assert len(got) == 3 and all(g["depth"] == 3 and "p.depth 3" in g["why"] for g in got), got
    x, y, z = got[0]["anchor"]
    assert got[0]["why"].startswith(f"column {x},{y} z{z}-z{z - 2}")
    # a named depth is checked as given: depth 20 does reach the cavern, and the refusal names the level and a column
    with pytest.raises(ValueError, match=r"an avoided cavern/warm level: \d+ \[\d+,\d+: cavern/warm level z-10 \(cavern breach at .*\) lies within the shaft's z5-z-14"):
        bp.rank(snap, "aqshaft", {"depth": 20}, manifest=m)
    assert bp.rank(snap, "aqshaft", {"depth": 3}, manifest=m)[0]["depth"] == 3


def test_the_level_right_below_the_bottom_still_refuses(fort):
    snap, man = fort
    with pytest.raises(ValueError, match=r"cavern/warm level z2 \(cavern breach at .*\) lies within the shaft's z5-z3 or the level below"):
        bp.rank(snap, "aqshaft", {}, manifest=_man(man, caverns=[(1, 1, 2)]))      # bottom z3, one level below: refused
    assert bp.rank(snap, "aqshaft", {}, manifest=_man(man, caverns=[(1, 1, 1)]))    # two below: fine


def test_refusals_name_at_most_three_examples_per_reason(fort):
    snap, man = fort
    cav = {**snap, "marks": {**snap.get("marks", {}), "cavern": [[0, 0, 3]]}}
    with pytest.raises(ValueError) as e:
        bp.rank(cav, "aqshaft", {}, manifest=_man(man))
    msg = str(e.value)
    ex = msg.split("an avoided cavern/warm level:")[1].split("]")[0]
    assert ex.count("cavern/warm level z3") == 3, msg                        # first 3 examples of many
    assert "p.x, p.y, p.top, p.depth" in msg


def test_water_near_the_shaft_refuses_the_column(fort):
    snap, man = fort
    m = _man(man)
    best = bp.rank(snap, "aqshaft", {}, manifest=m)[0]["anchor"]
    wet = _tile(snap, best[0] + 3, best[1], 3, "~")                          # 3 tiles beside the column on a level it passes
    assert [b["anchor"] for b in bp.rank(wet, "aqshaft", {}, manifest=m, n=40) if b["anchor"] == best] == []
    with pytest.raises(ValueError, match=rf"open water at {best[0] + 3},{best[1]} z3 \(within 3 tiles\)"):
        sites.check_column(wet, m, best[0], best[1], best[2], 3)
    sites.check_column(snap, m, best[0], best[1], best[2], 3)                # the dry map: accepted


def test_check_column_refuses_rock_side_cavern_and_water_top(fort):
    snap, man = fort
    m = _man(man, caverns=[(1, 1, -10)])
    x, y, z = bp.rank(snap, "aqshaft", {}, manifest=m)[0]["anchor"]
    sites.check_column(snap, m, x, y, z, 3)
    with pytest.raises(ValueError, match=rf"{x},{y} z{z} depth 20 .*cavern/warm level z-10"):
        sites.check_column(snap, m, x, y, z, 20)
    with pytest.raises(ValueError, match=rf"{x + 1},{y} z{z - 1} is '\.', not rock"):
        sites.check_column(_tile(snap, x + 1, y, z - 1, "."), m, x, y, z, 3)
    with pytest.raises(ValueError, match="top tile is open water"):
        sites.check_column(_tile(snap, x, y, z, "~"), m, x, y, z, 3)


def test_bp_place_checks_an_explicit_column_and_uses_the_refuge_depth(fort, tmp_path, monkeypatch):
    snap, man = fort
    m = _man(man, caverns=[(1, 1, -10)])
    monkeypatch.setattr(cmd, "sites_snapshot", lambda d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda d: m)
    x, y, z = bp.rank(snap, "aqshaft", {}, manifest=m)[0]["anchor"]
    col = [x, y, z]
    got = cmd.column_checked(tmp_path, "aqshaft", {"x": x, "y": y, "top": z}, col, None)
    assert got["depth"] == 3                                                 # no p.depth: down to the core level
    with pytest.raises(cmd.BpError, match=r"cavern/warm level z-10"):
        cmd.column_checked(tmp_path, "aqshaft", {"x": x, "y": y, "top": z, "depth": 20}, col, None)
    assert cmd.column_checked(tmp_path, "workshops", {"a": 1}, col, None) == {"a": 1}
    # a ranked site carries its depth into the emitted shaft
    site = bp.rank(snap, "aqshaft", {}, manifest=m)[0]
    doc = cmd.emit_at("aqshaft", cmd.site_params("aqshaft", {}, site), site, "S1", "t")
    assert len(doc["stages"]) == 3
    assert cmd.site_params("aqshaft", {"depth": 4}, site) == {"depth": 4}


def _best(snap, man):
    return bp.rank(snap, "aqshaft", {}, manifest=_man(man))[0]["anchor"]


def _sparse(snap, n, z, key="cavern"):
    """n cavern marks on level z (a few tiles of a big cavern, the export keeps the first ones in scan order)."""
    return {**snap, "marks": {**snap.get("marks", {}), key: [[i % 40, i // 40, z] for i in range(n)]}}


def test_sparse_marks_refuse_the_whole_level(fort):
    """Marks are sparse: one revealed cavern tile far from the column means the cavern level is there, level-wide."""
    snap, man = fort
    x, y, z = _best(snap, man)
    m = _man(man)
    one = {**snap, "marks": {**snap.get("marks", {}), "cavern": [[x + 40, y + 40, 4]]}}      # far away, on a level the shaft passes
    with pytest.raises(ValueError, match=r"an avoided cavern/warm level: \d+ \[\d+,\d+: cavern/warm level z4 \(cavern mark at"):
        bp.rank(one, "aqshaft", {}, manifest=m)
    with pytest.raises(ValueError, match=rf"{x},{y}: cavern/warm level z4"):
        sites.check_column(one, m, x, y, z, 3)
    warm = {**snap, "marks": {**snap.get("marks", {}), "warm": [[x + 40, y + 40, 4]]}}
    with pytest.raises(ValueError, match="cavern/warm level z4 .warm mark"):
        bp.rank(warm, "aqshaft", {}, manifest=m)


def test_a_large_cavern_with_one_breach_point_refuses_the_level_for_every_column(fort):
    """i3 (evidence: manifest caverns [[50,63,122]] = BREACH_STOP why cavern_lake of explore y375s1b0, '154 water tiles in
    reach', inside the aquifer z121-124): a real cavern lake breach. Every column passes that level, so every column is refused
    (the shaft cannot stay above it)."""
    snap, man = fort
    m = _man(man, caverns=[(500, 500, 4)])                                   # the breach is far from every column, on z4
    m["breaches"] = [{"pos": [500, 500, 4], "proj": "y375s1b0", "tpl": "explore", "why": "cavern_lake"}]
    with pytest.raises(ValueError, match=r"an avoided cavern/warm level: \d+ \[.*cavern breach at 500,500,4"):
        bp.rank(snap, "aqshaft", {}, manifest=m)


def test_an_aquifer_breach_inside_the_aquifer_span_is_not_a_cavern(fort):
    """A point recorded as heavy_aquifer/damp/water inside the known aquifer span is the aquifer itself: it refuses nothing.
    The same point recorded as cavern_lake does."""
    snap, man = fort
    for why in ("heavy_aquifer", "damp", "water"):
        m = _man(man, caverns=[(500, 500, 4)], aq=(4, 5))
        m["breaches"] = [{"pos": [500, 500, 4], "why": why}]
        assert bp.rank(snap, "aqshaft", {}, manifest=m), why
    m = _man(man, caverns=[(500, 500, 4)], aq=(4, 5))                        # the same point recorded as a cavern lake: a cavern
    m["breaches"] = [{"pos": [500, 500, 4], "why": "cavern_lake"}]
    # BUG-633: on a known aquifer level it is a flood of our rooms, LOCAL: the columns far from it pass, the ones beside it do not
    assert bp.rank(snap, "aqshaft", {}, manifest=m)
    with pytest.raises(ValueError, match="cavern breach at 500,500,4"):
        sites.check_column(snap, m, 502, 500, 5, 3)
    m2 = _man(man, caverns=[(500, 500, 2)], aq=(4, 5))                       # off the aquifer levels: a cavern, level-wide as before
    m2["breaches"] = [{"pos": [500, 500, 2], "why": "cavern_lake"}]
    with pytest.raises(ValueError, match="cavern breach at 500,500,2"):
        bp.rank(snap, "aqshaft", {}, manifest=m2)


def test_capped_cavern_marks_mean_incomplete_coverage(fort):
    """marks.cavern is cut at 500 per export in scan order (low z first): at the cap the levels from the last mark up were not fully
    scanned, a shaft touching one is refused level-wide; below the cap the same marks on a low level refuse nothing above."""
    snap, man = fort
    m = _man(man)
    capped = _sparse(snap, sites.MARKS_CAP, -20)                             # 500 marks on z-20: capped
    with pytest.raises(ValueError, match=r"cavern marks capped at 500, z\d+ not fully scanned"):
        bp.rank(capped, "aqshaft", {}, manifest=m)
    x, y, z = _best(snap, man)
    with pytest.raises(ValueError, match="marks capped at 500"):
        sites.check_column(capped, m, x, y, z, 3)
    assert bp.rank(_sparse(snap, sites.MARKS_CAP - 1, -20), "aqshaft", {}, manifest=m)    # 499: complete, z-20 is far below


def test_the_shaft_stops_at_the_core_level(fort):
    snap, man = fort
    assert sites.shaft_depth_auto(snap, _man(man, aq=(5, 6)), 6) == 6 - (5 - sites.AQ_REACH) + 1 == 4
    assert sites.AQ_REACH == 2                                               # not the refuge room 3 levels deeper
