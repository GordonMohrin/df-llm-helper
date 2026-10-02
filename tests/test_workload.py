"""Spec 06 workload control: decision tree, maintenance automation, 10 min block, effect measurement."""
import json

from conftest import FIX
from df_llm_helper.anomaly import CancelLoop, cancel_loops
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import read_text_tolerant
from df_llm_helper.workload import DEFAULTS, WorkloadPilot, WorkObs, diagnose, obs_from
from helpers import snap_for

GAMELOG = read_text_tolerant(FIX / "logs" / "gamelog_selected.txt").splitlines()


def svc(**kw):
    base = {"raster": True, "kohle": True, "orders": True, "arbeit": True}
    base.update(kw)
    return base


def test_dig_queue_empty_new_stage_first():
    """Acceptance 1: dig queue 0, idle 68 % -> 'new dig stage' first."""
    o = WorkObs(idle_pct=68, idle=100, adults=147, jobs_open=12, dig_queue=0, picks_total=11, work_weapons=11,
                coke=20, wood=50, services=svc(), raster_known=True, raster_next="E7_Nord")
    ms = diagnose(o)
    assert ms[0].key == "grab-etappe" and "new dig stage" in ms[0].action and ms[0].cmd == "claude/raster next"
    o.services["raster"] = False
    assert diagnose(o)[0].cmd == "claude/raster start"
    o.services["raster"], o.raster_next = True, None
    m = diagnose(o)[0]
    assert m.key == "grab-etappe" and m.cmd is None and "stages.lua" in m.action


def test_many_open_jobs_few_picks():
    """Acceptance 2: 208 open jobs, 54 idle, 11 picks -> 'Picks/fuel'."""
    o = WorkObs(idle_pct=60, idle=54, adults=90, jobs_open=208, dig_queue=150, picks_total=11, picks_free=0,
                work_weapons=11, coke=3, wood=10, services=svc())
    ms = diagnose(o)
    assert ms[0].key == "picken" and "Picks/fuel" in ms[0].action and "buy" in ms[0].action
    o.picks_free = 4
    assert "claude/pickfix --apply" in diagnose(o)[0].action and diagnose(o)[0].auto is False   # proposal only
    o.cancels = {"Needs refined coal": 40}
    keys = [m.key for m in diagnose(o)]
    assert keys[:2] == ["picken", "koks"]
    o.services["kohle"] = False
    assert not [m for m in diagnose(o) if m.key == "kohle"]               # coal unknown/present: no digging
    o.coal = 0
    m = [m for m in diagnose(o) if m.key == "kohle"][0]
    assert not m.auto and m.cmd is None and "kohle run 10" in m.action    # never automatic (9 s freeze, live)


def test_no_fuel_refers_to_spec07():
    """Acceptance 3: coke 0 + wood 0 -> pointer to spec 07."""
    o = WorkObs(idle_pct=55, idle=40, jobs_open=10, dig_queue=500, coke=0, wood=0, services=svc())
    ms = diagnose(o)
    assert ms[0].key == "brennstoff" and "spec 07" in ms[0].action and "bottleneck" in ms[0].action


def test_below_warn_nothing_and_services_restart():
    assert diagnose(WorkObs(idle_pct=30)) == [] and diagnose(WorkObs()) == []
    o = WorkObs(idle_pct=70, idle=30, jobs_open=2, dig_queue=500, services=svc(orders=False, arbeit=False),
                full_stockpiles=3)
    keys = [m.key for m in diagnose(o)]
    assert keys[:2] == ["dienst-arbeit", "dienst-orders"] and "lager" in keys and keys[-1] == "fuellarbeit"
    o2 = WorkObs(idle_pct=70, idle=30, jobs_open=100, dig_queue=500, suspended=20, services=svc(),
                 cancels={"Inappropriate dig square": 12, "Could not find path": 30})
    assert {"suspendiert", "grabfehler", "pfad"} <= {m.key for m in diagnose(o2)}


def pilot(responses=None):
    clock = FakeClock(100_000)
    m = MockClient(responses or {"claude/raster next": '{"etappe": "E7", "kacheln": 40}',
                                 "claude/raster start": '{"ok": true}', "claude/orders start": '{"ok": true}',
                                 "claude/arbeit start": '{"ok": true}'}, clock=clock)
    return WorkloadPilot(m, Store(), clock, DEFAULTS), m, clock


def test_effect_measured_next_run_and_no_repeat_within_10_min():
    """Acceptance 4 + 5."""
    wp, m, clock = pilot()
    o = WorkObs(idle_pct=68, idle=100, jobs_open=12, dig_queue=0, services=svc(), raster_known=True,
                raster_next="E7")
    out = wp.run(o)
    assert m.write_calls == ["claude/raster next"] and any("[executed]" in ln for ln in out)
    clock.advance(120)
    out = wp.run(o)
    assert m.write_calls == ["claude/raster next"] and any("blocked" in ln for ln in out)   # < 10 min
    clock.advance(240)                                                                       # 360 s > measure_after
    o2 = WorkObs(idle_pct=40, idle=60, jobs_open=12, dig_queue=300, services=svc())
    out = wp.run(o2)
    assert any(ln.startswith("ok done: grab-etappe (idle 68 -> 40 %)") for ln in out)
    w = wp.store.take_warnings()
    assert any("ok done" in x["text"] for x in w)
    assert wp.store.get("workload.effects") == {"grab-etappe": {"ok": 1, "ohne": 0}}
    clock.advance(400)
    wp.run(o)
    assert m.write_calls.count("claude/raster next") == 2                                   # again after 10 min
    clock.advance(400)
    wp.run(WorkObs(idle_pct=67, idle=99, jobs_open=12, dig_queue=500, services=svc()))
    assert any("no effect: grab-etappe" in x["text"] for x in wp.store.take_warnings())


def test_max_auto_per_run_and_dry():
    wp, m, _ = pilot()
    o = WorkObs(idle_pct=70, idle=30, jobs_open=2, dig_queue=0, services=svc(orders=False, arbeit=False, raster=False))
    out = wp.run(o)
    assert len(m.write_calls) == 2 and any("[deferred]" in ln for ln in out)
    wp2, m2, _ = pilot()
    out = wp2.run(o, dry=True)
    assert m2.write_calls == [] and any("[dry]" in ln for ln in out) and wp2.store.actions() == []
    assert len(out) <= 8


def test_obs_from_real_fixtures():
    snap = snap_for()
    ausl = json.loads((FIX / "auslastung_status.txt").read_text(encoding="utf-8"))
    pick = {"picks": [{"item": 1, "holder": 5}, {"item": 2}, {"item": 3, "holder": 7}], "work_weapons": 2}
    mat = {"stock": {"coke": 0, "wood": 0}}
    loops = cancel_loops(GAMELOG, min_count=1)
    o = obs_from(snap, auslastung=ausl, pickfix=pick, material=mat, cancels=loops,
                 raster={"laeuft": True, "naechste": None}, kohle={"laeuft": False})
    assert o.jobs_open == 199 and o.dig_queue == 63 and o.idle_pct == snap.idle_pct
    assert o.picks_total == 3 and o.picks_free == 1 and o.work_weapons == 2 and o.coke == 0 and o.wood == 0
    assert o.services["raster"] is True and o.services["kohle"] is False and o.raster_known and o.raster_next is None
    assert o.cancels.get("No water source", 0) > 0 and len(o.full_stockpiles.__str__()) > 0
    o2 = obs_from(snap, cancels=[CancelLoop("Dig", "Inappropriate dig square", 5, 1)])
    assert o2.cancels == {"Inappropriate dig square": 5}


def test_cli_workload(tmp_path, tools_dir, capsys):
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "workload", "--dry-run"]) == 0
    assert "Workload ok" in capsys.readouterr().out                           # fixture: idle 30 %
