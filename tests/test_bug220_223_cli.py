"""BUG-220..223 (live round 4: Trussroads and the fresh fort Earthboat): status clipped the UNREADY line's trap-hall note
and its one next: hint, NEXT said `plan propose` right after the apply that builds the refuge, plan check demanded
refuge_beds no site takes before fortcore stage 3 is dug, and kept explore shafts ran into a cavern level known since."""
import copy
import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import brief, cmd, files, guide, plan, schema
from dfpilot.events import est_tokens

NOW = 1333056                                       # the fixture state's t.abs (y3)
BYPASS = "bypass: wall 75,65,131 ramp (+more) -> 74,65,130"
FAILS = ["open_perimeter", "audit_old", "bypass", "no_outer", "no_kern", "office", "refuge_dry", "hospital_out"]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **extra):
    st = files.read_state(save)
    for k, v in extra.items():
        if v is None:
            st.pop(k, None)
        else:
            st[k] = v
    st["seq"] = st["seq"] + 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


def READY(**kw):
    return dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 100, "min_traps": 0},
                 "fail": ["open_perimeter"], "open": 2}, **kw)


def _unready(out):
    return next(ln for ln in out.splitlines() if ln.startswith("SIEGE UNREADY"))


# ---------------------------------------------------------------- BUG-220: status keeps the note and the command
def _long(save):
    ents = [f"{x},62,117 floor" for x in range(50, 53)]
    put_state(save, ready=READY(open=7, ents=ents, pd=12, pw="w" * 60, route=BYPASS, fail=FAILS, office="o" * 200),
              proj=[["c1a1", "s1.build", 34, ""], ["c1a2", "s1.dig", 5, "waits:Bed"], ["c1a3", "s0.dig", 1, ""]])


def test_status_keeps_the_no_trap_hall_note_under_a_long_unready_line(save):
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [cmd.NO_HALL, BYPASS]}, tick=NOW - 10)])
    _long(save)
    out = brief.status_text(save)
    un = _unready(out)
    assert un.startswith(f"SIEGE UNREADY (R0): {','.join(FAILS)} | no trap hall yet: the bypass waits for fortcore "
                         "stage 2"), un
    assert "next: " in un and un.index("no trap hall") < un.index("next: ") < un.index("PERIMETER OPEN"), un
    assert est_tokens(out) <= brief.STATUS_TOKENS
    full = brief.line_unready(brief.Ctx(save), cmds=True)          # brief: details first, the decision at the end
    assert full.index("audit route:") < full.index("no trap hall yet") < full.index("next: ")


def test_status_keeps_the_one_next_hint_under_a_long_unready_line(save):
    _long(save)                                                     # a trap hall exists: the wall hint comes first
    un = _unready(brief.status_text(save))
    assert f"{','.join(FAILS)} | next: wall it: dfllm cmd bp.place tpl=seal site=S1 at=audit" in un, un
    assert un.count("next:") == 1


# ---------------------------------------------------------------- BUG-221: NEXT waits for the applied refuge build
def _plan_with(save, *builds, year=3):
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    doc["year"] = year
    doc["seasons"][1]["build"] += list(builds)
    assert schema.validate("plan", doc) == []
    files.write_json_atomic(save / "plan.json", doc)
    return doc


def test_next_waits_when_the_applied_plan_builds_the_refuge(save, monkeypatch):
    monkeypatch.setattr(guide, "_hospital_project", lambda save_dir: False)
    put_state(save, ready=READY(fail=["refuge_dry", "no_inner"], open=0, audit={"ok": 1, "age": 100, "min_traps": 40}))
    s = guide.decide(guide.gather(save))
    assert s.cmd == guide.PLAN_CMD and "R0 refuge/fortcore" in s.why     # nothing builds it: propose
    _plan_with(save, {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}, {"tpl": "refuge_drink", "site": "S1"})
    f = guide.gather(save)
    assert f["refuge_proj"] == ["y3s1b1", "y3s1b2"]
    s = guide.decide(f)
    assert s.cmd is None and s.key == "idle" and "the applied plan builds it: y3s1b1, y3s1b2; wait" in s.why, s.why
    files.write_json_atomic(save / "bp" / "y3s1b1.json", {"tpl": "fortcore", "params": {"stage": 3}, "anchor": [1, 2, 3]})
    files.write_json_atomic(save / "bp" / "y3s1b2.json", {"tpl": "refuge_drink", "params": {}, "anchor": [1, 2, 3]})
    append_events(save, [ev(9001, "PROJECT_DONE", "done", {"proj": "y3s1b1"}, tick=NOW - 5),
                         ev(9002, "PROJECT_DONE", "done", {"proj": "y3s1b2"}, tick=NOW - 4)])
    assert guide.decide(guide.gather(save)).cmd == guide.PLAN_CMD     # both done and the fail stays: propose again


def test_next_ignores_cancelled_and_old_core_projects(save, monkeypatch):
    monkeypatch.setattr(guide, "_hospital_project", lambda save_dir: False)
    put_state(save, ready=READY(fail=["no_inner"], open=0, audit={"ok": 1, "age": 100, "min_traps": 40}))
    _plan_with(save, {"tpl": "fortcore", "site": "same", "p": {"stage": 3}})
    (save / "bp" / ".cancelled").mkdir(parents=True, exist_ok=True)
    files.write_json_atomic(save / "bp" / ".cancelled" / "y3s1b1.json", {"tpl": "fortcore", "params": {"stage": 3}})
    # the fort's own (stalled) fortcore stage 1 of an earlier year: no new core, no refuge fix under way
    files.write_json_atomic(save / "bp" / "y1s0b1.json", {"tpl": "fortcore", "params": {"stage": 1}, "anchor": [1, 2, 3]})
    f = guide.gather(save)
    assert f["refuge_proj"] == [], f["refuge_proj"]
    assert guide.decide(f).cmd == guide.PLAN_CMD


def test_next_proposes_when_the_refuge_plan_is_from_an_earlier_year(save, monkeypatch):
    monkeypatch.setattr(guide, "_hospital_project", lambda save_dir: False)
    put_state(save, ready=READY(fail=["refuge_dry"], open=0, audit={"ok": 1, "age": 100, "min_traps": 40}))
    _plan_with(save, {"tpl": "refuge_drink", "site": "S1"}, year=2)  # no bp file: never applied
    f = guide.gather(save)
    assert f["refuge_proj"] == []
    assert guide.PLAN_CMD in [c.cmd for c in guide.candidates(f)]
    put_state(save, ready=READY(fail=["refuge_dry"], open=0, audit={"ok": 1, "age": 100, "min_traps": 40}),
              proj=[["fortcore", "s3.dig", 40, ""]])                   # a running fortcore stage 3
    assert guide.gather(save)["refuge_proj"] == ["fortcore"]


def test_an_audit_seal_is_no_refuge_fix():
    assert guide._refuge_build({"tpl": "seal", "site": "S1", "p": {"at": "audit"}}) is False
    assert guide._refuge_build({"tpl": "seal", "params": {"at": "refuge"}}) is True
    assert guide._refuge_build({"tpl": "refuge_beds", "site": "S1", "p": {"n": 8}}) is True
    assert guide._refuge_build({"tpl": "fortcore", "site": "same", "p": {"stage": 2}}) is False
    assert guide._refuge_build({"tpl": "tombs", "site": "S1"}) is False


# ---------------------------------------------------------------- BUG-222: beds follow fortcore stage 3 at P3+
STAGE3 = {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}


def _ref(errs_warn):
    errs, warn = errs_warn
    return [e for e in errs if e.startswith("refuge")], [w for w in warn if w.startswith("refuge")]


def _refuge(state, beds=0, need=8):
    s = copy.deepcopy(state)
    s.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    s["alert"]["ref"] = {"ex": 1, "sep": 1, "beds": beds, "need": need}
    assert schema.validate("state", s) == []
    return s


def test_refuge_beds_without_a_site_wait_for_stage_3_at_p3_plus(save):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    state = _refuge(files.read_state(save))
    fort = {"refuge": {"fortcore": True, "stage3": False, "beds": 0, "seal": False, "ents": 0, "bed_site": False}}
    doc = copy.deepcopy(prev)                                           # phase_target P4
    doc["seasons"][1]["build"].append(STAGE3)

    def gate(d, ft):
        return _ref(plan.check(d, state, decisions={}, banned=plan.BANNED, prev=prev, fort=ft))
    errs, warn = gate(doc, fort)
    assert errs == [] and warn == ["refuge: Tiefe+ has 0 beds < 8; beds follow fortcore stage 3 (no refuge room takes "
                                   "refuge_beds yet): apply, wait for s3.dig, propose again"], (errs, warn)
    under = {"refuge": dict(fort["refuge"], stage3=True)}              # stage 3 under way, none in this plan
    assert gate(copy.deepcopy(prev), under)[0] == []
    errs, warn = gate(copy.deepcopy(prev), fort)                       # no stage 3 anywhere and no site: BUG-321
    assert errs == [] and any(w.startswith("refuge: Tiefe+ has 0 beds < 8; no free site") for w in warn), (errs, warn)
    errs, _ = gate(doc, {"refuge": dict(fort["refuge"], bed_site=True)})   # a site exists: refuge_beds is asked
    assert any('"tpl":"refuge_beds"' in e for e in errs), errs


# ---------------------------------------------------------------- BUG-223: kept explore shafts and known caverns
def test_kept_explore_reaching_a_known_cavern_level_gets_its_cancel(save, monkeypatch):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    prev["seasons"][3]["build"] = [{"tpl": "explore", "site": "S1"}]
    prev["seasons"][2]["build"].append({"tpl": "explore", "site": "S1", "p": {"depth": 4}})
    files.write_json_atomic(save / "plan.json", prev)
    files.write_json_atomic(save / "bp" / "y3s3b0.json", {"tpl": "explore", "params": {"depth": 12}, "anchor": [50, 77, 135]})
    files.write_json_atomic(save / "bp" / "y3s2b1.json", {"tpl": "explore", "params": {"depth": 4}, "anchor": [60, 70, 135]})
    doc = copy.deepcopy(prev)
    monkeypatch.setattr(plan, "_kern_manifest", lambda d: {})
    assert plan.fit_explore_kept(save, doc, prev) == []                # no cavern known: nothing to say
    monkeypatch.setattr(plan, "_kern_manifest", lambda d: {"caverns": [[46, 77, 123], [70, 68, 123]]})
    lines = plan.fit_explore_kept(save, doc, prev)
    assert lines == ["explore y3s3b0 (depth 12 from z135) reaches the known cavern level z123 (manifest caverns): dfllm "
                     "cmd bp.cancel proj=y3s3b0, then propose again (a new explore gets a depth above it)"], lines
    assert "explore y3s3b0 reaches the cavern level z123: dfllm cmd bp.cancel proj=y3s3b0" in doc["notes"]
    assert plan.stable_ids(doc, prev) == []                            # the kept build itself is unchanged
    append_events(save, [ev(9001, "PROJECT_DONE", "done", {"proj": "y3s3b0"}, tick=NOW - 5)])
    assert plan.fit_explore_kept(save, copy.deepcopy(prev), prev) == []   # done: nothing to cancel
    assert plan.fit_explore_kept(save, dict(copy.deepcopy(prev), year=4), prev) == []   # another year: nothing kept
