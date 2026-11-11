-- BUG-747 / BUG-749 (Run 16b i2 Whirledrampart y435-y440: Cabinet, Coffin, Trap, Bridge, Craftsdwarfs 'no builder took it: no cause readable (labor 25/31, items 1/0,
-- in burrow, not walled in)' 30-35 d beside 8 free idle adults and 'set aside, no runner slot'; Run 16d i4 Pagedsculpture the refuge hatch 95,94,141 450+ days; Run 16a
-- i1 Basementflew the explore and tombs digs at 6 % with the one Miner on StoreItemInBarrel): the labor holders were there and DF gave them nothing. The kernel raises
-- its own untaken construction and dig jobs to top priority (job flag do_now, DFHack `prioritize`), a few at a time, and the answer names who could have taken a job
-- and what was done; a dig stage names its dig jobs and the Miners.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local DAYT = 1200

-- list = {{id, type 'ConstructBuilding'|'Dig', worker?, susp?, pos?}}; world.jobs.list as DFHack's linked list
local function job_list(list)
  local head, cur = {}, nil
  cur = head
  local items = {}
  for _, e in ipairs(list) do
    local node = {item = {id = e.id, job_type = df.job_type[e.type], flags = {suspend = e.susp == true, do_now = false},
                          _worker = e.worker and {id = 1} or nil, pos = e.pos or {x = 30, y = 30, z = 100}}}
    items[e.id] = node.item
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
  return items
end

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.units or 0 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  add_jobs({'ConstructBuilding', 'Dig'})
  df.unit_labor = {HAUL_FURNITURE = 41, MECHANIC = 42, MINE = 1}
  dfhack.job.getWorker = function(j) return j._worker end
  W.load({name = 'snapshot', every = {ticks = 100}, items_at = function() return {} end, tile = function() return {c = '.'} end,
          far = function() return false end, groups = opts.groups})
  W.set_census('i', {})
  W.economy = fresh('economy')
  return W
end

local function boost(W)
  local ok, r = W.K.call('economy', 'boost_jobs')
  T.ok(ok, tostring(r))
end
local function days_of(W, jid)
  local ok, d = W.K.call('economy', 'boost_days', jid)
  T.ok(ok)
  return d
end
local function raised(items)
  local n = 0
  for _, j in pairs(items) do if j.flags.do_now then n = n + 1 end end
  return n
end

T.test('BUG-747: a construction or dig job nobody took for 3 days gets top priority; not before, not a taken or suspended one', function()
  local W = world{}
  local items = job_list{{id = 11, type = 'ConstructBuilding'}, {id = 12, type = 'Dig'}, {id = 13, type = 'ConstructBuilding', worker = true},
                         {id = 14, type = 'Dig', susp = true}}
  W.load(W.economy)
  boost(W)                                       -- first seen now
  T.eq(raised(items), 0)
  W.run(2 * DAYT, {skip = 100})
  boost(W)
  T.eq(raised(items), 0, 'two days: not yet')
  W.run(DAYT + 10, {skip = 100})
  boost(W)
  T.eq({items[11].flags.do_now, items[12].flags.do_now}, {true, true})
  T.eq({items[13].flags.do_now, items[14].flags.do_now}, {false, false}, 'a taken job and a suspended one stay as they are')
  T.eq(days_of(W, 11), 0)
  T.eq(days_of(W, 13), nil)
  local logged = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('untaken job', 1, true) and tostring(l.msg):find('do_now', 1, true) then logged = true end end
  T.ok(logged, 'one kern.log line')
end)

T.test('BUG-747: at most 4 a day and 8 raised and untaken at once; a job that is taken or gone frees its place', function()
  local W = world{}
  local list = {}
  for i = 1, 9 do list[i] = {id = 100 + i, type = 'ConstructBuilding'} end
  local items = job_list(list)
  W.load(W.economy)                               -- the economy's own daily pass runs the boost
  W.run(3 * DAYT + 100, {skip = 100})
  T.eq(raised(items), 0, 'none is 3 days old yet')
  local seen = 0
  for _ = 1, 6 do
    W.run(DAYT, {skip = 100})
    seen = math.max(seen, raised(items))
  end
  T.eq(raised(items), 8, 'max 8 raised and untaken at once')
  for _, l in ipairs(W.logs) do
    local n = tostring(l.msg):match('^jobs: (%d+) untaken job')
    if n then T.ok(tonumber(n) <= 4, 'at most 4 a day: ' .. l.msg) end
  end
  local first
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('^jobs: %d+ untaken job') then first = first or l.msg end end
  T.ok(first and first:find('(4 raised and still untaken now)', 1, true), first)
  items[101]._worker = {id = 1}                  -- one of them is taken: a place is free
  items[101].flags.do_now = true
  W.run(2 * DAYT, {skip = 100})
  T.eq(raised(items), 9, 'the freed place is used (the taken job keeps its flag)')
  df.global.world.jobs = {list = {}}             -- everything gone
  W.run(DAYT, {skip = 100})
  T.eq(days_of(W, 102), nil, 'records of vanished jobs are dropped')
end)

T.test('BUG-747: no raise in an alert, a siege or a breach (PEACE and RECOVERY only)', function()
  local W = world{mode = 'SIEGE'}
  local items = job_list{{id = 21, type = 'ConstructBuilding'}}
  W.load(W.economy)
  boost(W)
  W.run(4 * DAYT, {skip = 100})
  boost(W)
  T.eq(raised(items), 0)
  W.mode = 'ALERT'
  boost(W)
  T.eq(raised(items), 0)
  W.mode = 'BREACH'
  boost(W)
  T.eq(raised(items), 0)
  W.mode = 'PEACE'
  boost(W)
  T.eq(raised(items), 1)
end)

-- a door building at X,Y,Z whose job is not suspended and has no worker
local X, Y, Z = 40, 41, 120
local function building(jid)
  local ji = {item_type = df.item_type.DOOR, quantity = 0, mat_type = -1, mat_index = -1, flags2 = {}}
  local j = {id = jid, job_type = df.job_type.ConstructBuilding, flags = {suspend = false, do_now = false}, job_items = {elements = kmock.vec{ji}},
             items = kmock.vec{}, pos = {x = X, y = Y, z = Z}}
  local b = {id = 900, x1 = X, y1 = Y, x2 = X, y2 = Y, z = Z, _st = 0, jobs = kmock.vec{j},
             getType = function() return df.building_type.Door end,
             getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
  return b, j
end

local function bworld(opts)
  local W = world{units = 3, groups = opts.groups}
  local b, j = building(4711)
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z) if x == X and y == Y and z == Z then return b end end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = nil
  for id = 1, 3 do
    local u = W.unit(id)
    u.status.labors = {[df.unit_labor.HAUL_FURNITURE] = true}
    u.job = opts.jobs and opts.jobs[id] or {current_job = nil}
    u.mood = -1
  end
  W.set_census('u', F.census_u({1, 2, 3}, {soldiers = 1, soldier_ids = {3}}))
  W.load(W.economy)
  return W, b, j
end
local function state(W)
  local ok, r = W.K.call('economy', 'build_state', X, Y, Z)
  T.ok(ok, tostring(r))
  return r
end

T.test('BUG-747: no readable blocker, idle labor holders reach the site: the answer says DF did not assign it, and after a raise since when', function()
  local W, b, j = bworld{}
  local r = state(W)
  T.eq({r.hands.holders, r.hands.idle, r.hands.reach}, {2, 2, 2})
  T.eq(r.short, 'no builder took it: nothing blocks it (labor 2/2, items 0/0, in burrow, not walled in); 2 idle holders reach it, DF did not assign it')
  T.ok(r.line:find('2 idle holders reach it, DF did not assign it', 1, true), r.line)
  df.global.world.jobs = {list = {next = nil}}
  -- the job in the list is the building's own: share the table so the raise lands on it
  local head = {next = {item = j}}
  df.global.world.jobs = {list = head}
  boost(W)
  T.eq(j.flags.do_now, false, 'seen now, not yet')
  W.run(3 * DAYT + 10, {skip = 100})
  boost(W)
  T.eq(j.flags.do_now, true)
  local r2 = state(W)
  T.eq({r2.boost, r2.do_now}, {0, true})
  T.ok(r2.short:find('2 idle holders reach it, DF did not assign it (priority raised 0 d ago)', 1, true), r2.short)
  T.ok(#r2.short <= 190, #r2.short)
end)

T.test('BUG-747: all labor holders busy, or idle ones on another walk group: said so', function()
  local W = bworld{jobs = {{current_job = {job_type = df.job_type.Dig}}, {current_job = {job_type = df.job_type.Dig}}}}
  local r = state(W)
  T.eq({r.hands.holders, r.hands.idle}, {2, 0})
  T.ok(r.short:find('all 2 holders busy (2 at Dig)', 1, true), r.short)
  -- the idle ones stand on group 5, the site's neighbours on group 9
  local W2 = bworld{groups = function(K, pts, near) local o = {} for i = 1, #pts do o[i] = near and 9 or 5 end return o end}
  local r2 = state(W2)
  T.eq({r2.hands.idle, r2.hands.reach}, {2, 0})
  T.ok(r2.short:find('no builder: 2 idle holders of the labor, none on its walk group', 1, true), r2.short)
end)

T.test('BUG-749: a dig stage names its dig jobs and the Miners detail (open, taken, suspended, raised; idle or at what job)', function()
  local W = world{units = 2}
  job_list{{id = 31, type = 'Dig', pos = {x = 50, y = 50, z = 100}}, {id = 32, type = 'Dig', pos = {x = 51, y = 50, z = 100}, worker = true},
           {id = 33, type = 'Dig', pos = {x = 52, y = 50, z = 100}, susp = true}, {id = 34, type = 'Dig', pos = {x = 90, y = 90, z = 100}}}
  df.global.world.jobs.list.next.item.flags.do_now = true
  W.unit(1).job = {current_job = {job_type = df.job_type.Dig}}
  W.unit(2).job = {current_job = {job_type = df.job_type.Dig}}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{{name = 'Miners', assigned_units = kmock.vec{1, 2}}}}
  W.load(W.economy)
  local ok, d = W.K.call('economy', 'dig_wait', {45, 45, 100, 55, 55, 100})
  T.ok(ok, tostring(d))
  T.eq({d.jobs, d.open, d.taken, d.susp, d.raised, d.miners, d.idle}, {3, 1, 1, 1, 1, 2, 0})
  T.eq(d.text, '3 dig jobs here (1 open, 1 taken, 1 suspended, 1 raised); Miners detail 2 (0 idle, 2 at Dig)')
end)

-- the runner's wiring: a dig stage nobody digs is set aside with economy's dig_wait text (stub) as the cause, and the set-aside text does not call it a slot shortage
T.test('BUG-749 / BUG-748: a set-aside dig project names its dig jobs and the Miners; the text says no progress, not a slot shortage, and the free idle adults', function()
  local H = require('runner_world')
  local runner = require('dfllm.runner')
  local W = H.world{tag = 'b749dig'}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function() return nil end
  W.load({name = 'economy', every = {ticks = 100000},
          dig_wait = function(K, bb) return {text = '2 dig jobs here (2 open, 0 taken, 0 suspended); Miners detail 1 (0 idle, 1 at StoreItemInBarrel)', bb = bb} end,
          idle_free = function() return 5, 20 end})
  W.load(runner)
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, 'dg', H.dig_doc(1, {tpl = 'bedrooms', class = 'living', x = 20}))
  for _ = 1, 2 * 40 do H.runs(W, 1) end           -- designated, never dug: 40 days
  local ev
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.idle then ev = e end end
  T.ok(ev, 'set aside')
  T.ok(ev.d.parts and ev.d.parts:find('dig: 2 dig jobs here (2 open', 1, true), tostring(ev.d.parts))
  T.ok(ev.d.parts:find('Miners detail 1 (0 idle, 1 at StoreItemInBarrel)', 1, true), ev.d.parts)
  local full
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('set aside for want of progress, not of slots', 1, true) then full = l.msg end end
  T.ok(full and full:find('not of slots (5 free idle adults); resume:', 1, true), tostring(full))   -- the event text is cut at 200 bytes
  T.eq(ev.d.free, 5)
end)

T.done()
