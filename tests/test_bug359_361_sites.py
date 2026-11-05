"""Run 16c site97 (i3) and Run 16b Ostgate (i2), 04.11.2026.
BUG-359: every reachable fortcore site broke into water ('breach:heavy_aquifer' at A74_92_125_3, 'breach:cavern_lake' at
A88_92_125_3, dig_lost at A106_78_125_1) while the ranking and the embark panel only said 'light aquifer'. A recorded
heavy_aquifer stop never counted as a wet layer (its label's first word is not damp/water), and nothing rated the levels
under the anchor from the snapshot. Now the ranking rates them (manifest aquifer_levels, snapshot `aqz`, breach layers,
revealed water and cavern beside the deep dig) and names them per site.
BUG-360: 'no water reachable' with a brook in the embark rectangle: the sites box did not cover the brook; the reason line
now says so, and a body the box cuts off counts.
BUG-361: the seal on the dead cores' tunnels held every ranked fortcore site; the fortcore ranking keeps only free sites
and names the holders."""
import copy
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, schema
from dfpilot.bp import sites
from dfpilot.bp.primitives import Xform

sys.path.insert(0, str(Path(__file__).parent / "bp"))
from bp_fixtures import mutation, set_tiles, terrain  # noqa: E402


@pytest.fixture(scope="module")
def land():
    return terrain().snapshot(purpose="sites")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _breach(pos, why, proj="p1"):
    return {"pos": list(pos), "why": why, "proj": proj, "tpl": "fortcore"}


def _with_aq(snap, **zs):
    s = copy.deepcopy(snap)
    s["aqz"] = {k: v for k, v in zs.items()}
    return s


# ---------------------------------------------------------------- BUG-359: the contract
def test_a_sites_snapshot_may_carry_the_aquifer_levels(land):
    s = _with_aq(land, z6=40)
    assert schema.validate("snapshot", s) == []
    assert schema.validate("snapshot", _with_aq(land, z6=-1)) != []
    assert schema.validate("snapshot", _with_aq(land, up=3)) != []
    assert sites.snapshot_aquifer(s) == {6: 40}
    assert sites.snapshot_aquifer(land) == {}


# ---------------------------------------------------------------- BUG-359: the ranking
def test_a_known_aquifer_level_under_the_shaft_is_named_and_costs_score(land):
    plain = bp.rank(land, "fortcore", n=3)
    assert all("no aquifer or water known on z1-10" in s["why"] for s in plain)
    aq = bp.rank(_with_aq(land, z6=40, z7=12), "fortcore", n=3)
    assert aq and all("aquifer at z6,z7" in s["why"] for s in aq)
    assert aq[0]["score"] == plain[0]["score"] - 2 * sites.AQ_PENALTY
    # the manifest's aquifer_levels (the kernel saw damp) count the same; a level the dig never reaches does not
    man = bp.rank(land, "fortcore", manifest={"v": 2, "aquifer_levels": [6]}, n=3)
    assert "aquifer at z6" in man[0]["why"] and "z7" not in man[0]["why"]
    far = bp.rank(land, "fortcore", manifest={"v": 2, "aquifer_levels": [11]}, n=3)
    assert "aquifer at" not in far[0]["why"]


def test_one_heavy_aquifer_stop_makes_the_level_a_wet_layer_around_its_stop(land):
    man = {"v": 2, "breaches": [_breach([5, 5, 6], "heavy_aquifer")]}
    assert sites._breach_layers(man) == {6: "wet level z6 (heavy aquifer: breach heavy_aquifer 5,5,6 p1)"}
    # BUG-388: the wet layer rules out the dig near its stop (LAYER_R), not the level for every site of the map (`_dry`, under
    # p.aquifer=pass); BUG-484: a stage 1 with no p.aquifer never digs through a level a dig of ours met a heavy aquifer on
    got = bp.rank(land, "fortcore", {"aquifer": "pass"}, manifest=man, n=10)
    assert got and all(max(abs(s["anchor"][0] - 5), abs(s["anchor"][1] - 5)) > sites.LAYER_R for s in got)
    with pytest.raises(ValueError, match=r"heavy aquifer known at z6.*p\.aquifer=pass"):
        bp.rank(land, "fortcore", manifest=man, n=10)
    grid = {"v": 2, "breaches": [_breach([x, y, 6], "heavy_aquifer") for x in range(0, 100, 15) for y in range(0, 100, 15)][:32]}
    with pytest.raises(ValueError, match=r"no dry fortcore site.*wet level z6 \(heavy aquifer"):
        bp.rank(land, "fortcore", manifest=grid)                        # stops all over the map: nothing dry is left
    # damp keeps its two-stop rule (a pocket), and a heavy stop on a level the dig never reaches changes nothing
    assert sites._breach_layers({"v": 2, "breaches": [_breach([5, 5, 6], "damp")]}) == {}
    assert bp.rank(land, "fortcore", manifest={"v": 2, "breaches": [_breach([5, 5, 11], "heavy_aquifer")]})


def test_revealed_water_beside_the_deep_dig_drops_the_site(land):
    best = bp.rank(land, "fortcore", n=3)
    b = best[0]
    x, y, z = Xform(b["anchor"], b["rot"]).pos(0, 48 + 3, -5)            # 3 tiles beside the core hub's south wall
    wet = set_tiles(land, [(x, y, z)], "~")
    got = bp.rank(wet, "fortcore", n=3)
    assert got and all(s["anchor"] != b["anchor"] for s in got), "the site beside the pool is gone, the rest stays"
    # water on a shallow level (a brook bed at -1) is no reason
    bed = set_tiles(land, [Xform(b["anchor"], b["rot"]).pos(0, 48 + 3, -1)], "~")
    assert bp.rank(bed, "fortcore", n=1)[0]["anchor"] == b["anchor"]


def test_every_site_beside_water_is_named(land):
    p = sites.check_params("fortcore", {})
    rects = sites.footprint("fortcore", p)
    cand = {"anchor": [50, 20, 10], "rot": 0, "score": 1000, "why": "x"}
    x, y, z = Xform(cand["anchor"], 0).pos(0, 48 + 3, -5)
    wet = set_tiles(land, [(x, y, z)], "~")
    with pytest.raises(ValueError, match=r"no site clear of water below.*water below at z5"):
        sites._flooded([cand], wet, None, p, rects)
    assert sites._flooded([cand], land, None, p, rects)[0]["why"].startswith("x; no aquifer")


def test_a_revealed_cavern_near_the_dig_costs_score(land):
    best = bp.rank(land, "fortcore", n=3)[0]
    x, y, z = Xform(best["anchor"], best["rot"]).pos(0, 48 + 3, -5)
    s = copy.deepcopy(land)
    s["marks"] = {"cavern": [[x, y, z]]}
    got = bp.rank(s, "fortcore", n=3)
    assert got[0]["anchor"] != best["anchor"] or got[0]["score"] <= best["score"] - sites.CAV_PENALTY
    hit = [g for g in got if g["anchor"] == best["anchor"]]
    assert not hit or f"cavern near z{z}" in hit[0]["why"]


def test_p_aquifer_modes_choose_their_levels_themselves(land):
    s = _with_aq(land, z6=40)
    got = bp.rank(s, "fortcore", {"aquifer": "above"}, n=3)             # none of the new notes: aquifer_ok decides
    assert all("aquifer at" not in g["why"] and "no aquifer" not in g["why"] for g in got) or not got


def test_rooms_keep_off_the_levels_a_snapshot_shows_wet():
    cands = [{"box": (0, 0, 5, 3, 3, 5)}, {"box": (0, 0, 9, 3, 3, 9)}]
    assert sites.aquifer_ok(cands, "farms", {}, {}, {"v": 2}) == cands
    keep = sites.aquifer_ok(cands, "farms", {}, {}, {"v": 2}, {"aqz": {"z5": 3}})
    assert keep == cands[1:]
    heavy = {"v": 2, "breaches": [_breach([1, 1, 9], "heavy_aquifer")]}
    assert sites.aquifer_ok(cands, "farms", {}, {}, heavy, None) == cands[:1]
    assert sites.RANK_V >= 4


# ---------------------------------------------------------------- BUG-360
def test_no_water_names_the_snapshot_box_and_whether_any_water_was_in_it():
    dry = bp.rank(terrain(river=False).snapshot(purpose="sites"), "fortcore", n=1)[0]["why"]
    assert "no water reachable (none revealed inside the snapshot box x0-99 y0-99" in dry and "a brook beyond it" in dry
    t = terrain(river=False).snapshot(purpose="sites")
    pool = set_tiles(t, [(40, 40, 10), (41, 40, 10), (40, 41, 10), (41, 41, 10)], "w")      # 4 tiles, inside the box
    why = bp.rank(pool, "fortcore", n=1)[0]["why"]
    assert "only 4 water tile(s) in the snapshot box" in why and "a puddle" in why


def test_a_brook_the_box_cuts_off_counts_even_when_short():
    t = terrain(river=False).snapshot(purpose="sites")
    edge = set_tiles(t, [(99, 50, 10), (99, 51, 10), (99, 52, 10), (98, 51, 10)], "w")      # 4 tiles at the x border
    best = bp.rank(edge, "fortcore", n=1)[0]
    assert "water" in best["why"] and "steps" in best["why"] and "no water reachable" not in best["why"]
    assert sites._water_bodies(edge, 8) == set()                          # not a body of its own accord
    assert len(sites._water_bodies(edge, 8, edge=True)) == 4


# ---------------------------------------------------------------- BUG-361
def _held(save, monkeypatch, owner_z, name="y373s0b0"):
    occ = cmd.Occupancy()
    occ.owner = {(x, y, owner_z): (name, "seal") for x in range(0, 100) for y in range(0, 100)}
    monkeypatch.setattr(cmd, "occupancy", lambda save_dir, skip=(): occ)
    return occ


def test_the_fortcore_ranking_keeps_only_sites_no_placed_project_holds(save, monkeypatch, land):
    plain, _ = cmd.rank_sites(save, "fortcore", snap=land, manifest={"v": 2})
    b = plain[0]
    occ = cmd.Occupancy()
    doc = mutation([("s.build", "dig", [(*Xform(b["anchor"], b["rot"]).pos(0, 3, -1), "d")])])
    doc.update(id="y373s0b0", tpl="seal")
    occ.add(doc)
    monkeypatch.setattr(cmd, "occupancy", lambda save_dir, skip=(): occ)
    got, _ = cmd.rank_sites(save, "fortcore", snap=land, manifest={"v": 2})
    assert got and all(g["anchor"] != b["anchor"] or g["rot"] != b["rot"] for g in got)
    assert len(got) == len(plain), "the list is filled up with free sites, not shortened"


def test_when_a_seal_holds_every_site_the_error_names_it(save, monkeypatch, land):
    _held(save, monkeypatch, 10)
    with pytest.raises(cmd.BpError, match=r"lie on or beside placed projects \(y373s0b0\).*seal's cancel drops only"):
        cmd.rank_sites(save, "fortcore", snap=land, manifest={"v": 2})
