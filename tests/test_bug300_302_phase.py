"""BUG-300..302 (Run 15 Drillchamber r3: phase P0 the whole run while the plans targeted P5, because the P0 deliverable
farms can never be made: every farm site is stone without water, `bp sites farms` 0 ranked; traps P5, kit and the cavern
sweep P6, rooms P7 never unlocked; nothing said which deliverable held the phase; `plan propose` drafted farms@S1 again
with 0 sites). Python side: the phase.waive verb and the new state/persist fields keep their contracts, status/brief/
doctor name what holds the phase, follow waives farms when no farm site exists at all, propose leaves such farms out."""
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, doctor, files, plan, schema, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc.update(parts)
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")


PHW = {"wait": ["workshops Still,Butchers"], "waived": ["farms: bp sites farms: 0 room and 0 surface sites"]}


def test_contracts_verb_state_and_persist():
    assert schema.VERBS["phase.waive"][0] == "runner"
    assert schema.validate_args("phase.waive", {"tpl": "farms", "why": "0 farm sites"}) == []
    assert schema.validate_args("phase.waive", {"tpl": "fortcore", "stage": 2, "why": "x"}) == []
    assert schema.validate_args("phase.waive", {"tpl": "farms"}) != []
    assert schema.validate_args("phase.waive", {"tpl": "Farms!", "why": "x"}) != []
    ph = {"v": 2, "phase": "P1", "since": 5, "done": ["P0"],
          "waive": [{"d": "farms", "why": "0 farm sites", "ph": "P0", "t": 5, "by": "follow"}]}
    assert schema.validate("persist.phase", ph) == []
    assert schema.validate("persist.phase", {**ph, "waive": [{"d": "farms"}]}) != []
    assert schema.STATE_OWNERS["phw.*"] == "runner"


def test_line_phase_names_the_wait_and_the_waived():
    s = {"phase": "P0", "phw": PHW}
    assert brief.line_phase(s) == ("phase P0: waits for workshops Still,Butchers (farms impossible: bp sites farms: "
                                   "0 room and 0 surface sites -> waived)")
    assert brief.line_phase({"phase": "P1", "phw": {"waived": ["farms: x"]}}) == \
        "phase P1: deliverables met (farms impossible: x -> waived)"
    assert brief.line_phase({"phase": "P0"}) == ""
    h = brief.line_phase({"phase": "P0", "phw": {"wait": ["farms"]}}, hint=True)
    assert "dfllm cmd phase.waive '{\"tpl\":\"farms\"" in h, h


def test_status_brief_and_doctor_name_the_blocking_deliverable(save):
    put_state(save, phase="P0", phw={"wait": ["farms"]})
    assert "phase P0: waits for farms" in brief.status_text(save)
    lines, _ = doctor.diagnose(save)
    txt = "\n".join(lines)
    assert "phase P0: waits for farms" in txt and "phase.waive" in txt, txt


def test_farm_site_fix_leaves_out_farms_without_a_site():
    b = [{"tpl": "farms", "site": "S1"}, {"tpl": "dining", "site": "S1"}]
    out, note = plan.farm_site_fix(list(b), {"mode": "PEACE"}, {"farms": {"open": False, "site": "none"}})
    assert [x["tpl"] for x in out] == ["dining"] and "BUG-302: farms left out: no farm site" in note
    out, note = plan.farm_site_fix([dict(x) for x in b], {"mode": "PEACE"}, {"farms": {"site": "surface"}})
    assert out[0]["p"] == {"surface": 1} and "p.surface=1" in note
    out, note = plan.farm_site_fix([dict(x) for x in b], {"mode": "ALERT"}, {"farms": {"site": "surface"}})
    assert [x["tpl"] for x in out] == ["dining"] and "PEACE only" in note
    for site in ("room", None):
        out, note = plan.farm_site_fix(list(b), {"mode": "PEACE"}, {"farms": {"site": site}})
        assert out == b and note == ""


def test_propose_drafts_no_farms_without_a_farm_site():
    """Live y378 Drillchamber: P0, food 28 d, drink 0 d, farm_facts site 'none'; the draft had farms@S1 (plan check ERROR)."""
    phases = plan.load_phases()
    st = {"v": 2, "t": {"y": 378, "tick": 1000, "season": 0, "tps": 50, "paused": False}, "mode": "PEACE",
          "phase": "P0", "stock": {"food_d": 28, "drink_d": 0, "meals": 2}, "pop": {"cit": 43}}
    fort = {"farms": {"open": False, "site": "none"}}
    doc = plan.propose(st, phases, None, fort=fort, applied=set())
    tpls = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
    assert "farms" not in tpls, tpls
    assert "BUG-302: farms left out" in doc["notes"]
    doc = plan.propose(st, phases, None, fort={"farms": {"open": False, "site": "room"}}, applied=set())
    assert "farms" in [b["tpl"] for se in doc["seasons"] for b in se["build"]]


def test_follow_waives_farms_when_no_site_exists_at_all(save, monkeypatch):
    put_state(save, phase="P0")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    sent = []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **kw: sent.append((verb, args)) or "c1")
    monkeypatch.setattr(plan, "farm_site", lambda d: "none")
    err = "site S1: only 0 free site(s) for farms (plots 1) on snapshot s1"
    f._waive_farms(err, 1000.0)
    assert sent == [("phase.waive", {"tpl": "farms", "why": "bp sites farms: 0 room and 0 surface sites"})]
    f._waive_farms(err, 1500.0)
    assert len(sent) == 1, "once per WAIVE_COOLDOWN_S"
    f.jobs.clear()
    monkeypatch.setattr(plan, "farm_site", lambda d: "surface")
    f._waive_farms(err, 9000.0)
    assert len(sent) == 1, "a surface site is free: no waiver"
    monkeypatch.setattr(plan, "farm_site", lambda d: "none")
    f._waive_farms("site S1: only 0 free site(s) for tombs", 9000.0)
    assert len(sent) == 1
    put_state(save, phase="P1")
    f._waive_farms(err, 9000.0)
    assert len(sent) == 1, "P1 has no farms deliverable"
    assert files.read_state(save)["phase"] == "P1"


def test_follow_restart_keeps_the_waive_cooldown(save):
    """Review: _fresh_jobs dropped jobs['waive'] (not a PLACE_KEY), so every follow restart sent phase.waive again."""
    f = wake.Follower(out=lambda s: None, clock=lambda: 2000.0)
    f.dir = save
    kept = f._fresh_jobs({"waive": {"since": 1000.0}})
    assert kept == {"waive": {"since": 1000.0}}
    assert f._fresh_jobs({"waive": {"since": 2000.0 - wake.WAIVE_COOLDOWN_S - 1}}) == {}
