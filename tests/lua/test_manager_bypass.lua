-- economy BUG-231..233 (live Guildcleans, run 15, y372-y373, pop 20): the manager had no office zone, so DF's manager
-- validated none of the 22 manager work orders (#84/#85 Make wooden door 333 days old, blocks, food). The office project
-- (bp.place office c1a1873b86d5b80201) itself waited for a chair and a table that only those orders made: no door ->
-- the seal stuck (perimeter open 427 days), workshops, tombs and farms hung, a strange mood failed. Now: past
-- orders.bypass_days the kernel adds the held items as workshop tasks (act.ws_task, a player's "add task" without the
-- manager), bounded and deduped; no shop -> PROJECT_REQUEST workshops why=manager; an Office zone is drawn over a lone
-- chair; the state says what happens (orders.mgr / orders.byp).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local function job_list(jobs)
  local head = {}
  local cur = head
  for _, j in ipairs(jobs) do
    cur.next = {item = j}
    cur = cur.next
  end
  df.global.world.jobs = {list = head}
end

-- a planned door (buildingplan) at x,50,109 waiting for its door item
local function planned_door(id, x)
  local b = {id = 500 + id, x1 = x, y1 = 50, x2 = x, y2 = 50, z = 109,
             getType = function() return df.building_type.Door end, getBuildStage = function() return 0 end}
  return {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b, items = kmock.vec{},
          job_items = {elements = kmock.vec{{item_type = df.item_type.DOOR, mat_type = -1, mat_index = -1, quantity = 1}}}}
end

-- opts: office (true: the manager's zone 18631 without furniture; default none), shops ({'Carpenters'}), logs (30),
-- boulders (0), orders (22 unvalidated doors/blocks), doors (planned doors), cfg (economy overrides), setup
local function world(opts)
  opts = opts or {}
  local ctl = {tasks = {}, zones = {}, shops = {}}
  local units = {}
  for i = 1, 20 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local cfg = F.cfg()
  cfg.economy.standing = false
  for part, kv in pairs(opts.cfg or {}) do
    cfg.economy[part] = cfg.economy[part] or {}
    for k, v in pairs(kv) do cfg.economy[part][k] = v end
  end
  local W = F.world{cfg = {baseline = cfg}, units = units}
  add_jobs({'ConstructBuilding'})
  local ids = {}
  for i = 1, 20 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u(ids))
  df.global.plotinfo.main = {fortress_entity = {positions = {
    own = kmock.vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
    assignments = kmock.vec{{id = 1, position_id = 3, histfig = 5769, histfig2 = 5769}}}}}
  local mg = W.unit(2)
  mg.hist_figure_id = 5769
  mg._m.name = 'Astesh Shorastthum, Manager'
  dfhack.units.getUnitByNobleRole = function(role) if role == 'manager' then return W.unit(2) end end
  if opts.office then
    F.building(W, 'ACTIVITY_ZONE', {id = 18631, type = df.civzone_type.Office, x1 = 127, y1 = 73, x2 = 129, y2 = 75,
                                    z = 141, assigned_unit_id = 2})
  end
  dfhack.buildings.findAtTile = function() return nil end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = {isPlannedBuilding = function() return true end,
                                            getGlobalSettings = function()
                                              return {blocks = true, boulders = true, logs = true, bars = false}
                                            end}
  dfhack.job.getWorker = function(j) return j._worker end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  for _ = 1, opts.logs or 30 do F.item(W, 'WOOD', {mat_type = 420, mat_index = 0}) end
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7}) end
  for _, name in ipairs(opts.shops or {'Carpenters'}) do
    local b = F.workshop(W, name)
    b.jobs = kmock.vec{}
    ctl.shops[name] = b
  end
  local one = df.workquota_frequency_type.OneTime
  for k = 1, opts.orders or 22 do
    F.order(W, {job_type = k % 2 == 0 and df.job_type.ConstructDoor or df.job_type.ConstructBlocks, amount_left = 1,
                amount_total = 1, frequency = one, mat_type = -1, mat_index = -1, material_category = {wood = true},
                status = {validated = false}})
  end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P1'} end,
          repair = function(K, cells, why) return true, 'rp1' end})
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  -- workshop sheet > add task: the job appears in the shop's queue (DF counts it there)
  W.act_result('ws_task', function(id, job, mat)
    ctl.tasks[#ctl.tasks + 1] = {id = id, job = job, mat = mat}
    for _, b in pairs(ctl.shops) do
      if b.id == id then b.jobs:insert('#', {id = 7000 + #ctl.tasks, job_type = df.job_type[job]}) end
    end
    return true, 7000 + #ctl.tasks
  end)
  W.act_result('zone_place', function(spec)
    ctl.zones[#ctl.zones + 1] = spec
    local zid = 19000 + #ctl.zones
    F.building(W, 'ACTIVITY_ZONE', {id = zid, type = df.civzone_type.Office, x1 = spec.box.x0, y1 = spec.box.y0,
                                    x2 = spec.box.x1, y2 = spec.box.y1, z = spec.box.z, assigned_unit_id = -1})
    return true, {ids = {zid}}
  end)
  if opts.setup then opts.setup(W, ctl) end
  local jobs = {}
  for k, x in ipairs(opts.doors or {}) do jobs[#jobs + 1] = planned_door(k, x) end
  job_list(jobs)
  W.load(fresh('economy'))
  return W, ctl
end

local function tasks_of(ctl, job)
  local n = 0
  for _, t in ipairs(ctl.tasks) do if t.job == job then n = n + 1 end end
  return n
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end

T.test('BUG-231 live Guildcleans replay: no office zone, 22 orders unvalidated: after bypass_days the office\'s chair '
       .. 'and table come as workshop tasks at the Carpenters (wood), once, with MANAGER_BYPASS and the state line',
       function()
  local W, ctl = world{}
  days(W, 4)
  T.eq(#ctl.tasks, 0, 'before orders.bypass_days (5) the manager may still validate')
  local s = W.state()
  T.eq(s.orders.mgr, 'no office (chair+table needed)', 'BUG-233: the reason in the words the status shows')
  days(W, 2)
  T.eq(tasks_of(ctl, 'ConstructThrone'), 1, 'old code: nothing ever made the chair (the deadlock)')
  T.eq(tasks_of(ctl, 'ConstructTable'), 1)
  T.eq({ctl.tasks[1].id, ctl.tasks[1].mat}, {ctl.shops.Carpenters.id, 'wood'})
  local ev = W.find_events('MANAGER_BYPASS')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('no office (chair+table needed)', 1, true) and ev[1].msg:find('chair (wood) at', 1, true), ev[1].msg)
  T.eq({ev[1].d.n, ev[1].d.why}, {2, 'no office (chair+table needed)'})
  s = W.state()
  T.eq(s.orders.byp, 'kernel adds workshop tasks: chair, table')
  -- the queued tasks count: no second chair while the first waits in the shop's queue
  days(W, 5)
  T.eq({tasks_of(ctl, 'ConstructThrone'), tasks_of(ctl, 'ConstructTable')}, {1, 1}, 'deduped by the shop queue')
  T.eq(#W.find_events('MANAGER_BYPASS'), 1)
  -- the question the player hears asks for nothing a player without clicks cannot do (BUG-233)
  for _, d in ipairs(decisions(W, 'manager_office')) do
    T.ok(not d.d.q:find('by hand', 1, true), d.d.q)
  end
  -- the chair and the table are made (free in the census): nothing is wanted, the line stays the reason
  F.item(W, 'CHAIR', {})
  F.item(W, 'TABLE', {})
  days(W, 2)
  T.eq(#ctl.tasks, 2)
end)

T.test('BUG-231: the doors the planned buildings wait for are added too, bounded by bypass_max a day and bypass_open',
       function()
  local W, ctl = world{office = true, doors = {20, 21, 22, 23, 24, 25, 26}}
  days(W, 6)
  T.eq(tasks_of(ctl, 'ConstructThrone') + tasks_of(ctl, 'ConstructTable'), 2, 'the office\'s chair and table first')
  T.eq(#ctl.tasks, 4, 'bypass_max 4 a day')
  T.ok(W.state().orders.byp:find('door x6', 1, true), W.state().orders.byp)    -- pieces.max_n 6 of the 7 doors
  days(W, 1)
  T.eq(#ctl.tasks, 8, 'the next day four more (8 = bypass_open)')
  days(W, 3)
  T.eq(#ctl.tasks, 8, 'never more than bypass_open queued at once')
  T.eq(tasks_of(ctl, 'ConstructDoor'), 6)
end)

T.test('BUG-231: no logs: the Mason\'s workshop in stone; no shop at all: PROJECT_REQUEST workshops why=manager once a '
       .. 'week; bypass_days 0 is off', function()
  local W, ctl = world{shops = {'Masons'}, logs = 0, boulders = 40}
  days(W, 6)
  T.eq(#ctl.tasks, 2)
  T.eq({ctl.tasks[1].job, ctl.tasks[1].mat, ctl.tasks[1].id}, {'ConstructThrone', 'rock', ctl.shops.Masons.id})
  local W2, ctl2 = world{shops = {}}
  days(W2, 6)
  T.eq(#ctl2.tasks, 0)
  local rq = {}
  for _, e in ipairs(W2.find_events('PROJECT_REQUEST')) do if e.d.why == 'manager' then rq[#rq + 1] = e end end
  T.eq(#rq, 1)
  T.eq({rq[1].d.tpl, rq[1].d.types}, {'workshops', {'Carpenters'}})
  T.ok(W2.state().orders.byp:find('no Carpenters: workshop requested for chair, table', 1, true), W2.state().orders.byp)
  days(W2, 3)
  T.eq(#W2.find_events('PROJECT_REQUEST'), 1, 'not again within 7 days')
  local W3, ctl3 = world{cfg = {orders = {bypass_days = 0}}}
  days(W3, 8)
  T.eq(#ctl3.tasks, 0, 'orders.bypass_days 0: off')
end)

T.test('BUG-231 live Guildcleans (deep soil, stone free 0): the logs the held wood orders reserve are free for the tasks; '
       .. 'no stone and no mason workshop asks for no Masons', function()
  local W, ctl = world{logs = 12, boulders = 0}             -- 22 held wood orders reserve more logs than stand
  days(W, 6)
  T.eq({tasks_of(ctl, 'ConstructThrone'), tasks_of(ctl, 'ConstructTable')}, {1, 1},
       'old code: wood_left counted the held orders, 0 logs, no stone: no task ever (the deadlock stayed)')
  T.eq(ctl.tasks[1].mat, 'wood')
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do T.ok(e.d.why ~= 'manager', e.msg) end
end)

T.test('BUG-232: no Office zone at all: one is drawn over a built chair and the table beside it outside every room zone; '
       .. 'a chair in a bedroom is left alone', function()
  local W, ctl = world{setup = function(W)
    local function furn(cat, x, y)
      local b = F.building(W, cat, {x1 = x, y1 = y, x2 = x, y2 = y, z = 120, getMaxBuildStage = function() return 1 end})
      b.getBuildStage = function() return 1 end
    end
    F.building(W, 'ACTIVITY_ZONE', {id = 300, type = df.civzone_type.Bedroom, x1 = 10, y1 = 10, x2 = 12, y2 = 12, z = 120,
                                    assigned_unit_id = 5})
    furn('CHAIR', 11, 11)                                   -- a bedroom's chair: not the manager's
    furn('CHAIR', 40, 40)
    furn('TABLE', 41, 40)
  end}
  days(W, 2)
  T.eq(#ctl.zones, 1)
  T.eq({ctl.zones[1].cell, ctl.zones[1].pos, ctl.zones[1].ztype}, {'o{name=Office}(2x1)', {40, 40, 120}, 'Office'})
  local mo = W.find_events('MANAGER_OFFICE')
  T.ok(#mo >= 1 and mo[1].msg:find('Office zone 19001 drawn over the chair at 40,40-41,40 z120', 1, true),
       mo[1] and mo[1].msg)
  T.ok(#W.find_acts('manager_office') >= 1, 'the free zone is then given to the manager (act.manager_office)')
  days(W, 8)
  T.eq(#ctl.zones, 1, 'one zone; the free one exists now')
end)

T.done()
