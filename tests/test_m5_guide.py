"""M5 guidance (FR-86 .. FR-88): the stale-plan alarm and the minimal plan, the hook check of `doctor`, the `view` verb, the
camera suggestion of the wake lines. `dfllm next` (FR-85) is tests/test_m5_next.py; the Lua side is tests/lua/test_view.lua."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import files, schema
from dfpilot.cli import main
from dfpilot.cmd import parse_kv

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "v2" / "runtime" / "region7"
NOW = 1333056                                       # the fixture state's t.abs (y3)


@pytest.fixture
def save(tmp_path, monkeypatch):
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


def put_plan(save, year):
    plan = json.loads((FIXTURE / "plan.json").read_text("utf-8"))
    plan["year"] = year
    files.write_json_atomic(save / "plan.json", plan)


def A(n, typ, msg="", d=None, tick=NOW - 100):
    return ev(n, typ, msg, d, tick=tick)


# ================================================================ FR-86: the stale plan
from dfpilot import brief, plan, wake                                    # noqa: E402
from cli_v2_helpers import FIX, FakeKern, install_fake_bp                 # noqa: E402

TINFO = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
         for t in ("fortcore", "tombs", "temple", "bedrooms", "tavern", "hospital", "dining", "workshops")}


def at_year(save, year, **kw):
    st = files.read_state(save)
    put_state(save, t=dict(st["t"], y=year, abs=year * 403200 + st["t"]["tick"]), **kw)


def head(save):
    return brief.status_text(save).splitlines()[0]


def test_status_line_one_says_the_plan_is_stale(save):
    assert "PLAN" not in head(save)                                    # y3 with a plan for y3
    at_year(save, 4)
    assert "PLAN" not in head(save)                                    # one year without an apply is a review, not an alarm
    at_year(save, 708)
    put_plan(save, 503)
    assert head(save).endswith(" | PLAN STALE: applied y503, now y708")
    assert "PLAN STALE: applied y503, now y708" in brief.brief_text(save).splitlines()[0]
    (save / "plan.json").unlink()
    assert " | PLAN NONE: no plan applied" in head(save)


def test_status_line_names_the_plan_follow_applied(save):
    plan_doc = json.loads((FIXTURE / "plan.json").read_text("utf-8"))
    plan_doc["notes"] = plan.MINIMAL_TAG + ": follow applied it"
    files.write_json_atomic(save / "plan.json", plan_doc)
    assert head(save).endswith(" | PLAN MINIMAL (by follow): replace it with dfllm plan propose")
    at_year(save, 9)
    assert head(save).endswith(" | PLAN STALE: applied y3, now y9 (minimal, by follow)")


def test_the_status_stays_in_its_budget_with_the_flag(save):
    at_year(save, 708)
    put_plan(save, 503)
    text = brief.status_text(save)
    assert "PLAN STALE: applied y503, now y708" in text and brief.est_tokens(text) <= brief.STATUS_TOKENS


def test_fixes_of_reads_the_repairs_the_errors_name():
    errs = ['audit: a bypass; add {"tpl":"seal","site":"S1","p":{"at":"audit"}} as the first build of seasons[1] (x)',
            'refuge: none; add {"tpl":"fortcore","site":"same","p":{"stage":3}} (the refuge); or add {"tpl":"seal","site":"S1",'
            '"p":{"at":"audit"}} again',
            'metal: no route; add tpl explore (site S1)', 'broken add {"tpl": ', 'bad add {"tpl":"X Y","site":"S1"}']
    assert plan.fixes_of(errs) == [{"tpl": "seal", "site": "S1", "p": {"at": "audit"}},
                                   {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]


def test_minimal_ok_is_the_short_list():
    ok = [{"tpl": t, "site": "S1"} for t in ("seal", "tombs", "hospital", "farms", "cistern", "stockroom", "refuge_beds",
                                             "refuge_drink")]
    ok += [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}, {"tpl": "workshops", "site": "S1",
                                                                     "p": {"add": "Still", "skip": ",".join(plan._moodable())}}]
    assert all(plan.minimal_ok(b) for b in ok)
    no = [{"tpl": t, "site": "S1"} for t in ("temple", "tavern", "bedrooms", "dining", "barracks", "explore")]
    no += [{"tpl": "fortcore", "site": "same", "p": {"stage": 4}}, {"tpl": "fortcore", "site": "S1"}]
    assert not any(plan.minimal_ok(b) for b in no)


def test_the_minimal_plan_keeps_only_the_short_list_and_no_star(save):
    at_year(save, 6)
    state = files.read_state(save)
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    doc, errs, _ = plan.minimal_plan(save, state, phases, tinfo=TINFO, decisions={}, tpls=list(TINFO))
    assert errs == [] and schema.validate("plan", doc) == []
    built = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
    assert built == ["fortcore", "tombs"], built                        # the draft also held a temple
    assert doc["year"] == 6 and doc["phase_target"] == state["phase"]
    assert doc["notes"].startswith(plan.MINIMAL_TAG) and "2 new builds" in doc["notes"]
    full = plan.propose(state, phases, plan.applied_plan(save), decisions={}, tinfo=TINFO,
                        applied=plan.applied_builds(save, state))
    assert full["phase_target"] > doc["phase_target"] and "temple" in [b["tpl"] for se in full["seasons"] for b in se["build"]]


def test_the_minimal_plan_adds_the_repairs_the_errors_name_and_nothing_else(save, monkeypatch):
    at_year(save, 6)
    state = files.read_state(save)
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    seal = {"tpl": "seal", "site": "S1", "p": {"at": "last"}}
    temple = {"tpl": "temple", "site": "S1"}
    real = plan.check
    rounds = []

    def fake_check(doc, st, **kw):
        errs, warn = real(doc, st, **kw)
        have = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
        rounds.append(have)
        if "seal" not in have:
            errs = errs + ['audit: a bypass; add ' + json.dumps(seal, separators=(",", ":")) + ' as the first build']
        if "temple" not in have:
            errs = errs + ['stress: add ' + json.dumps(temple, separators=(",", ":")) + ' (FR-74)']
        return errs, warn
    monkeypatch.setattr(plan, "check", fake_check)
    doc, errs, _ = plan.minimal_plan(save, state, phases, tinfo=TINFO, decisions={}, tpls=[*TINFO, "seal"])
    assert [b["tpl"] for se in doc["seasons"] for b in se["build"]][:1] == ["seal"]       # the repair went in, first
    assert "temple" not in [b["tpl"] for se in doc["seasons"] for b in se["build"]]       # a non-minimal repair did not
    assert len(errs) == 1 and "temple" in errs[0] and len(rounds) == 2                    # and its error stays: not applied
    errs2, msg = plan.apply_minimal(save, wait_s=0)
    assert errs2 and msg == "not applied" and not (save / "bp" / "y6s1b0.json").exists()


def test_apply_minimal_writes_the_plan_and_the_status_names_it(save, monkeypatch):
    install_fake_bp(monkeypatch)
    at_year(save, 6)
    monkeypatch.setattr(plan, "load_phases", lambda path=None: json.loads((FIX / "phases.json").read_text("utf-8")))
    with FakeKern(save, lambda d: (True, "plan y6 loaded", {"year": 6})) as k:
        errs, msg = plan.apply_minimal(save, by="follow", wait_s=5)
    assert errs == [] and "plan.reload" in msg and [d["by"] for d in k.seen] == ["follow"]
    written = json.loads((save / "plan.json").read_text("utf-8"))
    assert written["year"] == 6 and plan.is_minimal(written) and written["phase_target"] == "P3"
    assert head(save).endswith(" | PLAN MINIMAL (by follow): replace it with dfllm plan propose")


# ---------------------------------------------------------------- follow applies it, once a year, and remembers
class Clock:
    def __init__(self, t=2_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def follower(clock, **kw):
    out = []
    return wake.Follower(out=out.append, clock=clock, **kw), out


@pytest.fixture
def applied(monkeypatch):
    calls = []

    def fake(save_dir, by="follow", wait_s=5.0):
        calls.append(by)
        return [], "plan.json y6 + 2 bp; ok plan.reload"
    monkeypatch.setattr(plan, "apply_minimal", fake)
    return calls


def test_follow_applies_the_minimal_plan_after_two_years_once(save, applied):
    c = Clock()
    f, out = follower(c)
    at_year(save, 4)
    f.poll()
    assert applied == []                                               # plan y3, now y4: a year, not two
    at_year(save, 5)
    c.t += 301
    f.poll()
    assert applied == ["follow"] and f.plan_auto == {"tried_y": 5, "applied_y": 5}
    c.t += 301
    f.poll()
    assert applied == ["follow"], "once per game year"
    c.t += 11
    f.poll()
    assert any("PLAN_AUTO" in x and "no plan applied since y3, now y5" in x for x in out)
    st = json.loads((save / ".follow.json").read_text("utf-8"))
    assert st["plan_auto"] == {"tried_y": 5, "applied_y": 5}
    f2, _ = follower(c)                                                # a restart of follow: the memory is the file
    c.t += 301
    f2.poll()
    assert applied == ["follow"] and f2.plan_auto == {"tried_y": 5, "applied_y": 5}
    at_year(save, 6)
    c.t += 301
    f2.poll()
    assert applied == ["follow", "follow"]                             # the next year again, if nobody applied one


def test_follow_counts_from_the_first_year_it_saw_no_plan(save, applied):
    (save / "plan.json").unlink()
    c = Clock()
    f, _ = follower(c)
    f.poll()
    assert f.plan_auto == {"first_y": 3} and applied == []
    f.save_state()
    at_year(save, 5)
    c.t += 301
    f2, _ = follower(c)
    f2.poll()
    assert applied == ["follow"] and f2.plan_auto["first_y"] == 3


@pytest.mark.parametrize("why", ["off", "noauto", "siege", "no_state"])
def test_follow_leaves_the_plan_alone(save, applied, tmp_path, why):
    at_year(save, 9)
    kw = {}
    if why == "off":
        cfg = tmp_path / "config"
        cfg.mkdir(exist_ok=True)
        (cfg / "baseline.json").write_text(json.dumps({"plan": {"stale_apply_years": 0}}), encoding="utf-8")
    elif why == "noauto":
        kw["auto"] = False
    elif why == "siege":
        put_state(save, mode="SIEGE")
    else:
        for slot in "ab":
            (save / f"state.{slot}.json").write_text("{", encoding="utf-8")
    f, _ = follower(Clock(), **kw)
    f.poll()
    assert applied == []


def test_the_years_come_from_the_config(save, applied, tmp_path):
    cfg = tmp_path / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "baseline.json").write_text(json.dumps({"plan": {"stale_apply_years": 4}}), encoding="utf-8")
    assert plan.stale_years() == 4
    at_year(save, 6)
    f, _ = follower(Clock())
    f.poll()
    assert applied == []
    at_year(save, 7)
    f.poll()
    assert applied == []                                               # the poll cadence: 300 s, not at once
    c = Clock(f.clock() + 301)
    f.clock = c
    f.poll()
    assert applied == ["follow"]
    (cfg / "baseline.json").write_text(json.dumps({"plan": {"stale_apply_years": 99}}), encoding="utf-8")
    assert plan.stale_years() == plan.STALE_DEF                        # a bad value keeps the default


def test_a_minimal_plan_that_does_not_check_wakes_auto_fail(save, monkeypatch):
    monkeypatch.setattr(plan, "apply_minimal", lambda *a, **k: (["audit: a bypass; add tpl explore"], "not applied"))
    at_year(save, 9)
    c = Clock()
    f, out = follower(c)
    f.poll()
    c.t += 11
    f.poll()
    assert any("AUTO_FAIL" in x and "minimal plan" in x and "a bypass" in x for x in out), out
    assert f.plan_auto == {"tried_y": 9}


def test_config_lint_knows_the_plan_key(tmp_path):
    from dfpilot import fairplay
    assert fairplay.plan_errors() == []
    p = tmp_path / "b.json"
    p.write_text(json.dumps({"plan": {"stale_apply_years": 99, "x": 1}}), encoding="utf-8")
    assert fairplay.plan_errors(p) == ["config/baseline.json: plan.stale_apply_years: int 0..20 expected, got 99",
                                       "config/baseline.json: plan.x: unknown key"]
    assert json.loads((Path(__file__).resolve().parent.parent / "config" / "baseline.json")
                      .read_text("utf-8"))["plan"] == {"stale_apply_years": plan.STALE_DEF}


# ---------------------------------------------------------------- the YEAR_REVIEW wake names the fixes
def test_year_review_wake_carries_the_stale_plan_and_the_fixes(save, monkeypatch):
    seal = '{"tpl":"seal","site":"S1","p":{"at":"audit"}}'
    real = plan.check

    def fake_check(doc, st, **kw):
        errs, warn = real(doc, st, **kw)
        return errs + [f"audit: a bypass; add {seal} as the first build"], warn
    monkeypatch.setattr(plan, "check", fake_check)
    monkeypatch.setattr(plan, "load_phases", lambda path=None: json.loads((FIX / "phases.json").read_text("utf-8")))
    monkeypatch.setattr(plan, "templates", lambda: [*TINFO, "seal"])
    at_year(save, 708)
    put_plan(save, 503)
    note = plan.review_note(save)
    assert note.startswith("PLAN STALE y503->y708; propose: 1 ERROR: fix add " + seal), note
    assert brief.est_tokens(note) <= plan.NOTE_TOKENS
    g = wake.WakeGate()
    g.add(A(9001, "YEAR_REVIEW", "year 707 done", {"year": 707}), 0)
    line = wake.wake_line(g.flush(30), files.read_state(save), review=note)
    assert "YEAR_REVIEW: year 707 done | PLAN STALE y503->y708" in line and "next: dfllm plan propose y.json" in line
    assert brief.est_tokens(line) <= wake.WAKE_TOKENS
    c = Clock()
    f, out = follower(c)
    f.poll()
    append_events(save, [A(9002, "YEAR_REVIEW", "year 707 done", {"year": 707}, tick=708 * 403200)])
    f.poll()
    c.t += 11
    f.poll()
    assert any("YEAR_REVIEW" in x and "PLAN STALE y503->y708" in x for x in out), out


def test_a_current_plan_has_no_review_note_only_the_errors(save, monkeypatch):
    monkeypatch.setattr(plan, "load_phases", lambda path=None: None)
    assert plan.review_note(save) == ""
    monkeypatch.setattr(plan, "propose", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    assert plan.review_note(save) == ""                                # a failure is silent: the wake line goes out


# ================================================================ FR-88: the view verb
def test_view_is_a_verb_with_checked_args():
    assert schema.VERBS["view"] == ("arbiter", None, False)
    ok = [{}, {"target": 39230}, {"target": [77, 67, 128]}, {"target": "77,67,128"}, {"target": "bld:12"},
          {"target": "Oddom"}, {"target": "y3s0b1", "why": "the hospital"}, {"target": 7, "follow": True, "ttl_s": 300}]
    for a in ok:
        assert schema.validate_args("view", a) == [], a
    for a in ({"target": [1, 2]}, {"target": -5}, {"target": ""}, {"target": "x" * 61}, {"target": 7, "ttl_s": 0},
              {"target": 7, "ttl_s": 3601}, {"target": 7, "follow": "yes"}, {"target": 7, "speed": 3},
              {"target": "a\nb"}):
        assert schema.validate_args("view", a), a
    assert parse_kv(["target=39230", "follow=true", "ttl_s=60"]) == {"target": 39230, "follow": True, "ttl_s": 60}
    assert parse_kv(["target=77,67,128"]) == {"target": "77,67,128"}


def test_the_cli_sends_view_to_the_inbox(save):
    from cli_v2_helpers import FakeKern
    with FakeKern(save, lambda d: (True, "camera on 77,67 z128", {"pos": [77, 67, 128]})) as k:
        assert main(["--runtime", str(save.parent), "cmd", "view", "target=77,67,128", "follow=true", "--wait", "5"]) == 0
    assert k.seen[0]["verb"] == "view" and k.seen[0]["args"] == {"target": "77,67,128", "follow": True}


def test_contract_lua_and_schema_agree_on_the_new_names():
    root = Path(__file__).resolve().parent.parent
    lua = (root / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "['view'] = {mod = 'arbiter'}" in lua and "POPUP_GONE = {cls = 'C', by = 'arbiter'}" in lua
    assert "view_to = {'arbiter'}" in lua and "view_window = {'arbiter'}" in lua
    assert schema.ACT["view_to"] == ["arbiter"] and schema.ACT["view_window"] == ["arbiter"]
    assert schema.EVENTS["POPUP_GONE"][:2] == ("C", "arbiter")
    assert schema.validate("event", {"n": 5, "tick": 9, "type": "POPUP_GONE", "cls": "C", "msg": "1 popup gone",
                                     "d": {"n": 1, "text": "x", "kind": "death"}}) == []


# ---------------------------------------------------------------- wake lines carry a ready view command
def _burst(*evs):
    g = wake.WakeGate()
    for e in evs:
        g.add(e, 0)
    return g.flush(30)


def test_wake_line_suggests_the_camera_on_the_unit_or_the_place(save):
    st = files.read_state(save)
    line = wake.wake_line(_burst(A(5, "INTRUDER", "a goblin", {"id": 39230, "pos": [77, 67, 128], "n": 1})), st)
    assert line.endswith(" | show: dfllm cmd view target=39230"), line
    line = wake.wake_line(_burst(A(5, "MOOD_CRITICAL", "Urist", {"unit": 55, "why": "x", "pos": [29, 118, 126]})), st)
    assert "show: dfllm cmd view target=55" in line
    line = wake.wake_line(_burst(A(5, "BUILDING_TOPPLED", "a statue", {"what": "statue", "by": "Urist", "pos": [3, 4, 5]})),
                          st)
    assert wake.show_hint(_burst(A(5, "BUILDING_TOPPLED", "a statue", {"what": "s", "by": "U", "pos": [3, 4, 5]})), st) == \
        "show: dfllm cmd view target=3,4,5"
    line = wake.wake_line(_burst(A(5, "PATIENT_DYING", "2 patients", {"units": [77, 78], "n": 2, "thirst": 62000, "carers": 1,
                                                                       "want": 5, "hosp": "ok"})), st)
    assert "show: dfllm cmd view target=77" in line
    assert "show:" not in wake.wake_line(_burst(A(5, "KERN_FAULT", "x", {"module": "runner"})), st)
    for l in (wake.wake_line(_burst(A(5, "INTRUDER", "a goblin", {"id": 39230, "pos": [77, 67, 128]})), st),):
        assert brief.est_tokens(l) <= wake.WAKE_TOKENS


def test_in_a_fight_the_suggestion_is_the_players_command(save):
    st = files.read_state(save)
    by = {"id": 39230, "race": "GOBLIN", "k": "inv", "pos": [77, 67, 128], "dc": 10, "de": 58, "hl": 1, "n": 1, "sz": 6}
    st = dict(st, mode="BREACH", alarm={"defcon": 1, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "breach", "by": by})
    line = wake.wake_line(_burst(A(5, "BREACH", "breach", {"why": "destroyed", "bridge": "O1"})), st)
    assert line.endswith(" | show (the player, in a fight): dfllm cmd view target=39230 --by gordon"), line
    assert brief.est_tokens(line) <= wake.WAKE_TOKENS
    by["id"] = -1
    assert wake.show_hint(_burst(A(5, "BREACH", "breach", {"why": "x"})), st).endswith("target=77,67,128 --by gordon")
    assert wake.show_hint(_burst(A(5, "BREACH", "breach", {"why": "x"})), dict(st, alarm=None)) == ""


# ================================================================ FR-87: the hook check of doctor
from dfpilot import doctor                                                # noqa: E402

HOOK_SETTINGS = {"hooks": {"PreToolUse": [{"matcher": "Bash|PowerShell|Monitor|Write|Edit", "hooks": [
    {"type": "command", "shell": "bash", "command": 'cd "${CLAUDE_PROJECT_DIR:-.}" && python -m dfpilot.hook'}]}]}}
REPO = Path(__file__).resolve().parent.parent


def _project(tmp_path, name, settings=HOOK_SETTINGS, hook=True):
    d = tmp_path / name
    (d / ".claude").mkdir(parents=True)
    if settings is not None:
        (d / ".claude" / "settings.json").write_text(json.dumps(settings), encoding="utf-8")
    if hook:
        (d / "dfpilot").mkdir()
        (d / "dfpilot" / "hook.py").write_text("", encoding="utf-8")
    return d


def test_hook_check_in_the_repo_is_active():
    state, text = doctor.hook_check({"CLAUDE_PROJECT_DIR": str(REPO)}, cwd=REPO, home=Path("/nonexistent"))
    assert state == "active" and "Bash is covered" in text
    shipped = json.loads((REPO / ".claude" / "settings.json").read_text("utf-8"))                    # the hook the repo ships
    assert doctor._hook_entries(shipped) and all(doctor._covers_bash(m) for m, _ in doctor._hook_entries(shipped))


def test_hook_check_in_the_parent_folder_says_not_active(tmp_path):
    parent = tmp_path / "claude gordons projects"
    parent.mkdir()
    repo = _project(parent, "dfpilot-public")
    env = {"CLAUDE_PROJECT_DIR": str(parent)}
    state, text = doctor.hook_check(env, cwd=repo, home=tmp_path / "home")
    assert state == "inactive" and text.startswith("hook: not active in this session") and str(parent) in text
    assert "Start Claude Code inside the repo folder" in text
    # without CLAUDE_PROJECT_DIR the shell that walked into the repo looks right (the nearest .claude folder): the check
    # cannot see where the session started; the doc names CLAUDE_PROJECT_DIR and hook.log as the live evidence
    assert doctor.hook_check({"CLAUDECODE": "1"}, cwd=repo, home=tmp_path / "home")[0] == "active"
    assert doctor.hook_check({"CLAUDECODE": "1"}, cwd=parent, home=tmp_path / "home")[0] == "inactive"


def test_hook_check_other_states(tmp_path):
    home = tmp_path / "home"
    nohook = _project(tmp_path, "a", hook=False)
    state, text = doctor.hook_check({"CLAUDE_PROJECT_DIR": str(nohook)}, cwd=nohook, home=home)
    assert state == "broken" and "cannot be reached" in text and "dfpilot/hook.py" in text
    wrong = _project(tmp_path, "b", settings={"hooks": {"PreToolUse": [{"matcher": "Read", "hooks": [
        {"type": "command", "command": "python -m dfpilot.hook"}]}]}})
    assert doctor.hook_check({"CLAUDE_PROJECT_DIR": str(wrong)}, cwd=wrong, home=home)[0] == "inactive"      # not Bash
    empty = _project(tmp_path, "c", settings=None)
    assert doctor.hook_check({"CLAUDE_PROJECT_DIR": str(empty)}, cwd=empty, home=home)[0] == "inactive"
    (empty / ".claude" / "settings.json").write_text("{not json", encoding="utf-8")
    assert doctor.hook_check({"CLAUDE_PROJECT_DIR": str(empty)}, cwd=empty, home=home)[0] == "inactive"
    state, text = doctor.hook_check({}, cwd=empty, home=home)
    assert state == "skip" and "not a Claude Code session" in text
    # a user-level hook with a fixed `cd` into a clone counts
    (home / ".claude").mkdir(parents=True)
    (home / ".claude" / "settings.json").write_text(json.dumps({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
        {"type": "command", "command": f'cd "{REPO}" && python -m dfpilot.hook'}]}]}}), encoding="utf-8")
    state, text = doctor.hook_check({"CLAUDE_PROJECT_DIR": str(empty)}, cwd=empty, home=home)
    assert state == "active" and str(REPO) in text


def test_doctor_reports_an_inactive_hook_as_a_problem_and_the_vanished_popups(save, tmp_path, monkeypatch, capsys):
    parent = tmp_path / "parent"
    parent.mkdir()
    monkeypatch.setenv("CLAUDE_PROJECT_DIR", str(parent))
    monkeypatch.chdir(parent)
    append_events(save, [{"n": 8830, "tick": NOW - 100, "type": "POPUP_GONE", "cls": "C", "msg": "1 popup gone",
                          "d": {"n": 2, "text": "Oddom has been cursed by Ok!"}}])
    lines, bad = doctor.diagnose(save)
    assert any(b.startswith("hook: not active in this session") for b in bad)
    assert any(x.startswith("2 popups vanished without a kernel dismiss in the last 7 game days (last: "
                            "\"Oddom has been cursed by Ok!\")") for x in lines), lines
    assert main(["--runtime", str(save.parent), "doctor"]) == 1
    assert "hook: not active in this session" in capsys.readouterr().out
    monkeypatch.setenv("CLAUDE_PROJECT_DIR", str(REPO))
    lines, bad = doctor.diagnose(save)
    assert not [b for b in bad if b.startswith("hook:")] and any(x.startswith("hook: active") for x in lines)
    monkeypatch.delenv("CLAUDE_PROJECT_DIR")
    for k in doctor.SESSION_ENV:
        monkeypatch.delenv(k, raising=False)
    lines, bad = doctor.diagnose(save)
    assert any(x.startswith("hook: not checked") for x in lines) and not [b for b in bad if b.startswith("hook:")]
    assert doctor.popup_gone_line(save, NOW + 8 * 1200) is None                     # older than a game week


# ---------------------------------------------------------------- the documents say it
def test_quickstart_demands_the_repo_folder_and_names_next():
    text = (REPO / "docs" / "v2" / "QUICKSTART.md").read_text("utf-8")
    assert "INSIDE that folder" in text and "hook: not active in this session" in text
    assert "python -m dfpilot next" in text and "PLAN STALE" in text and "stale_apply_years" in text
    rules = (REPO / "RULES.md").read_text("utf-8")
    assert "dfllm next" in rules and "`ack` / `view`" in rules and len(rules.splitlines()) <= 300


def test_config_lint_knows_the_view_keys(tmp_path):
    from dfpilot import fairplay
    assert fairplay.view_errors() == []
    cfg = json.loads((REPO / "config" / "baseline.json").read_text("utf-8"))
    assert cfg["view"] == {"on": True, "default_ttl_s": 300, "max_ttl_s": 900}
    p = tmp_path / "b.json"
    p.write_text(json.dumps({"view": {"on": "yes", "default_ttl_s": 0, "max_ttl_s": 5000, "speed": 1}}), encoding="utf-8")
    assert fairplay.view_errors(p) == ["config/baseline.json: view.on: true or false expected, got 'yes'",
                                       "config/baseline.json: view.default_ttl_s: int 1..3600 expected, got 0",
                                       "config/baseline.json: view.max_ttl_s: int 1..3600 expected, got 5000",
                                       "config/baseline.json: view.speed: unknown key"]
    p.write_text(json.dumps({"view": {"default_ttl_s": 800, "max_ttl_s": 600}}), encoding="utf-8")
    assert "default_ttl_s 800 > max_ttl_s 600" in fairplay.view_errors(p)[0]
