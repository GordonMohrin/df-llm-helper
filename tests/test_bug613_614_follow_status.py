"""Round 39 (follow): BUG-613 (Run 16b i2 y412 / y413 / y414: `follow --takeover` 'did not take over a running owner': the only text
was the displaced follow's own exit line; a displaced follow went on for up to 10 s) and BUG-614 (after a DF restart the kernel
stays pause:df and neither `status` nor `follow` said that `dfllm cmd resume` runs the game)."""
import json
import os
import time

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, files, wake


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put(save, pid, **kw):
    now = int(time.time())
    files.write_json_atomic(save / wake.FOLLOW_LOCK, {"v": 1, "pid": pid, "start": now, "hb": now, "code": wake.CODE, **kw})


def lock(save):
    return json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))


# ------------------------------------------------------------------ BUG-613
def test_bug613_a_successful_takeover_says_so_and_names_the_old_pid(save, monkeypatch, capsys):
    monkeypatch.setattr(wake, "pid_alive", lambda p: p in (4242, os.getpid()))
    put(save, 4242)
    lk = wake._Lock(True)
    assert lk.step(save) is None
    out = capsys.readouterr().out
    assert "TOOK OVER" in out and "from pid 4242" in out and f"pid {os.getpid()}) follows now" in out
    assert "another follow owns" not in out
    assert lock(save)["pid"] == os.getpid() and lock(save)["took"] == 4242


def test_bug613_no_text_when_nobody_held_the_save(save, capsys):
    assert wake._Lock(True).step(save) is None
    assert capsys.readouterr().out == ""


def test_bug613_the_displaced_follow_leaves_at_its_next_poll_not_at_the_beat(save, monkeypatch):
    """The old follow read the lock only every FOLLOW_HB_EVERY_S (10 s): up to 10 s of every event answered twice."""
    monkeypatch.setattr(wake, "pid_alive", lambda p: p in (5151, os.getpid()))
    lk = wake._Lock(False)
    assert lk.step(save) is None and lock(save)["pid"] == os.getpid()
    assert lk.beat > time.time() - 5                      # a beat just happened: the next one is 10 s away
    assert lk.step(save) is None                           # still ours
    put(save, 5151)                                        # a --takeover start writes the lock
    why = lk.step(save)
    assert why is not None and "another follow owns this instance (pid 5151); do not restart" in why
    assert "DISPLACED" in why and "OLD follow" in why and f"pid {os.getpid()}" in why
    assert lock(save)["pid"] == 5151 and lk.dir is None   # its lock is never deleted


def test_bug613_a_refused_new_start_says_it_is_the_new_one_that_exits(save, monkeypatch):
    monkeypatch.setattr(wake, "pid_alive", lambda p: p == 222)
    put(save, 222, took=111, took_at=int(time.time()) - 5)
    why = wake._Lock(True).step(save)
    assert "do not restart" in why and "NOT STARTED" in why and "new start" in why
    assert "Stop-Process -Id 222" in why and "does not take it back" in why
    assert lock(save)["pid"] == 222


def test_bug613_run_exit_codes_unchanged(save, monkeypatch, capsys):
    monkeypatch.setattr(wake, "pid_alive", lambda p: p in (222, os.getpid()))
    put(save, 222, took=111, took_at=int(time.time()) - 5)
    args = type("A", (), {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0.3, "interval": 0.02,
                          "takeover": True})()
    assert wake.run(args) == wake.FOLLOW_OWNED_EXIT
    assert "NOT STARTED" in capsys.readouterr().out


# ------------------------------------------------------------------ BUG-614
def beat(save, paused, at=None):
    at = time.time() if at is None else at
    files.write_json_atomic(save / "heartbeat", {"frame": 1, "mode": "PEACE", "paused": paused, "seq": 1, "tick": 5, "v": 2,
                                                  "wall": int(at)})
    os.utime(save / "heartbeat", (at, at))


def owner_state(save, pause):
    st = files.read_state(save)
    st["owners"] = {"pause": pause, "tempo": "mode"} if pause else {"tempo": "mode"}
    st["t"] = dict(st.get("t") or {}, paused=bool(pause))
    st["seq"] += 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))


def follower(save):
    f = wake.Follower(out=lambda line: None, clock=lambda: time.time())
    f._attach(save)
    return f


def test_bug614_follow_says_cmd_resume_after_a_pause_by_df_stands(save):
    owner_state(save, "df")
    f = follower(save)
    now = time.time()
    beat(save, True, now)
    f._check_paused(now)
    f._check_paused(now + wake.PAUSED_HINT_S - 1)
    assert f.gate.pending == {}
    beat(save, True, now + wake.PAUSED_HINT_S + 1)
    f._check_paused(now + wake.PAUSED_HINT_S + 1)
    msg = f.gate.pending["PAUSED_BY_DF"]["e"]["msg"]
    assert msg.startswith("PAUSED_BY_DF ") and "pause:df" in msg and "dfllm cmd resume" in msg
    f.gate.pending.clear()
    beat(save, True, now + 3 * wake.PAUSED_HINT_S)
    f._check_paused(now + 3 * wake.PAUSED_HINT_S)
    assert f.gate.pending == {}                              # once per pause
    beat(save, False, now + 4 * wake.PAUSED_HINT_S)           # it runs again, then a new pause: a new hint
    f._check_paused(now + 4 * wake.PAUSED_HINT_S)
    assert f._pdf == {}


def test_bug614_the_players_own_pause_and_a_running_game_say_nothing(save):
    f = follower(save)
    now = time.time()
    for pause in ("gordon", "inbox", None):
        owner_state(save, pause)
        beat(save, True, now)
        f._check_paused(now)
        beat(save, True, now + 5 * wake.PAUSED_HINT_S)
        f._check_paused(now + 5 * wake.PAUSED_HINT_S)
    owner_state(save, "df")
    beat(save, False, now)                                    # not paused at all
    f._check_paused(now + 10 * wake.PAUSED_HINT_S)
    assert f.gate.pending == {}


def test_bug614_status_and_brief_name_the_command(save):
    owner_state(save, "df")
    beat(save, True)
    text = brief.status_text(save)
    assert "PAUSED by df" in text and "dfllm cmd resume" in text
    assert "PAUSED by df" in brief.brief_text(save)
    owner_state(save, "gordon")
    beat(save, True)
    assert "PAUSED by" not in brief.status_text(save)
    owner_state(save, "popup")
    beat(save, True)
    assert "PAUSED by popup" in brief.status_text(save) and "threat or curse" in brief.status_text(save)
