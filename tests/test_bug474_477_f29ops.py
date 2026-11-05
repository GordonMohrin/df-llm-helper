"""Round 29 ops fixes: BUG-474 (follow --takeover after a deploy, single ownership), BUG-475 (TICK_STALL), BUG-477 (the minimal plan
as the error-free subset of its builds). BUG-476 (the altar of the offering place) is tests/lua/test_economy_pieces.lua."""
import json
import os
import time

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import files, plan, wake


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


# ------------------------------------------------------------------ BUG-474
def test_bug474_takeover_of_an_old_code_owner_that_took_over_from_my_start_id(save, monkeypatch):
    """i1/i3/i4: the owner (old code) had taken the save over from a follow with the same parent pid as the new start."""
    monkeypatch.setenv("DFLLM_FOLLOW_SID", "shell-1")
    put(save, 19612, code="0ld0c0de0000", took=111, took_at=int(time.time()) - 5, took_sid="shell-1")
    ok, owner = wake.acquire_lock(save, time.time(), True, alive=lambda p: True)
    assert (ok, owner) == (True, None)
    doc = lock(save)
    assert doc["pid"] == os.getpid() and doc["took"] == 19612 and doc["took_code"] == "0ld0c0de0000"


def test_bug474_old_code_owner_without_any_code_is_displaced(save):
    now = int(time.time())
    files.write_json_atomic(save / wake.FOLLOW_LOCK, {"v": 1, "pid": 7, "start": now, "hb": now, "took": os.getpid(),
                                                      "took_at": now - 1})
    hb = save / files.FOLLOW_HB
    if hb.exists():
        hb.unlink()
    assert wake.acquire_lock(save, time.time(), True, alive=lambda p: True) == (True, None)


def test_bug474_same_code_still_obeys_the_ping_pong_guards(save, monkeypatch):
    monkeypatch.setenv("DFLLM_FOLLOW_SID", "shell-1")
    put(save, 222, took=111, took_at=int(time.time()) - 5)
    assert not wake.acquire_lock(save, time.time(), True, alive=lambda p: True)[0]
    put(save, 222, took=111, took_at=int(time.time()) - 10 * wake.FOLLOW_TAKEOVER_COOL_S, took_sid="shell-1")
    assert not wake.acquire_lock(save, time.time(), True, alive=lambda p: True)[0]


def test_bug474_old_code_coming_back_is_a_real_ping_pong(save):
    """The owner (other code) took the save over from a follower of MY code: I am the displaced start, not a deploy."""
    put(save, 333, code="0thercode000", took=1, took_at=int(time.time()) - 5, took_code=wake.CODE)
    ok, owner = wake.acquire_lock(save, time.time(), True, alive=lambda p: True)
    assert not ok and owner["pid"] == 333 and owner["cooldown"] > 0


def test_bug474_refresh_keeps_took_code(save, monkeypatch):
    monkeypatch.setattr(wake, "pid_alive", lambda p: True)
    put(save, os.getpid(), took=111, took_at=int(time.time()) - 10, took_code="0ld0c0de0000")
    assert wake.refresh_lock(save, time.time() + 1) is None
    assert lock(save)["took_code"] == "0ld0c0de0000"


def test_bug474_run_takes_over_and_the_old_one_exits_by_itself(save, monkeypatch, capsys):
    """The whole round: the deploy's new follow takes the lock; the old one finds another live pid at its next beat."""
    monkeypatch.setattr(wake.Follower, "poll", lambda self: (_ for _ in ()).throw(KeyboardInterrupt))
    monkeypatch.setattr(wake, "pid_alive", lambda p: p in (19612, os.getpid()))
    monkeypatch.setenv("DFLLM_FOLLOW_SID", "shell-1")
    put(save, 19612, code="0ld0c0de0000", took=111, took_at=int(time.time()) - 5, took_sid="shell-1")
    args = type("A", (), {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0, "interval": 0.02,
                          "takeover": True})()
    assert wake.run(args) == 0                       # KeyboardInterrupt from poll: it got past the lock
    assert "another follow owns" not in capsys.readouterr().out
    # what the old follow's next beat sees while the new one holds the lock: a live foreign owner (it exits)
    put(save, 4242, code=wake.CODE)
    owner = wake.refresh_lock(save, time.time() + 1, alive=lambda p: p == 4242)
    assert owner is not None and owner["pid"] == 4242


def test_bug474_a_second_beating_pid_is_said_once_after_the_stale_window(save, monkeypatch, capsys):
    monkeypatch.setattr(wake, "pid_alive", lambda p: p == 25008)
    lk = wake._Lock(False)
    lk.dir = save
    now = time.time()
    files.write_follow_hb(save, {"v": 2, "wall": int(now), "last_n": 0, "code": "0ld0c0de0000", "pid": 25008})
    lk._dup_check(save, now)
    assert capsys.readouterr().out == ""             # first sight: it may be the displaced one's last beat
    lk._dup_check(save, now + wake.FOLLOW_LOCK_STALE_S + 1)
    out = capsys.readouterr().out
    assert "BUG-474" in out and "pid 25008" in out and "Stop-Process -Id 25008" in out
    lk._dup_check(save, now + wake.FOLLOW_LOCK_STALE_S + 5)
    assert capsys.readouterr().out == ""             # once per pid


# ------------------------------------------------------------------ BUG-475
class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


def beat(save, tick, paused=False, at=None):
    """The kernel's heartbeat at wall time `at` (file mtime = the beat; the tick may stand)."""
    at = time.time() if at is None else at
    hb = {"frame": 1, "mode": "PEACE", "paused": paused, "seq": 1, "tick": tick, "v": 2, "wall": int(at)}
    files.write_json_atomic(save / "heartbeat", hb)
    os.utime(save / "heartbeat", (at, at))


def follower(save):
    f = wake.Follower(out=lambda line: None, clock=Clock(time.time()))
    f._attach(save)
    return f


def look(f, save, tick, at, paused=False):
    beat(save, tick, paused, at)
    f._check_stall(at)


def test_bug475_a_standing_tick_with_the_kernel_alive_wakes_once(save):
    f = follower(save)
    now = time.time()
    look(f, save, 1_000_000, now)
    look(f, save, 1_000_000, now + wake.STALL_S - 1)
    assert f.gate.pending == {}
    look(f, save, 1_000_000, now + wake.STALL_S + 1)
    assert "TICK_STALL" in f.gate.pending
    msg = f.gate.pending["TICK_STALL"]["e"]["msg"]
    assert "tick 1000000 static" in msg and "not paused" in msg and "Esc/Enter" in msg
    f.gate.pending.clear()
    look(f, save, 1_000_000, now + wake.STALL_S + 30)
    assert f.gate.pending == {}                      # once per stall
    look(f, save, 1_000_000, now + wake.STALL_S + wake.STALL_AGAIN_S + 5)
    assert "TICK_STALL" in f.gate.pending            # and again when it goes on


def test_bug475_a_moving_tick_or_a_players_pause_is_no_stall(save):
    f = follower(save)
    now = time.time()
    look(f, save, 5, now)
    look(f, save, 6, now + wake.STALL_S + 1)         # moved: the clock restarts
    look(f, save, 6, now + wake.STALL_S + 2)
    assert f.gate.pending == {}
    look(f, save, 6, now + 3 * wake.STALL_S, paused=True)     # state owners.pause is not df / popup in the fixture
    look(f, save, 6, now + 4 * wake.STALL_S, paused=True)
    assert f.gate.pending == {}


def test_bug475_pause_popup_names_the_logged_text_and_resume(save):
    st = files.read_state(save)
    st["owners"] = {"pause": "popup", "tempo": "mode"}
    st["seq"] += 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    append_events(save, [ev(9000, "PAUSED_BY_DF", "PAUSED_BY_DF for 5 min", {"by": "popup", "min": 5, "popup": "A mandate has expired."})])
    f = follower(save)
    now = time.time()
    look(f, save, 77, now, paused=True)
    look(f, save, 77, now + wake.STALL_S + 1, paused=True)
    msg = f.gate.pending["TICK_STALL"]["e"]["msg"]
    assert "paused by popup" in msg and "A mandate has expired." in msg and "dfllm cmd resume" in msg


def test_bug475_a_heartbeat_that_stops_beating_is_hb_stale_not_a_stall(save):
    f = follower(save)
    now = time.time()
    look(f, save, 9, now)
    f._check_stall(now + 10 * wake.STALL_S)          # the heartbeat file was not rewritten: the kernel is not beating
    f._check_stall(now + 20 * wake.STALL_S)
    assert f.gate.pending == {}


def test_bug475_tick_stall_is_a_synth_wake_with_a_next_hint():
    assert "TICK_STALL" in wake.SYNTH and "TICK_STALL" in wake.NEXT and "TICK_STALL" in wake.PRIO


# ------------------------------------------------------------------ BUG-477
def test_bug477_minimal_plan_falls_back_to_the_error_free_subset(save, monkeypatch):
    """i1 y379-y388 / i2 y386-y397: the check ERROR belongs to a drafted build whose repair minimal_ok forbids (a core stage
    behind a parked stage 1): the plan follow applies is the subset without it, not an AUTO_FAIL every year."""
    state = files.read_state(save)
    seen = {}
    real_fix = plan._fix_rounds

    def fix(doc, *a, **k):
        real_fix(doc, *a, **k)
        seen["fix"] = True
        return ["seasons[0].build[0] fortcore stage 3 @same would build on a parked stage 1: re-site first"], []

    def subset(cand, *a, **k):
        seen["subset"] = True
        return cand, ["w"]

    monkeypatch.setattr(plan, "_fix_rounds", fix)
    monkeypatch.setattr(plan, "_subset", subset)
    r = plan.auto_plan(save, state)
    assert seen == {"fix": True, "subset": True}
    assert r["errs"] == [] and len(r["held"]) == 1 and "re-site first" in r["held"][0]
    assert "1 ERROR held back" in r["doc"]["notes"]


def test_bug477_without_a_subset_the_errors_stay(save, monkeypatch):
    monkeypatch.setattr(plan, "_fix_rounds", lambda doc, *a, **k: (["boom"], []))
    monkeypatch.setattr(plan, "_subset", lambda *a, **k: None)
    r = plan.auto_plan(save, files.read_state(save))
    assert r["errs"] == ["boom"] and r["held"] == []
