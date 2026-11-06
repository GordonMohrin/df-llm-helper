-- Round 34 (fix34-hosp): BUG-540 (a dry hospital memory neither blocks a site that has water nor flaps; it expires; a hospital room
-- whose zone is gone and was never remembered is drawn again), BUG-541 (GiveWater carriers at a DRY well: an early DECISION dry_well,
-- the verb well.retire, the zone of a patient over trap_dying goes from the second round), BUG-542 (water.unstick keeps the zone).
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
  local flags = {wet = opts.wet ~= false}
  local n = opts.cit or 14
  local units = {}
  for i = 1, n do units[i] = {id = i, citizen = true, pos = {50, 50, 10}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}, rooms = opts.rooms or {}}}
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
          tile = function(K, x, y, z) return {c = ((x == 20 or opts.second and x == 25) and y == 12 and z == 4) and '_' or (((flags.wet and x == 20 and y == 12 or opts.second and x == 25 and y == 12) and z == 3) and '~' or '#'),
                                              dig = '', bld = ''} end})
  if opts.hospital ~= false then
    W.hosp = F.hospital(W, {10, 10, 14, 14, 5})
    W.well = F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
    if opts.second then F.building(W, 'WELL', {x1 = 25, y1 = 12, x2 = 25, y2 = 12, z = 5}) end
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
  W.flags = flags
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


local function removed_zones(W)
  local n = 0
  for _, x in ipairs(W.removed) do if tostring(x):sub(1, 1) == 'h' then n = n + 1 end end
  return n
end

local ROOM = {{tpl = 'hospital', id = 'hospital10_10_5r0', bbox = {10, 10, 5, 14, 14, 5}, tier = 0, use = 'utility'}}

local function restore_act(W)
  W.restored = {}
  W.act_result('hospital_restore', function(spec)
    W.restored[#W.restored + 1] = spec
    W.hosp.location_id = spec.loc
    return true, {ids = {900 + #W.restored}}
  end)
end

-- a patient at 30,000 in a hospital whose well is dry: remove_dry takes the zone and remembers it ('dry')
local function dry_removed()
  local W = world{patients = {{id = 5, thirst = 30000, care = true, pos = {12, 12, 5}}}, carers = {1, 2}, wet = false,
                  setup = restore_act}
  day(W, 2)
  return W
end

T.test('BUG-540: a dry memory does not count for bp sites (state hrm) and hospital.restore refuses it with the reason; no flapping', function()
  local W = dry_removed()
  T.eq(removed_zones(W), 1, 'remove_dry took the dry zone once')
  T.eq(W.state().water.hrm, nil, 'a dry memory without water near blocks no site')
  local r = W.inbox('hospital.restore', {})
  T.eq(r.ok, false)
  T.ok(r.msg:find('dry: no accepted water', 1, true), r.msg)
  T.eq(#W.restored, 0, 'nothing drawn: remove_dry would take it away again under a new id')
  day(W, 3)
  T.eq(#W.restored, 0)
  T.eq(removed_zones(W), 1, 'and nothing removed again')
end)

T.test('BUG-540: water near again: the dry memory counts and the kernel draws the zone', function()
  local W = dry_removed()
  W.flags.wet = true
  day(W, 1)
  T.eq(W.state().water.hrm == 1 or #W.restored == 1, true, 'counted while waiting, or already drawn')
  day(W, 2)
  T.eq(#W.restored, 1, 'drawn again by the kernel once the well is wet (restore_wait passed)')
  T.eq(W.state().water.hrm, nil)
end)

T.test('BUG-540: the verb draws a dry entry at once when water stands near again', function()
  local W = dry_removed()
  W.flags.wet = true
  W.ms = W.ms + 300000; W.run(600, {skip = 100})            -- a water run sees the wet well (less than restore_wait)
  local r = W.inbox('hospital.restore', {})
  T.ok(r.ok or #W.restored == 1, tostring(r.msg))
end)

T.test('BUG-540: a remembered zone expires after hrm_expire (20 days): the verb then says nothing is remembered', function()
  local W = dry_removed()
  day(W, 21)
  T.eq(W.state().water.hrm, nil)
  local r = W.inbox('hospital.restore', {})
  T.eq(r.ok, false)
  T.ok(r.msg:find('no removed hospital zone is remembered', 1, true), r.msg)
  T.eq(#W.restored, 0)
end)

T.test('BUG-540: a hospital room of the manifest whose zone is gone and was never remembered (Brotherarrow) gets its zone back over ' ..
       'the room, at the old location, once water is near', function()
  local W = world{rooms = ROOM, setup = restore_act}
  local loc = W.hosp.location_id
  W.hosp.location_id = -99                             -- the zone was removed before BUG-539 (the location stays)
  day(W, 2)
  T.eq(#W.restored, 1, 'the kernel draws it (no hospital zone stands, water near, restore_wait passed)')
  local s = W.restored[1]
  T.eq({s.loc, s.x1, s.y1, s.x2, s.y2, s.z}, {loc, 10, 10, 14, 14, 5}, 'over the room of the manifest, at its location')
end)

T.test('BUG-540: the zoneless room needs water near too; with water the state names it (no second hospital) and the verb draws it', function()
  local W = world{rooms = ROOM, wet = false, setup = restore_act}
  W.hosp.location_id = -99
  day(W, 2)
  T.eq(#W.restored, 0, 'dry: not drawn')
  T.eq(W.state().water.hrm, nil)
  local r = W.inbox('hospital.restore', {})
  T.eq(r.ok, false)
  T.ok(r.msg:find('dry: no accepted water', 1, true), r.msg)
  W.flags.wet = true
  W.ms = W.ms + 100000; W.run(600, {skip = 100})
  T.eq(W.state().water.hrm, 1, 'with water near the room counts as the fort\'s hospital')
  r = W.inbox('hospital.restore', {})
  T.ok(r.ok, r.msg)
  T.ok(#W.restored >= 1, 'drawn (the act itself answers present when the kernel was first)')
end)

-- a GiveWater job on carrier 1 who stands still at 21,13,5, one tile from the well at 20,12,5
local function trapped(opts)
  opts = opts or {}
  local W = world{patients = {{id = 5, thirst = opts.thirst or 30000, care = true, pos = {12, 12, 5}}}, carers = {1, 2},
                  jobs = {{id = 501, worker = 1}}, wet = opts.wet, second = true, setup = function(W)
                    detail(W, {1, 2})
                    W.act_result('well_remove', function(id) W.wells = (W.wells or 0) + 1; W.last_well = id; return true, 1 end)
                  end}
  W.move(1, 21, 13, 5)
  return W
end

T.test('BUG-541: carriers standing at a DRY well while a patient is over 25,000: an early DECISION dry_well names the well and well.retire', function()
  local W = trapped{wet = false}
  day(W, 2)
  local d = needed(W, 'dry_well')
  T.ok(#d >= 1, 'DECISION_NEEDED dry_well after trap_days (1), not after 28')
  local e = d[1].d
  T.ok(e.cmds[1]:find('well.retire id=' .. W.well.id, 1, true), e.cmds[1])
  T.ok(e.q:find('DRY well', 1, true), e.q)
  T.eq(#needed(W, 'job_stalled'), 0, 'one decision for the case')
end)

T.test('BUG-541: the same carrier at a WET well is no case (no decision before stall_days)', function()
  local W = trapped{wet = true}
  day(W, 2)
  T.eq(#needed(W, 'dry_well'), 0)
end)

T.test('BUG-541: no thirsty patient, no decision', function()
  local W = trapped{wet = false, thirst = 2000}
  day(W, 2)
  T.eq(#needed(W, 'dry_well'), 0)
end)

T.test('BUG-541: from the second round the zone of a patient over trap_dying (35,000) goes', function()
  local W = trapped{wet = false, thirst = 40000}
  day(W, 4)
  T.ok(removed_zones(W) >= 1, 'the hospital zone is removed at 40,000 (45,000 would be the plain third-round rung)')
end)

T.test('BUG-541: a patient under trap_dying keeps the zone (the decision is the answer)', function()
  local W = trapped{wet = false, thirst = 30000}
  day(W, 4)
  T.eq(removed_zones(W), 0)
  T.ok(#needed(W, 'dry_well') >= 1)
end)

T.test('BUG-541: well.retire takes a dry well away; a wet well and an unknown id are refused', function()
  local W = trapped{wet = false}
  day(W, 1)
  local r = W.inbox('well.retire', {id = 99999})
  T.eq(r.ok, false)
  T.ok(r.msg:find('no well 99999', 1, true), r.msg)
  local wid = W.well.id
  r = W.inbox('well.retire', {id = wid})
  T.ok(r.ok, r.msg)
  T.eq(W.wells, 1)
  T.eq(W.last_well, wid)
  local Wet = trapped{wet = true}
  day(Wet, 1)
  r = Wet.inbox('well.retire', {id = Wet.well.id})
  T.eq(r.ok, false)
  T.ok(r.msg:find('has water below it', 1, true), r.msg)
  T.eq(Wet.wells, nil)
end)

T.test('BUG-541: a cistern room\'s dry well is retired only with approve:true', function()
  local W = world{wet = false, rooms = {{tpl = 'cistern', id = 'cistern18_10_5r0', bbox = {18, 10, 5, 22, 14, 5}, tier = 0, use = 'utility'}},
                  setup = function(W) W.act_result('well_remove', function(id) W.wells = (W.wells or 0) + 1; return true, 1 end) end}
  day(W, 1)
  local r = W.inbox('well.retire', {id = W.well.id})
  T.eq(r.ok, false)
  T.ok(r.msg:find('cistern room', 1, true), r.msg)
  r = W.inbox('well.retire', {id = W.well.id, approve = true})
  T.ok(r.ok, r.msg)
  T.eq(W.wells, 1)
end)

T.test('BUG-542: water.unstick cancels the stuck job (off Orderlies) and KEEPS the hospital zone, however often it is sent', function()
  local W = trapped{wet = true, thirst = 60000}
  day(W, 1)
  for _ = 1, 4 do
    local r = W.inbox('water.unstick', {unit = 1})
    T.ok(r.ok, r.msg)
    T.ok(r.msg:find('hospital zone stays', 1, true), r.msg)
  end
  T.eq(removed_zones(W), 0, 'no hospital zone removed by the verb')
  T.eq(W.state().water.hrm, nil)
end)

T.done()
