-- Run 15 round 3 (fix13-water-hosp): BUG-324 found water never became accepted water (Inkintense: the scan found 7/7 water
-- at 88,102,132 under an open tile, the hospital still waited for 'accepted water'; Earthboat: the river under its ramp
-- tops, a dry well, '1 GiveWater job open, none taken by 53 idle'): the kernel zones the scan's best reachable, safe water as
-- a Water Source, the next run accepts it (water.src: bp sites hospital ranks by it), and the patient_thirst verdict says
-- 'no accepted water' instead of blaming idle carers. BUG-325 the scan's single walk origin (a citizen in another walk group
-- made every bank and well spot unreachable). Every test fails on 1d17c7e.
local T = require('testlib')
local F = require('wp8_world')
local C = require('dfllm.util.contract')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local DEPTH = {['~'] = 7, w = 2}

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove', 'work_detail'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- the river of Earthboat in small: water 40,40,4 under the open ramp top 40,40,5, the floor 39,40,5 beside it
local function pit_tiles()
  return {['40,40,4'] = '~', ['40,40,5'] = 'v', ['41,40,5'] = '.', ['39,40,5'] = '.'}
end

-- opts: tiles, pos (unit positions), reach(a, b), inside (outside_near answers 0), man (manifest extra), patient
-- {id, thirst}, jobs (open GiveWater job ids), zone (act result: true paints a zone the next run reads), setup(W)
local function world(opts)
  opts = opts or {}
  owners()
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = (opts.pos or {})[i] or {12, 12, 5}} end
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 199, 199, 20}}}}
  for k, v in pairs(opts.man or {}) do man[k] = v end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = {manifest = man}}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  df.unit_labor = df.unit_labor or {}
  df.unit_labor.FEED_WATER_CIVILIANS = df.unit_labor.FEED_WATER_CIVILIANS or 40
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    W.unit(i).counters2 = {thirst_timer = 1000}
    W.unit(i).job = {current_job = nil}
  end
  if opts.patient then
    local u = W.unit(opts.patient[1])
    u.counters2.thirst_timer = opts.patient[2]
    u.health = {flags = {needs_healthcare = true}}
  end
  local head
  for i = #(opts.jobs or {}), 1, -1 do head = {item = {job_type = 78, id = opts.jobs[i]}, next = head} end
  df.global.world.jobs = {list = {next = head}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return j._worker end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 199, 199, 20})
  W.cmap = opts.tiles or {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local c = W.cmap[x .. ',' .. y .. ',' .. z] or '#'
    if c == '?' then return nil end
    return {c = c, dig = '', bld = '', flow = DEPTH[c] or 0}
  end
  function snap.liquids(K, x0, y0, x1, y1, z, min, ice, lat)
    local out = {}
    for y = y0, y1 do
      for x = x0, x1 do
        if not lat or (x + 2 * y) % lat == 0 then
          local f = DEPTH[W.cmap[x .. ',' .. y .. ',' .. z] or ''] or 0
          if f >= (min or 1) then out[#out + 1] = {x, y, f, W.cav and 1 or 0} end
        end
      end
    end
    return out
  end
  function snap.reach(K, a, b) if opts.reach then return opts.reach(a, b) end return true end
  if opts.inside ~= nil then
    function snap.outside_near(K, pts) return {opts.inside and 0 or 1} end
  end
  W.load(snap)
  W.load({name = 'runner', every = {ticks = 600}, pending = function() return 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end, aq_seen = function() return true end})
  W.zid = 900
  if C.ACT.water_zone then W.act_result('water_zone', function(pos, up)   -- (the act is new: old code has none)
    if opts.zone == false then return false, 'quickfort designated no zone there' end
    for _, zz in ipairs(up and {pos[3], pos[3] + 1} or {pos[3]}) do
      W.zid = W.zid + 1
      F.building(W, 'ZONE_WATER_SOURCE', {id = W.zid, type = df.civzone_type.WaterSource, x1 = pos[1], y1 = pos[2],
                                          x2 = pos[1], y2 = pos[2], z = zz, spec_sub_flag = {active = true}})
    end
    return true, up and 2 or 1
  end) end
  if opts.setup then opts.setup(W) end
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 10}) end end
local function zones(W) return W.find_acts('water_zone') end

---------------------------------------------------------------- BUG-324
T.test('BUG-324 (Run 15 Earthboat/Inkintense: the scan found 7/7 water under an open tile with a reachable floor beside it, ' ..
       'nothing zoned it): the kernel paints a Water Source zone on the water and the open tile above, the next run accepts ' ..
       'it, water.src carries it (bp sites hospital ranks by it)', function()
  local W, M = world{tiles = pit_tiles()}
  day(W, 3)
  local z = zones(W)
  T.eq(#z, 1, 'old code: the scan only wrote a recipe')
  T.eq(z[1].args[1], {40, 40, 4})
  T.eq(z[1].args[2], true, 'the carrier stands one level up: the open tile is zoned too')
  day(W, 1)
  local w = W.state().water
  T.eq(w.src[1], {40, 40, 4}, 'accepted: the zone over deep water')
  T.ok(w.src_l[1]:find('^zone 9'), tostring(w.src_l[1]))
  T.eq(#zones(W), 1, 'accepted: no second zone')
  local log = ''
  for _, l in ipairs(W.logs) do log = log .. tostring(l.msg or l[3] or l) .. '\n' end
  T.ok(log:find('Water Source zone dfllm-water painted at 40,40,4 (7/7, open above; carrier floor', 1, true), log)
  local _, _, d = M.inspect(W.K, 'water_sources')
  T.eq(d.wz.at, {40, 40, 4})
end)

T.test('BUG-324: a bank on the water\'s own level zones the water tile beside it (one level only)', function()
  local tiles = {['20,20,5'] = '~', ['21,20,5'] = '~', ['20,19,5'] = '.'}
  local W = world{tiles = tiles}
  day(W, 3)
  local z = zones(W)
  T.eq(#z, 1)
  T.eq(z[1].args[2], false)
  T.ok(z[1].args[1][2] == 20 and z[1].args[1][3] == 5, 'a water tile beside the bank')
end)

T.test('BUG-324: safe only: never in BREACH, outside PEACE/RECOVERY only a roofed bank, never on the attack path, never ' ..
       'cavern water', function()
  local W = world{tiles = pit_tiles(), setup = function(W) W.set_mode('BREACH') end}
  day(W, 3)
  T.eq(#zones(W), 0, 'BREACH')
  local W2 = world{tiles = pit_tiles(), inside = false, setup = function(W) W.set_mode('SIEGE') end}
  day(W2, 3)
  T.eq(#zones(W2), 0, 'SIEGE and open sky')
  local W3 = world{tiles = pit_tiles(), inside = true, setup = function(W) W.set_mode('SIEGE') end}
  day(W3, 3)
  T.eq(#zones(W3), 1, 'SIEGE but roofed')
  local W4 = world{tiles = pit_tiles(), man = {zones = {Z4 = {{0, 0, 0, 199, 199, 20}}, Z1 = {{35, 35, 5, 45, 45, 5}}}}}
  day(W4, 3)
  T.eq(#zones(W4), 0, 'the carrier floor lies in the bailey (Z1)')
  local W5 = world{tiles = pit_tiles(), setup = function(W) W.cav = true end}
  day(W5, 3)
  T.eq(#zones(W5), 0, 'cavern water stays sealed')
end)

T.test('BUG-324: a refused zone is not tried at the same spot again; the next spot waits wz_every, at most wz_max spots',
       function()
  local tiles = pit_tiles()
  tiles['30,15,4'], tiles['30,15,5'], tiles['31,15,5'] = '~', '_', '.'
  local W, M = world{tiles = tiles, zone = false}
  day(W, 3)
  T.eq(#zones(W), 1)
  local first = zones(W)[1].args[1]
  day(W, 4)
  T.eq(#zones(W), 2)
  T.ok(zones(W)[2].args[1][1] ~= first[1], 'another spot')
  T.ok(zones(W)[2].tick - zones(W)[1].tick >= M.conf(W.K).wz_every, 'not before wz_every')
  day(W, 10)
  T.eq(#zones(W), 2, 'no spot left: none tried again')
  T.ok(M.conf(W.K).wz_max >= 2)
end)

T.test('BUG-324 (Earthboat y385: "1 GiveWater job open, none taken by 53 idle" with no accepted water): the verdict is ' ..
       'nowater, not idle carers', function()
  local W = world{tiles = {}, patient = {1, 37348}, jobs = {700}}
  day(W, 2)
  local pt
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'patient_thirst' then pt = e end end
  T.ok(pt, 'patient_thirst')
  T.eq(pt.d.key, 'nowater', 'old code: open (none taken by N idle)')
  T.ok(pt.msg:find('no accepted water (no well over water, no Water Source zone): 1 GiveWater job open without a source',
                   1, true), pt.msg)
end)

---------------------------------------------------------------- BUG-325
T.test('BUG-325 (Run 15 Earthboat: the same 1490 tiles gave "12 with a well spot" and "0 with a well spot"): the scan asks ' ..
       'the walk from several citizens; one in another walk group no longer hides the well spot', function()
  -- unit 1 stands next to the reference (the hospital) in a walk group of his own; the others reach the river
  local W, M = world{tiles = pit_tiles(), pos = {[1] = {12, 12, 5}, [2] = {30, 30, 5}, [3] = {31, 30, 5}, [4] = {32, 30, 5}},
                     reach = function(a) return not (a.x == 12 and a.y == 12) end,
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W, 3)
  local _, _, d = M.inspect(W.K, 'water_sources')
  T.ok(d.bodies and d.bodies[1], 'scanned')
  T.eq(d.bodies[1].pit, {40, 40, 5}, 'old code: one origin, unit 1 in his own walk group: no well spot')
  T.eq(#M.origins({{x = 1, y = 1, z = 1}, {x = 1, y = 1, z = 1}, {x = 9, y = 9, z = 1}}, {x1 = 0, y1 = 0, x2 = 0, y2 = 0, z = 1}, 3),
       2, 'distinct tiles only')
end)

T.done()
