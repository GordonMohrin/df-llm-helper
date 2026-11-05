"""BUG-437..440 (Run 16a i1 Syrupobeyed R5 / Run 16d i4 Mazelanterns R4, round 27).
BUG-437: stone-fall traps hit citizens (3 killed in the hall, the fort's way out): propose / check / bp.place hold the hall and the
stone lanes while citizens go out for water or food or one died to our traps (state traps.ck).
BUG-438: a soil fort (state stock.rsoil) digs an explore shaft down to hard stone (24..16 levels, tunnels every 6) instead of a
bedrooms dig in soil, trade.want mechanism, stone first; the embark `stone` item warns from 3 levels of soil (lua tests).
BUG-440: trade.want add / remove (inbox schema); the plan notes stay under 2000 bytes (cap_notes)."""
from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema, traps


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _state(save, **over):
    s = copy.deepcopy(files.read_state(save))
    for k, v in over.items():
        s[k] = {**(s.get(k) or {}), **v} if isinstance(v, dict) else v
    files.write_json_atomic(save / "state.a.json", s)
    files.write_json_atomic(save / "state.b.json", s)
    return s


# ---------------------------------------------------------------- BUG-437
def test_trap_hold_names_why_and_is_none_when_the_fort_is_fed():
    ok = {"stock": {"drink_d": 120, "food_d": 90}, "water": {"src": [[1, 2, 3]]}}
    assert plan.trap_hold(ok) is None and plan.trap_hold({}) is None and plan.trap_hold(None) is None
    thirsty = plan.trap_hold({"stock": {"drink_d": 12, "food_d": 90}})
    assert thirsty and "drink 12 d" in thirsty
    killed = plan.trap_hold({**ok, "traps": {"n": 3, "m": 41, "ck": 3}})
    assert killed and "3 citizen(s) killed by our own traps" in killed
    assert "no accepted water" in plan.trap_hold({"stock": {"drink_d": 120}, "water": {"src": []}})


def test_the_draft_keeps_the_cage_lanes_and_drops_the_stone_ones_under_a_hold():
    fort = {"traps": {"open": 2, "ways": ["1,2,3"], "bopen": 1, "bways": ["O1"]}}
    both, _ = traps.draft(fort, "P6", [], None, 372, None, False)
    assert sorted(traps._word(b) for b in both) == ["bridges", "ways"]
    held, note = traps.draft(fort, "P6", [], None, 372, None, False, hold=True)
    assert [traps._word(b) for b in held] == ["ways"] and "bridge" not in note


def test_check_warns_for_the_hall_and_the_stone_lanes_while_the_hold_stands():
    doc = {"seasons": [{"build": [copy.deepcopy(plan.HALL), {"tpl": "traps", "site": "S1", "p": {"at": "bridges"}},
                                  {"tpl": "traps", "site": "S1", "p": {"at": "ways"}}]}, {"build": []}, {"build": []}, {"build": []}]}
    assert plan.trap_hold_gate(doc, {"stock": {"drink_d": 200, "food_d": 90}}) == []
    w = plan.trap_hold_gate(doc, {"stock": {"drink_d": 4}})
    assert len(w) == 2 and all("BUG-437" in x and "drink 4 d" in x for x in w), w
    assert any("fortcore" in x for x in w) and any("traps" in x and "bridges" in x for x in w)


def test_bp_place_refuses_the_hall_and_stone_lanes_but_not_cage_lanes_under_a_hold(save):
    _state(save, stock={"drink_d": 3, "food_d": 90})
    for tpl, p in (("fortcore", {"stage": 4}), ("traps", {"at": "bridges"}), ("traps", {"at": "hall"}),
                   ("traps", {"at": "b30,40,5:1,0 2,0"})):
        msg = cmd.stone_fall_refusal(save, tpl, p)
        assert "BUG-437" in msg and "drink 3 d" in msg, (tpl, p, msg)
    for tpl, p in (("fortcore", {"stage": 2}), ("fortcore", {}), ("traps", {"at": "ways"}), ("traps", {}), ("seal", {"at": "last"})):
        assert cmd.stone_fall_refusal(save, tpl, p) == "", (tpl, p)
    with pytest.raises(cmd.BpError, match="BUG-437"):
        cmd.send(save, "bp.place", {"tpl": "fortcore", "site": "same", "p": {"stage": 4}}, wait_s=0)
    _state(save, stock={"drink_d": 200, "food_d": 90}, water={"src": [[1, 2, 3]]})
    assert cmd.stone_fall_refusal(save, "fortcore", {"stage": 4}) == ""


def test_state_and_decision_schema_carry_ck(save):
    st = _state(save, traps={"n": 38, "m": 41, "ck": 3})
    assert schema.validate("state", st) == [], schema.validate("state", st)
    d = {"id": "trap_friendly", "q": "3 killed by our own traps in a year", "n": 3, "unit": 26667, "pos": [76, 106, 138],
         "cmds": ["dfllm cmd inspect what=reach"], "opts": ["drink inside"]}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []


# ---------------------------------------------------------------- BUG-438
def test_state_carries_rsoil(save):
    st = _state(save, stock={"rock": 0, "rock_need": 17, "rsoil": 1})
    assert schema.validate("state", st) == []
    assert plan.soil_fort(st) and not plan.soil_fort({"stock": {"rock": 0}}) and not plan.soil_fort(None)


def test_a_soil_fort_swaps_the_bedrooms_dig_for_an_explore_shaft_down_to_stone(save, monkeypatch):
    _state(save, stock={"rock": 0, "rock_need": 17, "rsoil": 1})
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [{"tpl": "farms", "site": "S1"}, copy.deepcopy(plan.STONE_DIG)]}, {"build": []}, {"build": []},
                      {"build": []}]
    doc["notes"] = "draft"
    seen = []

    def rank(save_dir, tpl, params=None, *a, **k):
        seen.append((tpl, dict(params or {})))
        if (params or {}).get("depth", 12) > 20:                       # the deepest asked: an avoided level
            raise cmd.BpError("explore: every anchor's shaft of depth reaches an avoided level (z120)")
        return [{"id": "S1", "anchor": [109, 102, 138], "rot": 1, "why": "rot1"}], "s1"
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 1)
    note = plan.soil_dig(save, doc, prev)
    b0 = doc["seasons"][0]["build"]
    assert [b["tpl"] for b in b0] == ["explore", "farms"], b0
    assert b0[0]["p"]["depth"] == 20 and b0[0]["p"]["every"] == plan.SOIL_EVERY, b0[0]
    assert seen[0][1]["depth"] == 24 and seen[1][1]["depth"] == 20 and seen[0][1]["every"] == plan.SOIL_EVERY, seen
    assert "BUG-438" in note and "depth 20" in note, note
    assert "BUG-438" in doc["notes"]
    assert plan.STONE_DIG not in [b for se in doc["seasons"] for b in se["build"]]
    assert schema.validate("plan", doc) == []


def test_a_fort_that_is_not_soil_keeps_the_bedrooms_dig_and_the_default_depths(save, monkeypatch):
    _state(save, stock={"rock": 0, "rock_need": 17})
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [copy.deepcopy(plan.STONE_DIG), {"tpl": "explore", "site": "S1"}]}, {"build": []}, {"build": []},
                      {"build": []}]
    doc["notes"] = "draft"
    seen = []

    def rank(save_dir, tpl, params=None, *a, **k):
        seen.append(dict(params or {}))
        return [{"id": "S1", "anchor": [1, 2, 3], "rot": 0, "why": "w"}], "s1"
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 1)
    assert plan.soil_dig(save, doc, prev) == ""
    plan.fit_explore(save, doc, prev)
    assert seen[0] == {"depth": 12} and plan.STONE_DIG in doc["seasons"][0]["build"]


def test_propose_puts_mechanism_and_stone_first_in_a_soil_fort(save):
    s = _state(save, stock={"rock": 0, "rock_need": 17, "rsoil": 1})
    fort = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True, "stone_dig": False}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert doc["trade"]["want"][:2] == ["mechanism", "stone"], doc["trade"]
    assert "BUG-438" in doc["notes"]
    s2 = _state(save, stock={"rock": 0, "rock_need": 17, "rsoil": 0})
    doc2 = plan.propose(s2, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert doc2["trade"]["want"][:2] != ["mechanism", "stone"]


# ---------------------------------------------------------------- BUG-440
def test_trade_want_takes_add_and_remove():
    assert schema.validate_args("trade.want", {"add": ["bone", "stone"], "remove": ["anvil"]}) == []
    assert schema.validate_args("trade.want", {"sell_add": ["gem"], "sell_remove": ["crafts"], "want": ["bar:iron"]}) == []
    assert schema.validate_args("trade.want", {"add": ["Bone"]}) != [] and schema.validate_args("trade.want", {"add": "bone"}) != []
    assert schema.validate_args("trade.want", {"bogus": []}) != []
    # the kernel's own suggestions add, they no longer replace the list
    root = Path(cmd.__file__).resolve().parent.parent / "lua" / "dfllm"
    for name in ("care.lua", "economy.lua"):
        src = (root / name).read_text("utf-8")
        assert "trade.want '{\"add\":[" in src and "trade.want '{\"want\":[" not in src, name


def test_cap_notes_cuts_the_notes_under_2000_bytes_and_says_so():
    short = {"notes": "draft; BUG-1: x"}
    assert plan.cap_notes(short) is False and short["notes"] == "draft; BUG-1: x"
    notes = "; ".join(f"BUG-370: tpl{i}@S1 left out: every candidate site lies in a walk group the citizens cannot reach"
                      for i in range(30))
    assert len(notes.encode()) > 2000
    doc = {"notes": notes + " äöü" * 200}
    assert plan.cap_notes(doc) is True
    out = doc["notes"]
    assert len(out.encode()) <= 2000 and out.endswith(" bytes written)") and "BUG-440" in out
    assert out.startswith("BUG-370: tpl0@S1") and "; BUG-370: tpl1@S1" in out
    assert plan.cap_notes({"notes": 5}) is False


def test_a_capped_draft_passes_its_own_check(save):
    s = _state(save)
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(),
                       fort={"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True, "stone_dig": False})
    doc["notes"] += "; " + "; ".join(f"BUG-370: t{i}@S1 left out: no site" for i in range(200))
    assert schema.validate("plan", doc) != []
    plan.cap_notes(doc)
    assert schema.validate("plan", doc) == []
