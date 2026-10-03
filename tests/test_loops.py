"""FEATURE-006: loop registry (lockfiles + heartbeat), duplicate/stale detection, stop, adoption by the CLI loops."""
import json
import os
import subprocess
import sys
import time

import pytest

from df_llm_helper import loops as L
from df_llm_helper.cli import main
from df_llm_helper.clock import FakeClock
from df_llm_helper.digest import DigestState, build_digest
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.wake import wake_check
from helpers import ROOT

SLEEPER = [sys.executable, "-c", "import time; time.sleep(60)"]


@pytest.fixture(autouse=True)
def no_psutil(monkeypatch):
    """The player's machine may lack psutil: the registry must work with the OS calls alone."""
    monkeypatch.setattr(L, "_psutil", lambda: None)


@pytest.fixture
def sleeper():
    p = subprocess.Popen(SLEEPER)
    yield p
    if p.poll() is None:
        p.kill()
        p.wait()


def dead_pid():
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    return p.pid


def lock(tools, fname, name, pid, *, beat_age=1.0, interval=10, cmd="python -m df_llm_helper wake --loop"):
    d = tools / "loops"
    d.mkdir(parents=True, exist_ok=True)
    now = time.time()
    (d / fname).write_text(json.dumps({"name": name, "pid": pid, "started": now - 100, "heartbeat": now - beat_age,
                                       "interval_s": interval, "cmd": cmd}), encoding="utf-8")
    return d / fname


def cfgfile(tmp_path, tools):
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tools}\n  scopes: {tools / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'gamelog.txt'}\n  exceptions: {tmp_path / 'ex.jsonl'}\n", encoding="utf-8")
    return str(c)


# ---------------------------------------------------------------- acceptance (fixture based)
def test_two_lockfiles_with_the_same_name_are_duplicate(tmp_path, sleeper):
    lock(tmp_path, "wake.lock", "wake", os.getpid())
    lock(tmp_path, f"wake.{sleeper.pid}.lock", "wake", sleeper.pid)
    infos = L.scan(tmp_path)
    assert [i.status for i in infos] == ["DUPLICATE", "DUPLICATE"]
    probs = L.problems(infos)
    assert len(probs) == 1 and probs[0].startswith("Loop wake runs 2x")


def test_stale_heartbeat_is_stale(tmp_path):
    lock(tmp_path, "guard.lock", "guard", os.getpid(), beat_age=900, interval=60)    # limit 3 x 60 + 30 = 210 s
    lock(tmp_path, "wake.lock", "wake", os.getpid(), beat_age=5, interval=10)
    st = {i.name: i.status for i in L.scan(tmp_path)}
    assert st == {"guard": "STALE", "wake": "OK"}
    assert any("guard" in p and "hangs" in p for p in L.problems(L.scan(tmp_path)))


def test_stop_removes_the_lock_of_a_dead_loop(tmp_path):
    p = lock(tmp_path, "siege.lock", "siege", dead_pid())
    assert L.scan(tmp_path)[0].status == "DEAD"
    out = L.stop(tmp_path, "siege", wait_s=0)
    assert "lock removed" in out[0] and not p.exists()


def test_stop_kill_terminates_a_matching_process_and_removes_the_lock(tmp_path, sleeper):
    p = lock(tmp_path, "holdguard.lock", "holdguard", sleeper.pid, cmd=" ".join(SLEEPER))
    out = L.stop(tmp_path, "holdguard", kill=True, wait_s=0.5)
    assert "killed, lock removed" in out[0] and not p.exists()
    sleeper.wait(5)
    assert sleeper.returncode is not None


def test_stop_kill_refuses_a_reused_pid(tmp_path, sleeper):
    lock(tmp_path, "waechter.lock", "waechter", sleeper.pid, cmd="python -m df_llm_helper waechter --loop")
    out = L.stop(tmp_path, "waechter", kill=True, wait_s=0.5)
    assert "NOT killed" in out[0]
    assert sleeper.poll() is None                                    # the foreign program keeps running


# ---------------------------------------------------------------- the loop side
def test_second_start_refuses_and_warn_mode_registers_a_duplicate(tmp_path, sleeper):
    lock(tmp_path, "autopilot.lock", "autopilot", sleeper.pid)
    with pytest.raises(L.LoopBusy, match="already runs"):
        L.LoopLock(tmp_path, "autopilot").acquire()
    seen = []
    with L.LoopLock(tmp_path, "autopilot", on_duplicate="warn", report=seen.append) as lk:
        assert lk.path.name == f"autopilot.{os.getpid()}.lock" and seen and "DUPLICATE" in seen[0]
        assert {i.status for i in L.scan(tmp_path)} == {"DUPLICATE"}
    assert not lk.dir.joinpath(f"autopilot.{os.getpid()}.lock").exists()


def test_dead_lock_is_reclaimed_and_released(tmp_path):
    lock(tmp_path, "guard.lock", "guard", dead_pid())
    with L.LoopLock(tmp_path, "guard", "x") as lk:
        j = json.loads(lk.path.read_text())
        assert lk.path.name == "guard.lock" and j["pid"] == os.getpid() and j["cmd"] == "x"
    assert not (tmp_path / "loops" / "guard.lock").exists()


def test_beat_refreshes_the_heartbeat_and_sees_a_stop_request(tmp_path):
    t = [1000.0]
    with L.LoopLock(tmp_path, "wake", "x", clock=lambda: t[0], cfg={"beat_min_s": 5}) as lk:
        t[0] += 30
        assert lk.beat() is True
        assert json.loads(lk.path.read_text())["heartbeat"] == 1030.0
        (tmp_path / "loops" / "wake.stop").write_text("4242")      # stop for another pid only
        assert lk.beat() is True
        (tmp_path / "loops" / "wake.stop").write_text(str(os.getpid()))
        assert lk.beat() is False


def test_pid_alive_without_psutil(sleeper):
    assert L.pid_alive(os.getpid()) and L.pid_alive(sleeper.pid)
    assert not L.pid_alive(dead_pid()) and not L.pid_alive(0) and not L.pid_alive("x")


def test_invalid_names_are_refused(tmp_path):
    for bad in ("../x", "a b", "", "x" * 41):
        with pytest.raises(ValueError):
            L.LoopLock(tmp_path, bad)


# ---------------------------------------------------------------- CLI, wake, digest, check
def test_cli_list_json_stop_and_clean(tmp_path, capsys, sleeper):
    tools = tmp_path / "tools"
    lock(tools, "wake.lock", "wake", os.getpid())
    lock(tools, f"wake.{sleeper.pid}.lock", "wake", sleeper.pid)
    lock(tools, "siege.lock", "siege", dead_pid())
    cfg = cfgfile(tmp_path, tools)
    rc = main(["--config", cfg, "loops", "list", "--json"])
    j = json.loads(capsys.readouterr().out)
    assert rc == 1 and sorted(x["status"] for x in j["loops"]) == ["DEAD", "DUPLICATE", "DUPLICATE"]
    assert main(["--config", cfg, "loops", "clean"]) == 0
    assert "removed dead lock siege.lock" in capsys.readouterr().out
    assert main(["--config", cfg, "loops", "stop"]) == 2                         # name missing: usage error
    assert main(["--config", cfg, "loops", "stop", "../x"]) == 2


def test_wake_reports_a_duplicate_loop(tmp_path, sleeper):
    tools = tmp_path / "tools"
    tools.mkdir()
    clock = FakeClock(1_790_840_000.0)
    store = Store()
    wake_check(ToolsDir(tools, clock), store, clock)                             # baseline
    lock(tools, "siege.lock", "siege", os.getpid())
    lock(tools, f"siege.{sleeper.pid}.lock", "siege", sleeper.pid)
    out = wake_check(ToolsDir(tools, clock), store, clock)
    assert len(out) == 1 and out[0].startswith("WAKE loops: Loop siege runs 2x")
    assert wake_check(ToolsDir(tools, clock), store, clock) == []                # deduplicated


def test_digest_shows_loop_items_once(tmp_path, sleeper):
    from df_llm_helper.config import DEFAULTS
    from df_llm_helper.pilot import Pilot
    from df_llm_helper.config import Config
    from df_llm_helper.snapshot import Snapshot
    from df_llm_helper.client import MockClient
    tools = tmp_path / "tools"
    lock(tools, "wake.lock", "wake", os.getpid())
    lock(tools, f"wake.{sleeper.pid}.lock", "wake", sleeper.pid)
    data = json.loads(json.dumps(DEFAULTS))
    data["paths"]["tools"] = str(tools)
    p = Pilot(Config(data), MockClient({}), store=Store(), tools=ToolsDir(tools, FakeClock(0)))
    items = p.loop_items()
    assert [i.key for i in items] == ["loop:dup:wake"]
    t1, st = build_digest(Snapshot(), DigestState(), th=DEFAULTS["thresholds"], extra=items)
    assert "Loop wake runs 2x" in t1
    t2, _ = build_digest(Snapshot(), st, th=DEFAULTS["thresholds"], extra=items)
    assert "Loop wake" not in t2 and "Loops" in t2                            # 'still open', not repeated


def test_real_wake_loop_registers_refuses_a_second_start_and_stops(tmp_path):
    tools = tmp_path / "tools"
    cfg = cfgfile(tmp_path, tools)
    env = {**os.environ, "PYTHONPATH": str(ROOT)}
    cmd = [sys.executable, "-m", "df_llm_helper", "--config", cfg, "wake", "--loop", "--interval", "0.2"]
    p = subprocess.Popen(cmd, cwd=str(ROOT), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        lk = tools / "loops" / "wake.lock"
        for _ in range(100):
            if lk.exists():
                break
            time.sleep(0.1)
        assert lk.exists(), p.stderr.read1().decode() if p.poll() is not None else "no lock"
        assert json.loads(lk.read_text())["pid"] == p.pid
        r = subprocess.run(cmd, cwd=str(ROOT), env=env, capture_output=True, timeout=30)
        assert r.returncode == 2 and b"already runs" in r.stderr
        out = L.stop(tools, "wake", wait_s=15)
        assert "stopped (stop request)" in out[0]
        p.wait(15)
        assert p.returncode == 0 and not lk.exists()
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()


def test_check_hook_lists_problems_but_not_dead_locks(tmp_path, sleeper):
    from types import SimpleNamespace
    from df_llm_helper.features import loops as F
    lock(tmp_path, "guard.lock", "guard", os.getpid(), beat_age=999)
    lock(tmp_path, "siege.lock", "siege", dead_pid())
    pilot = SimpleNamespace(cfg={}, tools=SimpleNamespace(path=tmp_path))
    lines = F.check_hook(pilot, None, True)
    assert len(lines) == 1 and "guard" in lines[0] and "hangs" in lines[0]
