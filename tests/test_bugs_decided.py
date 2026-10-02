"""Regression tests for the bug reports whose open questions the player delegated to us (BUG-104, BUG-220, BUG-319,
BUG-418, BUG-421)."""
from __future__ import annotations

import json
import stat
import sys
from pathlib import Path

import pytest

from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient, RealClient, Result
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import DEFAULTS, load_config
from df_llm_helper.store import Store

HERE = Path(__file__).resolve().parent
HOME = HERE.parent
FIX = HOME / "fixtures" / "run5"
EVID = HOME / "Bugs" / "evidence"


# ---------------------------------------------------------------- BUG-104 mock rows in the live state.db
def _fixture_facts() -> tuple[str, dict]:
    from df_llm_helper.pilot import Pilot
    p = Pilot(load_config(None), MockClient.from_fixture_dir(FIX), store=Store())
    snap = p.snapshot()
    return snap.game_id, snap.facts()


def test_bug104_fingerprints_match_fixtures():
    """data/mock_fingerprints.json must describe what `--mock fixtures/run5` really writes (regenerate on change)."""
    from df_llm_helper.mockrows import FINGERPRINT_KEYS, load_fingerprints
    gid, facts = _fixture_facts()
    fps = load_fingerprints()
    assert any(fp["game_id"] == gid and fp["facts"] == {k: facts.get(k) for k in FINGERPRINT_KEYS} for fp in fps)


def _seed(db_path: Path, gid: str, mock: dict) -> None:
    """The live state.db of BUG-104 (Bugs/evidence/BUG-104/live_state_db_readonly_queries.txt): ids 1 and 4 are the
    fixture, the others real Y116/Y118 rows of the same game."""
    real116 = {**mock, "date": "26. Opal, Jahr 116", "pop": 176, "drink_days": 62, "jobs_open": 237, "wealth": 900000}
    real118 = {**mock, "date": "27. Granite, Jahr 118", "pop": 174, "drink_days": 49, "jobs_open": 101,
               "wealth": 950000}
    t0 = 1_790_840_000.0
    rows = [(t0, mock), (t0 + 13, real116), (t0 + 23, real116), (t0 + 1304, mock), (t0 + 13564, real118)]
    st = Store(":memory:")
    st.db.execute(f"ATTACH DATABASE '{db_path}' AS live")
    st.db.executescript("CREATE TABLE IF NOT EXISTS live.snapshots (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, "
                        "game_id TEXT, facts TEXT); CREATE TABLE IF NOT EXISTS live.kpis (id INTEGER PRIMARY KEY "
                        "AUTOINCREMENT, ts REAL, game_date TEXT, name TEXT, value REAL);")
    for ts, f in rows:
        st.db.execute("INSERT INTO live.snapshots(ts, game_id, facts) VALUES(?,?,?)", (ts, gid, json.dumps(f)))
        for k in ("pop", "drink_days"):
            st.db.execute("INSERT INTO live.kpis(ts, game_date, name, value) VALUES(?,?,?,?)",
                          (ts + 0.002, f["date"], k, f[k]))      # own clock reading right after the snapshot
    st.close()


def test_bug104_live_db_mock_rows_removed_real_rows_kept(tmp_path):
    gid, mock = _fixture_facts()
    db = tmp_path / "data" / "state.db"
    db.parent.mkdir()
    _seed(db, gid, mock)
    st = Store(db)                                   # opening the live db runs the cleanup
    assert st.purged == {"snapshots": 2, "kpis": 4}
    dates = [s["facts"]["date"] for s in st.snapshots()]
    assert dates == ["26. Opal, Jahr 116"] * 2 + ["27. Granite, Jahr 118"]
    assert {r[0] for r in st.db.execute("SELECT game_date FROM kpis")} == {"26. Opal, Jahr 116", "27. Granite, Jahr 118"}
    assert st.get("migration.mock_rows_purged") == {"snapshots": 2, "kpis": 4}
    st.close()
    st2 = Store(db)                                  # idempotent
    assert st2.purged == {"snapshots": 0, "kpis": 0} and len(st2.snapshots()) == 3


def test_bug104_real_snapshot_at_the_fixture_moment_is_kept(tmp_path):
    """A real row with the fixture's facts but a consistent time line (the fort was really at Y102 then) stays."""
    gid, mock = _fixture_facts()
    db = tmp_path / "state.db"
    st = Store(db)
    st.add_snapshot(1_000.0, gid, mock)
    st.add_snapshot(1_000.0 + 86400 * 3, gid, {**mock, "date": "26. Opal, Jahr 116"})    # 14 years in 3 real days
    st.add_snapshot(5_000.0, "Other|1|2", {**mock, "fort": "Other"})                      # other game: untouched
    st.close()
    st = Store(db)
    assert st.purged["snapshots"] == 0 and len(st.snapshots()) == 3


def test_bug104_no_cleanup_in_mock_db_or_mock_run(tmp_path, monkeypatch):
    from df_llm_helper import config as C
    gid, mock = _fixture_facts()
    monkeypatch.setattr(C, "RUNTIME", tmp_path / "rt")
    mdb = tmp_path / "rt" / "mock" / "state.db"
    mdb.parent.mkdir(parents=True)
    _seed(mdb, gid, mock)
    assert Store(mdb).purged["snapshots"] == 0       # the isolated mock db keeps its fixture rows
    live = tmp_path / "live.db"
    _seed(live, gid, mock)
    monkeypatch.setattr(C, "_FORCED", {"paths": {}})  # during a --mock run nothing is deleted
    assert Store(live).purged["snapshots"] == 0
    monkeypatch.setattr(C, "_FORCED", {})
    assert Store(live).purged["snapshots"] == 2


# ---------------------------------------------------------------- BUG-220 mood minima, block/mechanism stock
def _mood_live() -> str:
    for ln in (EVID / "BUG-220" / "l_mood_res.jsonl").read_text(encoding="utf-8").splitlines():
        d = json.loads(ln)
        if d.get("cmd") == "claude/mood status":
            return d["stdout"]
    raise AssertionError("no claude/mood status in the evidence")


def test_bug220_mood_reserve_uses_claude_mood_minimum(tmp_path):
    from df_llm_helper.moods import MoodManager
    from df_llm_helper.toolsfs import ToolsDir
    clk = FakeClock(1_790_840_000.0)
    status = json.dumps({"population": {"total": 174}})
    m = MockClient({"claude/mood status": _mood_live(), "claude/status": status}, clock=clk)
    mm = MoodManager(m, ToolsDir(tmp_path, clk), Store(), clk, DEFAULTS["mood"])
    out = mm.reserve(dry=True)
    assert out == ["Mood reserve missing: rough gems 6/12 (minima: claude/mood minimum)"]     # same gap as the game
    # unreadable claude/mood answer without 'minimum' -> config fallback with the raised defaults
    j = json.loads(_mood_live())
    j.pop("minimum")
    m.set("claude/mood status", json.dumps(j))
    assert mm.reserve(dry=True) == ["Mood reserve missing: rough gems 6/12 (minima: config mood.reserves)"]
    assert DEFAULTS["mood"]["reserves"]["rough_gems"] == 12 and DEFAULTS["mood"]["reserves"]["cut_gems"] == 10
    assert DEFAULTS["mood"]["reserves"]["wood"] == 14


def test_bug220_bottleneck_block_and_mechanism_have_a_stock_source():
    from df_llm_helper.bottleneck import DEFAULTS as BD, BottleneckWatch
    clk = FakeClock(0)
    mat = json.dumps({"stock": {"wood": 177, "coke": 12, "coal": 697, "bars": {"IRON": 32}, "chain": 3,
                                "bucket": 4, "have": {"WEAPON:ITEM_WEAPON_PICK": 20}}})
    m = MockClient({"claude/material status": mat,
                    "claude/pilot_defense status": json.dumps({"ok": True, "stock": {"mechanisms": 65}}),
                    "claude/muell status": json.dumps({"lose_stapel": 900, "typen": "BOULDER=300 BLOCKS=482"})},
                   clock=clk)
    bw = BottleneckWatch(m, Store(), clk, BD, HOME)
    st = bw.stock()
    assert st["mechanism"] == 65 and st["blocks"] == 482
    out = bw.run(dry=True)
    assert out[0] == "No bottleneck in the production chains" and not any("no stock data" in ln for ln in out)
    # claude/material status reporting the keys itself wins; unknown sources stay 'unknown' (never 0)
    m.set("claude/material status", json.dumps({"stock": {**json.loads(mat)["stock"], "mechanism": 2, "blocks": 7}}))
    m.calls.clear()
    st2 = bw.stock()
    assert st2["mechanism"] == 2 and st2["blocks"] == 7 and m.calls == ["claude/material status"]
    m2 = MockClient({"claude/material status": mat,
                     "claude/pilot_defense status": json.dumps({"ok": True, "stock": {"mechanisms": -1}}),
                     "claude/muell status": json.dumps({"typen": "BOULDER=300"})}, clock=clk)
    out2 = BottleneckWatch(m2, Store(), clk, BD, HOME).run(dry=True)
    assert any(ln.startswith("no stock data: block, mechanism") for ln in out2)


# ---------------------------------------------------------------- BUG-319 deathcause/gaydar, message text
def test_bug319_read_only_commands_and_message_text_not_reported():
    from df_llm_helper.fairplay import FairPlayError, check_command
    from df_llm_helper.lint import lint_paths, lint_source
    ins = EVID / "BUG-319" / "inputs"
    assert lint_paths([ins]) == []
    for ok in ("dfhack.run_command('deathcause')", "dfhack.run_command('gaydar')", "print('do not use createitem')",
               "qerror('createitem is forbidden')", "dfhack.printerr(\"no createitem\")",
               "util.emit({error = 'createitem not allowed'})", "-- createitem in a comment"):
        assert lint_source(ok) == [], ok
    for bad in ("dfhack.run_command('createitem', 'X')", "print(dfhack.run_command_silent('createitem x'))",
                "local c = 'createitem X'", "createitem WEAPON:ITEM_WEAPON_PICK", "os.execute('createitem')",
                "say('x') dfhack.run_script('createitem')", "print(load('createitem'))"):
        assert [f.rule for f in lint_source(bad)] == ["L01"], bad
    assert [f.rule for f in lint_source("dfhack.run_command('fastdwarf', '1')")] == ["L25"]
    check_command("deathcause")                       # runtime gate: read-only, allowed
    check_command("gaydar")
    with pytest.raises(FairPlayError):
        check_command("fastdwarf 1")


# ---------------------------------------------------------------- BUG-418 local consent register for lint
def test_bug418_lint_honours_local_fp09_consent(tmp_path, capsys):
    from df_llm_helper.cli import main
    from df_llm_helper.fairplay import ExceptionRegistry
    from df_llm_helper.lint import lint_paths
    lua = HOME / "lua" / "pilot_caravan.lua"
    shared = tmp_path / "exceptions.jsonl"
    shutil_copy = (HOME / "data" / "exceptions.jsonl").read_text(encoding="utf-8")
    shared.write_text(shutil_copy, encoding="utf-8")
    fs = [f for f in lint_paths([lua], ExceptionRegistry(shared)) if f.rule == "L07"]
    assert len(fs) == 1 and "data/exceptions.local.jsonl" in fs[0].reason and "--local" in fs[0].reason
    cfg = tmp_path / "c.yaml"
    cfg.write_text(f"paths:\n  exceptions: '{shared}'\n  state_db: '{tmp_path / 's.db'}'\n"
                   f"  tools: '{tmp_path / 't'}'\n  scopes: '{tmp_path / 't' / 'scopes'}'\n", encoding="utf-8")
    assert main(["--config", str(cfg), "exception", "add", "FP09", "--local", "--reason", "stuck merchants",
                 "--ja", "yes, always send stuck traders home"]) == 0
    assert "exceptions.local.jsonl" in capsys.readouterr().out
    assert shared.read_text(encoding="utf-8") == shutil_copy            # the shipped register is unchanged
    reg = ExceptionRegistry(shared)
    assert reg.local_path.is_file() and reg.allows("FP09")
    assert [f for f in lint_paths([lua], reg) if f.rule == "L07"] == []


# ---------------------------------------------------------------- BUG-421 stall log, 2 timeouts = failure
def _fake_exe(tmp_path: Path, sleep: float) -> Path:
    if sys.platform.startswith("win"):
        pytest.skip("shell script stand-in for dfhack-run")
    exe = tmp_path / "dfhack-run"
    exe.write_text(f"#!/bin/sh\nsleep {sleep}\necho 42\n", encoding="utf-8")
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    return exe


def test_bug421_slow_calls_go_to_the_stall_log(tmp_path, monkeypatch):
    from df_llm_helper import stalllog
    monkeypatch.setattr(stalllog, "STALL_S", 0.05)
    log = tmp_path / "out" / "stall.log"
    c = RealClient(_fake_exe(tmp_path, 0.2), stall_log=log)
    assert c.run("claude/mil").ok
    r = c.run("claude/mil guard", timeout=0.05)
    assert r.timed_out
    rows = stalllog.read_stalls(log)
    assert [(s, cmd) for _, _, s, cmd in rows] == [("ok", "claude/mil"), ("timeout", "claude/mil guard")]
    assert rows[0][1] >= 0.2


def test_bug421_stall_period_and_rotation(tmp_path):
    from df_llm_helper import stalllog
    log = tmp_path / "stall.log"
    t = 1_790_840_000.0
    for i in range(6):                     # a stall every 600 s; two queued calls in the same stall count once
        stalllog.append_stall(log, t + 600 * i, 8.5, "claude/mil")
        stalllog.append_stall(log, t + 600 * i + 2, 6.0, "claude/alert")
    s = stalllog.stall_stats(log)
    assert s["stalls"] == 6 and s["calls"] == 12 and s["period_s"] == 600 and s["max_s"] == 8.5
    assert "stall period: median interval 600 s" in stalllog.stall_line(log)
    stalllog.append_stall(log, t + 9999, 4.0, "x", max_bytes=10)          # rotation at the size limit
    assert (tmp_path / "stall.log.1").is_file() and len(log.read_text(encoding="utf-8").splitlines()) == 1
    assert stalllog.stall_stats(log)["calls"] == 13                         # both generations are read
    assert "no dfhack-run call" in stalllog.stall_line(tmp_path / "none.log")


def test_bug421_one_timeout_is_no_watcher_failure(tmp_path):
    from df_llm_helper.toolsfs import ToolsDir
    from df_llm_helper.waechter import CLEAR_CMD, FOOD_CMD, Waechter
    clk = FakeClock(1_790_840_000.0)
    tools = ToolsDir(tmp_path, clk)
    tools.set_last_report_id(90)
    tools.touch_heartbeat()
    slow = Result(ok=False, stdout="", stderr="Timeout after 40.0s: x", elapsed_s=40.0)
    answers = [slow, "100", slow, slow]
    m = MockClient({MAX_REPORT_ID_CMD: lambda c: answers.pop(0), FOOD_CMD: "S 50 0 10 100 20",
                    CLEAR_CMD: "R 0 dwarfmode/Default"}, clock=clk)
    m.prefix_handlers.append(('lua "local last=', lambda c: ""))
    w = Waechter(m, tools, clk, Store(), DEFAULTS)
    out = w.step()                                                   # 1st timeout: skipped, alive
    assert "timed out (1/2)" in out[0] and (tmp_path / "out" / "waechter.alive").exists()
    w.step()                                                         # answer again: counter reset
    assert w.timeouts == 0
    w.step()                                                         # 1 timeout
    with pytest.raises(RuntimeError):                                # 2 consecutive timeouts: failure
        w.step()
