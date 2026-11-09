-- Round 40 (fix40-water): BUG-615 (Run 16c i3 Wallfree y380: 2 children died of thirst at a shallow well with two Pond zones beside it:
-- the pond zones of a dry / shallow well go early, all of them, with a DECISION), BUG-616 (drink 0 d with the only accepted water
-- outside the walls: the thirst decision says so and offers the cistern; STRANDED 'no raised bridge leads to drink' names the way to
-- water), BUG-617 (well.retire: deconstruct of a built well queues a job, that is no refusal; dry_well offers only commands that work).
local C = require('dfllm.util.contract')
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local FEED, MINE_L = 40, 41

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'hospital_restore', 'work_detail', 'pond_remove', 'well_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

local function fresh() package.loaded['dfllm.water'] = nil; return require('dfllm.water') end

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

-- opts: wet (default false), thirst = {[unit] = thirst}, move = {[unit] = {x, y, z}}, ponds = {{id, x1, y1, x2, y2}} (z 5), rooms, jobs,
-- patients, shallow (the well stands over 2/7), setup
local function world(opts)
  opts = opts or {}
  owners()
  local flags = {wet = opts.wet == true}
  local n = 14
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
  for _, pt in ipairs(opts.patients or {}) do
    local u = W.unit(pt.id)
    u.counters2.thirst_timer = pt.thirst
    if pt.care then u.health = {flags = {needs_healthcare = true}} end
    if pt.pos then W.move(pt.id, pt.pos[1], pt.pos[2], pt.pos[3]) end
  end
  for id, th in pairs(opts.thirst or {}) do W.unit(id).counters2.thirst_timer = th end
  for id, pos in pairs(opts.move or {}) do W.move(id, pos[1], pos[2], pos[3]) end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            local c = '#'
            if x == 20 and y == 12 and z == 4 then c = '_'
            elseif x == 20 and y == 12 and z == 3 and (flags.wet or opts.shallow) then c = '~' end
            return {c = c, flow = (opts.shallow and not flags.wet) and 2 or nil, dig = '', bld = ''}
          end})
  W.hosp = F.hospital(W, {10, 10, 14, 14, 5})
  W.well = F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  for _, pd in ipairs(opts.ponds or {}) do
    F.building(W, 'ANY_ZONE', {id = pd[1], type = df.civzone_type.Pond, x1 = pd[2], y1 = pd[3], x2 = pd[4], y2 = pd[5], z = 5})
  end
  for i = 1, 6 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  jobs(opts.jobs or {})
  W.removed = {}
  W.act_result('pond_remove', function(id)
    W.removed[#W.removed + 1] = id
    local az = df.global.world.buildings.other.ANY_ZONE         -- the zone is gone from the game
    for i = 0, #az - 1 do if az[i].id == id then az:erase(i); break end end
    return true, 1
  end)
  W.act_result('hospital_remove', function(id) W.removed[#W.removed + 1] = 'h' .. id; return true, 1 end)
  W.act_result('well_remove', function(id) W.retired = (W.retired or 0) + 1; return true, opts.queued and 'queued' or 1 end)
  if opts.setup then opts.setup(W) end
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
local function pond_ids(W)
  local r = {}
  for _, x in ipairs(W.removed) do if type(x) == 'number' then r[#r + 1] = x end end
  table.sort(r)
  return r
end

local TWO_PONDS = {{77, 21, 12, 22, 13}, {78, 18, 11, 19, 12}}

---------------------------------------------------------------- BUG-615
T.test('BUG-615 (Wallfree y380): a citizen at thirst 30,000 beside a dry well with two Pond zones: BOTH zones go at once and a DECISION ' ..
       'pond_blocks_well names the well, no stall wait', function()
  local W = world{ponds = TWO_PONDS, thirst = {[3] = 30000}, move = {[3] = {21, 14, 5}}}
  day(W, 1)
  T.eq(pond_ids(W), {77, 78}, 'both pond zones removed in the first run')
  local d = needed(W, 'pond_blocks_well')
  T.eq(#d, 1)
  T.eq(d[1].cls, 'A')
  T.ok(d[1].d.q:find('dry well ' .. W.well.id, 1, true) and d[1].d.q:find('77,78', 1, true), d[1].d.q)
  T.eq(d[1].d.units, {3})
  T.ok(d[1].d.cmds[1]:find('inspect what=water_sources', 1, true), d[1].d.cmds[1])
  day(W, 4)
  T.eq(#needed(W, 'pond_blocks_well'), 1, 'nothing left to remove: one decision')
end)

T.test('BUG-615: a shallow well (2/7) counts like a dry one', function()
  local W = world{ponds = TWO_PONDS, shallow = true, thirst = {[3] = 30000}, move = {[3] = {21, 14, 5}}}
  day(W, 1)
  T.eq(pond_ids(W), {77, 78})
  local d = needed(W, 'pond_blocks_well')
  T.ok(#d == 1 and d[1].d.q:find('shallow, 2/7', 1, true), d[1] and d[1].d.q or 'no decision')
end)

T.test('BUG-615: nobody thirsty beside the well (thirst 20,000), a citizen far away, or a wet well: the pond stays, no decision', function()
  local W = world{ponds = TWO_PONDS, thirst = {[3] = 20000}, move = {[3] = {21, 14, 5}}}
  day(W, 2)
  T.eq(pond_ids(W), {}, 'under pond_thirst')
  T.eq(#needed(W, 'pond_blocks_well'), 0)
  local W2 = world{ponds = TWO_PONDS, thirst = {[3] = 40000}, move = {[3] = {60, 60, 5}}}
  day(W2, 2)
  T.eq(pond_ids(W2), {}, 'thirsty but nowhere near the well')
  T.eq(#needed(W2, 'pond_blocks_well'), 0)
  local W3 = world{ponds = TWO_PONDS, wet = true, thirst = {[3] = 40000}, move = {[3] = {21, 14, 5}}}
  day(W3, 2)
  T.eq(#needed(W3, 'pond_blocks_well'), 0, 'a wet well is the loop rule\'s case')
end)

T.test('BUG-615: the pond zone beside a cistern room\'s well stays (it fills by it); the decision says so, once per three days', function()
  local W = world{ponds = TWO_PONDS, thirst = {[3] = 30000}, move = {[3] = {21, 14, 5}},
                  rooms = {{tpl = 'cistern', id = 'cistern18_10_5r0', bbox = {18, 10, 5, 22, 14, 5}, tier = 0, use = 'utility'}}}
  day(W, 1)
  T.eq(pond_ids(W), {}, 'held')
  local d = needed(W, 'pond_blocks_well')
  T.eq(#d, 1)
  T.eq(d[1].d.held, 1)
  T.ok(d[1].d.q:find("cistern room's well", 1, true), d[1].d.q)
  day(W, 1)
  T.eq(#needed(W, 'pond_blocks_well'), 1, 'not again within pond_block_every')
  day(W, 3)
  T.ok(#needed(W, 'pond_blocks_well') >= 2, 'again after three days')
end)

T.test('BUG-615: pond_block = false is off', function()
  local W = world{ponds = TWO_PONDS, thirst = {[3] = 30000}, move = {[3] = {21, 14, 5}}, setup = function(W)
    W.K.cfg.baseline.water = {pond_block = false}
  end}
  day(W, 2)
  T.eq(pond_ids(W), {})
  T.eq(#needed(W, 'pond_blocks_well'), 0)
end)

T.test('BUG-615: the stall ladder (water.unstick) takes every Pond zone beside the stalled FillPond worker, not only the first', function()
  -- pond_block off: the ladder alone (the worker at thirst 30,000 stands still for stall_days)
  local W = world{ponds = TWO_PONDS, jobs = {{id = 601, type = 'FillPond', worker = 4}}, thirst = {[4] = 30000},
                  move = {[4] = {20, 14, 5}}, setup = function(W) W.K.cfg.baseline.water = {pond_block = false} end}
  day(W, 4)
  T.eq(pond_ids(W), {77, 78})
end)

---------------------------------------------------------------- BUG-617
T.test('BUG-617: well.retire of a built dry well answers ok when the removal is queued (a Remove Building job), says so, and the well ' ..
       'is marked: no second command is offered', function()
  local W = world{queued = true, patients = {{id = 5, thirst = 30000, care = true, pos = {12, 12, 5}}}}
  day(W, 1)
  local r = W.inbox('well.retire', {id = W.well.id})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('removal of the dry well', 1, true) and r.msg:find('Remove Building job is queued', 1, true), r.msg)
  T.eq(W.retired, 1)
end)

T.test('BUG-617: a well already marked for removal is told, not refused, and not retired twice', function()
  local W = world{queued = true, setup = function(W)
    dfhack.buildings = dfhack.buildings or {}
    dfhack.buildings.markedForRemoval = function(b) return true end
  end}
  day(W, 1)
  local r = W.inbox('well.retire', {id = W.well.id})
  dfhack.buildings.markedForRemoval = nil
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('already marked for removal', 1, true), r.msg)
  T.eq(W.retired, nil)
end)

local function trapped(opts)
  opts = opts or {}
  opts.patients = {{id = 5, thirst = 30000, care = true, pos = {12, 12, 5}}}
  opts.jobs = {{id = 501, worker = 1}}
  local W = world(opts)
  W.move(1, 21, 13, 5)
  return W
end

T.test('BUG-617: the dry_well decision of a cistern room\'s well offers well.retire with approve=true (the bare command is refused)', function()
  local W = trapped{rooms = {{tpl = 'cistern', id = 'cistern18_10_5r0', bbox = {18, 10, 5, 22, 14, 5}, tier = 0, use = 'utility'}}}
  day(W, 2)
  local d = needed(W, 'dry_well')
  T.ok(#d >= 1, 'decision')
  T.ok(d[1].d.cmds[1]:find('well.retire id=' .. W.well.id .. ' approve=true', 1, true), d[1].d.cmds[1])
  local r = W.inbox('well.retire', {id = W.well.id, approve = true})
  T.ok(r.ok, r.msg)
  local W2 = trapped{}
  day(W2, 2)
  local d2 = needed(W2, 'dry_well')
  T.ok(d2[1].d.cmds[1] == 'dfllm cmd well.retire id=' .. W2.well.id, d2[1].d.cmds[1])
end)

T.test('BUG-617: carriers at a dry well that is marked for removal get no dry_well decision again', function()
  local W = trapped{setup = function(W)
    dfhack.buildings = dfhack.buildings or {}
    dfhack.buildings.markedForRemoval = function(b) return true end
  end}
  day(W, 3)
  dfhack.buildings.markedForRemoval = nil
  T.eq(#needed(W, 'dry_well'), 0, 'the Remove Building job stands: nothing to send')
  T.eq(#needed(W, 'job_stalled'), 0)
end)

---------------------------------------------------------------- BUG-616
T.test('BUG-616: the thirst question says the only accepted water lies OUTSIDE the core and offers a cistern near it; with a source inside ' ..
       'it stays the plain text', function()
  local W, M = world{wet = true}
  day(W, 1)
  -- the well at 20,12 is inside Kern+ (0..99): plain
  local txt = M.drink_fix(W.K)
  T.ok(txt:find('accepted water:', 1, true) and not txt:find('OUTSIDE', 1, true), txt)
  -- the same well, Kern+ moved away from it: the water lies outside the core
  W.burrow('Kern+', {60, 60, 0, 99, 99, 20})
  W.ms = W.ms + 300000; W.run(1200, {skip = 100})
  local txt2, cmds = M.drink_fix(W.K)
  T.ok(txt2:find('lies OUTSIDE the core', 1, true) and txt2:find('bp sites cistern --near 20,12,5 --fresh', 1, true), txt2)
  T.ok(cmds[#cmds]:find('bp sites cistern --near 20,12,5 --fresh', 1, true), cmds[#cmds])
end)

T.test('BUG-616: stranded_fix names the nearest accepted water and the way (a walk path or a cistern beside them); nil before the first run', function()
  local W, M = world{wet = true}
  T.eq(M.stranded_fix(W.K, {70, 70, 5}), nil)
  day(W, 1)
  local fx = M.stranded_fix(W.K, {70, 70, 5})
  T.ok(fx:find('well ' .. W.well.id .. ' at 20,12,5 is 58 tiles off', 1, true) and fx:find('walk path', 1, true)
       and fx:find('bp sites cistern --near 70,70,5', 1, true), fx)
  T.ok(#fx <= 200, #fx)
end)

T.done()
