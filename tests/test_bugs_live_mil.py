"""Live test 2026-10-02/03, military and alarm: BUG-423 (civilian alert livelock, prisoners, refuge supply), BUG-425 (mil add/create),
BUG-426 (kill orders on caged units, starving squads). Lua parts run under tests/lua_mock/claude_mock.lua (needs lua5.4)."""
import json
import time

import pytest

from df_llm_helper.siege import DEFAULTS, SiegeFlow, obs_from_status
from df_llm_helper.snapshot import Snapshot, _parse_gefahr
from test_lua_claude import CLAUDE, LUA, run, run_snippet

lua = pytest.mark.skipif(not LUA or not CLAUDE.is_dir(), reason="lua5.4 or lua/claude missing")

# ---------------------------------------------------------------- common mock world
# One enemy (invader) at (100,100,100) next to the fort centre (96/96/100 = neutral config default), alarm 1 with the refuge
# burrow 5 ('Zuflucht' = tiles x 90..110), optional supply. ENEMY_FLAGS / ENEMY_CONTAINER / N_ENEMIES / SUPPLY are set per test.
WORLD = """
df.global.enabler.fps = 100
local function vec(t)
  t = t or {}
  return setmetatable(t, { __len = function(v) local k = 0 while rawget(v, k) ~= nil do k = k + 1 end return k end,
    __index = { insert = function(v, _, x) v[#v] = x end,
                erase = function(v, i) local n = #v for k = i, n - 2 do v[k] = v[k + 1] end v[n - 1] = nil end } })
end
VEC = vec
BURROW = { id = 5, name = 'Zuflucht' }
df.global.plotinfo.alerts = { civ_alert_idx = 0, list = vec({ [0] = { name = 'inactive', burrows = vec() },
                                                             [1] = { name = 'civ-alert', burrows = vec({ [0] = 5 }) } }) }
dfhack.burrows.findByName = function(name) if name == 'Zuflucht' then return BURROW end end
dfhack.burrows.isAssignedTile = function(b, p) return p.x >= 90 and p.x <= 110 and p.y >= 90 and p.y <= 110 end
dfhack.units.getCitizens = function() return {} end
dfhack.units.isActive = function() return true end
dfhack.units.isDead = function(u) return u.dead == true end
dfhack.units.isAlive = function(u) return u.dead ~= true end
dfhack.units.isCitizen = function(u) return u.citizen == true end
dfhack.units.isTame = function() return false end
dfhack.units.isInvader = function(u) return u.invader == true end
dfhack.units.isDanger = function(u) return u.invader == true end
dfhack.units.isGreatDanger = function() return false end
dfhack.units.isAgitated = function() return false end
dfhack.units.isCrazed = function() return false end
dfhack.units.isWildlife = function() return false end
dfhack.units.isVisitor = function() return false end
dfhack.units.isMerchant = function() return false end
dfhack.units.isPet = function() return false end
dfhack.units.isFortControlled = function() return false end
dfhack.units.casteFlagSet = function() return false end
dfhack.units.getContainer = function(u) return u.container end
local col = setmetatable({}, { __index = function() return { hidden = false } end })
dfhack.maps.getTileBlock = function() return { designation = setmetatable({}, { __index = function() return col end }) } end
UNITS = {}
local function enemy(id, x)
  return { id = id, pos = { x = x, y = 100, z = 100 }, invader = true, race = 1, caste = 0, hist_figure_id = 1000 + id, profession = 0,
           flags1 = {}, flags2 = {}, body = { size_info = { size_cur = 60000 } }, _name = 'Goblin ' .. id }
end
for i = 1, (N_ENEMIES or 1) do UNITS[#UNITS + 1] = enemy(i, 100 + i % 5) end
for k, v in pairs(ENEMY_FLAGS or {}) do UNITS[1].flags1[k] = v end
if ENEMY_CONTAINER then UNITS[1].container = { id = 77 } end
df.global.world.units.active = UNITS
df.unit.find = function(id) for _, u in ipairs(UNITS) do if u.id == id then return u end end end
dfhack.items.getPosition = function(it) return it.pos end
dfhack.items.getContainer = function(it) return it.container end
if SUPPLY then
  local barrel = { flags = {} }
  df.global.world.items.other.DRINK = { { flags = {}, pos = { x = 95, y = 95, z = 100 }, container = barrel } }
  df.global.world.items.other.FOOD = { { flags = {}, pos = { x = 96, y = 95, z = 100 } } }
end
if FORBIDDEN_SUPPLY then
  df.global.world.items.other.DRINK = { { flags = { forbid = true }, pos = { x = 95, y = 95, z = 100 } } }
end
if REQUIRE_WATER ~= nil then reqscript('claude/config').REFUGE_REQUIRE_WATER = REQUIRE_WATER end
SCHED = {}
package.loaded['repeat-util'].scheduleEvery = function(key, n, unit, fn) SCHED[key] = fn end
"""

# After `claude/watchdog start`: run the alert job for CYCLES cycles; between the cycles the orchestrator switches the alert off
# (only the index, like a stale UI click) when RESET is set; prints the civ alert index after each cycle.
CYCLES = """
local al = df.global.plotinfo.alerts
local out = {}
for i = 1, 3 do
  SCHED['claude-watchdog-alert']()
  out[#out + 1] = tostring(al.civ_alert_idx)
  if RESET then al.civ_alert_idx = 0 end
  df.global.cur_year_tick = df.global.cur_year_tick + 100
end
print('CIV ' .. table.concat(out, ' '))
local G = reqscript('claude/gefahr')
local ok, why, info = G.civ_gate(#UNITS, 0)
print('GATE ' .. tostring(ok) .. ' ' .. tostring(why) .. ' ' .. tostring(info.manual_off_until))
"""


def world(tmp_path, **kw):
    pre = "".join(f"{k} = {v}\n" for k, v in kw.items())
    return pre + WORLD


def after(tmp_path, code):
    f = tmp_path / "after.lua"
    f.write_text(code, encoding="utf-8")
    return {"MOCK_AFTER": str(f)}


def cycles(tmp_path, manual_off=None, **kw):
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    if manual_off is not None:                       # `claude/alert off` was given with this many enemies near
        (home / "tools" / "alert-manual-off.flag").write_text(f"{int(time.time())} {manual_off} 0\n")
    out, r = run("watchdog", "start", tmp_path=tmp_path, setup=world(tmp_path, **kw), env=after(tmp_path, CYCLES))
    assert r.returncode == 0, r.stderr.decode()
    lines = out.splitlines()
    civ = next(x for x in lines if x.startswith("CIV ")).split()[1:]
    gate = next(x for x in lines if x.startswith("GATE ")).split()[1:]
    return civ, gate, home / "tools"


# ---------------------------------------------------------------- BUG-423
@lua
def test_bug423_manual_off_holds_against_the_watchdog(tmp_path):
    civ, gate, tools = cycles(tmp_path, manual_off=1, SUPPLY="true", RESET="true")
    assert civ == ["0", "0", "0"]                    # 3 cycles with the enemy in range: the alert stays off
    assert gate[:2] == ["false", "manual_off"] and gate[2] != "nil"     # manual_off_until is reported


@lua
def test_bug423_without_manual_off_the_watchdog_still_calls_civilians_in(tmp_path):
    civ, gate, tools = cycles(tmp_path, SUPPLY="true")
    assert civ == ["1", "1", "1"] and gate[0] == "true"
    assert not (tools / "notfall.flag").exists()


@lua
def test_bug423_manual_off_yields_when_many_more_enemies_come(tmp_path):
    civ, gate, _ = cycles(tmp_path, manual_off=1, SUPPLY="true", N_ENEMIES=8)
    assert civ[0] == "1" and gate[0] == "true"       # 8 > 1 + ALERT_MANUAL_GROW (5)


@lua
@pytest.mark.parametrize("kw", [{}, {"FORBIDDEN_SUPPLY": "true"}])
def test_bug423_refuge_without_water_is_not_used_and_reported(tmp_path, kw):
    civ, gate, tools = cycles(tmp_path, REQUIRE_WATER="true", **kw)
    assert civ == ["0", "0", "0"] and gate[:2] == ["false", "refuge_no_water"]
    assert "ZUFLUCHT OHNE WASSER" in (tools / "notfall.flag").read_text()


@lua
@pytest.mark.parametrize("kw", [{"ENEMY_FLAGS": "{ caged = true }"}, {"ENEMY_FLAGS": "{ chained = true }"},
                                {"ENEMY_CONTAINER": "true"}])
def test_bug423_prisoner_does_not_keep_the_alert_on(tmp_path, kw):
    civ, _, tools = cycles(tmp_path, SUPPLY="true", **kw)
    assert civ == ["0", "0", "0"]
    assert not (tools / "alert.flag").exists() and not (tools / "notfall.flag").exists()


@lua
def test_bug423_selftest_reports_the_unsupplied_refuge(tmp_path):
    out, r = run("gefahr", "status", tmp_path=tmp_path, setup=world(tmp_path))
    j = json.loads(out)
    assert any(p.startswith("ZUFLUCHT OHNE WASSER") for p in j["selbsttest"])
    assert any(p.startswith("ZUFLUCHT OHNE ESSEN") for p in j["selbsttest"])
    assert j["refuge"]["supply"]["ok"] is False and j["refuge"]["supply"]["missing"][:2] == ["water", "food"]
    out, r = run("gefahr", "status", tmp_path=tmp_path, setup=world(tmp_path, SUPPLY="true"))
    j = json.loads(out)
    assert not [p for p in j["selbsttest"] if p.startswith("ZUFLUCHT")]
    sup = j["refuge"]["supply"]
    assert sup["ok"] is True and sup["drink"] == 1 and sup["food"] == 1


@lua
def test_bug423_mil_refuge_check_is_read_only(tmp_path):
    out, r = run("mil", "refuge", "check", tmp_path=tmp_path, setup=world(tmp_path))
    j = json.loads(out)
    assert j["refuge"]["water_ok"] is False and j["require_water"] is False          # default: alert on + warning
    assert any("ZUFLUCHT OHNE WASSER" in p for p in j["refuge"]["problems"])


@lua
def test_bug423_alert_off_writes_the_hold_and_on_clears_it(tmp_path):
    out, r = run("alert", "off", tmp_path=tmp_path, setup=world(tmp_path, SUPPLY="true"))
    assert r.returncode == 0, r.stderr.decode()
    j = json.loads(out)
    flag = tmp_path / "home" / "tools" / "alert-manual-off.flag"
    assert flag.exists() and flag.read_text().split()[1:] == ["1", "0"]
    assert j["manual_off_until"] and j["enemies_near"] == 1 and j["refuge_supply"]["ok"] is True
    out, r = run("alert", "on", tmp_path=tmp_path, setup=world(tmp_path, SUPPLY="true"))
    assert not flag.exists()


@lua
def test_bug423_ueberwacher_names_the_real_cause(tmp_path):
    # fake clock: every os.time() call is 200 s later, so the alert counts as 'on for > 3 min' within one check
    setup = (world(tmp_path) + "df.global.plotinfo.alerts.civ_alert_idx = 1\n"
             "reqscript('claude/config').rt.enemies_near = 3\n"
             "local t = os.time() os.time = function() t = t + 200 return t end\n")
    out, r = run("ueberwacher", "once", tmp_path=tmp_path, setup=setup)
    assert r.returncode == 0, r.stderr.decode()
    txt = (tmp_path / "home" / "tools" / "notfall.flag").read_text()
    assert "ZIVILWARNUNG seit > 3 Min AN: 3 Feinde in ALERT_RANGE" in txt
    assert "Watchdog neu starten" not in txt


def test_bug423_snapshot_marks_an_unsupplied_refuge_not_ok():
    s = Snapshot()
    _parse_gefahr(s, {"alarm": 1, "refuge": {"ok": True, "supply": {"ok": False, "problems": ["ZUFLUCHT OHNE WASSER: x"]}}})
    assert s.alerts.refuge_ok is False and s.alerts.refuge_problems == ["ZUFLUCHT OHNE WASSER: x"]
    s = Snapshot()
    _parse_gefahr(s, {"alarm": 0, "refuge": {"ok": True, "supply": {"ok": True, "problems": []}}})
    assert s.alerts.refuge_ok is True and s.alerts.refuge_problems == []


# ---------------------------------------------------------------- BUG-425
SQUADS = """
df.global.plotinfo.group_id = 7
local function vec(t)
  t = t or {}
  return setmetatable(t, { __len = function(v) local k = 0 while rawget(v, k) ~= nil do k = k + 1 end return k end,
    __index = { insert = function(v, _, x) v[#v] = x end } })
end
local function squad(id, occ)
  local pos = {}
  for i = 0, 9 do pos[i] = { occupant = occ[i] or -1, equipment = {} } end
  return { id = id, entity_id = 7, positions = vec(pos), orders = vec(), alias = '' }
end
HF = { [500] = { id = 500, unit_id = 50 }, [600] = { id = 600, unit_id = 60 } }   -- 900: orphaned histfig (no unit)
SQ = { [3] = squad(3, { [0] = 900, [1] = 500 }), [4] = squad(4, { [0] = 600, [1] = 500, [2] = 500, [3] = 500, [4] = 500, [5] = 500,
       [6] = 500, [7] = 500, [8] = 500, [9] = 500 }), [5] = squad(5, {}) }
df.global.plotinfo.main.fortress_entity.squads = { 3, 4, 5 }
df.squad.find = function(id) return SQ[id] end
df.historical_figure.find = function(id) return HF[id] end
local function cit(id, sq) return { id = id, hist_figure_id = id * 10, military = { squad_id = sq or -1 }, status = { labors = {} }, citizen = true } end
U = { [50] = cit(50, 3), [60] = cit(60, 4), [70] = cit(70) }
df.unit.find = function(id) return U[id] end
dfhack.units.isCitizen = function(u) return u.citizen end
dfhack.units.isChild = function() return false end
dfhack.units.isDead = function() return false end
dfhack.military.getSquadName = function(id) return 'Trupp ' .. id end
ADDS = {}
dfhack.military.addToSquad = function(uid, sid, slot)
  ADDS[#ADDS + 1] = slot
  if slot == -1 or slot == 0 then return false end        -- live: the empty/orphaned leader slot refuses
  SQ[sid].positions[slot].occupant = U[uid].hist_figure_id
  return true
end
"""


@lua
def test_bug425_add_uses_an_explicit_free_slot_and_reports_it(tmp_path):
    out, r = run("mil", "add", 3, 70, "--apply", tmp_path=tmp_path, setup=SQUADS,
                 env=after(tmp_path, "print('ADDS ' .. table.concat(ADDS, ','))"))
    assert r.returncode == 0, r.stderr.decode()
    lines = out.splitlines()
    j = json.loads(lines[0])
    assert j["ok"] is True and j["slot"] == 2 and j["orphaned_slots"] == [0]
    assert lines[1] == "ADDS 2"                       # never -1


@lua
@pytest.mark.parametrize("squad,unit,reason", [(4, 70, "squad full"), (3, 50, "unit already in this squad"),
                                               (4, 50, "unit already in squad 3")])
def test_bug425_add_failure_always_has_a_reason(tmp_path, squad, unit, reason):
    out, r = run("mil", "add", squad, unit, "--apply", tmp_path=tmp_path, setup=SQUADS)
    j = json.loads(out)
    assert j["ok"] is False and j["reason"].startswith(reason)


@lua
def test_bug425_add_reports_refusal_of_every_slot(tmp_path):
    setup = SQUADS + "dfhack.military.addToSquad = function() return false end\n"
    out, r = run("mil", "add", 5, 70, "--apply", tmp_path=tmp_path, setup=setup)
    j = json.loads(out)
    assert j["ok"] is False and "addToSquad refused" in j["reason"]


@lua
def test_bug425_add_dry_run_shows_the_slot(tmp_path):
    out, r = run("mil", "add", 3, 70, tmp_path=tmp_path, setup=SQUADS)
    j = json.loads(out)
    assert j["dry"] is True and j["slot"] == 2 and "ok" not in j


CREATE = SQUADS + """
local function vec(t)
  t = t or {}
  return setmetatable(t, { __len = function(v) local k = 0 while rawget(v, k) ~= nil do k = k + 1 end return k end,
    __index = { insert = function(v, _, x) v[#v] = x end, erase = function() end } })
end
ENT = { id = 7, positions = { own = vec({ [0] = { code = 'MILITIA_CAPTAIN', id = 11, responsibilities = {} } }),
        next_assignment_id = 40, assignments = vec() }, assignments_by_type = {} }
df.historical_entity.find = function() return ENT end
df.entity_position_assignment = { new = function() return {} end }
dfhack.military.makeSquad = function() local s = { id = 9, name = {}, positions = vec({ [0] = { occupant = -1, equipment = {} } }), orders = vec() } SQ[9] = s return s end
HF[700] = { id = 700, entity_links = vec() }
"""


@lua
def test_bug425_create_always_returns_the_squad_id(tmp_path):
    out, r = run("mil", "create", "Wache", 70, "--apply", tmp_path=tmp_path, setup=CREATE)
    assert r.returncode == 0, r.stderr.decode()
    j = json.loads(out)
    assert j["squad_id"] == 9 and j["squad"] == 9 and j["ok"] is True
    assert j["reuse_hint"]["empty_squads"] == [{"id": 5, "name": "Trupp 5"}]
    # a later step fails (no histfig): the squad exists anyway -> id + warning instead of a bare error
    out, r = run("mil", "create", "Wache", 70, "--apply", tmp_path=tmp_path, setup=CREATE + "HF[700] = nil\n")
    j = json.loads(out)
    assert j["squad_id"] == 9 and j["ok"] is False and "Trupp angelegt" in j["warning"]


@lua
def test_bug425_rename_reuses_an_empty_squad(tmp_path):
    out, r = run("mil", "rename", 5, "Wache", "--apply", tmp_path=tmp_path, setup=SQUADS,
                 env=after(tmp_path, "print('ALIAS ' .. SQ[5].alias)"))
    lines = out.splitlines()
    assert json.loads(lines[0])["ok"] is True and lines[1] == "ALIAS Wache"


# ---------------------------------------------------------------- BUG-426
KILL = WORLD + """
df.global.plotinfo.group_id = 7
local function cit(id, thirst, hunger)
  return { id = id, hist_figure_id = id, citizen = true, flags1 = {}, flags2 = {}, pos = { x = 96, y = 96, z = 99 },
           counters2 = { thirst_timer = thirst or 0, hunger_timer = hunger or 0 }, inventory = {}, job = {} }
end
SOLDIERS = { [60] = cit(60), [61] = cit(61, STARVE and 48000 or 0, STARVE and 71000 or 0) }
local find_enemy = df.unit.find
df.unit.find = function(id) return SOLDIERS[id] or find_enemy(id) end
df.historical_figure.find = function(id) if SOLDIERS[id] then return { id = id, unit_id = id } end end
local function squad(id, occ)
  local pos = {}
  for i = 0, 9 do pos[i] = { occupant = occ[i] or -1, equipment = { assigned_items = {}, uniform = { body = {}, head = {}, pants = {},
    gloves = {}, shoes = {}, shield = {}, weapon = {} } } } end
  return { id = id, entity_id = 7, positions = VEC(pos), orders = VEC() }
end
SQ = { [45] = squad(45, { [0] = 60 }), [46] = squad(46, { [0] = 61 }) }
df.global.plotinfo.main.fortress_entity.squads = { 45, 46 }
df.squad.find = function(id) return SQ[id] end
dfhack.military.getSquadName = function(id) return 'Trupp ' .. id end
local KL = {}
KL.__index = KL
KL.getType = function() return 'KILL' end
df.squad_order_kill_listst = { new = function() return setmetatable({ units = VEC(), histfigs = VEC() }, KL) end,
                               is_instance = function(_, o) return getmetatable(o) == KL end }
if OLD_ORDER then                        -- an order from before the fix: kill the caged enemy 1
  for _, s in pairs(SQ) do
    local o = df.squad_order_kill_listst.new() o.units:insert('#', 1) o.histfigs:insert('#', 1001) s.orders:insert('#', o)
  end
end
-- interior = the whole test area
local cfg = reqscript('claude/config')
cfg.INNEN_BOXEN = { { name = 'Fort', x1 = 0, x2 = 200, y1 = 0, y2 = 200, z1 = 0, z2 = 200 } }
"""
ORDERS = "for _, id in ipairs({45, 46}) do print('ORD ' .. id .. ' ' .. #SQ[id].orders .. ' ' .. (#SQ[id].orders > 0 and #SQ[id].orders[0].units or 0)) end\n"


def orders(out):
    return {int(x.split()[1]): (int(x.split()[2]), int(x.split()[3])) for x in out.splitlines() if x.startswith("ORD ")}


@lua
@pytest.mark.parametrize("kw", [{"ENEMY_FLAGS": "{ caged = true }"}, {"ENEMY_FLAGS": "{ chained = true }"},
                                {"ENEMY_CONTAINER": "true"}])
def test_bug426_no_kill_order_on_a_caged_enemy(tmp_path, kw):
    pre = "".join(f"{k} = {v}\n" for k, v in kw.items())
    out, r = run("killorder", tmp_path=tmp_path, setup=pre + KILL, env=after(tmp_path, ORDERS))
    assert r.returncode == 0, r.stderr.decode()
    assert "keine Ziele" in out and orders(out) == {45: (0, 0), 46: (0, 0)}


@lua
def test_bug426_free_enemy_gets_a_kill_order(tmp_path):
    out, r = run("killorder", tmp_path=tmp_path, setup=KILL, env=after(tmp_path, ORDERS))
    assert r.returncode == 0, r.stderr.decode()
    assert orders(out) == {45: (1, 1), 46: (1, 1)}


@lua
def test_bug426_existing_order_on_a_caged_unit_is_removed(tmp_path):
    pre = "ENEMY_FLAGS = { caged = true }\nOLD_ORDER = true\n"
    code = ("local K = reqscript('claude/killorder')\n"
            "print('SCRUB ' .. K.scrub_orders())\n" + ORDERS)
    out, r = run("killorder", "--unwatch", tmp_path=tmp_path, setup=pre + KILL, env=after(tmp_path, code))
    assert r.returncode == 0, r.stderr.decode()
    assert "SCRUB 2" in out and orders(out) == {45: (0, 0), 46: (0, 0)}
    log = (tmp_path / "home" / "tools" / "out" / "killorder.log").read_text()
    assert "Ziel 1 entfernt (gefangen)" in log


@lua
def test_bug426_starving_squad_gets_no_order_and_loses_the_old_one(tmp_path):
    pre = "STARVE = true\nOLD_ORDER = true\n"
    out, r = run("killorder", tmp_path=tmp_path, setup=pre + KILL, env=after(tmp_path, ORDERS))
    assert r.returncode == 0, r.stderr.decode()
    o = orders(out)
    assert o[46] == (0, 0)                         # 61 is thirsty/hungry: no kill order, the old one is gone
    assert o[45] == (1, 1)                         # the fed squad fights
    assert "KEIN Kill-Befehl" in out


@lua
def test_bug426_relieve_starving_drops_orders_from_the_guard(tmp_path):
    pre = "STARVE = true\nOLD_ORDER = true\n"
    code = "local K = reqscript('claude/killorder') print('RELIEVED ' .. K.relieve_starving())\n" + ORDERS
    out, r = run("killorder", "--unwatch", tmp_path=tmp_path, setup=pre + KILL, env=after(tmp_path, code))
    assert "RELIEVED 1" in out and orders(out)[46] == (0, 0) and orders(out)[45] == (1, 1)


@lua
def test_bug426_mil_kill_skips_a_caged_unit(tmp_path):
    pre = "ENEMY_FLAGS = { caged = true }\nN_ENEMIES = 2\n"
    out, r = run("mil", "kill", 45, "1,2", tmp_path=tmp_path, setup=pre + KILL)
    j = json.loads(out)
    assert 1 not in j.get("targets", []) and "1" in j.get("skipped", "")


def test_bug426_siege_flow_ignores_prisoners_and_feeds_starving_soldiers():
    j = {"invaders": [{"id": 1, "dist": 5, "caged": True}, {"id": 2, "dist": 5}], "civ_alert": 1,
         "squads": [{"id": 33, "name": "Wache", "orders": 0,
                     "members": [{"id": 7, "alive": True, "blood_pct": 100, "thirst": 0, "hunger": 0}]}]}
    o = obs_from_status(j, "Wache")
    assert [i["id"] for i in o.invaders] == [2]
    f = SiegeFlow(cfg=dict(DEFAULTS))
    cmds = f.step(o)
    assert "claude/pilot_siege kill 33 2" in cmds
    j["squads"][0]["orders"] = 1
    j["squads"][0]["members"][0]["thirst"] = 48000
    cmds = f.step(obs_from_status(j, "Wache"))
    assert "claude/pilot_siege clear 33" in cmds and not [c for c in cmds if " kill " in c]
    assert any("hungry/thirsty" in n for n in f.notify)


@lua
def test_bug426_pilot_siege_lists_no_caged_invader(tmp_path):
    from test_lua_claude import MOCK, ROOT
    import subprocess
    setup = tmp_path / "s.lua"
    setup.write_text("ENEMY_FLAGS = { caged = true }\nN_ENEMIES = 2\n" + WORLD
                     + "df.global.plotinfo.main.fortress_entity.squads = {}\n", encoding="utf-8")
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_siege.lua"), "status"], capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home), "MOCK_SETUP": str(setup),
                            "MOCK_SCRIPT_DIR": str(CLAUDE)}, timeout=10)
    assert r.returncode == 0, r.stderr
    j = json.loads(r.stdout.splitlines()[0])
    assert [i["id"] for i in j["invaders"]] == [2]


@lua
def test_bug423_default_unsupplied_refuge_still_calls_civilians_in_with_a_warning(tmp_path):
    """Default REFUGE_REQUIRE_WATER = false: during a siege the citizens are still called in; the missing water is reported."""
    civ, gate, tools = cycles(tmp_path)
    assert civ == ["1", "1", "1"] and gate[0] == "true"
    out, _ = run("gefahr", "status", tmp_path=tmp_path, setup=world(tmp_path))
    assert any(p.startswith("ZUFLUCHT OHNE WASSER") for p in json.loads(out)["selbsttest"])
