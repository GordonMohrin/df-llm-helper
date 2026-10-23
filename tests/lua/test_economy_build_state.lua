-- BUG-044 (Run 11 y483-y497, Kilrudrabed, notes 21/22): the seal door 115,73,143 stood open for 14 game years, its
-- ConstructBuilding job "SUSPENDED again and again" and the status said only "stalled". economy.build_state reads what
-- the building on a tile and its job wait for (the building sheet and the job list; read-only) and names the component
-- that keeps the job suspended: buildingplan (a planned building suspends its own job until its materials are attached:
-- a resume by hand is undone at once, with suspendmanager disabled too), suspendmanager (isKeptSuspended) or DF itself
-- (the builder's cancel report, items on the tile). Every test fails on f17e2b3 (no economy.build_state).
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

local X, Y, Z = 115, 73, 143

-- opts: sm, bp (plugin fakes), blds = {[key] = building}, items (snapshot.items_at answer), orders
local function world(opts)
  local W = F.world{cfg = {baseline = F.cfg()}, units = {}}
  add_jobs({'ConstructBuilding'})
  package.loaded['plugins.suspendmanager'] = opts.sm
  package.loaded['plugins.buildingplan'] = opts.bp
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z) return (opts.blds or {})[x .. ',' .. y .. ',' .. z] end
  W.load({name = 'snapshot', every = {ticks = 100},
          items_at = function(K, x0, y0, x1, y1, z) return opts.items or {} end})
  W.set_census('i', opts.inv or {})
  W.economy = fresh('economy')
  W.load(W.economy)
  return W
end

-- a door building at X,Y,Z with its construction job; job.job_items wants one DOOR
local function door(job)
  local ji = {item_type = df.item_type.DOOR, quantity = 1, mat_type = -1, mat_index = -1, flags2 = {}}
  local j = {id = 4711, job_type = df.job_type.ConstructBuilding, flags = {suspend = true},
             job_items = {elements = kmock.vec{ji}}, items = kmock.vec{}}
  for k, v in pairs(job or {}) do j[k] = v end
  return {id = 900, x1 = X, y1 = Y, x2 = X, y2 = Y, z = Z, _st = 0, jobs = kmock.vec{j},
          getType = function() return df.building_type.Door end,
          getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}, j
end

local function state(W, x, y, z)
  local ok, r = W.K.call('economy', 'build_state', x or X, y or Y, z or Z)
  T.ok(ok, 'economy.build_state is called')
  return r
end

T.test('BUG-044: nothing stands on the tile, or the building is built: said so', function()
  local W = world{}
  T.eq(state(W), {none = true, line = 'nothing stands at 115,73,143'})
  local b = door()
  b._st = 1
  local W2 = world{blds = {['115,73,143'] = b}}
  local r = state(W2)
  T.eq({r.built, r.kind, r.line}, {true, 'Door', 'built'})
end)

T.test('BUG-044: a planned door waits for its door item: buildingplan suspends the job itself (a resume by hand is ' ..
       'undone), the line names the item, the free ones and the open ConstructDoor orders', function()
  local b = door()
  local bp = {isPlannedBuilding = function(x) return x.id == 900 end}
  local sm = {isKeptSuspended = function() return false end}
  local W = world{blds = {['115,73,143'] = b}, bp = bp, sm = sm, inv = {doors = 0}}
  local mo = df.global.world.manager_orders.all
  for i = 1, 3 do mo:insert('#', {id = i, job_type = df.job_type.ConstructDoor, frequency = 0, amount_left = 10,
                                  status = {validated = i == 1}}) end
  local r = state(W)
  T.eq({r.who, r.planned, r.susp, r.job, r.work}, {'buildingplan', true, true, 4711, false})
  T.eq(r.line, 'job 4711 suspended by buildingplan: waits for door x1 (0 free, 30 ordered, 20 not validated)')
  T.eq(r.piece_ord, {30, 20})
end)

T.test('BUG-044: suspendmanager keeps the job suspended (preventblocking): the line carries its own description', function()
  local b = door()
  local sm = {isKeptSuspended = function() return true end,
              suspensionDescription = function() return 'Blocks another build job' end}
  local W = world{blds = {['115,73,143'] = b}, bp = {isPlannedBuilding = function() return false end}, sm = sm}
  local r = state(W)
  T.eq({r.who, r.kept, r.desc}, {'suspendmanager', true, 'Blocks another build job'})
  T.eq(r.line, 'job 4711 suspended by suspendmanager: Blocks another build job')
end)

T.test('BUG-044: neither plugin keeps it: DF suspended it (the builder cancelled): the cancel report near the tile and ' ..
       'the items on the tile are named; nothing readable is said as such', function()
  local b = door()
  local W = world{blds = {['115,73,143'] = b}, bp = {isPlannedBuilding = function() return false end},
                  sm = {isKeptSuspended = function() return false end}, items = {{501}, {502}, {503}}}
  local f = {}
  for id, forb in pairs({[501] = true, [502] = false, [503] = true}) do
    f[id] = {id = id, flags = {forbid = forb}}
  end
  df.item.find = function(id) return f[id] end
  W.K.on = nil
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist cancels Construct Building: Item blocking site.',
                     pos = {x = X, y = Y, z = Z}})
  W.frame(1)
  local r = state(W)
  T.eq(r.who, 'DF')
  T.eq(r.site, {forb = 2, other = 1})
  T.ok(r.line:find('^job 4711 suspended by DF %(not buildingplan, not suspendmanager%): '), r.line)
  T.eq(r.cancel, 'Item blocking site')
  T.ok(r.line:find(': cancelled "Item blocking site"; 2 forbidden and 1 other items on the tile', 1, true), r.line)
  local W2 = world{blds = {['115,73,143'] = door()}, bp = {isPlannedBuilding = function() return false end},
                   sm = {isKeptSuspended = function() return false end}}
  T.eq(state(W2).line, 'job 4711 suspended by DF (not buildingplan, not suspendmanager): no cause readable')
end)

T.test('BUG-044: a job that is not suspended: a builder works at it, or nobody has taken it', function()
  local b, j = door({flags = {suspend = false}})
  local W = world{blds = {['115,73,143'] = b}}
  T.eq(state(W).line, 'job 4711 not suspended, no builder has taken it')
  j._worker = {id = 7}
  local r = state(W)
  T.eq({r.work, r.line}, {true, 'job 4711 runs: a builder works at it'})
  local b2 = door()
  b2.jobs = kmock.vec{}
  local W2 = world{blds = {['115,73,143'] = b2}}
  T.eq(state(W2).line, 'no construction job')
end)

T.test('BUG-044: the same answer on demand: inspect workload key build:x,y,z (read-only; the live data the notes 21/22 ' ..
       'were missing)', function()
  local b = door()
  local bp = {isPlannedBuilding = function(x) return x.id == 900 end}
  local W = world{blds = {['115,73,143'] = b}, bp = bp, inv = {doors = 0}}
  local r = W.inbox('inspect', {what = 'workload', key = 'build:115,73,143'})
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'job 4711 suspended by buildingplan: waits for door x1 (0 free, 0 ordered)')
  T.eq({r.data.who, r.data.job, r.data.planned, r.data.pos}, {'buildingplan', 4711, true, nil})
  local none = W.inbox('inspect', {what = 'workload', key = 'build:1,2,3'})
  T.eq({none.ok, none.msg, none.data.none}, {true, 'nothing stands at 1,2,3', true})
end)

T.done()
