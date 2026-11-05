"""BUG-429 / BUG-430 (Run 16b i2 Glendagger, newest FR-BUGS entries; Gordon: the fort goes UNDER the aquifer).
BUG-429: a fortcore that stands (stage 1+2 applied, stage 3 stopped on breach:water three times, the stopped projects cancelled by
hand so fort.core is None) got no aqshaft: `surface_facts` returned at once for an applied fortcore. Now `aquifer_late` drafts the
aqshaft first and the remaining stages wait for the PASSED shaft (p.aquifer=pass); a known aquifer level inside the core's dig
counts for a new core too (sites.surface_core_why).
BUG-430: 0 free boulders and 0 logs: the dead digs (parked on a breach, set aside, stalled) no longer count as 'a stone dig is under
way', the draft puts wood and blocks first in trade.want, and a quarry (explore with p.avoid on the aquifer levels) takes the place of a
stone dig no bedrooms site can take."""
from __future__ import annotations

import copy
import json

import pytest
from cli_v2_helpers import ev, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema
from dfpilot.bp import sites

Z = 132
AQ = list(range(123, 130))                        # Glendagger: aquifer z123-129
STOP = [{"proj": f"y37{k}", "tpl": "fortcore", "why": "water", "pos": [121, 110, 129]} for k in (4, 5, 7)]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    box = {"man": {"v": 2, "aquifer_levels": list(AQ), "breaches": copy.deepcopy(STOP)}, "free": [
        {"id": "S1", "anchor": [140, 108, Z], "rot": 0, "why": "column 140,108 z132-z113, passes aquifer level z129"}]}
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: {"v": 2, "id": "s1", "rows": {}, "bbox": [0, 0, 100, 1, 1, 140], "marks": {}})
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "core_anchor", lambda _d: [122, 66, 137])

    def free(save, tpl, params=None, snap=None, n=3, **kw):
        return (box["free"] if tpl == "aqshaft" else []), "s1", len(box["free"])
    monkeypatch.setattr(plan, "free_sites", free)
    yield d, box
    reset_paths()


APPLIED = {("fortcore", 1), ("fortcore", 2), ("seal", None)}


def _state(save, phase="P3"):
    s = copy.deepcopy(files.read_state(save))
    s["phase"], s["proj"], s["sched"] = phase, [], {}
    s["pop"] = {"cit": 40}
    return s


# ---------------------------------------------------------------- BUG-429
def test_a_standing_core_with_stopped_stage_three_gets_the_aqshaft_route(world):
    save, _ = world
    f = plan.surface_facts(save, _state(save), APPLIED, None)               # core None: the stopped projects were cancelled
    assert f["need"] is False, "no new core is needed"
    late = f["aq_late"]
    assert late["ok"] is True and late["aquifers"] == AQ, late
    assert late["meet"] == [129] and [r["proj"] for r in late["stops"]] == ["y374", "y375", "y377"]
    assert late["site"]["anchor"] == [140, 108, Z]


def test_propose_drafts_the_aqshaft_first_and_stage_three_waits_for_it(world):
    save, _ = world
    fort = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True,
            "surface": plan.surface_facts(save, _state(save), APPLIED, None)}
    builds = [{"tpl": "seal", "site": "S1"}, {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}, {"tpl": "farms", "site": "S1"}]
    note = plan.aquifer_late_swap(builds, fort["surface"]["aq_late"])
    assert [b["tpl"] for b in builds] == ["seal", "aqshaft", "fortcore", "farms"], builds
    assert builds[1]["p"] == {"x": 140, "y": 108, "top": Z}
    assert builds[2]["p"] == {"stage": 3, "aquifer": "pass"}
    assert "BUG-429" in note and "z129" in note and "PASSED shaft" in note and "y374 water z129" in note, note
    doc = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied=APPLIED, fort=fort)
    bs = [b for se in doc["seasons"] for b in se["build"]]
    assert bs[0]["tpl"] == "aqshaft" and bs[0]["p"]["top"] == Z, bs
    assert "BUG-429" in doc["notes"]
    assert schema.validate("plan", doc) == []


def test_every_aquifer_source_counts_not_only_the_core_levels(world):
    save, box = world
    # no manifest aquifer_levels, no snapshot aqz: the repeated water stops of the cancelled stage-3 projects alone say z129
    box["man"] = {"v": 2, "breaches": copy.deepcopy(STOP)}
    late = plan.aquifer_late(save, APPLIED)
    assert late and 129 in late["aquifers"] and late["ok"], late
    # a lone water stop is a puddle, not an aquifer: not due
    box["man"] = {"v": 2, "breaches": STOP[:1]}
    assert plan.aquifer_late(save, APPLIED) is None


def test_stops_of_cancelled_projects_come_from_the_events(world, tmp_path):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": list(AQ)}                      # the kernel dropped the breach rows with the projects
    (save / "bp" / ".cancelled").mkdir(parents=True, exist_ok=True)
    for pid in ("y374", "y375"):
        (save / "bp" / ".cancelled" / f"{pid}.json").write_text(json.dumps({"tpl": "fortcore", "id": pid}), encoding="utf-8")
    (save / "bp" / ".cancelled" / "y373.json").write_text(json.dumps({"tpl": "explore", "id": "y373"}), encoding="utf-8")
    from cli_v2_helpers import append_events
    append_events(save, [ev(9001, "BREACH_STOP", "", {"proj": "y374", "pos": [121, 110, 129], "why": "water", "src": "tile"}),
                         ev(9002, "BREACH_STOP", "", {"proj": "y375", "pos": [121, 110, 129], "why": "water", "src": "tile"}),
                         ev(9003, "BREACH_STOP", "", {"proj": "y373", "pos": [125, 123, 127], "why": "heavy_aquifer", "src": "tile"})])
    stops = plan.fortcore_stops(save)
    assert [r["proj"] for r in stops] == ["y374", "y375"], "the explore's stop is no fortcore stop"
    late = plan.aquifer_late(save, APPLIED)
    assert late and late["ok"] and len(late["stops"]) == 2


def test_not_due_with_a_shaft_a_dry_core_or_no_fortcore(world):
    save, box = world
    assert plan.aquifer_late(save, APPLIED | {("aqshaft", None)}) is None, "a shaft placed already"
    assert plan.aquifer_late(save, {("seal", None)}) is None, "no fortcore stands: the core route (BUG-412) is the one"
    box["man"] = {"v": 2, "aquifer_levels": list(AQ)}                      # aquifer known, no stop, core levels above it
    assert plan.aquifer_late(save, APPLIED) is not None, "stage 1's levels (z137 - 8..5 = z129..132) meet z129"


def test_a_core_far_above_the_aquifer_is_left_alone(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [100, 101]}
    assert plan.aquifer_late(save, APPLIED) is None


def test_no_free_aqshaft_column_is_said_not_drafted(world):
    save, box = world
    box["free"] = []
    late = plan.aquifer_late(save, APPLIED)
    assert late["ok"] is False and "no free aqshaft column" in late["why"]
    builds = [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]
    note = plan.aquifer_late_swap(builds, late)
    assert [b["tpl"] for b in builds] == ["fortcore"] and builds[0]["p"] == {"stage": 3}
    assert "no aqshaft column is free" in note


def test_a_known_aquifer_inside_the_dig_sends_a_new_core_to_the_aquifer_route():
    anchor = 137
    site = {"anchor": [122, 66, anchor], "dig": (115, 59, anchor - 8, 129, 80, anchor - 3)}
    man = {"v": 2, "aquifer_levels": [anchor - 6]}                          # 6 levels under the anchor: beyond SURFACE_AQ (3)
    why = sites.surface_core_why({"aqz": {}}, man, site)
    assert why and "inside its dig" in why and f"z{anchor - 6}" in why, why
    assert sites.surface_core_why({"aqz": {}}, {"v": 2, "aquifer_levels": [anchor - 12]}, site) is None
    near = sites.surface_core_why({"aqz": {}}, {"v": 2, "aquifer_levels": [anchor - 2]}, site)
    assert near and "inside its dig" not in near, near


# ---------------------------------------------------------------- BUG-430
def _bp(save, pid, tpl):
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / f"{pid}.json").write_text(json.dumps({"id": pid, "tpl": tpl, "anchor": [1, 2, 3]}), encoding="utf-8")


def test_a_dead_dig_is_no_stone_dig_under_way(world):
    save, _ = world
    for p in (save / "bp").glob("*.json"):
        p.unlink()
    _bp(save, "y374s2b0", "explore")
    _bp(save, "c1a1a928", "bedrooms")
    assert plan.stone_digs(save) is True, "without the state both count (as before)"
    parked = {"proj": [["y374s2b0", "dig", 1, "parked: breach:heavy_aquifer"], ["c1a1a928", "build", 43, "set aside 1309 d: stalled (bp.resume)"]]}
    assert plan.stone_digs(save, parked) is False
    live = {"proj": [["y374s2b0", "dig", 1, "parked: breach:heavy_aquifer"], ["c1a1a928", "s1.dig", 43, ""]]}
    assert plan.stone_digs(save, live) is True
    assert plan.stone_digs(save, {"proj": [["y374s2b0", "dig", 12, ""]]}) is True


def _short(save, rock=0, logs=0, n=9100):
    from cli_v2_helpers import append_events
    append_events(save, [ev(n, "MATERIAL_SHORT", "no material", {"boulders": 0, "logs": logs, "n": 12, "pieces": "chair x6",
                                                                  "rock": rock, "why": ["no rock, no logs"]})])


def test_material_famine_reads_the_newest_material_short(world):
    save, _ = world
    _short(save, rock=0, logs=0)
    f = plan.material_famine(save, {"stock": {"rock": 0, "rock_need": 4}})
    assert f == {"short": True, "rock0": True, "logs0": True}
    assert plan.material_famine(save, {"stock": {"rock": 3, "rock_need": 4}})["rock0"] is False
    _short(save, rock=5, logs=7, n=9101)
    f = plan.material_famine(save, {"stock": {}})
    assert f["rock0"] is False and f["logs0"] is False


def test_the_draft_puts_wood_and_blocks_first_and_a_stone_dig_in_a_famine(world):
    save, _ = world
    s = _state(save, "P1")
    s["stock"] = {**(s.get("stock") or {}), "rock": 0, "rock_need": 4}
    fort = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True, "stone_dig": False,
            "famine": {"short": True, "rock0": True, "logs0": True}}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert doc["trade"]["want"][:2] == ["wood", "block"], doc["trade"]
    assert "BUG-430" in doc["notes"] and "a safe stone dig first" in doc["notes"], doc["notes"]
    bs = [b for se in doc["seasons"] for b in se["build"]]
    assert plan.STONE_DIG in bs, bs
    # a stone dig under way (alive) keeps the draft from a second one, the trade want stays
    fort["stone_dig"] = True
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert plan.STONE_DIG not in [b for se in doc["seasons"] for b in se["build"]]
    assert doc["trade"]["want"][:2] == ["wood", "block"]
    assert schema.validate("plan", doc) == []


def test_a_famine_without_a_bedrooms_site_gets_a_quarry_off_the_aquifer(world, monkeypatch):
    save, _ = world
    _short(save, rock=0, logs=0)
    st = copy.deepcopy(files.read_state(save))
    st["stock"] = {**(st.get("stock") or {}), "rock": 0, "rock_need": 4}
    files.write_json_atomic(save / "state.b.json", st)
    files.write_json_atomic(save / "state.a.json", st)
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [copy.deepcopy(plan.STONE_DIG), {"tpl": "farms", "site": "S1"}]}, {"build": []}, {"build": []},
                      {"build": []}]
    doc["notes"] = "draft; rock: 0 free boulders: bedrooms@S1 n=4 first (a stone dig)"
    seen = []

    def rank(save_dir, tpl, params=None, *a, **k):
        seen.append((tpl, dict(params or {})))
        if tpl == "bedrooms":
            raise cmd.BpError("bedrooms rooms open from the dug Z4 floor")
        return [{"id": "S1", "anchor": [109, 102, Z], "rot": 1, "why": "rot1, shaft to z126"}], "s1"
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 1)
    line = plan.fit_stone_dig(save, doc, prev)
    b0 = doc["seasons"][0]["build"]
    assert [b["tpl"] for b in b0] == ["explore", "farms"], b0
    assert b0[0]["p"]["avoid"] == "123-129", b0[0]
    assert ("explore", {"depth": 12, "avoid": "123-129"}) in seen, seen
    assert "BUG-430" in line and "quarry explore@S1 p.avoid=123-129" in line and "digs stone meanwhile" in line, line
    assert "BUG-430" in doc["notes"]
    assert schema.validate("plan", doc) == []


def test_no_famine_no_quarry(world, monkeypatch):
    save, _ = world
    st = copy.deepcopy(files.read_state(save))
    st["stock"] = {**(st.get("stock") or {}), "rock": 3, "rock_need": 4}
    files.write_json_atomic(save / "state.b.json", st)
    files.write_json_atomic(save / "state.a.json", st)
    _short(save, rock=3, logs=0)
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [copy.deepcopy(plan.STONE_DIG)]}, {"build": []}, {"build": []}, {"build": []}]
    doc["notes"] = "draft"
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: (_ for _ in ()).throw(cmd.BpError("none")))
    plan.fit_stone_dig(save, doc, prev)
    assert doc["seasons"][0]["build"] == []
