"""Live trade findings of 2026-10-02/03: BUG-223 (trade pause needs pause.hold), BUG-224 (stale pause.hold, Squads
window freezes the game), BUG-225 (OPEN during an alarm), BUG-226 (Python side: Lua errors reach the orchestrator)."""
import json

from conftest import set_age
from df_llm_helper import holds
from df_llm_helper.caravan import CaravanPilot
from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import DEFAULTS
from df_llm_helper.guard import GuardRunner
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.trade_flow import (BLOCKED_MAX_S, FOCUS_TRADE, HOLD_CMD, RELEASE_CMD, TradeFlow, TradeObs,
                                      blocker)
from df_llm_helper.waechter import CARAVANS_CMD, CLEAR_CMD, FOOD_CMD, SQUADS_CLOSE_CMD, Waechter
from helpers import ROOT


# ---------------------------------------------------------------- BUG-223: the trade owns a pause.hold
class GuardedGame:
    """Fake game with the fort's pause guard: without pause.hold a pause is lifted, with a hold a running game is
    paused again (both directions, as observed live)."""

    def __init__(self, tools):
        self.tools = tools
        self.paused, self.broker, self.open = False, False, False

    def apply(self, cmd):
        if cmd.startswith("HELPER "):
            assert holds.run_helper(cmd, self.tools)[0]
        elif cmd == "claude/advance 0":
            self.paused = True
        elif cmd == "claude/advance run":
            self.paused = False
        elif cmd.startswith("claude/handel broker"):
            self.broker = True
        elif cmd == "claude/handel open --live":
            self.open = True
        elif cmd == "claude/handel finish --live":
            self.open = False

    def guard(self):
        self.paused = self.tools.flag("pause.hold").exists

    def obs(self):
        return TradeObs(caravan_state="AtDepot", broker_in_depot=self.broker, broker_job="TradeAtDepot",
                        focus=FOCUS_TRADE if self.open else "dwarfmode/Default", trade_open=self.open,
                        stable_s=3 if self.open else 0, paused=self.paused, haul_pending=0 if self.paused is False
                        else None, plan_ok=True)


def test_bug223_trade_passes_pause_with_a_pause_guard_and_runs_while_hauling(tmp_path):
    tools = ToolsDir(tmp_path, FakeClock(0))
    g = GuardedGame(tools)
    f = TradeFlow()
    seen, t = [], 0.0
    for _ in range(40):
        if f.state == "REVIEW":
            f.approve()
        o = g.obs()
        if f.state == "MARK":
            o.haul_pending = 0
        for c in f.step(o, t):
            g.apply(c)
        g.guard()                                           # the fort's pause guard acts between two steps
        seen.append((f.state, g.paused, tools.flag("pause.hold").exists))
        t += 8
        if f.state in ("DONE", "ABORT", "FAILED"):
            break
    assert f.state == "DONE", f.log
    states = {s for s, _, _ in seen}
    assert "FAILED" not in states
    assert all(paused for s, paused, _ in seen if s == "SAVE")          # PAUSE held (hold written)
    assert not any(paused for s, paused, _ in seen if s in ("BROKER", "MARK"))   # broker/haulers can walk
    assert not tools.flag("pause.hold").exists and not g.paused          # nothing left behind


def test_bug223_failed_names_what_was_tried_and_releases_the_hold(tmp_path):
    tools = ToolsDir(tmp_path, FakeClock(0))
    f = TradeFlow(state="PAUSE")
    cmds = []
    for i in range(5):
        cmds += f.step(TradeObs(caravan_state="AtDepot", paused=False), float(i))
    assert f.state == "FAILED" and "pause.hold 'trade' written" in f.abort_reason
    assert cmds.count(HOLD_CMD) == 3 and cmds[-1] == RELEASE_CMD
    for c in cmds:
        holds.run_helper(c, tools)
    assert not tools.flag("pause.hold").exists


def test_bug223_release_never_lifts_an_alarm_hold(tmp_path):
    tools = ToolsDir(tmp_path, FakeClock(0))
    tools.write_flag("pause.hold", "alarm")
    assert holds.run_helper(HOLD_CMD, tools) == (True, "pause.hold 'alarm'")     # trade does not weaken it
    ok, txt = holds.run_helper(RELEASE_CMD, tools)
    assert ok and "kept" in txt and tools.flag("pause.hold").text == "alarm"
    tools.write_flag("pause.hold", "karawane")
    assert holds.run_helper(RELEASE_CMD, tools)[1] == "pause.hold deleted"
    assert holds.run_helper("HELPER nonsense", tools)[0] is False


def test_bug223_cli_trade_step_writes_the_hold_and_reset_removes_it(tmp_path, tools_dir, capsys):
    import shutil
    from conftest import FIX
    from df_llm_helper.cli import main
    fx = tmp_path / "fx"
    shutil.copytree(FIX, fx)
    shutil.copy(ROOT / "fixtures" / "run5_live" / "handel_status_atdepot_open.json", fx / "handel_status.txt")
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(fx), "trade", "step"]) == 0
    out = capsys.readouterr().out
    assert "ok   HELPER hold trade (pause.hold 'trade')" in out and "State now: PAUSE" in out
    assert (tools_dir / "pause.hold").read_text() == "trade"
    assert main(["--config", str(c), "--mock", str(fx), "trade", "reset"]) == 0
    assert "pause.hold of the trade deleted" in capsys.readouterr().out
    assert not (tools_dir / "pause.hold").exists()


# ---------------------------------------------------------------- BUG-224: stale holds
def test_bug224_stale_hold_rules(tmp_path):
    clock = FakeClock(10_000)
    tools = ToolsDir(tmp_path, clock)
    store = Store()
    assert holds.stale_hold(tools, store) is None                       # no hold
    tools.write_flag("pause.hold", "alarm")
    set_age(tools.flag_path("pause.hold"), clock, 16)
    h = holds.stale_hold(tools, store)
    assert h is not None and h.reason == "alarm"
    assert holds.stale_text(h, True) == ('pause.hold stale (age 16 min, reason "alarm", no active danger) - game is '
                                         'frozen; delete tools/pause.hold if nothing needs the pause')
    assert holds.stale_hold(tools, store, danger=True) is None          # snapshot danger
    tools.write_flag("alert", "berserk")                                 # fresh alert = danger still active
    assert holds.stale_hold(tools, store) is None
    set_age(tools.flag_path("alert"), clock, 10)
    assert holds.stale_hold(tools, store) is not None
    tools.write_flag("siege", "x")
    assert holds.stale_hold(tools, store) is None
    tools.delete_flag("siege")
    # karawane: protected by a running trade (up to trade_active_max_min), stale without one
    tools.write_flag("pause.hold", "karawane")
    set_age(tools.flag_path("pause.hold"), clock, 15)
    assert holds.stale_hold(tools, store).reason == "karawane"
    store.set("trade.flow", {"state": "OPEN"})
    assert holds.stale_hold(tools, store) is None
    set_age(tools.flag_path("pause.hold"), clock, 61)
    assert holds.stale_hold(tools, store) is not None                   # abandoned trade
    tools.write_flag("pause.hold", "gefahr 12:00:01")
    set_age(tools.flag_path("pause.hold"), clock, 19)
    assert holds.stale_hold(tools, store) is None                        # limit 20 min


def test_handelauto_flag_protects_trade_hold(tmp_path):
    """claude/handelauto (Lua) refreshes handel_aktiv.flag every 20 s: its trade hold is never stale, a danger hold still is."""
    clock = FakeClock(10_000)
    tools = ToolsDir(tmp_path, clock)
    store = Store()
    tools.write_flag("pause.hold", "trade handelauto 14:00:00")
    set_age(tools.flag_path("pause.hold"), clock, 40)
    assert holds.stale_hold(tools, store) is not None                   # no flag: stale
    tools.write_flag("handel_aktiv", "handelauto 14:00:20")
    assert holds.handel_aktiv(tools) and holds.stale_hold(tools, store) is None
    set_age(tools.flag_path("handel_aktiv"), clock, 6)                  # flag older than 5 min: automaton dead
    assert not holds.handel_aktiv(tools) and holds.stale_hold(tools, store) is not None
    tools.write_flag("handel_aktiv", "x")
    tools.write_flag("pause.hold", "alarm")
    set_age(tools.flag_path("pause.hold"), clock, 16)
    assert holds.stale_hold(tools, store) is not None                   # never protects a danger hold


def test_bug224_check_reports_a_stale_hold_once(tmp_path, clock):
    tools = ToolsDir(tmp_path, clock)
    tools.write_flag("pause.hold", "alarm")
    set_age(tools.flag_path("pause.hold"), clock, 15.5)
    store = Store()
    g = GuardRunner(MockClient({}), store, tools, clock, DEFAULTS)
    acts, _, _ = g.cycle(None)
    warns = [a.reason for a in acts if a.kind == "warn" and "pause.hold stale" in a.reason]
    assert warns == ['pause.hold stale (age 15 min, reason "alarm", no active danger) - game is frozen; '
                     'delete tools/pause.hold if nothing needs the pause']
    assert any("pause.hold stale" in w["text"] and w["level"] == "crit" for w in store.peek_warnings())
    acts, _, _ = g.cycle(None)
    assert not any("pause.hold stale" in a.reason for a in acts)        # once per hold
    tools.write_flag("pause.hold", "alarm")                              # a new hold, later stale again
    set_age(tools.flag_path("pause.hold"), clock, 20)
    import os
    os.utime(tools.flag_path("pause.hold"), (clock.now().epoch - 1300, clock.now().epoch - 1300))
    acts, _, _ = g.cycle(None)
    assert any("pause.hold stale" in a.reason for a in acts)


def watcher(tmp_path, clock, clear="R 0 dwarfmode/Default"):
    tools = ToolsDir(tmp_path, clock)
    tools.set_last_report_id(90)
    (tmp_path / "events.log").write_text("", encoding="utf-8")
    tools.touch_heartbeat()
    m = MockClient({MAX_REPORT_ID_CMD: "90", FOOD_CMD: "S 50 0 10 100 20", CLEAR_CMD: clear, CARAVANS_CMD: "1"},
                   clock=clock)
    m.prefix_handlers.append(('lua "local last=', lambda c: ""))
    return Waechter(m, tools, clock, Store(), DEFAULTS), m, tools


def test_bug224_watcher_releases_stale_alarm_and_karawane_holds(tmp_path, clock):
    w, m, tools = watcher(tmp_path, clock, clear="P 0 dwarfmode/Default")
    tools.write_flag("pause.hold", "alarm")
    set_age(tools.flag_path("pause.hold"), clock, 16)
    tools.write_flag("alert", "berserk")
    set_age(tools.flag_path("alert"), clock, 16)
    w.step()
    assert not tools.flag("pause.hold").exists and not tools.flag("alert").exists
    assert "stale pause.hold 'alarm' released after 16 min" in "\n".join(tools.events_lines())
    assert "claude/advance run" in m.calls                                # the game runs again
    w2, m2, tools2 = watcher(tmp_path / "b", clock, clear="P 0 dwarfmode/Default")
    tools2.write_flag("pause.hold", "karawane")
    set_age(tools2.flag_path("pause.hold"), clock, 5)
    w2.step()
    assert tools2.flag("pause.hold").exists and "claude/advance run" not in m2.calls     # still young
    set_age(tools2.flag_path("pause.hold"), clock, 11)
    w2.step()
    assert not tools2.flag("pause.hold").exists                         # caravan can now walk to the depot


def test_bug224_watcher_keeps_alarm_hold_while_danger_is_active(tmp_path, clock):
    w, m, tools = watcher(tmp_path, clock, clear="P 0 dwarfmode/Default")
    tools.write_flag("pause.hold", "alarm")
    set_age(tools.flag_path("pause.hold"), clock, 30)
    tools.write_flag("siege", "goblins")
    w.step()
    assert tools.flag("pause.hold").exists and "claude/advance run" not in m.calls


def test_bug224_watcher_closes_a_squads_window_that_freezes_the_game(tmp_path, clock):
    w, m, tools = watcher(tmp_path, clock, clear="P 0 dwarfmode/Squads/Default fc=500 yt=7")
    m.set(SQUADS_CLOSE_CMD, "dwarfmode/Default")
    for _ in range(20):                                                  # 2 s passes
        w.step()
        clock.advance(2)
    assert m.calls.count(SQUADS_CLOSE_CMD) >= 1 and "claude/advance run" in m.calls
    first = m.calls.index(SQUADS_CLOSE_CMD)
    assert "squads window open (focus dwarfmode/Squads/Default), no pause.hold - closed and resumed" in \
        "\n".join(tools.events_lines())
    assert any("squads window" in x["text"] for x in w.store.peek_warnings())
    # not before holds.squads_close_s (30 s = 15 passes)
    assert sum(1 for c in m.calls[:first] if c == CLEAR_CMD) >= 15


def test_bug224_squads_window_left_alone_during_an_alarm_or_when_time_runs(tmp_path, clock):
    w, m, tools = watcher(tmp_path, clock, clear="P 0 dwarfmode/Squads/Default fc=500 yt=7")
    tools.write_flag("pause.hold", "alarm")
    for _ in range(20):
        w.step()
        clock.advance(2)
    assert SQUADS_CLOSE_CMD not in m.calls
    fc = iter(range(1000, 2000, 7))
    w2, m2, tools2 = watcher(tmp_path / "b", clock)
    m2.set(CLEAR_CMD, lambda c: f"R 0 dwarfmode/Squads/Default fc={next(fc)} yt=7")    # player uses it, time runs
    for _ in range(20):
        w2.step()
        clock.advance(2)
    assert SQUADS_CLOSE_CMD not in m2.calls


# ---------------------------------------------------------------- BUG-225: OPEN waits during an alarm
def _o(**kw):
    base = dict(caravan_state="AtDepot", broker_in_depot=True, broker_job="TradeAtDepot", focus="dwarfmode/Default",
                trade_open=False, stable_s=0, paused=True, haul_pending=0, plan_ok=True)
    base.update(kw)
    return TradeObs(**base)


def test_bug225_open_blocked_by_danger_waits_then_continues():
    f = TradeFlow(state="MARK", since=0.0)
    assert f.step(_o(), 601.0)[-1] == "claude/handel open --live"
    cmds = []
    for i in range(10):                                                  # 10 observations: paused + alert.flag
        cmds += f.step(_o(danger="alert.flag"), 610.0 + 8 * i)
    assert f.state == "OPEN" and cmds == [] and f.note == "blocked: alarm active (alert.flag)"
    assert "OPEN blocked: alarm active (alert.flag)" in f.log
    assert f.step(_o(), 700.0) == [HOLD_CMD, "claude/advance 0", "claude/handel open --live"]   # danger gone
    assert f.state == "OPEN" and f.note == ""
    assert f.step(_o(trade_open=True, focus=FOCUS_TRADE, stable_s=3), 705.0) == ["claude/handel select --dry"]
    assert f.state == "SELECT_DRY"


def test_bug225_blockers_squads_window_and_foreign_focus():
    assert blocker(_o(focus="dwarfmode/Squads/Default")) == "squads window open (focus dwarfmode/Squads/Default)"
    assert blocker(_o(focus="dwarfmode/Info/JUSTICE")) == "focus=dwarfmode/Info/JUSTICE"
    for ok in ("dwarfmode/Default", "dwarfmode/ViewSheets/BUILDING/TradeDepot", FOCUS_TRADE, ""):
        assert blocker(_o(focus=ok)) == ""


def test_bug225_blocked_too_long_aborts_and_reenters_when_free():
    f = TradeFlow(state="OPEN", since=0.0)
    f.step(_o(focus="dwarfmode/Squads/Default"), 1.0)
    cmds = f.step(_o(focus="dwarfmode/Squads/Default"), 2.0 + BLOCKED_MAX_S)
    assert f.state == "ABORT" and f.abort_reason.startswith("blocked for 601 s: squads window open")
    assert "claude/handel abort --live" not in cmds and cmds[-2:] == [RELEASE_CMD, "claude/advance run"]
    assert f.step(_o(focus="dwarfmode/Squads/Default"), 700.0) == [] and f.state == "ABORT"   # still blocked
    assert f.step(_o(), 710.0) == [HOLD_CMD, "claude/advance 0", "claude/handel open --live"]
    assert f.state == "OPEN" and f.reentries == 1 and "re-enter 1/2" in f.log[-1]


def test_bug225_window_not_open_names_the_answer_and_reenters_at_most_twice():
    f = TradeFlow(state="OPEN", since=0.0)
    f.last_answer = "Makler nicht am Depot mit Job TradeAtDepot"
    t = 0.0
    for _ in range(3):
        while f.state == "OPEN":
            f.step(_o(), t)
            t += 8
        assert f.state == "ABORT"
        assert f.abort_reason == "window not open (last answer: Makler nicht am Depot mit Job TradeAtDepot)"
        f.step(_o(), t)
        t += 8
    assert f.state == "ABORT" and f.reentries == 2                      # REENTER_MAX
    g = TradeFlow(state="ABORT", abort_reason="caravan is leaving")
    assert g.step(_o(), 0.0) == [] and g.state == "ABORT"                # other aborts stay terminal


def test_bug225_caravan_pilot_waits_during_alarm_and_reenters(tmp_path):
    clock = FakeClock(0)
    mc = MockClient({}, clock=clock)
    status = {"caravans": [{"name": "Muboomon", "state": "AtDepot", "time_remaining": 3000}],
              "broker": {"in_depot": True, "job": "TradeAtDepot"}, "focus": ["dwarfmode/Default"],
              "trade_ui": {"open": False}, "depots": [{"jobs": []}], "errors": ["stability mark not written: x"]}
    mc.set("claude/handel status", lambda c: json.dumps(status))
    mc.set("claude/advance clock", json.dumps({"paused": True}))
    mc.set("claude/handel open --live", json.dumps({"ok": False, "abort": "unknown focus"}))
    tools = ToolsDir(tmp_path, clock)
    store = Store()
    store.set("caravan.state", {"flow": {"state": "OPEN", "since": 0.0}})
    cp = CaravanPilot(mc, tools, store, clock, {}, ROOT)
    tools.write_flag("pause.hold", "alarm")
    for _ in range(10):
        s, log = cp.step()
        clock.advance(8)
    assert s == "open" and "claude/handel open --live" not in mc.calls
    assert any(r.startswith("blocked: alarm active (pause.hold 'alarm')") for r in cp.report())
    assert any("stability mark not written" in w["text"] for w in store.peek_warnings())   # BUG-226 errors surface
    tools.delete_flag("pause.hold")
    for _ in range(12):
        s, log = cp.step()
        clock.advance(8)
        if s == "abort":
            break
    assert s == "abort" and "last answer: unknown focus" in store.get("caravan.state")["flow"]["abort_reason"]
    assert tools.flag("pause.hold").exists is False                     # the trade's own hold is released
    s, log = cp.step()                                                   # caravan still at the depot: re-enter
    assert s == "open" and "ok HELPER hold trade (pause.hold 'trade')" in log


def test_stale_siege_flag_is_no_danger(tmp_path):
    """Night audit 10.10.2026: a forgotten siege.flag (08.10.) kept every danger hold alive and the Squads/freeze guards off."""
    clock = FakeClock()
    tools = ToolsDir(tmp_path, clock)
    store = Store()
    tools.write_flag("siege", "22:43:52 [CONFLICT_CONVERSATION] ...")
    assert holds.siege_active(tools) and holds.danger_reason(tools) == "siege.flag"
    set_age(tools.flag_path("siege"), clock, 61)
    assert not holds.siege_active(tools) and holds.danger_reason(tools) == ""
    tools.write_flag("pause.hold", "gefahr 12:00:01")
    set_age(tools.flag_path("pause.hold"), clock, 25)
    assert holds.stale_hold(tools, store) is not None                   # stale siege.flag no longer protects the hold
    tools.write_flag("siege_aktiv", "claude/siege start")               # running siege protocol: always danger
    assert holds.siege_active(tools) and holds.stale_hold(tools, store) is None
