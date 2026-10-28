-- water, package M1 (Run 14 notes 74, 79, 90): BUG-103 a resident or merchant is no patient and no caregiver; BUG-104 the
-- patient_thirst / PATIENT_DYING text names why no GiveWater job runs, in counts (the 'added' of the DECISION_NEEDED counts
-- caregivers put into the Orderlies work detail, never jobs: nothing in the kernel creates a job); BUG-106 `inspect
-- what=hospital` lists every gap of the wound care. Every test here fails on the commit before the package (32994bb).
local C = require('dfllm.util.contract')
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local FEED, MINE_L = 40, 41

local function owners(on)
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'work_detail'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn]) do if o ~= 'water' then keep[#keep + 1] = o end end
    if on then keep[#keep + 1] = 'water' end
    C.ACT[fn] = keep
  end
end

local function fresh() package.loaded['dfllm.water'] = nil; return require('dfllm.water') end

-- GiveWater jobs on the job list: list = {{id, worker = unit id | nil}}
local function jobs(list)
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  local head
  for i = #list, 1, -1 do
    head = {item = {job_type = 78, id = list[i].id, _worker = list[i].worker}, next = head}
  end
  df.global.world.jobs = {list = {next = head}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return j._worker end
end

-- opts: cit, patients = {{id, thirst, care, pos}}, carers = {ids}, hospital (default true), jobs, reach (function(a, b)),
-- alert (burrow name the civ alert holds the citizens in), setup(W)
local function world(opts)
  opts = opts or {}
  owners(true)
  local n = opts.cit or 14
  local units = {}
  for i = 1, n do units[i] = {id = i, citizen = true, pos = {50, 50, 10}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = MINE_L, CUTWOOD = 42, HUNT = 43, DIAGNOSE = 50, SURGERY = 51,
                   BONE_SETTING = 52, SUTURE = 53, DRESSING_WOUNDS = 54}
  local ids = {}
  for i = 1, n do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000}
    u.job = {current_job = nil}
    u.status = {labors = {[FEED] = false, [MINE_L] = false, [42] = false, [43] = false, [50] = false, [51] = false,
                          [52] = false, [53] = false, [54] = false}}
  end
  for _, id in ipairs(opts.carers or {}) do W.unit(id).status.labors[FEED] = true end
  for _, pt in ipairs(opts.patients or {}) do
    local u = W.unit(pt.id)
    u.counters2.thirst_timer = pt.thirst
    if pt.care then u.health = {flags = {needs_healthcare = true}} end
    if pt.pos then W.move(pt.id, pt.pos[1], pt.pos[2], pt.pos[3]) end
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z) return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'),
                                              dig = '', bld = ''} end,
          reach = opts.reach and function(K, a, b) return opts.reach(a, b) end or nil})
  if opts.alert then
    df.global.plotinfo.alerts.civ_alert_idx = 1
    W.load({name = 'siege', every = {ticks = 1000}, alert_names = function() return {opts.alert} end})
  end
  if opts.hospital ~= false then
    F.hospital(W, {10, 10, 14, 14, 5})
    F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  end
  for i = 1, (opts.buckets == false) and 0 or 6 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  jobs(opts.jobs or {})
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

---------------------------------------------------------------- BUG-103
T.test('BUG-103: a resident or merchant far outside the fort is no patient and no caregiver: no patient_thirst, no ' ..
       'PATIENT_DYING, no hospital removal; a citizen patient at the same thirst is all three', function()
  local function run(citizen)
    local W, M = world{cit = 6, carers = {1, 2}, hospital = false, setup = function(W)
      W.add_unit({id = 9, citizen = citizen, resident = not citizen, pos = {190, 23, 133}})
      local u = W.unit(9)
      u.counters2 = {thirst_timer = 70000}
      u.job = {current_job = nil}
      u.health = {flags = {needs_healthcare = true}}
      u.status = {labors = {[FEED] = true}}
      W.set_census('u', F.census_u({1, 2, 3, 4, 5, 6, 9}))
    end}
    day(W)
    return W, M
  end
  local W, M = run(false)
  T.eq(#needed(W, 'patient_thirst'), 0)
  T.eq(#W.find_events('PATIENT_DYING'), 0)
  T.eq(#W.find_events('HOSPITAL_REMOVED'), 0)
  T.eq(M.kpi(W.K).patients, 0)
  T.eq(M.kpi(W.K).carers, 2, 'he is no caregiver either: his labor does not count')
  local W2, M2 = run(true)
  T.eq(M2.kpi(W2.K).patients, 1)
  T.eq(#needed(W2, 'patient_thirst'), 1)
  T.eq(#W2.find_events('PATIENT_DYING'), 1)
end)

---------------------------------------------------------------- BUG-104
local function wake(W)
  local pt = needed(W, 'patient_thirst')
  T.eq(#pt, 1)
  T.ok(#pt[1].msg <= 200 and #pt[1].d.q <= 200, #pt[1].msg .. '/' .. #pt[1].d.q)
  return pt[1]
end

T.test('BUG-104: note 79 (buckets and caregivers present, no GiveWater job): the line says the game posts no job, in counts; ' ..
       '`added` stays the caregivers put into the Orderlies detail', function()
  local W = world{patients = {{id = 5, thirst = 41000, care = true, pos = {12, 12, 5}}}, carers = {1, 2, 3, 4, 6, 7},
                  setup = function(W) W.unit(1).job = {current_job = {id = 9, job_type = 5}} end}
  day(W)
  local e = wake(W)
  T.eq({e.d.added, e.d.n_carers, e.d.open, e.d.run, e.d.key}, {0, 6, 0, 0, 'nojob'})
  T.ok(not e.msg:find('water, buckets and caregivers present', 1, true), e.msg)
  T.ok(e.msg:find('the game posts no GiveWater job', 1, true), e.msg)
  T.ok(e.msg:find('jobs 0 open/0 running', 1, true) and e.msg:find('carers 6 (5 idle, 6 reach', 1, true), e.msg)
  T.ok(e.msg:find('buckets 6 free of 6', 1, true), e.msg)
  T.ok(e.d.q:find('the game posts no GiveWater job', 1, true), e.d.q)
end)

T.test('BUG-104: open jobs nobody takes: open, and stuck once they stood open for give_stuck_days (2)', function()
  local W = world{patients = {{id = 5, thirst = 20000, care = true, pos = {12, 12, 5}}}, carers = {1, 2, 3, 4},
                  jobs = {{id = 501}, {id = 502}}}
  day(W, 3)                                                            -- the patient is below the alarm: nothing wakes yet
  T.eq(#needed(W, 'patient_thirst'), 0)
  W.unit(5).counters2.thirst_timer = 41000
  day(W)
  local e = wake(W)
  T.eq({e.d.open, e.d.run, e.d.stuck, e.d.key}, {2, 0, 2, 'stuck'})
  T.ok(e.msg:find('2 GiveWater jobs open 2+ days', 1, true), e.msg)
  local W2 = world{patients = {{id = 5, thirst = 41000, care = true, pos = {12, 12, 5}}}, carers = {1, 2, 3, 4},
                   jobs = {{id = 501}}}
  day(W2)
  local e2 = wake(W2)
  T.eq({e2.d.open, e2.d.stuck, e2.d.key}, {1, 0, 'open'}, 'first seen today: open, not yet stuck')
  T.ok(e2.msg:find('1 GiveWater job open, none taken by 4 idle', 1, true), e2.msg)
end)

T.test('BUG-104: a job a caregiver carries out is running; the text says so', function()
  local W = world{patients = {{id = 5, thirst = 41000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                  jobs = {{id = 501, worker = 1}}}
  day(W)
  local e = wake(W)
  T.eq({e.d.open, e.d.run, e.d.key}, {0, 1, 'run'})
  T.ok(e.msg:find('1 GiveWater job running', 1, true), e.msg)
end)

T.test('BUG-104: no caregiver reaches the patient (the walk groups differ): named with the count of caregivers asked', function()
  local W = world{patients = {{id = 5, thirst = 41000, care = true, pos = {12, 12, 5}}}, carers = {1, 2, 3},
                  reach = function(a, b) return false end}
  day(W)
  local e = wake(W)
  T.eq({e.d.reach, e.d.key}, {0, 'noreach'})
  T.ok(e.msg:find('no caregiver reaches the patient (0 of 3)', 1, true), e.msg)
end)

T.test('BUG-104: the civ alert holds the caregivers in Kern+ while the patient lies outside it: named', function()
  local W = world{patients = {{id = 5, thirst = 41000, care = true, pos = {150, 50, 5}}}, carers = {1, 2, 3},
                  alert = 'Kern+'}
  day(W)
  local e = wake(W)
  T.eq(e.d.key, 'alert')
  T.ok(e.msg:find('the civ alert holds the caregivers in Kern+', 1, true), e.msg)
end)

T.test('BUG-104: PATIENT_DYING carries the same counts and the reason; a changed reason is news', function()
  local W = world{patients = {{id = 5, thirst = 61000, care = true, pos = {12, 12, 5}}}, carers = {1, 2, 3}}
  day(W)
  local ev = W.find_events('PATIENT_DYING')
  T.eq(#ev, 1)
  T.eq({ev[1].d.open, ev[1].d.run, ev[1].d.stuck, ev[1].d.key}, {0, 0, 0, 'nojob'})
  T.ok(ev[1].msg:find('the game posts no GiveWater job', 1, true), ev[1].msg)
  T.ok(#ev[1].msg <= 200)
  df.global.world.jobs.list.next = {item = {job_type = 78, id = 700, _worker = 2}}     -- a caregiver takes a job
  day(W, 2)
  W.ms = W.ms + 600000
  day(W)
  ev = W.find_events('PATIENT_DYING')
  T.eq(#ev, 2, 'the reason changed: nojob -> run')
  T.eq(ev[2].d.key, 'run')
end)

T.test('BUG-104: no free bucket is said in counts: how many exist, hold water, are forbidden', function()
  local W = world{patients = {{id = 5, thirst = 41000, care = true, pos = {12, 12, 5}}}, carers = {1, 2, 3}, buckets = false,
                  setup = function(W)
    F.item(W, 'BUCKET', {_pos = {20, 20, 5}, _contents = {{id = 900}}})              -- holds water
    F.item(W, 'BUCKET', {_pos = {150, 20, 5}, flags = {forbid = true}})               -- forbidden, outside Kern+
  end}
  day(W)
  local e = wake(W)
  T.ok(e.msg:find('no free bucket (2 in the fort, 1 hold water, 1 forbidden)', 1, true), e.msg)
  T.eq(e.d.buckets, 0)
end)

---------------------------------------------------------------- BUG-106
-- opts for audit_world: furniture {bed = n, table = n, bench = n} in the zone, doctors = {[labor key] = {unit ids}},
-- skilled = {unit ids with every skill 3}, supplies (the location contents) or false (no fields)
local BT = {Bed = 5, Table = 6, TractionBench = 7}
local SK = {DIAGNOSE = 1, SURGERY = 2, SET_BONE = 3, SUTURE = 4, DRESS_WOUNDS = 5}
local LAB = {diag = 50, surg = 51, bone = 52, suture = 53, dress = 54}
local FULL = {desired_splints = 5, count_splints = 5, desired_thread = 5, count_thread = 5, desired_cloth = 5, count_cloth = 5,
              desired_crutches = 2, count_crutches = 2, desired_powder = 3, count_powder = 3, desired_soap = 2,
              count_soap = 2, desired_buckets = 4, count_buckets = 4, need_more = {}}

local function audit_world(o)
  o = o or {}
  local doctors = o.doctors or {}
  local W, M = world{cit = o.cit or 8, carers = o.carers or {6, 7}, patients = o.patients, hospital = false,
                     setup = function(W)
    for k, v in pairs(BT) do df.building_type[k] = v end
    for k, v in pairs(SK) do df.job_skill = df.job_skill or {}; df.job_skill[k] = v end
    dfhack.units.getNominalSkill = function(u, sk) return (u._skilled and u._skilled[sk]) or 0 end
    local box = o.box or {10, 10, 14, 14, 5}
    if o.zone ~= false then
      F.hospital(W, box)
      if o.well ~= false then F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5}) end
      local loc = W.site.buildings[#W.site.buildings - 1]
      if o.supplies ~= false then
        loc.contents = {}
        for k, v in pairs(o.supplies or FULL) do loc.contents[k] = v end
      end
    end
    local fur = o.furniture or {bed = 2, table = 1, bench = 1}
    local function put(n, ty)
      for i = 1, n do
        local b = F.building(W, ty == 5 and 'BED' or (ty == 6 and 'TABLE' or 'ANY_ZONE'), {x1 = box[1] + i, y1 = box[2] + ty - 4,
                             x2 = box[1] + i, y2 = box[2] + ty - 4, z = box[5]})
        b.getType = function() return ty end
      end
    end
    put(fur.bed, BT.Bed); put(fur.table, BT.Table); put(fur.bench, BT.TractionBench)
    dfhack.buildings = dfhack.buildings or {}
    dfhack.buildings.findAtTile = function(x, y, z)
      for _, b in pairs(W.buildings) do
        if b.getType and b.z == z and x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
      end
    end
    for key, ids in pairs(doctors) do
      for _, id in ipairs(ids) do W.unit(id).status.labors[LAB[key]] = true end
    end
    for _, id in ipairs(o.skilled or {}) do
      W.unit(id)._skilled = {[1] = 3, [2] = 3, [3] = 3, [4] = 3, [5] = 3}
    end
    W.set_census('i', {tick = 0, thread = o.fort_thread or 0, cloth = o.fort_cloth or 0})
  end}
  return W, M
end

local ALL_DOC = {diag = {1}, surg = {1}, bone = {1}, suture = {1}, dress = {1}}

local function toks(g)
  local r = {}
  for i, x in ipairs(g) do r[i] = x.tok end
  return r
end

T.test('BUG-106: note 90 (Run 14): a hospital with no table, no traction bench, no suture or dressing labor and no thread: ' ..
       'inspect what=hospital lists every gap with its counts, in a fixed vocabulary, within 200 bytes', function()
  local sup = {}
  for k, v in pairs(FULL) do sup[k] = v end
  sup.desired_thread, sup.count_thread, sup.count_cloth = 0, 0, 0
  local W, M = audit_world{furniture = {bed = 2, table = 0, bench = 0}, doctors = {diag = {1}, surg = {1}, bone = {1}},
                           skilled = {1}, supplies = sup, fort_thread = 0, fort_cloth = 12}
  day(W)
  local r = W.inbox('inspect', {what = 'hospital'})
  T.ok(r.ok, r.msg)
  T.eq(toks(r.data.gaps), {'no_table', 'no_traction', 'no_suture', 'no_dress', 'no_thread', 'no_cloth'})
  T.eq(r.msg, 'hospital: 6 gaps: no_table, no_traction, no_suture, no_dress, no_thread, no_cloth')
  local by = {}
  for _, g in ipairs(r.data.gaps) do by[g.tok] = g.txt; T.ok(#g.txt <= 70, g.txt) end
  T.eq(by.no_table, 'no table in the zone (surgery, suturing)')
  T.eq(by.no_suture, 'no adult citizen has the SUTURE labor on')
  T.eq(by.no_thread, 'the location asks for 0: nobody brings any, fort 0')
  T.eq(by.no_cloth, 'asks 5, holds 0, fort 12')
  T.eq({r.data.doctors.diag.on, r.data.doctors.diag.skilled, r.data.doctors.suture.on}, {1, 1, 0})
  T.eq(r.data.rooms[1].beds, 2)
  T.eq(r.data.supplies.cloth, {want = 5, have = 0, fort = 12})
  T.eq(r.data.carers.have, 2)
  T.ok(#require('dfllm.util.json').encode(r.data) < 8192)
  local w = W.state().water
  T.eq(w.gaps, {'no_table', 'no_traction', 'no_suture', 'no_dress', 'no_thread', 'no_cloth'})
  T.eq(C.check_state(W.state()), {})
end)

T.test('BUG-106: a complete hospital has no gaps; the state carries none and the message says so', function()
  local W = audit_world{doctors = ALL_DOC, skilled = {1}}
  day(W)
  local r = W.inbox('inspect', {what = 'hospital'})
  T.eq(r.data.gaps, {})
  T.eq(r.msg, 'hospital: no gaps (1 zones, 0 patients)')
  T.eq(W.state().water.gaps, nil)
end)

T.test('BUG-106: the labor without the skill, a location without supply fields and a hospital outside Kern+ are each named',
       function()
  local W = audit_world{doctors = ALL_DOC, skilled = {}, supplies = false}
  day(W)
  local g = W.inbox('inspect', {what = 'hospital'}).data.gaps
  T.eq(toks(g), {'no_diag', 'no_surgery', 'no_bone', 'no_suture', 'no_dress', 'supply_unknown'})
  T.eq(g[1].txt, '1 have the DIAGNOSE labor on, none has the skill')
  local W2 = audit_world{doctors = ALL_DOC, skilled = {1}, box = {150, 10, 154, 14, 5}}
  day(W2)
  local g2 = W2.inbox('inspect', {what = 'hospital'}).data.gaps
  T.eq(g2[1].tok, 'outside')
  T.ok(g2[1].txt:find('of 25 zone tiles outside Kern+/Tiefe+', 1, true), g2[1].txt)
end)

T.test('BUG-106: a hospital without accepted water is dry: the nearest source or none is named', function()
  local W = audit_world{doctors = ALL_DOC, skilled = {1}, well = false}
  day(W)
  local g = W.inbox('inspect', {what = 'hospital'}).data.gaps
  T.eq(toks(g), {'dry'})
  T.eq(g[1].txt, 'no accepted water in the fort')
  T.eq(W.state().water.gaps, {'dry'})
end)

T.test('BUG-106: no hospital zone: no_zone in the inspect, nothing in the state (nothing to fix yet)', function()
  local W = audit_world{zone = false, doctors = ALL_DOC, skilled = {1}, supplies = false, furniture = {bed = 0, table = 0, bench = 0}}
  day(W)
  local r = W.inbox('inspect', {what = 'hospital'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.gaps[1].tok, 'no_zone')
  T.eq(W.state().water.gaps, nil)
end)

T.test('BUG-106: a fort of 80 with a sick bay: the gap list stays within its bounds', function()
  local W = audit_world{cit = 80, carers = {}, furniture = {bed = 0, table = 0, bench = 0}, doctors = {}, supplies = {},
                        patients = {{id = 9, thirst = 1000, care = true, pos = {12, 12, 5}}}}
  day(W)
  local r = W.inbox('inspect', {what = 'hospital'})
  T.ok(#r.data.gaps <= 16 and #r.msg <= 200, #r.data.gaps .. '/' .. #r.msg)
  T.ok(#W.state().water.gaps <= 8)
  T.eq(C.check_state(W.state()), {})
end)

T.test('BUG-106: before the first water run the inspect says so (no error)', function()
  local W = audit_world{doctors = ALL_DOC, skilled = {1}}
  local r = W.inbox('inspect', {what = 'hospital'})
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'hospital: no water run finished yet')
end)
T.done()
