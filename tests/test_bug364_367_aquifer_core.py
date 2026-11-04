"""Run 16a-d (new forts in a world with an aquifer almost everywhere), 04.11.2026.
BUG-364: no fortcore site anywhere (heavy_aquifer, cavern_lake, dig_lost); depth 1 was refused, nothing offered a shallower core.
BUG-365: 'dig_lost at 111,80,124' for anchor 66,80,127: no offset bug, the chunk is the civilian stair at v 45; DF had cancelled
the designation on an aquifer tile (the runner side: tests/lua/test_bug365_lost_aquifer.lua).
BUG-366: after bp.cancel `bp sites fortcore --fresh` said '0 ranked' for good: the kernel's default sites box shrank to the
remaining pieces (44 x 51 tiles on i1) and the 35 x 52 fortcore fitted nowhere; the draft kept the cancelled `fortcore@same`.
BUG-367: the explore build stood at depth 12 on an aquifer level and the check told the player to type p.depth=2."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema
from dfpilot.bp import fortcore, sites

sys.path.insert(0, str(Path(__file__).parent / "bp"))
from bp_fixtures import terrain  # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    (d / "bp").mkdir(exist_ok=True)
    yield d
    reset_paths()


def _bp(save, name, tpl="fortcore", anchor=(60, 70, 110), **params):
    (save / "bp" / f"{name}.json").write_text(json.dumps({"tpl": tpl, "anchor": list(anchor), "rot": 0, "params": params}),
                                             "utf-8")


def _clean(save):
    """No bp file and no manifest: no piece of the fort is known."""
    for f in (save / "bp").glob("*.json"):
        f.unlink()
    for name in (".manifest.json", "manifest.json"):
        (save / name).unlink(missing_ok=True)


# ---------------------------------------------------------------- BUG-364: depth 1
@pytest.mark.parametrize("rot", range(4))
def test_a_core_of_depth_one_is_a_valid_fort(rot):
    docs = bp.emit_all("fortcore", {"depth": 1}, {"id": "S1", "anchor": [100, 100, 130], "rot": rot})
    assert bp.validate(docs) == []
    assert docs[2]["manifest"]["refuge"]["anchor"][2] == 130 - 2 - 1 - 3            # ze - depth - refuge
    with pytest.raises(ValueError, match="depth"):
        bp.emit_all("fortcore", {"depth": 0}, {"id": "S1", "anchor": [100, 100, 130], "rot": 0})
    assert fortcore.PARAMS["depth"] == (3, 1, 12)


def test_shallower_core_names_the_depths_to_fall_back_to():
    assert cmd.shallower_core("fortcore", {"stage": 1}) == [2, 1]
    assert cmd.shallower_core("fortcore", {"stage": 1, "depth": 2}) == [1]
    assert cmd.shallower_core("fortcore", {"stage": 1, "depth": 1}) == []
    assert cmd.shallower_core("fortcore", {"stage": 1, "retrofit": 1}) == []
    assert cmd.shallower_core("fortcore", {"stage": 1, "aquifer": "pass"}) == []        # p.aquifer chooses its levels itself
    assert cmd.shallower_core("fortcore", {"stage": 2}) == []                           # later stages keep the core's depth
    assert cmd.shallower_core("farms", {"stage": 1}) == []


def test_place_falls_back_to_a_shallower_core_at_a_ranked_label(save, monkeypatch):
    asked = []

    def fake(save_dir, tpl, params, label, bp_id, occ, same, snap, need):
        asked.append((params or {}).get("depth"))
        if (params or {}).get("depth", 3) > 2:
            raise cmd.BpError("fortcore: all 3 candidate site(s) lie on or beside placed projects")
        return {"tpl": tpl, "params": params}
    monkeypatch.setattr(cmd, "_place", fake)
    doc = cmd.place(save, "fortcore", {"stage": 1}, "S1", "bpA")
    assert doc["params"]["depth"] == 2 and asked == [None, 2]
    assert "BUG-364" in cmd.PLACE_NOTES["bpA"] and "depth=2" in cmd.PLACE_NOTES["bpA"]
    asked.clear()
    with pytest.raises(cmd.BpError, match="lie on or beside"):                         # an explicit anchor is asked for
        cmd.place(save, "fortcore", {"stage": 1}, "A60_70_110_0", "bpB")
    assert asked == [None]
    monkeypatch.setattr(cmd, "_place", lambda *a: (_ for _ in ()).throw(cmd.BpError("fortcore: no valid site")))
    with pytest.raises(cmd.BpError, match=r"BUG-364: no shallower core \(depth 2/1\)"):
        cmd.place(save, "fortcore", {"stage": 1}, "S1", "bpC")


def test_a_later_stage_takes_the_depth_of_the_core_it_is_placed_on(save):
    _bp(save, "c1", anchor=(60, 70, 110), stage=1, depth=1, refuge=3)
    _bp(save, "c2", anchor=(90, 70, 110), stage=1, depth=4, refuge=5)
    got = cmd.core_params_of(save, "fortcore", [60, 70, 110], {"stage": 3})
    assert got == {"stage": 3, "depth": 1, "refuge": 3}
    assert cmd.core_params_of(save, "fortcore", [60, 70, 110], {"stage": 3, "depth": 2})["depth"] == 2     # explicit wins
    assert cmd.core_params_of(save, "fortcore", [90, 70, 110], {"stage": 2})["refuge"] == 5
    assert cmd.core_params_of(save, "fortcore", [60, 70, 110], {"stage": 1}) == {"stage": 1}              # stage 1 chooses
    assert cmd.core_params_of(save, "fortcore", [1, 1, 1], {"stage": 2}) == {"stage": 2}                  # no core there
    assert cmd.core_params_of(save, "farms", [60, 70, 110], {"stage": 2}) == {"stage": 2}
    # fortcore@same: the placed record names the anchor
    (save / "bp" / ".placed-fortcore.json").write_text(json.dumps({"anchor": [60, 70, 110], "rot": 0, "bp": "c1"}), "utf-8")
    doc = cmd.place(save, "fortcore", {"stage": 2}, cmd.SAME, "bpS", occ=cmd.Occupancy())
    assert doc["params"]["depth"] == 1 and doc["params"]["refuge"] == 3


def test_shallower_core_sites_offers_a_depth_that_clears_the_aquifer(save, monkeypatch):
    wet = [{"id": "S1", "why": "rot0; aquifer at z105,z107"}]
    dry = [{"id": "S1", "why": "rot0; no aquifer or water known on z104-108"}]
    seen = []

    def free(save_dir, tpl, params, snap=None, n=3, where=None, taken=None):
        seen.append(params["depth"])
        return ([] if params["depth"] == 2 else dry), "snap1", 1
    monkeypatch.setattr(cmd, "free_sites", free)
    assert cmd.shallower_core_sites(save, "fortcore", {"stage": 1}, have=wet) == (2 - 1, dry, "snap1", 1)
    assert seen == [2, 1]
    seen.clear()
    assert cmd.shallower_core_sites(save, "fortcore", {"stage": 1}, have=dry) is None and not seen
    seen.clear()
    assert cmd.shallower_core_sites(save, "fortcore", {"stage": 1}, have=[])[0] == 1          # nothing at 3: the first with sites


def test_the_draft_gives_a_new_core_the_shallower_depth_at_every_stage(save, monkeypatch):
    doc = {"year": 372, "notes": "", "seasons": [{"build": [{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}},
                                                            {"tpl": "fortcore", "site": "same", "p": {"stage": 2}}]},
                                                 {"build": [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]},
                                                 {"build": []}, {"build": []}]}
    wet = [{"id": "S1", "anchor": [1, 2, 3], "why": "aquifer at z105"}]
    monkeypatch.setattr(plan._cmd, "free_sites", lambda *a, **k: (wet, "s", 1))
    monkeypatch.setattr(plan._cmd, "shallower_core_sites",
                        lambda *a, **k: (2, [{"id": "S1", "anchor": [4, 5, 6], "why": "dry"}], "s", 1))
    lines = plan.fit_core_depth(save, doc, None)
    assert len(lines) == 1 and "depth 2 (BUG-364)" in lines[0] and "passes a known aquifer level" in lines[0]
    assert [b["p"]["depth"] for se in doc["seasons"] for b in se["build"]] == [2, 2, 2]
    assert "BUG-364" in doc["notes"]
    assert plan.fit_core_depth(save, doc, None) == []                      # a build with its depth is left alone
    kept = copy.deepcopy(doc)
    for se in kept["seasons"]:
        for b in se["build"]:
            b["p"].pop("depth")
    assert plan.fit_core_depth(save, kept, copy.deepcopy(kept)) == []     # builds of the applied plan are not changed


# ---------------------------------------------------------------- BUG-365
def test_chunk_8_far_from_the_anchor_is_the_civilian_stair_not_an_offset():
    """Run 16c i3: anchor 66,80,127 rot 3, 's1.dig chunk 8: designation at 111,80,124' (45 tiles from the anchor)."""
    d = bp.emit_all("fortcore", {}, {"id": "S1", "anchor": [66, 80, 127], "rot": 3})[0]
    hit = [i for i, ch in enumerate(d["stages"][0]["chunks"])
           if any((ch["pos"][0] + c[0], ch["pos"][1] + c[1], ch["pos"][2] + c[2]) in ((111, 80, 124), (111, 80, 123))
                  for c in ch["cells"])]
    assert hit == [8]
    stair = {c for c in cmd.bp_cells(d) if c[0] == 111 and c[1] == 80}
    assert stair == {(111, 80, z) for z in range(119, 126)}                     # refuge level up to the defense level
    civ = fortcore.CIV                                                          # (u, v) = (0, 45)
    assert civ == (0, 45) and 66 + civ[1] == 111                                # rot 3: v runs along +x


# ---------------------------------------------------------------- BUG-366: the sites box
def test_a_box_the_size_of_the_remaining_pieces_ranks_no_fortcore_site():
    small = terrain(w=44, h=51, river=False, trees=False).snapshot(purpose="sites")
    big = terrain(w=100, h=100, river=False, trees=False).snapshot(purpose="sites")
    assert bp.rank(small, "fortcore", n=3) == []                                # i1: all anchors 'outside box'
    assert bp.rank(big, "fortcore", n=3)
    assert "only 44 x 51 tiles" in cmd.box_hint(small, "fortcore") and "52 tiles round the fort" in cmd.box_hint(small, "fortcore")
    assert cmd.box_hint(big, "fortcore") == "" and cmd.box_hint(small, "farms") == "" and cmd.box_hint(None, "fortcore") == ""


def test_the_fresh_fortcore_box_reaches_round_the_fort_pieces(save):
    _clean(save)
    assert cmd.sites_box(save, "fortcore") is None                              # no piece known: the kernel's own box
    _bp(save, "y372s0b0", tpl="farms", anchor=(59, 96, 110))
    _bp(save, "y372s0b1", tpl="farms", anchor=(70, 82, 110))
    box = cmd.sites_box(save, "fortcore")
    assert box == [59 - cmd.CORE_PAD, 82 - cmd.CORE_PAD, 110 - cmd.CORE_DOWN, 70 + cmd.CORE_PAD, 96 + cmd.CORE_PAD,
                   110 + cmd.CORE_UP]
    assert schema.validate_args("snapshot", {"purpose": "sites", "bbox": box}) == []
    assert (box[3] - box[0] + 1) * (box[4] - box[1] + 1) * (box[5] - box[2] + 1) <= cmd.CORE_TILES
    assert cmd.sites_box(save, "farms") is None
    # the fortcore then fits: the box holds the 35 x 52 fort round any anchor of the pieces
    assert box[3] - box[0] + 1 >= 35 + 2 * 11 and box[4] - box[1] + 1 >= 52 + 2 * 14


def test_a_far_flung_fort_shrinks_the_pad_or_leaves_the_box_to_the_kernel(save):
    _clean(save)
    _bp(save, "a", tpl="farms", anchor=(100, 100, 100))
    _bp(save, "b", tpl="farms", anchor=(200, 160, 104))
    box = cmd.sites_box(save, "fortcore")
    assert box is not None and box[0] == 100 - 40                                  # 52 is over the cap, 40 fits
    assert (box[3] - box[0] + 1) * (box[4] - box[1] + 1) * (box[5] - box[2] + 1) <= cmd.CORE_TILES
    _bp(save, "c", tpl="farms", anchor=(700, 700, 110))
    assert cmd.sites_box(save, "fortcore") is None                                 # spread over the map: the kernel's box


def _prev(year, builds):
    return {"v": 2, "year": year, "phase_target": "P0", "policy": {"option": "B", "pop_ceiling": 50, "beauty": "none"},
            "seasons": [{"build": builds}, {"build": []}, {"build": []}, {"build": []}], "military": {
                "pct": 15, "squads": {"melee": 1, "xbow": 0}, "cv_min": 12, "training": True},
            "supply": {"drink_d": 170, "food_d": 60, "mood_stock": 10}, "orders": {"import": []}, "trade": {"want": [], "sell": []}}


def test_a_cancelled_core_is_not_done_for_the_draft(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"], s["proj"] = "P0", []
    s["t"] = {**(s.get("t") or {}), "y": 372, "season": 1}
    fort = dict(plan.fort_facts(save, s), z4=False, core_any=False, core_dig=False)
    prev = _prev(372, [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}])
    keys = plan.stale_core_keys(prev, set(), fort, s)
    assert keys == {("fortcore", 3)}
    assert plan.stale_core_keys(prev, {("fortcore", 3)}, fort, s) == set()                    # a project stands behind it
    assert plan.stale_core_keys(prev, set(), dict(fort, core_any=True), s) == set()           # a core is on file
    assert plan.stale_core_keys(prev, None, fort, s) == set() and plan.stale_core_keys(None, set(), fort, s) == set()
    later = _prev(372, [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}])
    later["seasons"][3]["build"], later["seasons"][0]["build"] = later["seasons"][0]["build"], []
    assert plan.stale_core_keys(later, set(), fort, s) == set(), "a build of a later season is not placed yet, not stale"
    doc = plan.propose(s, plan.load_phases(), prev, decisions={}, applied=set(), fort=fort)
    cores = [(b["site"], (b.get("p") or {}).get("stage")) for se in doc["seasons"][1:] for b in se["build"]
             if b["tpl"] == "fortcore"]
    assert cores == [("S1", 1)], "the draft starts the core again at a ranked site, no stage @same on a vanished anchor"
    assert schema.validate("plan", doc) == []


# ---------------------------------------------------------------- BUG-367
def test_the_automatic_plan_fits_the_explore_depth_too(save, monkeypatch):
    calls = []
    monkeypatch.setattr(plan, "fit_explore", lambda sd, doc, prev: calls.append(doc["year"]))
    s = copy.deepcopy(files.read_state(save))
    plan.auto_plan(save, s)
    assert calls, "follow's auto_plan fitted nothing: its explore stayed at depth 12 (Run 16b y378)"
