-- BUG-060: a stone furniture order that makes no job while a planned building waits for that piece is stale after
-- stale.wait_days (3), not stale.days (10); the planned building's door order goes wood (Run 13 y508: five builds
-- "waiting for materials (door x5)", eleven stone door orders without a job).
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
  local head, cur = {}, nil
  cur = head
  for _, j in ipairs(jobs) do cur.next = {item = j}; cur = cur.next end
  df.global.world.jobs = {list = head}
end
local function planned_door(id, x)
  local b = {id = 500 + id, x1 = x, y1 = 50, x2 = x, y2 = 50, z = 109,
             getType = function() return df.building_type.Door end, getBuildStage = function() return 0 end}
  return {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b, items = kmock.vec{},
          job_items = {elements = kmock.vec{{item_type = df.item_type.DOOR, mat_type = -1, mat_index = -1, quantity = 1}}}}
end

local function world(waiting)
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'ConstructBuilding'})
  df.unit_labor = {MASON = 1, CARPENTER = 2, [1] = 'MASON', [2] = 'CARPENTER'}
  for i = 1, 4 do
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {[1] = true, [2] = true}, -1
  end
  W.set_census('u', F.census_u({1, 2, 3, 4}))
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = {isPlannedBuilding = function() return true end,
                                            getGlobalSettings = function() return {blocks = true, boulders = true, logs = true, bars = false} end}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  W.act_result('order_material', function(id, mat)
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if o.id == id then o.mat_type, o.mat_index = -1, -1; o.material_category = {wood = true}; return true, 'wood' end
    end
    return false, 'no order'
  end)
  for _ = 1, 40 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7}) end
  for _ = 1, 40 do F.item(W, 'WOOD', {mat_type = 420, mat_index = 0}) end
  F.workshop(W, 'Masons')
  F.workshop(W, 'Carpenters')
  for _ = 1, 2 do                      -- quickfort's rock door orders: validated, one-time, no conditions
    F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = 0, mat_index = -1, amount_left = 5, amount_total = 5,
                frequency = df.workquota_frequency_type.OneTime, material_category = {}, item_conditions = kmock.vec{},
                item_subtype = -1, status = {validated = true}, _name = 'Construct rock Door'})
  end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  job_list(waiting and {planned_door(1, 20)} or {})
  W.load(fresh('economy'))
  return W
end

T.test('BUG-060: with a planned door waiting the stone door orders are stale after wait_days, not stale.days', function()
  local W = world(true)
  days(W, 2)
  T.eq(#W.find_acts('order_material'), 0, 'not before wait_days')
  days(W, 3)
  local om = W.find_acts('order_material')
  T.eq(#om, 2, 'both stone door orders went wood after 3 days')
  local ev = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if e.d.why:find('stale', 1, true) then ev[#ev + 1] = e end end
  T.eq(#ev, 2)
  T.eq(ev[1].d.days >= 3 and ev[1].d.days < 10, true)
end)

T.test('BUG-060: without a planned building the same orders wait stale.days', function()
  local W = world(false)
  days(W, 6)
  T.eq(#W.find_acts('order_material'), 0)
  days(W, 5)
  T.eq(#W.find_acts('order_material'), 2)
end)

T.done()
