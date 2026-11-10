"""Round 41 misc (Run 16, 10.11.2026; BUG numbers 645-650). The Lua halves are in tests/lua/test_kern_perf.lua (BUG-645),
test_siege_strand_noise.lua (BUG-646), test_bug544_547_stone_manager.lua (BUG-648) and test_embark_bug649.lua (BUG-649); here the
Python halves: the doctor does not blame the kernel for a host sleep (BUG-645), an aquifer cistern at an explicit anchor passes the
ranking's test (BUG-647), a dry refuge no build can fix holds no ceiling (BUG-650)."""
import copy
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, doctor, files, plan
from dfpilot.bp import sites

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402

HEADER = "wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


# ---------------------------------------------------------------- BUG-645
def test_a_host_sleep_gap_is_no_kernel_problem(save):
    lines, wall, tick = [HEADER], 1791676800, 1_000_000
    for gap_max, gaps3, mods in ((35186000, 1, "sense=40;gap:sleep=35186000;gapn:sleep=1"), (400, 0, "sense=40")):
        lines.append(f"{wall},{tick},PEACE,460,5,150,3000,12,{gap_max},{gaps3},{mods}")
        wall, tick = wall + 30, tick + 30 * 460
    (Path(save) / "perf.csv").write_text("\n".join(lines) + "\n", encoding="utf-8")
    out, bad = doctor.diagnose(save)
    assert any("sleep 1 (35186 s)" in x for x in out), out
    assert not any("frame gap" in b for b in bad), bad


# ---------------------------------------------------------------- BUG-647
def test_an_aquifer_cistern_at_an_explicit_anchor_must_be_a_site_of_the_ranking(save, monkeypatch):
    seen = {}

    def refuse(_d, tpl, params, snap, n=3, manifest=None, where=None):
        seen["where"], seen["params"] = where, params
        raise cmd.BpError("cistern water=aquifer: no site with its basin on an aquifer level (z141,z142,z143) under a dry room level")
    monkeypatch.setattr(cmd, "rank_sites", refuse)
    with pytest.raises(cmd.BpError, match=r"cistern@A106_48_146.*basin.*aquifer level.*BUG-647.*would stay dry.*no site with its basin"):
        cmd.anchor_checked(save, "cistern", {"water": "aquifer"}, [106, 48, 146], {"id": "s"})
    assert seen["where"] == {"at": [106, 48, 146]} and seen["params"] == {"water": "aquifer"}
    monkeypatch.setattr(cmd, "rank_sites", lambda *a, **k: [{"id": "S1"}])
    cmd.anchor_checked(save, "cistern", {"water": "aquifer"}, [106, 48, 143], {"id": "s"})           # the ranking offers it: placed
    monkeypatch.setattr(cmd, "rank_sites", refuse)
    cmd.anchor_checked(save, "cistern", {"path": "1,6;1,9"}, [106, 48, 146], {"id": "s"})          # a piped cistern: not this test


def test_aquifer_well_refuses_a_basin_off_the_aquifer_levels():
    snap = {"marks": {"damp": []}}
    man = {"aquifer_levels": [141, 142, 143]}
    cands = [{"anchor": [106, 48, 146], "rot": 0, "score": 1, "why": "x", "box": [0, 0, 0, 1, 1, 1]},
             {"anchor": [106, 48, 144], "rot": 0, "score": 1, "why": "x", "box": [0, 0, 0, 1, 1, 1]}]
    out = sites.aquifer_well(cands, snap, man)
    assert [c["anchor"][2] for c in out] == [144], out        # basin z143 is an aquifer level, z146's basin z145 is none
    with pytest.raises(ValueError, match="no site with its basin on an aquifer level"):
        sites.aquifer_well(cands[:1], snap, man)


# ---------------------------------------------------------------- BUG-650
def world(save, pop=48):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P5"
    s["pop"] = dict(s.get("pop") or {}, cit=pop, soldiers=10)
    s["ready"] = {"lvl": 0, "worn": 80, "cv": 8, "drill_age": -1, "fail": ["refuge_dry"],
                  "audit": {"ok": 1, "age": 900, "min_traps": 30}}
    s["mil"] = {"soldiers": 10, "worn": 80, "squads": 3, "cv": 8, "kit": {"n": 10, "full": 10, "armor": 10, "weapon": 10}}
    s["traps"] = {"m": 30, "n": 30}
    return s


def test_a_dry_refuge_no_build_can_fix_holds_no_ceiling(save):
    s = world(save)
    assert plan.defense_gaps(s) == ["refuge_dry"]                                # no fort facts: the hold as before
    assert plan.defense_cap(s, 100) == 48
    buildable = {"refuge": {"drink_fit": 9, "drink": 0, "drink_room": False, "stage3": False}}
    assert plan.defense_gaps(s, buildable) == ["refuge_dry"] and plan.defense_cap(s, 100, buildable) == 48
    nosite = {"refuge": {"drink_fit": 0, "drink": 0, "drink_room": False, "stage3": False,
                         "drink_why": "refuge_drink: the refuge room is missing in the manifest"}}
    assert "refuge room is missing" in plan.refuge_unbuilt(s, nosite)
    assert plan.defense_gaps(s, nosite) == []                                    # (propose applies defense_cap only with gaps)
    assert plan.defense_on(s, "P5", nosite) == []
    assert "BUG-650" in plan.refuge_free_note(s, nosite) and plan.refuge_free_note(s, buildable) == ""
    for k, v in (("drink", 4), ("drink_room", True), ("stage3", True)):         # a store, a room, a stage 3 under way: still a gap
        under_way = {"refuge": dict(nosite["refuge"], **{k: v})}
        assert plan.refuge_unbuilt(s, under_way) is None
        assert plan.defense_gaps(s, under_way) == ["refuge_dry"]
    s["mil"]["worn"] = 38                                                        # the other gaps hold as before
    assert plan.defense_gaps(s, nosite) == ["armor worn 38 %"]
