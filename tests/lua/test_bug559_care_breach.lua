-- Run 16b i2 Brotherarrow y402 (BUG-559): a cave dragon BREACH; the new hospital (100,103-106,133) lay on Kern+ but outside the
-- alert burrow Tiefe+, 47 caregivers stood inside Tiefe+, the care burrow Pflege+ was closed in BREACH ('nobody is drawn out
-- toward a seal') and 3 patients died of thirst (58,000-60,000 at the start, GiveWater 'noeffect'). Now the care burrow opens
-- in BREACH for a patient on Kern+ while every hostile is care_breach_near (30) tiles off, and a patient it does not reach is a
-- DECISION_NEEDED patient_out (urgent). The world is test_bug330_care_burrow's.
local T = require('testlib')
local C = require('dfllm.util.contract')
local F = require('wp8_world')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'
local FEED = 40

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'work_detail', 'burrow_tiles'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

local function world(o)
  o = o or {}
  owners()
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {50, 50, 2}} end
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
  local pt = o.patient or {5, 58000, {30, 30, 5}}
  local pu = W.unit(pt[1])
  pu.counters2.thirst_timer = pt[2]
  pu.health = {flags = {needs_healthcare = true}}
  W.move(pt[1], pt[3][1], pt[3][2], pt[3][3])
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', o.kern or {0, 0, 0, 60, 60, 20})
  W.set_mode(o.mode or 'BREACH')
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'),
                    dig = '', bld = ''} end})
  df.global.plotinfo.alerts.civ_alert_idx = 1
  W.load({name = 'siege', every = {ticks = 1000}, alert_names = function() return {'Tiefe+'} end})
  F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  for i = 1, 3 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  df.global.world.jobs = {list = {next = {item = {job_type = 78, id = 501}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return nil end
  W.foe = o.foe
  W.hcensus = true
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n)
  for _ = 1, (n or 1) * 12 do
    if W.hcensus then
      local list = {}
      if W.foe then list[1] = {id = 900, x = W.foe[1], y = W.foe[2], z = W.foe[3], k = 'inv', d_o1 = 50, dc = 50} end
      W.set_census('h', {tick = W.K.now().tick, vis = #list, inv = #list, inside = 0, list = list})
    end
    W.run(100, {skip = 100})
  end
end

local function needed(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function has_tile(tiles, x, y, z)
  for _, t in ipairs(tiles) do if t[1] == x and t[2] == y and t[3] == z then return true end end
  return false
end
local function see(W, x, y, z)
  W.set_census('h', {tick = W.K.now().tick, vis = 1, inv = 1, inside = 0,
                     list = {{id = 900, x = x, y = y, z = z, k = 'inv', d_o1 = 50, dc = 50}}})
end

T.test('BUG-559 (Brotherarrow y402): BREACH, the patient on Kern+ outside the alert burrow, the dragon 60 tiles off: the ' ..
       'care burrow opens with his tile, the well and a bucket; no patient_out decision', function()
  local W, M = world{foe = {5, 95, 5}}
  day(W)
  local a = W.find_acts('burrow_tiles')
  T.eq(#a, 1, 'old code: nothing opens in BREACH')
  T.ok(has_tile(a[1].args[2], 30, 30, 5) and has_tile(a[1].args[2], 20, 12, 5), 'his tile and the well')
  T.eq(M.care_rooms(W.K), {'Pflege+'})
  T.eq(#needed(W, 'patient_out'), 0)
end)

T.test('BUG-559: a hostile within 30 tiles of a care tile keeps it closed in BREACH; SIEGE keeps care_near 20; a ' ..
       'SIEGE -> BREACH change keeps an open one while the hostile is far', function()
  local W, M = world{foe = {30, 55, 5}}                    -- 25 tiles from the patient
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0, 'BREACH: 25 < 30')
  T.eq(M.care_rooms(W.K), {})
  local W2, M2 = world{foe = {30, 55, 5}, mode = 'SIEGE'}
  day(W2)
  T.eq(M2.care_rooms(W2.K), {'Pflege+'}, 'SIEGE: 25 > care_near 20')
  W2.set_mode('BREACH')
  see(W2, 30, 55, 5)
  T.eq(M2.care_rooms(W2.K), {}, 'the BREACH distance (30) closes it at once')
  local W3, M3 = world{foe = {5, 95, 5}, mode = 'SIEGE'}
  day(W3)
  T.eq(M3.care_rooms(W3.K), {'Pflege+'})
  W3.set_mode('BREACH')
  see(W3, 5, 95, 5)
  T.eq(M3.care_rooms(W3.K), {'Pflege+'}, 'SIEGE -> BREACH with the hostile far: stays open')
end)

T.test('BUG-559: a patient outside Kern+ in BREACH gets no care burrow, and a DECISION_NEEDED patient_out names it', function()
  local W, M = world{foe = {5, 95, 5}, patient = {5, 58000, {74, 83, 5}}}
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0)
  local e = needed(W, 'patient_out')
  T.eq(#e, 1, 'old code: PATIENTS_OUT only, no decision')
  T.eq(e[1].d.units, {5})
  T.ok(e[1].d.q:find('outside Tiefe+', 1, true) and e[1].d.q:find('outside Kern+', 1, true), e[1].d.q)
  T.ok(#e[1].d.cmds >= 3)
  day(W)
  T.eq(#needed(W, 'patient_out'), 1, 'once per fight')
end)

T.done()
