"""M5 / FR-85: `dfllm next`, the one most urgent action (dfpilot/guide.py). The other parts of the package are in
tests/test_m5_guide.py."""
import json
import shlex
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import cli, files, guide, schema
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


def WATER(patients=3, thirst=61000):
    return {"patients": patients, "thirst_max": thirst, "hosp_ok": 1, "refuge_ok": 1, "buckets_free": 2, "hosp": 1,
            "src": [[1, 2, 3]]}


@pytest.fixture
def no_hospital_project(monkeypatch):
    """The fixture runtime holds a hospital bp file that no PROJECT_DONE closes: a hospital project under way."""
    monkeypatch.setattr(guide, "_hospital_project", lambda save_dir: False)


def A(n, typ, msg="", d=None, tick=NOW - 100):
    return ev(n, typ, msg, d, tick=tick)


def step(save, tried=()):
    return guide.decide(guide.gather(save), tried)


def green(save):
    """The fixture fort with R1 and a plan for the current year: nothing to do."""
    put_state(save)


# ---------------------------------------------------------------- the priority list
def test_green_fort_says_nothing(save):
    s = step(save)
    assert (s.key, s.cmd) == ("idle", None)
    assert s.lines()[0] == "NEXT: nothing" and s.lines()[1].startswith("WHY: green: PEACE R1")


def test_unacked_interrupts_come_first_and_name_the_last_one(save):
    al = {"defcon": 3, "unacked": 2, "last": 8820, "ack": 8810, "lock": 0, "why": ""}
    put_state(save, alarm=al, mode="ALERT", threat={"vis": 2, "armed": 1})
    (save / "alarm.txt").write_text("DEFCON 3 | mode ALERT | unacked 2 | last 8820 | ack 8810 | lockdown off\n"
                                    "8819\t1\t1333000\tPREDATOR\tunacked\ta cougar near the farms\n"
                                    "8820\t2\t1333010\tINTRUDER\tunacked\tgoblin at the gate\n", encoding="utf-8")
    s = step(save)
    assert (s.key, s.cmd) == ("interrupt", "dfllm ack")
    assert "2 interrupts unacked (last #8820 INTRUDER: goblin at the gate)" in s.why
    assert s.tell == "INTRUDER: goblin at the gate"


def test_visible_danger_waits_and_tells_the_player(save):
    put_state(save, mode="SIEGE", threat={"vis": 7, "armed": 1})
    s = step(save)
    assert s.key == "danger" and s.cmd == guide.WAIT
    assert "SIEGE: 7 hostile visible" in s.why and "nothing tactical" in s.why and s.tell and s.show is None


def test_a_lockdown_cause_is_named(save):
    by = {"id": 300, "race": "GOBLIN", "k": "inv", "pos": [77, 67, 128], "dc": 10, "de": 58, "hl": 1, "n": 1, "sz": 4000}
    al = {"defcon": 3, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:invader", "age": 5040, "lim": 12000,
          "qw": "near", "by": by}
    put_state(save, mode="ALERT", alarm=al, threat={"vis": 1, "armed": 1})
    s = step(save)
    assert s.key == "danger" and "cause inv 300 GOBLIN at 77,67,128, harmless" in s.why
    # FR-88: in a fight the camera is the player's: the line is his command
    assert s.show == "dfllm cmd view target=300" and s.show_by_player
    assert s.lines()[-1] == "SHOW (the player runs it): dfllm cmd view target=300 --by gordon"


def test_cursed_citizens_are_danger_too(save):
    """BUG-115 (M4) adds the state key `curse` and the class-A events CURSED / TRANSFORM / CURSE_MOON. The state key is
    injected into the facts here (an older kernel's schema would prune it from the file), the event comes from the log."""
    f = guide.gather(save)
    f["state"]["curse"] = {"n": 3, "tf": 1, "ids": [41, 42, 43], "mi": 9}
    s = guide.decide(f)
    assert (s.key, s.cmd) == ("curse", "dfllm brief")
    assert "3 cursed citizens, 1 in were-form now, next full moon in 9 d" in s.why
    assert s.show == "dfllm cmd view target=41"
    assert "9 days" in s.tell
    assert not s.show_by_player and s.lines()[-1] == "SHOW: dfllm cmd view target=41"
    f["state"]["mode"] = "ALERT"                                       # in a fight the camera is the player's
    cur = [c for c in guide.candidates(f) if c.key == "curse"][0]
    assert cur.show_by_player and cur.lines()[-1].endswith("view target=41 --by gordon")
    assert step(save).key == "idle"
    append_events(save, [{"n": 8830, "tick": NOW - 50, "type": "CURSED", "cls": "A", "msg": "Oddom cursed by Ok",
                          "d": {"n": 2}}])
    s = step(save)
    assert s.key == "curse" and s.why.startswith("2 cursed citizens")


def test_dying_patients(save):
    put_state(save, water=WATER())
    s = step(save)
    assert s.key == "dying" and json.loads(shlex.split(s.cmd)[3]) == {"what": "water_sources"}
    assert "3 patients near the thirst death line (thirst 61000)" in s.why
    put_state(save, water=WATER(thirst=30000))
    assert step(save).key == "idle"
    append_events(save, [A(8820, "PATIENT_DYING", "2 patients", {"units": [77, 78], "n": 2, "thirst": 62000, "carers": 1,
                                                              "want": 5, "hosp": "ok", "why": "no buckets"})])
    s = step(save)
    assert s.key == "dying" and "carers 1 of 5 wanted: no buckets" in s.why and s.show == "dfllm cmd view target=77"
    assert s.lines()[-1] == "SHOW: dfllm cmd view target=77"


def test_a_mood_dwarf_until_his_mood_ends(save):
    crit = A(8821, "MOOD_CRITICAL", "Urist in a mood", {"unit": 55, "why": "thirst", "thirst": 52000, "ws": "Craftsdwarfs",
                                                         "name": "Urist", "pos": [29, 118, 126], "missing": ["bone"]})
    append_events(save, [crit])
    s = step(save)
    assert (s.key, s.cmd) == ("mood", "dfllm brief")
    assert "Urist (55) in a mood at the Craftsdwarfs 29,118,126, thirst 52000, missing bone" in s.why
    assert s.show == "dfllm cmd view target=55"
    append_events(save, [A(8822, "MOOD_END", "done", {"unit": 55}, tick=NOW - 50)])
    assert step(save).key == "idle"


def test_a_mood_event_older_than_two_days_is_history(save):
    append_events(save, [A(8821, "MOOD_CRITICAL", "Urist", {"unit": 55, "why": "x"}, tick=NOW - 3 * 1200)])
    assert step(save).key == "idle"


def test_no_plan_a_past_year_and_a_stale_plan(save):
    (save / "plan.json").unlink()
    s = step(save)
    assert (s.key, s.cmd) == ("plan", guide.PLAN_CMD) and "no plan applied yet" in s.why
    put_plan(save, 2)
    s = step(save)
    assert s.key == "plan" and "year review due: the plan is for y2, now y3" in s.why and s.tell is None
    put_plan(save, 1)
    s = step(save)
    assert s.key == "plan" and "PLAN STALE: applied y1, now y3" in s.why and "kernel builds only what an approved plan" in s.tell
    put_plan(save, 4)                                    # a plan for the next year is current
    assert step(save).key == "idle"


def test_a_waiting_draft_is_checked_before_a_new_one_is_proposed(save):
    put_plan(save, 2)
    draft = json.loads((save / "plan.json").read_text("utf-8"))
    draft["year"] = 3
    files.write_json_atomic(save / "plan.draft.json", draft)
    s = step(save)
    assert (s.key, s.cmd) == ("plan", "dfllm plan check") and "a draft waits" in s.why


def test_r0_blockers_in_order(save, no_hospital_project):
    put_state(save, ready={"lvl": 0, "worn": 94, "cv": 13, "drill_age": -1, "audit": {"age": -1, "ok": 0, "min_traps": 0},
                           "fail": ["audit", "open_perimeter", "hospital_out", "no_refuge"], "open": 2, "pd": 9,
                           "pw": "x,y,z door"})
    got = []
    for _ in range(5):
        s = step(save, tried=tuple(got))
        if s.cmd is None:
            break
        got.append(s.cmd)
    assert got == [guide.SEAL_CMD, "dfllm audit", guide.HOSPITAL_CMD, guide.PLAN_CMD]
    s = step(save, tried=tuple(got))
    assert s.key == "idle" and "tried 3x with no change" in s.why and "I am stuck" in s.tell


def test_an_open_seal_or_hospital_project_is_waited_for(save):
    put_state(save, ready={"lvl": 0, "worn": 94, "cv": 13, "drill_age": 5, "audit": {"age": 10, "ok": 1, "min_traps": 40},
                           "fail": ["open_perimeter"], "open": 1},
              sched={"seal": {"n": 1, "proj": "c1a147c261", "paused": 0}})
    s = step(save)
    assert s.key == "idle" and "R0 waits on open_perimeter" in s.why


def test_other_r0_blockers_go_to_the_brief(save):
    put_state(save, ready={"lvl": 0, "worn": 94, "cv": 13, "drill_age": 5, "audit": {"age": 10, "ok": 1, "min_traps": 40},
                           "fail": ["traps<30", "office"]})
    s = step(save)
    assert (s.cmd, s.key) == ("dfllm brief", "r0") and "traps<30, office" in s.why


def test_the_kernel_is_not_running(save):
    (save / "state.a.json").write_text("{", encoding="utf-8")
    (save / "state.b.json").write_text("{", encoding="utf-8")
    s = step(save)
    assert (s.key, s.cmd) == ("dead", "dfllm doctor")


def test_a_save_that_is_not_active(save):
    (save.parent / "ACTIVE").write_text("another_fort", encoding="utf-8")
    s = step(save)
    assert (s.key, s.cmd) == ("dead", "dfllm doctor") and "not the ACTIVE one" in s.why


def test_a_stale_heartbeat_of_the_active_save(save):
    import os
    old = 1_000_000_000
    os.utime(save / "heartbeat", (old, old))
    s = step(save)
    assert s.key == "dead" and "heartbeat" in s.why


def test_priority_order_walks_down_as_the_causes_go(save, no_hospital_project):
    """Every cause at once: the list is interrupt > danger > dying > mood > plan > r0 > idle."""
    put_plan(save, 1)
    append_events(save, [A(8821, "MOOD_CRITICAL", "Urist", {"unit": 55, "why": "x", "thirst": 51000})])
    full = dict(mode="ALERT", threat={"vis": 1, "armed": 1},
                alarm={"defcon": 3, "unacked": 1, "last": 9, "ack": 8, "lock": 0, "why": ""},
                water=WATER(1),
                ready={"lvl": 0, "worn": 94, "cv": 13, "drill_age": -1, "audit": {"age": -1, "ok": 0, "min_traps": 0},
                       "fail": ["audit"]})
    put_state(save, **full)
    order = []
    while True:
        s = step(save)
        order.append(s.key)
        if s.key == "interrupt":
            put_state(save, alarm=dict(full["alarm"], unacked=0))
        elif s.key == "danger":
            put_state(save, mode="PEACE", threat={"vis": 0, "armed": 0})
        elif s.key == "dying":
            put_state(save, water=None)
        elif s.key == "mood":
            append_events(save, [A(8822, "MOOD_END", "", {"unit": 55}, tick=NOW - 10)])
        elif s.key == "plan":
            put_plan(save, 3)
        elif s.key == "r0":
            put_state(save, ready=dict(full["ready"], lvl=1, fail=[]))
        else:
            break
    assert order == ["interrupt", "danger", "dying", "mood", "plan", "r0", "idle"]


# ---------------------------------------------------------------- the output and its commands
def test_output_is_at_most_four_short_lines_with_the_labels(save):
    append_events(save, [A(8821, "MOOD_CRITICAL", "Urist", {"unit": 55, "why": "thirst", "thirst": 52000, "name": "Urist"})])
    lines = step(save).lines()
    assert [x.split(":")[0] for x in lines] == ["NEXT", "WHY", "TELL PLAYER", "SHOW"]
    assert all(len(x) <= 200 for x in lines)


def test_a_waiting_hospital_project_is_no_second_bp_place(save):
    """The fixture holds a hospital bp file without PROJECT_DONE: `bp.place hospital` again would duplicate it."""
    put_state(save, ready={"lvl": 0, "worn": 94, "cv": 13, "drill_age": 5, "audit": {"age": 10, "ok": 1, "min_traps": 40},
                           "fail": ["hospital_out"]})
    s = step(save)
    assert s.key == "idle" and "R0 waits on hospital_out" in s.why


def _commands_of_every_scenario(save):
    """The command line of every step the module can print, built from the fixture with the scenario's cause."""
    out = []

    def add(**kw):
        put_state(save, **kw)
        for s in guide.candidates(guide.gather(save)):
            out.extend([s.cmd, s.show])
    al = {"defcon": 3, "unacked": 1, "last": 9, "ack": 8, "lock": 0, "why": ""}
    add(alarm=al)
    add(mode="SIEGE", threat={"vis": 2, "armed": 1}, alarm=dict(al, unacked=0))
    add(mode="PEACE", threat={"vis": 0, "armed": 0}, curse={"n": 2, "tf": 0, "ids": [5]})
    add(curse=None, water=WATER(2, 65000))
    add(water=None, ready={"lvl": 0, "worn": 1, "cv": 1, "drill_age": -1, "audit": {"age": -1, "ok": 0, "min_traps": 0},
                           "fail": ["audit", "open_perimeter", "hospital_out", "no_refuge", "office"], "open": 2})
    append_events(save, [A(8821, "MOOD_CRITICAL", "U", {"unit": 55, "why": "x"})])
    (save / "plan.json").unlink()
    add()
    put_plan(save, 2)
    draft = json.loads((FIXTURE / "plan.json").read_text("utf-8"))
    files.write_json_atomic(save / "plan.draft.json", draft)
    add()
    f = guide.gather(save)
    f["state"]["curse"] = {"n": 2, "tf": 0, "ids": [5]}
    out.extend(x for c in guide.candidates(f) for x in (c.cmd, c.show))
    return [c for c in out if c]


def test_every_printed_command_exists(save, no_hospital_project):
    cmds = _commands_of_every_scenario(save)
    assert len(set(cmds)) >= 8
    subs = set(cli._parser()._subparsers._group_actions[0].choices)
    for line in cmds:
        w = shlex.split(line)
        assert w[0] == "dfllm" and w[1] in subs, line
        if w[1] == "cmd":
            assert w[2] in schema.VERBS, f"{line}: {w[2]} is not a verb of the registry"
            args = parse_kv(w[3:])
            assert schema.validate_args(w[2], args) == [], line
        if w[1] == "wait":
            assert "--until-interrupt" in w
    # the parser accepts them as written
    ap = cli._parser()
    for line in cmds:
        w = shlex.split(line)[1:]
        if w[0] in ("cmd", "plan", "wait", "audit", "ack", "brief", "doctor"):
            ap.parse_args(w)


def test_the_cli_prints_the_step_and_counts_repeats(save, capsys):
    (save / "plan.json").unlink()
    for _ in range(guide.REPEAT_MAX):
        assert main(["--runtime", str(save.parent), "next"]) == 0
        out = capsys.readouterr().out
        assert out.splitlines()[0] == f"NEXT: {guide.PLAN_CMD}"
    assert main(["--runtime", str(save.parent), "next"]) == 0           # the fourth time: not the same command again
    out = capsys.readouterr().out
    assert out.splitlines()[0] == "NEXT: nothing" and "tried 3x" in out and "TELL PLAYER" in out
    assert main(["--runtime", str(save.parent), "next", "--peek"]) == 0
    capsys.readouterr()
    put_plan(save, 3)                                                  # the cause went: the memory does not hold it
    assert main(["--runtime", str(save.parent), "next"]) == 0
    assert capsys.readouterr().out.startswith("NEXT: nothing\nWHY: green")


def test_a_changed_command_resets_the_repeat_memory(save, tmp_path):
    (save / "plan.json").unlink()
    t0 = 5_000_000.0
    for i in range(3):
        guide.next_step(save, now=t0 + i)
    assert guide.read_memory(save, t0 + 3)["n"] == 3
    put_plan(save, 3)
    put_state(save, mode="SIEGE", threat={"vis": 1, "armed": 1})
    guide.next_step(save, now=t0 + 4)                                  # the danger wait is another command
    assert guide.read_memory(save, t0 + 5)["n"] == 1
    assert guide.read_memory(save, t0 + 4 + guide.REPEAT_WINDOW_S + 1) == {}     # and a memory expires


def test_danger_is_never_skipped(save):
    put_state(save, mode="SIEGE", threat={"vis": 7, "armed": 1})
    s = guide.decide(guide.gather(save), (guide.WAIT,))
    assert s.key == "danger"
