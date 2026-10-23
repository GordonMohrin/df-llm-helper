"""BUG-069 (Run 13 y506: `dfllm save` said QUICKSAVE_FAILED after 122 s while quicksaves take 54-110 s in a big world and
the newest save was an autosave 12 minutes old): the wait follows the real duration (DF writes save/current while it saves),
a save still running is not a failure, no second quicksave starts while DF writes or an autosave just saved the game, and the
message says which of these happened. Fake clock, fake OS, tmp dirs only."""
import json
from pathlib import Path
from types import SimpleNamespace

from cli_v2_helpers import reset_paths  # noqa: F401
from test_save import W, Clock, make_save, put  # noqa: F401  (fixture W)

from dfpilot import brief, save as qs, schema, wake

T0 = 1_791_700_000.0


def args(**kw):
    return SimpleNamespace(**{"timeout": 120, "min_gap": qs.MIN_GAP_S, "by": "cli", "dry_run": False, **kw})


def record(W):
    rec = json.loads((W.save / qs.RECORD).read_text("utf-8"))
    assert schema.validate("quicksave", rec) == []
    return rec


class LongSave:
    """dfhack('quicksave'): after `start` s DF fills save/current (a file touched every second), after `end` s the folder
    'autosave 1' lands and save/current is emptied. end=None: DF writes for ever (a stuck save)."""

    def __init__(self, W, start=20, end=250):
        self.W, self.start, self.end, self.calls = W, start, end, []
        self.t0 = None

    def dfhack(self, *a, timeout=60):
        self.calls.append(a)
        W, t0 = self.W, W_now(self.W)
        self.t0 = t0

        def hook(t):
            cur = W.env.saves / "current" / "unit-1.dat"
            if t >= t0 + self.start and (self.end is None or t < t0 + self.end):
                put(cur, b"x", t)
            elif self.end is not None and t >= t0 + self.end:
                if cur.exists():
                    cur.unlink()
                make_save(W.env.saves, "autosave 1", t)
                W.clock.hooks.remove(hook)
        W.clock.hooks.append(hook)
        return True, ""


def W_now(W):
    return W.clock()


def test_a_save_that_takes_four_minutes_is_followed_to_the_end(W):
    """Base: the wait ends at --timeout (120 s) with QUICKSAVE_FAILED although DF is writing; now the wait goes on while
    save/current fills (max-wait) and the save is verified."""
    W.env.os = LongSave(W, start=20, end=250)
    rec = qs.quicksave(W.env, W.save, timeout=120)
    assert rec["ok"] == 1 and rec["state"] == "ok" and rec["folder"] == "autosave 1", rec
    assert 250 <= rec["secs"] <= 260 and rec["fails"] == 0
    assert "written 250 s after the call" in rec["why"]


def test_a_save_still_running_at_the_limit_is_running_not_failed(W, capsys):
    W.env.os = LongSave(W, start=10, end=None)
    assert qs.run(args(timeout=60, max_wait=200), W.save, env=W.env) == qs.EXIT_RUNNING
    rec = record(W)
    assert rec["ok"] == 0 and rec["state"] == "running" and rec["kind"] == "writing" and rec["secs"] <= 205, rec
    assert "still being written" in rec["why"] and "not a failure" in rec["why"]
    out = capsys.readouterr().out
    assert out.startswith("QUICKSAVE_RUNNING:") and "QUICKSAVE_FAILED" not in out
    # follow does not call it a failure, status says it runs
    c = Clock(W.clock() + 5)
    got = []
    f = wake.Follower(out=got.append, clock=c)
    f.poll()
    for _ in range(3):
        c.t += 20
        f.poll()
    assert not any("QUICKSAVE_FAILED" in x for x in got)
    assert "QUICKSAVE RUNNING" in brief.line_save(W.save, now=rec["wall"] + 120)
    assert "QUICKSAVE UNSETTLED" in brief.line_save(W.save, now=rec["wall"] + 2400)
    # the rate limit does not call a running save "failed"
    W.clock.t = rec["wall"] + 30
    put(W.env.saves / "current" / "unit-1.dat", b"x", W.clock() - 100)       # stale leftover: DF is not writing now
    assert "the last running quicksave was" in qs.refusal(W.save, None, W.clock(), qs.MIN_GAP_S, "region7")


def test_silent_failure_says_that_df_started_no_save(W):
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: (True, ""))
    rec = qs.quicksave(W.env, W.save, timeout=30)
    assert rec["ok"] == 0 and rec["state"] == "failed" and rec["kind"] == "silent", rec
    assert "DF started no save" in rec["why"] and "save/current stayed empty" in rec["why"]
    assert "the newest save is 'region7' from 60 min ago" in rec["why"]


def test_call_failure_has_its_own_kind(W):
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: (False, "error: could not connect to DFHack"))
    rec = qs.quicksave(W.env, W.save, timeout=30)
    assert rec["state"] == "failed" and rec["kind"] == "call" and "dfhack-run quicksave failed" in rec["why"]


def test_no_second_quicksave_while_df_writes(W, capsys):
    put(W.env.saves / "current" / "unit-1.dat", b"x", W.clock() - 5)         # an autosave in progress
    called = []
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: called.append(a) or (True, ""))
    assert qs.run(args(), W.save, env=W.env) == 3 and called == []
    out = capsys.readouterr().out
    assert "DF is writing a save" in out and "1 file(s)" in out
    assert "refused: DF is writing a save" in (W.save / "cli.log").read_text("utf-8")
    # a leftover from long ago is no activity
    put(W.env.saves / "current" / "unit-1.dat", b"x", W.clock() - 3600)
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: called.append(a) or (True, ""))
    qs.run(args(timeout=5), W.save, env=W.env)
    assert called == [("quicksave",)]


def test_a_fresh_autosave_is_the_save(W, capsys):
    """The yearly autosave just wrote the fort: no second quicksave 80 s later (run_watch asks at the year start)."""
    make_save(W.env.saves, "autosave 2", W.clock() - 80)
    called = []
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: called.append(a) or (True, ""))
    assert qs.run(args(), W.save, env=W.env) == 0 and called == []
    out = capsys.readouterr().out
    assert "not needed" in out and "autosave 2" in out
    rec = record(W)
    assert rec["ok"] == 1 and rec["state"] == "ok" and rec["kind"] == "autosave" and rec["folder"] == "autosave 2"
    # --min-gap 0 forces the quicksave
    W.clock.t += 1
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: called.append(a) or (True, ""))
    qs.run(args(timeout=5, min_gap=0), W.save, env=W.env)
    assert called == [("quicksave",)]


def test_a_save_that_lands_after_the_failure_settles_it(W, capsys):
    """Run 13: the failure was written at 122 s; the save landed later. The next call finds it, rewrites the record
    (ok, late) and starts no second quicksave; the record keeps the delay for the live diagnosis."""
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: (True, ""))
    rec = qs.quicksave(W.env, W.save, timeout=30)
    assert rec["ok"] == 0 and rec["state"] == "failed"
    t_call = rec["wall"]
    make_save(W.env.saves, "autosave 3", t_call + 130)
    W.clock.t = t_call + 400
    called = []
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: called.append(a) or (True, ""))
    assert qs.run(args(), W.save, env=W.env) == 0 and called == []
    rec = record(W)
    assert rec["ok"] == 1 and rec["state"] == "ok" and rec["folder"] == "autosave 3" and rec["late"] == 130 - 30
    assert "130 s after the call" in rec["why"] and "late" in rec["why"]
    assert "landed after the wait" in capsys.readouterr().out


def test_a_save_an_hour_later_is_not_the_late_save_of_a_failed_call(W):
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: (True, ""))
    rec = qs.quicksave(W.env, W.save, timeout=30)
    make_save(W.env.saves, "autosave 3", rec["wall"] + 3600)            # the next yearly autosave, an hour later
    W.clock.t = rec["wall"] + 3700
    called = []
    W.env.os = SimpleNamespace(dfhack=lambda *a, timeout=60: called.append(a) or (True, ""))
    again = qs.settle(W.env, W.save)
    assert again["ok"] == 0 and again["state"] == "failed"
    qs.run(args(timeout=5, min_gap=0), W.save, env=W.env)
    assert called == [("quicksave",)]


def test_a_running_save_that_never_lands_becomes_a_failure(W):
    W.env.os = LongSave(W, start=5, end=None)
    rec = qs.quicksave(W.env, W.save, timeout=30, max_wait=60)
    assert rec["state"] == "running"
    (W.env.saves / "current" / "unit-1.dat").unlink()                       # DF stopped writing, nothing landed
    W.clock.t += qs.RUNNING_GRACE_S + 100
    W.clock.hooks.clear()
    again = qs.settle(W.env, W.save)
    assert again["ok"] == 0 and again["state"] == "failed" and again["kind"] == "vanished", again
    assert "stopped writing" in again["why"]
    got = []
    c = Clock(again["wall"] + 500)
    f = wake.Follower(out=got.append, clock=c)
    for _ in range(4):
        c.t += 20
        f.poll()
    assert any("QUICKSAVE_FAILED" in x for x in got)


def test_the_limits_are_configurable_and_checked(tmp_path, monkeypatch):
    from dfpilot import fairplay
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path))
    assert qs.limits() == {"wait_s": qs.WAIT_S, "max_wait_s": qs.MAX_WAIT_S, "autosave_fresh_s": qs.AUTOSAVE_FRESH_S}
    (tmp_path / "baseline.json").write_text(json.dumps({"v": 2, "save": {"wait_s": 90, "max_wait_s": 300}}))
    assert qs.limits()["wait_s"] == 90 and qs.limits()["max_wait_s"] == 300
    (tmp_path / "baseline.json").write_text(json.dumps({"v": 2, "save": {"wait_s": 5, "max_wait_s": "x", "bogus": 1}}))
    assert qs.limits()["wait_s"] == qs.WAIT_S                                  # a bad value = the default
    errs = fairplay.save_errors(tmp_path / "baseline.json")
    assert any("save.wait_s" in e for e in errs) and any("save.max_wait_s" in e for e in errs)
    assert any("save.bogus: unknown key" in e for e in errs)
    assert fairplay.save_errors() == []                                       # the shipped config
    reset_paths()


def test_run_watch_waits_as_long_as_the_cli(monkeypatch):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
    import run_watch
    seen = {}

    def fake(cmd, **kw):
        seen.update(kw)
        return SimpleNamespace(returncode=4, stdout="QUICKSAVE_RUNNING: still being written\n", stderr="")
    monkeypatch.setattr(run_watch.subprocess, "run", fake)
    assert run_watch.save_verified()[0] == 4
    assert seen["timeout"] >= qs.MAX_WAIT_S + qs.CALL_S
