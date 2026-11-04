-- Run 15b Earthboat y385 (i3, fix14-lockdown): BUG-330 patient 26629 lay at 74,83,138 outside the alert burrow Tiefe+ for 30
-- days of a SIEGE and died of thirst while 77 caregivers stood idle in Tiefe+; the verdict named the alert only, although no
-- water was accepted at all. Now the care burrow Pflege+ (the patient's tile, the nearest accepted water, a free bucket) is
-- painted exactly and siege lists it in the alert while no hostile is near; without accepted water the verdict names both
-- causes and nothing opens. The world is test_water_m1's (wp8 world, the real water module, a fake siege with alert_names).
-- Every test fails on 9b6f614.
local C = require('dfllm.util.contract')
local T = require('testlib')
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

-- opts: patient {id, thirst, pos}, foe (a hostile's position, nil = none in sight), census (false: no hostile census),
-- well (false: no well, no accepted water), alert (default 'Tiefe+')
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
  local pt = o.patient or {5, 46000, {74, 83, 5}}
  local pu = W.unit(pt[1])
  pu.counters2.thirst_timer = pt[2]
  pu.health = {flags = {needs_healthcare = true}}
  W.move(pt[1], pt[3][1], pt[3][2], pt[3][3])
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z) return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'),
                                              dig = '', bld = ''} end})
  df.global.plotinfo.alerts.civ_alert_idx = 1
  W.load({name = 'siege', every = {ticks = 1000}, alert_names = function() return {o.alert or 'Tiefe+'} end})
  if o.well ~= false then F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5}) end
  for i = 1, 3 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  df.global.world.jobs = {list = {next = {item = {job_type = 78, id = 501}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return nil end
  W.foe = o.foe
  W.hcensus = o.census ~= false
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

-- a game day with a fresh hostile census every 100 ticks (sense's role)
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
local function logged(W, needle)
  for _, l in ipairs(W.logs) do if tostring(l.msg or ''):find(needle, 1, true) then return true end end
  return false
end
local function has_tile(tiles, x, y, z)
  for _, t in ipairs(tiles) do if t[1] == x and t[2] == y and t[3] == z then return true end end
  return false
end

T.test('BUG-330 (Earthboat y385: patient 26629 outside the alert burrow Tiefe+, 77 carers idle inside): the care burrow ' ..
       'Pflege+ gets exactly his tile, the nearest accepted water and a free bucket, water.care_rooms names it, the ' ..
       'verdict says so', function()
  local W, M = world{foe = {5, 95, 5}}                     -- a goblin 69 tiles away
  day(W)
  local a = W.find_acts('burrow_tiles')
  T.eq(#a, 1, 'old code: nothing lets the carriers out (no care burrow)')
  T.eq({a[1].args[1], a[1].args[3], a[1].args[4]}, {'Pflege+', true, true}, 'created if missing, painted exactly')
  local tiles = a[1].args[2]
  T.ok(has_tile(tiles, 74, 83, 5), 'the patient\'s tile')
  T.ok(has_tile(tiles, 20, 12, 5), 'the wet well (outside Tiefe+)')
  T.ok(has_tile(tiles, 20, 16, 5), 'the free bucket nearest to him')
  T.eq(#tiles, 3)
  T.eq(M.care_rooms(W.K), {'Pflege+'})
  T.ok(logged(W, 'care burrow Pflege+ opened to patient(s) 5 outside the alert burrow Tiefe+'), 'kern.log')
  local e = needed(W, 'patient_thirst')
  T.eq(#e, 1)
  T.eq(e[1].d.key, 'alert')
  T.ok(e[1].d.q:find('Pflege+ opened to him', 1, true), e[1].d.q)
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 1, 'the same tiles: not painted again')
  W.foe = {70, 83, 5}                                      -- 4 tiles from the patient
  day(W)
  T.eq(M.care_rooms(W.K), {}, 'a hostile near him: closed')
  T.ok(logged(W, 'care burrow Pflege+ closed: patient 5: a hostile 4 tiles from it'), 'kern.log names why')
  W.foe = {5, 95, 5}
  day(W)
  T.eq(M.care_rooms(W.K), {'Pflege+'}, 'open again')
  T.eq(#W.find_acts('burrow_tiles'), 2, 'erased and painted anew')
end)

T.test('BUG-330: no accepted water at all (Earthboat: the dry well 17700, no Water Source zone): the verdict names the ' ..
       'alert AND the missing water, nothing opens', function()
  local W, M = world{well = false, foe = {5, 95, 5}}
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0)
  T.eq(M.care_rooms(W.K), {})
  local e = needed(W, 'patient_thirst')
  T.eq(#e, 1)
  T.eq(e[1].d.key, 'alert')
  T.ok(e[1].msg:find('the civ alert holds the caregivers in Tiefe+', 1, true), e[1].msg)
  T.ok(e[1].d.q:find('and no accepted water (no well over water, no Water Source zone): nothing to carry', 1, true),
       'old code: the alert alone: ' .. e[1].d.q)
end)

T.test('BUG-330: no fresh hostile census is no safety: nothing opens; a patient inside the alert burrow or below ' ..
       'care_thirst needs none', function()
  local W, M = world{census = false}
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0)
  T.eq(M.care_rooms(W.K), {})
  local W2, M2 = world{patient = {5, 46000, {50, 50, 2}}, foe = {5, 95, 5}}     -- inside Tiefe+
  day(W2)
  T.eq(#W2.find_acts('burrow_tiles'), 0)
  local W3, M3 = world{patient = {5, 20000, {74, 83, 5}}, foe = {5, 95, 5}}     -- not thirsty yet
  day(W3)
  T.eq(#W3.find_acts('burrow_tiles'), 0)
  T.eq(M3.care_rooms(W3.K), {})
end)

T.test('BUG-330: the civ alert off closes the care burrow', function()
  local W, M = world{foe = {5, 95, 5}}
  day(W)
  T.eq(M.care_rooms(W.K), {'Pflege+'})
  df.global.plotinfo.alerts.civ_alert_idx = 0
  day(W)
  T.eq(M.care_rooms(W.K), {})
  T.ok(logged(W, 'care burrow Pflege+ closed: the civ alert is off'), 'kern.log')
end)

T.done()
