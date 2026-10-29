"""Live test round 2, instance i3 (region2-site90 Trussroads y722-723), BUG-130 still partial:
BUG-162: a runtime whose bp/ holds no files while manifest.breaches names fortcore y707s0b1 (damp): propose drafted a plain
fortcore@S1 (core_breaches needed a bp file), plan check rejected it with "no dry fortcore site".
BUG-163: the re-site drafted fortcore@S1 stage 1 plus @same only for the stages of the stopped anchor ({1,3}: no stage 2);
after the re-site was applied, the stages 2/3 of the moved core were never drafted.
BUG-164: applied_builds counted ('fortcore', 2) of an older core at another anchor (y497s3b0 at 122,68,132), so the phase
deliverables never drafted stage 2 for the current core (after the bp.cancel: a lone stage 3 @same)."""
import copy
import json

import pytest
from cli_v2_helpers import RUNTIME, SAVE, append_events, ev, make_runtime, reset_paths

from dfpilot import cmd, files, plan

PID = "y707s0b1"
DAMP = [50, 42, 127]
A, B, C = (48, 30, 130), (122, 68, 132), (70, 82, 132)


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _core(save, pid, stage, anchor, rot=0):
    doc = json.loads((RUNTIME / SAVE / "bp" / "y3s0b0.json").read_text("utf-8"))
    doc.update(id=pid, tpl="fortcore", site="S1", anchor=list(anchor), rot=rot, params={"stage": stage},
               manifest={"v": 2})
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), "utf-8")


def _manifest(save):
    files.write_json_atomic(save / "manifest.json", {"v": 2, "breaches": [
        {"pos": DAMP, "why": "damp", "proj": PID, "tpl": "fortcore"}]})


def _state(save, phase="P0", rows=None):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = phase
    s["proj"] = rows if rows is not None else [[PID, "s1.dig", 0, "parked: breach:damp"]]
    s["ready"] = {"lvl": 0, "fail": ["no_inner", "no_outer"]}
    s["bridges"] = {}
    return s


def _no_bp(save):
    for p in (save / "bp").glob("*.json"):
        p.unlink()


def _facts(save, monkeypatch, st, sites=True):
    def fake(save_dir, tpl, params=None, snap=None, n=3, where=None, taken=None):
        if sites is True:
            return [{"id": "S1", "anchor": [10, 10, 130], "rot": 0}], "c201", 3
        raise cmd.BpError("bp.sites.rank(fortcore): fortcore: no dry fortcore site: every site's dig lies within 10 "
                          "tiles of a recorded breach (wet level z128 (4 damp/water stops))")
    monkeypatch.setattr(cmd, "free_sites", fake)
    return plan.fort_facts(save, st)


def _cores(doc):
    return [(b["site"], b["p"]["stage"]) for se in doc["seasons"] for b in se["build"] if b["tpl"] == "fortcore"]


def _propose(save, st, fort):
    return plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)


# ---------------------------------------------------------------- BUG-162: a manifest row without a bp file
def test_a_manifest_breach_without_a_bp_file_is_a_stopped_core(save):
    _no_bp(save)
    _manifest(save)
    st = _state(save, rows=[[PID, "s1.dig", 0, "parked: breach:damp"]])
    got = plan.core_breaches(save, st)
    assert [(b["proj"], b["stage"], b["why"], b["pos"]) for b in got] == [(PID, 1, "damp", DAMP)]
    st3 = _state(save, rows=[[PID, "s3.dig", 0, "parked: breach:damp"]])
    assert plan.core_breaches(save, st3)[0]["stage"] == 3            # the stage from the state.proj label


def test_a_cancelled_or_done_manifest_row_is_none(save):
    _no_bp(save)
    _manifest(save)
    (save / "bp" / ".cancelled").mkdir()
    (save / "bp" / ".cancelled" / f"{PID}.json").write_text("{}", "utf-8")
    assert plan.core_breaches(save, _state(save)) == []
    (save / "bp" / ".cancelled" / f"{PID}.json").unlink()
    n0 = max([e["n"] for e in files.iter_events_rev(save)] or [0])
    append_events(save, [ev(n0 + 1, "PROJECT_DONE", "done", {"proj": PID, "tpl": "fortcore"})])
    assert plan.core_breaches(save, _state(save)) == []


def test_a_manifest_row_resumed_in_observe_mode_is_none(save):
    # FR-95: observe mode resumed the park (AQ_OBSERVE newest): it digs again, no re-site
    _no_bp(save)
    _manifest(save)
    n0 = max([e["n"] for e in files.iter_events_rev(save)] or [0])
    append_events(save, [ev(n0 + 1, "BREACH_STOP", "stop", {"proj": PID, "why": "damp", "pos": DAMP}),
                         ev(n0 + 2, "AQ_OBSERVE", "observe", {"proj": PID, "tpl": "fortcore", "src": "resume"})])
    assert plan.core_breaches(save, _state(save, rows=[[PID, "s1.dig", 0, ""]])) == []


def test_propose_and_check_agree_without_bp_files(save, monkeypatch):
    _no_bp(save)
    _manifest(save)
    st = _state(save)
    fort = _facts(save, monkeypatch, st, sites=None)
    assert fort["core"] and fort["core"]["ok"] is False
    fort["refuge"]["seal_n"] = 2
    doc = _propose(save, st, fort)
    assert _cores(doc) == [], "no plain fortcore@S1 that check rejects"
    assert {"tpl": "seal", "site": "S1", "p": {"at": "last"}} in [b for se in doc["seasons"] for b in se["build"]]
    assert doc["phase_target"] < "P3" and "BUG-130" in doc["notes"] and f"bp.cancel proj={PID}" in doc["notes"]
    errs, _ = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if "fortcore" in e], errs


# ---------------------------------------------------------------- BUG-163: the re-site drafts every stage
def test_the_resite_drafts_stage_2_although_an_older_core_had_one(save, monkeypatch):
    _no_bp(save)
    _manifest(save)
    _core(save, "y497s3b0", 2, B)                 # an older core's stage 2 elsewhere
    _core(save, PID, 1, A)
    _core(save, "y707s0b3", 3, A)
    st = _state(save)
    fort = _facts(save, monkeypatch, st)
    assert fort["core"]["stages"] == [1, 3] and not fort["core"]["moved"]
    doc = _propose(save, st, fort)
    assert _cores(doc) == [("S1", 1), ("same", 2), ("same", 3)]
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if "fortcore" in e], errs
    assert not [w for w in warn if "duplicate fortcore@same" in w], warn


def test_a_moved_core_gets_its_missing_stages_at_its_explicit_anchor(save, monkeypatch):
    _no_bp(save)
    _manifest(save)
    _core(save, "y497s3b0", 2, B)
    _core(save, PID, 1, A)
    _core(save, "y707s0b3", 3, A)
    _core(save, "y722s2b0", 1, C, rot=1)          # the re-site was applied
    st = _state(save)
    st["proj"].append(["y722s2b0", "s1.dig", 5, ""])
    fort = _facts(save, monkeypatch, st)
    mv = fort["core"]["moved"]
    assert mv["proj"] == "y722s2b0" and mv["stages"] == [1]
    doc = _propose(save, st, fort)
    assert _cores(doc) == [("A70_82_132_1", 2), ("A70_82_132_1", 3)], "no second stage 1, both later stages"
    assert "y722s2b0" in doc["notes"] and f"bp.cancel proj={PID}" in doc["notes"]
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if "fortcore" in e], errs
    assert not [w for w in warn if "is not a `bp sites` label" in w], warn


def test_an_explicit_anchor_stage_does_not_clash_with_its_own_stage_1(save):
    d = cmd.emit_at("fortcore", {"stage": 1}, {"id": "S1", "anchor": [100, 100, 130], "rot": 0}, "S1", "y9s0b0")
    cmd.write_bp(save, d)
    x = cmd.place(save, "fortcore", {"stage": 2}, "A100_100_130_0", "y9s0b1")
    assert x["anchor"] == [100, 100, 130] and x["params"]["stage"] == 2
    assert cmd.anchor_label([100, 100, 130], 0) == "A100_100_130_0"
    with pytest.raises(cmd.BpError, match="overlaps"):                  # another template there still clashes
        cmd.place(save, "fortcore", {"stage": 1}, "A100_100_130_0", "y9s0b2")


def test_the_why_text_is_cut_at_a_word_boundary():
    why = "bp.sites.rank(fortcore): fortcore: no dry fortcore site: every site's dig lies within 10 tiles of a recorded breach"
    out = plan._cut(why, 100)
    assert len(out) <= 100 and out.endswith("...") and why.startswith(out[:-3])
    assert why[len(out) - 3] == " ", out                       # the cut falls on a space, not inside a word
    assert plan._cut("short", 100) == "short"


# ---------------------------------------------------------------- BUG-164: fortcore stages per anchor
def test_applied_fortcore_stages_count_on_the_current_core_only(save):
    _no_bp(save)
    _core(save, "y497s3b0", 2, B)
    _core(save, "y722s2b0", 1, C, rot=1)
    files.write_json_atomic(save / "bp" / ".placed-fortcore.json", {"anchor": list(C), "rot": 1, "from": "S1",
                                                                    "bp": "y722s2b0"})
    got = plan.applied_builds(save, {"proj": []})
    assert ("fortcore", 1) in got and ("fortcore", 2) not in got
    assert plan.core_anchor(save) == list(C)
    (save / "bp" / ".placed-fortcore.json").unlink()             # no record: the newest stage 1
    assert plan.core_anchor(save) == list(C)


def test_a_lone_stage_3_gets_the_cores_stage_2_first(save):
    # after the bp.cancel of the damp core: the new core has stage 1 only, the fort is at P3
    _no_bp(save)
    _core(save, "y497s3b0", 2, B)
    _core(save, "y722s2b0", 1, C, rot=1)
    files.write_json_atomic(save / "bp" / ".placed-fortcore.json", {"anchor": list(C), "rot": 1, "from": "S1",
                                                                    "bp": "y722s2b0"})
    st = _state(save, phase="P3", rows=[["y722s2b0", "s1.zone", 100, ""]])
    applied = plan.applied_builds(save, st)
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=applied, fort={})
    cores = _cores(doc)
    assert ("same", 2) in cores and ("same", 3) in cores
    assert cores.index(("same", 2)) < cores.index(("same", 3))


def test_a_manifest_breach_of_a_retrofit_fortcore_is_no_stopped_core(save):
    # review: the manifest-only path (BUG-162) must not pick up a retrofit fortcore, whose bp file exists
    _no_bp(save)
    _core(save, PID, 1, A)
    p = save / "bp" / f"{PID}.json"
    doc = json.loads(p.read_text("utf-8"))
    doc["params"] = {"stage": 1, "retrofit": 1}
    p.write_text(json.dumps(doc), "utf-8")
    _manifest(save)
    assert plan.core_breaches(save, _state(save)) == []
