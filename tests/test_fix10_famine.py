"""Run 15c Inkintense famine (fix10-famine, BUG-293..299), the Python side: the popcap verbs and pop.hold in the contract
and the status line (BUG-293), soil marks beyond 500 (BUG-297), the surface farm template and its sites (BUG-297), plan
propose drafting a farm below 60 food days also after an earlier farms project (BUG-297). Every test but the room-farm guard
(test_bug297_room_farms_unchanged_without_surface, unchanged behaviour) fails on 05dc764."""
from __future__ import annotations

from types import SimpleNamespace

from dfpilot import brief, plan, schema
from dfpilot.bp import rooms, sites
from dfpilot.bp.emit import check_params


# ---------------------------------------------------------------- BUG-293
def test_bug293_popcap_verbs_and_pop_hold_in_the_contract():
    assert schema.validate_args("popcap.raise", {}) == []
    assert schema.validate_args("popcap.set", {"cap": 25}) == []
    assert schema.validate_args("popcap.set", {"cap": 0}) != []
    assert schema.validate_args("popcap.lower", {"cap": 25, "until": "food"}) == []
    assert schema.validate_args("popcap.lower", {"cap": 25, "until": "later"}) != []
    assert schema.VERBS["popcap.raise"][0] == schema.VERBS["popcap.set"][0] == "readiness"
    st = {"v": schema.V, "seq": 1, "t": {"y": 376, "tick": 1, "season": 2, "tps": 0, "paused": True}, "mode": "PEACE",
          "k": {"ms_s": 1, "gap_max_ms": 1, "slow": [], "faults": 0}, "ev": 1,
          "pop": {"cit": 50, "cap": 50, "gate_cap": 25, "hold": "player 25 until food 60 d"}}
    assert schema.validate("state", st) == []
    assert schema.STATE_OWNERS["pop.hold"] == "readiness"


def test_bug293_status_pop_line_names_the_ceiling():
    ctx = SimpleNamespace(s={"pop": {"cit": 50, "adults": 47, "soldiers": 8, "cap": 50, "gate_cap": 25,
                                     "hold": "player 25 until food 60 d"}}, b={}, now_tick=lambda: 0)
    line = brief.pop_items(ctx)[0][1]
    assert line == "pop 50 (47ad 8sol) cap 50 gate 25 ceiling player 25 until food 60 d"


# ---------------------------------------------------------------- BUG-297 soil marks, surface farms
def test_bug297_snapshot_soil_marks_beyond_500():
    snap = {"v": 2, "id": "s1", "tick": 1, "bbox": [0, 0, 100, 1, 1, 100], "rows": {"z100": ["..", ".."]},
            "marks": {"soil": [[i % 100, i // 100, 100] for i in range(3000)], "shrub": []}}
    errs = [e for e in schema.validate("snapshot", snap) if "marks" in e]
    assert errs == [], errs
    snap["marks"]["shrub"] = [[0, 0, 100]] * 501
    assert any("shrub" in e for e in schema.validate("snapshot", snap))


def test_bug297_surface_farms_template_digs_nothing():
    p = check_params("farms", {"plots": 2, "surface": 1})
    P = rooms.farms(p)
    assert P.dug() == {}
    plots = [it for st in P.stages for it in st.items if it.key == "p"]
    assert len(plots) == 2 and all(st.mode == "build" for st in P.stages)
    assert rooms.plot_rects(p) == [(0, 0, 4, 6, 0), (6, 0, 10, 6, 0)]
    assert P.rooms[0]["tpl"] == "farms"


def _snap(w=40, h=30, z=133):
    rows = [["."] * w for _ in range(h)]
    return {"v": 2, "id": "s1", "tick": 1, "purpose": "sites", "bbox": [0, 0, z, w - 1, h - 1, z],
            "rows": {f"z{z}": ["".join(r) for r in rows]}, "marks": {"soil": []}}


def _man(z=133):
    return {"v": 2, "zones": {"Z4": [[0, 0, z - 2, 5, 5, z - 2]]}, "edge": [[20, 20, z]], "rooms": [], "bridges": {},
            "killboxes": [], "stairs": {}, "stations": {}, "workshops": []}


def test_bug297_surface_farm_sites_on_soil_floor_by_the_entrance():
    snap, man = _snap(), _man()
    p = {"plots": 1, "surface": 1}
    assert sites.rank(snap, "farms", p, man) == [], "no soil marks: nothing"
    snap["marks"]["soil"] = [[x, y, 133] for x in range(0, 40) for y in range(0, 30)]
    out = sites.rank(snap, "farms", p, man)
    assert out, "old code: surface is no farms parameter"
    best = out[0]
    assert "surface farm on soil floor" in best["why"] and "from the entrance" in best["why"]
    ax, ay, _ = best["anchor"]
    assert max(abs(ax - 20), abs(ay - 20)) <= sites.SURFACE_NEAR + 7
    # the way in stays clear, nothing beyond SURFACE_NEAR, never on the attack path
    for s in out:
        x, y, _ = s["anchor"]
        assert not (18 <= x <= 22 and 18 <= y <= 22)
    man["zones"]["Z1"] = [[0, 0, 133, 39, 29, 133]]
    assert sites.rank(snap, "farms", p, man) == []
    # soil on exactly one 5x7 block: that block only; one tile of it without soil: nothing
    snap["marks"]["soil"] = [[x, y, 133] for x in range(25, 30) for y in range(3, 10)]
    out = sites.rank(snap, "farms", p, _man())
    assert out and all(s["anchor"] in ([25, 3, 133], [29, 9, 133]) for s in out), out
    snap["marks"]["soil"].remove([27, 6, 133])
    assert sites.rank(snap, "farms", p, _man()) == []


def test_bug297_room_farms_unchanged_without_surface():
    snap = _snap()
    snap["marks"]["soil"] = [[x, y, 133] for x in range(40) for y in range(30)]
    assert sites.rank(snap, "farms", {"plots": 1}, _man()) == [], "a room farm needs rock to dig into"


# ---------------------------------------------------------------- BUG-297 plan propose
STATE = {"t": {"y": 376, "season": 2}, "phase": "P5", "ready": {"lvl": 0}, "mode": "PEACE",
         "stock": {"food_d": 40, "drink_d": 200}}


def test_bug297_food_draft_rules():
    fort = {"farms": {"open": False, "site": "surface"}}
    b, note = plan.food_draft(STATE, fort, [], None)
    assert b == {"tpl": "farms", "site": "S1", "p": {"surface": 1}}
    assert "food 40 d (< 60): farms@S1 p.surface=1" in note
    b, note = plan.food_draft(STATE, {"farms": {"open": False, "site": "room"}}, [], None)
    assert b == {"tpl": "farms", "site": "S1"}
    assert plan.food_draft(STATE, {"farms": {"open": True, "site": "room"}}, [], None)[0] is None
    b, note = plan.food_draft(STATE, {"farms": {"open": False, "site": "none"}}, [], None)
    assert b is None and "no farm site" in note
    assert plan.food_draft({**STATE, "stock": {"food_d": 60}}, fort, [], None) == (None, "")
    assert plan.food_draft(STATE, fort, [{"tpl": "farms", "site": "S1"}], None) == (None, "")
    assert plan.food_draft(STATE, fort, [], {"bedrooms": {}}) == (None, "")
    # review: a surface farm (plots by the door) is drafted in PEACE only; a room farm also outside PEACE
    b, note = plan.food_draft({**STATE, "mode": "RECOVERY"}, fort, [], None)
    assert b is None and "PEACE only" in note
    assert plan.food_draft({**STATE, "mode": "RECOVERY"}, {"farms": {"open": False, "site": "room"}}, [], None)[0]


def test_bug297_propose_drafts_a_farm_after_an_earlier_farms_project():
    fort = {"farms": {"open": False, "site": "surface"}}
    doc = plan.propose(STATE, {"phases": []}, None, decisions={}, tinfo=None, applied={("farms", None)}, fort=fort)
    builds = [b for se in doc["seasons"] for b in se["build"]]
    assert {"tpl": "farms", "site": "S1", "p": {"surface": 1}} in builds, builds
    assert "BUG-297" in doc["notes"]
    low = {**STATE, "stock": {"food_d": 1, "drink_d": 200}}
    doc = plan.propose(low, {"phases": []}, None, decisions={}, tinfo=None, applied={("farms", None)}, fort=fort)
    builds = [b for se in doc["seasons"] for b in se["build"]]
    assert builds and builds[0]["tpl"] == "farms", "the emergency puts it first"
    doc = plan.propose(STATE, {"phases": []}, None, decisions={}, tinfo=None, applied={("farms", None)},
                       fort={"farms": {"open": True, "site": "room"}})
    assert not any(b["tpl"] == "farms" for se in doc["seasons"] for b in se["build"])
