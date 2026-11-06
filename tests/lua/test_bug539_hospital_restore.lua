-- Round 33 (fix33-unstick): BUG-539 water.unstick (and the dry-hospital removal) took the hospital zone away and nothing drew it
-- again (Run 16b i2 Brotherarrow y395-y396: 'hospital none' for 15+ days, 6-10 patients without a zone). The kernel remembers a
-- removed zone (p.hrm), draws it again at its old location (act.hospital_restore) once the patients are over the worst, and the
-- verb hospital.restore does it at once. Every test fails on 398d6f8 (no memory, no verb, no act).
local C = require('dfllm.util.contract')
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local FEED, MINE_L = 40, 41

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'hospital_restore', 'work_detail', 'pond_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

local function fresh() package.loaded['dfllm.water'] = nil; return require('dfllm.water') end

-- water jobs on the job list: list = {{id, type = 'GiveWater' | 'FillPond', worker = unit id | nil}}
local TYPES = {GiveWater = 78, FillPond = 79, GiveFood = 80}
local function jobs(list)
  for name, v in pairs(TYPES) do df.job_type[name], df.job_type[v] = v, name end
  local head
  for i = #list, 1, -1 do
    head = {item = {job_type = TYPES[list[i].type or 'GiveWater'], id = list[i].id, _worker = list[i].worker}, next = head}
  end
  df.global.world.jobs = {list = {next = head}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return j._worker end
end

local function world(opts)
  opts = opts or {}
  owners()
  local n = opts.cit or 14
  local units = {}
  for i = 1, n do units[i] = {id = i, citizen = true, pos = {50, 50, 10}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = MINE_L, CUTWOOD = 42, HUNT = 43, DIAGNOSE = 50, SURGERY = 51,
                   BONE_SETTING = 52, SUTURING = 53, DRESSING_WOUNDS = 54}
  local ids = {}
  for i = 1, n do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
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
  for id, th in pairs(opts.thirst or {}) do W.unit(id).counters2.thirst_timer = th end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z) return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'),
                                              dig = '', bld = ''} end})
  if opts.hospital ~= false then
    W.hosp = F.hospital(W, {10, 10, 14, 14, 5})
    F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  end
  if opts.pond then W.pond = F.building(W, 'ANY_ZONE', {id = 77, type = df.civzone_type.Pond, x1 = 51, y1 = 50, x2 = 52, y2 = 51, z = 10}) end
  for i = 1, 6 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  jobs(opts.jobs or {})
  W.removed = {}
  W.act_result('pond_remove', function(id) W.removed[#W.removed + 1] = id; return true, 1 end)
  W.act_result('hospital_remove', function(id)
    W.removed[#W.removed + 1] = 'h' .. id
    if W.hosp and W.hosp.id == id then W.hosp.location_id = -99 end           -- the zone is gone
    return true, 1
  end)
  if opts.setup then opts.setup(W) end
  if opts.water then W.K.cfg.baseline.water = opts.water end
  local M = fresh()
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.ms = W.ms + 600000; W.run(1200, {skip = 100}) end end
local function needed(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function detail(W, members)
  local calls = {}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{{name = 'Orderlies', assigned_units = kmock.vec(members), flags = {}}}}
  dfhack.df2utf = dfhack.df2utf or function(s) return s end
  W.act_result('work_detail', function(name, id, on)
    calls[#calls + 1] = {name, id, on}
    W.unit(id).status.labors[FEED] = on
    return true, 'ok'
  end)
  return calls
end

local function restores(W)
  local r = {}
  for _, a in ipairs(W.find_acts('hospital_restore')) do r[#r + 1] = a.args[1] end
  return r
end

-- BUG-542: water.unstick no longer removes the zone; the kernel's own third stall round does (stall_dying 45,000), as it always could
local function auto_remove(W)
  for _ = 1, 10 do
    for _, x in ipairs(W.removed) do if tostring(x):sub(1, 1) == 'h' then return end end
    day(W, 1)
  end
  error('the stalled GiveWater job never reached the hospital rung')
end

-- a patient (5) at thirst 50,000 in the hospital, a stalled GiveWater job on carrier 1: water.unstick unit=1 removes the zone
local function stalled(extra)
  extra = extra or {}
  local W = world{patients = {{id = 5, thirst = 50000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                  jobs = {{id = 501, worker = 1}}, setup = function(W)
                    detail(W, {1, 2})
                    W.restored = {}
                    W.act_result('hospital_restore', function(spec)
                      W.restored[#W.restored + 1] = spec
                      if extra.fail then return false, extra.fail end
                      W.hosp.location_id = spec.loc
                      return true, {ids = {900 + #W.restored}}
                    end)
                  end, water = {restale = false}}
  day(W, 4)
  return W
end

T.test('BUG-539: the stall ladder (third round) removes the stalled patient\'s hospital zone and the kernel draws it again at the SAME location ' ..
       'and rectangle once the patient drinks (thirst under patient_thirst) and restore_wait has passed', function()
  local W = stalled()
  local loc = W.hosp.location_id
  auto_remove(W)
  T.eq(W.restored, {}, 'not in the same pass: the patient must drink first')
  T.eq(W.state().water.hrm, 1, 'the state names the remembered zone')
  -- the patient drinks (no zone: GiveWater or his own drink)
  W.unit(5).counters2.thirst_timer = 2000
  day(W, 2)
  T.eq(#W.restored, 1, 'drawn again once')
  local s = W.restored[1]
  T.eq({s.loc, s.x1, s.y1, s.x2, s.y2, s.z}, {loc, 10, 10, 14, 14, 5}, 'the old location (read before the removal) and rectangle')
  T.eq(W.state().water.hrm, nil, 'nothing remembered any more')
  day(W, 2)
  T.eq(#W.restored, 1, 'and not again')
end)

T.test('BUG-539: while the patient is still over patient_thirst the zone waits, at the latest restore_max (5 days) it comes back', function()
  local W = stalled()
  auto_remove(W)
  day(W, 3)
  T.eq(#W.restored, 0, 'patient still at 50,000 after 3 days: wait')
  day(W, 3)
  T.eq(#W.restored, 1, 'after restore_max the fort has a hospital zone again, whatever the patient')
end)

T.test('BUG-539: verb hospital.restore draws the remembered zone at once (any mode); nothing remembered is refused; a refused ' ..
       'act keeps the memory', function()
  local W = stalled()
  local r = W.inbox('hospital.restore', {})
  T.eq(r.ok, false)
  T.ok(r.msg:find('no removed hospital zone is remembered', 1, true), r.msg)
  auto_remove(W)
  W.set_mode('ALERT')
  r = W.inbox('hospital.restore', {loc = 12345})
  T.eq(r.ok, false)
  T.eq(#W.restored, 0)
  r = W.inbox('hospital.restore', {})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('drawn again', 1, true), r.msg)
  T.eq(#W.restored, 1)
  r = W.inbox('hospital.restore', {})
  T.eq(r.ok, false, 'drawn: nothing left')
  local W2 = stalled{fail = 'quickfort designated no zone there'}
  auto_remove(W2)
  r = W2.inbox('hospital.restore', {})
  T.eq(r.ok, false)
  T.ok(r.msg:find('quickfort designated no zone there', 1, true), r.msg)
  T.eq(W2.state().water.hrm, 1, 'the memory stays for the next try')
end)

T.test('BUG-539: a hospital location that is gone drops the memory (nothing to come back to)', function()
  local W = stalled{fail = 'no hospital location 600'}
  auto_remove(W)
  local r = W.inbox('hospital.restore', {})
  T.eq(r.ok, false)
  T.eq(W.state().water.hrm, nil)
end)

T.done()
