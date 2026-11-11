-- BUG-771 (Run 16a i1 Basementflew y534-y538: patients 27129 and 31512 over thirst 30,000 with 'GiveWater job running' and the nearest accepted
-- water 46-117 tiles away, both dead beside 342 days of barrel drink; the kernel only asked for a cistern every 28 days): a patient over
-- thirst_watch farther than patient_far from accepted water gets a Water Source zone on the scan's nearest safe water that lies at least
-- wz_gain tiles nearer to him than the accepted source (the BUG-324 painter, so no BREACH, no attack path, no cavern water), and carers_far
-- more caregivers. Every test fails on 87b10464.
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

-- the accepted water: a Water Source zone over deep water far away (190,190,4); the scanned pit 40,40,4 lies 28 tiles from the patient at 12,12
local function far_world(extra)
  local tiles = pit_tiles()
  tiles['190,190,4'] = '~'
  local o = {tiles = tiles, patient = {1, 26000}, setup = function(W)
    F.building(W, 'ZONE_WATER_SOURCE', {id = 950, type = df.civzone_type.WaterSource, x1 = 190, y1 = 190, x2 = 190, y2 = 190, z = 4,
                                        spec_sub_flag = {active = true}})
  end}
  for k, v in pairs(extra or {}) do o[k] = v end
  return world(o)
end

T.test('BUG-771: a thirsty patient 178 tiles from the accepted water gets a zone on the scanned water 28 tiles from him', function()
  local W, M = far_world()
  day(W, 4)
  local z = zones(W)
  T.eq(#z, 1, 'old code: the zone painter runs only while no water is accepted')
  T.eq(z[1].args[1], {40, 40, 4})
  local log = ''
  for _, l in ipairs(W.logs) do log = log .. tostring(l.msg or l[3] or l) .. '\n' end
  T.ok(log:find('28 tiles from patient 1', 1, true), log)
  day(W, 2)
  T.eq(#zones(W), 1, 'accepted now: no second zone')
  T.eq(#W.state().water.src >= 2, true, 'both zones are accepted water')
end)

T.test('BUG-771: no zone when the accepted water is near enough (patient_far), or the candidate is not nearer by wz_gain', function()
  local tiles = pit_tiles()
  tiles['30,12,4'] = '~'                                  -- an accepted zone 18 tiles from the patient: not far
  local W = world{tiles = tiles, patient = {1, 26000}, setup = function(W)
    F.building(W, 'ZONE_WATER_SOURCE', {id = 950, type = df.civzone_type.WaterSource, x1 = 30, y1 = 12, x2 = 30, y2 = 12, z = 4,
                                        spec_sub_flag = {active = true}})
  end}
  day(W, 4)
  T.eq(#zones(W), 0, 'the accepted water is within patient_far')
  local t2 = pit_tiles()
  local W2 = world{tiles = t2, patient = {1, 26000}, man = {}, setup = function(W)
    F.building(W, 'ZONE_WATER_SOURCE', {id = 950, type = df.civzone_type.WaterSource, x1 = 52, y1 = 12, x2 = 52, y2 = 12, z = 4,
                                        spec_sub_flag = {active = true}})
    W.cmap['52,12,4'] = '~'
  end}
  day(W2, 4)
  T.eq(#zones(W2), 0, 'accepted water 40 tiles away is not farther than patient_far (40): nothing')
end)

T.test('BUG-771: a patient under thirst_watch, or none, paints nothing', function()
  local W = far_world{patient = {1, 12000}}
  day(W, 4)
  T.eq(#zones(W), 0)
end)

T.test('BUG-771: never in BREACH (the BUG-324 rules apply to the near zone too)', function()
  local W = far_world{setup = function(W)
    F.building(W, 'ZONE_WATER_SOURCE', {id = 950, type = df.civzone_type.WaterSource, x1 = 190, y1 = 190, x2 = 190, y2 = 190, z = 4,
                                        spec_sub_flag = {active = true}})
    W.set_mode('BREACH')
  end}
  day(W, 4)
  T.eq(#zones(W), 0)
end)

T.test('BUG-771: far_patient names the thirstiest patient beyond patient_far; carers want carers_far more for him', function()
  local W, M = far_world()
  local c = M.conf(W.K)
  local r = {patients = {{id = 1, x = 12, y = 12, z = 5, thirst = 26000}, {id = 2, x = 12, y = 12, z = 5, thirst = 31000}},
             sources = {{wet = true, x = 190, y = 190, z = 4}}}
  local f = M.far_patient(c, r)
  T.eq({f.id, f.d, f.thirst}, {2, 178, 31000})
  r.sources = {{wet = true, x = 20, y = 12, z = 5}}
  T.eq(M.far_patient(c, r), nil, 'accepted water 8 tiles away')
  r.sources = {}
  T.eq(M.far_patient(c, r).d, nil, 'no accepted water at all')
  local rr = {patients = {{id = 1}}, carers = {}, carers_idle = 0, pool = {}, hosp = {}}
  T.eq((M.carers(W.K, c, rr, {}, 0, false, false)).want, 2)
  T.eq((M.carers(W.K, c, rr, {}, 0, false, true)).want, 2 + c.carers_far)
  T.eq((M.carers(W.K, c, rr, {}, 0, true, true)).want, 2 + c.carers_urgent + c.carers_far)
end)

T.done()
