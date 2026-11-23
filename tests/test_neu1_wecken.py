"""Neuausrichtung 1 / P3 (docs/v2/NEU1-wecken.md): the wake list of `dfllm wait` (BUG-792), the session heartbeat the kernel's
dead-man switch reads, the park/deadman lines of status, and the bounded follow (BUG-791 sleep, BUG-793 memory)."""
import json
import os
import threading
import time
import types
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import alarm, brief, fairplay, files, schema, session, wake
from dfpilot.cli import main

FAST = {"act": True, "repeat_s": 300, "backlog": 2000, "kernel_stale_s": 120, "follow_check": True,
        "quiet_types": list(session.QUIET_TYPES), "quiet_decisions": list(session.QUIET_DECISIONS)}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.delenv(session.NO_SESSION_ENV, raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def run(save, *argv):
    return main(["--runtime", str(save.parent), *argv])


def later(save, evs, delay=0.2):
    def go():
        time.sleep(delay)
        append_events(save, evs)
    threading.Thread(target=go, daemon=True).start()


# ---------------------------------------------------------------- the session heartbeat
def test_session_touch_read_and_switches(save, monkeypatch):
    assert session.touch(save, "wait", now=1000.0)
    doc, age = session.read(save, now=1030.0)
    assert doc["wall"] == 1000 and doc["by"] == "wait" and doc["pid"] == os.getpid() and age == 30
    monkeypatch.setenv(session.NO_SESSION_ENV, "1")
    assert not session.touch(save, "brief", now=2000.0)
    assert session.read(save, now=2000.0)[0]["wall"] == 1000
    monkeypatch.delenv(session.NO_SESSION_ENV)
    cfg = session.config()
    cfg["session"]["on"] = False
    assert not session.touch(save, "brief", now=2000.0, cfg=cfg)


def test_session_commands_write_the_heartbeat_status_does_not(save, capsys):
    p = save / session.SESSION_FILE
    run(save, "status")
    assert not p.exists(), "a supervisor's look keeps no fort alive"
    run(save, "brief")
    doc = json.loads(p.read_text(encoding="utf-8"))
    assert doc["by"] == "brief" and time.time() - doc["wall"] < 30
    assert set(session.SESSION_CMDS) == {"wait", "brief", "cmd", "ack", "plan", "next"}


def test_config_defaults_and_bad_values(tmp_path):
    p = tmp_path / "wake.json"
    p.write_text(json.dumps({"v": 2, "wait": {"repeat_s": -5, "act": "yes", "quiet_types": ["GHOSTS"]},
                             "follow": {"max_rss_mb": 300}}), encoding="utf-8")
    c = session.config(p)
    assert c["wait"]["repeat_s"] == 300 and c["wait"]["act"] is True, "a bad value keeps its default (ON)"
    assert c["wait"]["quiet_types"] == ["GHOSTS"] and c["follow"]["max_rss_mb"] == 300
    assert fairplay.wake_errors() == []
    errs = fairplay.wake_errors(p)
    assert any("repeat_s" in e for e in errs) and any("wait.act" in e for e in errs)
    p.write_text(json.dumps({"v": 2, "wait": {"quiet_types": ["SEASON", "NOPE"]}, "x": 1}), encoding="utf-8")
    errs = fairplay.wake_errors(p)
    assert any("not class-A" in e and "SEASON" in e for e in errs) and any("unknown key 'x'" in e for e in errs)


def test_reflex_deadman_block_is_linted():
    assert fairplay.reflex_errors() == []
    doc = json.loads(fairplay.REFLEX_PATH.read_text(encoding="utf-8"))
    assert doc["deadman"] == {"on": True, "timeout_s": 600, "check_s": 5, "grace_s": 60}


def test_contract_knows_the_dead_man():
    assert schema.EVENTS["DEADMAN_PAUSE"][0] == "A" and schema.VERBS["park"][0] == "arbiter"
    assert schema.validate("event", ev(1, "DEADMAN_PAUSE", "x", {"age": -1, "timeout": 600})) == []
    assert "DEADMAN_PAUSE" in wake.WAKE_TYPES and "resume" in wake.NEXT["DEADMAN_PAUSE"]


# ---------------------------------------------------------------- the wake list
def test_every_class_a_type_is_either_waking_or_quiet():
    a = {t for t, (c, _, _) in schema.EVENTS.items() if c == "A"}
    quiet = set(session.QUIET_TYPES)
    assert quiet <= a
    wakes = a - quiet - set(schema.INTERRUPTS)
    for must in ("PATIENT_DYING", "MOOD_CRITICAL", "STRANDED", "CUTOFF", "SIEGE_START", "BREACH", "REFUGE_FAIL",
                 "PAUSED_BY_DF", "YEAR_REVIEW", "DECISION_NEEDED", "DEADMAN_PAUSE", "WATER_PREDATOR", "MISSING"):
        assert must in wakes, must
    assert alarm.acts(ev(1, "PROJECT_BLOCKED"), FAST) is False
    assert alarm.acts(ev(1, "DECISION_NEEDED", d={"id": "seal_stalled"}), FAST) is False
    assert alarm.acts(ev(1, "DECISION_NEEDED", d={"id": "thirst_unit"}), FAST) is True
    assert alarm.acts(ev(1, "DECISION_NEEDED", d={"id": "brand_new_id"}), FAST) is True, "unknown ids wake (fail closed)"
    assert alarm.acts(ev(1, "PREDATOR"), FAST) is False, "interrupts keep their own channel"
    assert alarm.acts(ev(1, "SEASON"), FAST) is False


def test_an_actionable_event_wakes_wait_within_a_second(save):
    later(save, [ev(9001, "PROJECT_BLOCKED", "stalled"), ev(9002, "MOOD_CRITICAL", "Urist dies in 3 days", {"unit": 5})])
    t0 = time.monotonic()
    items, _ = alarm.wait_wake(save, timeout=10, poll=0.05, cfg=FAST)
    assert time.monotonic() - t0 < 3
    assert [(i["kind"], i["type"], i["n"]) for i in items] == [("act", "MOOD_CRITICAL", 9002)]


def test_quiet_events_do_not_wake(save):
    later(save, [ev(9001, "PROJECT_BLOCKED", "x"), ev(9002, "DECISION_NEEDED", "metal", {"id": "metal", "q": "?"})], 0.05)
    items, _ = alarm.wait_wake(save, timeout=0.8, poll=0.05, cfg=FAST)
    assert items == []


def test_cursor_reports_what_came_between_two_waits_and_no_history_at_first_use(save):
    append_events(save, [ev(9001, "MOOD_CRITICAL", "old one")])
    items, _ = alarm.wait_wake(save, timeout=0.2, poll=0.05, cfg=FAST)
    assert items == [], "first use starts at the end of the log"
    append_events(save, [ev(9002, "PATIENT_DYING", "patient 7 thirst 45000", {"unit": 7})])   # the player was busy
    t0 = time.monotonic()
    items, _ = alarm.wait_wake(save, timeout=10, poll=0.05, cfg=FAST)
    assert time.monotonic() - t0 < 2 and [i["n"] for i in items] == [9002]
    assert json.loads((save / alarm.CURSOR).read_text(encoding="utf-8"))["n"] == 9002


def test_one_key_wakes_once_per_repeat_s(save):
    append_events(save, [ev(9001, "SEASON", "s")])
    alarm.wait_wake(save, timeout=0, cfg=FAST)                     # the cursor exists
    append_events(save, [ev(9002, "DECISION_NEEDED", "t", {"id": "thirst_unit", "q": "?"})])
    assert [i["n"] for i in alarm.wait_wake(save, timeout=0, cfg=FAST)[0]] == [9002]
    append_events(save, [ev(9003, "DECISION_NEEDED", "t", {"id": "thirst_unit", "q": "?"}),
                         ev(9004, "DECISION_NEEDED", "f", {"id": "famine", "q": "?"})])
    assert [i["n"] for i in alarm.wait_wake(save, timeout=0, cfg=FAST)[0]] == [9004], "the same key within repeat_s is quiet"
    cur = json.loads((save / alarm.CURSOR).read_text(encoding="utf-8"))
    cur["said"] = {k: v - 400 for k, v in cur["said"].items()}
    (save / alarm.CURSOR).write_text(json.dumps(cur), encoding="utf-8")
    append_events(save, [ev(9005, "DECISION_NEEDED", "t", {"id": "thirst_unit", "q": "?"})])
    assert [i["n"] for i in alarm.wait_wake(save, timeout=0, cfg=FAST)[0]] == [9005]


def test_cursor_far_behind_or_beyond_the_log_starts_at_the_end(save):
    (save / alarm.CURSOR).write_text(json.dumps({"v": 2, "n": 99999999, "said": {}}), encoding="utf-8")
    append_events(save, [ev(9001, "MOOD_CRITICAL", "x")])
    assert alarm.wait_wake(save, timeout=0, cfg=FAST)[0] == []
    (save / alarm.CURSOR).write_text(json.dumps({"v": 2, "n": 1, "said": {}}), encoding="utf-8")
    assert alarm.wait_wake(save, timeout=0, cfg=dict(FAST, backlog=10))[0] == []


def test_own_reasons_deadman_follow_off_kernel_stale(save):
    for s in "ab":
        p = save / f"state.{s}.json"
        d = json.loads(p.read_text(encoding="utf-8"))
        d["owners"]["pause"], d["t"]["paused"] = "deadman", True
        p.write_text(json.dumps(d), encoding="utf-8")
    hb = json.loads((save / "heartbeat").read_text(encoding="utf-8"))
    hb["paused"] = True
    (save / "heartbeat").write_text(json.dumps(hb), encoding="utf-8")
    (save / files.FOLLOW_HB).unlink()
    items, _ = alarm.wait_wake(save, timeout=5, poll=0.05, cfg=FAST)
    assert sorted(i["type"] for i in items) == ["DEADMAN", "FOLLOW_OFF"]
    assert alarm.wait_wake(save, timeout=0.3, poll=0.05, cfg=FAST)[0] == [], "said once per repeat_s"
    old = time.time() - 600
    os.utime(save / "heartbeat", (old, old))
    items, _ = alarm.wait_wake(save, timeout=5, poll=0.05, cfg=FAST)
    assert [i["type"] for i in items] == ["KERNEL_STALE"]


def test_wait_cli_prints_wake_lines_with_next_and_logs(save, capsys):
    run(save, "wait", "--timeout", "0")                            # cursor at the end
    capsys.readouterr()
    append_events(save, [ev(9001, "PATIENT_DYING", "patient 7 at 45000 thirst", {"unit": 7})])
    assert run(save, "wait", "--timeout", "5") == 0
    out = capsys.readouterr().out
    assert out.startswith("WAKE #9001 PATIENT_DYING: patient 7 at 45000 thirst | next: ")
    assert "woke: PATIENT_DYING#9001" in (save / "cli.log").read_text(encoding="utf-8")
    assert json.loads((save / session.SESSION_FILE).read_text(encoding="utf-8"))["by"] == "wait"


def test_act_false_is_the_old_interrupts_only_wait(save, tmp_path, monkeypatch, capsys):
    cfgdir = tmp_path / "cfg"
    cfgdir.mkdir()
    (cfgdir / "wake.json").write_text(json.dumps({"v": 2, "wait": {"act": False}}), encoding="utf-8")
    monkeypatch.setenv("DFLLM_CONFIG", str(cfgdir))
    run(save, "wait", "--timeout", "0")
    append_events(save, [ev(9001, "MOOD_CRITICAL", "x")])
    assert run(save, "wait", "--timeout", "0.3") == 1
    assert "no interrupt in 0.3 s" in capsys.readouterr().out


def test_cursor_said_is_bounded(save):
    cur = {"v": 2, "n": 5, "said": {f"K{i}": time.time() - alarm.SAID_KEEP_S - 10 for i in range(500)}}
    cur["said"]["fresh"] = time.time()
    alarm.write_cursor(save, cur, time.time())
    assert list(alarm.read_cursor(save)["said"]) == ["fresh"]


# ---------------------------------------------------------------- status / brief
def test_status_line_names_the_dead_man_and_the_park():
    for own, want in (("deadman", "PAUSED by deadman"), ("park", "PARKED"), ("gordon", "")):
        ctx = types.SimpleNamespace(s={"owners": {"pause": own}, "t": {"paused": True}}, hb={"paused": True})
        line = brief.line_paused(ctx)
        assert (line.startswith(want) if want else line == ""), (own, line)
    assert "dfllm cmd resume" in brief.line_paused(types.SimpleNamespace(s={"owners": {"pause": "deadman"},
                                                                            "t": {"paused": True}}, hb={}))


# ---------------------------------------------------------------- follow: sleep and memory
def test_bug791_a_sleep_that_raises_does_not_end_follow(monkeypatch):
    calls = []

    def bad_sleep(s):
        calls.append(s)
        if len(calls) == 1:
            raise OSError(1450, "Insufficient system resources exist to complete the requested service")
    monkeypatch.setattr(wake.time, "sleep", bad_sleep)
    errs = [0]
    wake._sleep(1.0, errs)
    assert errs == [1] and calls == [1.0, wake.SLEEP_ERR_S]
    wake._sleep(1.0, errs)
    assert errs == [0]


def test_bug791_follow_run_survives_sleep_errors(save, monkeypatch):
    real = time.sleep
    n = [0]

    def flaky(s):
        n[0] += 1
        if n[0] % 2:
            raise OSError(1450, "Insufficient system resources")
        real(0.01)
    monkeypatch.setattr(wake.time, "sleep", flaky)
    args = types.SimpleNamespace(save_pin=None, since=None, no_auto=True, no_audit=True, takeover=False, once=False,
                                 max_s=0.5, interval=0.01)
    assert wake.run(args) == 0
    assert n[0] >= 2


def test_bug793_restart_why():
    cfg = {"restart": True, "max_rss_mb": 400, "max_hours": 12}
    assert wake.restart_why(cfg, 60, 120.0) is None
    assert "MB" in wake.restart_why(cfg, 60, 512.0)
    assert "h" in wake.restart_why(cfg, 12 * 3600, None)
    assert wake.restart_why(dict(cfg, restart=False), 13 * 3600, 9999.0) is None
    r = wake.rss_mb()
    assert r is None or 1 < r < 4000


def test_bug793_follow_hands_over_to_a_fresh_copy(save, monkeypatch):
    spawned = []
    monkeypatch.setattr(wake, "MEM_EVERY_S", 0.0)
    monkeypatch.setattr(wake, "rss_mb", lambda: 9999.0)
    monkeypatch.setattr(wake, "spawn", lambda argv: spawned.append(argv) or True)
    real = time.sleep
    n = [0]

    def sleep(s):
        n[0] += 1
        if n[0] > 200:
            raise KeyboardInterrupt
        real(0.005)
    monkeypatch.setattr(wake.time, "sleep", sleep)
    args = types.SimpleNamespace(save_pin=None, since=None, no_auto=True, no_audit=True, takeover=False, once=False,
                                 max_s=0, interval=0.01, argv=["--runtime", "X", "follow", "--no-auto"])
    assert wake.run(args) == 0
    assert len(spawned) == 1 and spawned[0][1:] == ["-m", "dfpilot", "--runtime", "X", "follow", "--no-auto", "--takeover"]
    assert not (save / wake.FOLLOW_LOCK).exists(), "the lock is free for the copy"
    assert "follow: restart" in (save / "cli.log").read_text(encoding="utf-8")


def test_bug793_a_copy_that_does_not_start_leaves_follow_running(save, monkeypatch):
    monkeypatch.setattr(wake, "MEM_EVERY_S", 0.0)
    monkeypatch.setattr(wake, "rss_mb", lambda: 9999.0)
    monkeypatch.setattr(wake, "spawn", lambda argv: False)
    args = types.SimpleNamespace(save_pin=None, since=None, no_auto=True, no_audit=True, takeover=False, once=False,
                                 max_s=0, interval=0.01)
    real = time.sleep
    n = [0]

    def sleep(s):
        n[0] += 1
        if n[0] > 30:
            raise KeyboardInterrupt
        real(0.005)
    monkeypatch.setattr(wake.time, "sleep", sleep)
    assert wake.run(args) == 0
    assert n[0] > 30, "it went on after the failed restart"
    log = (save / "cli.log").read_text(encoding="utf-8")
    assert log.count("the copy did not start") == 1, "retried only after RESPAWN_RETRY_S"
