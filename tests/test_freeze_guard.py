"""Spec v3-04: time-standstill and window guard (df_llm_helper/freeze_guard.py, called by the watcher)."""
import json
import re

import pytest

from conftest import HOME
from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient
from df_llm_helper.config import DEFAULTS
from df_llm_helper.features.freeze_guard_cfg import DEFAULTS as FG_DEFAULTS
from df_llm_helper.freeze_guard import (FocusObs, FreezeCtx, FreezeGuard, focus_classes, leave_cmd, parse_status)
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.waechter import CARAVANS_CMD, CLEAR_CMD, FOOD_CMD, UNPAUSE_RE, Waechter

FIXV3 = HOME / "fixtures" / "v3" / "freeze"
LEAVE_PREFIX = 'lua "local g=require(\'gui\') local f='


class Game:
    """Mock game from a fixtures/v3/freeze scenario: focus stack, pause, frame counter, LEAVESCREEN/SELECT."""

    def __init__(self, spec: dict):
        self.screens = list(spec["screens"])
        self.paused = bool(spec.get("paused"))
        self.fc = int(spec["fc"])
        self.yt = int(spec.get("yt", 0))
        self.moves_with_window = bool(spec.get("time_moves_with_window"))
        self.stuck = bool(spec.get("stuck"))
        self.inputs: list[str] = []

    @property
    def focus(self) -> str:
        return "|".join(self.screens) or "dwarfmode/Default"

    def status(self, _cmd=None) -> str:
        if not self.paused and (not self.screens or self.moves_with_window):
            self.fc += 50
            self.yt += 1
        return f"{'P' if self.paused else 'R'} 0 {self.focus} fc={self.fc} yt={self.yt}"

    def leave(self, cmd: str) -> str:
        key = re.search(r"simulateInput\([^,]+,'(\w+)'\)", cmd).group(1)
        toks = re.findall(r"'([A-Za-z/]+)'", cmd.split("ipairs({", 1)[1].split("})", 1)[0])
        f = self.focus
        hit = any(t in f for t in toks) and ("not f:find('Trade'" not in cmd or "Trade" not in f)
        if hit:
            self.inputs.append(key)
            if not self.stuck and self.screens:
                self.screens.pop()
        return self.focus

    def advance_run(self, _cmd=None) -> str:
        self.paused = False
        return ""


def setup(tmp_path, clock, name: str, cfg: dict | None = None):
    spec = json.loads((FIXV3 / name).read_text(encoding="utf-8"))
    g = Game(spec)
    tools = ToolsDir(tmp_path, clock)
    tools.set_last_report_id(90)
    tools.touch_heartbeat()
    (tmp_path / "events.log").write_text("", encoding="utf-8")
    for fname, text in (spec.get("flags") or {}).items():
        tools.write_flag(fname, text)
    store = Store()
    if spec.get("trade_flow"):
        store.set("trade.flow", {"state": spec["trade_flow"]["state"], "since": clock.now().epoch + 10})
    m = MockClient({MAX_REPORT_ID_CMD: "100", FOOD_CMD: "S 50 0 10 100 20", CARAVANS_CMD: "0",
                    CLEAR_CMD: g.status, "claude/advance run": g.advance_run}, clock=clock)
    m.prefix_handlers.append(('lua "local last=', lambda c: ""))
    m.prefix_handlers.append((LEAVE_PREFIX, g.leave))
    full = {**DEFAULTS, "freeze_guard": {**FG_DEFAULTS, **(cfg or {})}}
    w = Waechter(m, tools, clock, store, full)
    return w, g, m, tools, store


def run(w, clock, n: int) -> list[str]:
    out = []
    for _ in range(n):
        out += w.step()
        clock.advance(2)
    return out


def leaves(m) -> list[str]:
    return [c for c in m.calls if c.startswith(LEAVE_PREFIX)]


# ---- parsing
def test_parse_status_and_classes():
    o = parse_status("R 0 dwarfmode/Info/JUSTICE/OPEN_CASES|dwarfmode/Help fc=12 yt=34")
    assert o == FocusObs(False, 0, "dwarfmode/Info/JUSTICE/OPEN_CASES|dwarfmode/Help", 12, 34)
    assert parse_status("P 2 dwarfmode/Default fc=5").yt is None
    assert parse_status("R 0 dwarfmode/Default") is None            # old output without fc: guard stays idle
    assert focus_classes(o.focus) == ["Help", "Info"]
    assert focus_classes("dfhack/lua/MessageBox") == ["MessageBox"]
    assert focus_classes("dwarfmode/Trade/Default") == ["Trade"]
    assert focus_classes("dwarfmode/Default") == []


def test_unpause_pattern_accepts_trailing_counters():
    assert UNPAUSE_RE.match("P 1 dwarfmode/Default fc=123 yt=4")
    assert UNPAUSE_RE.match("P 1 dwarfmode/Default fc=123")
    assert UNPAUSE_RE.match("P 1 dwarfmode/Default")
    assert not UNPAUSE_RE.match("P 1 dwarfmode/Info/JUSTICE fc=1")
    assert "fc='..df.global.world.frame_counter" in CLEAR_CMD and "cur_year_tick" in CLEAR_CMD


def test_leave_cmd_is_guarded():
    c = leave_cmd("LEAVESCREEN", ["Info", "Help"])
    assert "if hit and not f:find('Trade',1,true) then" in c        # never on Default, never on a trade window
    assert "'Info','Help'" in c
    assert "not f:find('Trade'" not in leave_cmd("SELECT", ["Trade"], allow_trade=True)
    with pytest.raises(ValueError):
        leave_cmd("ESC", ["Info"])


# ---- acceptance criteria
def test_ac1_justice_help_closed_after_6s_and_time_runs(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "justice_help.json")
    t0 = clock.now().epoch
    out = []
    for _ in range(3):                                              # 0 s, 2 s, 4 s: still waiting
        out += w.step()
        clock.advance(2)
    assert not leaves(m) and g.screens
    assert clock.now().epoch - t0 == 6
    out += w.step()                                                 # 6 s: act (2 inputs, 1 s apart)
    assert g.focus == "dwarfmode/Default" and g.inputs == ["LEAVESCREEN", "LEAVESCREEN"]
    assert any("time stood still (dwarfmode/Info/JUSTICE/OPEN_CASES|dwarfmode/Help): screens closed" in ln
               for ln in out)
    fc = g.fc
    clock.advance(2)
    w.step()
    assert g.fc > fc                                                # time runs again
    acts = [a for a in store.actions() if a["rule"] == "freeze_guard"]
    assert acts and acts[-1]["action"] == "close_screens" and acts[-1]["ok"] == 1


def test_ac2_messagebox_after_trade_done(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "messagebox_after_trade.json")
    clock.advance(30)                                               # trade reached DONE after the flags were written
    out = w.step()
    assert not tools.flag("pause.hold").exists and not tools.flag("caravan").exists
    assert g.screens == [] and g.inputs == ["SELECT"]               # OK first
    assert "claude/advance run" in m.calls and g.paused is False
    assert any("trade aftercare" in ln for ln in out)
    assert store.count_actions("freeze_guard", "trade_aftercare", 0) == 1
    assert store.get("freeze_guard.aftercare_since") is not None
    # once per trade: a new caravan with the same finished flow is left alone
    tools.write_flag("caravan", "new caravan")
    tools.write_flag("pause.hold", "karawane")
    run(w, clock, 3)
    assert tools.flag("caravan").exists and tools.flag("pause.hold").exists


def test_ac2_new_caravan_after_restart_is_not_cleared(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "messagebox_after_trade.json")
    clock.advance(60)
    tools.write_flag("caravan", "a NEW caravan arrived after DONE")    # newer than the end of the trade
    tools.write_flag("pause.hold", "karawane")
    w.step()
    assert tools.flag("caravan").exists and tools.flag("pause.hold").exists


@pytest.mark.parametrize("classes", [None, ["Info", "Help", "MessageBox", "ViewSheets", "Trade"]])
def test_ac3_running_trade_window_never_closed(tmp_path, clock, classes):
    w, g, m, tools, store = setup(tmp_path, clock, "trade_select_live.json",
                                  {"classes": classes} if classes else None)
    run(w, clock, 15)
    assert not leaves(m) and g.screens == ["dwarfmode/Trade/Default"]
    assert sum(1 for a in store.actions() if a["action"] == "protected") == 1      # noted once


def test_ac4_player_opens_info_time_runs_no_action(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "player_info_running.json")
    run(w, clock, 20)
    assert not leaves(m) and g.screens and not [a for a in store.actions() if a["rule"] == "freeze_guard"]


def test_ac5_loop_protection_after_3_attempts(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "stuck_window.json")
    run(w, clock, 40)
    assert len(leaves(m)) == 3 * FG_DEFAULTS["max_leave"]            # 3 attempts x 4 inputs, then silence
    ev = "\n".join(tools.events_lines())
    assert ev.count("CRITICAL") == 4                                 # 3 failed attempts + 1 give-up warning
    assert "no further input" in ev
    assert any(x["level"] == "crit" and "freeze_guard" in x["key"] for x in store.take_warnings())
    # time runs again -> the counter is reset
    g.moves_with_window = True
    run(w, clock, 2)
    g.moves_with_window = False
    run(w, clock, 5)
    assert len(leaves(m)) == 4 * FG_DEFAULTS["max_leave"]


# ---- more behaviour
def test_grace_for_window_opened_while_time_ran(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "player_info_running.json")
    g.screens = []
    run(w, clock, 2)                                                 # time runs on the map
    g.screens = ["dwarfmode/Info/CREATURES/CITIZEN"]                 # the player opens Info ...
    g.moves_with_window = False                                      # ... and it holds time
    run(w, clock, 8)                                                 # 16 s < grace 20 s
    assert not leaves(m)
    run(w, clock, 4)
    assert leaves(m) and g.focus == "dwarfmode/Default"


def test_paused_info_is_left_alone_but_messagebox_is_not():
    fgd = FreezeGuard()
    ctx = FreezeCtx()
    ds = [fgd.decide(FocusObs(True, 0, "dwarfmode/Info/X", 7), t, ctx).kind for t in range(0, 20, 2)]
    assert set(ds) == {"none"}
    fgd = FreezeGuard()
    ds = [fgd.decide(FocusObs(True, 0, "dfhack/lua/MessageBox", 7), t, ctx).kind for t in range(0, 8, 2)]
    assert ds[-1] == "close"


def test_unhandled_class_only_noted_once_and_hourly_cap():
    fgd = FreezeGuard()
    kinds = [fgd.decide(FocusObs(False, 0, "dwarfmode/Squads/Default", 7), t, FreezeCtx()).kind for t in range(0, 30, 2)]
    assert kinds.count("unhandled") == 1 and "close" not in kinds
    fgd = FreezeGuard()
    kinds = [fgd.decide(FocusObs(False, 0, "dwarfmode/Help", 7), t, FreezeCtx(actions_last_hour=10)).kind
             for t in range(0, 30, 2)]
    assert kinds.count("capped") == 1 and "close" not in kinds


def test_no_resume_during_alarm(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "justice_help.json")
    tools.write_flag("alert", "goblins")
    run(w, clock, 5)
    assert g.focus == "dwarfmode/Default"                            # windows closed ...
    assert "claude/advance run" not in m.calls                       # ... but no resume command during an alarm


def test_disabled(tmp_path, clock):
    w, g, m, tools, store = setup(tmp_path, clock, "justice_help.json", {"enabled": False})
    run(w, clock, 10)
    assert not leaves(m)
