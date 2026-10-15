-- water (live L3): patients' thirst, hospital and refuge water, bucket supply, the cistern flood alarm.
-- `water` is in contract.MODULES (iter2 integration); ACT item_flag/workorder list water, and the tests toggle
-- that per test to check the feature detection.
local C = require('dfllm.util.contract')
local listed = false
for _, m in ipairs(C.MODULES) do if m.name == 'water' then listed = true end end
assert(listed, 'water missing from contract.MODULES')
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'      -- a real buildings_other_id (dfhack.dll)

local function owners(on)
  for _, fn in ipairs({'item_flag', 'workorder'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn]) do if o ~= 'water' then keep[#keep + 1] = o end end
    if on then keep[#keep + 1] = 'water' end
    C.ACT[fn] = keep
  end
end

local function fresh() package.loaded['dfllm.water'] = nil; return require('dfllm.water') end

-- opts: patients = {{id, thirst, rest|care, pos}}, act (default true), tiles = {['x,y,z'] = c}, manifest
local function world(opts)
  opts = opts or {}
  owners(opts.act ~= false)
  local units = {}
  for i = 1, opts.cit or 4 do units[i] = {id = i, citizen = true, pos = {50, 50, 10}} end
  local persist = {manifest = opts.manifest or {v = 2, burrows = {['Kern+'] = {role = 'kern'},
                                                                   ['Tiefe+'] = {role = 'refuge'}},
                                                 zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource = 10
  df.civzone_type[10] = 'WaterSource'
  df.job_type.Rest = 77
  df.job_type[77] = 'Rest'
  local ids = {}
  for i = 1, opts.cit or 4 do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000}
    u.job = {current_job = nil}
  end
  for _, pt in ipairs(opts.patients or {}) do
    local u = W.unit(pt.id)
    u.counters2.thirst_timer = pt.thirst
    if pt.rest then u.job.current_job = {job_type = df.job_type.Rest} end
    if pt.care then u.health = {flags = {needs_healthcare = true}} end
    if pt.pos then W.move(pt.id, pt.pos[1], pt.pos[2], pt.pos[3]) end
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.cmap = opts.tiles or {}
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function(K, x, y, z)
    local c = W.cmap[x .. ',' .. y .. ',' .. z]
    if c == '?' then return nil end
    return {c = c or '#', dig = '', bld = ''}
  end})
  if opts.setup then opts.setup(W) end
  local M = fresh()
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 100}) end end
local function needed(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function well(W, x, y, z) return F.building(W, 'WELL', {x1 = x, y1 = y, x2 = x, y2 = y, z = z}) end

T.test('config/baseline.json may tune water; the defaults stand without it', function()
  local W, M = world()
  local c = M.conf(W.K)
  T.eq(c.thirst_alarm, 30000)                                 -- FR-34: hospital patients over 30,000 wake
  T.eq(c.deep, 4)
  T.eq(c.near, 30)
  T.ok(c.buckets_min >= 2)
end)

T.test('a bedridden patient over 30k thirst without water: patient_thirst (A) with cause and recipe, cistern requested', function()
  local W, M = world{patients = {{id = 2, thirst = 45000, rest = true, pos = {12, 12, 5}}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W)
  local pt = needed(W, 'patient_thirst')
  T.eq(#pt, 1)
  T.eq(pt[1].cls, 'A')
  T.eq(pt[1].d.unit, 2)
  T.eq(pt[1].d.units, {2})
  T.ok(pt[1].msg:find('no wet', 1, true), pt[1].msg)
  T.ok(pt[1].d.q:find('delete the hospital zone', 1, true), pt[1].d.q)  -- FR-34 recipe
  T.ok(#pt[1].d.q <= 200 and #pt[1].msg <= 200)
  T.eq(#W.find_events('HOSPITAL_DRY'), 0)                     -- patient_thirst already names the dry hospital
  local req = W.find_events('PROJECT_REQUEST')
  T.eq(#req, 1)
  T.eq(req[1].d.tpl, 'cistern')
  local k = M.kpi(W.K)
  T.eq({k.patients, k.hosp_ok, k.thirst_max}, {1, 0, 45000})
  day(W, 5)                                                    -- review: no longer every 3 days, but weekly
  T.eq(#needed(W, 'patient_thirst'), 1)
  day(W, 2)
  T.eq(#needed(W, 'patient_thirst'), 2)
  T.eq(#W.find_events('HOSPITAL_DRY'), 0)
  T.eq(#W.find_events('PROJECT_REQUEST'), 1)                   -- monthly
end)

T.test('one patient_thirst line for all patients; a patient crossing the alarm wakes at once', function()
  local W, M = world{patients = {{id = 2, thirst = 45000, rest = true}, {id = 3, thirst = 52000, care = true},
                                 {id = 4, thirst = 29000, care = true}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W)
  local pt = needed(W, 'patient_thirst')
  T.eq(#pt, 1)
  T.eq({pt[1].d.unit, pt[1].d.n, pt[1].d.units}, {3, 2, {3, 2}})   -- the thirstiest first
  day(W)
  T.eq(#needed(W, 'patient_thirst'), 1)
  W.unit(4).counters2.thirst_timer = 31000                    -- unit 4 crosses the alarm
  day(W)
  pt = needed(W, 'patient_thirst')
  T.eq(#pt, 2)
  T.eq(pt[2].d.n, 3)
  W.unit(2).counters2.thirst_timer = 1000                     -- unit 2 got water: its episode ends
  day(W)
  W.unit(2).counters2.thirst_timer = 32000                    -- and starts again: at once
  day(W)
  T.eq(#needed(W, 'patient_thirst'), 3)
end)

T.test('hospital gate (FR-31/34): HOSPITAL_DRY when the dry episode starts, weekly with patients, else monthly', function()
  local W, M = world{patients = {{id = 2, thirst = 1000, care = true}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W)
  local hd = W.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1)
  T.eq(hd[1].cls, 'A')
  T.eq({hd[1].d.patients, hd[1].d.near}, {1, 30})
  T.ok(hd[1].d.recipe:find('delete the hospital zone', 1, true), hd[1].d.recipe)
  T.ok(#hd[1].msg <= 200 and #hd[1].d.recipe <= 200)
  day(W, 6)
  T.eq(#W.find_events('HOSPITAL_DRY'), 1)
  day(W)
  T.eq(#W.find_events('HOSPITAL_DRY'), 2, 'weekly while somebody is a patient')
  W.unit(2).health = nil                                       -- healed: the gate stays, monthly now
  day(W, 14)
  T.eq(#W.find_events('HOSPITAL_DRY'), 2)
  day(W, 14)
  T.eq(#W.find_events('HOSPITAL_DRY'), 3, 'a hospital without water is reported without patients too')
  T.eq(#needed(W, 'patient_thirst'), 0)
  T.eq(#needed(W, 'hospital_water'), 0, 'the DECISION_NEEDED of the old gate is gone')
end)

T.test('hospital gate: water ends the episode, a dry hospital again wakes at once; a planned hospital without water', function()
  local W, M = world{tiles = {['20,12,4'] = '_', ['20,12,3'] = '~'},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W)
  T.eq(#W.find_events('HOSPITAL_DRY'), 1)
  well(W, 20, 12, 5)
  day(W)
  T.eq(M.kpi(W.K).gate, 0)
  W.cmap['20,12,3'] = '.'                                      -- the sump ran dry
  day(W)
  T.eq(#W.find_events('HOSPITAL_DRY'), 2)
  local W2 = world{setup = function(W)
    W.load({name = 'runner', every = {ticks = 600}, pending = function(K, tpl) return tpl == 'hospital' and 1 or 0 end})
  end}
  day(W2)
  local hd = W2.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1)
  T.ok(hd[1].msg:find('planned hospital', 1, true), hd[1].msg)
  T.eq(hd[1].d.zone, -1)
end)

T.test('needs_healthcare marks a patient too; a thirsty dwarf at work is no patient', function()
  local W, M = world{patients = {{id = 1, thirst = 30000, care = true}, {id = 3, thirst = 48000}}}
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.patients, k.thirsty, k.thirst_max}, {1, 1, 30000})
  T.eq(#needed(W, 'patient_thirst'), 0)                       -- 30k is below the alarm, unit 3 is no patient
end)

T.test('a wet well near the hospital serves it: no gate alarm; patient_thirst lists caregivers and buckets', function()
  local W, M = world{patients = {{id = 2, thirst = 41000, care = true}},
                     tiles = {['20,12,4'] = '_', ['20,12,3'] = '~'},
                     setup = function(W)
                       F.hospital(W, {10, 10, 14, 14, 5}); well(W, 20, 12, 5)
                       df.unit_labor = {FEED_WATER_CIVILIANS = 40}
                       for _, id in ipairs({1, 3, 4}) do W.unit(id).status = {labors = {[40] = id ~= 4}} end
                     end}
  F.item(W, 'BUCKET', {_pos = {20, 13, 5}})
  F.item(W, 'BUCKET', {_pos = {20, 14, 5}})
  F.item(W, 'BUCKET', {_pos = {20, 15, 5}})
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.hosp_ok, k.wells, k.wet, k.buckets_free}, {1, 1, 1, 3})
  T.eq(#W.find_events('HOSPITAL_DRY'), 0)
  local pt = needed(W, 'patient_thirst')
  T.eq(#pt, 1)
  T.ok(pt[1].msg:find('water, buckets and caregivers present', 1, true), pt[1].msg)
  T.eq({pt[1].d.carers, pt[1].d.n_carers, pt[1].d.buckets, pt[1].d.buckets_all}, {{1, 3}, 2, 3, 3})
  T.ok(pt[1].d.q:find('carers 2 (FEED_WATER_CIVILIANS: 1,3)', 1, true), pt[1].d.q)
  T.eq(M.kpi(W.K).carers, 2)
  T.eq(#W.find_events('PROJECT_REQUEST'), 0)
  df.unit_labor = nil
end)

T.test('a dry sump, a hidden shaft or a well 40 tiles away do not serve the hospital', function()
  local W, M = world{patients = {{id = 2, thirst = 1000, care = true}},
                     tiles = {['11,11,4'] = 'r', ['13,11,4'] = '?', ['60,12,4'] = '~'},
                     setup = function(W)
                       F.hospital(W, {10, 10, 14, 14, 5})
                       well(W, 11, 11, 5); well(W, 13, 11, 5); well(W, 60, 12, 5)
                     end}
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.hosp_ok, k.wells, k.wet}, {0, 3, 1})
  T.eq(#W.find_events('HOSPITAL_DRY'), 1)
end)

T.test('FR-33a: a Water Source zone counts only on water >= 4/7 on its own level (zone_below for a brook bed)', function()
  local function run(tiles, below)
    local W, M = world{patients = {{id = 2, thirst = 1000, care = true}}, tiles = tiles,
                       setup = function(W)
                         F.hospital(W, {10, 10, 14, 14, 5})
                         F.building(W, 'ZONE_WATER_SOURCE', {id = 70, type = df.civzone_type.WaterSource, x1 = 30,
                                                             y1 = 12, x2 = 31, y2 = 12, z = 5,
                                                             spec_sub_flag = {active = true}})
                         F.building(W, 'ANY_ZONE', {id = 71, type = df.civzone_type.WaterSource, x1 = 90, y1 = 90,
                                                    x2 = 90, y2 = 90, z = 5, spec_sub_flag = {active = false}})
                       end}
    if below then
      local cfg = F.cfg()
      cfg.water = {zone_below = true}
      W.K.cfg.baseline = cfg
    end
    day(W)
    return M.kpi(W.K).hosp_ok, M.kpi(W.K).wet
  end
  T.eq({run({['31,12,5'] = '~'})}, {1, 1}, 'deep water on the zone level')
  T.eq({run({['31,12,5'] = 'w'})}, {0, 0}, '1/7 seepage: the game cancels GiveWater "No water source"')
  T.eq({run({['31,12,4'] = '~'})}, {0, 0}, 'water one level below: not by default')
  T.eq({run({['31,12,4'] = '~'}, true)}, {1, 1}, 'zone_below accepts a brook bed')
end)

T.test('deep_tile reads the depth from snapshot.tile, magma never counts', function()
  local M = fresh()
  local c = {deep = 4}
  T.eq({M.deep_tile({c = 'w', flow = 3}, c), M.deep_tile({c = '~', flow = 4}, c), M.deep_tile({c = '~', flow = 7, magma = true}, c),
        M.deep_tile({c = '~'}, c), M.deep_tile({c = 'w'}, c), M.deep_tile(nil, c)}, {false, true, false, true, false, false})
end)

T.test('buckets: unforbid inside Kern+ first, then one live dfllm:bucket order for the rest', function()
  local W, M = world{patients = {{id = 2, thirst = 1000, care = true}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  W.burrow('Kern+', {0, 0, 0, 40, 40, 20})
  local inside = F.item(W, 'BUCKET', {_pos = {20, 20, 5}, flags = {forbid = true}})
  local outside = F.item(W, 'BUCKET', {_pos = {80, 80, 5}, flags = {forbid = true}})
  F.item(W, 'BUCKET', {_pos = {21, 20, 5}, flags = {in_job = true}})
  day(W)
  local flags = W.find_acts('item_flag')
  T.eq(#flags, 1)
  T.eq({flags[1].args[1], flags[1].args[2], flags[1].args[3]}, {inside.id, 'forbid', false})
  local orders = W.find_acts('workorder')
  T.eq(#orders, 1)                                            -- want 2 + 1 patient = 3, one usable now
  T.eq(orders[1].args[1].job, 'MakeBucket')
  T.eq(orders[1].args[1].tag, 'dfllm:bucket')
  T.eq(orders[1].args[1].amount_total, 2)
  T.eq(outside.flags.forbid, true)
  day(W, 3)
  T.eq(#W.find_acts('workorder'), 1)                          -- the order is still live
  df.global.world.manager_orders.all[0].amount_left = 0
  day(W)
  T.eq(#W.find_acts('workorder'), 2)
end)

T.test('buckets: ids, not pointers; a bucket gone by write time is skipped; no unforbid in BREACH or without Kern+ outside PEACE', function()
  local W, M = world{patients = {{id = 2, thirst = 1000, care = true}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  local gone = F.item(W, 'BUCKET', {_pos = {20, 20, 5}, flags = {forbid = true}})
  local kept = F.item(W, 'BUCKET', {_pos = {21, 20, 5}, flags = {forbid = true}})
  W.items_by_id[gone.id] = nil                                -- destroyed between the scan and the write
  W.mode = 'BREACH'
  day(W)
  T.eq(#W.find_acts('item_flag'), 0)                          -- an enemy inside Kern+: nobody fetches buckets
  W.mode = 'PEACE'
  day(W)
  local flags = W.find_acts('item_flag')
  T.eq(#flags, 1)
  T.eq(flags[1].args[1], kept.id)
  local man = {v = 2, burrows = {['Ohne+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}
  local W2 = world{manifest = man, patients = {{id = 2, thirst = 1000, care = true}},
                   setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  F.item(W2, 'BUCKET', {_pos = {20, 20, 5}, flags = {forbid = true}})
  W2.mode = 'ALERT'
  day(W2)
  T.eq(#W2.find_acts('item_flag'), 0)                         -- no Kern+ burrow (the manifest's is missing)
  W2.mode = 'PEACE'
  day(W2)
  T.eq(#W2.find_acts('item_flag'), 1)                         -- only in PEACE then
end)

T.test('a bucket that still holds water is no free bucket (fix/dry-buckets empties it later)', function()
  local W, M = world{patients = {{id = 2, thirst = 1000, care = true}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  F.item(W, 'BUCKET', {_pos = {20, 20, 5}, _contents = {{id = 900}}})
  F.item(W, 'BUCKET', {_pos = {21, 20, 5}})
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.buckets, k.buckets_free, k.buckets_full, k.buckets_want}, {2, 1, 1, 3})
  T.eq(W.find_acts('workorder')[1].args[1].amount_total, 2)
end)

T.test('without the contract change water writes nothing (feature detection, strict k_mock)', function()
  local W, M = world{act = false, patients = {{id = 2, thirst = 47000, care = true}},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  F.item(W, 'BUCKET', {_pos = {20, 20, 5}, flags = {forbid = true}})
  day(W, 2)
  T.eq(#W.find_acts('item_flag'), 0)
  T.eq(#W.find_acts('workorder'), 0)
  T.eq(#needed(W, 'patient_thirst'), 1)
  T.eq(M.kpi(W.K).missing, 3)
  owners(true)
end)

T.test('the hospital location\'s desired buckets raise the want', function()
  local W, M = world{setup = function(W)
    local z = F.hospital(W, {10, 10, 14, 14, 5})
    W.site.buildings[0].contents = {desired_buckets = 5}
    T.ok(z.location_id == W.site.buildings[0].id)
  end}
  day(W)
  T.eq(M.kpi(W.K).buckets_want, 5)
  T.eq(W.find_acts('workorder')[1].args[1].amount_total, 5)
end)

T.test('refuge: a wet well on a Tiefe+ tile', function()
  local W, M = world{tiles = {['45,45,1'] = 'w'}, setup = function(W) well(W, 45, 45, 2); well(W, 70, 70, 2) end}
  day(W)
  T.eq(M.kpi(W.K).refuge_ok, 1)
  local W2, M2 = world{tiles = {['70,70,1'] = 'w'}, setup = function(W) well(W, 70, 70, 2) end}
  day(W2)
  T.eq(M2.kpi(W2.K).refuge_ok, 0)
end)

T.test('cistern flood: water on the well room floor wakes the LLM every 2 days; one wet tile once is a poured bucket', function()
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 99, 99, 20}}},
               rooms = {{id = 'cistern50_50_2r0', tpl = 'cistern', use = 'utility', bbox = {49, 52, 2, 51, 54, 2},
                         tier = 0}}}
  local W, M = world{manifest = man, tiles = {['50,54,2'] = 'w'}}
  day(W)
  T.eq(#needed(W, 'cistern_flood'), 0)                        -- one tile, one run: a bucket into the pond hole
  W.cmap['50,54,2'] = '.'
  day(W)
  T.eq(#needed(W, 'cistern_flood'), 0)
  W.cmap['50,54,2'] = 'w'
  day(W)
  T.eq(#needed(W, 'cistern_flood'), 0)
  day(W)                                                       -- still wet in the next run: a flood
  local f = needed(W, 'cistern_flood')
  T.eq(#f, 1)
  T.ok(f[1].d.q:find('lever', 1, true))
  day(W)
  T.eq(#needed(W, 'cistern_flood'), 1)                        -- every 2 days
  W.cmap['50,54,2'] = '.'
  day(W, 2)
  T.eq(#needed(W, 'cistern_flood'), 1)
  local W2 = world{manifest = man, tiles = {['50,54,2'] = '~', ['49,53,2'] = 'w'}}
  day(W2)
  T.eq(#needed(W2, 'cistern_flood'), 1)                       -- two wet tiles at once
  T.ok(needed(W2, 'cistern_flood')[1].msg:find('2 wet tiles', 1, true))
end)

T.test('pond loop (live L6): a Pond zone beside a wet well is removed; a real Water Source zone keeps it', function()
  local function run(with_source)
    local removed = {}
    local W, M = world{tiles = {['20,12,4'] = '_', ['20,12,3'] = '~', ['31,12,5'] = '~'},
                       setup = function(W)
                         df.civzone_type.Pond = 11
                         df.civzone_type[11] = 'Pond'
                         well(W, 20, 12, 5)
                         F.building(W, 'ANY_ZONE', {id = 80, type = df.civzone_type.Pond, x1 = 21, y1 = 12, x2 = 21,
                                                    y2 = 12, z = 5})
                         F.building(W, 'ANY_ZONE', {id = 81, type = df.civzone_type.Pond, x1 = 70, y1 = 70, x2 = 70,
                                                    y2 = 70, z = 5})
                         if with_source then
                           F.building(W, 'ZONE_WATER_SOURCE', {id = 82, type = df.civzone_type.WaterSource, x1 = 30,
                                                               y1 = 12, x2 = 31, y2 = 12, z = 5,
                                                               spec_sub_flag = {active = true}})
                         end
                         W.act_result('pond_remove', function(id) removed[#removed + 1] = id; return true, 1 end)
                       end}
    local C2 = require('dfllm.util.contract')
    C2.ACT.pond_remove = {'water'}
    day(W)
    return removed
  end
  T.eq(run(false), {80}, 'only the pond beside the wet well; the far one stays')
  T.eq(run(true), {}, 'a wet Water Source zone is the real supply: no loop')
end)

T.test('state: nothing published until the contract has a water key; the census is sliced', function()
  local W, M = world{cit = 90}
  W.run(100, {skip = 100})
  T.eq(W.state().water, nil)
  day(W)
  T.ok(M.kpi(W.K) ~= nil)
  T.eq(M.kpi(W.K).patients, 0)
end)

T.done()
