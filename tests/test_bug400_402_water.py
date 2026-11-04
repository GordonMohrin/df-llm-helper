"""BUG-400..402 (Run 16a Mansionlauded y372-373, and the first i1 fort Bachwald: 13 of 16 dead of thirst).
BUG-400: `bp sites fortcore` ranked S1 110,62,159 'water 1 steps' (score 1029) over a frozen river: the walkable ice floor
above the water counted as the brook top; the step count also crossed into other walk groups. The sites export now lists
the ice (snapshot `ice`), water_steps gives no bank over it and walks the citizens' group only.
BUG-401: the early drink check (kernel: tests/lua/test_bug400_402_water.lua) reaches the wake line and the plan's first note.
BUG-402: dying of thirst with drink 0 is the line under the clock in status and brief."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, brief, files, plan, schema, wake
from dfpilot.bp import sites
from dfpilot.bp.topo import Graph

sys.path.insert(0, str(Path(__file__).parent / "bp"))
from bp_fixtures import terrain  # noqa: E402


def snap_of(z0, rows_by_z, **extra):
    """A tiny snapshot: rows_by_z = {z: ['row', ...]} (same width and height on every level)."""
    zs = sorted(rows_by_z)
    h, w = len(rows_by_z[zs[0]]), len(rows_by_z[zs[0]][0])
    doc = {"v": 2, "id": "t1", "tick": 1, "purpose": "sites", "bbox": [0, 0, zs[0], w - 1, h - 1, zs[-1]],
           "rows": {f"z{z}": rows_by_z[z] for z in zs}, "bridges": {}, "traps": []}
    doc.update(extra)
    return doc


# a river 3 tiles wide on z0 between rock; z1 is the surface over it
RIVER = {0: ["#~~~#", "#~~~#"], 1: [".....", "....."]}


def test_ice_over_water_is_no_bank_water_over_nothing_is():
    snap = snap_of(0, RIVER)
    g = Graph(snap)
    open_water = sites.water_steps(g, sites._water_bodies(snap, 1))
    assert open_water and min(open_water.values()) == 0, "the brook top over the river: a bank (as before)"
    iced = {**snap, "ice": [[x, y, 1] for x in (1, 2, 3) for y in (0, 1)]}
    assert sites.ice_tiles(iced) == {(x, y, 1) for x in (1, 2, 3) for y in (0, 1)}
    assert sites.water_steps(g, sites._water_bodies(iced, 1), sites.ice_tiles(iced)) == {}, \
        "old code: every floor tile 0-1 steps from 'water' under the ice"
    # ice on part of the river: the open part still gives banks above it
    half = {**snap, "ice": [[1, 0, 1], [1, 1, 1]]}
    d = sites.water_steps(g, sites._water_bodies(half, 1), sites.ice_tiles(half))
    assert d and g.idx((2, 0, 1)) in d and d[g.idx((2, 0, 1))] == 0


def test_water_steps_walks_the_citizens_group_only():
    snap = snap_of(0, {0: ["..~.."]}, wg={"home": 7, "rows": {"z0": ["11-00"]}})
    g = Graph(snap)
    bodies = sites._water_bodies(snap, 1)
    far = sites.other_group(snap, g)
    assert far is not None and [i for i in range(g.N) if far[i]] == [3, 4]
    plain = sites.water_steps(g, bodies)
    assert plain[g.idx((3, 0, 0))] == 0 and plain[g.idx((0, 0, 0))] == 1
    mine = sites.water_steps(g, bodies, None, far)
    assert set(mine) == {g.idx((0, 0, 0)), g.idx((1, 0, 0))}, "no bank and no step on the far side"
    assert sites.other_group(snap_of(0, {0: ["..~.."]}), g) is None, "no wg (audit export): not filtered"


def test_fortcore_over_a_frozen_river_says_so_and_scores_no_water_bonus():
    land = terrain().snapshot(purpose="sites")
    bodies = sites._water_bodies(land, 8, edge=True)
    before = bp.rank(land, "fortcore", n=1)[0]
    assert "water 3 steps" in before["why"]
    # the exporter writes a frozen tile as an ice floor ('.') and lists it; its flow no longer makes it '~'
    iced = copy.deepcopy(land)
    x0, y0 = land["bbox"][:2]
    for x, y, z in bodies:
        r = iced["rows"][f"z{z}"]
        r[y - y0] = r[y - y0][:x - x0] + "." + r[y - y0][x - x0 + 1:]
    iced["ice"] = [list(t) for t in sorted(bodies)]
    assert schema.validate("snapshot", iced) == []
    after = bp.rank(iced, "fortcore", n=3)
    assert after and all("steps" not in s["why"].split(",")[1] for s in after), [s["why"] for s in after]
    assert all("is frozen" in s["why"] for s in after), after[0]["why"]
    assert after[0]["score"] < before["score"]
    # water under an ice roof (the Mansionlauded case): the message counts the covered tiles
    roofed = copy.deepcopy(land)
    roofed["ice"] = [[x, y, z + 1] for x, y, z in bodies]
    assert "lie under ice" in sites._no_water(roofed, bodies, len(bodies), sites.ice_tiles(roofed))


def test_fortcore_water_steps_stay_on_the_citizens_walk_group():
    land = terrain().snapshot(purpose="sites")
    x0, y0 = land["bbox"][:2]
    rows = {k: [list("1" * len(r)) for r in v] for k, v in land["rows"].items()}
    for k in rows:                                                          # the river side (x >= 70) is another walk group
        for r in rows[k]:
            for x in range(70 - x0, len(r)):
                r[x] = "0"
    snap = {**land, "wg": {"home": 5, "rows": {k: ["".join(r) for r in v] for k, v in rows.items()}}}
    assert schema.validate("snapshot", snap) == []
    top = bp.rank(snap, "fortcore", n=3)
    assert top and all(s["anchor"][0] < 70 for s in top)
    assert all("no water reachable" in s["why"] for s in top), [s["why"] for s in top]   # old: 'water 13 steps' across the far group


def test_snapshot_ice_key_is_in_the_contract():
    land = terrain().snapshot(purpose="sites")
    ok = {**land, "ice": [[1, 2, 3]]}
    assert schema.validate("snapshot", ok) == []
    assert schema.validate("snapshot", {**land, "ice": [[1, 2]]}) != []
    assert schema.validate("snapshot", {**land, "ice": [[0, 0, 0]] * 8001}) != []
    assert sites.RANK_V >= 6


# ---------------------------------------------------------------- BUG-401 / BUG-402
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **keys):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        st = json.loads(p.read_text("utf-8"))
        for k, v in keys.items():
            if isinstance(v, dict) and isinstance(st.get(k), dict):
                st[k].update(v)
            else:
                st[k] = v
        assert schema.validate("state", st) == [], schema.validate("state", st)
        p.write_text(files.dumps(st), encoding="utf-8")


def test_no_water_is_urgent_and_carries_its_commands_to_the_wake_line():
    assert "no_water" in wake.URGENT_DECISIONS
    e = {"type": "DECISION_NEEDED", "d": {"id": "no_water", "q": "q", "cmds": ["dfllm cmd inspect what=water_sources", "x"]}}
    assert wake.urgent_game(e)
    assert "inspect what=water_sources" in wake.next_hint("DECISION_NEEDED", e)
    d = {"id": "no_water", "q": "q", "drink": 40, "cmds": ["dfllm cmd inspect what=water_sources"], "water": ["zone it"],
         "auto": ["gatherers"]}
    assert schema.validate("event", {"n": 1, "tick": 1, "type": "DECISION_NEEDED", "cls": "A", "msg": "m", "d": d}) == []


def test_plan_propose_names_the_missing_water_first():
    assert plan.no_water_note({"stock": {"dwhy": "no brew order"}}) is None
    assert plan.no_water_note(None) is None
    note = plan.no_water_note({"stock": {"dwhy": "no reachable water; no brew order"}})
    assert note.startswith("BUG-401") and "no_water" in note and "before every build" in note
    s = {"stock": {"dwhy": "no reachable water", "drink_d": 48, "food_d": 90}, "phase": "P1", "proj": []}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort={})
    assert doc["notes"].startswith("BUG-401"), doc["notes"][:120]
    assert plan.propose({**s, "stock": {"drink_d": 48, "food_d": 90}}, plan.load_phases(), None, decisions={}, applied=set(),
                        fort={})["notes"].startswith("BUG-401") is False


def test_status_and_brief_show_the_thirst_deaths_first(save):
    put_state(save, stock={"drink_d": 0, "dwhy": "no reachable water; 4 stranded without drink (group 1577)"},
              care={"died": {"dehydrated": 13}})
    out = brief.status_text(save)
    lines = out.splitlines()
    assert lines[1].startswith("DYING OF THIRST: drink 0d, 13 dead of dehydration this month: no reachable water"), out
    assert "inspect what=reach" in lines[1]
    b = brief.brief_text(save).splitlines()
    assert b[1].startswith("DYING OF THIRST")


def test_the_thirst_line_needs_drink_gone_and_deaths_or_dying_patients(save):
    put_state(save, stock={"drink_d": 60}, care={"died": {"dehydrated": 3}})
    assert brief.thirst_items(brief.Ctx(save, full=False)) == []                 # drink is there: not this line
    put_state(save, stock={"drink_d": 0}, care={"died": {}})
    assert brief.thirst_items(brief.Ctx(save, full=False)) == []                 # drink 0 and nobody dying yet
    put_state(save, stock={"drink_d": 0}, care={"died": {}},
              water={"patients": 2, "thirst_max": 61000, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 0, "hosp": 0, "src": []})
    t = brief.thirst_items(brief.Ctx(save, full=False))
    assert len(t) == 1 and t[0][0] == 1
    assert "2 patient(s) over thirst 50000" in t[0][1] and "no accepted water and no brewed drink" in t[0][1], t
