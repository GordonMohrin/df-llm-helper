"""Round 47 (stone supply), Python side; offline, live-untested.
BUG-732 (Run 16a i1 Basementflew y520: `bp sites explore` -> '5 ranked, 5 projects hold them (explore finished)', no probe for years): the explore
         ranking keeps only sites free of placed projects (cmd.FREE_RANK_TPLS), and that test sees the depth and arm the ranking is trying, so a
         finished probe's shaft column no longer hides every other depth / arm.
BUG-735 (Run 16d i4 Pagedsculpture y384-y388: five probes of depth 20-24 ended at z113 and saw the same layers): the next probe goes under the
         earlier probes' lowest level; the summary says where the first stone is or 'NO STONE within N levels'."""
import json

import pytest

from dfpilot import bp, cmd, files
from dfpilot.bp import sites

from bp_fixtures import fort_docs, terrain


@pytest.fixture(scope="module")
def deep():
    w = bp.as_built(fort_docs(anchor=[50, 20, 30]), base=terrain(z0=1, z1=32, surf=30).snapshot())
    return w.snapshot(purpose="sites"), w.manifest


# ---------------------------------------------------------------- BUG-732
def test_explore_ranking_hands_the_free_test_the_depth_and_arm_it_is_trying(deep):
    snap, man = deep
    seen = []

    def free(c):
        seen.append((c.get("depth"), c.get("arm")))
        return True
    got = bp.rank(snap, "explore", {}, manifest=man, free=free)
    assert got and seen
    assert all(isinstance(d, int) and isinstance(a, int) for d, a in seen), seen[:3]
    assert (12, 6) in seen, "the template's own depth and arm are tried first"


def test_explore_all_taken_at_the_default_depth_falls_back_to_a_shorter_shaft(deep):
    """The default 12-deep probe clashes everywhere (the free test refuses it), a 9-deep shaft does not: the ranking must go on to it instead of
    ending with 'all N candidate site(s) lie on or beside placed projects'."""
    snap, man = deep

    def free(c):
        return c["depth"] < 12
    got = bp.rank(snap, "explore", {}, manifest=man, free=free)
    assert got and all(s["depth"] == 9 and "BUG-553" in s["why"] for s in got), [(s.get("depth"), s["why"][-60:]) for s in got]


def test_explore_every_depth_taken_names_the_placed_projects(deep):
    snap, man = deep
    free = lambda c: False                                       # noqa: E731
    free.held, free.why, free.first = {"y9s0b0"}, {"clash": 5}, {}
    with pytest.raises(ValueError, match=r"lie on or beside placed projects \(y9s0b0\).*tried"):
        bp.rank(snap, "explore", {}, manifest=man, free=free)


def test_explore_is_a_free_ranked_template(tmp_path):
    assert "explore" in cmd.FREE_RANK_TPLS
    d = tmp_path / "save"
    (d / "bp").mkdir(parents=True)
    assert callable(cmd._free_of_projects(d, "explore", None))
    assert cmd._free_of_projects(d, "hospital", None) is None


# ---------------------------------------------------------------- BUG-735
def _rocks(tmp_path, *events):
    d = tmp_path / "save"
    d.mkdir(exist_ok=True)
    with open(d / "events.jsonl", "w", encoding="utf-8") as f:
        for i, rocks in enumerate(events):
            f.write(json.dumps({"n": i + 1, "tick": i + 1, "type": "PROJECT_DONE", "cls": "B", "msg": "x",
                                "d": {"proj": f"y{i}s0b0", "tpl": "explore", "rocks": rocks}}) + "\n")
    cmd._ROCK_CACHE.clear()
    return d


def test_soil_layers_are_not_stone():
    for n in ("CLAY", "SILTY_CLAY", "SANDY_CLAY", "CLAY_LOAM", "SAND", "PEAT", "SOIL", "SANDY_LOAM"):
        assert cmd.is_soil_rock(n), n
    for n in ("CLAYSTONE", "SILTSTONE", "SANDSTONE", "MUDSTONE", "CHERT", "ROCK_SALT", "LIMESTONE"):
        assert not cmd.is_soil_rock(n), n


def test_summary_names_the_first_stone_layer_and_the_depth_looked_at(tmp_path):
    d = _rocks(tmp_path, ["SILTY_CLAY z140-z138", "CLAYSTONE z137-z134", "CHERT z133-z129", "SILTSTONE z114-z113"])
    s = cmd.explore_summary(d, top_z=142)
    assert s["low"] == 113 and s["high"] == 140 and s["soil_only"] is False
    assert s["first_stone"] == ("CLAYSTONE", 137)
    assert "first stone layer from the top: CLAYSTONE at z137 (5 level(s) down)" in s["text"] and "down to z113 (30 levels)" in s["text"]


def test_summary_says_no_stone_within_n_levels_when_every_layer_is_soil(tmp_path):
    d = _rocks(tmp_path, ["SILTY_CLAY z142-z138", "CLAY z137-z131"], ["SILTY_CLAY z142-z139", "CLAY z138-z125"])
    s = cmd.explore_summary(d, top_z=142)
    assert s["soil_only"] is True and s["first_stone"] is None
    assert s["text"].startswith("NO STONE within 18 levels") and "z125" in s["text"], s["text"]
    assert cmd.explore_summary(tmp_path / "none") == {}
    assert "NO STONE within 18 levels" in cmd.explore_rock_note(d)


def test_explored_low_is_the_lowest_level_seen_and_unset_with_flux(tmp_path):
    d = _rocks(tmp_path, ["CLAYSTONE z137-z120"], ["CLAYSTONE z137-z113"])
    assert cmd.explore_low(d) == 113
    d = _rocks(tmp_path, ["CLAYSTONE z137-z120", "LIMESTONE z119-z113"])
    assert cmd.explore_low(d) is None, "a flux stone was seen: the old depth ladder stands"


def test_the_next_probe_goes_under_the_lowest_level_the_earlier_ones_saw(deep):
    snap, man = deep
    top_z = max(b[5] for b in man["zones"]["Z4"])
    got = bp.rank(snap, "explore", {}, manifest=dict(man, explored=[[50, 20, 27]], explored_low=top_z - 8), n=3)
    want = top_z - (top_z - 8 - sites.EXPLORE_DEEPER)
    assert want == 14 and got and all(s["depth"] == want and "BUG-735" in s["why"] for s in got), [s["why"][-90:] for s in got]
    # p.depth given stays the player's; a template depth that already reaches that far stays; no explored_low: as before
    assert all("depth" not in s for s in bp.rank(snap, "explore", {"depth": 6}, manifest=dict(man, explored_low=top_z - 8)))
    assert all(s.get("depth") != 14 for s in bp.rank(snap, "explore", {}, manifest=dict(man, explored_low=top_z - 3)))
    assert all("BUG-735" not in s["why"] for s in bp.rank(snap, "explore", {}, manifest=man))
    # never deeper than the template's maximum depth
    assert sites._explore_deeper(dict(man, explored_low=-80), {}, 12) == 40


def test_manifest_carries_explored_low_from_the_finished_probes(tmp_path):
    d = _rocks(tmp_path, ["CLAYSTONE z137-z113"])
    (d / "bp").mkdir(exist_ok=True)
    doc = cmd.emit_at("explore", {"depth": 6}, {"id": "S0", "anchor": [100, 100, 134], "rot": 0}, "S0", "y9s0b0")
    files.write_json_atomic(d / "bp" / "y9s0b0.json", doc)
    m = cmd._with_explored(d, {"v": 2})
    assert m["explored"] == [[100, 100, 134]] and m["explored_low"] == 113
