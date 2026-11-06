-- BUG-544 (Run 16a i1 Basementflew y414/y415: census rock 32 / boulders 64 / blocks 62, all of them in the flooded z117 complex; masons
-- and mechanics never worked, bm_route took the 13 'free' blocks for the aqshaft ring and never switched buildingplan's logs on beside
-- 255 logs): a boulder, block or piece on another walk group than the citizens' is counted apart (`rock_far`, `blocks_far`, ...) and is
-- no stone and no building material.
-- BUG-545 (Run 16d i4 Trumpetrealms y404: 101 boulders, "Needs non-economic hard stone boulders" cancels for years, rock orders and
-- the mechanisms of the refuge levers queued for nothing): DF's own cancel, three within seven days, makes the stone count 0 and raises
-- DECISION_NEEDED no_hard_stone with the counts and the commands; boulders that are all economic stone say the same from the census.
-- BUG-547 (Run 16d i4 Trumpetrealms y397: the manager worked as HarvestPlants, a ConstructDoor order unvalidated for 14 days): orders
-- unvalidated past orders.unval_days and a manager with the Farming labor on: act.labor_set(manager, 'farm', false), at most daily.
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

T.test('BUG-544: boulders, blocks and doors on another walk group are counted apart (rock_far, blocks_far, doors_far) and are no stock', function()
  local W = world{boulders = 5, far_boulders = 20, blocks = 8, far_blocks = 13, logs = 40, setup = function(W)
    F.item(W, 'DOOR', {_pos = {5, 7, 1}})
    F.item(W, 'DOOR', {_pos = {6, 8, 37}})
    F.item(W, 'DOOR', {_pos = {6, 9, 37}})
  end}
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.rock, i.rock_far, i.blocks_free, i.blocks_far, i.doors, i.doors_far}, {5, 20, 8, 13, 1, 2}, T.show(i))
  T.eq(i.boulders, 25, 'the whole vector is still counted')
  local s = stock(W)
  T.eq({s.blocks, s.rock}, {8, 5})
  T.ok(s.logs > 0 and s.logs <= 40, 'logs above the mood floor: ' .. tostring(s.logs))
end)

T.test('BUG-544 (Basementflew): all the blocks and boulders lie in the flooded complex, 255 logs, buildingplan logs off: ' ..
       'the ring wall is no longer "built from blocks", buildingplan logs go on, wall_stock counts the logs only', function()
  local W = world{far_boulders = 64, far_blocks = 13, logs = 255, bp = {blocks = true, boulders = true, logs = false, bars = false},
                  jobs = function() return {wall(1, 7)} end}
  days(W, 1)
  T.ok(F.has(F.runs(W), 'buildingplan set logs true'), table.concat(F.runs(W), ' | '))
  T.eq(F.bad_runs(W), {}, 'allowlisted')
  local s = stock(W)
  T.eq({s.blocks, s.rock}, {0, 0})
  T.ok(s.logs >= 200, 'logs ' .. tostring(s.logs))
  T.eq(W.find_events('MATERIAL_SHORT'), {})
  -- the same fort with the blocks reachable: buildingplan's blocks answer, nothing is switched on
  local W2 = world{blocks = 13, logs = 255, bp = {blocks = true, boulders = true, logs = false, bars = false},
                   jobs = function() return {wall(1, 7)} end}
  days(W2, 1)
  T.ok(not F.has(F.runs(W2), 'buildingplan set logs true'), 'reachable blocks: no switch')
  -- nothing reachable at all: the reason names the other walk group
  local W3 = world{far_boulders = 64, far_blocks = 13, logs = 0, jobs = function() return {wall(1, 7)} end}
  days(W3, 1)
  local ev = W3.find_events('MATERIAL_SHORT')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('no rock, no blocks, no logs (77 boulders and blocks lie on another walk group)', 1, true), ev[1].msg)
end)

local function cancel(W, n)
  for _ = 1, n or 1 do
    W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mechanic cancels Make rock mechanisms: Needs non-economic hard stone boulders.'})
  end
  settle(W)
end

T.test('BUG-545 (Trumpetrealms): usable boulders by the census, DF cancels "Needs non-economic hard stone" three times: stone counts 0, ' ..
       'DECISION_NEEDED no_hard_stone with the commands, once; more boulders lift it', function()
  local W = world{boulders = 30, logs = 10}
  days(W, 1)
  T.eq(stock(W).rock, 30)
  cancel(W, 2)
  T.eq(stock(W).rock, 30, 'two cancels are no proof')
  T.eq(#decisions(W, 'no_hard_stone'), 0)
  cancel(W, 1)
  T.eq(stock(W).rock, 0, 'DF refuses the stone: it counts 0')
  local d = decisions(W, 'no_hard_stone')
  T.eq(#d, 1)
  T.eq(d[1].d.cause, 'denied')
  T.ok(d[1].d.q:find('Needs non-economic hard stone', 1, true), d[1].d.q)
  T.ok(d[1].d.q:find('wood serves', 1, true), d[1].d.q)
  local cmds = table.concat(d[1].d.cmds or {}, ' | ')
  T.ok(cmds:find('trade.want', 1, true) and cmds:find('mechanism', 1, true) and cmds:find('plan propose', 1, true), cmds)
  cancel(W, 3)
  T.eq(#decisions(W, 'no_hard_stone'), 1, 'the same cause is not asked again')
  -- the state: the caravans are asked for stone
  local want = select(2, W.K.call('economy', 'supply_wants'))
  T.ok(type(want) == 'table')
  -- ten new boulders (more than 5 beyond the count at the last cancel): stone is believed again
  for _ = 1, 10 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7, _pos = {5, 5, 1}}) end
  days(W, 1)
  T.eq(stock(W).rock, 40, 'new stone arrived')
  -- and after hold_days without a cancel
  local W2 = world{boulders = 30}
  days(W2, 1)
  cancel(W2, 3)
  T.eq(stock(W2).rock, 0)
  days(W2, 15)
  T.eq(stock(W2).rock, 30, 'hold_days passed without a cancel')
end)

T.test('BUG-545: 20 boulders, all economic stone (no usable one), 40 rock orders waiting: the decision comes from the census alone', function()
  local W = world{boulders = 20, econ = true, logs = 0, rock_orders = 40}
  days(W, 1)
  local d = decisions(W, 'no_hard_stone')
  T.eq(#d, 1, 'asked')
  T.eq(d[1].d.cause, 'none')
  T.ok(d[1].d.q:find('no non-economic hard stone: 20 boulders, 0 usable (20 economic/soft', 1, true), d[1].d.q)
  days(W, 5)
  T.eq(#decisions(W, 'no_hard_stone'), 1, 'once (util/cadence)')
  -- 20 usable boulders and the same orders: no decision
  local W2 = world{boulders = 20, logs = 0, rock_orders = 40}
  days(W2, 2)
  T.eq(#decisions(W2, 'no_hard_stone'), 0)
end)

T.test('BUG-547 (Trumpetrealms): 3 orders unvalidated for 3 days, the manager has the Farming labor on: it goes off, once a day, ' ..
       'the cause is named by inspect manager', function()
  local W, ctl = world{unval = 3, logs = 30}
  days(W, 1)
  T.eq(#ctl.labor, 0, 'unval_days (2) not passed')
  days(W, 2)
  T.eq(#ctl.labor, 1, T.show(ctl.labor))
  T.eq(ctl.labor[1], {id = 2, which = 'farm', on = false})
  T.eq(W.unit(2).status.labors[7], false)
  days(W, 3)
  T.eq(#ctl.labor, 1, 'off stays off: nothing more')
  W.unit(2).status.labors[7] = true                  -- the work details give it back
  days(W, 2)
  T.eq(#ctl.labor, 2, 'switched off again, not more than once a day')
  -- inspect manager names the farmer
  W.unit(2).job = {current_job = {id = 77, job_type = df.job_type.HarvestPlants}}
  W.unit(2).status.labors[7] = true
  local r = W.inbox('inspect', {what = 'manager'})
  T.ok(r.ok and tostring(r.msg):find('he works as a farmer (HarvestPlants)', 1, true) ~= nil, T.show(r))
  -- a manager without the labor: nothing; no unvalidated order: nothing
  local W2, ctl2 = world{unval = 3, plant = false}
  days(W2, 5)
  T.eq(#ctl2.labor, 0)
  local W3, ctl3 = world{unval = 0}
  days(W3, 5)
  T.eq(#ctl3.labor, 0)
end)

T.test('BUG-546: economy.mechanic_labor: nobody has the Mechanics labor: the best candidate (idle first; no soldier, no patient, no noble) ' ..
       'gets it through act.labor_set, once a day; a holder is enough', function()
  local W, ctl = world{unval = 0}
  W.unit(3).military.squad_id = 1                      -- a soldier
  W.unit(4).job = nil                                  -- idle
  W.unit(5).job = nil                                  -- idle too
  W.unit(5)._m.skills = {MECHANICS = 4}
  local function call() return W.K.call('economy', 'mechanic_labor') end
  local ok, res, uid = call()
  T.eq({ok, res}, {true, 'set'})
  T.eq(ctl.labor[#ctl.labor].which, 'mechanic')
  T.ok(uid == 4 or uid == 5, 'an idle adult: ' .. tostring(uid))
  T.ok(uid ~= 2 and uid ~= 3, 'not the manager, not the soldier')
  ok, res, uid = call()
  T.eq({ok, res}, {true, 'have'})
  T.eq(#ctl.labor, 1, 'a holder is enough: nothing more')
end)

T.done()
