-- BUG-607 (treeless fort: stone doors, wood-only beds), BUG-610 (the hard-stone denial is held after a second episode); BUG-608 / BUG-612
-- (runner) are in test_bug608_612_runner.lua. Round 39 economy blockers, offline.
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
  for _, j in ipairs(jobs) do
    cur.next = {item = j}
    cur = cur.next
  end
  df.global.world.jobs = {list = head}
end

-- a wall (building material) waiting at x,50,109
local function wall(id, n, x)
  local b = {id = 500 + id, x1 = x or 20, y1 = 50, x2 = x or 20, y2 = 50, z = 109,
             getType = function() return df.building_type.Construction end, getBuildStage = function() return 0 end}
  return {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b, items = kmock.vec{},
          job_items = {elements = kmock.vec{{item_type = -1, mat_type = -1, mat_index = -1, quantity = n or 1,
                                             flags2 = {building_material = true}}}}}
end

-- opts: boulders / far_boulders (z 37 = another walk group), blocks / far_blocks, logs, econ (the boulders' stone is economic stone),
-- bp (buildingplan settings), rock_orders, unval (unvalidated manager orders), plant (the manager's Farming labor is on), jobs, setup
local function world(opts)
  opts = opts or {}
  local ctl = {labor = {}}
  local units = {}
  for i = 1, 20 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'ConstructBuilding', 'Dig', 'MakeWeapon', 'HarvestPlants'})
  df.unit_labor = {PLANT = 7, MECHANIC = 8, [7] = 'PLANT', [8] = 'MECHANIC'}
  local ids = {}
  for i = 1, 20 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.unit(2).status.labors[7] = opts.plant ~= false
  W.set_census('u', F.census_u(ids))
  df.global.plotinfo.main = {fortress_entity = {positions = {
    own = kmock.vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
    assignments = kmock.vec{{id = 1, position_id = 3, histfig = 5769, histfig2 = 5769}}}}}
  W.unit(2).hist_figure_id = 5769
  W.unit(2)._m.name = 'Domas Shorastthum, Manager'
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  dfhack.job.getWorker = function(j) return j._worker end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = {isPlannedBuilding = function() return true end,
                                            getGlobalSettings = function()
                                              return opts.bp or {blocks = true, boulders = true, logs = true, bars = false}
                                            end}
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  for _ = 1, opts.logs or 0 do F.item(W, 'WOOD', {mat_type = 420, mat_index = 0}) end
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  for _ = 1, opts.far_boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {6, 6, 37}}) end
  for _ = 1, opts.blocks or 0 do F.item(W, 'BLOCKS', {_pos = {5, 6, 1}}) end
  for _ = 1, opts.far_blocks or 0 do F.item(W, 'BLOCKS', {_pos = {6, 7, 37}}) end
  for _, name in ipairs({'Masons', 'Carpenters', 'Mechanics'}) do F.workshop(W, name) end
  local one = df.workquota_frequency_type.OneTime
  if (opts.rock_orders or 0) > 0 then
    F.order(W, {job_type = df.job_type.ConstructTable, mat_type = 0, mat_index = -1, amount_left = opts.rock_orders,
                amount_total = opts.rock_orders, frequency = one, material_category = {}, _name = 'Construct rock Table'})
  end
  for _ = 1, opts.unval or 0 do
    F.order(W, {job_type = df.job_type.ConstructBuilding, amount_left = 1, amount_total = 1, frequency = one, mat_type = -1,
                mat_index = -1, material_category = {wood = true}, status = {validated = false}})
  end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return z == 37 end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  W.act_result('labor_set', function(id, which, on)
    ctl.labor[#ctl.labor + 1] = {id = id, which = which, on = on}
    if which == 'farm' then W.unit(id).status.labors[7] = false end
    if which == 'mechanic' then W.unit(id).status.labors[8] = true end
    return true, on and 'enabled' or 'disabled'
  end)
  if opts.econ then
    local d0 = dfhack.matinfo.decode
    dfhack.matinfo.decode = function(t, i)
      local m = d0(t, i)
      if m and t == 0 and i == 7 then m.inorganic = {metal_ore = {mat_index = {}}}; m.material.reaction_class = {} end
      return m
    end
    F.mat(W, 0, 7, {token = 'INORGANIC:MUDSTONE', flags = {ITEMS_HARD = true}})
    df.global.plotinfo.economic_stone = {[7] = 1}
  end
  if opts.setup then opts.setup(W, ctl) end
  job_list(opts.jobs and opts.jobs() or {})
  W.load(fresh('economy'))
  return W, ctl
end

local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function stock(W) return select(2, W.K.call('economy', 'wall_stock')) end

local function cancel(W, n)
  for _ = 1, n or 1 do
    W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mechanic cancels Make rock mechanisms: Needs non-economic hard stone boulders.'})
  end
  settle(W)
end

-- BUG-607 (Run 16c i3 Wallfree: an embark without a tree, doors and beds waited 32 days for logs): after treeless_days (20) with no log the
-- doors, chests ... are made of stone even while DF's hard-stone denial holds the stone at 0 (a bounded probe); a bed (wood only) says so
T.test('BUG-607: treeless fort: a door goes to the Masons in the hard-stone denial, a bed is named wood-only; a fort with logs is unchanged', function()
  local W0 = world{boulders = 30, logs = 0}
  days(W0, 2)
  cancel(W0, 3)
  T.eq(stock(W0).rock, 0, 'DF refuses the stone')
  local v0, w0 = select(2, W0.K.call('economy', 'mat_for', 'door', 1))
  T.eq(v0, nil, 'two days without logs are no treeless fort: ' .. tostring(w0))
  local W = world{boulders = 30, logs = 0}
  days(W, 22)
  cancel(W, 3)
  T.eq(stock(W).rock, 0, 'DF refuses the stone')
  local via, why = select(2, W.K.call('economy', 'mat_for', 'door', 1))
  T.eq(via, 'rock', 'treeless: the stone door is tried: ' .. tostring(why))
  local bv, bw = select(2, W.K.call('economy', 'mat_for', 'bed', 1))
  T.eq(bv, nil)
  T.ok(bw:find('no logs, the fort has no trees', 1, true) and bw:find('a bed is wood only: trade.want wood', 1, true), bw)
  -- a fort with logs: the old answer (wood for the door while stone is denied)
  local W2 = world{boulders = 30, logs = 40}
  days(W2, 2)
  cancel(W2, 3)
  local v2 = select(2, W2.K.call('economy', 'mat_for', 'door', 1))
  T.eq(v2, 'wood')
  days(W2, 22)
  v2 = select(2, W2.K.call('economy', 'mat_for', 'bed', 1))
  T.eq(v2, 'wood', 'beds are made of the logs it has')
end)

-- BUG-610 (Run 16a i1 Basementflew y426-y429: the 14-day hold ran out, the rock orders came back, DF cancelled them again): the second
-- episode with no new boulders is held until new boulders come, with no time limit
T.test('BUG-610: a second hard-stone denial is held until new boulders come; the first one still ends after hold_days', function()
  local W = world{boulders = 30, logs = 10}
  days(W, 1)
  cancel(W, 3)
  T.eq(stock(W).rock, 0)
  days(W, 15)
  T.eq(stock(W).rock, 30, 'hold_days passed: the first episode ends')
  cancel(W, 3)                                          -- the rock orders were queued again and DF cancelled them again
  T.eq(stock(W).rock, 0)
  days(W, 40)
  T.eq(stock(W).rock, 0, 'second episode: no time limit')
  T.eq(#decisions(W, 'no_hard_stone'), 1, 'asked once')
  for _ = 1, 10 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  days(W, 1)
  T.eq(stock(W).rock, 40, 'new boulders lift it')
  cancel(W, 3)
  T.eq(stock(W).rock, 0, 'denied again')
  days(W, 15)
  T.eq(stock(W).rock, 40, 'a fresh denial is a first episode again')
end)

T.done()
