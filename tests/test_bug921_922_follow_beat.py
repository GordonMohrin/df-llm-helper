"""BUG-921 / BUG-922 (Run 17 i3 run-17c, 26.11.: 7 FOLLOW_OFF in 3 h while follow lived; the beat came only from poll() in the thread
that also ran the 70-75 s audit): a late beat of a LIVE pid is `SLOW`, not `OFF`, and wakes nobody until FOLLOW_STUCK_S (then its own
FOLLOW_STUCK wake); a dead pid stays OFF and wakes at once. The beat is written by its own thread, only while the poll loop progresses,
names the running step, and a poll step longer than FOLLOW_STEP_LOG_S goes to cli.log."""
import os
import time

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import alarm, files, session, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _beat(save, now, age, pid=None, **more):
    doc = {"v": 2, "wall": int(now - age), "last_n": 0, "code": files.code_stamp(), "auto": 1}
    if pid is not None:
        doc["pid"] = pid
    doc.update(more)
    files.write_follow_hb(save, doc)
    mt = now - age
    os.utime(save / files.FOLLOW_HB, (mt, mt))


def _cfg():
    return {**session.config()["wait"], "follow_check": True}


def test_live_pid_with_a_late_beat_is_slow_not_off(save, monkeypatch):
    now = time.time()
    monkeypatch.setattr(wake, "pid_alive", lambda pid: pid == 4711)
    _beat(save, now, 70, pid=4711, step="audit s1", step_s=65)
    msg = files.follow_off(save, now)
    assert msg.startswith("follow: SLOW (heartbeat ") and "pid 4711 alive" in msg and "busy in audit s1 65 s" in msg
    assert "OFF" not in msg
    _beat(save, now, 200, pid=4711)
    assert files.follow_off(save, now).startswith("follow: SLOW")        # still no wake at 200 s


def test_slow_wakes_nobody_stuck_wakes_with_its_own_key_dead_wakes_at_once(save, monkeypatch):
    now = time.time()
    monkeypatch.setattr(wake, "pid_alive", lambda pid: pid == 4711)
    monkeypatch.setattr(files, "read_heartbeat", lambda d, n: ({"paused": False}, 1.0))
    monkeypatch.setattr(files, "read_state", lambda d: {})
    _beat(save, now, 120, pid=4711)
    assert [r for r in alarm.sys_reasons(save, _cfg(), now) if r["type"].startswith("FOLLOW")] == []
    _beat(save, now, files.FOLLOW_STUCK_S + 10, pid=4711)
    got = [r for r in alarm.sys_reasons(save, _cfg(), now) if r["type"].startswith("FOLLOW")]
    assert [r["type"] for r in got] == ["FOLLOW_STUCK"] and got[0]["key"] == "FOLLOW_STUCK"
    assert "alive but not progressing" in got[0]["msg"] and "OFF" not in got[0]["msg"]
    assert "FOLLOW_STUCK" in alarm.SYS_NEXT
    _beat(save, now, 65, pid=999999)                                       # dead pid: OFF at once
    got = [r for r in alarm.sys_reasons(save, _cfg(), now) if r["type"].startswith("FOLLOW")]
    assert [r["type"] for r in got] == ["FOLLOW_OFF"] and "was pid 999999" in got[0]["msg"]
    _beat(save, now, 65)                                                   # no pid in the beat (older follow): OFF as before
    assert files.follow_off(save, now).startswith("follow: OFF (last heartbeat")


def test_fresh_beat_of_a_busy_loop_says_busy_but_is_no_wake(save, monkeypatch):
    now = time.time()
    monkeypatch.setattr(files, "read_heartbeat", lambda d, n: ({"paused": False}, 1.0))
    monkeypatch.setattr(files, "read_state", lambda d: {})
    _beat(save, now, 3, pid=os.getpid(), step="event SNAPSHOT_READY", step_s=70)
    msg = files.follow_off(save, now)
    assert msg.startswith("follow: busy in event SNAPSHOT_READY 70 s") and "OFF" not in msg
    assert [r for r in alarm.sys_reasons(save, _cfg(), now) if r["type"].startswith("FOLLOW")] == []
    _beat(save, now, 3, pid=os.getpid(), step="audit", step_s=5)
    assert files.follow_off(save, now) is None


class Mono:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _follower(save):
    f = wake.Follower(out=lambda s: None, clock=lambda: time.time())
    f.mono = Mono()
    f._loop_mono = f.mono()
    f.poll()                                  # attaches the save dir
    f._beat = -1e18
    return f


def test_beat_thread_beats_during_a_long_step_and_names_it(save):
    f = _follower(save)
    with f._step("audit s9"):
        f.mono.t += 70                        # the audit runs 70 s; the poll thread cannot beat, the beat thread can
        assert f.beat_thread_tick(time.time()) is True
        doc, age = files.read_follow_hb(save)
        assert doc["step"] == "audit s9" and doc["step_s"] == 70 and doc["pid"] == os.getpid() and age < 5
        assert f.beat_thread_tick(time.time()) is False                    # not twice within FOLLOW_HB_EVERY_S
    log = (save / "cli.log").read_text("utf-8") if (save / "cli.log").exists() else ""
    assert "slow_step" in log and "audit s9" in log                       # the measurement for the next live round


def test_beat_thread_is_silent_when_the_loop_does_not_progress(save):
    f = _follower(save)
    with f._step("run_jobs"):
        f.mono.t += wake.FOLLOW_BUSY_MAX_S + 1                           # one step hangs: a dead loop must not look alive
        assert f.beat_thread_tick(time.time()) is False
    assert files.read_follow_hb(save)[0].get("step") is None             # only the poll-thread beat of the attach is there
    f.mono.t += 5
    with f._step("check_plan"):
        pass                                                              # the loop moves again (step end stamps progress)
    assert f.beat_thread_tick(time.time()) is True


def test_short_steps_are_not_logged_and_poll_still_beats(save):
    f = _follower(save)
    f.mono.t += 1
    f.poll()
    log = (save / "cli.log").read_text("utf-8") if (save / "cli.log").exists() else ""
    assert "slow_step" not in log
    assert files.read_follow_hb(save)[0]["pid"] == os.getpid()
