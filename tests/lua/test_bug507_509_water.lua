-- Round 32 (fix32-water): BUG-507 a GiveWater job that hangs on a worker (Run 16b i2 Brotherarrow y386: a child stood 26 days at a dry
-- well, the patient died of thirst, no command), BUG-508 the same for FillPond / thirsty workers (the captain at 53,360), and the
-- verb water.unstick. Every test fails on dbd6e11 (no stall detection, no verb).
local C = require('dfllm.util.contract')
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local FEED, MINE_L = 40, 41

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'work_detail', 'pond_remove'}) do
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

T.test('BUG-507 (Run 16b i2: a child hung 26 days in a GiveWater job at a dry well, no Orderlies member): after stall_days a ' ..
       'DECISION_NEEDED job_stalled names him with the command water.unstick; nothing is removed for a healthy fort', function()
  local W = world{patients = {{id = 5, thirst = 31000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                  jobs = {{id = 501, worker = 9}}, setup = function(W) detail(W, {1, 2}) end}
  day(W, 2)
  T.eq(#needed(W, 'job_stalled'), 0, 'two days: not yet stalled')
  day(W, 3)
  local ev = needed(W, 'job_stalled')
  T.ok(#ev >= 1, 'a stalled job after stall_days')
  T.eq({ev[1].cls, ev[1].d.units}, {'A', {9}})
  T.eq(ev[1].d.cmds[1], 'dfllm cmd water.unstick unit=9')
  T.ok(ev[1].d.q:find('9 GiveWater', 1, true), ev[1].d.q)
  T.eq(#W.removed, 0, 'a thirst 31,000 patient and no pond: no zone is touched')
  local n = #ev
  day(W, 1)
  T.eq(#needed(W, 'job_stalled'), n, 'not again within three days')
end)

T.test('BUG-507: a worker who keeps moving is no stall; stall = false is report only nothing (no event)', function()
  local W = world{patients = {{id = 5, thirst = 40000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                  jobs = {{id = 501, worker = 9}}}
  for i = 1, 6 do W.move(9, 50 + i, 50, 10); day(W) end
  T.eq(#needed(W, 'job_stalled'), 0, 'he walks: the job id has a new tile every run')
  local W2 = world{patients = {{id = 5, thirst = 40000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                    jobs = {{id = 501, worker = 9}}, water = {stall = false}}
  day(W2, 6)
  T.eq(#needed(W2, 'job_stalled'), 0, 'stall false')
end)

T.test('BUG-507: a stalled carrier in Orderlies leaves it for a run (the BUG-383 release for every stalled worker); the third ' ..
       'round removes the hospital zone of a patient over stall_dying', function()
  local calls
  local W = world{patients = {{id = 5, thirst = 50000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                  jobs = {{id = 501, worker = 1}}, setup = function(W) calls = detail(W, {1, 2}) end,
                  water = {restale = false}}
  day(W, 4)
  local rel = {}
  for _, c in ipairs(calls) do if c[3] == false then rel[#rel + 1] = c end end
  T.ok(#rel >= 1 and rel[1][2] == 1, 'the stalled carrier left Orderlies')
  T.eq(#W.removed, 0, 'one round is no hospital removal yet')
  day(W, 4)
  local hz = {}
  for _, id in ipairs(W.removed) do if tostring(id):sub(1, 1) == 'h' then hz[#hz + 1] = id end end
  T.eq(hz, {'h' .. W.hosp.id}, 'the hospital zone the patient lies in went (once)')
  local ev = W.find_events('HOSPITAL_REMOVED')
  T.eq(#ev, 1)
  T.eq(ev[1].d.stalled, 1)
end)

T.test('BUG-508 (the captain in FillPond at thirst 53,360 beside a dry well): a FillPond worker over stall_need whose tile does not ' ..
       'change loses the pond zone beside him; one with thirst 1,000 is left alone', function()
  local W = world{jobs = {{id = 601, type = 'FillPond', worker = 3}}, thirst = {[3] = 53360}, pond = true}
  day(W, 4)
  T.eq(W.removed, {77}, 'the pond zone within pond_near + 1 of him')
  local ev = needed(W, 'job_stalled')
  T.ok(#ev >= 1 and ev[1].d.q:find('3 FillPond', 1, true), 'named')
  T.ok(ev[1].d.q:find('pond zone 77 removed', 1, true) and #ev[1].d.q <= 200, ev[1].d.q)
  local W2 = world{jobs = {{id = 601, type = 'FillPond', worker = 3}}, thirst = {[3] = 1000}, pond = true}
  day(W2, 6)
  T.eq(W2.removed, {}, 'a healthy worker in a long job is not touched')
  T.eq(#needed(W2, 'job_stalled'), 0)
end)

T.test('BUG-507: verb water.unstick {unit}: any mode, runs the ladder at once whatever the need; refuses a unit without a watched ' ..
       'job; the reply names what was done', function()
  local calls
  local W = world{jobs = {{id = 601, type = 'FillPond', worker = 3}, {id = 602, worker = 1}}, pond = true,
                  carers = {1, 2}, setup = function(W) calls = detail(W, {1, 2}) end}
  day(W, 1)
  local r = W.inbox('water.unstick', {unit = 4})
  T.eq(r.ok, false)
  T.ok(r.msg:find('unit 4 holds no water job', 1, true), r.msg)
  day(W, 3)
  W.set_mode('ALERT')
  r = W.inbox('water.unstick', {unit = 3})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('3 FillPond', 1, true) and r.msg:find('pond zone 77 removed', 1, true), r.msg)
  T.eq(W.removed, {77})
  r = W.inbox('water.unstick', {})
  T.ok(r.ok, r.msg)
  local rel
  for _, c in ipairs(calls) do if c[3] == false and c[2] == 1 then rel = true end end
  T.ok(rel, 'the Orderlies member 1 (GiveWater 602) was released by the no-argument form')
end)


---------------------------------------------------------------- BUG-509: a strange-mood dwarf dying of thirst
local CW = require('care_world')
local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end
local function mdecisions(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_thirst' then r[#r + 1] = e end end
  return r
end

T.test('BUG-509 care: a strange-mood dwarf gets ONE DECISION_NEEDED mood_thirst per step of his thirst (30,000 / 40,000 / 50,000 / ' ..
       '60,000), whatever the wall-clock cadence: the days to 75,000, what is short, an inspect command', function()
  local W = CW.world{setup = function(W)
    CW.F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    local u = W.unit(1)
    u.mood = df.mood_type.Fey
    u.job.current_job = CW.mood_job(W, 901, CW.F.workshop(W, 'Craftsdwarfs'), {filter('BAR', {mat_type = 0, mat_index = 9, quantity = 150})})
    u.counters2 = {thirst_timer = 12000, hunger_timer = 0}
  end}
  CW.day(W, 1)
  T.eq(#mdecisions(W), 0, 'thirst 12,000: no decision')
  W.unit(1).counters2.thirst_timer = 31000
  CW.day(W, 1)
  local d = mdecisions(W)
  T.eq(#d, 1, 'step 1 at mood_thirst')
  T.eq({d[1].cls, d[1].d.unit, d[1].d.kind, d[1].d.thirst}, {'A', 1, 'Fey', 31000})
  T.eq(d[1].d.days, (75000 - 31000) // 1200)
  T.ok(d[1].d.q:find('mood unit 1 (Fey)', 1, true) and d[1].d.q:find('dead in ~36 d', 1, true), d[1].d.q)
  T.ok(d[1].d.q:find('the job cannot be cancelled', 1, true), d[1].d.q)
  T.ok(d[1].d.q:find('short bars', 1, true) and #d[1].d.q <= 200, d[1].d.q)
  T.eq(d[1].d.ws, 'Craftsdwarfs')
  T.eq(d[1].d.cmds[#d[1].d.cmds], 'dfllm cmd inspect what=unit key=1')
  CW.day(W, 2)
  T.eq(#mdecisions(W), 1, 'the same step: quiet (no wall-clock wait, no repeat)')
  W.unit(1).counters2.thirst_timer = 41000
  CW.day(W, 1)
  T.eq(#mdecisions(W), 2, 'step 2 at mood_act')
  W.unit(1).counters2.thirst_timer = 51000
  CW.day(W, 1)
  W.unit(1).counters2.thirst_timer = 61000
  CW.day(W, 1)
  local last = mdecisions(W)
  T.eq(#last, 4, 'steps 3 and 4')
  T.eq(last[4].d.days, (75000 - 61000) // 1200)
end)

T.test('BUG-509 care: hunger steps count too; mood_help gives the picture economy uses (nil without a record)', function()
  local W = CW.world{setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Possessed
    u.job.current_job = CW.mood_job(W, 901, CW.F.workshop(W, 'Craftsdwarfs'), {})
    u.counters2 = {thirst_timer = 100, hunger_timer = 41000}
    u.profession2 = nil
  end}
  CW.day(W, 1)
  local d = mdecisions(W)
  T.eq(#d, 1)
  T.eq(d[1].d.hunger, 41000)
  local Cm = require('dfllm.care')
  local ok, h = W.K.call('care', 'mood_help', 1)
  T.ok(ok and type(h) == 'table', 'mood_help answers for a moody dwarf')
  T.eq(h.kind, 'Possessed')
  T.eq({W.K.call('care', 'mood_help', 2)}, {true, nil}, 'nil for a dwarf without a mood record')
end)

T.test('BUG-509 economy: thirst_unit for a moody unit names his mood and carries the mood commands', function()
  local F2 = require('wp8_world')
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F2.world{cfg = {baseline = F2.cfg()}, units = units}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F2.census_u(ids))
  for _ = 1, 4 do F2.item(W, 'BARREL', {}) end
  for _ = 1, 3 do F2.item(W, 'DRINK', {stack_size = 400}) end
  W.load({name = 'care', every = {ticks = 100000}, mood_help = function(K, id)
    if id ~= 4 then return nil end
    return {kind = 'Fey', child = true, lack = {'gems x1 (none in the fort)'},
            cmds = {[[dfllm cmd trade.want '{"add":["gems"]}']]}, opts = {'trade.want'}}
  end})
  package.loaded['dfllm.economy'] = nil
  W.load(require('dfllm.economy'))
  W.unit(4).counters2 = {thirst_timer = 62000, hunger_timer = 61000}
  W.unit(5).counters2 = {thirst_timer = 52000, hunger_timer = 0}
  W.run(1200, {skip = 100})
  for _ = 1, 40 do W.run(1) end
  local w
  for _, ev in ipairs(W.find_events('DECISION_NEEDED')) do if ev.d.id == 'thirst_unit' then w = w or ev end end
  T.ok(w, 'thirst_unit')
  T.eq(w.d.mood, {4})
  T.ok(w.d.q:find('strange mood Fey (child)', 1, true) and #w.d.q <= 200, w.d.q)
  local has = false
  for _, c in ipairs(w.d.cmds) do if c:find('trade.want', 1, true) then has = true end end
  T.ok(has, 'the mood command is among cmds')
  T.eq(w.d.cmds[1], 'dfllm cmd inspect what=unit key=4')
end)

T.done()
