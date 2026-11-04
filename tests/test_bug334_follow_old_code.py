"""BUG-334 (Run 15b Earthboat y385: 'follow already runs' from pid 22684 on OLD CODE; the player did not know --takeover
and watched by polling): a follow takes the save over by itself from a follow that runs other dfpilot code."""
import json
import os
import time

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, wake


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def ARGS(**kw):
    a = {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0.3, "interval": 0.02}
    a.update(kw)
    return type("A", (), a)()


def lock(save, pid, code=None):
    doc = {"v": 1, "pid": pid, "start": int(time.time()), "hb": int(time.time())}
    if code is not None:
        doc["code"] = code
    files.write_json_atomic(save / wake.FOLLOW_LOCK, doc)


def test_bug334_lock_carries_the_code(save):
    assert wake.acquire_lock(save, time.time(), alive=lambda pid: True) == (True, None)
    doc = json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))
    assert doc["pid"] == os.getpid() and doc["code"] == wake.CODE
    assert wake.refresh_lock(save, time.time() + 10, alive=lambda pid: True) is None
    assert json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))["code"] == wake.CODE


def test_bug334_owner_code_from_lock_or_hb(save):
    now = time.time()
    assert wake.owner_code(save, {"pid": 1, "code": "abc"}, now) == "abc"
    assert wake.owner_code(save, {"pid": 1}, now) is None                        # nothing says: unknown
    files.write_follow_hb(save, {"v": 2, "wall": int(now), "last_n": 0, "code": "old123", "auto": 1})
    assert wake.owner_code(save, {"pid": 1}, now) == "old123"                  # a follower from before BUG-334
    assert wake.owner_code(save, {"pid": 1}, now + files.FOLLOW_STALE_S + 60) is None    # a stale heartbeat says nothing


def test_bug334_old_code_owner_is_taken_over(save, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(wake.Follower, "poll", lambda self: calls.append(1))
    monkeypatch.setattr(wake, "pid_alive", lambda pid: pid in (22684, os.getpid()))
    lock(save, 22684)                                                           # a pre-BUG-334 lock without code
    files.write_follow_hb(save, {"v": 2, "wall": int(time.time()), "last_n": 0, "code": "0ld0c0de0000", "auto": 1})
    assert wake.run(ARGS(max_s=0.2)) == 0 and calls                              # it polls: no exit 3
    out = capsys.readouterr().out
    assert "pid 22684 ran OLD CODE (0ld0c0de0000" in out and "taken over" in out
    assert "follow already runs" not in out
    assert "OLD CODE" in (save / "cli.log").read_text("utf-8")


def test_bug334_old_one_exits_at_its_next_beat(save, monkeypatch):
    """The owner (old code) finds the new pid in the lock at its next beat and exits (BUG-238 refresh_lock)."""
    lock(save, 5151, code="newer")
    assert wake.refresh_lock(save, time.time(), alive=lambda pid: True)["pid"] == 5151


def test_bug334_same_code_still_refused(save, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(wake.Follower, "poll", lambda self: calls.append(1))
    monkeypatch.setattr(wake, "pid_alive", lambda pid: pid in (4242, os.getpid()))
    lock(save, 4242, code=wake.CODE)
    assert wake.run(ARGS()) == 3 and calls == []
    out = capsys.readouterr().out
    assert "follow already runs (pid 4242" in out and "dfllm follow --takeover" in out
    assert json.loads((save / wake.FOLLOW_LOCK).read_text("utf-8"))["pid"] == 4242
