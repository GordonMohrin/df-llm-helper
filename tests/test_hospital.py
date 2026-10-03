"""FEATURE-004 hospital watch: staff posts (addendum 02.10.2026), labors, waiting patients, water (hospital + refuge),
supplies, plaster check in the planner, state-change wake, staff --apply gate, Lua script under the mock.
Fixtures (fixtures/v3/hospital/) are SYNTHETIC."""
import json
import shutil
import subprocess

import pytest

from df_llm_helper import care
from df_llm_helper.client import MockClient, is_write
from df_llm_helper.clock import FakeClock
from df_llm_helper.fairplay import ExceptionRegistry
from df_llm_helper.features import hospital as H
from df_llm_helper.planners.medical import PLASTER_IMPOSSIBLE, gypsum_count, plan_medical
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.wake import wake_check
from helpers import ROOT

FIX = ROOT / "fixtures" / "v3" / "hospital"
LUA = shutil.which("lua5.4")
MOCK = ROOT / "tests" / "lua_mock" / "claude_mock.lua"
CLAUDE = ROOT / "lua" / "claude"


def fx(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


def texts(ev):
    return [t for _, _, t in ev.problems]


# ---------------------------------------------------------------- care.py extension (pure)
def test_post_rules():
    alive = {"id": 6, "type": "DOCTOR", "unit_id": 1, "holder": {"id": 1, "alive": True, "adult": True}}
    dead = {"id": 7, "type": "DOCTOR", "unit_id": 2, "holder": {"id": 2, "alive": False}}
    gone = {"id": 8, "type": "SURGEON", "unit_id": 3, "holder": None}
    child = {"id": 9, "type": "DOCTOR", "unit_id": 4, "holder": {"id": 4, "alive": True, "adult": False}}
    empty = {"id": 10, "type": "DOCTOR", "unit_id": -1, "holder": None}
    assert care.post_filled(alive) and not any(care.post_filled(p) for p in (dead, gone, child, empty))
    assert care.location_staffed([alive]) and not care.location_staffed([dead, empty])
    trio = [{"type": t, "unit_id": 1, "holder": {"alive": True}} for t in ("DIAGNOSTICIAN", "SURGEON", "BONE_DOCTOR")]
    assert care.location_staffed(trio) and not care.location_staffed(trio[:2])
    un = care.unfilled_posts([{"id": 11, "zones": 1, "posts": [alive, dead, gone, empty]},
                              {"id": 3, "zones": 0, "posts": [empty]}])
    assert [(p["id"], p["dead_holder"], p["location"]) for p in un] == [(7, True, 11), (8, True, 11), (10, False, 11)]


def test_labor_staff_and_post_candidates():
    cits = [{"id": 1, "labors": ["DIAGNOSE"], "idle": True}, {"id": 2, "labors": ["DIAGNOSE"], "squad": True},
            {"id": 3, "labors": ["DIAGNOSE"], "cant_stand": True}]
    st = care.labor_staff(cits)
    assert st["DIAGNOSE"] == {"n": 3, "idle": 1, "injured": 1, "squad": 1} and st["SURGERY"]["n"] == 0
    pool = [{"id": 10, "care_skill": 1}, {"id": 11, "care_skill": 5}, {"id": 12, "care_skill": 9, "squad": True},
            {"id": 13, "care_skill": 9, "pick": True}, {"id": 14, "care_skill": 9, "mood": True},
            {"id": 15, "care_skill": 9, "child": True}, {"id": 16, "care_skill": 9, "stress": 90000},
            {"id": 17, "care_skill": 9, "job": "Rest"}, {"id": 18, "care_skill": 9, "prisoner": True},
            {"id": 19, "care_skill": 5}]
    assert [c["id"] for c in care.post_candidates(pool, 5)] == [11, 19, 10]
    assert [c["id"] for c in care.post_candidates(pool, 5, exclude={11})] == [19, 10]


# ---------------------------------------------------------------- acceptance 1: patients, no surgeon, waiting
def test_patients_no_surgeon_lists_the_labor_and_the_waiting_patients():
    clock = FakeClock(1_790_840_000.0)
    data = fx("status_patients_no_surgeon.json")
    h = H.Hospital(MockClient({}, clock=clock), Store(), clock, {})
    ev = h.evaluate(data)
    assert "0 doctors with SURGERY" in texts(ev) and not ev.waiting                 # first sighting: not waiting yet
    data["tick"] += 2400
    ev = h.evaluate(data)
    assert ev.waiting == [4800, 4801]                                               # 4802 has a RecoverWounded job
    assert "2 patient(s) without a care job > 2400 ticks" in texts(ev)
    line = H.summary_line(ev)
    assert line == "HOSPITAL: 3 patients, 0 doctors with SURGERY, 2 patient(s) without a care job > 2400 ticks"
    out = "\n".join(H.status_lines(ev))
    assert "4800 Patient Rith (no care job)" in out and "4802 Patient Bomrek (RecoverWounded)" in out
    data["citizens"][-3]["care_jobs"] = ["DiagnosePatient"]                          # 4800 gets a job: memory drops
    data["tick"] += 100
    assert h.evaluate(data).waiting == [4801]


# ---------------------------------------------------------------- acceptance 2: water unreachable
def test_refuge_without_water_source_is_reported():
    ev = H.evaluate(fx("status_refuge_no_water.json"))
    assert ev.problems == [("warn", "water_refuge",
                            "water unreachable in the refuge burrow (no drink, well or water tile)")]
    assert "water unreachable" in H.summary_line(ev)


def test_hospital_water_unreachable_is_critical_with_patients():
    data = fx("status_patients_no_surgeon.json")
    data["water"]["reach_hospital"] = False
    ev = H.evaluate(data)
    assert ("crit", "water_hospital", "water unreachable from the hospital (no well/drink reachable)") in ev.problems
    assert H.summary_line(ev).startswith("HOSPITAL: 3 patients, water unreachable from the hospital")


# ---------------------------------------------------------------- acceptance 3: plaster check in the planner
def test_plaster_needs_gypsum_class_stone():
    stock = {"splint": 0, "crutch": 2, "plaster": 0, "cloth": 10, "thread": 10, "soap": 2, "wood": 10}
    plan = plan_medical(stock, {"total": 0})
    assert not any(o.key == "plaster" for o in plan.orders) and PLASTER_IMPOSSIBLE in plan.notes
    assert plan.plaster_possible is False
    assert [o.job for o in plan.orders] == ["ConstructSplint"]
    plan = plan_medical(stock, {"total": 3, "by_mat": {"ALABASTER": 3}})
    pl = [o for o in plan.orders if o.key == "plaster"]
    assert pl and pl[0].job == "MAKE_PLASTER_POWDER" and pl[0].workshop == "Kiln" and pl[0].qty == 3
    assert PLASTER_IMPOSSIBLE not in plan.notes
    assert gypsum_count({"ALABASTER": 2, "GRANITE": 40, "satin spar": 1}) == 3     # claude/material stone list
    assert gypsum_count(None) == 0 and gypsum_count(5) == 5 and gypsum_count({"by_mat": {"MARBLE": 4}}) == 0
    nowood = plan_medical({**stock, "wood": 0}, 0)
    assert not nowood.orders and any("no wood" in n for n in nowood.notes)


def test_plan_cli_from_fixtures(capsys):
    from df_llm_helper.cli import main
    assert main(["hospital", "plan", "--file", str(FIX / "status_all_ok.json")]) == 0
    out = capsys.readouterr().out
    assert PLASTER_IMPOSSIBLE in out and "MAKE_PLASTER_POWDER" not in out
    assert main(["hospital", "plan", "--file", str(FIX / "status_alabaster.json")]) == 0
    assert "order 3x MAKE_PLASTER_POWDER (Kiln" in capsys.readouterr().out


# ---------------------------------------------------------------- acceptance 4: all ok, no wake on the second run
def _pilot(tmp_path, data):
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(1_790_840_000.0)
    m = MockClient({H.STATUS_CMD: json.dumps(data)}, clock=clock)
    return Pilot(load_config(overrides={}), m, store=Store(), clock=clock, tools=ToolsDir(tmp_path, clock)), m, clock


def test_all_ok_one_line_no_wake_on_second_run(tmp_path, capsys):
    from df_llm_helper.cli import main
    ev = H.evaluate(fx("status_all_ok.json"))
    assert ev.ok and H.summary_line(ev) == "Hospital ok (0 patients, 3 doctors)"
    p, m, clock = _pilot(tmp_path, fx("status_all_ok.json"))
    tools = ToolsDir(tmp_path, clock)
    wake_check(tools, p.store, clock)
    assert H.check_hook(p, None, False) == ["Hospital ok (0 patients, 3 doctors)"]
    clock.advance(700)
    assert H.check_hook(p, None, False) == [] and wake_check(tools, p.store, clock) == []
    assert main(["hospital", "--file", str(FIX / "status_all_ok.json")]) == 0
    assert capsys.readouterr().out.startswith("Hospital ok")


def test_state_change_wakes_once_and_resolves(tmp_path):
    p, m, clock = _pilot(tmp_path, fx("status_all_ok.json"))
    tools = ToolsDir(tmp_path, clock)
    wake_check(tools, p.store, clock)
    H.check_hook(p, None, False)
    m.set(H.STATUS_CMD, json.dumps(fx("status_posts_unfilled.json")))
    clock.advance(700)
    assert H.check_hook(p, None, False) == ["HOSPITAL: 1 patients, no staff posts filled"]
    woke = wake_check(tools, p.store, clock)
    assert len(woke) == 1 and "no staff posts filled" in woke[0]
    clock.advance(700)
    assert H.check_hook(p, None, False) == [] and wake_check(tools, p.store, clock) == []
    m.set(H.STATUS_CMD, json.dumps(fx("status_all_ok.json")))
    clock.advance(700)
    assert H.check_hook(p, None, False) == ["Hospital ok (0 patients, 3 doctors) (resolved)"]
    m.set(H.STATUS_CMD, "")
    clock.advance(700)
    assert H.check_hook(p, None, False) == []                                      # script missing: silent


# ---------------------------------------------------------------- addendum: staff posts
def test_eight_posts_unfilled_critical_and_eight_suggestions():
    data = fx("status_posts_unfilled.json")
    ev = H.evaluate(data)
    assert ev.critical and ("crit", "posts", "no staff posts filled") in ev.problems
    assert len(ev.unfilled) == 8 and len(ev.suggestions) == 8
    ids = [c["id"] for _, c in ev.suggestions]
    assert len(set(ids)) == 8 and not set(ids) & {4700, 4701, 4702, 4703, 4704, 4800}   # no soldier/miner/...
    assert ids[:3] == [4402, 4500, 4501]                                                 # best care skill first
    assert "orphaned hospital locations without a zone: [0, 3, 4, 10] (report only)" in ev.info
    assert all(p.get("location") == 11 for p, _ in ev.suggestions)


def test_all_posts_filled_ok_and_dead_holder_counts_as_unfilled():
    assert not [p for p in H.evaluate(fx("status_all_ok.json")).problems if p[1].startswith("posts")]
    ev = H.evaluate(fx("status_post_dead.json"))
    assert ("warn", "posts", "no staff posts filled") in ev.problems                  # no patients: warn only
    assert ("warn", "posts_dead", "posts held by dead units: DOCTOR #6 (unit 4390)") in ev.problems
    assert ev.unfilled[0]["id"] == 6 and ev.unfilled[0]["dead_holder"] is True
    assert ev.suggestions[0][0]["id"] == 6                                           # the dead post is refilled


def test_zone_furniture_supplies_duplicates():
    data = fx("status_patients_no_surgeon.json")
    data["hospitals"][0].update(beds=0, tables=0, containers=0)
    data["hospitals"].append({**data["hospitals"][0], "id": 3761})
    data["supplies"].update(cloth=0, thread=0)
    data["supplies"]["forbidden"]["thread"] = 4
    t = texts(H.evaluate(data))
    for want in ("hospital zone 3760 without beds", "hospital zone 3760 without a table (surgery)",
                 "hospital zone 3760 without a chest (supplies)", "supplies only forbidden: thread (unforbid them)",
                 "no cloth for the patients", "hospital zones 3760 and 3761 overlap (report only, nothing deleted)"):
        assert want in t
    data["hospitals"] = []
    assert "no hospital zone" in texts(H.evaluate(data))


# ---------------------------------------------------------------- staff --apply gate (register entry HOSPITAL)
def _staff(registry=None):
    clock = FakeClock(1_790_840_000.0)
    m = MockClient({H.STATUS_CMD: (FIX / "status_posts_unfilled.json").read_text(encoding="utf-8")}, clock=clock)
    m.prefix_handlers.append(("claude/pilot_hospital staff", lambda c: json.dumps({"ok": True, "done": "fill"})))
    m.prefix_handlers.append(("claude/pilot_care labors", lambda c: json.dumps({"ok": True, "set": ["SURGERY"]})))
    return H.Hospital(m, Store(), clock, {}, registry=registry), m


def test_staff_apply_needs_the_register(tmp_path):
    h, m = _staff()
    ev = h.evaluate(h.read())
    dry = h.staff(ev, apply=False)
    assert dry[0] == "[dry] claude/pilot_hospital staff 6 4402 --apply"
    assert dry[1] == "[dry] claude/pilot_care labors 4402 " + ",".join(H.DEFAULTS["labors"])
    assert len(dry) == 17 and not m.write_calls
    assert h.staff(ev, apply=True)[0].startswith("Refused") and not m.write_calls
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("HOSPITAL", "staff the hospital", "ja, besetz das Hospital")
    h2, m2 = _staff(reg)
    out = h2.staff(h2.evaluate(h2.read()), apply=True)
    assert len(m2.write_calls) == 16 and all(ln.startswith("ok   ") for ln in out)
    assert m2.write_calls[0] == "claude/pilot_hospital staff 6 4402 --apply"
    assert len(h2.store.actions()) == 16
    assert is_write("claude/pilot_hospital staff 6 4402 --apply") and not is_write(H.STATUS_CMD)


def test_cli_status_json_and_missing_script(monkeypatch, capsys):
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(1_790_840_000.0)
    m = MockClient({H.STATUS_CMD: (FIX / "status_posts_unfilled.json").read_text(encoding="utf-8")}, clock=clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(load_config(overrides={}), m, store=Store(), clock=clock))
    assert cli.main(["hospital", "--json"]) == 1
    j = json.loads(capsys.readouterr().out)
    assert j["critical"] is True and len(j["suggestions"]) == 8
    assert cli.main(["hospital", "staff"]) == 0
    assert "(plan only - add --apply; needs a register entry HOSPITAL)" in capsys.readouterr().out
    m.set(H.STATUS_CMD, "")
    assert cli.main(["hospital"]) == 2
    assert "pilot_hospital installed?" in capsys.readouterr().out


# ---------------------------------------------------------------- Lua under the mock
_SETUP = """
local function ident() return setmetatable({}, { __index = function(_, k) return k end }) end
df.job_skill = ident(); df.unit_labor = ident(); df.job_type = ident(); df.item_type = ident()
df.building_type = ident(); df.occupation_type = ident(); df.general_ref_type = ident()
df.abstract_building_type = { HOSPITAL = 'HOSPITAL' }
local function vec(t)
  local v = { _n = #t }
  for i, x in ipairs(t) do v[i - 1] = x end
  return setmetatable(v, { __len = function(s) return s._n end, __index = {
    insert = function(s, _, x) s[s._n] = x s._n = s._n + 1 end,
    erase = function(s, i) for k = i, s._n - 2 do s[k] = s[k + 1] end s[s._n - 1] = nil s._n = s._n - 1 end } })
end
local U = {}
local function mk(id, t)
  local u = { id = id, _name = t.name, hist_figure_id = 9000 + id, mood = t.mood or -1, _dead = t.dead,
              _child = t.child, _skill = t.skill or 0,
              status = { current_soul = { personality = { stress = t.stress or 0 } }, labors = t.labors or {} },
              status2 = { limbs_stand_count = t.cant_stand and 0 or 2 }, body = { wounds = t.wounds or {} },
              job = { current_job = t.job and { job_type = t.job } or nil }, flags1 = {},
              military = { squad_id = t.squad or -1 }, inventory = {}, pos = t.pos or { x = 50, y = 50, z = 130 },
              occupations = vec(t.occ or {}) }
  U[id] = u
  return u
end
local site_hosp = { id = 11, getType = function() return 'HOSPITAL' end }
local site_orphan = { id = 3, getType = function() return 'HOSPITAL' end }
df.global.world.world_data.active_site = { [0] = { buildings = { site_hosp, site_orphan } } }
df.global.world.buildings.other.ACTIVITY_ZONE = { { id = 3760, location_id = 11, x1 = 120, y1 = 100, x2 = 126,
                                                   y2 = 104, z = 130 } }
local function bld(t, x, y) return { getType = function() return t end, centerx = x, centery = y, z = 130 } end
df.global.world.buildings.all = { bld('Bed', 121, 101), bld('Bed', 122, 101), bld('Table', 123, 102),
                                  bld('Box', 124, 103), bld('Bed', 10, 10) }
df.global.world.buildings.other.WELL = MOCK_WELLS or { { centerx = 140, centery = 99, z = 130 } }
dfhack.maps.getWalkableGroup = function(p) return 1 end
dfhack.maps.canWalkBetween = function(a, b) return MOCK_REACH ~= false end
dfhack.maps.getTileFlags = function(x, y, z) return { hidden = (x == 99) } end
local function item(t, n, extra)
  local it = { _t = t, _n = n or 1, flags = {}, _pos = { 60, 60, 130 } }
  for k, v in pairs(extra or {}) do it[k] = v end
  it.getType = function(s) return s._t end
  it.getStackSize = function(s) return s._n end
  return it
end
local drink = item('DRINK', 5)
df.global.world.items.other.DRINK = MOCK_DRINKS or { drink }
df.global.world.items.other.IN_PLAY = {
  item('CLOTH', 3), item('THREAD', 2, { flags = { forbid = true } }), item('SPLINT', 1), item('WOOD', 7),
  item('POWDER_MISC', 1, { _mat = 'PLASTER' }), item('BAR', 1, { _mat = 'SOAP_TALLOW' }),
  item('BOULDER', 1, { _mat = 'ALABASTER' }), item('BOULDER', 1, { _mat = 'GRANITE' }),
  item('BOULDER', 1, { _mat = 'SELENITE', _pos = { 99, 1, 130 } }),                  -- hidden tile: not counted
  item('BOULDER', 1, { _mat = 'SATINSPAR', flags = { forbid = true } }) }
dfhack.items.getPosition = function(it) return it._pos[1], it._pos[2], it._pos[3] end
dfhack.matinfo.decode = function(it) return { inorganic = { id = it._mat }, material = { reaction_class = {} } } end
local doc = mk(4402, { name = 'Ast', labors = { DIAGNOSE = true, SURGERY = true }, skill = 6, pos = { x = 121, y = 101, z = 130 } })
local pat = mk(4800, { name = 'Rith', cant_stand = true, wounds = { 1, 2 }, job = 'Rest', pos = { x = 122, y = 101, z = 130 } })
local civ = mk(4600, { name = 'Kol' })
local moody = mk(4601, { name = 'Zuglar', mood = 1 })
local soldier = mk(4602, { name = 'Mafol', squad = 33 })
local dead = mk(4390, { name = 'Dead', dead = true })
dfhack.units.getCitizens = function() return { doc, pat, civ, moody, soldier, dead } end
dfhack.units.isDead = function(u) return u._dead == true end
dfhack.units.isAlive = function(u) return not u._dead end
dfhack.units.isCitizen = function() return true end
dfhack.units.isAdult = function(u) return not u._child end
dfhack.units.getEffectiveSkill = function(u, s) return s == 'DIAGNOSE' and u._skill or 0 end
df.unit.find = function(id) return U[id] end
local j1 = { job_type = 'DiagnosePatient', _patient = 4800 }
local j2 = { job_type = 'Haul' }
df.global.world.jobs.list = { next = { item = j1, next = { item = j2, next = nil } } }
dfhack.job.getGeneralRef = function(j, t) return j._patient and { unit_id = j._patient } or nil end
OCC = { { id = 6, type = 'DOCTOR', location_id = 11, unit_id = 4390, histfig_id = 9000 + 4390 },
        { id = 7, type = 'SURGEON', location_id = 11, unit_id = -1, histfig_id = -1 },
        { id = 8, type = 'TAVERN_KEEPER', location_id = 11, unit_id = -1, histfig_id = -1 },
        { id = 9, type = 'DOCTOR', location_id = 3, unit_id = -1, histfig_id = -1 } }
dead.occupations = vec({ OCC[1] })
df.global.world.occupations.all = OCC
"""
_AFTER = """
local o = OCC[1]
local d, n = df.unit.find(4390), df.unit.find(4600)
print('AFTER ' .. o.unit_id .. ' ' .. o.histfig_id .. ' ' .. #d.occupations .. ' ' .. #n.occupations)
"""


def run_hospital(tmp_path, *args, extra=""):
    setup = tmp_path / "hospital_setup.lua"
    setup.write_text(extra + _SETUP, encoding="utf-8")
    after = tmp_path / "hospital_after.lua"
    after.write_text(_AFTER, encoding="utf-8")
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_hospital.lua"), *args], capture_output=True,
                       timeout=10, env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home),
                                        "MOCK_SCRIPT_DIR": str(CLAUDE), "MOCK_SETUP": str(setup),
                                        "MOCK_AFTER": str(after)})
    assert r.returncode == 0, r.stderr.decode()
    lines = r.stdout.decode().splitlines()
    return json.loads(lines[0]), lines[-1].split()[1:], home


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_status_shape(tmp_path):
    j, after, _ = run_hospital(tmp_path, "status")
    assert j["ok"] and after == ["4390", "13390", "1", "0"]                         # read only: nothing changed
    h = j["hospitals"][0]
    assert (h["id"], h["beds"], h["tables"], h["containers"], h["water_reach"]) == (3760, 2, 1, 1, True)
    locs = {loc["id"]: loc for loc in j["locations"]}
    assert locs[3]["zones"] == 0 and locs[11]["zones"] == 1
    posts = {p["id"]: p for p in locs[11]["posts"]}
    assert set(posts) == {6, 7} and posts[6]["holder"]["alive"] is False           # tavern keeper not a post
    cits = {c["id"]: c for c in j["citizens"]}
    assert 4390 not in cits and cits[4800]["care_jobs"] == ["DiagnosePatient"] and cits[4800]["hospital"] == 3760
    assert cits[4402]["labors"] == ["DIAGNOSE", "SURGERY"] and cits[4402]["care_skill"] == 6
    assert cits[4601]["mood"] is True and cits[4602]["squad"] is True
    s = j["supplies"]
    assert (s["cloth"], s["thread"], s["forbidden"]["thread"], s["splint"], s["wood"], s["plaster"], s["soap"]) == \
        (3, 0, 2, 1, 7, 1, 1)
    assert j["gypsum"] == {"by_mat": {"ALABASTER": 1}, "forbidden": 1, "total": 1}
    assert j["care_jobs"] == {"DiagnosePatient": 1} and j["water"] == {"drinks": 5, "reach_hospital": True, "wells": 1}
    ev = H.evaluate(j)                                                              # the Python side reads it
    assert ("crit", "posts", "no staff posts filled") in ev.problems
    assert [c["id"] for _, c in ev.suggestions] == [4402, 4600]                     # not moody, soldier, patient


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_water_unreachable(tmp_path):
    j, _, _ = run_hospital(tmp_path, "status", extra="MOCK_REACH = false\n")
    assert j["hospitals"][0]["water_reach"] is False and j["water"]["reach_hospital"] is False


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_staff_dry_apply_and_refusals(tmp_path):
    j, after, _ = run_hospital(tmp_path, "staff", "6", "4600")
    assert j["dry"] is True and j["would"] == "fill" and after == ["4390", "13390", "1", "0"]
    j, after, home = run_hospital(tmp_path, "staff", "6", "4600", "--apply")
    assert j["done"] == "fill" and j["old_unit"] == 4390 and after == ["4600", "13600", "0", "1"]
    log = (home / "tools" / "out" / "hospital-log.json").read_text(encoding="utf-8")
    assert '"old_unit":4390' in log and '"new_unit":4600' in log
    for uid, why in (("4601", "in a mood"), ("4602", "soldier"), ("4800", "patient"), ("4390", "dead")):
        j, after, _ = run_hospital(tmp_path, "staff", "6", uid, "--apply")
        assert j["ok"] is False and j["error"] == f"refused: {why}" and after[0] == "4390"
    for occ in ("8", "77"):                                                         # tavern post, unknown
        j, _, _ = run_hospital(tmp_path, "staff", occ, "4600", "--apply")
        assert j["ok"] is False and j["error"].startswith("not a hospital post")
    j, _, _ = run_hospital(tmp_path, "staff", "9", "4600", "--apply")               # orphaned location
    assert j["ok"] is False and "no zone" in j["error"]
    j, _, _ = run_hospital(tmp_path, "staff", "7", "4600", "--apply")               # empty post: filled
    assert j["done"] == "fill" and j["old_unit"] == -1
