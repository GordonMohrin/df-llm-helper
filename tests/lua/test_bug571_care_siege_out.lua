-- BUG-571 (Run 16b i2 Brotherarrow y406: patient 27722 of the Deepcore hospital at 100,106,133 died of thirst in a 115-day SIEGE; the
-- only accepted water, the pond zone 17696 at 102,108,138, lay one level above Kern+ (z122-137) and water.care_step wanted every
-- patient, water and bucket tile on Kern+: DECISION patient_thirst 'every accepted water outside the alert burrows has a hostile near it
-- or lies outside Kern+', PATIENT_DYING, no hand option). In a SIEGE the care burrow now reaches water / bucket tiles outside Kern+ when
-- seal's entrance check says the fort is sealed, the tile lies on the citizens' walk groups (snapshot.far false) and no visible hostile
-- is within care_siege_near (40) tiles of it. The world is test_bug559_care_breach's with Kern+ shrunk so that the well lies outside it.
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

-- o.sealed (seal.groups().sealed), o.far (snapshot.far answers true: the tile is outside the walls), o.foe {x, y, z}, o.mode
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
  local pu = W.unit(5)
  pu.counters2.thirst_timer = 58000
  pu.health = {flags = {needs_healthcare = true}}
  W.move(5, 30, 30, 5)
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 25, 0, 60, 60, 20})                    -- the pond below lies OUTSIDE it (y 12)
  W.set_mode(o.mode or 'SIEGE')
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          far = function(K, x, y, z) return o.far == true end,
          tile = function(K, x, y, z)
            return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'),
                    dig = '', bld = ''} end})
  W.sealed = o.sealed ~= false
  W.load({name = 'seal', every = {ticks = 100000},
          groups = function(K) return {sealed = W.sealed, stale = false} end})
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

local function has_tile(tiles, x, y, z)
  for _, t in ipairs(tiles) do if t[1] == x and t[2] == y and t[3] == z then return true end end
  return false
end

T.test('BUG-571 (Brotherarrow y406): SIEGE, the only water (a well) one level off Kern+, the walls verified sealed, the tile on the ' ..
       'citizens\' walk groups, the army 80 tiles off: the care burrow opens with the patient, the well and a bucket', function()
  local W, M = world{foe = {5, 95, 5}}
  day(W)
  local a = W.find_acts('burrow_tiles')
  T.eq(#a, 1, 'old code: nothing opens (every accepted water lies outside Kern+)')
  T.ok(has_tile(a[1].args[2], 30, 30, 5) and has_tile(a[1].args[2], 20, 12, 5), 'his tile and the well outside Kern+')
  T.eq(M.care_rooms(W.K), {'Pflege+'})
end)

T.test('BUG-571: the walls are not verified sealed, or the tile is outside the walls (snapshot.far): it stays closed, and the reason ' ..
       'names the rule', function()
  local W, M = world{sealed = false, foe = {5, 95, 5}}
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0, 'not sealed: closed')
  T.eq(M.care_rooms(W.K), {})
  local W2, M2 = world{far = true, foe = {5, 95, 5}}
  day(W2)
  T.eq(#W2.find_acts('burrow_tiles'), 0, 'the pond lies outside the walls: closed')
  T.eq(M2.care_rooms(W2.K), {})
end)

T.test('BUG-571: a hostile 35 tiles from the well keeps it closed (care_siege_near 40) although care_near is 20; 45 tiles opens it; the ' ..
       'walls losing their seal close an open one at once', function()
  local W, M = world{foe = {55, 12, 5}}                          -- 35 tiles from the well, 25 from the patient
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0, '35 <= 40: closed')
  local W2, M2 = world{foe = {65, 12, 5}}                        -- 45 tiles from the well
  day(W2)
  T.eq(M2.care_rooms(W2.K), {'Pflege+'}, '45 > 40: open')
  W2.sealed = false
  T.eq(M2.care_rooms(W2.K), {}, 'the seal is gone: closed at once (care_check)')
  local closed = false
  for _, l in ipairs(W2.logs) do if tostring(l.msg):find('not verified sealed', 1, true) then closed = true end end
  T.ok(closed, 'kern.log names why')
end)

T.test('BUG-571: only a SIEGE reaches outside Kern+: in a BREACH or with care_siege_out false the well outside Kern+ is no water for the care burrow',
       function()
  local W, M = world{mode = 'BREACH', foe = {5, 95, 5}}
  day(W)
  T.eq(#W.find_acts('burrow_tiles'), 0, 'BREACH: closed')
  local W2, M2 = world{foe = {5, 95, 5}}
  W2.K.cfg.baseline.water = W2.K.cfg.baseline.water or {}
  W2.K.cfg.baseline.water.care_siege_out = false
  day(W2)
  T.eq(#W2.find_acts('burrow_tiles'), 0, 'care_siege_out false: the old rule')
end)

T.done()
