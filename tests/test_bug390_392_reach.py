"""Run 16 round 21 (04.11.2026).
BUG-390 (i4 Mazelanterns): `bp sites` dropped every site as 'beyond the brook' while `inspect reach` said all reachable; the
walk-group ids move while an export runs (lua/dfllm/snapshot.lua re-reads the home groups per row, tests/lua/test_bug390_reach.lua).
Python side: a ranking asked for a spot on another walk group (BUG-391, a cut-off group's well) is not filtered.
BUG-392 (i2 Ostgate): the draft proposed explore at the spot (54,100,129) where it had stopped as breach:cavern_lake."""
import copy
import json
import sys
from pathlib import Path

import pytest

from dfpilot import bp, cmd
from dfpilot.bp import sites

sys.path.insert(0, str(Path(__file__).parent / "bp"))
from bp_fixtures import fort_docs, terrain  # noqa: E402


@pytest.fixture(scope="module")
def deep():
    w = bp.as_built(fort_docs(anchor=[50, 20, 30]), base=terrain(z0=1, z1=32, surf=30).snapshot())
    return w.snapshot(purpose="sites"), w.manifest


def _groups(snap, far_xy=None):
    """snap with wg: every tile '1', or '0' where far_xy(x, y) holds."""
    s = copy.deepcopy(snap)
    x0, y0 = s["bbox"][:2]
    rows = {}
    for k, v in s["rows"].items():
        rows[k] = ["".join("0" if far_xy and far_xy(x0 + i, y0 + j) else "1" for i in range(len(r))) for j, r in enumerate(v)]
    s["wg"] = {"home": 7, "rows": rows}
    return s


# ---------------------------------------------------------------- BUG-391: a spot on another walk group
def test_a_ranking_asked_for_a_spot_on_another_group_is_not_filtered(deep):
    snap, man = deep
    plain = bp.rank(snap, "explore", {"depth": 4}, manifest=man, n=2)
    ax, ay, az = plain[0]["anchor"]
    allfar = _groups(snap, lambda x, y: True)
    with pytest.raises(ValueError, match="cannot reach"):
        bp.rank(allfar, "explore", {"depth": 4}, manifest=man)
    near = bp.rank(allfar, "explore", {"depth": 4}, manifest=man, near=[ax, ay, az], within=30)
    assert near and near[0]["anchor"] == plain[0]["anchor"]
    # the spot lies on the citizens' group: the filter works as before
    home = _groups(snap, lambda x, y: (x, y) != (ax, ay) and abs(x - ax) + abs(y - ay) > 3)
    got = bp.rank(home, "explore", {"depth": 4}, manifest=man, near=[ax, ay, az], within=30)
    assert all(abs(s["anchor"][0] - ax) + abs(s["anchor"][1] - ay) <= 3 for s in got)


def test_a_cutoff_focus_drops_sites_on_the_citizens_group(deep):
    snap, man = deep
    plain = bp.rank(snap, "explore", {"depth": 4}, manifest=man, n=6)
    ax, ay, az = plain[0]["anchor"]
    # a mixed snapshot: only the tiles around the first anchor are the cut-off group, the rest is the citizens' group
    mixed = _groups(snap, lambda x, y: abs(x - ax) + abs(y - ay) <= 3)
    got = bp.rank(mixed, "explore", {"depth": 4}, manifest=man, near=[ax, ay, az], within=40, n=6)
    assert got
    for s in got:
        assert sites.walk_at(mixed, s["anchor"]) != "1", s["anchor"]
        assert "walk" not in s


# ---------------------------------------------------------------- BUG-392: not again where a dig stopped
def test_explore_keeps_off_a_breach_and_a_failed_anchor(deep):
    snap, man = deep
    best = bp.rank(snap, "explore", {"depth": 4}, manifest=man, n=1)[0]["anchor"]
    ax, ay, az = best
    # a breach 5 levels under the best anchor, 4 tiles beside it: a shaft of depth 4 reaches that level
    hurt = {**man, "breaches": [{"pos": [ax + 3, ay + 4, az - 5], "proj": "y377s0b0", "tpl": "explore", "why": "cavern_lake"}]}
    got = bp.rank(snap, "explore", {"depth": 4}, manifest=hurt)
    assert got and all(max(abs(s["anchor"][0] - ax), abs(s["anchor"][1] - ay)) > sites.EXPLORE_REDO_R
                       or s["anchor"][2] != az for s in got), [s["anchor"] for s in got]
    # a shallow shaft that stays above the breach is no repeat
    shallow = bp.rank(snap, "explore", {"depth": 2}, manifest=hurt, n=1)
    assert shallow[0]["anchor"] == bp.rank(snap, "explore", {"depth": 2}, manifest=man, n=1)[0]["anchor"]
    # the failed anchor itself (from the bp file): no explore within the radius on its level, whatever the depth
    failed = {**man, "failed_explore": [{"anchor": [ax, ay, az], "why": "cavern_lake", "proj": "y377s0b0"}]}
    for depth in (2, 4):
        got = bp.rank(snap, "explore", {"depth": depth}, manifest=failed)
        assert all(not (abs(s["anchor"][2] - az) <= 1 and max(abs(s["anchor"][0] - ax), abs(s["anchor"][1] - ay))
                        <= sites.EXPLORE_REDO_R) for s in got), [s["anchor"] for s in got]


def test_explore_with_every_anchor_near_a_failure_says_no_safe_site(deep):
    snap, man = deep
    grid = [[x, y, z] for b in man["zones"]["Z4"] for z in range(b[2], b[5] + 1)
            for x in range(b[0], b[3] + 1, 4) for y in range(b[1], b[4] + 1, 4)]
    failed = {**man, "failed_explore": [{"anchor": a, "why": "water", "proj": f"p{i}"} for i, a in enumerate(grid)]}
    with pytest.raises(ValueError, match="no safe explore site") as e:
        bp.rank(snap, "explore", {"depth": 2}, manifest=failed)
    assert "failed explore water" in str(e.value)


def test_fort_manifest_names_the_anchor_of_a_failed_explore(tmp_path):
    save = tmp_path / "run"
    (save / "bp").mkdir(parents=True)
    (save / "manifest.json").write_text(json.dumps({"v": 2, "breaches": [
        {"pos": [53, 96, 126], "proj": "y377s0b0", "tpl": "explore", "why": "cavern_lake"},
        {"pos": [87, 123, 130], "proj": "y376s1b1", "tpl": "dining", "why": "water"},
        {"pos": [60, 100, 123], "proj": "gone", "tpl": "explore", "why": "water"}]}))
    (save / "bp" / "y377s0b0.json").write_text(json.dumps({"id": "y377s0b0", "tpl": "explore", "anchor": [54, 100, 129]}))
    m = cmd._with_failed_explores(save, json.loads((save / "manifest.json").read_text()))
    assert m["failed_explore"] == [{"anchor": [54, 100, 129], "why": "cavern_lake", "proj": "y377s0b0"}]
    assert cmd._with_failed_explores(save, {"v": 2}) == {"v": 2}


def test_a_stranded_drink_decision_is_not_held_by_the_hourly_limit():
    """BUG-391: DECISION_NEEDED stranded_drink (a cut-off group over the thirst mark, no bridge brings drink) is urgent."""
    from dfpilot import wake
    assert wake.urgent_game({"type": "DECISION_NEEDED", "cls": "A", "d": {"id": "stranded_drink"}})
