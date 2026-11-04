-- water BUG-383 (Run 16b i2 y381: patient 26275 died of thirst at 75,001 under '1 GiveWater job running 25+ days without
-- effect': BUG-343's `noeffect` verdict was only a report). On `noeffect` the carriers of the running GiveWater jobs that are
-- members of the Orderlies detail leave it for one run (the game drops the stale job and posts a new one), the next run puts
-- them back; at most restale_max, again after restale_every; a carrier outside the detail is left alone (the kernel never
-- removes a job). Fails on ec9bd8e (nothing released).
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
                   BONE_SETTING = 52, SUTURING = 53, DRESSING_WOUNDS = 54}   -- DF 53.16 names (BUG-153)
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

-- the Orderlies detail with its members (unit ids); calls = [{name, id, on}] of the work_detail act
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
local function grow(W, u, n)
  for _ = 1, n do
    u.counters2.thirst_timer = u.counters2.thirst_timer + 1200
    W.ms = W.ms + 600000
    day(W)
  end
end

T.test('BUG-383: a GiveWater job that runs for days without effect: its carrier leaves the Orderlies detail for one run, then returns',
       function()
  local W
  local calls
  W = world{patients = {{id = 5, thirst = 61000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
            jobs = {{id = 501, worker = 1}}, setup = function(W) calls = detail(W, {1, 2}) end}
  day(W)
  for _, c in ipairs(calls) do T.ok(c[3] ~= false, 'the first run: the verdict is `run`, nothing is released') end
  grow(W, W.unit(5), 3)
  local rel = {}
  for _, c in ipairs(calls) do if c[3] == false then rel[#rel + 1] = c end end
  T.eq(rel, {{'Orderlies', 1, false}}, 'the carrier of the running job left the detail')
  local ev = W.find_events('PATIENT_DYING')
  T.ok(ev[#ev].d.why:find('stale job released: carrier 1 off Orderlies', 1, true) or
       ev[#ev].msg:find('stale job released: carrier 1 off Orderlies', 1, true), ev[#ev].msg)
  local logged
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('taken off Orderlies for one run', 1, true) then logged = true end end
  T.ok(logged, 'kern.log names it')
  grow(W, W.unit(5), 1)
  local at, back = nil, 0
  for i, c in ipairs(calls) do
    if c[2] == 1 and c[3] == false and not at then at = i end
    if at and i > at and c[2] == 1 and c[3] == true then back = back + 1 end
  end
  T.ok(back >= 1, 'the next run puts him back')
end)

T.test('BUG-383: a carrier outside the Orderlies detail is left alone; restale false and no job change nothing', function()
  local W, calls
  W = world{patients = {{id = 5, thirst = 61000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
            jobs = {{id = 501, worker = 1}}, setup = function(W) calls = detail(W, {2}) end}   -- 1 holds the labor otherwise
  day(W)
  grow(W, W.unit(5), 3)
  local ev = W.find_events('PATIENT_DYING')
  T.eq(ev[#ev].d.key, 'noeffect', 'the verdict stands')
  for _, c in ipairs(calls) do T.ok(c[3] ~= false or c[2] ~= 1, 'carrier 1 is no member: not released') end
  local W2, calls2
  W2 = world{patients = {{id = 5, thirst = 61000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
             jobs = {{id = 501, worker = 1}}, setup = function(W)
               calls2 = detail(W, {1, 2})
               W.K.cfg.baseline.water = {restale = false}
             end}
  day(W2)
  grow(W2, W2.unit(5), 3)
  local ev2 = W2.find_events('PATIENT_DYING')
  T.eq(ev2[#ev2].d.key, 'noeffect', 'the verdict stands')
  for _, c in ipairs(calls2) do T.ok(c[3] ~= false, 'restale false: nobody released') end
end)

T.done()
