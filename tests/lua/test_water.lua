-- water (live L3): patients' thirst, hospital and refuge water, bucket supply, the cistern flood alarm; BUG-034: a dry
-- hospital's zones are removed once a patient is thirsty (HOSPITAL_REMOVED), the state's water key.
-- `water` is in contract.MODULES (iter2 integration); ACT item_flag/workorder/hospital_remove list water, and the tests
-- toggle that per test to check the feature detection.
local C = require('dfllm.util.contract')
local listed = false
for _, m in ipairs(C.MODULES) do if m.name == 'water' then listed = true end end
assert(listed, 'water missing from contract.MODULES')
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'      -- a real buildings_other_id (dfhack.dll)

-- rm = false: water may not remove hospital zones (the patient_thirst and HOSPITAL_DRY cases of a fort where the
-- removal is off or refused)
local function owners(on, rm)
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn]) do if o ~= 'water' then keep[#keep + 1] = o end end
    if on and (fn ~= 'hospital_remove' or rm ~= false) then keep[#keep + 1] = 'water' end
    C.ACT[fn] = keep
  end
end

local function fresh() package.loaded['dfllm.water'] = nil; return require('dfllm.water') end

-- opts: patients = {{id, thirst, rest|care, pos}}, act (default true), rm (false: no hospital removal), tiles =
-- {['x,y,z'] = c}, manifest
local function world(opts)
  opts = opts or {}
  owners(opts.act ~= false, opts.rm)
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
  local W, M = world{rm = false, patients = {{id = 2, thirst = 45000, rest = true, pos = {12, 12, 5}}},
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
  T.eq(#needed(W, 'patient_thirst'), 1, 'BUG-008: a game week is 21 s at timestream speed: the wall clock waits too')
  W.ms = W.ms + 600000
  day(W)
  T.eq(#needed(W, 'patient_thirst'), 2)
  T.eq(#W.find_events('HOSPITAL_DRY'), 0)
  T.eq(#W.find_events('PROJECT_REQUEST'), 1)                   -- monthly
end)

T.test('one patient_thirst line for all patients; a patient crossing the alarm wakes at once', function()
  local W, M = world{rm = false, patients = {{id = 2, thirst = 45000, rest = true}, {id = 3, thirst = 52000, care = true},
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

T.test('hospital gate (FR-31/34): HOSPITAL_DRY when the dry episode starts; BUG-008: again only for news, after max(a week, 10 min)', function()
  local W, M = world{patients = {{id = 2, thirst = 1000, care = true}},
                     setup = function(W)
                       F.hospital(W, {10, 10, 14, 14, 5})
                       df.unit_labor = {FEED_WATER_CIVILIANS = 40}           -- (BUG-054: the added caregivers take the labor)
                       for i = 1, 4 do W.unit(i).status = {labors = {[40] = false}} end
                       W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[40] = on; return true end)
                     end}
  day(W)
  local hd = W.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1)
  T.eq(hd[1].cls, 'A')
  T.eq({hd[1].d.patients, hd[1].d.near}, {1, 30})
  T.ok(hd[1].d.recipe:find('until then the kernel removes it at thirst 25000', 1, true), hd[1].d.recipe)  -- BUG-034
  T.ok(#hd[1].msg <= 200 and #hd[1].d.recipe <= 200)
  day(W, 7)
  W.ms = W.ms + 600000
  day(W)
  T.eq(#W.find_events('HOSPITAL_DRY'), 1, 'the same patient and causes: no repeat')
  W.unit(3).health = {flags = {needs_healthcare = true}}       -- a new patient
  day(W)
  T.eq(#W.find_events('HOSPITAL_DRY'), 2, 'a new patient, both clocks passed')
  W.unit(3).health = {flags = {needs_healthcare = false}}
  W.unit(4).health = {flags = {needs_healthcare = true}}       -- another new patient within the week
  day(W, 3)
  T.eq(#W.find_events('HOSPITAL_DRY'), 2, 'within the cadence: waits')
  W.unit(2).health, W.unit(4).health = nil, nil                -- healed: the gate stays
  day(W, 28)
  W.ms = W.ms + 600000
  day(W)
  T.eq(#W.find_events('HOSPITAL_DRY'), 2, 'fewer patients is no news')
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
  -- BUG-054: 2 caregivers for 1 patient over the alarm are not "present" (want 2 + 2 urgent = 4): unit 4 is added to
  -- the Orderlies detail, the line says so; the old text "water, buckets and caregivers present" stays for enough of them
  T.ok(pt[1].msg:find('caregivers short: 3 of 4 wanted for 1 patient(s), 1 added to Orderlies now', 1, true), pt[1].msg)
  T.eq({pt[1].d.carers, pt[1].d.n_carers, pt[1].d.want, pt[1].d.added, pt[1].d.buckets, pt[1].d.buckets_all},
       {{1, 3}, 3, 4, 1, 3, 3})
  T.ok(pt[1].d.q:find('carers 3 of 4 wanted (FEED_WATER_CIVILIANS: 1,3)', 1, true), pt[1].d.q)
  T.eq(M.kpi(W.K).carers, 3)
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
  T.eq(#W.find_acts('hospital_remove'), 0, 'BUG-034: no hospital_remove owner, no removal')
  T.eq(#W.find_events('HOSPITAL_REMOVED'), 0)
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

T.test('BUG-035 (Run 11: "refuge dry, 1 wet sources (13 wells)"): the summary says how many wells lie in Tiefe+ and ' ..
       'how many of those are wet', function()
  local function line(W)
    for _, l in ipairs(W.logs) do if tostring(l.msg):find('water: ', 1, true) then return l.msg end end
    return ''
  end
  -- three wells: one dry in Tiefe+, a wet one and a dry one outside it
  local W, M = world{tiles = {['20,20,1'] = 'w'}, setup = function(W)
    well(W, 45, 45, 2); well(W, 20, 20, 2); well(W, 70, 70, 2)
  end}
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.refuge_ok, k.wells, k.rwells, k.rwet}, {0, 3, 1, 0})
  T.ok(line(W):find('refuge dry (3 wells, 1 in Tiefe+, 0 of them wet), 1 wet sources', 1, true), line(W))
  -- none in Tiefe+
  local W2, M2 = world{tiles = {['20,20,1'] = 'w'}, setup = function(W) well(W, 20, 20, 2) end}
  day(W2)
  T.eq({M2.kpi(W2.K).rwells, M2.kpi(W2.K).rwet}, {0, 0})
  T.ok(line(W2):find('refuge dry (1 well, 0 in Tiefe+), 1 wet sources', 1, true), line(W2))
  -- its well is wet
  local W3, M3 = world{tiles = {['45,45,1'] = 'w'}, setup = function(W) well(W, 45, 45, 2) end}
  day(W3)
  T.ok(line(W3):find('refuge ok (1 well, 1 in Tiefe+, 1 of them wet), 1 wet sources', 1, true), line(W3))
end)

T.test('BUG-036 (Run 11 siege 9: 7 patients killed in their hospital beds by cave dragons): a hospital zone on tiles ' ..
       'outside Kern+ and Tiefe+ counts in hosp_out (kpi, state), water.hospital_out names it; inside Kern+ or in ' ..
       'Tiefe+ it does not', function()
  local W, M = world{setup = function(W)
    W.burrow('Kern+', {0, 0, 0, 30, 30, 20})              -- the core: x0-30 y0-30
    F.hospital(W, {10, 10, 14, 14, 5})                     -- in Kern+
    F.hospital(W, {42, 42, 44, 44, 2})                     -- in Tiefe+
    F.hospital(W, {70, 70, 74, 72, 5})                     -- outside both
    F.hospital(W, {28, 20, 33, 22, 5})                     -- half in Kern+: 9 of its 18 tiles outside
  end}
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.hosp, k.hosp_out}, {4, 2})
  T.eq(W.state().water.hosp_out, 2, 'the state carries it (readiness, plan check)')
  local ho = M.hospital_out(W.K)
  T.eq({ho.n, ho.total, #ho.zones}, {2, 4, 2})
  T.eq({ho.zones[1].x, ho.zones[1].y, ho.zones[1].z, ho.zones[1].tiles, ho.zones[1].of}, {72, 71, 5, 15, 15})
  T.eq({ho.zones[2].tiles, ho.zones[2].of}, {9, 18})
  T.eq({ho.kern, ho.refuge}, {'Kern+', 'Tiefe+'})
  -- all inside: none
  local W2, M2 = world{setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W2)
  T.eq({M2.kpi(W2.K).hosp_out, M2.hospital_out(W2.K).n}, {0, 0})
  -- a big zone (30x30, 900 tiles) is sampled evenly: 100 tiles looked at
  local W3, M3 = world{setup = function(W)
    W.burrow('Kern+', {0, 0, 0, 30, 30, 20})
    F.hospital(W, {20, 0, 49, 29, 5})
  end}
  day(W3)
  local z = M3.hospital_out(W3.K).zones[1]
  T.eq({z.of, z.tiles}, {100, 60})          -- x 20,23,...,47: 6 of 10 columns beyond x 30
end)

T.test('BUG-036: in a fight (SIEGE/BREACH) the patients outside the burrow the alert confines to are reported once ' ..
       'per fight (PATIENTS_OUT, class A since M3 note 94): they cannot walk there, only a rescue moves them', function()
  local W, M = world{patients = {{id = 2, thirst = 9000, rest = true, pos = {72, 71, 5}},
                                 {id = 3, thirst = 9000, rest = true, pos = {43, 43, 2}}},
                     setup = function(W)
                       W.burrow('Kern+', {0, 0, 0, 30, 30, 20})
                       F.hospital(W, {70, 70, 74, 72, 5})
                       F.hospital(W, {42, 42, 44, 44, 2})
                       W.load({name = 'siege', every = {ticks = 100000},
                               alert_names = function() return W.alert_names or {} end})
                     end}
  day(W)
  T.eq(#W.find_events('PATIENTS_OUT'), 0, 'PEACE: nothing')
  W.alert_names = {'Tiefe+'}
  W.set_mode('BREACH')
  day(W)
  local po = W.find_events('PATIENTS_OUT')
  T.eq(#po, 1)
  T.eq(po[1].cls, 'A')
  T.eq({po[1].d.n, po[1].d.patients, po[1].d.burrow, po[1].d.units, po[1].d.mode, po[1].d.hosp_out},
       {1, 2, 'Tiefe+', {2}, 'BREACH', 1})
  T.ok(po[1].msg:find('BREACH: 1 of 2 patients lie outside the alert burrow Tiefe+ (2 at 72,71,5)', 1, true), po[1].msg)
  T.ok(po[1].msg:find('only a rescue moves them', 1, true), po[1].msg)
  day(W, 2)
  T.eq(#W.find_events('PATIENTS_OUT'), 1, 'once per fight')
  W.set_mode('PEACE')
  day(W)
  W.set_mode('SIEGE')
  day(W)
  T.eq(#W.find_events('PATIENTS_OUT'), 2, 'the next fight again')
  -- the alert silent: measured against Kern+ and Tiefe+
  W.alert_names = {}
  W.set_mode('PEACE')
  day(W)
  W.set_mode('SIEGE')
  day(W)
  local last = W.find_events('PATIENTS_OUT')
  T.eq(last[#last].d.burrow, 'Kern+/Tiefe+')
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

T.test('state: water is published once a run is done (BUG-034: the contract has the key); the census is sliced', function()
  local W, M = world{cit = 90}
  W.run(100, {skip = 100})
  T.eq(W.state().water, nil, 'the first run is still slicing the 90 citizens')
  day(W)
  T.ok(M.kpi(W.K) ~= nil)
  T.eq(M.kpi(W.K).patients, 0)
  local w = W.state().water
  T.eq({w.patients, w.thirst_max, w.hosp, w.hosp_ok, w.refuge_ok, #w.src}, {0, 0, 0, 0, 0, 0})
  T.eq(C.check_state(W.state()), {})
  local spec = C.STATE_SPEC.opt.water                          -- an older contract without the key: nothing
  C.STATE_SPEC.opt.water = nil
  T.eq(M.state(W.K), {})
  C.STATE_SPEC.opt.water = spec
end)

---------------------------------------------------------------- BUG-034 (Run 11)
-- Run 11 (Kilrudrabed site98, y439 spring d28): 5 bedridden patients died of thirst (75,000), 8 more were over 40,000;
-- the hospital (4 locations, 5 zones) had no accepted water and HOSPITAL_DRY had said so for a long time. The game
-- session removed the 5 zones by hand and GiveWater jobs brought water to the patients again (4 at once).
local function removable(W)                    -- the zones screen's remove: the zone leaves the vectors
  W.act_result('hospital_remove', function(id)
    local v = df.global.world.buildings.other.ANY_ZONE
    for i = #v - 1, 0, -1 do
      if v[i].id == id then v:erase(i); return true, 1 end
    end
    return false, 'no such zone'
  end)
end
local function zone_of(W, loc, box)            -- a second zone of an existing hospital location
  return F.building(W, 'ANY_ZONE', {x1 = box[1], y1 = box[2], x2 = box[3], y2 = box[4], z = box[5], location_id = loc})
end
local function logs(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if l.module == 'water' and l.msg:find(pat, 1, true) then r[#r + 1] = l end end
  return r
end
local function run11(opts)
  opts = opts or {}
  local pts = {}
  for i = 1, 8 do pts[#pts + 1] = {id = 2 + i, thirst = 40000 + i * 1000, care = true} end     -- 41k .. 48k
  pts[#pts + 1] = {id = 11, thirst = 9000, rest = true}
  pts[#pts + 1] = {id = 12, thirst = 12000, care = true}
  local W, M = world{cit = 16, patients = pts, rm = opts.rm, tiles = {['60,12,5'] = '~'}, setup = function(W)
    local z = {}
    z[1] = F.hospital(W, {10, 10, 14, 14, 5})
    z[2] = zone_of(W, z[1].location_id, {16, 10, 18, 12, 5})
    z[3] = F.hospital(W, {10, 20, 14, 24, 5})
    z[4] = F.hospital(W, {10, 30, 14, 34, 5})
    z[5] = F.hospital(W, {20, 30, 24, 34, 5})
    W.zones = z
    F.building(W, 'ZONE_WATER_SOURCE', {id = 90, type = df.civzone_type.WaterSource, x1 = 60, y1 = 12, x2 = 60,
                                        y2 = 12, z = 5, spec_sub_flag = {active = true}})       -- 46 tiles away
    removable(W)
    if opts.setup then opts.setup(W) end
  end}
  return W, M
end

T.test('BUG-034 (Run 11): a dry hospital with patients over 25,000: all 5 zones of its 4 locations are removed, ' ..
       'HOSPITAL_REMOVED (A) names zones, locations and patients; no patient_thirst or HOSPITAL_DRY beside it ' ..
       '(old: HOSPITAL_DRY only, the zones stayed and the patients died)', function()
  local W, M = run11()
  day(W)
  local z = W.zones
  local acts = W.find_acts('hospital_remove')
  T.eq(#acts, 5)
  local ids = {}
  for i, a in ipairs(acts) do ids[i] = a.args[1] end
  T.eq(ids, {z[1].id, z[2].id, z[3].id, z[4].id, z[5].id})
  local ev = W.find_events('HOSPITAL_REMOVED')
  T.eq(#ev, 1)
  local e = ev[1]
  T.eq(e.cls, 'A')
  T.eq(e.d.zones, ids)
  T.eq(e.d.locs, {z[1].location_id, z[3].location_id, z[4].location_id, z[5].location_id})
  T.eq({e.d.n, e.d.thirst, e.d.units[1], #e.d.units, e.d.patients, e.d.failed, e.d.near}, {8, 48000, 10, 8, 10, 0, 30})
  T.eq({e.d.src, e.d.d}, {{60, 12, 5}, 46})
  T.ok(e.msg:find('^removed 5 dry hospital zone%(s%) ' .. z[1].id .. ','), e.msg)
  T.ok(e.msg:find('8 patient(s) over thirst 25000, unit 10 at 48000; nearest accepted water 60,12,5 (46 tiles)', 1,
                  true), e.msg)
  T.ok(#e.msg <= 200, #e.msg)
  T.eq(#needed(W, 'patient_thirst'), 0, 'HOSPITAL_REMOVED carries the patients')
  T.eq(#W.find_events('HOSPITAL_DRY'), 0)
  T.eq(#logs(W, 'water: removed hospital zone(s) '), 1)
  local k = M.kpi(W.K)
  T.eq({k.removed, k.hosp, k.give}, {5, 0, 0})
  T.eq(W.state().water.hosp, 0)
  T.eq(W.state().water.src, {{60, 12, 5}})
  -- the next days: no hospital zone, so no dry gate and nothing to remove; a day later the GiveWater jobs are counted
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  W.unit(1).job.current_job = {job_type = 78}
  W.unit(13).job.current_job = {job_type = 78}
  day(W)
  T.eq(#W.find_acts('hospital_remove'), 5)
  T.eq(#W.find_events('HOSPITAL_REMOVED'), 1)
  T.eq(#W.find_events('HOSPITAL_DRY'), 0, 'no hospital zone left: no dry gate')
  local after = logs(W, 'a day after the hospital removal')
  T.eq(#after, 1)
  T.ok(after[1].msg:find(': 2 GiveWater job(s), 10 patient(s), max thirst 48000 (was 48000)', 1, true), after[1].msg)
  local rm = W.inbox('inspect', {what = 'water_sources'}).data.removed
  T.eq({rm.zones, rm.n, rm.tmax, rm.give, rm.after}, {ids, 8, 48000, 0, 2})
  day(W, 2)
  T.eq(#logs(W, 'a day after the hospital removal'), 1, 'once per removal')
  df.job_type.GiveWater, df.job_type[78] = nil, nil
end)

T.test('BUG-034: never while the hospital has a working source: a location with one served zone keeps all of its ' ..
       'zones; only the dry location goes', function()
  local W = run11{setup = function(W)
    well(W, 20, 12, 5)                                         -- 2 tiles from zone 2, 6 from zone 1 (location 1)
    W.cmap['20,12,4'] = '~'
  end}
  day(W)
  local ids = {}
  for i, a in ipairs(W.find_acts('hospital_remove')) do ids[i] = a.args[1] end
  -- zones 3 and 5 are within 30 tiles of the well too (served); zone 4 (10..14 x 30..34) is 18 tiles away: served
  T.eq(ids, {}, 'every location has a zone within 30 tiles of the wet well')
  T.eq(#W.find_events('HOSPITAL_REMOVED'), 0)
  T.eq({W.state().water.hosp, W.state().water.hosp_ok}, {5, 1})
  local W2 = run11{setup = function(W)
    W.cmap['20,12,4'] = '~'
    well(W, 20, 12, 5)
    local far = F.hospital(W, {80, 80, 84, 84, 5})              -- a fifth location 60 tiles from the well
    zone_of(W, W.zones[1].location_id, {80, 90, 82, 92, 5})     -- location 1 also has a far zone: it stays
    W.far = far
  end}
  day(W2)
  ids = {}
  for i, a in ipairs(W2.find_acts('hospital_remove')) do ids[i] = a.args[1] end
  T.eq(ids, {W2.far.id}, 'only the location without a served zone')
  T.eq(W2.find_events('HOSPITAL_REMOVED')[1].d.locs, {W2.far.location_id})
  T.eq({W2.state().water.hosp, W2.state().water.hosp_ok}, {6, 0}, 'location 1 keeps its far zone too')
  local W3 = run11{setup = function(W)
    W.cmap['20,12,4'] = '~'
    well(W, 20, 12, 5)
    W.far = F.hospital(W, {80, 80, 84, 84, 5})
  end}
  day(W3)
  T.eq(#W3.find_acts('hospital_remove'), 1)
  T.eq({W3.state().water.hosp, W3.state().water.hosp_ok}, {5, 1}, 'the zones left are all served')
end)

T.test('BUG-034: below patient_thirst nothing goes (HOSPITAL_DRY as before); config patient_thirst, hosp_remove false ' ..
       '(the old report), remove_per_run, a refused removal is tried again', function()
  local W = world{patients = {{id = 2, thirst = 24000, care = true}}, setup = function(W)
    F.hospital(W, {10, 10, 14, 14, 5}); removable(W)
  end}
  day(W)
  T.eq(#W.find_acts('hospital_remove'), 0)
  T.eq(#W.find_events('HOSPITAL_DRY'), 1)
  W.unit(2).counters2.thirst_timer = 26000
  day(W)
  T.eq(#W.find_acts('hospital_remove'), 1, 'over 25,000: removed')
  local function cfg_world(water, thirst)
    local W2 = world{patients = {{id = 2, thirst = thirst, care = true}}, setup = function(W)
      F.hospital(W, {10, 10, 14, 14, 5}); F.hospital(W, {10, 20, 14, 24, 5}); F.hospital(W, {10, 30, 14, 34, 5})
      removable(W)
    end}
    local cfg = F.cfg()
    cfg.water = water
    W2.K.cfg.baseline = cfg
    day(W2)
    return W2
  end
  T.eq(#cfg_world({patient_thirst = 40000}, 35000).find_acts('hospital_remove'), 0, 'a higher mark from config')
  T.eq(#cfg_world({patient_thirst = 'high'}, 35000).find_acts('hospital_remove'), 3, 'a string is ignored: 25,000')
  local off = cfg_world({hosp_remove = false}, 35000)
  T.eq(#off.find_acts('hospital_remove'), 0)
  T.eq(#needed(off, 'patient_thirst'), 1, 'report only, as before BUG-034')
  T.ok(needed(off, 'patient_thirst')[1].d.q:find('delete the hospital zone (GiveWater resumes', 1, true))
  local capped = cfg_world({remove_per_run = 2}, 35000)
  T.eq(#capped.find_acts('hospital_remove'), 2)
  T.eq(capped.find_events('HOSPITAL_REMOVED')[1].d.zones, {capped.find_acts('hospital_remove')[1].args[1],
                                                           capped.find_acts('hospital_remove')[2].args[1]})
  day(capped)
  T.eq(#capped.find_acts('hospital_remove'), 3, 'the rest in the next run')
  T.eq(#capped.find_events('HOSPITAL_REMOVED'), 2)
  -- a refused removal (the zone sheet is open): no event, the next run tries again
  local W3 = world{patients = {{id = 2, thirst = 30500, care = true}}, setup = function(W)
    F.hospital(W, {10, 10, 14, 14, 5})
  end}
  W3.act_result('hospital_remove', function() return false, 'zone sheet open' end)
  day(W3)
  T.eq(#W3.find_acts('hospital_remove'), 1)
  T.eq(#W3.find_events('HOSPITAL_REMOVED'), 0)
  T.eq(#needed(W3, 'patient_thirst'), 1, 'the patient_thirst line still comes')
  removable(W3)
  day(W3)
  T.eq(#W3.find_acts('hospital_remove'), 2)
  T.eq(W3.find_events('HOSPITAL_REMOVED')[1].d.n, 1)
end)

T.test('BUG-034: the state water.src lists the accepted sources nearest the hospital first (at most 8); a dry well and ' ..
       'a shallow zone are none', function()
  local W = world{tiles = {['30,12,4'] = '~', ['20,12,4'] = 'w', ['50,12,4'] = '.', ['70,12,5'] = '~'},
                  setup = function(W)
                    F.hospital(W, {10, 10, 14, 14, 5})
                    well(W, 30, 12, 5); well(W, 20, 12, 5); well(W, 50, 12, 5)
                    F.building(W, 'ZONE_WATER_SOURCE', {id = 91, type = df.civzone_type.WaterSource, x1 = 70, y1 = 12,
                                                        x2 = 70, y2 = 12, z = 5, spec_sub_flag = {active = true}})
                  end}
  day(W)
  local w = W.state().water
  T.eq(w.src, {{20, 12, 5}, {30, 12, 5}, {70, 12, 5}})
  T.eq({w.hosp, w.hosp_ok}, {1, 1})
  T.eq(C.check_state(W.state()), {})
end)

---------------------------------------------------------------- BUG-040 (Run 11, y453)
-- the cistern room of the live save: tpl cistern (merged into the manifest when its project is done), the well room
-- x49-51 y52-54 z2 with its well at 50,53 over the cistern on z1, the pond hole at 51,53
local CIS_MAN = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                 zones = {Z4 = {{0, 0, 0, 99, 99, 20}}},
                 rooms = {{id = 'cistern50_50_2r0', tpl = 'cistern', use = 'utility', bbox = {49, 52, 2, 51, 54, 2},
                           tier = 0}}}
local function cistern_world(opts)
  opts = opts or {}
  local wid
  local W, M = world{manifest = CIS_MAN, tiles = opts.tiles or {['50,53,1'] = '.'}, setup = function(W)
    df.civzone_type.Pond = 11
    df.civzone_type[11] = 'Pond'
    wid = well(W, 50, 53, 2).id
    if opts.pond ~= false then
      W.pond = F.building(W, 'ANY_ZONE', {id = 77, type = df.civzone_type.Pond, x1 = 51, y1 = 53, x2 = 51, y2 = 53,
                                          z = 2})
    end
    W.load({name = 'runner', every = {ticks = 600},
            kept_in = function(K, b) return b[1] == 49 and 'y450s0b0' or nil end,
            bp_params = function(K, id) return {path = opts.path or ''} end})
    if opts.setup then opts.setup(W) end
  end}
  return W, M, wid
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

T.test('BUG-040 (Run 11 y453: the cisterns y450s0b0 and y452s1b0 were PROJECT_DONE, their wells never wet, nobody ' ..
       'said why): a done cistern whose well stays dry for 30 days: CISTERN_DRY (B) once, with what should fill it; ' ..
       'wet again ends the spell, the next dry spell is reported again', function()
  local W, M, wid = cistern_world()
  day(W, 29)
  T.eq(#W.find_events('CISTERN_DRY'), 0, 'not before 30 days')
  day(W, 2)
  local e = W.find_events('CISTERN_DRY')
  T.eq(#e, 1, 'old code: never a word')
  T.eq(e[1].cls, 'B')
  T.eq({e[1].d.proj, e[1].d.room, e[1].d.fill, e[1].d.pond, e[1].d.well, e[1].d.days},
       {'y450s0b0', 'cistern50_50_2r0', 'pond', 77, wid, 30})
  T.eq(e[1].d.pos, {50, 53, 2})
  local want = string.format('cistern y450s0b0 done, its well %d at 50,53,2 dry for 30 days: bucket-fed (pond zone ' ..
                             '77); no accepted water to carry from (no revealed water source); no drink for a ' ..
                             'hospital or the refuge', wid)
  T.eq(e[1].msg, want)
  T.ok(logged(W, 'water: ' .. want), 'kern.log')
  day(W, 40)
  T.eq(#W.find_events('CISTERN_DRY'), 1, 'once per dry spell')
  W.cmap['50,53,1'] = 'w'                                    -- a few buckets reached the cistern: the well is wet
  day(W)
  T.ok(logged(W, 'water: cistern cistern50_50_2r0: its well ' .. wid .. ' holds water again'), 'kern.log')
  W.cmap['50,53,1'] = '.'
  day(W, 31)
  T.eq(#W.find_events('CISTERN_DRY'), 2, 'a new dry spell')
  -- a cistern room without a built well is no done cistern (HOSPITAL_DRY's cistern state says "no well")
  local W2 = world{manifest = CIS_MAN}
  day(W2, 32)
  T.eq(#W2.find_events('CISTERN_DRY'), 0)
end)

T.test('BUG-040: the reason names a pond zone water removed as a loop (the cistern\'s own well was the carriers\' ' ..
       'source), a pipe waiting for its lever, nothing at all, and the nearest accepted water to carry from', function()
  local C2 = require('dfllm.util.contract')
  -- the well was wet once (a bucket), the pond loop rule removed the cistern's pond zone, then the well dried again
  local W, M, wid = cistern_world{tiles = {['50,53,1'] = 'w'}, setup = function(W)
    W.act_result('pond_remove', function(id) W.pond.type = 0; return true, 1 end)
  end}
  C2.ACT.pond_remove = {'water'}
  day(W)
  T.ok(logged(W, 'water: pond zone 77 removed'), 'the pond loop rule')
  W.cmap['50,53,1'] = '.'
  day(W, 31)
  local e = W.find_events('CISTERN_DRY')
  T.eq(#e, 1)
  T.eq({e[1].d.fill, e[1].d.pond}, {'pond_removed', 77})
  T.ok(e[1].msg:find('bucket-fed, its pond zone 77 removed as a pond loop (its own well fed it)', 1, true), e[1].msg)
  -- piped: the floodgate waits for its lever; a wet well elsewhere is the water to carry from
  local W2, _, wid2 = cistern_world{pond = false, path = '1,6;1,9;4,9', tiles = {['50,53,1'] = '.', ['20,20,1'] = 'w'},
                                    setup = function(W) W.wid = well(W, 20, 20, 2).id end}
  day(W2, 31)
  e = W2.find_events('CISTERN_DRY')
  T.eq(#e, 1)
  T.eq({e[1].d.fill, e[1].d.src, e[1].d.d}, {'pipe', {20, 20, 2}, 32})
  T.ok(e[1].msg:find('piped: its floodgate waits for the lever (link it, pull it once); carry from: well ' .. W2.wid ..
                     ' at 20,20,2 (32 tiles)', 1, true), e[1].msg)
  T.ok(#e[1].msg <= 200)
  -- no pond zone, no pipe
  local W3 = cistern_world{pond = false}
  day(W3, 31)
  T.eq(W3.find_events('CISTERN_DRY')[1].d.fill, 'none')
  T.ok(W3.find_events('CISTERN_DRY')[1].msg:find('no pond zone, no pipe: nothing fills it', 1, true))
  T.eq(C.check_state(W3.state()), {})
end)

T.test('BUG-040: every accepted source is labelled with the burrow it stands on (state water.src_l, water.label); ' ..
       'wet_wells tells seal how many wells of a burrow are wet; inspect water_sources gives the depth under a well, ' ..
       'the burrow and where the refuge lies', function()
  local W, M = world{tiles = {['20,20,1'] = 'w', ['45,45,1'] = '.', ['80,80,1'] = '~'}, setup = function(W)
    W.burrow('Kern+', {0, 0, 0, 30, 30, 20})               -- Kern+ x0-30, Tiefe+ x40-60 z2
    W.w1, W.w2, W.w3 = well(W, 20, 20, 2).id, well(W, 45, 45, 2).id, well(W, 80, 80, 2).id
    W.load({name = 'seal', every = {ticks = 100000}, refuge_drink = function(K)
      return {name = 'Tiefe+', exists = true, drink = 0, need = 4, wells = 1, wet = false, wwet = 0,
              box = {40, 40, 2, 60, 60, 2}, near = {d = 20, at = {40, 40, 2}, src = {20, 20, 2}}}
    end})
  end}
  day(W)
  local w = W.state().water
  T.eq(w.src, {{20, 20, 2}, {80, 80, 2}})                  -- the dry Tiefe+ well is no source
  T.eq(w.src_l, {'well ' .. W.w1 .. ' in Kern+', 'well ' .. W.w3}, 'old code: no labels')
  T.eq(M.label(W.K, 20, 20, 2), 'well ' .. W.w1 .. ' at 20,20,2 in Kern+')
  T.eq(M.label(W.K, 1, 2, 3), 'accepted water at 1,2,3')
  T.eq({M.wet_wells(W.K, 'Tiefe+')}, {0, 1})
  T.eq({M.wet_wells(W.K, 'Kern+')}, {1, 1})
  T.eq(M.wet_wells(W.K, 'Nowhere+'), nil)
  local r = W.inbox('inspect', {what = 'water_sources'})
  T.ok(r.ok, r.msg)
  local by = {}
  for _, s in ipairs(r.data.sources) do by[s[2]] = s end
  T.eq(by[W.w1], {'well', W.w1, 20, 20, 2, 1, -1, 'Kern+'})   -- the mock's tiles carry no depth
  T.eq(by[W.w2], {'well', W.w2, 45, 45, 2, 0, 0, 'Tiefe+'})
  T.eq({r.data.refuge.name, r.data.refuge.box, r.data.refuge.d, r.data.refuge.src},
       {'Tiefe+', {40, 40, 2, 60, 60, 2}, 20, 'well ' .. W.w1 .. ' at 20,20,2 in Kern+'})
  T.eq(C.check_state(W.state()), {})
end)

---------------------------------------------------------------- BUG-054 (Run 11 y497): caregivers scale with the patients
-- Run 11 y497: 3-5 patients at thirst 30,000-40,293, 24-27 of 62 buckets free, 4 caregivers, a served hospital:
-- patient_thirst said "water, buckets and caregivers present" and nothing else happened; five died of thirst together.
-- Old code: nothing ever gave the FEED_WATER_CIVILIANS labor to anybody, 4 for 5 patients counted as "present".
local FEED, MINE_L = 40, 41
local function carer_world(opts)
  opts = opts or {}
  local W, M = world{cit = opts.cit or 14, patients = opts.patients, tiles = {['20,12,4'] = '_', ['20,12,3'] = '~'},
                     setup = function(W)
                       df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = MINE_L, CUTWOOD = 42, HUNT = 43}
                       F.hospital(W, {10, 10, 14, 14, 5}); well(W, 20, 12, 5)
                       for i = 1, opts.cit or 14 do
                         W.unit(i).status = {labors = {[FEED] = false, [MINE_L] = false, [42] = false, [43] = false}}
                       end
                       for _, id in ipairs(opts.carers or {}) do W.unit(id).status.labors[FEED] = true end
                       if opts.setup then opts.setup(W) end
                     end}
  for i = 1, 6 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  return W, M
end
local function details(W)
  local r = {}
  for _, a in ipairs(W.find_acts('work_detail')) do r[#r + 1] = {a.args[1], a.args[2], a.args[3]} end
  return r
end

T.test('BUG-054: 5 patients over the alarm, 4 caregivers, a served hospital: the Orderlies detail grows to the want ' ..
       '(per patient + urgent, at most carers_max), 2 a run, and patient_thirst names it', function()
  local pats = {}
  for i, th in ipairs({30000, 31500, 36000, 38800, 40293}) do pats[i] = {id = 4 + i, thirst = th, care = true, pos = {12, 12, 5}} end
  local W, M = carer_world{patients = pats, carers = {1, 2, 3, 4}}
  W.act_result('work_detail', function(name, id, on)
    W.unit(id).status.labors[FEED] = on
    return true, on and 'added' or 'removed'
  end)
  day(W)
  -- want = 5 patients x 1 = 5, + 2 urgent = 7; have 4; carers_per_run 2
  local d1 = details(W)
  T.eq(#d1, 2)
  T.eq({d1[1][1], d1[1][3], d1[2][1], d1[2][3]}, {'Orderlies', true, 'Orderlies', true})
  T.eq(W.find_acts('work_detail')[1].args[4], {select = true}, 'a detail on "nobody does this" is switched to selected')
  local pt = needed(W, 'patient_thirst')
  T.eq(#pt, 1)
  T.ok(pt[1].msg:find('caregivers short: 6 of 7 wanted for 5 patient(s), 2 added to Orderlies now', 1, true), pt[1].msg)
  T.eq({pt[1].d.n_carers, pt[1].d.want, pt[1].d.added}, {6, 7, 2})
  T.ok(#pt[1].msg <= 200 and #pt[1].d.q <= 200)
  day(W)
  T.eq(#details(W), 3, 'the third one next run, then enough')
  day(W, 2)
  T.eq(#details(W), 3)
  T.eq(M.kpi(W.K).carers, 7, 'the census sees the labor the act gave')
  local ins = W.inbox('inspect', {what = 'water_sources'})
  T.ok(ins.ok, ins.msg)
  T.eq({ins.data.carers.have, ins.data.carers.want, ins.data.carers.mine}, {7, 7, 3}, 'inspect: the caregivers\' state')
  T.eq(#needed(W, 'patient_thirst'), 1)
  df.unit_labor = nil
end)

T.test('BUG-054: the census sees the new caregivers: no more additions at the want; the bounds hold (carers_max)', function()
  local pats = {}
  for i = 1, 9 do pats[i] = {id = 3 + i, thirst = 31000, care = true} end
  local W, M = carer_world{cit = 16, patients = pats, carers = {1, 2}}
  W.act_result('work_detail', function(name, id, on)
    W.unit(id).status.labors[FEED] = on
    return true, on and 'added' or 'removed'
  end)
  day(W, 5)
  -- 9 patients x 1 + 2 urgent = 11 -> carers_max 8; only 3 citizens are free (16 - 9 patients - 2 carers = 5 candidates)
  T.eq(M.kpi(W.K).carers, 7, '2 + 5 free citizens: all candidates used, the rest is short')
  local pt = needed(W, 'patient_thirst')
  T.ok(pt[1].msg:find('caregivers short: 4 of 8 wanted', 1, true) or pt[1].msg:find('caregivers short', 1, true), pt[1].msg)
  local cfg = F.cfg()
  cfg.water = {carers_max = 0}
  local W2 = carer_world{patients = {{id = 5, thirst = 41000, care = true}}, carers = {1}}
  W2.K.cfg.baseline = cfg
  day(W2)
  T.eq(#details(W2), 0, 'carers_max 0 switches the scaling off')
end)

T.test('BUG-054: the candidates: idle first, then the nearest the hospital; never a soldier, a dwarf in a mood, a noble, ' ..
       'a miner, a child or a patient', function()
  local W = carer_world{cit = 10, patients = {{id = 5, thirst = 41000, care = true}}, carers = {1}, setup = function(W)
    W.unit(2).military.squad_id = 3                                   -- a soldier
    W.unit(3).mood = 4                                                -- in a mood
    W.unit(4).status.labors[MINE_L] = true                            -- a miner
    W.unit(6)._m.adult = false                                        -- a child
    W.unit(7).job = {current_job = {id = 1}}                          -- busy, nearest
    W.move(7, 12, 12, 5)
    W.unit(8).job = {current_job = nil}                               -- idle, far
    W.move(8, 90, 90, 5)
    W.unit(9).job = {current_job = nil}                               -- idle, nearer
    W.move(9, 30, 30, 5)
    W.unit(10).job = {current_job = nil}
    W.move(10, 12, 13, 5)
    dfhack.units.getNoblePositions = function(u) if u.id == 10 then return {{position = {code = 'BROKER'}}} end end
  end}
  W.act_result('work_detail', function(name, id, on)
    W.unit(id).status.labors[FEED] = on
    return true, 'added'
  end)
  day(W)
  -- want = 1 + 2 urgent... 1 patient x 1 = max(2, 1) = 2, + 2 urgent = 4; have 1; 2 a run: units 9 then 8 (idle, nearest)
  local d = details(W)
  T.eq({d[1][2], d[2][2]}, {9, 8})
  day(W)
  d = details(W)
  T.eq(d[3] and d[3][2], 7, 'then the busy one; the soldier, mood, noble, miner, child and patient never')
  T.eq(#d, 3)
  dfhack.units.getNoblePositions = nil
  df.unit_labor = nil
end)

T.test('BUG-054: the kernel never holds more than carers_max members in the detail when its labors grant no caregiver ' ..
       '(the act changes nothing the census sees): the shortfall says so', function()
  local pats = {}
  for i = 1, 5 do pats[i] = {id = 3 + i, thirst = 31000, care = true} end
  local W, M = carer_world{cit = 20, patients = pats, carers = {1}}
  day(W, 12)
  local added = 0
  for _, d in ipairs(details(W)) do if d[3] == true then added = added + 1 end end
  T.eq(added, 8, 'carers_max 8 members, then no more')
  local ins = W.inbox('inspect', {what = 'water_sources'})
  T.eq({ins.data.carers.have, ins.data.carers.want, ins.data.carers.mine}, {1, 7, 8})
  T.eq(ins.data.carers.err, '8 citizens added to Orderlies hold no FEED_WATER_CIVILIANS labor')
  T.eq(M.kpi(W.K).carers, 1)
  df.unit_labor = nil
end)

T.test('BUG-054: hysteresis: the kernel\'s own additions leave one a run, carers_hold_days after the last patient', function()
  local W, M = carer_world{patients = {{id = 5, thirst = 41000, care = true}}, carers = {1}}
  W.act_result('work_detail', function(name, id, on)
    W.unit(id).status.labors[FEED] = on
    return true, on and 'added' or 'removed'
  end)
  day(W, 3)
  T.eq(M.kpi(W.K).carers, 4)
  local n = #details(W)
  W.unit(5).health = nil                                              -- the patient is healed
  day(W, 13)
  T.eq(#details(W), n, 'held for 14 days')
  day(W, 1)
  T.eq(#details(W), n + 1, 'then one leaves')
  T.eq(details(W)[n + 1][3], false)
  day(W, 4)
  T.eq(#details(W), n + 3, 'one a run; unit 1 (not ours) stays')
  T.eq(W.unit(1).status.labors[FEED], true)
  day(W, 3)
  T.eq(#details(W), n + 3)
  df.unit_labor = nil
end)

T.test('BUG-054: no Orderlies detail: the failure is named once and asked again after a week; without the contract owner ' ..
       'water writes nothing', function()
  local W = carer_world{patients = {{id = 5, thirst = 41000, care = true}}, carers = {1}}
  W.act_result('work_detail', function() return false, 'no work detail Orderlies' end)
  day(W)
  T.eq(#details(W), 1)
  local pt = needed(W, 'patient_thirst')
  T.ok(pt[1].msg:find('could not add: no work detail Orderlies', 1, true), pt[1].msg)
  day(W, 6)
  T.eq(#details(W), 1, 'a missing detail is not asked for again within a week')
  day(W, 2)
  T.eq(#details(W), 2)
  local C2 = require('dfllm.util.contract')
  local keep = {}
  for _, o in ipairs(C2.ACT.work_detail) do if o ~= 'water' then keep[#keep + 1] = o end end
  C2.ACT.work_detail = keep
  local W2 = carer_world{patients = {{id = 5, thirst = 41000, care = true}}, carers = {1}}
  day(W2)
  T.eq(#details(W2), 0, 'feature detection: no owner, no write')
  C2.ACT.work_detail = {'economy', 'water'}
  df.unit_labor = nil
end)

T.test('BUG-054: a patient at the death-risk line is PATIENT_DYING (A) with the caregivers\' state, once; news wakes it, ' ..
       'the same set does not repeat before dying_every and the wall clock', function()
  local pats = {{id = 5, thirst = 61000, care = true}, {id = 6, thirst = 45000, care = true}}
  local W, M = carer_world{patients = pats, carers = {1, 2}, setup = function(W)
    df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
    W.unit(1).job = {current_job = {job_type = 78}}                   -- one is giving water, one stands idle
  end}
  W.act_result('work_detail', function(name, id, on)
    W.unit(id).status.labors[FEED] = on
    return true, 'added'
  end)
  day(W)
  local ev = W.find_events('PATIENT_DYING')
  T.eq(#ev, 1)
  T.eq(ev[1].cls, 'A')
  T.eq({ev[1].d.units, ev[1].d.n, ev[1].d.thirst, ev[1].d.hosp, ev[1].d.give}, {{5}, 1, 61000, 'ok', 1})
  T.eq({ev[1].d.carers, ev[1].d.want, ev[1].d.idle, ev[1].d.added, ev[1].d.buckets}, {4, 4, 1, 2, 6})
  T.eq({ev[1].d.open, ev[1].d.run}, {0, 0}, 'job list read: none')
  T.ok(ev[1].msg:find('1 patient(s) near death of thirst (>= 60000), unit 5 at 61000: hospital ok, caregivers 4 of 4 wanted '
                      .. '(1 idle), 1 giving water', 1, true), ev[1].msg)
  T.ok(#ev[1].msg <= 200 and #ev[1].d.why <= 120)
  W.unit(6).counters2.thirst_timer = 62000                            -- another patient crosses the line
  day(W)
  T.eq(#W.find_events('PATIENT_DYING'), 1, 'news, but within dying_every (2 days)')
  day(W)
  T.eq(#W.find_events('PATIENT_DYING'), 1, 'two days passed, the wall clock waits (BUG-008)')
  W.ms = W.ms + 600000
  day(W)
  ev = W.find_events('PATIENT_DYING')
  T.eq(#ev, 2)
  T.eq(ev[2].d.units, {6, 5}, 'thirstiest first')
  day(W, 4)
  W.ms = W.ms + 600000
  day(W)
  T.eq(#W.find_events('PATIENT_DYING'), 2, 'the same patients, the same state: no repeat')
  W.unit(5).counters2.thirst_timer, W.unit(6).counters2.thirst_timer = 1000, 1000
  day(W)
  W.unit(5).counters2.thirst_timer = 63000                            -- a new episode starts at once after a quiet run
  W.ms = W.ms + 600000
  day(W, 2)
  T.eq(#W.find_events('PATIENT_DYING'), 3)
  df.job_type.GiveWater, df.job_type[78] = nil, nil
  df.unit_labor = nil
end)

T.test('BUG-054: PATIENT_DYING names a dry hospital and no caregiver; below the line only patient_thirst', function()
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED}
  local W = world{rm = false, patients = {{id = 2, thirst = 65000, rest = true, pos = {12, 12, 5}}},
                  setup = function(W)
                    F.hospital(W, {10, 10, 14, 14, 5})
                    for i = 1, 4 do W.unit(i).status = {labors = {[FEED] = false}} end
                  end}
  day(W)
  local ev = W.find_events('PATIENT_DYING')
  T.eq(#ev, 1)
  T.eq({ev[1].d.hosp, ev[1].d.carers < ev[1].d.want}, {'dry', true})
  local W2 = carer_world{patients = {{id = 5, thirst = 59000, care = true}}, carers = {1, 2, 3, 4}}
  day(W2)
  T.eq(#W2.find_events('PATIENT_DYING'), 0)
  T.eq(#needed(W2, 'patient_thirst'), 1)
  df.unit_labor = nil
end)


-- BUG-056 (Run 11, note 11): 8 abstract HOSPITAL locations stayed after their zones were deleted
T.test('BUG-056: hospital locations without a zone disturb no count: hosp, the dry gate, hosp_out and the removal go by ' ..
       'zones; inspect water_sources says how many are stale', function()
  local W, M = world{patients = {{id = 2, thirst = 41000, care = true}}, setup = function(W)
    for i = 1, 8 do                                                   -- eight locations whose zones were deleted
      W.site.buildings:insert('#', {id = 700 + i, getType = function() return df.abstract_building_type.HOSPITAL end})
    end
    F.hospital(W, {10, 10, 14, 14, 5}); well(W, 20, 12, 5)            -- one live hospital, served
  end, tiles = {['20,12,4'] = '_', ['20,12,3'] = '~'}}
  day(W)
  local k = M.kpi(W.K)
  T.eq({k.hosp, k.hosp_ok, k.hosp_out}, {1, 1, 0})
  T.eq(#W.find_events('HOSPITAL_DRY'), 0)
  T.eq(#W.find_acts('hospital_remove'), 0)
  local r = W.inbox('inspect', {what = 'water_sources'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.locs, {total = 9, live = 1, stale = 8})
  -- no zone at all, 8 locations: no hospital, no gate, nothing to remove; patient_thirst says "no hospital zone"
  local W2, M2 = world{patients = {{id = 2, thirst = 41000, care = true}}, setup = function(W)
    for i = 1, 8 do
      W.site.buildings:insert('#', {id = 700 + i, getType = function() return df.abstract_building_type.HOSPITAL end})
    end
  end}
  day(W2)
  local k2 = M2.kpi(W2.K)
  T.eq({k2.hosp, k2.gate, k2.hosp_out, k2.removed}, {0, 0, 0, 0})
  T.eq(#W2.find_events('HOSPITAL_DRY'), 0)
  T.ok(needed(W2, 'patient_thirst')[1].msg:find('no hospital zone', 1, true))
  T.eq(W2.state().water.hosp, 0)
  T.eq(W2.inbox('inspect', {what = 'water_sources'}).data.locs, {total = 8, live = 0, stale = 8})
end)

---------------------------------------------------------------- BUG-131 (Run 14)
-- Run 14 (site90): readiness R0 hospital_out stayed red the whole run: an old hospital zone 24422 at 88,28 lay outside
-- Kern+/Tiefe+ ("1 of 3 zones") while the fort had or built a hospital inside; the session may not delete zones, so goal
-- G3 never turned green. o: old_beds (beds in the old zone outside), new (a hospital zone inside Kern+), new_beds (1),
-- sup (the old location's contents; false: no fields), nofind (no findAtTile: the furniture is unknown), patients
local function loc_of(W, id)
  for _, l in ipairs(W.site.buildings) do if l.id == id then return l end end
end
local SUP0 = {count_splints = 0, count_thread = 0, count_cloth = 0, count_crutches = 0, count_powder = 0, count_soap = 0,
              count_buckets = 0}
local function b131(o)
  o = o or {}
  return world{patients = o.patients, setup = function(W)
    W.burrow('Kern+', {0, 0, 0, 30, 30, 20})             -- the core: x0-30 y0-30
    df.building_type.TractionBench = df.building_type.TractionBench or 98
    W.old = F.hospital(W, {86, 26, 90, 30, 5})           -- the old zone outside, centre 88,28,5
    local loc = loc_of(W, W.old.location_id)
    if o.sup ~= false then
      loc.contents = {}
      for k, v in pairs(o.sup or SUP0) do loc.contents[k] = v end
    end
    local beds = {}
    local function bed(x, y, z)
      beds[x .. ',' .. y .. ',' .. z] = {id = 9000 + x * 100 + y, getType = function() return df.building_type.Bed end}
    end
    for i = 1, o.old_beds or 0 do bed(86 + i, 27, 5) end
    if o.new then
      W.new = F.hospital(W, {10, 10, 14, 14, 5})
      for i = 1, o.new_beds or 1 do bed(10 + i, 11, 5) end
    end
    if o.second then W.second = zone_of(W, W.old.location_id, {86, 40, 88, 42, 5}) end
    if not o.nofind then
      dfhack.buildings.findAtTile = function(x, y, z) return beds[x .. ',' .. y .. ',' .. z] end
    end
    removable(W)
    if o.setup then o.setup(W) end
  end}
end
local function hout(W, M) return M.kpi(W.K).hosp_out, M.hospital_out(W.K) end

T.test('BUG-131 (Run 14: hospital_out red the whole run over the old zone 24422 at 88,28): a hospital zone outside the ' ..
       'core with no patient, no bed and no supply does not block; one with a bed, a patient lying in it, a supply or ' ..
       'unknown furniture or supplies does (old code: every zone outside blocked)', function()
  local W, M = b131{}
  day(W)
  local n, ho = hout(W, M)
  T.eq({n, ho.n, ho.raw, ho.total}, {0, 0, 1, 1}, 'old code: hosp_out 1')
  T.eq({#ho.ign, ho.ign[1] and ho.ign[1].id, ho.ign[1] and ho.ign[1].why}, {1, W.old.id, 'idle'})
  T.eq(W.state().water.hosp_out, 0)
  T.eq(W.state().water.hout, nil, 'nothing blocks: no blocking zone in the state')
  T.eq(#W.find_acts('hospital_remove'), 0, 'ignored, never removed by the kernel itself')
  local cases = {{{old_beds = 1}, 'a bed'}, {{patients = {{id = 2, thirst = 1000, rest = true, pos = {88, 28, 5}}}},
                 'a patient lying in it'}, {{sup = {count_splints = 3}}, 'a supply'}, {{sup = false}, 'supplies unknown'},
                 {{nofind = true}, 'furniture unknown'}}
  for _, cs in ipairs(cases) do
    local W2, M2 = b131(cs[1])
    day(W2)
    local n2, ho2 = hout(W2, M2)
    T.eq({n2, ho2.n, #ho2.ign}, {1, 1, 0}, cs[2])
  end
end)

T.test('BUG-131: an old hospital outside the core is superseded by a finished hospital inside Kern+/Tiefe+ (a zone ' ..
       'with a bed): it does not block unless a patient lies in it; the state names the blocking zone (hout)', function()
  local W, M = b131{old_beds = 2, new = true}
  day(W)
  local n, ho = hout(W, M)
  T.eq({n, ho.raw, ho.fin}, {0, 1, W.new.id}, 'old code: hosp_out 1')
  T.eq({ho.ign[1].id, ho.ign[1].why}, {W.old.id, 'superseded'})
  -- a patient still lies in the old zone: it blocks; the state names it, retire allowed once he is gone (ok 1)
  local W2, M2 = b131{old_beds = 2, new = true, patients = {{id = 2, thirst = 1000, rest = true, pos = {87, 27, 5}}}}
  day(W2)
  T.eq(hout(W2, M2), 1)
  T.eq(W2.state().water.hout, {z = W2.old.id, at = {88, 28, 5}, ok = 1, pat = 1})
  -- the new hospital is still being built (no bed yet): the old one blocks, retire only with approve (ok 0)
  local W3, M3 = b131{old_beds = 2, new = true, new_beds = 0}
  day(W3)
  T.eq(hout(W3, M3), 1)
  T.eq(W3.state().water.hout, {z = W3.old.id, at = {88, 28, 5}, ok = 0, pat = 0})
end)

T.test('BUG-131: verb hospital.retire {zone} = the zones screen remove for a hospital zone outside the core: PEACE only, ' ..
       'no patient lying in it, a finished hospital inside Kern+/Tiefe+ or approve:true; the reply names the zone, its ' ..
       'place and what becomes of its location (BUG-056/077)', function()
  local W, M = b131{old_beds = 2}
  day(W)
  local id = W.old.id
  W.set_mode('ALERT')
  local r = W.inbox('hospital.retire', {zone = id})
  T.eq(r.ok, false)
  T.ok(r.msg:find('not allowed in ALERT', 1, true), r.msg)
  W.set_mode('PEACE')
  r = W.inbox('hospital.retire', {zone = id})
  T.eq(r.ok, false, 'no finished hospital inside and no approve')
  T.ok(r.msg:find('no finished hospital inside Kern+/Tiefe+', 1, true) and r.msg:find('approve:true', 1, true), r.msg)
  T.eq(#W.find_acts('hospital_remove'), 0)
  r = W.inbox('hospital.retire', {zone = 4242})
  T.eq(r.ok, false)
  T.ok(r.msg:find('no hospital zone 4242', 1, true), r.msg)
  r = W.inbox('hospital.retire', {zone = id, approve = true})
  T.ok(r.ok, r.msg)
  T.eq(#W.find_acts('hospital_remove'), 1)
  T.eq(W.find_acts('hospital_remove')[1].args[1], id)
  T.ok(r.msg:find(string.format('retired hospital zone %d at 88,28,5 (location %d', id, W.old.location_id), 1, true), r.msg)
  T.ok(r.msg:find('no zone left', 1, true), r.msg)
  T.eq({r.data.zone, r.data.at, r.data.loc, r.data.left, r.data.approve}, {id, {88, 28, 5}, W.old.location_id, 0, 1})
  T.ok(#r.msg <= 300)
  local n, ho = hout(W, M)
  T.eq({n, ho.n}, {0, 0}, 'the blocker goes at once')
  T.eq(W.state().water.hosp_out, 0)
  day(W)
  T.eq(hout(W, M), 0)
  -- a patient lying in it: refused, even with approve
  local W2 = b131{old_beds = 2, new = true, patients = {{id = 2, thirst = 1000, rest = true, pos = {87, 27, 5}}}}
  day(W2)
  r = W2.inbox('hospital.retire', {zone = W2.old.id, approve = true})
  T.eq(r.ok, false)
  T.ok(r.msg:find('1 patient lies in it', 1, true), r.msg)
  -- a zone inside the core: refused
  r = W2.inbox('hospital.retire', {zone = W2.new.id, approve = true})
  T.eq(r.ok, false)
  T.ok(r.msg:find('inside Kern+/Tiefe+', 1, true), r.msg)
  T.eq(#W2.find_acts('hospital_remove'), 0)
  -- superseded by a finished hospital inside: no approve needed; the location keeps its second zone
  local W3 = b131{old_beds = 2, new = true, second = true}
  day(W3)
  r = W3.inbox('hospital.retire', {zone = W3.old.id})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('keeps 1 zone', 1, true), r.msg)
  T.eq({r.data.left, r.data.approve}, {1, 0})
end)


T.done()
