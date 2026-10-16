"""Run 10 (item 6): `dfllm save` verifies DFHack's quicksave by the save folder's file times; a failure is loud (exit 1,
QUICKSAVE_FAILED) and wakes follow. Live: after a graphics crash `dfhack-run quicksave` wrote nothing (no error, no file,
empty output) and the restart loaded a state 30 game days older. Fake clock, fake OS, tmp dirs only."""
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, save as qs, schema, supervise as sv, wake

T0 = 1_791_700_000.0
MARK = ("region7", 1000, "Testfort")
OTHER = ("region9", 5000, "Otherfort")


class Clock:
    def __init__(self, t=T0):
        self.t, self.hooks = t, []

    def __call__(self):
        return self.t

    def sleep(self, dt):
        self.t += dt
        for h in list(self.hooks):
            h(self.t)


def put(p, data, t):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
    os.utime(p, (t, t))


def make_save(saves, name, t, marker=MARK):
    d = Path(saves) / name
    put(d / "unit-1.dat", b"u" * 1000, t - 2)
    m = {"v": 2, "adopted": marker[1], "save": marker[0], "fort": marker[2], "acceptance": 0, "baseline": 1, "boots": 3}
    put(d / "dfhack-entity-110.dat", json.dumps([{"k": "dfllm", "s": json.dumps(m)}]), t - 1)
    put(d / "world.sav", b"w" * 20000, t)
    return d


class FakeOS:
    """dfhack('quicksave') -> what: 'save' (DF writes 'autosave 1' `delay` s later), 'nothing' (empty output, no file:
    the Run 10 case), 'other' (a save of another fort), 'error' (dfhack-run fails), 'slow' (DF still writing)."""

    def __init__(self, env, clock, what="save", delay=5):
        self.env, self.clock, self.what, self.delay, self.calls = env, clock, what, delay, []

    def dfhack(self, *args, timeout=60):
        self.calls.append(args)
        if self.what == "error":
            return False, "error: could not connect to DFHack"
        if self.what == "nothing":
            return True, ""
        at = self.clock() + self.delay

        def write(t):
            if t >= at:
                if self.what == "slow":
                    put(self.env.saves / "current" / "world.sav", b"w", t)
                else:
                    make_save(self.env.saves, "autosave 1", t, OTHER if self.what == "other" else MARK)
                self.clock.hooks.remove(write)
        self.clock.hooks.append(write)
        return True, "Saving the game..."


@pytest.fixture
def W(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    save_dir = make_runtime(tmp_path)                    # ACTIVE region7, PEACE, unpaused
    clock = Clock()
    env = sv.Env(df=tmp_path / "df", runtime=save_dir.parent, saves=tmp_path / "saves", backups=tmp_path / "bk",
                 repo=tmp_path / "repo", os=object(), clock=clock, sleep=clock.sleep)
    env.os = FakeOS(env, clock)
    make_save(env.saves, "region7", T0 - 3600)          # the loaded fort's save, an hour old
    yield SimpleNamespace(env=env, clock=clock, os=env.os, save=save_dir)
    reset_paths()


def args(**kw):
    return SimpleNamespace(**{"timeout": qs.WAIT_S, "min_gap": qs.MIN_GAP_S, "by": "cli", "dry_run": False, **kw})


def record(W):
    rec = json.loads((W.save / qs.RECORD).read_text("utf-8"))
    assert schema.validate("quicksave", rec) == []
    return rec


def test_verified_quicksave(W, capsys):
    assert qs.run(args(), W.save, env=W.env) == 0
    assert W.os.calls == [("quicksave",)]
    rec = record(W)
    assert rec["ok"] == 1 and rec["folder"] == "autosave 1" and rec["last"] == "region7" and rec["last_age"] == 3600
    assert 5 + sv.STABLE_S <= rec["secs"] <= 5 + sv.STABLE_S + 2 and rec["fails"] == 0
    assert "quicksave ok: autosave 1 written 5 s after the call" in capsys.readouterr().out
    log = (W.save / "cli.log").read_text("utf-8").strip().splitlines()[-1].split("\t")
    assert log[1:3] == ["cli", "quicksave"] and log[4].startswith("ok autosave 1")


def test_quicksave_that_writes_nothing_is_a_loud_failure(W, capsys):
    """The Run 10 case: no error, no file, empty output."""
    W.os.what = "nothing"
    assert qs.run(args(), W.save, env=W.env) == 1
    rec = record(W)
    assert rec["ok"] == 0 and rec["folder"] == "" and rec["fails"] == 1 and rec["secs"] == qs.WAIT_S
    assert rec["why"] == ("no fortress save folder newer than the call after 120 s (dfhack-run printed nothing); "
                          "the newest save is 'region7' from 60 min ago")
    out = capsys.readouterr().out
    assert out.startswith("QUICKSAVE_FAILED: no fortress save folder newer than the call") and "follow wakes" in out
    assert "QUICKSAVE_FAILED no fortress save" in (W.save / "cli.log").read_text("utf-8")
    W.clock.t += qs.RETRY_S + 1                         # retried after the failure gap: the count goes on
    assert qs.run(args(), W.save, env=W.env) == 1 and record(W)["fails"] == 2


def test_another_forts_save_or_a_save_in_progress_does_not_count(W):
    W.os.what = "other"
    rec = qs.quicksave(W.env, W.save, timeout=30)
    assert rec["ok"] == 0 and "no fortress save folder newer than the call after 30 s" in rec["why"]
    W.os.what = "slow"
    rec = qs.quicksave(W.env, W.save, timeout=30)
    assert rec["ok"] == 0 and rec["why"].startswith("DF was still writing save/current")


def test_dfhack_run_failure_waits_only_briefly(W):
    W.os.what = "error"
    rec = qs.quicksave(W.env, W.save, timeout=120)
    assert rec["ok"] == 0 and rec["secs"] <= qs.FAIL_WAIT_S + 1
    assert "dfhack-run quicksave failed (error: could not connect to DFHack)" in rec["why"]


def test_refusals(W, capsys):
    st = files.read_state(W.save)
    assert qs.refusal(W.save, st, W.clock(), qs.MIN_GAP_S, "region7") is None
    assert qs.refusal(W.save, st, W.clock(), qs.MIN_GAP_S, None).startswith("no fort loaded")
    for mode in ("SIEGE", "BREACH", "DRILL"):
        assert qs.refusal(W.save, dict(st, mode=mode), W.clock(), qs.MIN_GAP_S, "region7").startswith(f"mode {mode}")
    assert qs.run(args(), W.save, env=W.env) == 0
    capsys.readouterr()
    W.clock.t += 100
    assert qs.run(args(), W.save, env=W.env) == 3                       # 600 s after a verified save
    assert "rate limit: the last verified quicksave was" in capsys.readouterr().out
    assert W.os.calls == [("quicksave",)]
    assert qs.run(args(dry_run=True, min_gap=0), W.save, env=W.env) == 0
    assert "quicksave would run now" in capsys.readouterr().out and len(W.os.calls) == 1
    assert qs.run(args(min_gap=0), W.save, env=W.env) == 0 and len(W.os.calls) == 2
    assert "refused: rate limit" in (W.save / "cli.log").read_text("utf-8")


def test_follow_wakes_on_a_failed_quicksave(W):
    c = Clock(T0 + 10_000)
    out = []
    f = wake.Follower(out=out.append, clock=c)
    f.poll()
    files.write_json_atomic(W.save / qs.RECORD, {"v": 2, "wall": int(c.t - 4000), "ok": 0, "by": "cli", "why": "old"})
    c.t += 20
    f.poll()
    assert out == []                                     # first look: a failure older than an hour stays quiet
    W.os.what = "nothing"
    W.clock.t = c.t
    qs.quicksave(W.env, W.save, timeout=5)
    for _ in range(3):
        c.t += 20
        f.poll()
    assert len(out) == 1 and "QUICKSAVE_FAILED" in out[0] and "wrote nothing" in out[0]
    assert "next: tell Gordon at once (the game is not saved)" in out[0]
    W.os.what, W.clock.t = "save", c.t
    qs.quicksave(W.env, W.save, timeout=30)               # a verified save wakes nobody
    c.t += 400
    f.poll()
    assert len(out) == 1
    # a follow started after a fresh failure wakes for it once (state persists in .follow.json)
    W.os.what, W.clock.t = "nothing", c.t
    qs.quicksave(W.env, W.save, timeout=5)
    f.save_state()
    out2 = []
    g = wake.Follower(out=out2.append, clock=c)
    for _ in range(3):
        c.t += 20
        g.poll()
    assert len(out2) == 1 and "QUICKSAVE_FAILED" in out2[0]
    g.save_state()
    out3 = []
    h = wake.Follower(out=out3.append, clock=c)
    for _ in range(3):
        c.t += 20
        h.poll()
    assert out3 == []                                    # seen by the earlier follow: not again


def test_run_watch_saves_through_the_verifying_cli(monkeypatch):
    """tools/run_watch.py: the yearly quicksave is `python -m dfpilot save` (no bare `dfhack-run quicksave` any more)."""
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
    import run_watch
    seen = []

    def fake(cmd, **kw):
        seen.append(cmd)
        return SimpleNamespace(returncode=1, stdout="draft\nQUICKSAVE_FAILED: no fortress save folder ...\n", stderr="")
    monkeypatch.setattr(run_watch.subprocess, "run", fake)
    assert run_watch.save_verified() == (1, "QUICKSAVE_FAILED: no fortress save folder ...")
    assert seen == [run_watch.CLI + ["save", "--by", "cli"]]
    src = (Path(run_watch.__file__)).read_text("utf-8")
    assert '"quicksave"]' not in src and "[RUN, \"quicksave\"]" not in src


def test_hook_sends_a_bare_quicksave_to_dfllm_save():
    from dfpilot import lint
    ok, why = lint.cmd('"E:/DF/hack/dfhack-run.exe" quicksave', shell=True)
    assert not ok and "python -m dfpilot save" in why
    assert lint.cmd("python -m dfpilot save --by llm", shell=True)[0]


def test_status_and_brief_say_the_game_is_not_saved(W):
    from dfpilot import brief
    import time
    assert "QUICKSAVE" not in brief.status_text(W.save)
    files.write_json_atomic(W.save / qs.RECORD, {"v": 2, "wall": int(time.time()) - 120, "ok": 0, "by": "cli",
                                                 "why": "no fortress save folder newer than the call after 120 s"})
    for text in (brief.status_text(W.save), brief.brief_text(W.save)):
        assert "QUICKSAVE FAILED 2m ago: no fortress save folder newer than the call" in text, text
    files.write_json_atomic(W.save / qs.RECORD, {"v": 2, "wall": int(time.time()), "ok": 1, "by": "cli", "why": "ok"})
    assert "QUICKSAVE" not in brief.status_text(W.save)
