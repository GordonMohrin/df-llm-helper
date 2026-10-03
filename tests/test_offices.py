"""FEATURE-001 offices watch: states, successor score, distinct suggestions, state-change wake, --apply gate, trade
precheck, Lua script under the mock. Fixtures (fixtures/v3/offices/) are SYNTHETIC."""
import json
import shutil
import subprocess

import pytest

from df_llm_helper.client import MockClient, is_write
from df_llm_helper.clock import FakeClock
from df_llm_helper.fairplay import ExceptionRegistry
from df_llm_helper.features import offices as O
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.trade_flow import HOLD_CMD, TradeFlow, TradeObs
from df_llm_helper.wake import wake_check
from helpers import ROOT

FIX = ROOT / "fixtures" / "v3" / "offices"
LUA = shutil.which("lua5.4")
MOCK = ROOT / "tests" / "lua_mock" / "claude_mock.lua"
CLAUDE = ROOT / "lua" / "claude"
SIX = ["MANAGER", "BOOKKEEPER", "BROKER", "CAPTAIN_OF_THE_GUARD", "MILITIA_COMMANDER", "CHIEF_MEDICAL_DWARF"]


def fx(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


def unit(**kw):
    d = {"id": 1, "alive": True, "adult": True, "citizen": True, "skills": {}, "stress": 0, "wounds": 0}
    d.update(kw)
    return d


# ---------------------------------------------------------------- acceptance 6: pure scoring
def test_score_skills_stress_wounds_squad():
    cfg = dict(O.DEFAULTS)
    trader = unit(skills={"NEGOTIATION": 5, "APPRAISAL": 4, "JUDGING_INTENT": 3})
    assert O.score(trader, "BROKER", cfg) == 5 * 3 + 4 * 2 + 3 * 2
    assert O.score({**trader, "stress": 50000}, "BROKER", cfg) == 29 - 2.0           # stress lowers the score
    assert O.score({**trader, "wounds": 2}, "BROKER", cfg) == 28.0                   # scars: small penalty
    assert O.score({**trader, "stress": 80000}, "BROKER", cfg) is None               # about to snap
    for bad in ({"mood": True}, {"adult": False}, {"prisoner": True}, {"patient": True}, {"cant_stand": True},
                {"alive": False}, {"citizen": False}, {"depot_reach": False}):
        assert O.score({**trader, **bad}, "BROKER", cfg) is None, bad
    assert O.score({**trader, "squad": True}, "BROKER", cfg) is None                 # soldiers stay soldiers
    lead = unit(skills={"LEADERSHIP": 3, "AXE": 8})
    assert O.score({**lead, "squad": True, "squad_leader": True}, "CAPTAIN_OF_THE_GUARD", cfg) == 9 + 8 + 5 + 3
    assert O.score(lead, "CAPTAIN_OF_THE_GUARD", cfg) == 9 + 8 - 3                   # not a soldier: allowed, lower
    org = unit(skills={"ORGANIZATION": 4})
    assert O.score({**org, "pick": True}, "MANAGER", cfg) == 12 - 6                   # keep the miners digging
    assert O.score({**org, "care": 6}, "MANAGER", cfg, patients=2) == 12 - 4          # caretaker stays with patients
    assert O.score({**org, "care": 6}, "MANAGER", cfg, patients=0) == 12
    med = unit(skills={"DIAGNOSE": 2}, care=6)
    assert O.score(med, "CHIEF_MEDICAL_DWARF", cfg, patients=3) == 6


def test_holder_states():
    cfg = dict(O.DEFAULTS)
    ok = unit(squad=True)
    assert O.holder_state("BROKER", None, cfg) == ("empty", "")
    assert O.holder_state("BROKER", {"hf": 5, "alive": False, "dead": True}, cfg) == ("dead", "")
    assert O.holder_state("BROKER", {"hf": 5, "alive": False, "gone": True}, cfg) == ("dead", "gone")
    assert O.holder_state("BROKER", {**ok, "mood": True}, cfg) == ("unfit", "mood")
    assert O.holder_state("BROKER", {**ok, "adult": False}, cfg) == ("unfit", "child")
    assert O.holder_state("BROKER", {**ok, "prisoner": True}, cfg) == ("unfit", "prisoner")
    assert O.holder_state("BROKER", {**ok, "patient": True}, cfg) == ("unfit", "wounded")
    assert O.holder_state("BROKER", {**ok, "stress": 90000}, cfg) == ("unfit", "stress")
    assert O.holder_state("BROKER", {**ok, "depot_reach": False}, cfg) == ("unfit", "depot unreachable")
    assert O.holder_state("CAPTAIN_OF_THE_GUARD", unit(), cfg) == ("unfit", "not a soldier")
    assert O.holder_state("CAPTAIN_OF_THE_GUARD", ok, cfg) == ("ok", "")


# ---------------------------------------------------------------- acceptance 1-3 (fixtures)
def test_siege_aftermath_six_problems_six_distinct_fit_successors():
    data = fx("status_siege_aftermath.json")
    rows = O.evaluate(data, O.DEFAULTS)
    assert [r.code for r in rows] == SIX and all(r.problem for r in rows)
    assert {r.state for r in rows} == {"empty", "dead"}
    ids = [r.suggest["id"] for r in rows]
    assert len(set(ids)) == 6
    cits = {c["id"]: c for c in data["citizens"]}
    for i in ids:
        c = cits[i]
        assert c["alive"] and c["adult"] and not c["mood"] and not c["patient"] and not c["cant_stand"]
    assert dict(zip(SIX, ids)) == {"MANAGER": 4621, "BOOKKEEPER": 4310, "BROKER": 4193, "CAPTAIN_OF_THE_GUARD": 4080,
                                   "MILITIA_COMMANDER": 3473, "CHIEF_MEDICAL_DWARF": 4402}
    line = O.summary_line(rows)
    assert line.startswith("OFFICES: MANAGER empty, BOOKKEEPER empty, BROKER empty, CAPTAIN_OF_THE_GUARD dead (Kosoth)")
    assert "MANAGER 4621 Kol (Mechanic)" in line


def test_broker_in_mood_is_unfit_and_next_trader_suggested():
    rows = {r.code: r for r in O.evaluate(fx("status_broker_mood.json"), O.DEFAULTS)}
    b = rows["BROKER"]
    assert (b.state, b.reason) == ("unfit", "mood") and b.suggest["id"] == 4193
    assert rows["MAYOR"].state == "unfit" and rows["MAYOR"].suggest is None          # elected: never suggested
    assert O.apply_commands(list(rows.values()), O.DEFAULTS) == []                    # unfit only with the flag
    assert O.apply_commands(list(rows.values()), O.DEFAULTS, replace_unfit=True) == [
        "claude/aemter vacate BROKER", "claude/aemter assign BROKER 4193"]


def test_all_ok_one_line_and_exit_0(capsys):
    from df_llm_helper.cli import main
    rows = O.evaluate(fx("status_all_ok.json"), O.DEFAULTS)
    assert O.summary_line(rows) == "Offices: 6/6 filled"
    assert main(["offices", "--file", str(FIX / "status_all_ok.json")]) == 0
    assert capsys.readouterr().out.startswith("Offices: 6/6 filled\n")
    assert main(["offices", "--file", str(FIX / "status_siege_aftermath.json")]) == 1


def test_on_demand_broker_may_stay_empty():
    data = fx("status_siege_aftermath.json")
    rows = {r.code: r for r in O.evaluate(data, {**O.DEFAULTS, "on_demand": ["BROKER"]})}
    assert rows["BROKER"].state == "empty" and not rows["BROKER"].problem


def test_mayor_required_only_when_present_and_na_positions():
    data = fx("status_all_ok.json")
    assert "MAYOR" not in O.required_codes(data, O.DEFAULTS)
    data["positions"] = [p for p in data["positions"] if p["code"] != "CHIEF_MEDICAL_DWARF"]
    rows = O.evaluate(data, O.DEFAULTS)
    assert rows[-1].state == "n/a" and O.summary_line(rows) == "Offices: 5/5 filled"


# ---------------------------------------------------------------- acceptance 3 + 5: wake once per state change
def _hook_env(tmp_path, data):
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(1_790_840_000.0)
    m = MockClient({O.STATUS_CMD: json.dumps(data)}, clock=clock)
    store = Store()
    p = Pilot(load_config(overrides={}), m, store=store, clock=clock, tools=ToolsDir(tmp_path, clock))
    return p, m, clock


def test_check_hook_all_ok_no_wake_on_second_run(tmp_path):
    p, m, clock = _hook_env(tmp_path, fx("status_all_ok.json"))
    tools = ToolsDir(tmp_path, clock)
    wake_check(tools, p.store, clock)                                     # baseline
    assert O.check_hook(p, None, False) == ["Offices: 6/6 filled"]
    clock.advance(400)
    assert O.check_hook(p, None, False) == []
    assert wake_check(tools, p.store, clock) == []


def test_state_change_ok_to_dead_exactly_one_wake_line(tmp_path):
    p, m, clock = _hook_env(tmp_path, fx("status_all_ok.json"))
    tools = ToolsDir(tmp_path, clock)
    wake_check(tools, p.store, clock)
    O.check_hook(p, None, False)
    m.set(O.STATUS_CMD, json.dumps(fx("status_broker_dead.json")))
    clock.advance(400)
    lines = O.check_hook(p, None, False)
    assert lines == ["OFFICES: BROKER dead (Adil) -> suggest 4193 Urist (Trader)"]
    woke = wake_check(tools, p.store, clock)
    assert len(woke) == 1 and "BROKER dead (Adil)" in woke[0]
    for _ in range(3):                                                    # unchanged: no more lines, no more wakes
        clock.advance(400)
        assert O.check_hook(p, None, False) == []
        assert wake_check(tools, p.store, clock) == []
    m.set(O.STATUS_CMD, json.dumps(fx("status_all_ok.json")))
    clock.advance(400)
    assert O.check_hook(p, None, False) == ["Offices: 6/6 filled (resolved)"]
    assert wake_check(tools, p.store, clock) == []


def test_check_hook_interval_dry_and_missing_script(tmp_path):
    p, m, clock = _hook_env(tmp_path, fx("status_broker_dead.json"))
    assert O.check_hook(p, None, True)                                    # dry: reports, records nothing
    assert p.store.get("offices.sig") is None and p.store.peek_warnings() == []
    assert O.check_hook(p, None, False)
    clock.advance(10)
    assert O.check_hook(p, None, False) == []                             # within every_s
    m.set(O.STATUS_CMD, "")
    clock.advance(400)
    assert O.check_hook(p, None, False) == []


def test_unfit_only_is_a_warn_not_a_wake(tmp_path):
    p, m, clock = _hook_env(tmp_path, fx("status_broker_mood.json"))
    tools = ToolsDir(tmp_path, clock)
    wake_check(tools, p.store, clock)
    assert O.check_hook(p, None, False)[0].startswith("OFFICES: BROKER unfit (mood, Adil)")
    assert [w["level"] for w in p.store.peek_warnings()] == ["warn"]
    assert wake_check(tools, p.store, clock) == []


# ---------------------------------------------------------------- --apply gate (register entry OFFICES)
def _offices(tmp_path, data, registry=None):
    clock = FakeClock(1_790_840_000.0)
    m = MockClient({O.STATUS_CMD: json.dumps(data)}, clock=clock)
    m.prefix_handlers.append(("claude/aemter ", lambda c: json.dumps({"done": c.split()[1]})))
    return O.Offices(m, Store(), clock, {}, registry=registry), m


def test_apply_needs_the_register_and_uses_vacate_plus_assign(tmp_path):
    o, m = _offices(tmp_path, fx("status_siege_aftermath.json"))
    rows = O.evaluate(o.read(), o.cfg)
    dry = o.apply(rows, apply=False)
    assert dry[0] == "[dry] claude/aemter assign MANAGER 4621" and not m.write_calls
    assert "[dry] claude/aemter vacate CAPTAIN_OF_THE_GUARD" in dry
    refused = o.apply(rows, apply=True)
    assert refused[0].startswith("Refused") and not m.write_calls
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("OFFICES", "fill dead/empty offices", "ja, besetz die Aemter")
    o2, m2 = _offices(tmp_path, fx("status_siege_aftermath.json"), registry=reg)
    out = o2.apply(O.evaluate(o2.read(), o2.cfg), apply=True)
    assert m2.write_calls == ["claude/aemter assign MANAGER 4621", "claude/aemter assign BOOKKEEPER 4310",
                              "claude/aemter assign BROKER 4193", "claude/aemter vacate CAPTAIN_OF_THE_GUARD",
                              "claude/aemter assign CAPTAIN_OF_THE_GUARD 4080",
                              "claude/aemter vacate MILITIA_COMMANDER", "claude/aemter assign MILITIA_COMMANDER 3473",
                              "claude/aemter vacate CHIEF_MEDICAL_DWARF",
                              "claude/aemter assign CHIEF_MEDICAL_DWARF 4402"]
    assert all(ln.startswith("ok   ") for ln in out) and len(o2.store.actions()) == 9


def test_apply_stops_when_vacate_fails(tmp_path):
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("OFFICES", "r", "ja")
    o, m = _offices(tmp_path, fx("status_broker_dead.json"), registry=reg)
    m.prefix_handlers.insert(0, ("claude/aemter vacate", lambda c: json.dumps({"error": "unbekanntes Amt"})))
    out = o.apply(O.evaluate(o.read(), o.cfg), apply=True)
    assert out[0].startswith("ERROR claude/aemter vacate BROKER") and "stopped" in out[1]
    assert m.write_calls == ["claude/aemter vacate BROKER"]


def test_offices_register_id_known_and_read_command():
    from df_llm_helper.fairplay import known_rule_ids
    assert {"OFFICES", "HOSPITAL"} <= known_rule_ids()
    assert not is_write(O.STATUS_CMD) and is_write("claude/aemter assign BROKER 4193")


# ---------------------------------------------------------------- acceptance 4: trade precheck
def test_trade_flow_fails_at_idle_with_the_offices_message():
    f = TradeFlow()
    o = TradeObs(caravan_state="AtDepot", broker_problem="offices: BROKER dead (Adil); candidate 4193 Urist")
    cmds = f.step(o, 100.0)
    assert cmds == [] and f.state == "FAILED" and f.abort_reason.startswith("offices: BROKER dead")
    assert HOLD_CMD not in cmds and f.log == ["IDLE -> FAILED (offices: BROKER dead (Adil); candidate 4193 Urist)"]
    g = TradeFlow()
    assert g.step(TradeObs(caravan_state="AtDepot"), 100.0)[0] == HOLD_CMD          # no problem: normal PAUSE


def test_broker_problem_rules():
    cfg = dict(O.DEFAULTS)
    assert O.broker_problem(fx("status_broker_dead.json"), cfg).startswith(
        "offices: BROKER dead (Adil); candidate 4193 Urist -> python -m df_llm_helper offices --apply")
    assert O.broker_problem(fx("status_broker_mood.json"), cfg).startswith("offices: BROKER unfit (mood, Adil)")
    assert O.broker_problem(fx("status_all_ok.json"), cfg) == ""
    assert O.broker_problem(fx("status_siege_aftermath.json"), cfg) == ""     # empty + candidate: handel prep appoints
    stressed = fx("status_all_ok.json")
    stressed["positions"][2]["holder"]["stress"] = 90000
    assert O.broker_problem(stressed, cfg) == ""                               # stress alone does not stop a trade
    nobody = fx("status_siege_aftermath.json")
    nobody["citizens"] = [c for c in nobody["citizens"] if c["id"] != 4193 and not c["skills"].get("NEGOTIATION")]
    nobody["citizens"] = [{**c, "squad": True} for c in nobody["citizens"]]
    assert O.broker_problem(nobody, cfg).startswith("offices: BROKER empty; no candidate")
    assert O.broker_problem(None, cfg) == "" and O.broker_problem({"ok": False}, cfg) == ""


def test_cli_trade_step_with_dead_broker_fails_without_pause_hold(tmp_path, tools_dir, capsys):
    from conftest import FIX as RUN5
    from df_llm_helper.cli import main
    fxd = tmp_path / "fx"
    shutil.copytree(RUN5, fxd)
    shutil.copy(ROOT / "fixtures" / "run5_live" / "handel_status_atdepot_open.json", fxd / "handel_status.txt")
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    import df_llm_helper.client as cl
    orig = cl.MockClient.from_fixture_dir.__func__

    def with_offices(cls, path, **kw):
        m = orig(cls, path, **kw)
        m.set(O.STATUS_CMD, (FIX / "status_broker_dead.json").read_text(encoding="utf-8"))
        return m
    try:
        cl.MockClient.from_fixture_dir = classmethod(with_offices)
        assert main(["--config", str(c), "--mock", str(fxd), "trade", "step"]) == 0
    finally:
        cl.MockClient.from_fixture_dir = classmethod(orig)
    out = capsys.readouterr().out
    assert "State now: FAILED (offices: BROKER dead (Adil)" in out and "HELPER hold" not in out
    assert not (tools_dir / "pause.hold").exists()


def test_caravan_autopilot_reports_the_broker_precheck(tmp_path):
    from df_llm_helper.caravan import CaravanPilot
    clock = FakeClock(1_790_840_000.0)
    st = json.loads((ROOT / "fixtures" / "run5_live" / "handel_status_atdepot_open.json").read_text(encoding="utf-8"))
    m = MockClient({"claude/handel status": json.dumps(st), "claude/advance clock": json.dumps({"paused": False}),
                    O.STATUS_CMD: (FIX / "status_broker_dead.json").read_text(encoding="utf-8")}, clock=clock)
    tools = ToolsDir(tmp_path, clock)
    cp = CaravanPilot(m, tools, Store(), clock, {}, ROOT)
    state, _ = cp.step()
    assert state == "failed" and not tools.flag("pause.hold").exists
    assert any(r.startswith("Trade not started (offices: BROKER dead") for r in cp.report())
    assert any("Trade not started" in w["text"] for w in cp.store.peek_warnings())


# ---------------------------------------------------------------- Lua under the mock
_SETUP = """
local function ident() return setmetatable({}, { __index = function(_, k) return k end }) end
df.job_skill = ident(); df.unit_labor = ident(); df.job_type = ident(); df.item_type = ident()
df.global.plotinfo.group_id = 1
local U, HF = {}, {}
local function mk(id, t)
  local u = { id = id, _name = t.name, hist_figure_id = 9000 + id, mood = t.mood or -1, _dead = t.dead,
              _child = t.child, _skills = t.skills or {}, _prof = t.prof or 'Peasant', _offices = t.offices or {},
              status = { current_soul = { personality = { stress = t.stress or 0 } }, labors = t.labors or {} },
              status2 = { limbs_stand_count = t.cant_stand and 0 or 2 }, body = { wounds = t.wounds or {} },
              job = { current_job = t.job and { job_type = t.job } or nil }, flags1 = { caged = t.caged or false },
              military = { squad_id = t.squad or -1, squad_position = t.squad_pos or -1 }, inventory = {},
              pos = { x = 1, y = 1, z = 1 } }
  U[id] = u
  HF[9000 + id] = { unit_id = id, died_year = t.dead and 120 or -1 }
  return u
end
local kol = mk(4621, { name = 'Kol', prof = 'Mechanic', skills = { ORGANIZATION = 4 }, offices = { 'MANAGER' } })
local cap = mk(3748, { name = 'Rovod', dead = true })
local trader = mk(4193, { name = 'Urist', skills = { NEGOTIATION = 5 }, stress = 20000, labors = { DIAGNOSE = true } })
local hurt = mk(4600, { name = 'Fikod', cant_stand = true, wounds = { 1, 2 }, job = 'Rest' })
local soldier = mk(4080, { name = 'Mafol', squad = 33, squad_pos = 0, skills = { LEADERSHIP = 3 } })
HF[8812] = { unit_id = -1, died_year = 121 }                       -- histfig without a unit: dead before
local own = { { id = 0, code = 'MANAGER' }, { id = 1, code = 'BROKER' }, { id = 2, code = 'CAPTAIN_OF_THE_GUARD' },
              { id = 3, code = 'CHIEF_MEDICAL_DWARF' }, { id = 4, code = 'BOOKKEEPER' } }
local asg = { { id = 10, position_id = 0, histfig = 9000 + 4621, histfig2 = -1 },
              { id = 11, position_id = 1, histfig = -1, histfig2 = -1 },
              { id = 12, position_id = 2, histfig = 9000 + 3748, histfig2 = 9000 + 3748 },
              { id = 13, position_id = 3, histfig = 8812, histfig2 = -1 },
              { id = 14, position_id = 4, histfig = -1, histfig2 = 9000 + 4193 } }
df.historical_entity.find = function() return { positions = { own = own, assignments = asg } } end
df.historical_figure.find = function(id) return HF[id] end
df.unit.find = function(id) return U[id] end
dfhack.TranslateName = function() return 'Adil' end
dfhack.units.getCitizens = function() return { kol, cap, trader, hurt, soldier } end
dfhack.units.isDead = function(u) return u._dead == true end
dfhack.units.isAlive = function(u) return not u._dead end
dfhack.units.isCitizen = function() return true end
dfhack.units.isAdult = function(u) return not u._child end
dfhack.units.getNominalSkill = function(u, s) return u._skills[s] or 0 end
dfhack.units.getProfessionName = function(u) return u._prof end
dfhack.units.getNoblePositions = function(u)
  local out = {}
  for _, c in ipairs(u._offices) do out[#out + 1] = { position = { code = c } } end
  return out
end
df.global.world.buildings.other.TRADE_DEPOT = { { centerx = 5, centery = 5, z = 1 } }
dfhack.maps.canWalkBetween = function() return MOCK_REACH ~= false end
"""


def run_offices(tmp_path, *args, extra=""):
    setup = tmp_path / "offices_setup.lua"
    setup.write_text(extra + _SETUP, encoding="utf-8")
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_offices.lua"), *args], capture_output=True,
                       timeout=10, env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home),
                                        "MOCK_SCRIPT_DIR": str(CLAUDE), "MOCK_SETUP": str(setup)})
    assert r.returncode == 0, r.stderr.decode()
    return json.loads(r.stdout.decode().splitlines()[0])


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_status_reads_holders_dead_histfigs_and_fitness(tmp_path):
    j = run_offices(tmp_path, "status")
    assert j["ok"] and j["depot"] is True and j["patients"] == 1
    pos = {p["code"]: p for p in j["positions"]}
    assert pos["MANAGER"]["holder"]["id"] == 4621 and pos["MANAGER"]["holder"]["alive"] is True
    assert pos["BROKER"].get("holder") is None
    assert pos["CAPTAIN_OF_THE_GUARD"]["holder"]["alive"] is False                 # assignment on a dead unit
    cmd = pos["CHIEF_MEDICAL_DWARF"]["holder"]
    assert cmd["dead"] is True and cmd["gone"] is True and cmd["alive"] is False    # histfig without a unit
    assert pos["BOOKKEEPER"]["holder"]["id"] == 4193                                # histfig2 wins
    cits = {c["id"]: c for c in j["citizens"]}
    assert 3748 not in cits                                                         # dead: no candidate
    t = cits[4193]
    assert t["skills"] == {"NEGOTIATION": 5} and t["stress"] == 20000 and t["care"] == 1 and t["depot_reach"] is True
    assert cits[4600]["patient"] is True and cits[4600]["wounds"] == 2 and cits[4600]["cant_stand"] is True
    assert cits[4080]["squad"] is True and cits[4080]["squad_leader"] is True
    assert cits[4621]["offices"] == ["MANAGER"] and cits[4621]["prof"] == "Mechanic"
    rows = {r.code: r for r in O.evaluate(j, O.DEFAULTS)}                           # the Python side reads it
    assert rows["CAPTAIN_OF_THE_GUARD"].state == "dead" and rows["BROKER"].state == "empty"
    assert rows["CAPTAIN_OF_THE_GUARD"].suggest["id"] == 4080


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_depot_unreachable_and_usage(tmp_path):
    j = run_offices(tmp_path, "status", extra="MOCK_REACH = false\n")
    assert all(c["depot_reach"] is False for c in j["citizens"])
    assert run_offices(tmp_path, "assign")["ok"] is False                          # no write path at all
