"""NEU5 (BUG-849): a CLI call that blocks keeps the session heartbeat (the kernel's dead-man switch) fresh while it runs; a dead process stops beating."""
import json
import time

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import session


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    monkeypatch.delenv(session.NO_SESSION_ENV, raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def wall_of(save):
    return json.loads((save / session.SESSION_FILE).read_text(encoding="utf-8"))["wall"]


def test_a_blocking_call_refreshes_every_keepalive_interval_with_a_fake_clock(save):
    mono, wall = Clock(), Clock(5_000_000.0)
    session.touch(save, "wait", wall())
    ka = session.Keepalive(save, "wait", every=15.0, clock=mono, wall=wall)
    mono.t += 14.0
    wall.t += 14.0
    assert ka.tick() is False and wall_of(save) == 5_000_000
    mono.t += 2.0
    wall.t += 2.0
    assert ka.tick() is True and wall_of(save) == 5_000_016
    for _ in range(4):                     # a long call: one beat per 15 s, never a gap above that
        mono.t += 15.0
        wall.t += 15.0
        assert ka.tick() is True
    assert ka.beats == 5 and wall_of(save) == 5_000_076
    mono.t += 5.0
    assert ka.tick() is False, "not twice inside one interval"


def test_the_beat_comes_from_a_thread_while_the_main_thread_blocks_and_stops_with_it(save):
    session.touch(save, "audit", 1.0)                       # an old heartbeat value
    ka = session.Keepalive(save, "audit", every=0.05)
    with ka:
        time.sleep(0.5)                                     # the blocked call
        w1 = wall_of(save)
    assert w1 > 1_000_000, "refreshed during the block"
    n = ka.beats
    assert n >= 1 and ka._thread is None
    time.sleep(0.2)
    assert ka.beats == n, "after the call (or the process) nothing beats any more"


def test_only_a_live_session_is_extended_by_the_long_calls_of_other_commands(save):
    wall = Clock(7_000_000.0)
    ka = session.Keepalive(save, "audit", extend_only=True, wall=wall)         # no session.json at all: a supervisor's look
    assert ka.alive is False
    ka.last -= 100
    assert ka.tick() is False and not (save / session.SESSION_FILE).exists()
    session.touch(save, "wait", wall() - 30)                                     # a session beat 30 s ago
    ka2 = session.Keepalive(save, "bp", extend_only=True, wall=wall)
    assert ka2.alive is True
    ka2.last -= 100
    assert ka2.tick() is True and wall_of(save) == 7_000_000
    session.touch(save, "wait", wall() - 600)                                    # a dead session (10 min old)
    assert session.Keepalive(save, "audit", extend_only=True, wall=wall).alive is False


def test_the_factory_covers_the_session_commands_and_the_long_calls_and_honours_the_switch(save, monkeypatch):
    for c in ("wait", "brief", "cmd", "ack", "plan", "next"):
        ka = session.keepalive(save, c)
        assert isinstance(ka, session.Keepalive) and ka.alive
    session.touch(save, "wait")
    assert isinstance(session.keepalive(save, "audit"), session.Keepalive)
    assert isinstance(session.keepalive(save, "why"), session.Keepalive)
    for c in ("status", "events", "doctor", "follow", "supervise"):
        assert not isinstance(session.keepalive(save, c), session.Keepalive), c
    monkeypatch.setenv(session.NO_SESSION_ENV, "1")
    assert not isinstance(session.keepalive(save, "wait"), session.Keepalive)
    assert not isinstance(session.keepalive(None, "wait"), session.Keepalive)


def test_main_runs_the_command_inside_the_keepalive(save, monkeypatch):
    from dfpilot import cli, paths
    seen = []

    class Spy:
        def __enter__(self):
            seen.append("in")

        def __exit__(self, *a):
            seen.append("out")

    monkeypatch.setattr(session, "keepalive", lambda d, c: Spy())
    monkeypatch.setattr(cli, "_dispatch", lambda args, d, c: seen.append(("run", c)) or 0)
    monkeypatch.setattr(paths, "save_dir", lambda: save)
    assert cli.main(["audit"]) == 0
    assert seen == ["in", ("run", "audit"), "out"]
