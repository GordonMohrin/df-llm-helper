"""Round 44 (proj): projects and plan (BUG-679 to BUG-684). See bugs/BUG-679..684."""
import copy
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths        # noqa: E402

from dfpilot import bp, cmd, files, plan, schema                               # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    yield d
    reset_paths()


DAY = schema.TICKS["DAY"]
MAN = {"v": 2, "refuge": {"anchor": [67, 46, 138], "burrow": "Tiefe+"}, "stairs": {"civ": [[67, 44, 138, 141]]},
       "zones": {"Z4": [[60, 40, 136, 75, 50, 141]]}}


# ---------------------------------------------------------------- BUG-684
def _stuck(n, tick, proj="y421s1b0", why="not placed"):
    return ev(n, "SEAL_STUCK", "built nothing", {"days": 4, "n": 1, "pieces": ["hatch 67,44,139"], "proj": proj, "stage": "seal.build",
                                                  "tpl": "seal", "wait": "hatch 67,44,139: nothing stands at 67,44,139", "why": why},
              tick=tick)


def test_a_seal_stuck_again_and_again_on_the_same_hatch_is_a_remembered_phantom(save, monkeypatch):
    """Wallfree y414-y421: no PROJECT_BLOCKED phantom (kernel not reloaded), the tile below the snapshot: the stuck seals are the record."""
    files.write_json_atomic(save / "manifest.json", MAN)
    year = schema.TICKS["YEAR"]
    monkeypatch.setattr(files, "current_tick", lambda sd: 10 * year)
    n = files.last_event_n(save)
    append_events(save, [_stuck(n + 1, 5 * year), _stuck(n + 2, 5 * year + 4 * DAY)])
    assert cmd.phantom_tiles(save) == set()                       # two events within days: not yet
    append_events(save, [_stuck(n + 3, 5 * year + 30 * DAY),
                         ev(n + 4, "DECISION_NEEDED", "q", {"id": "seal_stalled", "mat": "hatch 67,44,140",
                                                           "q": "seal x: hatch 67,44,140 open 64 d (not placed); the way in stays open"},
                            tick=5 * year)])
    assert cmd.phantom_tiles(save) == {"67,44,139"}
    for p in (save / "snap").glob("*.json"):
        p.unlink()
    rs = cmd.refuge_stair(save)
    assert (rs["state"], rs["head"]) == ("nostair", None), rs


def test_a_seal_that_was_built_or_stuck_for_another_cause_is_no_phantom(save, monkeypatch):
    files.write_json_atomic(save / "manifest.json", MAN)
    year = schema.TICKS["YEAR"]
    monkeypatch.setattr(files, "current_tick", lambda sd: 10 * year)
    n = files.last_event_n(save)
    append_events(save, [_stuck(n + i, 5 * year + i * 20 * DAY, why="no material") for i in range(1, 5)])
    assert cmd.phantom_tiles(save) == set()


# ---------------------------------------------------------------- BUG-683
def test_the_workshops_refusal_names_surface_and_only(save):
    """Basementflew y470-y472: '0 free sites' for the Kitchen, `surface=1` placed it within minutes and no message said so."""
    h = cmd.no_site_hint(save, "workshops", "s1", 0, ["c1a1ab437a0e153311"], {"skip": "Carpenters,Masons", "add": ""})
    assert "surface=1" in h and "bp.place tpl=workshops site=S1" in h
    h2 = cmd.no_site_hint(save, "workshops", "s1", 0, [], {"only": "Kitchen"})
    assert "only=Kitchen surface=1" in h2
    assert "surface=1" not in cmd.no_site_hint(save, "workshops", "s1", 0, [], {"surface": 1}).replace("`dfllm bp sites workshops surface=1 --fresh", "")


def test_bp_sites_workshops_accepts_only(save, monkeypatch):
    seen = {}

    def fake_rank(sd, tpl, params=None, snap=None, **kw):
        seen["params"] = dict(params or {})
        return [], "s1"

    monkeypatch.setattr(cmd, "rank_sites", fake_rank)
    monkeypatch.setattr(cmd, "ranking", fake_rank)
    cmd.free_sites(save, "workshops", {"only": "Kitchen"}, None)
    assert "only" not in seen["params"] and "Kitchen" not in seen["params"]["skip"].split(",")


# ---------------------------------------------------------------- BUG-680
def _held_world(save):
    sys.path.insert(0, str(Path(__file__).parent))
    from test_bug377_379_defense import CORE, FORT, TPLS, world        # noqa: E402
    from cli_v2_helpers import FIX                                       # noqa: E402
    s = world(save, pop=32)
    s["mode"] = "PEACE"
    s["ready"] = {"lvl": 0, "worn": 10, "cv": 8, "drill_age": -1, "fail": [], "audit": {"ok": 1, "age": 900, "min_traps": 30}}
    s["mil"] = {"soldiers": 11, "worn": 10, "squads": 3, "cv": 8, "kit": {"n": 11, "full": 0, "armor": 3, "weapon": 6}}
    s["traps"] = {"m": 30, "n": 30}
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    prev["seasons"] = [{"build": []} for _ in range(4)]
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""} for t in TPLS}
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort=dict(FORT), applied=set(CORE))
    return s, doc


def test_a_held_ceiling_is_raised_when_the_armor_gap_closes(save, monkeypatch):
    """Trumpetrealms y447: ceiling 31 held for armor worn 10 %, a month later worn 57 % and migrants still blocked."""
    s, doc = _held_world(save)
    held = doc["policy"]["pop_ceiling"]
    assert held < 100 and "held (policy" in doc["notes"], doc["notes"]
    files.write_json_atomic(save / "plan.json", doc)
    monkeypatch.setattr(plan, "fort_facts", lambda sd, st=None: {})
    assert plan.ceiling_refresh(save, s) is None                 # worn 10 %: nothing to lift
    s2 = copy.deepcopy(s)
    s2["mil"]["worn"] = 90
    s2["ready"]["worn"] = 90
    hit = plan.ceiling_refresh(save, s2)
    assert hit is not None and hit[0] == held and hit[1] > held, (hit, held)
    new = plan.applied_plan(save)
    assert new["policy"]["pop_ceiling"] == hit[1] and "BUG-680" in new["notes"]
    assert plan.ceiling_refresh(save, s2) is None                # once; nothing more to lift


def test_the_ceiling_is_left_alone_outside_peace_and_without_a_hold(save, monkeypatch):
    s, doc = _held_world(save)
    doc["policy"]["pop_ceiling"] = 100                           # a plan with no hold
    files.write_json_atomic(save / "plan.json", doc)
    monkeypatch.setattr(plan, "fort_facts", lambda sd, st=None: {})
    assert plan.ceiling_refresh(save, s) is None
    s2 = copy.deepcopy(s)
    s2["mode"] = "SIEGE"
    assert plan.ceiling_refresh(save, s2) is None


# ---------------------------------------------------------------- BUG-681
def test_no_trap_lane_is_drafted_while_every_free_part_lies_out_of_reach():
    """Basementflew y470-y486: 19 'free' mechanisms in the flooded level, traps@S1 drafted every year."""
    s = {"stock": {"mfree": 0, "mfar": 19}}
    assert "out of reach" in plan.noparts_reason(s)
    assert plan.noparts_reason({"stock": {"mfree": 4, "mfar": 19}}) == ""                       # one a citizen can reach
    assert plan.noparts_reason({"stock": {"mfree": 0, "mfar": 19, "mroute": "ordered"}}) == ""  # being made
    from dfpilot import traps
    fort = {"traps": {"open": 2, "ways": ["1,2,3"]}, "noparts": plan.noparts_reason(s)}
    out, note = traps.draft(fort, "P5", [], None, 486, None, False)
    assert out == [] and "BUG-628" in note


# ---------------------------------------------------------------- BUG-682
def test_stage3_is_due_while_r0_misses_a_gate_even_when_the_bridge_reads_replaced():
    s = {"bridges": {"O1": "replaced", "B1": "up", "B2": "up"}, "alert": {"ref": {"ex": 1}}, "ready": {"fail": ["no_outer"]}}
    fort = {"refuge": {"fortcore": True, "stage3": False}, "o1": False}
    assert plan.stage3_due(s, fort, set(), []) is True
    s2 = {**s, "ready": {"fail": []}}
    assert plan.stage3_due(s2, fort, set(), []) is False            # replaced stands for the perimeter, nothing misses
    assert plan.stage3_due(s, {**fort, "o1": True}, set(), []) is False       # stage 3 was built: no second one


def test_a_replaced_gate_is_named_not_redrafted():
    s = {"bridges": {"O1": "replaced", "B1": "up"}, "ready": {"fail": ["no_outer"]}}
    note = plan.replaced_gate_note(s, {})
    assert "BUG-682" in note and "O1" in note and "no automatic drill" in note
    assert plan.replaced_gate_note({"bridges": {"O1": "up"}, "ready": {"fail": ["no_outer"]}}, {}) == ""
    assert plan.replaced_gate_note({"bridges": {"O1": "replaced"}, "ready": {"fail": []}}, {}) == ""
