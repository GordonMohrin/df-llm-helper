"""Run 16c site97 (i3, 04.11.2026).
BUG-352: all 13 citizens stood in walk group 1562; `bp sites fortcore` ranked S3 [72,128,125] and S2 [58,128,125] on the
other side of the brook (group 1), the project on [58,128,125] stood 30 d at s1.dig 0 % ('unreachable DigChannel'). The
kernel's sites export now carries the citizens' walk group per walkable tile (snapshot `wg`), the ranking drops sites whose
anchor lies in another group and shows the group; the runner names a dig stage no citizen reaches after 3 days
(tests/lua/test_bug352_unreachable.lua).
BUG-354: propose in year 1 asked for farms@S1 / dining / bedrooms (ERROR 'no soil marks', 'no refuge') while the placed
fortcore's stage 1 had dug nothing; the year-1 plan is the fortcore stage 1 and the seal (PLAYBOOK 3a)."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, files, plan, schema, wake

sys.path.insert(0, str(Path(__file__).parent / "bp"))
from bp_fixtures import terrain  # noqa: E402


@pytest.fixture(scope="module")
def land():
    return terrain().snapshot(purpose="sites")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


HOME = 1562


def _with_groups(snap, far=()):
    """snap with a wg: every tile '1' (the citizens' group), the tiles of `far` '0' (another walk group)."""
    s = copy.deepcopy(snap)
    x0, y0 = s["bbox"][:2]
    rows = {k: [list("1" * len(r)) for r in v] for k, v in s["rows"].items()}
    for x, y, z in far:
        rows[f"z{z}"][y - y0][x - x0] = "0"
    s["wg"] = {"home": HOME, "rows": {k: ["".join(r) for r in v] for k, v in rows.items()}}
    return s


# ---------------------------------------------------------------- BUG-352: the ranking
def test_a_snapshot_with_walk_groups_validates_and_a_bad_one_does_not(land):
    s = _with_groups(land)
    assert schema.validate("snapshot", s) == []
    bad = copy.deepcopy(s)
    k = next(iter(bad["wg"]["rows"]))
    bad["wg"]["rows"][k][0] += "1"
    assert schema.validate("snapshot", bad) != []
    bad = copy.deepcopy(s)
    bad["wg"]["rows"][k][0] = "x" * len(bad["wg"]["rows"][k][0])
    assert schema.validate("snapshot", bad) != []


def test_fortcore_sites_beyond_the_brook_are_dropped_and_the_rest_name_the_walk_group(land):
    plain = bp.rank(land, "fortcore", n=5)
    assert len(plain) >= 3 and all("walk" not in s for s in plain)
    far = [plain[0]["anchor"], plain[1]["anchor"]]
    snap = _with_groups(land, far)
    sites = bp.rank(snap, "fortcore", n=5)
    assert sites and all(s["anchor"] not in far for s in sites), (far, [s["anchor"] for s in sites])
    assert all(s["walk"] == HOME and s["why"].endswith(f"; walk group {HOME}") for s in sites)
    # no filter without walk groups (an older export): the same ranking as before
    assert [s["anchor"] for s in bp.rank(land, "fortcore", n=5)] == [s["anchor"] for s in plain]


def test_every_site_beyond_the_brook_says_so(land):
    snap = _with_groups(land)
    snap["wg"]["rows"] = {k: ["0" * len(r) for r in v] for k, v in snap["wg"]["rows"].items()}
    with pytest.raises(ValueError) as e:
        bp.rank(snap, "fortcore", n=5)
    assert f"walk group {HOME}" in str(e.value) and "cannot reach" in str(e.value)


def test_a_tile_without_a_read_group_claims_nothing(land):
    plain = bp.rank(land, "fortcore", n=3)
    snap = _with_groups(land)
    x0, y0 = snap["bbox"][:2]
    x, y, z = plain[0]["anchor"]
    r = snap["wg"]["rows"][f"z{z}"]
    r[y - y0] = r[y - y0][:x - x0] + "-" + r[y - y0][x - x0 + 1:]
    sites = bp.rank(snap, "fortcore", n=3)
    assert sites[0]["anchor"] == plain[0]["anchor"] and "walk" not in sites[0]


def test_the_sites_cache_is_ranked_again_for_the_new_rules():
    from dfpilot.cmd import load_bp
    assert load_bp("sites").RANK_V >= 3


# ---------------------------------------------------------------- BUG-352: the player's hint
def test_the_unreachable_event_has_a_hint_with_the_safe_cancel():
    d = {"proj": "c1a1a6ad31b228f901", "tpl": "fortcore", "why": "unreachable", "unreach": 4, "stage": "s1.dig",
         "cmd": "dfllm cmd bp.cancel proj=c1a1a6ad31b228f901"}
    h = wake.next_hint("PROJECT_BLOCKED", {"d": d})
    assert "bp.cancel" in h and "dfllm bp sites fortcore --fresh" in h and "safe" in h


# ---------------------------------------------------------------- BUG-354: propose in year 1
def test_core_digging_needs_a_fortcore_project_at_its_first_dig(save):
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / "c1a1a6ad31b228f901.json").write_text(json.dumps({"tpl": "fortcore", "params": {"stage": 1}}), "utf-8")
    (save / "bp" / "y1s0b1.json").write_text(json.dumps({"tpl": "bedrooms", "params": {}}), "utf-8")
    assert plan.core_digging(save, {"proj": [["c1a1a6ad31b228f901", "s1.dig", 0, "stalled"]]}) is True
    assert plan.core_digging(save, {"proj": [["c1a1a6ad31b228f901", "s1.build", 10, ""]]}) is False
    assert plan.core_digging(save, {"proj": [["y1s0b1", "s1.dig", 0, ""]]}) is True          # BUG-363: placed, no row yet
    assert plan.core_digging(save, {"proj": [["c1a1a6ad31b228f901", "s1.dig", 0, "breach:damp"]]}) is False
    (save / "bp" / "c1a1a6ad31b228f901.json").unlink()
    assert plan.core_digging(save, {"proj": []}) is False          # no fortcore project at all


def _p0_state(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P0"
    s["proj"] = []
    return s


def test_year_one_with_the_placed_core_still_digging_drafts_no_rooms(save):
    s = _p0_state(save)
    fort = {"z4": False, "core_any": True, "core_dig": True}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)}, fort=fort)
    built = [b for se in doc["seasons"] for b in se["build"]]
    assert all(b["tpl"] == "seal" for b in built), built               # old: farms, dining, bedrooms ...
    assert doc["phase_target"] == "P0"
    assert "BUG-354: fortcore stage 1 is still digging" in doc["notes"]
    assert doc["notes"].endswith("apply, wait for s1.dig, propose again")
    assert schema.validate("plan", doc) == []
    # the stage 1 is not drafted a second time; without a placed core it still is (BUG-197)
    fresh = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(),
                         fort={"z4": False, "core_any": False, "core_dig": False})
    assert {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}} in [b for se in fresh["seasons"] for b in se["build"]]
    # a dug floor: the usual draft
    full = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)},
                        fort={"z4": True, "core_any": True, "core_dig": False})
    assert any(b["tpl"] not in ("fortcore", "seal") for se in full["seasons"] for b in se["build"])
