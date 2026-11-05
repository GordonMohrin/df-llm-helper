"""BUG-450..456 (Run 16a i1 Syrupobeyed R5, Run 16b i2, Run 16c i3, Run 16d i4; round 28, operations).
450 zone.place works in a siege for the manager's office, wake hint for DECISION_NEEDED manager_stuck;
452 wake hint for DECISION_NEEDED lockdown_long;
453 explore tunnels keep EXPLORE_RING tiles from any revealed opening, the stair bypass advice names the explore;
454 a draft written before follow's MINIMAL plan is rebuilt on the applied plan (check / apply), propose says it builds on it;
455 `seal at=last` says why status still counts ways in that the snapshot has closed;
456 brief wording (postings, not citizens), phase.waive why up to 200 bytes, orders.import kept by propose, planned slots in the
    no-site hint (the Lua parts: tests/lua/test_economy_drink.lua, test_stations.lua, test_m3_lone.lua, test_bug440_trade_add.lua,
    test_zone_place.lua)."""
from __future__ import annotations

import copy
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths       # noqa: E402

from dfpilot import brief, cmd, files, plan, schema, wake                     # noqa: E402
from dfpilot.bp import mine, sites                                            # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


# ---------------------------------------------------------------- BUG-450 / BUG-452: contract and wake lines
def test_zone_place_is_allowed_in_a_siege_and_the_phase_waive_reason_may_be_200_bytes():
    assert "SIEGE" in schema.VERBS["zone.place"][1] and "BREACH" not in schema.VERBS["zone.place"][1]
    assert schema.validate_args("phase.waive", {"tpl": "hospital", "why": "x" * 200}) == []
    assert schema.validate_args("phase.waive", {"tpl": "hospital", "why": "x" * 201}) != []


def test_the_wake_lines_for_manager_stuck_and_lockdown_long_carry_the_facts_and_the_command():
    d = {"id": "manager_stuck", "days": 149, "n": 35, "cmds": ["dfllm cmd inspect what=unit key=77", "dfllm cmd inspect what=orders"]}
    h = wake.manager_stuck_hint(d)
    assert "149 days" in h and "35 orders" in h and "inspect what=unit key=77" in h and "zone.place type=office" in h
    cmdline = "dfllm cmd squad.sortie '{\"squad\":\"A\",\"target\":[1,2,3],\"approve\":true}'"
    h2 = wake.lockdown_long_hint({"id": "lockdown_long", "days": 151, "mode": "SIEGE", "n": 33, "inside": 0, "calm": 1,
                                  "cmd": cmdline, "worn": 85, "need": 80, "rec": 1})
    assert "151 days" in h2 and "33" in h2 and "all far" in h2 and "squad.sortie" in h2
    assert "no squad to send" in wake.lockdown_long_hint({"id": "lockdown_long", "days": 12, "mode": "BREACH", "n": 3})


# ---------------------------------------------------------------- BUG-453
def test_the_explore_tunnel_levels_keep_three_tiles_from_any_opening_the_footprint_box_stays():
    p = {"depth": 12, "arm": 6, "every": 3, "avoid": ""}
    tun = set(mine.tunnel_levels(p))
    assert tun and 0 not in tun
    wide, narrow = sites.explore_wide_rects(p), sites.explore_rects(p)
    assert set(wide) == tun and sites.EXPLORE_RING == 3
    for w, (r,) in wide.items():
        n = narrow[w][0]
        assert r == (n[0] - 2, n[1] - 2, n[2] + 2, n[3] + 2), (w, r, n)          # three tiles round the dug tiles, the box has one
    assert sites.explore_wide_rects({**p, "arm": 0}) == {}          # a plain shaft: nothing wider


def test_the_stair_bypass_advice_names_the_explore_shaft_and_the_waiver():
    a = cmd.route_advice("bypass: via stair 40,86,138 -> 40,85,138")
    assert "explore" in a and "bp.cancel" in a and "WAIVED" in a and "BUG-453" in a, a


# ---------------------------------------------------------------- BUG-454
def _doc(year, builds_by_season):
    return {"year": year, "seasons": [{"build": [dict(b) for b in se]} for se in builds_by_season] + [{"build": []}] * (4 - len(builds_by_season))}


def test_a_draft_written_before_follows_minimal_plan_is_rebuilt_on_it():
    seal = {"tpl": "seal", "site": "S1", "p": {"at": "last"}}
    hosp = {"tpl": "hospital", "site": "S1"}
    farms = {"tpl": "farms", "site": "S2"}
    applied = _doc(384, [[seal], [hosp], [], []])
    draft = _doc(384, [[farms], [], [], []])                     # written before follow applied the minimal plan
    assert plan.stable_ids(draft, applied), "the old failure: 'is applied as y384s0b0; keep it'"
    out, note = plan.rebase_on_applied(draft, applied)
    assert note.startswith("BUG-454") and "1 new build" in note
    assert plan.stable_ids(out, applied) == []
    assert out["seasons"][0]["build"] == [seal, farms] and out["seasons"][1]["build"] == [hosp]
    again, note2 = plan.rebase_on_applied(out, applied)           # a draft that keeps the applied builds is left alone
    assert note2 == "" and again == out
    other_year, note3 = plan.rebase_on_applied(_doc(385, [[farms]]), applied)
    assert note3 == "" and other_year["seasons"][0]["build"] == [farms]


def test_a_repeated_build_is_matched_by_count(save):
    e = {"tpl": "explore", "site": "S1"}
    applied = _doc(384, [[e], [e], [], []])
    draft = _doc(384, [[e], [], [], []])
    out, note = plan.rebase_on_applied(draft, applied)
    assert note and out["seasons"][0]["build"] == [e] and out["seasons"][1]["build"] == [e]


def test_plan_check_rebuilds_the_draft_file_on_the_applied_plan(save, capsys, monkeypatch):
    st = files.read_state(save)
    year = st["t"]["y"]
    seal = {"tpl": "seal", "site": "S1", "p": {"at": "last"}}
    files.write_json_atomic(save / "plan.json", {**_valid_plan(year), "seasons": [{"build": [seal]}, {"build": []}, {"build": []},
                                                                                   {"build": []}]})
    draft = save / "my.json"
    files.write_json_atomic(draft, {**_valid_plan(year), "seasons": [{"build": []}] * 4})
    monkeypatch.setattr(plan, "applied_plan", lambda sd: files.read_json(Path(sd) / "plan.json"))
    import argparse
    args = argparse.Namespace(action="check", file=str(draft), phases=None, by="llm", wait=0.1, dry_run=True)
    plan.run(args, save)
    out = capsys.readouterr().out
    assert "BUG-454" in out, out
    assert files.read_json(draft)["seasons"][0]["build"] == [seal]


def _valid_plan(year):
    return {"v": 2, "year": year, "policy": {"option": "A", "pop_ceiling": 55, "beauty": "none"}, "phase_target": "P0",
            "seasons": [{"build": []}] * 4, "military": {"pct": 15, "squads": {"melee": 1, "xbow": 0}, "cv_min": 8},
            "supply": dict(schema.PLAN_DEFAULTS["supply"]), "orders": {"import": []},
            "trade": {"want": ["bar:iron"], "sell": ["crafts"]}, "notes": "test"}


# ---------------------------------------------------------------- BUG-456
def test_propose_keeps_the_order_libraries_of_the_applied_plan_when_it_has_none_of_its_own(save, monkeypatch):
    st = files.read_state(save)
    prev = {**_valid_plan(st["t"]["y"]), "orders": {"import": ["library/basic", "library/rockstock", "library/furnace"]}}
    fort = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True, "stone_dig": False}
    ph = copy.deepcopy(plan.load_phases())
    for p in ph["phases"]:                                         # a phase list whose phases name no library (the waive jumped past them)
        p["deliver"] = [d for d in p["deliver"] if d["k"] != "orders"]
    doc = plan.propose(st, ph, prev, decisions={}, applied=set(), fort=fort)
    assert doc["orders"]["import"] == prev["orders"]["import"], doc["orders"]
    none = plan.propose(st, ph, None, decisions={}, applied=set(), fort=fort)
    assert none["orders"]["import"] == []


def test_the_brief_calls_labor_postings_postings_and_status_keeps_hungry_for_citizens():
    txt = brief.idle_clause({"idle": 20, "starving": 53})
    assert "unfilled labor postings 53" in txt and "starving" not in txt, txt
    full = brief.idle_clause({"idle": 54, "starving": 0, "n": 13, "why": {"rest": 2}, "held": 0})
    assert full.endswith("unfilled labor postings 0"), full


def test_the_no_site_hint_says_a_planned_slot_of_the_same_template_is_yours(save):
    st = files.read_state(save)
    files.write_json_atomic(save / "bp" / "y372s3b2.json", {"tpl": "workshops", "id": "y372s3b2"})
    st["proj"] = []
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    hint = cmd.no_site_hint(save, "workshops", "s1", 3, ["y372s3b2"], {"only": "Kitchen"})
    assert "taken by y372s3b2" in hint and "planned workshops (not begun)" in hint and "bp.cancel proj=y372s3b2" in hint, hint
    files.write_json_atomic(save / "bp" / "y372s3b2.json", {"tpl": "farms", "id": "y372s3b2"})
    assert "planned" not in cmd.no_site_hint(save, "workshops", "s1", 3, ["y372s3b2"], {"only": "Kitchen"})


# ---------------------------------------------------------------- BUG-455
FORT = [".............",
        ".............",
        "##+.##.##.###",
        "##..##.##.###",
        "#...........#",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 5


def test_seal_closed_says_status_still_counts_the_ways_the_snapshot_has_closed(save):
    now = files.read_state(save)["t"]["abs"]
    snap = {**tiny([FORT, ROOF]), "id": "s455", "tick": now - 60, "purpose": "sites"}
    files.write_json_atomic(save / "snap" / "s455.json", snap)
    append_events(save, [ev(9001, "SIEGE_UNREADY", "u", {"fails": ["open_perimeter"], "routes": 1, "open": 1, "ents": ["2,2,0 floor"],
                                                         "traps": 0}, tick=now - 50)])
    st = files.read_state(save)
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 100, "min_traps": 0},
                   "fail": ["open_perimeter"], "open": 1}
    st["seq"] += 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    with pytest.raises(cmd.SealClosed) as ei:
        cmd.seal_openings(save, "last")
    msg = str(ei.value)
    assert "nothing to close" in msg and "status still counts 1 way in" in msg and "key=refresh" in msg, msg
