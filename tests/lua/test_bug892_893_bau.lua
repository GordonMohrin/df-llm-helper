-- NEU14 BUG-892 / BUG-893 (Run 17d i4 Girderroots y437-y460: the seal's wall job 1733178 at 98,86,143, ConstructBuilding flags=[], no worker, its block attached, not suspended,
-- the way in open 600+ game days beside 30 untaken dig jobs; 'idle holders' of a labor nobody read; 'why job:' read the wall as 'workshop:Farmers ... PROCESS_PLANT').
-- BUG-892: T.boost raises defence first: (1) a construction job of a seal / plug project or on a way in of the entrance check AT ONCE (no 3 day wait, outside the per-day cap, own
-- cap of 4 live), (2) the other defence buildings (bridges, levers, traps), (3) the rest oldest first as before. A job without its items is not class 1.
-- BUG-893: a wall / floor construction is built with BUILD_CONSTRUCTION: holders are counted for it, texts say 'adult' where the labor is unknown, the kernel puts the labor on
-- for more adults (3), `why job:` names the building and the labor.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200

local function add_enum(e, names)
  local n = 0
  for _, v in pairs(e) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if e[nm] == nil then n = n + 1; e[nm] = n; e[n] = nm end
  end
end
local function add_jobs(names) add_enum(df.job_type, names) end

-- list = {{id, type, pos?, items? (number attached), btype? (building type name), worker?, susp?}}
local function job_list(list)
  local head, cur = {}, nil
  cur = head
  local items = {}
  for _, e in ipairs(list) do
    local its = {}
    for i = 1, e.items == nil and 1 or e.items do its[i] = {item = {id = 9000 + i}} end
    local j = {id = e.id, job_type = df.job_type[e.type], flags = {suspend = e.susp == true, do_now = false}, _worker = e.worker and {id = 1} or nil,
               pos = e.pos or {x = 30, y = 30, z = 100}, items = kmock.vec(its)}
    if e.btype then
      j._b = {id = 800 + e.id, getType = function() return df.building_type[e.btype] end}
    end
    local node = {item = j}
    items[e.id] = j
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
  dfhack.job.getHolder = function(jb) return jb._b end
  return items
end

local SEAL = '98,86,143'
local function world(opts)
  opts = opts or {}
  local units, ids = {}, {}
  for i = 1, opts.units or 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  add_jobs({'ConstructBuilding', 'Dig', 'MakeCharcoal'})
  add_enum(df.building_type, {'Bridge', 'Trap'})
  df.unit_labor = {HAUL_FURNITURE = 41, MECHANIC = 42, MINE = 1, BUILD_CONSTRUCTION = 43, PROCESS_PLANT = 44, BURN_WOOD = 45}
  for k, v in pairs({HAUL_FURNITURE = 41, MECHANIC = 42, MINE = 1, BUILD_CONSTRUCTION = 43, PROCESS_PLANT = 44, BURN_WOOD = 45}) do df.unit_labor[v] = k end
  W.set_census('i', {})
  W.set_census('u', F.census_u(ids))
  for i = 1, #ids do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
    u.military = {squad_id = -1}
    u.job = {current_job = nil}
  end
  dfhack.job.getWorker = function(j) return j._worker end
  W.load({name = 'snapshot', every = {ticks = 100}, items_at = function() return {} end, tile = function() return {c = '.'} end,
          far = function() return false end})
  if opts.seal ~= false then
    W.load({name = 'runner', every = {ticks = 100000}, seal_tiles = function() return {[SEAL] = true} end})
  end
  W.economy = fresh('economy')
  W.load(W.economy)
  return W
end
local function boost(W) local ok, r = W.K.call('economy', 'boost_jobs'); T.ok(ok, tostring(r)) end
local function raised(items)
  local n = 0
  for _, j in pairs(items) do if j.flags.do_now then n = n + 1 end end
  return n
end

T.test('BUG-892: the seal wall job is raised the first time it is seen, ahead of 10 older dig jobs, outside the per-day cap; the dig jobs wait their 3 days', function()
  local W = world{}
  local list = {{id = 1733178, type = 'ConstructBuilding', pos = {x = 98, y = 86, z = 143}, items = 1}}
  for i = 1, 10 do list[#list + 1] = {id = 100 + i, type = 'Dig'} end
  local items = job_list(list)
  boost(W)
  T.eq(items[1733178].flags.do_now, true, 'the wall job at once')
  T.eq(raised(items), 1, 'no dig job yet')
  local ok, d = W.K.call('economy', 'boost_days', 1733178)
  T.ok(ok)
  T.eq(d, 0)
  local logged
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('seal / perimeter construction job', 1, true) and tostring(l.msg):find('job 1733178', 1, true) then logged = l.msg end end
  T.ok(logged, 'one kern.log line naming the job')
  W.run(3 * DAYT + 10, {skip = 100})
  boost(W)
  T.eq(raised(items), 1 + 4, 'the dig jobs after 3 days, 4 a day: the seal job did not use the day')
  local r = select(2, W.K.call('economy', 'state'))
  T.ok(r ~= nil)
end)

T.test('BUG-892: a job on a way in of the entrance check counts as class 1 (seal.entrances); one without an attached item does not', function()
  local W = world{seal = false}
  W.load({name = 'seal', every = {ticks = 100000}, entrances = function() return {{70, 71, 100}}, 12 end})
  local items = job_list{{id = 11, type = 'ConstructBuilding', pos = {x = 70, y = 71, z = 100}, items = 1},
                         {id = 12, type = 'ConstructBuilding', pos = {x = 70, y = 71, z = 100}, items = 0},
                         {id = 13, type = 'ConstructBuilding', pos = {x = 5, y = 5, z = 100}, items = 1}}
  boost(W)
  T.eq({items[11].flags.do_now, items[12].flags.do_now, items[13].flags.do_now}, {true, false, false})
end)

T.test('BUG-892: at most 4 seal jobs raised and untaken at once; a taken one frees its place; nothing in a siege', function()
  local W = world{}
  local list = {}
  for i = 1, 6 do list[i] = {id = 20 + i, type = 'ConstructBuilding', pos = {x = 98, y = 86, z = 143}, items = 1} end
  local items = job_list(list)
  boost(W)
  T.eq(raised(items), 4, 'own cap 4')
  items[21]._worker = {id = 1}
  boost(W)
  T.eq(raised(items), 5, 'the taken job keeps its flag, one more is raised')
  local W2 = world{mode = 'SIEGE'}
  local it2 = job_list{{id = 31, type = 'ConstructBuilding', pos = {x = 98, y = 86, z = 143}, items = 1}}
  boost(W2)
  T.eq(raised(it2), 0, 'PEACE and RECOVERY only')
end)

T.test('BUG-892: after 3 days the defence buildings (bridge, trap) come before older plain builds in the 4 a day', function()
  local W = world{}
  local list = {}
  for i = 1, 6 do list[i] = {id = 40 + i, type = 'ConstructBuilding', btype = 'Door', pos = {x = 20 + i, y = 20, z = 100}, items = 1} end
  list[#list + 1] = {id = 99, type = 'ConstructBuilding', btype = 'Bridge', pos = {x = 60, y = 60, z = 100}, items = 1}
  list[#list + 1] = {id = 98, type = 'ConstructBuilding', btype = 'Trap', pos = {x = 61, y = 60, z = 100}, items = 1}
  local items = job_list(list)
  boost(W)
  T.eq(raised(items), 0, 'class 2 waits its 3 days')
  W.run(3 * DAYT + 10, {skip = 100})
  boost(W)
  T.eq(raised(items), 4)
  T.eq({items[98].flags.do_now, items[99].flags.do_now, items[41].flags.do_now, items[42].flags.do_now, items[43].flags.do_now}, {true, true, true, true, false})
end)

T.test('BUG-893: a Construction has a labor: BUILD_CONSTRUCTION; holders are counted for it, and the texts say adults where the labor is unknown', function()
  local econ = fresh('economy')
  T.eq(econ.BUILD_LABOR.Construction, 'BUILD_CONSTRUCTION')
  T.eq(econ.LABOR_WORD.BUILD_CONSTRUCTION, 'Building construction (walls, floors)')
  local W = world{}
  for i = 1, 4 do W.unit(i).status.labors[41] = true end
  W.unit(1).status.labors[43] = true
  W.unit(2).status.labors[43] = true
  local ok, h = W.K.call('economy', 'hands', {kind = 'Construction'})
  T.ok(ok, tostring(h))
  T.eq({h.holders, h.unknown}, {2, nil})
  local ok2, h2 = W.K.call('economy', 'hands', {kind = 'Mystery'})
  T.ok(ok2)
  T.eq({h2.holders, h2.unknown}, {4, true})
end)

-- a wall at 98,86,143: a Construction building with its job
local function wall_world(labored)
  local W = world{units = 5}
  local j = {id = 1733178, job_type = df.job_type.ConstructBuilding, flags = {suspend = false, do_now = false}, job_items = {elements = kmock.vec{}},
             items = kmock.vec{{item = {id = 1530695}}}, pos = {x = 98, y = 86, z = 143}}
  local b = {id = 19342, x1 = 98, y1 = 86, x2 = 98, y2 = 86, z = 143, _st = 0, jobs = kmock.vec{j}, type = 1,
             getType = function() return df.building_type.Construction end,
             getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
  j._b = b
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z) if x == 98 and y == 86 and z == 143 then return b end end
  dfhack.job.getHolder = function(jb) return jb._b end
  df.global.world.jobs = {list = {next = {item = j}}}
  for i = 1, 5 do
    W.unit(i).status.labors[41] = true
    if labored and i <= labored then W.unit(i).status.labors[43] = true end
  end
  return W, j, b
end

T.test('BUG-893: a wall with no Building construction holder says so (no labor, a work detail grants it), not "12 idle holders"; with an item attached', function()
  local W = wall_world(0)
  local ok, r = W.K.call('economy', 'build_state', 98, 86, 143)
  T.ok(ok, tostring(r))
  T.eq({r.kind, r.nolabor, r.items}, {'Construction', true, 1})
  T.ok(r.line:find('no free adult citizen has the labor Building construction (walls, floors) on (0 of 5', 1, true), r.line)
  local runner = fresh('runner')
  T.eq(runner.cls_of(r), 'no labor')
  local W2 = wall_world(2)
  local _, r2 = W2.K.call('economy', 'build_state', 98, 86, 143)
  T.eq({r2.labor[1], r2.labor[2], r2.labor[3], r2.nolabor}, {'BUILD_CONSTRUCTION', 2, 5, nil})
  T.ok(r2.short:find('labor 2/5, items 1/0', 1, true), r2.short)
  T.ok(r2.short:find('idle holders reach it, DF did not assign it', 1, true), r2.short)
end)

T.test('BUG-893: "no item" only when nothing is attached: a suspended job with its block is "suspended"', function()
  local runner = fresh('runner')
  T.eq(runner.cls_of({job = 5, susp = true, who = 'buildingplan', items = 0}), 'no item')
  T.eq(runner.cls_of({job = 5, susp = true, who = 'buildingplan', items = 1}), 'suspended')
  T.eq(runner.cls_of({job = 5, susp = false, items = 1}), 'no builder')
end)

T.test('BUG-893: a raised wall job with fewer than 3 Building construction holders: the labor goes on for one more adult a day, named; 3 holders: nothing', function()
  local W, j = wall_world(1)
  boost(W)
  T.eq(j.flags.do_now, true, 'raised at once')
  boost(W)
  local sets = {}
  for _, a in ipairs(W.find_acts('labor_set')) do sets[#sets + 1] = {a.args[2], a.args[3]} end
  T.eq(sets, {{'construction', true}}, 'one adult a day')
  local seen
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('only 1 held BUILD_CONSTRUCTION', 1, true) then seen = e end end
  T.ok(seen and seen.d.kind == 'worker', 'ORDER_STUCK kind worker names it')
  local W3, j3 = wall_world(3)
  boost(W3)
  boost(W3)
  T.eq(#W3.find_acts('labor_set'), 0, 'three holders: nothing to add')
end)

T.test('BUG-893: why job: reads a wall as a Construction, not as a workshop; the labor is BUILD_CONSTRUCTION and the holders are counted', function()
  local W, j, b = wall_world(2)
  local JW = require('dfllm.jobwhy')
  local s = JW.shop(b, W.K)
  T.eq({s.key, s.kind, s.type}, {'building:Construction', 'Construction', nil})
  local labors = JW.labors(df.job_type.ConstructBuilding, nil, -1, -1, s.key)
  T.eq(labors, {43})
  local r = JW.job(W.K, j, nil)
  T.ok(r.workers and r.workers.n == 2 and r.workers.labor == 'BUILD_CONSTRUCTION', T.show(r.workers))
  local DR = require('dfllm.dfraw')
  local out = DR.job(W.K, j, nil)
  local t = table.concat(out.l, '\n')
  T.ok(t:find('derived labor: BUILD_CONSTRUCTION', 1, true), t)
  T.ok(not t:find('PROCESS_PLANT', 1, true), t)
  T.ok(t:find('holder building is a Construction, not a workshop', 1, true), t)
  T.ok(t:find('labor BUILD_CONSTRUCTION: 2 holder(s) of 5 citizens', 1, true), t)
  T.ok(t:find('building:Construction', 1, true), t)
end)

T.done()
