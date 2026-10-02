"""Watcher (replacement for unpause-guard.ps1) and tempo on with the guard check."""
import pytest

from conftest import FIX, set_age
from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient
from df_llm_helper.config import DEFAULTS
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.waechter import CARAVANS_CMD, CLEAR_CMD, FOOD_CMD, Waechter, reports_cmd


def make(tmp_path, clock, reports="", maxid="100", last="90", food="S 50 0 10 100 20", clear="R 0 dwarfmode/Default",
         caravans="1"):
    tools = ToolsDir(tmp_path, clock)
    tools.set_last_report_id(int(last))
    (tmp_path / "events.log").write_text("", encoding="utf-8")
    tools.touch_heartbeat()
    m = MockClient({MAX_REPORT_ID_CMD: maxid, FOOD_CMD: food, CLEAR_CMD: clear, CARAVANS_CMD: caravans}, clock=clock)
    m.prefix_handlers.append(('lua "local last=', lambda c: reports))
    return Waechter(m, tools, clock, Store(), DEFAULTS), m, tools


def test_reports_logged_and_id_saved(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, reports="91|MIGRANT_ARRIVAL|102.5|Some migrants have arrived.\n"
                                               "92|CANCEL_JOB|102.6|Urist cancels Dig: x.\nRauschen")
    w.step()
    ev = "\n".join(tools.events_lines())
    assert "info" in ev and "[MIGRANT_ARRIVAL] Some migrants have arrived." in ev
    assert tools.last_report_id() == 92 and (tmp_path / "out" / "waechter.alive").exists()
    assert "claude/advance run" not in m.calls          # not paused -> nothing to do


def test_enemy_alarm_pauses_and_flags(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, reports="91|AMBUSH|102.5|You have been ambushed by goblins!")
    w.step()
    assert tools.flag("alert").exists and tools.flag("siege").exists
    assert (tmp_path / "pause.hold").read_text() == "alarm"
    assert ["claude/advance 0", "claude/alert on", "claude/tempo suspend"] == \
        [c for c in m.calls if c in ("claude/advance 0", "claude/alert on", "claude/tempo suspend")]
    assert "CRITICAL" in "\n".join(tools.events_lines())


def test_death_without_enemy_only_flag(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, reports="91|CITIZEN_DEATH|102.5|Urist has been found dead.")
    w.step()
    assert tools.flag("alert").exists and not (tmp_path / "pause.hold").exists()
    assert "claude/advance 0" not in m.calls and "Alert flag without pause" in "\n".join(tools.events_lines())


def test_same_type_alarm_at_most_every_5_min_and_combat_ignored(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, reports="91|COMBAT|102.5|The goblin strikes!")
    w.step()
    assert not tools.flag("alert").exists                 # COMBAT does not raise an alarm
    w2, m2, tools2 = make(tmp_path / "b", clock, reports="91|THEFT|1.1|A thief stole!")
    w2.step()
    tools2.delete_flag("alert")
    w2.step()                                              # same report again (mock), < 300 s
    assert not tools2.flag("alert").exists


def test_caravan_arrival(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, reports="91|CARAVAN_ARRIVAL|102.5|A human caravan has arrived.")
    w.step()
    assert tools.flag("caravan").exists and (tmp_path / "pause.hold").read_text() == "karawane"
    assert "claude/advance 0" in m.calls


def test_new_game_resets_report_id(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, maxid="5", last="28181")
    w.step()
    assert tools.last_report_id() == 5 and "new game" in "\n".join(tools.events_lines())


def test_food_flag_and_gefahr_hold_expiry(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, food="S 4 0 0 103 6")
    (tmp_path / "pause.hold").write_text("gefahr Bestie")
    set_age(tmp_path / "pause.hold", clock, 25)
    tools.write_flag("alert", "old")
    w.step()
    assert "meals+meat+fish=4, drinks=103" in tools.flag("food").text
    assert not (tmp_path / "pause.hold").exists() and not tools.flag("alert").exists


def test_unpause_only_without_hold(tmp_path, clock):
    w, m, tools = make(tmp_path, clock, clear="P 1 dwarfmode/Default")
    w.step()
    assert "claude/advance run" in m.calls
    w2, m2, tools2 = make(tmp_path / "b", clock, clear="P 1 dwarfmode/Default")
    (tmp_path / "b" / "pause.hold").write_text("karawane")
    w2.step()
    assert "claude/advance run" not in m2.calls


def test_deadman_runs_in_waechter(tmp_path, clock):
    w, m, tools = make(tmp_path, clock)
    set_age(tools.heartbeat, clock, 30)
    w.step()
    assert 'lua "df.global.enabler.fps=30"' in m.calls


def test_reports_cmd_shape():
    c = reports_cmd(42)
    assert c.startswith('lua "local last=42 ') and "df2utf" in c


def test_guard_uses_alive_file(tmp_path, clock):
    from df_llm_helper.guard import GuardRunner
    tools = ToolsDir(tmp_path, clock)
    (tmp_path / "out").mkdir()
    (tmp_path / "out" / "waechter.alive").write_text("x")
    set_age(tmp_path / "out" / "waechter.alive", clock, 0.5)
    g = GuardRunner(MockClient({}), Store(), tools, clock, DEFAULTS)
    assert g.inputs(None).guard_running is True
    set_age(tmp_path / "out" / "waechter.alive", clock, 5)
    assert g.inputs(None).guard_running is False


def test_cli_waechter_and_tempo(tmp_path, tools_dir, capsys):
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "waechter"]) == 0
    assert main(["--config", str(c), "--mock", str(FIX), "tempo", "on"]) == 1
    assert "blockers" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "tempo", "off"]) == 0


def test_unpause_with_frame_counter_and_latency_monitor(tmp_path, clock):
    """Spec v3-04: the status line carries ' fc=.. yt=..'; spec v3-03: light queries feed the latency monitor."""
    w, m, tools = make(tmp_path, clock, clear="P 1 dwarfmode/Default fc=4711 yt=12")
    w.step()
    assert "claude/advance run" in m.calls
    assert len(w.perf.samples) == 2 and not tools.flag("perf").exists
