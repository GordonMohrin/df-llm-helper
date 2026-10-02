"""F8 guard: state machine (table tests >= 30), hysteresis, Run-4 replay, runner with files."""
import pytest

from conftest import set_age
from dfpilot.config import DEFAULTS
from dfpilot.guard import GuardInputs, GuardRunner, GuardState, ProcessProbe, decide, target_fps, tempo_blockers
from dfpilot.store import Store
from dfpilot.toolsfs import ToolsDir
from helpers import snap_for

G = DEFAULTS["guard"]
OK = dict(heartbeat_age_min=1, last_report_id=100, max_report_id=100, events_size=10, events_age_min=1,
          guard_running=True, drink_days=150, food_days=150, pop=24, timestream=False, fps=250, normal_fps=250,
          paused=False)


def run(state=None, **kw):
    inp = GuardInputs(**{**OK, **kw})
    return decide(inp, state or GuardState(), G)


def kinds(acts):
    return [a.kind for a in acts if a.kind != "info"]


# (name, state before, inputs, expected action kinds, check lambda on the new state)
TABLE = [
    ("ruhe", {}, {}, [], lambda s: not s.slowed),
    ("hb_19", {}, dict(heartbeat_age_min=19), [], lambda s: not s.slowed),
    ("hb_21_deadman", {}, dict(heartbeat_age_min=21), ["set_fps", "event"], lambda s: s.slowed),
    ("hb_8h_deadman", {}, dict(heartbeat_age_min=480), ["set_fps", "event"], lambda s: s.slowed),
    ("hb_fehlt", {}, dict(heartbeat_age_min=None), ["warn"], lambda s: s.no_heartbeat_reported),
    ("hb_fehlt_einmal", {"no_heartbeat_reported": True}, dict(heartbeat_age_min=None), [], lambda s: True),
    ("slowed_bleibt_15", {"slowed": True}, dict(heartbeat_age_min=15, fps=30), [], lambda s: s.slowed),
    ("slowed_ende_5", {"slowed": True}, dict(heartbeat_age_min=5, fps=30), ["set_fps", "event"], lambda s: not s.slowed),
    ("slowed_fps_hoch", {"slowed": True}, dict(heartbeat_age_min=30, fps=250), ["set_fps"], lambda s: s.slowed),
    ("slowed_fps_ok", {"slowed": True}, dict(heartbeat_age_min=30, fps=30), [], lambda s: s.slowed),
    ("blind", {}, dict(last_report_id=28181, max_report_id=12), ["reset_report_id", "event"], lambda s: s.blind_resets == 1),
    ("blind_max_0", {}, dict(last_report_id=5, max_report_id=0), ["reset_report_id", "event"], lambda s: True),
    ("max_unbekannt", {}, dict(last_report_id=5, max_report_id=None), [], lambda s: True),
    ("max_minus1", {}, dict(last_report_id=5, max_report_id=-1), [], lambda s: True),
    ("lag_1", {}, dict(last_report_id=100, max_report_id=200), [], lambda s: s.lag_cycles == 1),
    ("lag_2", {"lag_cycles": 1}, dict(last_report_id=100, max_report_id=200), ["warn"], lambda s: s.lag_cycles == 2),
    ("lag_3_still", {"lag_cycles": 2}, dict(last_report_id=100, max_report_id=200), [], lambda s: s.lag_cycles == 3),
    ("lag_weg", {"lag_cycles": 5}, dict(last_report_id=199, max_report_id=200), [], lambda s: s.lag_cycles == 0),
    ("guard_tot", {}, dict(guard_running=False), ["warn"], lambda s: s.guard_down_reported),
    ("guard_tot_einmal", {"guard_down_reported": True}, dict(guard_running=False), [], lambda s: True),
    ("guard_wieder", {"guard_down_reported": True}, dict(guard_running=True), [], lambda s: not s.guard_down_reported),
    ("guard_unbekannt", {}, dict(guard_running=None), [], lambda s: not s.guard_down_reported),
    ("events_fehlt", {}, dict(events_size=None, events_age_min=None), ["warn"], lambda s: s.events_stale_reported),
    ("events_alt_laeuft", {}, dict(events_age_min=45), ["warn"], lambda s: s.events_stale_reported),
    ("events_alt_pause", {}, dict(events_age_min=45, paused=True), [], lambda s: not s.events_stale_reported),
    ("ts_ok", {}, dict(timestream=True), [], lambda s: True),
    ("ts_danger", {}, dict(timestream=True, danger=True), ["tempo_off", "event"], lambda s: True),
    ("ts_mood", {}, dict(timestream=True, moods=1), ["tempo_off", "event"], lambda s: True),
    ("ts_caravan", {}, dict(timestream=True, caravan_active=True), ["tempo_off", "event"], lambda s: True),
    ("ts_supplies", {}, dict(timestream=True, drink_days=50), ["tempo_off", "event"], lambda s: s.supply_low),
    ("ts_no_supervision", {}, dict(timestream=True, heartbeat_age_min=16), ["tempo_off", "event"], lambda s: True),
    ("supplies_hyst_stays", {"supply_low": True}, dict(drink_days=105), [], lambda s: s.supply_low),
    ("supplies_hyst_free", {"supply_low": True}, dict(drink_days=111, food_days=200), [], lambda s: not s.supply_low),
    ("pop_gate_60", {}, dict(pop=60), ["warn"], lambda s: 60 in s.gates_hit),
    ("pop_gate_einmal", {"gates_hit": [60]}, dict(pop=61), [], lambda s: s.gates_hit == [60]),
    ("pop_gate_ts", {"gates_hit": [60]}, dict(pop=61, timestream=True), ["tempo_off", "event"], lambda s: True),
    ("pop_gate_acked", {"gates_hit": [60], "gates_acked": [60]}, dict(pop=61, timestream=True), [], lambda s: True),
    ("ts_wiederholt_1", {"tempo_off_pending": 1}, dict(timestream=True, danger=True), [], lambda s: s.tempo_off_pending == 2),
    ("ts_wirkt_nicht", {"tempo_off_pending": 2}, dict(timestream=True, danger=True), ["warn"], lambda s: True),
    ("ts_neu_nach_5", {"tempo_off_pending": 5}, dict(timestream=True, danger=True), ["tempo_off", "event"], lambda s: True),
    ("ts_aus_reset", {"tempo_off_pending": 4}, dict(timestream=False, danger=True), [], lambda s: s.tempo_off_pending == 0),
]


@pytest.mark.parametrize("name,state,inp,expected,check", TABLE, ids=[t[0] for t in TABLE])
def test_state_table(name, state, inp, expected, check):
    acts, st = run(GuardState.from_dict(state), **inp)
    assert kinds(acts) == expected, [a.line() for a in acts]
    assert check(st)


def test_table_has_30_cases():
    assert len(TABLE) >= 30


def test_deadman_values_and_target_fps():
    acts, st = run(heartbeat_age_min=480)
    fps = [a for a in acts if a.kind == "set_fps"][0]
    assert fps.value == 30 and fps.level == "crit" and "480" in fps.reason
    assert target_fps(st, GuardInputs(normal_fps=250), G) == 30
    acts, st = run(st, heartbeat_age_min=1, normal_fps=None)
    assert [a.value for a in acts if a.kind == "set_fps"] == [250]          # last seen NORMAL_FPS
    acts, _ = decide(GuardInputs(heartbeat_age_min=1), GuardState(slowed=True), G)
    assert [a.value for a in acts if a.kind == "set_fps"] == [G["normal_fps"]]


def test_hysteresis_no_flapping():
    st = GuardState()
    n = 0
    for age in [19, 21, 19, 21, 18, 22, 15, 19, 11, 21]:
        acts, st = decide(GuardInputs(**{**OK, "heartbeat_age_min": age, "fps": 30 if st.slowed else 250}), st, G)
        n += sum(1 for a in acts if a.kind == "set_fps")
    assert n == 1 and st.slowed
    # supplies low around the threshold: the time-lapse blocker stays stable
    st = GuardState()
    blocked = []
    for dd in [99, 101, 99, 105, 108, 109, 111]:
        _, st = decide(GuardInputs(**{**OK, "drink_days": dd}), st, G)
        blocked.append("supplies" in tempo_blockers(GuardInputs(**{**OK, "drink_days": dd}), st, G))
    assert blocked == [True] * 6 + [False]


def test_runner_run4_scenario_one_cycle(tmp_path, mock, clock):
    tools = ToolsDir(tmp_path, clock)
    tools.touch_heartbeat()
    set_age(tools.heartbeat, clock, 480)
    tools.set_last_report_id(28181)
    (tmp_path / "events.log").write_text("", encoding="utf-8")
    store = Store()
    snap = snap_for(max_report_id=12, timestream=True)
    r = GuardRunner(mock, store, tools, clock, DEFAULTS, probe=type("P", (), {"running": lambda self: True})())
    acts, st, info = r.cycle(snap)
    assert 'lua "df.global.enabler.fps=30"' in mock.calls and "claude/tempo off" in mock.calls
    assert tools.last_report_id() == 12
    ev = "\n".join(tools.events_lines())
    assert "CRITICAL" in ev and "DEADMAN" in ev and "Watcher blind" in ev
    assert info["target_fps"] == 30 and not info["timestream_allowed"]
    assert any(w["level"] == "crit" for w in store.take_warnings())
    # second cycle: nothing twice
    mock.calls.clear()
    r.cycle(snap_for(max_report_id=13, timestream=False, fps=30))
    assert mock.calls == []


def test_runner_dry_run(tmp_path, mock, clock):
    tools = ToolsDir(tmp_path, clock)
    tools.touch_heartbeat()
    set_age(tools.heartbeat, clock, 100)
    tools.set_last_report_id(999)
    store = Store()
    acts, st, info = GuardRunner(mock, store, tools, clock, DEFAULTS).cycle(snap_for(max_report_id=5), dry_run=True)
    assert {"set_fps", "reset_report_id"} <= {a.kind for a in acts}
    assert mock.calls == [] and tools.last_report_id() == 999 and store.get("guard.state") is None


def test_stale_flags_reported_and_probe(tmp_path, clock, mock):
    tools = ToolsDir(tmp_path, clock)
    tools.write_flag("food", "x")
    set_age(tools.flag_path("food"), clock, 90)
    inp = GuardRunner(mock, Store(), tools, clock, DEFAULTS).inputs(snap_for())
    assert inp.stale_flags == ["food"] and inp.heartbeat_age_min is None
    acts, _ = decide(inp, GuardState(), G)
    assert any(a.kind == "info" and "food" in str(a.value) for a in acts)
    assert ProcessProbe("python").running() in (True, None)
    assert ProcessProbe("surely-does-not-exist-xyz").running() in (False, None)
    assert GuardState.from_dict({"slowed": True, "unknown": 1}).slowed
