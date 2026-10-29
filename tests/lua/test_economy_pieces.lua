-- economy (Run 11, Kilrudrabed site98 y432, BREACH, pop 54): REFUGE_FAIL `open to 1 entrance 128,121,143 floor beside
-- door 127,121,143`, `seal at=last` ended build_lost (missing d) while ConstructDoor was cancelled for rock (1 boulder,
-- ~110 orders 'no rock'), 2 picks and 1 iron bar for the miners. What planned buildings wait for is ordered in a material
-- the fort has (T.jmake), walls switch buildingplan's logs on, MATERIAL_SHORT once, economy.mat_for, a "Needs rock" cancel
-- re-enters the order in wood or removes it, PROJECT_REQUEST bedrooms why=rock, picks forged or wanted from the caravans.
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

-- a planned building (buildingplan) at x,50,109 waiting for `n` items of item type `itype` ('BM' = building material;
-- a Construction then, or `btype`)
local function planned(id, itype, n, x, btype)
  local bt = btype or (itype == 'BM' and 'Construction' or 'Door')
  local b = {id = 500 + id, x1 = x or 20, y1 = 50, x2 = x or 20, y2 = 50, z = 109,
             getType = function() return df.building_type[bt] end, getBuildStage = function() return 0 end}
  local ji = itype == 'BM' and {item_type = -1, mat_type = -1, mat_index = -1, quantity = n or 1,
                                flags2 = {building_material = true}}
             or {item_type = df.item_type[itype], mat_type = -1, mat_index = -1, quantity = n or 1}
  return {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b, items = kmock.vec{},
          job_items = {elements = kmock.vec{ji}}}
end

-- opts: jobs (fn -> list), boulders, logs, bars ({token = n}), shops, rock_orders (amount of open rock tables),
-- door_order (a quickfort rock door order), bp (buildingplan settings), picks, mode, setup(W, ctl)
local function world(opts)
  opts = opts or {}
  local ctl = {bp_settings = opts.bp or {blocks = true, boulders = true, logs = true, bars = false}, pending = 0,
               backlog = 0}
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  add_jobs({'ConstructBuilding', 'Dig', 'MakeWeapon'})
  for i = 1, 4 do
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u({1, 2, 3, 4}))
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = {isPlannedBuilding = function() return true end,
                                            getGlobalSettings = function() return ctl.bp_settings end}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  W.act_result('order_material', function(id, mat)
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if o.id == id then o.mat_type, o.mat_index = -1, -1; o.material_category = {wood = true}; return true, 'wood' end
    end
    return false, 'no order'
  end)
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7}) end
  for _ = 1, opts.logs or 0 do F.item(W, 'WOOD', {mat_type = 420, mat_index = 0}) end
  for tok, n in pairs(opts.bars or {}) do
    local idx = tok == 'IRON' and 8 or 9
    F.mat(W, 0, idx, {token = 'INORGANIC:' .. tok, flags = {IS_METAL = true}})
    for _ = 1, n do F.item(W, 'BAR', {mat_type = 0, mat_index = idx}) end
  end
  for _, ws in ipairs(opts.shops or {'Masons', 'Carpenters'}) do F.workshop(W, ws) end
  local one = df.workquota_frequency_type.OneTime
  if (opts.rock_orders or 0) > 0 then
    F.order(W, {job_type = df.job_type.ConstructTable, mat_type = 0, mat_index = -1, amount_left = opts.rock_orders,
                amount_total = opts.rock_orders, frequency = one, material_category = {}, _name = 'Construct rock Table'})
  end
  if opts.door_order then
    ctl.door = F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = 0, mat_index = -1, amount_left = 1,
                           amount_total = 1, frequency = one, material_category = {}, _name = 'Construct rock Door'})
  end
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  for _ = 1, opts.picks or 0 do F.item(W, 'WEAPON', {subtype = 1, _pos = {20, 20, 5}}) end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return ctl.backlog end,
          pending = function(K, tpl) return ctl.pending end, state = function() return {phase = 'P1'} end})
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  if opts.setup then opts.setup(W, ctl) end
  job_list(opts.jobs and opts.jobs() or {})
  W.load(fresh('economy'))
  return W, ctl
end

local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function mat_for(W, kind, n) return select(2, W.K.call('economy', 'mat_for', kind, n)) end
local function why_for(W, kind, n) return select(3, W.K.call('economy', 'mat_for', kind, n)) end

T.test('census (Run 11): free doors, hatch covers, grates and blocks; built-in, forbidden and job items do not count',
       function()
  local W = world{setup = function(W)
    F.item(W, 'DOOR', {})
    F.item(W, 'DOOR', {flags = {in_building = true}})                   -- the door of a building
    F.item(W, 'DOOR', {flags = {in_job = true}})                        -- carried to a planned building
    F.item(W, 'DOOR', {flags = {forbid = true}})
    F.item(W, 'HATCH_COVER', {})
    F.item(W, 'GRATE', {})
    F.item(W, 'BLOCKS', {stack_size = 4})
    F.item(W, 'BLOCKS', {flags = {construction = true}})                -- built into a wall
  end}
  settle(W)
  local i = W.K.census.i
  T.eq({i.doors, i.hatches, i.grates, i.blocks_free}, {1, 1, 1, 4})
end)

T.test('Run 11: the seal\'s door waits, 1 boulder for 110 rock orders, 25 logs (below wood_min): the quickfort rock ' ..
       'door order is re-entered in wood at once', function()
  local W, ctl = world{boulders = 1, logs = 25, rock_orders = 110, door_order = true,
                       jobs = function() return {planned(1, 'DOOR')} end}
  days(W, 1)
  local om = W.find_acts('order_material')
  T.eq(#om, 1, 'old code: wood_orders keeps max(30, floor) logs and converts nothing (25 logs)')
  T.eq(om[1].args[1], ctl.door.id)
  T.eq(orders(W, 'dfllm:piece_door'), {}, 'the converted order makes the door: no second order')
  T.eq(W.find_events('MATERIAL_SHORT'), {})
  T.eq(mat_for(W, 'door', 1), 'wood', 'economy.mat_for: logs make a door')
end)

T.test('Run 11: a planned door without any order gets one in wood (no free stone), hatch and grate alike', function()
  local W = world{boulders = 0, logs = 12, jobs = function()
    return {planned(1, 'DOOR', 1, 20), planned(2, 'HATCH_COVER', 1, 21), planned(3, 'GRATE', 2, 22)}
  end}
  days(W, 1)
  local d = orders(W, 'dfllm:piece_door')
  T.eq(#d, 1)
  T.eq({d[1].job, d[1].amount_total, d[1].material_category}, {'ConstructDoor', 1, {'wood'}})
  T.eq(d[1].item_conditions[1].item_type, 'WOOD')
  T.eq(d[1].item_conditions[1].value, 1, 'a defense piece keeps only the moods\' wood floor (none here)')
  T.eq(orders(W, 'dfllm:piece_hatch')[1].job, 'ConstructHatchCover')
  T.eq(orders(W, 'dfllm:piece_grate')[1].amount_total, 2)
  days(W, 2)
  T.eq(#orders(W, 'dfllm:piece_door'), 1, 'the open order covers it: never twice')
end)

T.test('Run 11: rock free and no rock orders waiting: the door is ordered in stone at the mason\'s', function()
  local W = world{boulders = 30, logs = 0, jobs = function() return {planned(1, 'DOOR')} end}
  days(W, 1)
  local d = orders(W, 'dfllm:piece_door')
  T.eq(#d, 1)
  T.eq({d[1].material, d[1].material_category}, {'INORGANIC', nil})
end)

T.test('Run 11: no rock and no logs: MATERIAL_SHORT once ("no material for door: no rock, no logs"), economy.mat_for ' ..
       'says so', function()
  local W = world{boulders = 0, logs = 0, rock_orders = 110, door_order = true,
                  jobs = function() return {planned(1, 'DOOR'), planned(2, 'CABINET', 1, 21)} end}
  days(W, 1)
  local ev = W.find_events('MATERIAL_SHORT')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('no material for door, cabinet: no rock, no logs', 1, true) or
       ev[1].msg:find('no material for cabinet, door: no rock, no logs', 1, true), ev[1].msg)
  T.eq({ev[1].d.why, ev[1].d.rock, ev[1].d.logs, ev[1].d.n}, {{'no rock, no logs'}, 0, 0, 2})
  T.eq(mat_for(W, 'door', 1), nil)
  T.eq(why_for(W, 'door', 1), 'no material for door: no rock, no logs')
  T.eq(#W.find_acts('order_material'), 0, 'no logs: nothing to re-enter')
  days(W, 3)
  W.ms = W.ms + 600000
  days(W, 1)
  T.eq(#W.find_events('MATERIAL_SHORT'), 1, 'the same set: once (util/cadence)')
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(#r.data.short, 2)
  T.eq({r.data.stone.free, r.data.stone.need}, {0, 111})
end)

-- live y432 (34 boulders now, the refuge door 128,121,143 still open): the door item comes first (buildingplan waits for
-- a door, not for raw rock); 110 rock orders ahead of it, the quickfort door order long removed
local function econ_stone(W)            -- the boulders' stone is DF's economic stone (the stone use settings)
  local d0 = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(t, i)
    local m = d0(t, i)
    if m and t == 0 and i == 7 then m.inorganic = {metal_ore = {mat_index = {}}}; m.material.reaction_class = {} end
    return m
  end
  F.mat(W, 0, 7, {token = 'INORGANIC:MICROCLINE', flags = {ITEMS_HARD = true}})
  df.global.plotinfo.economic_stone = {[7] = 1}
end

T.test('live y432: 34 boulders behind 110 rock orders: the seal door is ordered in wood, without logs in stone (it ' ..
       'queues: MATERIAL_SHORT says so); economic stone is no stone', function()
  local function door_world(o)
    return world{boulders = 34, logs = o.logs, rock_orders = 110, setup = o.setup,
                 jobs = function() return {planned(1, 'DOOR', 1, 128)} end}
  end
  local W = door_world{logs = 6}
  days(W, 1)
  local d = orders(W, 'dfllm:piece_door')
  T.eq(#d, 1, 'old code: no order for a planned door at all')
  T.eq(d[1].material_category, {'wood'}, 'the carpenter is not behind the rock orders')
  T.eq(W.find_events('MATERIAL_SHORT'), {})
  local W2 = door_world{logs = 0}
  days(W2, 1)
  d = orders(W2, 'dfllm:piece_door')
  T.eq(#d, 1)
  T.eq(d[1].material, 'INORGANIC', 'stone is there: a stone door order')
  local ev = W2.find_events('MATERIAL_SHORT')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('stone queued for door: behind the other rock orders, no logs', 1, true), ev[1].msg)
  T.ok(ev[1].msg:find('34 free boulders, 110 in rock orders', 1, true), ev[1].msg)
  T.eq(mat_for(W2, 'door', 1), 'rock', 'economy.mat_for: stone can make it (the runner places it again)')
  days(W2, 2)
  T.eq(#orders(W2, 'dfllm:piece_door'), 1, 'its own order counts: never twice')
  local W3 = door_world{logs = 0, setup = econ_stone}
  days(W3, 1)
  T.eq(orders(W3, 'dfllm:piece_door'), {})
  ev = W3.find_events('MATERIAL_SHORT')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('no material for door: no rock, no logs', 1, true), ev[1].msg)
  T.ok(ev[1].msg:find('34 boulders are ore, flux, economic or soft stone', 1, true), ev[1].msg)
  T.eq({ev[1].d.rock, ev[1].d.boulders}, {0, 34})
end)

T.test('Run 11: walls wait for building material, only logs in the fort, buildingplan logs off: switched on once', function()
  local W = world{boulders = 0, logs = 10, bp = {blocks = true, boulders = true, logs = false, bars = false},
                  jobs = function() return {planned(1, 'BM', 3)} end}
  days(W, 1)
  local runs = F.runs(W)
  T.ok(F.has(runs, 'buildingplan set logs true'), table.concat(runs, ' | '))
  T.eq(F.bad_runs(W), {}, 'allowlisted')
  days(W, 2)
  local n = 0
  for _, l in ipairs(F.runs(W)) do if l == 'buildingplan set logs true' then n = n + 1 end end
  T.eq(n, 1, 'once a boot')
  T.eq(W.find_events('MATERIAL_SHORT'), {})
  local W2 = world{boulders = 0, logs = 0, jobs = function() return {planned(1, 'BM', 2)} end}
  days(W2, 1)
  local ev = W2.find_events('MATERIAL_SHORT')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('no material for wall: no rock, no blocks, no logs', 1, true), ev[1].msg)
  T.eq(mat_for(W2, 'wall', 1), nil)
  -- Run 11 siege 3: the trade depot rebuilt by the runner's keeper waits for its 3 building materials alike
  local W3 = world{boulders = 0, logs = 0, jobs = function() return {planned(1, 'BM', 3, 60, 'TradeDepot')} end}
  days(W3, 1)
  ev = W3.find_events('MATERIAL_SHORT')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('no material for depot: no rock, no blocks, no logs (depot x3 wait)', 1, true), ev[1].msg)
  T.eq(why_for(W3, 'depot', 3), 'no material for depot: no rock, no blocks, no logs')
  local W4 = world{boulders = 0, logs = 3, bp = {blocks = true, boulders = true, logs = false, bars = false},
                   jobs = function() return {planned(1, 'BM', 3, 60, 'TradeDepot')} end}
  days(W4, 1)
  T.ok(F.has(F.runs(W4), 'buildingplan set logs true'))
end)

T.test('Run 11: a "Needs rock" cancel while no stone is free: the order goes to wood at once, or is removed without ' ..
       'logs (not after needs_drop cancels)', function()
  local W, ctl = world{boulders = 0, logs = 10, door_order = true}
  settle(W)
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mason cancels Construct rock Door: Needs rock.'})
  settle(W)
  local om = W.find_acts('order_material')
  T.eq(#om, 1, 'old code: counted, removed only after 10 cancels')
  T.eq(om[1].args[1], ctl.door.id)
  local W2, ctl2 = world{boulders = 0, logs = 0, door_order = true}
  settle(W2)
  W2.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mason cancels Construct rock Door: Needs rock.'})
  settle(W2)
  local rm = W2.find_acts('order_remove')
  T.eq(#rm, 1)
  T.eq(rm[1].args[1], ctl2.door.id)
  local st = W2.find_events('ORDER_STUCK')
  T.eq(#st, 1)
  T.eq({st[1].d.dropped, st[1].d.why:sub(1, 8)}, {1, 'no rock:'})
  -- Run 11 itself: 1 boulder for 110 rock orders and a door order: the door goes to wood on its cancel
  local W4, ctl4 = world{boulders = 1, logs = 10, rock_orders = 110, door_order = true}
  settle(W4)
  W4.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mason cancels Construct rock Door: Needs rock.'})
  settle(W4)
  T.eq(#W4.find_acts('order_material'), 1)
  T.eq(W4.find_acts('order_material')[1].args[1], ctl4.door.id)
  -- the cancel loop of rock jobs: no `orders recheck` while the stone is short (it would post them again)
  for _ = 1, 6 do
    W2.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McY, Mason cancels Construct rock Table: Needs rock.'})
  end
  settle(W2)
  local cl = W2.find_events('CANCEL_LOOP')
  T.eq(#cl, 1)
  T.ok(cl[1].msg:find('no recheck', 1, true), cl[1].msg)
  T.eq(W2.find_acts('orders'), {}, 'old code: orders recheck')
  local W3 = world{boulders = 5, logs = 0, door_order = true}
  settle(W3)
  W3.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McX, Mason cancels Construct rock Door: Needs rock.'})
  settle(W3)
  T.eq(#W3.find_acts('order_remove') + #W3.find_acts('order_material'), 0, 'free stone: the old counting stands')
end)

T.test('Run 11: rock below the rock orders\' need, a pick, the miners without digging: PROJECT_REQUEST bedrooms why=rock ' ..
       'once a week, not while a dig waits', function()
  local W, ctl = world{boulders = 1, logs = 0, rock_orders = 40, picks = 2}
  local function reqs()
    local r = {}
    for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'rock' then r[#r + 1] = e end end
    return r
  end
  days(W, 1)
  local rq = reqs()
  T.eq(#rq, 1)
  T.eq({rq[1].d.tpl, rq[1].d.n, rq[1].d.short}, {'bedrooms', 4, 39})
  T.ok(rq[1].msg:find('1 free boulders < 40 wanted', 1, true), rq[1].msg)
  days(W, 3)
  T.eq(#reqs(), 1, 'request_days')
  ctl.pending = 1                                    -- follow placed it
  days(W, 6)
  T.eq(#reqs(), 1, 'not while a bedrooms project is pending')
  ctl.pending, ctl.backlog = 0, 30
  days(W, 2)
  T.eq(#reqs(), 1, 'not while the runner has dig tiles')
  ctl.backlog = 0
  days(W, 1)
  T.eq(#reqs(), 2)
  local s = W.state().stock
  T.eq({s.rock, s.rock_need}, {1, 40})
  local W2 = world{boulders = 1, rock_orders = 40, picks = 0}
  days(W2, 1)
  T.eq(#W2.find_events('PROJECT_REQUEST'), 0, 'no pick: nobody could dig it')
end)

-- the Miners detail (economy's tool details: its demand is the dig backlog's, at least `min` 2) for the picks tests
local function pick_world(opts)
  return world{picks = opts.picks, bars = opts.bars, shops = opts.shops, logs = 0, setup = function(W, ctl)
    df.unit_labor = {MINE = 1, [1] = 'MINE'}
    local wd = {name = 'Miners', assigned_units = kmock.vec{}, flags = {mode = 3},
                allowed_labors = setmetatable({[1] = true}, {__len = function() return 12 end})}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{wd}}
    W.act_result('work_detail', function() return true end)
    if opts.fuel then F.item(W, 'BAR', {mat_type = 7, mat_index = 0}) end
  end}
end

-- BUG-309: the mood stock's leather is a trade want too (none in these forts); the pick tests read the rest
local function wants(W)
  local out = {}
  for _, e in ipairs(select(2, W.K.call('economy', 'trade_wants'))) do if e.buy ~= 'leather' then out[#out + 1] = e end end
  return out
end

T.test('Run 11: picks below the Miners\' demand, an iron bar, a forge and fuel: one pick is forged', function()
  local W = pick_world{picks = 1, bars = {IRON = 1}, fuel = true, shops = {'MetalsmithsForge'}}
  days(W, 2)
  local o = orders(W, 'dfllm:pick')
  T.eq(#o, 1)
  T.eq({o[1].job, o[1].item_subtype, o[1].material, o[1].amount_total}, {'MakeWeapon', 'ITEM_WEAPON_PICK',
                                                                          'INORGANIC:IRON', 1})
  T.eq(wants(W), {}, 'the forge makes it: no trade want')
  local s = W.state().stock
  T.eq({s.picks, s.pick_want}, {1, 2})
end)

T.test('Run 11: picks short and no bar: economy.trade_wants asks the caravans for picks; enough picks: nothing', function()
  local W = pick_world{picks = 1, shops = {'MetalsmithsForge'}}
  days(W, 2)
  T.eq(orders(W, 'dfllm:pick'), {})
  local tw = wants(W)
  T.eq({#tw, tw[1].buy, tw[1].n}, {1, 'pick', 1})
  T.ok(tw[1].why:find('1 picks < 2', 1, true), tw[1].why)
  local W2 = pick_world{picks = 3}
  days(W2, 2)
  T.eq(wants(W2), {})
end)

T.done()
