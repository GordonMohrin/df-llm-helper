"""F14 anomalies, F15 trade automaton, F16 status overlay."""
import json
import random

import pytest

from conftest import FIX
from df_llm_helper.anomaly import (CancelLoop, Detector, GamelogReader, cancel_anomalies, cancel_loops, detect_series, ewma,
                             mad, series_anomalies)
from df_llm_helper.client import MockClient
from df_llm_helper.kb import KB
from df_llm_helper.overlay import overlay_lines, overlay_send
from df_llm_helper.store import Store
from df_llm_helper.trade_flow import ALLOWED, FOCUS_TRADE, TradeFlow, TradeObs, obs_from_status
from helpers import ROOT

GAMELOG = (FIX / "logs" / "gamelog_selected.txt").read_bytes().decode("cp437").splitlines()
KB_ALL = KB.load_dir(ROOT / "data" / "kb")


# ---------------------------------------------------------------- F14
def test_top3_cancel_loops_from_real_gamelog():
    top = cancel_loops(GAMELOG, min_count=3, top=3)
    assert [(c.job, c.reason, c.count) for c in top] == [
        ("Make bed", "Needs logs", 314), ("Give water", "No water source", 61),
        ("Plant seeds", "Needs plump helmet spawn", 9)]
    assert top[0].who == 21


def test_every_anomaly_has_kb_hint():
    hint = lambda q: (KB_ALL.search(q, k=1)[0].entry.id if KB_ALL.search(q, k=1) else "")  # noqa: E731
    an = cancel_anomalies(cancel_loops(GAMELOG, min_count=3, top=3), hint=hint)
    assert [a.hint for a in an] == ["bett_ohne_holz", "wasser_quelle", "getraenke_wueste"]
    hist = [{"drink_days": 100 + (i % 3)} for i in range(30)] + [{"drink_days": 60}]
    sa = series_anomalies(hist, hint=hint)
    assert len(sa) == 1 and sa[0].series == "drink_days" and sa[0].kind == "fall" and sa[0].hint


def test_false_alarm_rate_stable_series():
    rng = random.Random(42)
    total = 0
    for name, base, sd in (("drink_days", 120, 3), ("idle_pct", 20, 2), ("food_days", 150, 5)):
        vals = [base + rng.gauss(0, sd) for _ in range(1000)]
        total += len(detect_series(name, vals, window=20, k=6.0))
    assert total <= 3            # <= 1 per 1000 points per series


def test_detects_real_changes():
    vals = [100.0] * 25 + [100, 99, 101, 100, 40]
    assert [a.kind for a in detect_series("d", vals, "fall", window=20, k=5, min_abs=10)] == ["fall"]
    assert detect_series("d", vals, "rise", window=20, k=5) == []
    vals2 = [10.0 + (i % 2) for i in range(25)] + [60.0]
    assert detect_series("i", vals2, "rise", window=20, k=5)[0].value == 60.0
    assert series_anomalies([{"drink_days": 5}] * 3) == []


def test_stats_helpers_and_reader(tmp_path):
    assert ewma([1, 1, 4], alpha=0.5) == [1, 1, 2.5]
    assert mad([]) == (0.0, 0.0) and mad([1, 2, 3, 4])[0] == 2.5 and mad([1, 2, 3])[0] == 2
    st = Store()
    gl = tmp_path / "gamelog.txt"
    gl.write_bytes("A cancels Make rock bed: Needs logs.\n".encode("cp437") * 3)
    r = GamelogReader(gl, st)
    assert len(r.new_lines()) == 3 and r.new_lines() == []
    gl.write_bytes(b"new cancels Eat: Could not find path.\n")           # file new (shorter)
    assert r.new_lines() == ["new cancels Eat: Could not find path."]
    assert len(r.recent()) == 4
    assert cancel_loops(r.recent(), min_count=3)[0].job == "Make bed"
    assert GamelogReader(None, st).new_lines() == []
    big = tmp_path / "big.txt"
    big.write_text("x\n" * 1000)
    assert len(GamelogReader(big, Store()).new_lines(max_bytes=100)) == 50


# ---------------------------------------------------------------- F15
def ok_obs(**kw):
    base = dict(caravan_state="AtDepot", broker_in_depot=False, broker_job="TradeAtDepot", focus="dwarfmode/Default",
                trade_open=False, stable_s=0, paused=True, last_ok=True, plan_ok=True)
    base.update(kw)
    return TradeObs(**base)


def run_happy(flow, approve=True, steps=30):
    """Small world simulator: the world reacts to the commands like the real game (simplified)."""
    world = {"paused": False, "broker": False, "open": False}
    cmds, t = [], 0.0
    for _ in range(steps):
        if approve and flow.state == "REVIEW":
            flow.approve()
        o = ok_obs(paused=world["paused"], broker_in_depot=world["broker"], trade_open=world["open"],
                   focus=FOCUS_TRADE if world["open"] else "dwarfmode/Default", stable_s=3 if world["open"] else 0)
        out = flow.step(o, t)
        cmds += out
        for c in out:
            if c == "claude/advance 0":
                world["paused"] = True
            elif c == "claude/handel broker --live --force-job":
                world["broker"] = True
            elif c == "claude/handel open --live":
                world["open"] = True
            elif c == "claude/handel finish --live":
                world["open"] = False
        t += 5
        if flow.state in ("DONE", "ABORT", "FAILED"):
            break
    return cmds


def test_trade_happy_path():
    f = TradeFlow()
    cmds = run_happy(f)
    assert f.state == "DONE", f.log
    assert cmds == ["claude/advance 0", "quicksave", "claude/handel prep --live",
                    "claude/handel broker --live --force-job", "claude/handel plan", "claude/handel mark --live",
                    "claude/handel open --live", "claude/handel select --dry", "claude/handel select --live",
                    "claude/handel confirm --live", "claude/handel accept --live", "claude/handel finish --live",
                    "claude/handel release --live", "claude/advance run"]


def test_trade_waits_for_approval():
    f = TradeFlow()
    cmds = run_happy(f, approve=False)
    assert f.state == "REVIEW" and "claude/handel select --live" not in cmds


def test_trade_window_not_open_aborts_with_rollback():
    f = TradeFlow(state="OPEN")
    cmds = []
    for i in range(4):
        cmds += f.step(ok_obs(broker_in_depot=True), float(i))
    assert f.state == "ABORT" and f.abort_reason == "window not open"
    assert cmds[-2:] == ["claude/handel release --live", "claude/advance run"]
    assert cmds.count("claude/handel open --live") == 2


def test_trade_broker_loses_job_then_timeout():
    f = TradeFlow(state="BROKER", since=0)
    assert f.step(ok_obs(broker_job="DetailFloor"), 10) == ["claude/handel broker --live --force-job"]
    assert f.step(ok_obs(broker_job="DetailFloor"), 20) == ["claude/handel broker --live --force-job"]
    assert f.step(ok_obs(broker_job="DetailFloor"), 30) == []
    cmds = f.step(ok_obs(broker_job="DetailFloor"), 400)
    assert f.state == "ABORT" and "timeout in BROKER" in f.abort_reason and "claude/advance run" in cmds


@pytest.mark.parametrize("state", ["BROKER", "MARK", "OPEN", "SELECT_DRY", "REVIEW", "SELECT_LIVE", "CONFIRM"])
def test_trade_caravan_leaves_aborts(state):
    f = TradeFlow(state=state, since=0)
    cmds = f.step(ok_obs(caravan_state="Leaving", trade_open=True, focus=FOCUS_TRADE, stable_s=3), 1)
    assert f.state == "ABORT" and f.abort_reason == "caravan is leaving"
    assert cmds[0] == "claude/handel abort --live" and cmds[-1] == "claude/advance run"


def test_trade_other_failures():
    f = TradeFlow(state="PAUSE")
    for i in range(3):
        assert f.step(ok_obs(paused=False), i) == ["claude/advance 0"]
    assert f.step(ok_obs(paused=False), 4) == [] and f.state == "FAILED"
    f = TradeFlow(state="SAVE")
    assert f.step(ok_obs(last_ok=False), 1) == [] and f.state == "FAILED"
    f = TradeFlow(state="SELECT_DRY")
    f.step(ok_obs(trade_open=True, focus=FOCUS_TRADE, stable_s=3, plan_ok=False), 1)
    assert f.state == "ABORT" and "implausible" in f.abort_reason
    f = TradeFlow(state="REVIEW")
    f.approve()
    f.step(ok_obs(trade_open=True, focus="dwarfmode/Default", stable_s=3), 1)
    assert f.state == "ABORT" and f.abort_reason == "focus lost"
    f = TradeFlow(state="SELECT_LIVE")
    f.step(ok_obs(trade_open=True, focus=FOCUS_TRADE, stable_s=3, last_ok=False), 1)
    assert f.state == "ABORT"
    f = TradeFlow(state="CONFIRM")
    f.step(ok_obs(last_ok=False), 1)
    assert f.state == "ABORT"
    f = TradeFlow(state="OPEN")
    assert f.step(ok_obs(trade_open=True, focus=FOCUS_TRADE, stable_s=1), 1) == []     # wait until stable
    assert TradeFlow().step(ok_obs(caravan_state="Approaching"), 0) == []
    assert TradeFlow(state="DONE").step(ok_obs(), 0) == []
    f = TradeFlow(state="SELECT_DRY")
    f.step(ok_obs(trade_open=False), 1)
    assert f.state == "ABORT"


@pytest.mark.parametrize("seed", range(200))
def test_trade_property_no_action_in_wrong_state(seed):
    rng = random.Random(seed)
    f = TradeFlow()
    t = 0.0
    for _ in range(40):
        o = TradeObs(caravan_state=rng.choice(["AtDepot", "AtDepot", "AtDepot", "Approaching", "Leaving", None]),
                     broker_in_depot=rng.random() < 0.5, broker_job=rng.choice(["TradeAtDepot", "DetailFloor", None]),
                     focus=rng.choice([FOCUS_TRADE, "dwarfmode/Default", "dwarfmode/Trade/Other"]),
                     trade_open=rng.random() < 0.6, stable_s=rng.choice([0, 1, 2, 5]), paused=rng.random() < 0.7,
                     last_ok=rng.random() < 0.9, plan_ok=rng.choice([True, True, False, None]))
        if rng.random() < 0.3:
            f.approve()
        before = f.state
        ui_ok = o.trade_open and o.focus == FOCUS_TRADE and o.stable_s >= 2
        cmds = f.step(o, t)
        t += rng.choice([1, 5, 30, 400])
        allowed = ALLOWED.get(f.state, set()) | ALLOWED.get(before, set())
        for c in cmds:
            assert c in allowed, (before, f.state, c)
            if c in ("claude/handel select --live", "claude/handel confirm --live", "claude/handel accept --live"):
                assert ui_ok or before == "SELECT_LIVE"
            if c == "claude/handel select --live":
                assert f.approved and ui_ok
        if f.state in ("DONE", "ABORT", "FAILED"):
            break


def test_obs_from_real_status():
    j = json.loads((FIX / "handel_status.txt").read_text())
    o = obs_from_status(j)
    assert o.caravan_state == "Approaching" and not o.broker_in_depot and o.broker_job == "DetailFloor"
    assert o.focus == "dwarfmode/Default" and not o.trade_open
    assert obs_from_status({}).caravan_state is None


# ---------------------------------------------------------------- F16
DIGEST = ("Status Y102 Hematite 12 | Pop 24\n!! Hunger>40k: Tekkud414=47k, Eral3473=40k\n"
          "!! [guard] DEADMAN: no heartbeat for 480 min " + "x" * 200 + "\n! Caravan Muboomon: Approaching\n"
          "! fourth line\n> inbox")


def test_overlay_lines_limits():
    lines = overlay_lines(DIGEST)
    assert len(lines) == 3 and all(len(x) <= 120 for x in lines)
    assert lines[0].startswith("Hunger") and lines[1].startswith("DEADMAN") and lines[2].startswith("Caravan")
    assert overlay_lines("No change since 10:00.") == []          # BUG-101: no 'No change' text for the player
    assert overlay_lines("Status Y1 | Pop 7\n> x") == ["Status Y1 | Pop 7"]


def test_overlay_no_duplicate_within_10_min():
    st = Store()
    mc = MockClient({})
    sent = overlay_send(["Caravan here", 'Enemy "Goblin"'], st, mc, 1000.0)
    assert sent == ['claude/schau say "Caravan here" 3', 'claude/schau say "Enemy "Goblin"" 3'] or len(sent) == 2
    assert overlay_send(["Caravan here"], st, mc, 1000.0 + 9 * 60) == []
    assert overlay_send(["Caravan here"], st, mc, 1000.0 + 11 * 60) == ['claude/schau say "Caravan here" 3']
    assert len(mc.calls) == 3
    dry = overlay_send(["new"], st, mc, 5000.0, dry_run=True)
    assert dry and len(mc.calls) == 3


# ---------------------------------------------------------------- CLI F15/F16 + trend in the pilot
from df_llm_helper.cli import main  # noqa: E402


@pytest.fixture
def cfg3(tmp_path, tools_dir):
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  exceptions: {tmp_path / 'ex.jsonl'}\n  gamelog: {tmp_path / 'gl.txt'}\n", encoding="utf-8")
    return str(c)


def test_cli_overlay_and_trade(cfg3, capsys):
    base = ["--config", cfg3, "--mock", str(FIX)]
    assert main(base + ["overlay"]) == 0
    out = capsys.readouterr().out
    assert out.startswith('claude/schau say "Hunger')
    assert main(base + ["overlay", "--send"]) == 0
    capsys.readouterr()
    main(base + ["overlay", "--send"])
    assert "nothing new" in capsys.readouterr().out
    assert main(base + ["trade", "status"]) == 0 and "State IDLE" in capsys.readouterr().out
    assert main(base + ["trade", "step", "--dry-run"]) == 0
    assert "State now: IDLE" in capsys.readouterr().out          # caravan still 'Approaching'
    assert main(base + ["trade", "approve"]) == 2                  # BUG-201: nothing in REVIEW -> refused
    assert "Refused: no trade waits for an approval" in capsys.readouterr().out
    main(base + ["trade", "reset"])
    assert "reset" in capsys.readouterr().out


def test_pilot_trend_warning_in_digest(cfg, clock):
    from df_llm_helper.pilot import Pilot
    from make_fixtures import responses
    from df_llm_helper.client import MockClient
    p = Pilot(cfg, MockClient(responses(drink_days=120)), store=Store(), clock=clock)
    for i in range(14):
        p.client.set("claude/status", responses(drink_days=120 + (i % 2))["claude/status"])
        p.digest()
        clock.advance(60)
    p.client.set("claude/status", responses(drink_days=55)["claude/status"])
    d = p.digest()
    assert "drink_days falls unusually: 55" in d and "kb " in d
