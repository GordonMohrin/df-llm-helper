"""BUG-385 (Run 16b i2: 'also the 2nd and 3rd start is taken over by a foreign pid'): two starts with --takeover on one runtime
folder must not take the lock from each other for ever; status and doctor name the owner pid."""
import json
import os
import time

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import doctor, files, wake


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put(save, pid, **kw):
    now = int(time.time())
    files.write_json_atomic(save / wake.FOLLOW_LOCK, {"v": 1, "pid": pid, "start": now, "hb": now, "code": wake.CODE, **kw})


def test_bug385_takeover_of_a_plain_owner_works_once_and_is_recorded(save):
    put(save, 111)
    now = time.time()
    assert wake.acquire_lock(save, now, True, alive=lambda p: True) == (True, None)
    doc = json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))
    assert doc["pid"] == os.getpid() and doc["took"] == 111 and doc["took_at"] == int(now)


def test_bug385_no_ping_pong_the_second_takeover_is_refused(save):
    put(save, 222, took=111, took_at=int(time.time()) - 5)               # 222 took the save over 5 s ago
    ok, owner = wake.acquire_lock(save, time.time(), True, alive=lambda p: True)
    assert not ok and owner["pid"] == 222 and 0 < owner["cooldown"] <= wake.FOLLOW_TAKEOVER_COOL_S
    assert json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))["pid"] == 222        # untouched


def test_bug385_after_the_cool_down_a_takeover_works_again(save):
    put(save, 222, took=111, took_at=int(time.time()) - wake.FOLLOW_TAKEOVER_COOL_S - 5)
    assert wake.acquire_lock(save, time.time(), True, alive=lambda p: True) == (True, None)


def test_bug385_the_cool_down_survives_the_owners_beats(save, monkeypatch):
    monkeypatch.setattr(wake, "pid_alive", lambda p: True)
    assert wake.acquire_lock(save, time.time(), True, alive=lambda p: True) == (True, None)      # nobody there: no `took`
    put(save, os.getpid(), took=111, took_at=int(time.time()) - 10)
    assert wake.refresh_lock(save, time.time() + 1) is None
    doc = json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))
    assert doc["took"] == 111 and doc["took_at"] and doc["pid"] == os.getpid()


def test_bug385_run_exits_clean_and_names_the_owner(save, monkeypatch, capsys):
    """The restarted older follow (a Monitor that restarts it with --takeover) does not take the lock back."""
    calls = []
    monkeypatch.setattr(wake.Follower, "poll", lambda self: calls.append(1))
    monkeypatch.setattr(wake, "pid_alive", lambda p: p in (222, os.getpid()))
    put(save, 222, took=111, took_at=int(time.time()) - 5)
    args = type("A", (), {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0.3, "interval": 0.02,
                          "takeover": True})()
    assert wake.run(args) == 3 and calls == []
    out = capsys.readouterr().out
    assert "pid 222" in out and "from pid 111" in out and "does not take it back" in out
    assert json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))["pid"] == 222


def test_bug385_old_code_takeover_obeys_the_cool_down_too(save, monkeypatch, capsys):
    monkeypatch.setattr(wake.Follower, "poll", lambda self: None)
    monkeypatch.setattr(wake, "pid_alive", lambda p: p in (333, os.getpid()))
    put(save, 333, code="0ld0c0de0000", took=1, took_at=int(time.time()) - 5)
    args = type("A", (), {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0, "interval": 0.02})()
    monkeypatch.setattr(wake.Follower, "poll", lambda self: (_ for _ in ()).throw(KeyboardInterrupt))
    assert wake.run(args) == 3
    assert "does not take it back" in capsys.readouterr().out


def test_bug385_status_and_doctor_name_the_owner(save):
    now = time.time()
    put(save, 4711, took=99, took_at=int(now) - 17)
    files.write_follow_hb(save, {"v": 2, "wall": int(now), "last_n": 0, "code": files.code_stamp(), "auto": 1, "pid": 4711})
    line = files.follow_owner(save, now)
    assert "pid 4711" in line and "took over from pid 99" in line
    files.write_follow_hb(save, {"v": 2, "wall": int(now), "last_n": 0, "code": "old", "auto": 1, "pid": 4711})
    assert "pid 4711" in files.follow_off(save, now) and "OLD CODE" in files.follow_off(save, now)
    files.write_follow_hb(save, {"v": 2, "wall": int(now), "last_n": 0, "code": files.code_stamp(), "auto": 1, "pid": 5})
    assert "two follows" in files.follow_owner(save, now)               # lock pid 4711, heartbeat pid 5
    os.utime(save / files.FOLLOW_HB, (now - 600, now - 600))
    assert "was pid 5" in files.follow_off(save, now)
    assert files.follow_owner(save, now) is None


def test_bug385_doctor_lists_the_owner(save):
    now = time.time()
    put(save, 4711)
    files.write_follow_hb(save, {"v": 2, "wall": int(now), "last_n": 0, "code": files.code_stamp(), "auto": 1, "pid": 4711})
    assert hasattr(doctor, "files") and "pid 4711" in files.follow_owner(save, now)
