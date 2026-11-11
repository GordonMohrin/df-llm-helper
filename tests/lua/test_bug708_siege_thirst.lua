-- BUG-708 (Run 16b i2 Whirledrampart y430, main 534411e): a 200-day SIEGE lockdown, goblin army 49 outside, both wells in the core DRY, the
-- only accepted water a Water Source zone outside the walls (19-41 tiles from the hospital). 'hospital ok' stood (the zone was within near
-- 30 tiles of the hospital) and ~20 patients died of thirst; GiveWater jobs 6 open / 0 running; the carriers stood at the dry well. Now, in a
-- lockdown (SIEGE/BREACH, civ alert sounding, Kern+), an accepted source outside Kern+ / the refuge / the alert burrows / the open care
-- burrow is no water for the hospital: it is dry (the zones of a dry hospital go once a patient is over patient_thirst, the patients drink
-- from the stock), and with no source inside at all DECISION_NEEDED siege_no_water names the dry wells, the drink stock and what passes.
local T = require('testlib')
local C = require('dfllm.util.contract')
local F = require('wp8_world')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'
local FEED = 40

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'hospital_restore', 'work_detail', 'burrow_tiles'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- Kern+ is y 25..60: the hospital (10..14, 30..34) and the dry well (20,30) lie inside, the zone (30,12) outside, 18 tiles from the
-- hospital. o.mode, o.alert (civ alert sounds), o.inner (a second, wet well inside Kern+), o.thirst
local function world(o)
  o = o or {}
  owners()
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {12, 32, 5}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = 41, CUTWOOD = 42, HUNT = 43}
  local ids = {}
  for i = 1, 8 do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000}
    u.job = {current_job = nil}
    u.status = {labors = {[FEED] = i <= 4, [41] = false, [42] = false, [43] = false}}
  end
  local pu = W.unit(5)
  pu.counters2.thirst_timer = o.thirst or 40000
  pu.health = {flags = {needs_healthcare = true}}
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 25, 0, 60, 60, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.set_mode(o.mode or 'SIEGE')
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            local c = '#'
            if y == 12 and x == 30 and z == 5 then c = '~'                        -- the zone's water, outside Kern+
            elseif x == 25 and y == 30 and z == 4 and o.inner then c = '_'
            elseif x == 25 and y == 30 and z == 3 and o.inner then c = '~' end
            return {c = c, dig = '', bld = ''}
          end})
  df.global.plotinfo.alerts.civ_alert_idx = o.alert == false and 0 or 1
  W.load({name = 'siege', every = {ticks = 1000}, alert_names = function() return {'Tiefe+'} end})
  if o.drink then
    W.load({name = 'seal', every = {ticks = 100000},
            refuge_drink = function(K, which) return {name = 'Kern+', drink = o.drink, need = 70, wells = 2, wet = false} end})
  end
  W.hosp = F.hospital(W, {10, 30, 14, 34, 5})
  W.dry_well = F.building(W, 'WELL', {x1 = 20, y1 = 30, x2 = 20, y2 = 30, z = 5})
  if o.inner then F.building(W, 'WELL', {x1 = 25, y1 = 30, x2 = 25, y2 = 30, z = 5}) end
  F.building(W, 'ZONE_WATER_SOURCE', {id = 82, type = df.civzone_type.WaterSource, x1 = 30, y1 = 12, x2 = 30, y2 = 12, z = 5,
                                      spec_sub_flag = {active = true}})
  for i = 1, 4 do F.item(W, 'BUCKET', {_pos = {20, 31 + i, 5}}) end
  W.removed = {}
  W.act_result('hospital_remove', function(id) W.removed[#W.removed + 1] = id; return true, 1 end)
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  W.move(5, 12, 32, 5)
  df.global.world.jobs = {list = {next = {item = {job_type = 78, id = 501}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return nil end
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, (n or 1) * 12 do W.run(100, {skip = 100}) end end
local function needed(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end

T.test('BUG-708 (Whirledrampart y430): SIEGE lockdown, the core well dry, the only wet zone outside Kern+ 18 tiles off: the hospital is DRY ' ..
       '(old code: ok), its zone goes for the patient at thirst 40,000', function()
  local W = world{}
  day(W)
  T.eq(W.state().water.hosp_ok, 0, 'old code: hosp_ok 1 (the zone lies within near 30)')
  T.eq(W.removed, {W.hosp.id}, 'the dry hospital zone is removed: the patient drinks from the stock')
end)

T.test('BUG-708: the decision siege_no_water names the dry well, the water outside, the drink stock and what passes; once, then weekly',
       function()
  local W = world{drink = 1539}
  day(W)
  local d = needed(W, 'siege_no_water')
  T.eq(#d, 1)
  T.eq(d[1].cls, 'A')
  local q = d[1].d.q
  T.ok(q:find('well ' .. W.dry_well.id, 1, true) and q:find('dry', 1, true), q)
  T.ok(q:find('zone 82', 1, true) and q:find('outside', 1, true), q)
  T.ok(q:find('1539', 1, true), q)
  T.ok(d[1].d.how:find('BUG-469', 1, true) and d[1].d.how:find('aquifer', 1, true), d[1].d.how)
  T.eq(d[1].d.drink, 1539)
  T.ok(d[1].d.cmds[1]:find('inspect what=water_sources', 1, true), d[1].d.cmds[1])
  day(W, 3)
  T.eq(#needed(W, 'siege_no_water'), 1, 'not again within the week')
  day(W, 6)
  T.eq(#needed(W, 'siege_no_water'), 2, 'again after siege_water_every')
end)

T.test('BUG-708: PEACE (no lockdown): the zone 18 tiles off still serves the hospital, nothing is removed, no decision', function()
  local W = world{mode = 'PEACE', alert = false}
  day(W)
  T.eq(W.state().water.hosp_ok, 1)
  T.eq(W.removed, {})
  T.eq(#needed(W, 'siege_no_water'), 0)
end)

T.test('BUG-708: a wet well inside Kern+ keeps the hospital ok in the SIEGE, no decision, nothing removed', function()
  local W = world{inner = true}
  day(W)
  T.eq(W.state().water.hosp_ok, 1)
  T.eq(W.removed, {})
  T.eq(#needed(W, 'siege_no_water'), 0)
end)

T.test('BUG-708: the siege ends (PEACE, alert off): the stale episode clears and a new lockdown asks at once again', function()
  local W = world{}
  day(W)
  T.eq(#needed(W, 'siege_no_water'), 1)
  W.set_mode('PEACE')
  df.global.plotinfo.alerts.civ_alert_idx = 0
  day(W, 2)
  W.set_mode('SIEGE')
  df.global.plotinfo.alerts.civ_alert_idx = 1
  day(W, 1)
  T.eq(#needed(W, 'siege_no_water'), 2, 'p.sw was cleared in PEACE')
end)
