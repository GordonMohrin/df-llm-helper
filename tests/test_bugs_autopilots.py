"""Regression tests for the autopilot bug reports Bugs/BUG-200 .. BUG-220 (recorded game answers under fixtures/bugs/)."""
import json

import pytest

from df_llm_helper.cli import main
from df_llm_helper.store import Store
from helpers import ROOT

BUGS = ROOT / "fixtures" / "bugs"


@pytest.fixture
def cfgfile(tmp_path, tools_dir):
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'gamelog.txt'}\n  exceptions: {tmp_path / 'ex.jsonl'}\n", encoding="utf-8")
    return str(c)


def cli(capsys, *args):
    rc = main([str(a) for a in args])
    out = capsys.readouterr()
    return rc, out.out + out.err


def db(tmp_path):
    return Store(tmp_path / "s.db")


# ---------------------------------------------------------------- BUG-200 / 201 / 202 (caravan + trade automaton)

def test_bug200_caravan_done_is_terminal(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-200" / "car_replay.jsonl"]
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0", "--max-steps", "12")
    assert "Caravan: REVIEW" in out
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "Caravan: DONE" in out and out.count("claude/advance run") == 1          # was sent twice
    assert out.count("Trade completed") == 1
    (tools_dir / "pause.hold").write_text("alarm hold")
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "claude/advance run" not in out and out.count("Trade completed") == 1
    assert (tools_dir / "pause.hold").exists()                                       # a foreign hold survives


def test_bug201_trade_approve_reaches_caravan(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-201" / "car_replay_low.jsonl"]
    cli(capsys, *base, "caravan", "--loop", "--interval", "0", "--max-steps", "12")
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "NOT approved: Ratio 1.20 < 2.0" in out and "trade approve" in out
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert out.count("NOT approved") == 1                                            # no pile-up
    rc, out = cli(capsys, *base, "trade", "status")
    assert "Caravan autopilot: REVIEW" in out
    rc, out = cli(capsys, *base, "trade", "approve")
    assert rc == 0 and "approved" in out and "caravan" in out
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "ok claude/handel select --live" in out and "Caravan: DONE" in out
    assert db(tmp_path).get("caravan.state")["flow"]["approved"] is False            # one approval = one trade
    rc, out = cli(capsys, *base, "trade", "approve")
    assert rc == 2 and "Refused" in out


def test_bug202_trade_flow_leaves_done(tmp_path, tools_dir, cfgfile, capsys):
    from dataclasses import asdict

    from df_llm_helper.trade_flow import TradeFlow, TradeObs
    f = TradeFlow(state="DONE", approved=True, log=["RESUME -> DONE"])
    assert f.step(TradeObs(caravan_state="AtDepot"), 10) == [] and f.state == "DONE"
    assert f.step(TradeObs(caravan_state=None), 20) == [] and f.state == "IDLE" and not f.approved and f.log == []
    assert f.step(TradeObs(caravan_state="AtDepot"), 30) == ["claude/advance 0"]   # next caravan is traded
    f2 = TradeFlow(state="FINISH")
    f2.approved = True
    for _ in range(3):
        f2.step(TradeObs(caravan_state="AtDepot"), 40)
    assert f2.state == "DONE" and not f2.approved                                    # no stale approval
    # cli: DONE with the caravan still at the depot says why nothing happens
    db(tmp_path).set("trade.flow", asdict(TradeFlow(state="DONE", log=["RESUME -> DONE"])))
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-200" / "car_replay.jsonl"]
    rc, out = cli(capsys, *base, "trade", "step")
    assert "State now: DONE" in out and "trade reset" in out


# ---------------------------------------------------------------- BUG-203 / BUG-219 (dry runs write nothing; siege errors)

def test_bug203_dry_runs_write_no_warnings(tmp_path, tools_dir, cfgfile, capsys):
    from conftest import FIX
    cli(capsys, "--config", cfgfile, "--mock", FIX, "siege", "--dry-run")
    cli(capsys, "--config", cfgfile, "--mock", FIX, "mood", "reserve", "--dry-run")
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-201" / "car_replay_low.jsonl"]
    for _ in range(3):
        cli(capsys, *base, "caravan", "--dry-run", "--loop", "--interval", "0")
    assert db(tmp_path).take_warnings() == []
    assert not (tools_dir / "notify.flag").exists()


def test_bug203_mood_reserve_real_run_still_warns(tmp_path, tools_dir, cfgfile, capsys):
    from conftest import FIX
    rc, out = cli(capsys, "--config", cfgfile, "--mock", FIX, "mood", "reserve")
    if "missing" in out:                                   # the fixture has gaps -> the real run records them
        assert [w["key"] for w in db(tmp_path).take_warnings()] == ["mood:reserve"]


def test_bug219_unreadable_siege_status_is_an_error_not_an_abort(tmp_path, tools_dir, cfgfile, capsys):
    from conftest import FIX
    rcs = []
    for extra in ([], ["--once"], ["--dry-run"], ["--once", "--dry-run"]):
        rc, out = cli(capsys, "--config", cfgfile, "--mock", FIX, "siege", *extra)
        rcs.append(rc)
        assert "ABORTED" not in out and "ERROR" in out and "not readable" in out
    assert rcs == [2, 2, 2, 2]
    assert db(tmp_path).take_warnings() == [] and not (tools_dir / "notify.flag").exists()


def test_bug219_status_lost_during_siege_still_aborts():
    from df_llm_helper.client import MockClient
    from df_llm_helper.clock import FakeClock
    from df_llm_helper.siege import SiegeRunner, exit_code
    from df_llm_helper.store import Store
    from df_llm_helper.toolsfs import ToolsDir
    import tempfile
    from pathlib import Path
    clock = FakeClock(0)
    mc = MockClient({}, clock=clock)
    answers = iter([json.dumps({"invaders": [{"id": 9, "race": "GOBLIN", "dist": 200}],
                                "squads": [{"id": 33, "name": "Wache", "orders": 0,
                                            "members": [{"id": 1, "alive": True, "blood_pct": 100, "dist": 5}]}]})])
    mc.set("claude/pilot_siege status", lambda c: next(answers, "not json"))
    mc.set("claude/advance clock", '{"paused": true}')
    store = Store()
    tools = ToolsDir(Path(tempfile.mkdtemp()), clock)
    flow, log = SiegeRunner(mc, tools, store, clock, {"poll_s": 0.0, "max_wait_s": 0.0}).run()
    assert flow.state == "ABORT" and exit_code(flow) == 1 and store.take_warnings()
