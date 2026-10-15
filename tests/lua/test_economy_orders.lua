-- economy + act: manager orders (FR-39 crash guard, FR-01 order sanity, FR-10 "Needs" pruner, order.add,
-- inspect orders).
local T = require('testlib')
local F = require('wp8_world')
local OL = require('dfllm.orderlib')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

-- job types the fakes of wp8_world do not name: appended so the existing indices stay
local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end
local JOBS = {'MakeArmor', 'MakePants', 'MakeShoes', 'MakeGloves', 'MakeHelm', 'MakeWeapon', 'MakeAmmo', 'MakeShield',
              'BrewDrink', 'ConstructBuilding', 'MakeBarrel'}

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 6 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  add_jobs(JOBS)
  df.unit_labor = {MASON = 1, CARPENTER = 2, BREWER = 3, COOK = 4, FORGE_ARMOR = 5, CLOTHESMAKER = 6, [1] = 'MASON',
                   [2] = 'CARPENTER', [3] = 'BREWER', [4] = 'COOK', [5] = 'FORGE_ARMOR', [6] = 'CLOTHESMAKER'}
  local ids = {}
  for i = 1, opts.cit or 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[1] = opts.masons ~= false, [2] = true, [3] = true, [4] = true}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  -- the real workorder tool stores the item def index (0 here) when the spec names one, -1 otherwise
  W.act_result('workorder', function(spec)
    local mo = df.global.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    mo.all:insert('#', {id = id, job_type = df.job_type[spec.job], reaction_name = spec.reaction or '',
                        amount_left = spec.amount_total, amount_total = spec.amount_total, _spec = spec,
                        item_subtype = spec.item_subtype and 0 or -1, mat_type = -1, mat_index = -1,
                        status = {validated = false}})
    return true, id
  end)
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end

local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function ids_of(W)
  local r = {}
  for _, o in ipairs(df.global.world.manager_orders.all) do r[#r + 1] = o.id end
  return r
end

T.test('orderlib: FR-39 unsafe = an item-definition job without a subtype', function()
  T.eq(OL.unsafe('MakeArmor', nil), true)
  T.eq(OL.unsafe('MakeArmor', -1), true)
  T.eq(OL.unsafe('MakePants', ''), true)
  T.eq(OL.unsafe('MakeArmor', 'ITEM_ARMOR_SHIRT'), false)
  T.eq(OL.unsafe('MakeShoes', 3), false)
  T.eq(OL.unsafe('BrewDrink', nil), false)
  T.eq(OL.unsafe('MakeShield', 'shield'), true, 'a lowercase word is no item def token')
  for _, j in ipairs({'MakeArmor', 'MakePants', 'MakeShoes', 'MakeGloves', 'MakeHelm', 'MakeWeapon', 'MakeAmmo',
                      'MakeShield'}) do T.ok(OL.SUBTYPE_JOBS[j], j) end
end)

T.test('orderlib: cancel reasons, Needs, material class, workshops, labors, input keys', function()
  T.eq({OL.cancel_parts('Urist McX, Mason cancels Construct Table: Needs rock.')}, {'Construct Table', 'Needs rock'})
  T.eq(OL.cancel_parts('no cancel here'), nil)
  T.ok(OL.needs('Needs empty barrel'))
  T.ok(not OL.needs('Interrupted'))
  T.eq(OL.mat_class({material_category = {wood = true}, mat_type = -1}), 'wood')
  T.eq(OL.mat_class({material_category = {}, mat_type = 0, mat_index = 5}, function() return true end), 'metal')
  T.eq(OL.mat_class({material_category = {}, mat_type = 0, mat_index = 5}, function() return false end), 'rock')
  T.eq(OL.mat_class({material_category = {}, mat_type = 0, mat_index = -1}), 'rock')
  T.eq(OL.mat_class({mat_type = 4}), 'glass')
  T.eq(OL.mat_class({mat_type = -1}), 'any')
  T.eq(OL.workshops('ConstructTable', 'rock'), {'workshop:Masons'})
  T.eq(OL.workshops('PrepareMeal', 'any'), {'workshop:Kitchen'})
  T.eq(OL.workshops('SomethingNew', 'any'), nil)
  T.eq(OL.labors('MakeArmor', 'metal', OL.workshops('MakeArmor', 'metal')), {'FORGE_ARMOR'})
  T.eq(OL.labors('MakeCrafts', 'bone', OL.workshops('MakeCrafts', 'bone')), {'BONE_CARVE'})
  T.eq(OL.input('ConstructTable', 'wood'), 'wood')
  T.eq(OL.input('MakeArmor', 'metal', 'INORGANIC:IRON'), 'bars:INORGANIC:IRON')
  T.eq(OL.input('SmeltOre', 'rock', 'INORGANIC:HEMATITE'), 'ore:INORGANIC:HEMATITE')
  T.eq(OL.input('BrewDrink', 'any'), nil)
end)

T.test('FR-39: act.workorder refuses make-item orders without item_subtype (the real act.lua)', function()
  local A = fresh('act')
  local fails, cmds = {}, {}
  _G.dfhack = _G.dfhack or {}
  local old = dfhack.run_command_silent
  dfhack.run_command_silent = function(...) cmds[#cmds + 1] = {...}; return 'ok', 0 end
  local api = A.new{who = function() return 'economy' end, tick = function() return 0 end,
                    allowlist = function() return A.BUILTIN_ALLOWLIST end,
                    log_cmd = function() end, fail = function(fn, err) fails[#fails + 1] = fn .. ': ' .. err end}
  local ok, err = api.workorder({job = 'MakeArmor', material_category = {'cloth'}, amount_total = 10, tag = 'dfllm:x'})
  T.eq(ok, false)
  T.ok(tostring(err):find('item_subtype', 1, true), tostring(err))
  T.eq(#cmds, 0, 'nothing reached the workorder command')
  T.eq(#fails, 1, 'ACT_FAIL for the refusal')
  dfhack.run_command_silent = old
end)

T.test('FR-39: economy removes an unsafe order at once, ORDER_BAD (A) once, state orders.bad', function()
  local W = world{setup = function(W)
    F.order(W, {job_type = df.job_type.MakeArmor, item_subtype = -1, amount_left = 10, _name = 'Make cloth armor'})
    F.order(W, {job_type = df.job_type.MakePants, item_subtype = 2, amount_left = 4, _name = 'Make trousers'})
  end}
  settle(W)
  local bad = W.find_events('ORDER_BAD')
  T.eq(#bad, 1)
  T.eq({bad[1].d.order, bad[1].d.job, bad[1].d.dropped}, {1, 'MakeArmor', 1})
  T.eq(ids_of(W), {2}, 'the safe order stays')
  T.eq(W.state().orders.bad, 0)
  days(W, 2)
  T.eq(#W.find_events('ORDER_BAD'), 1, 'once per order')
end)

T.test('FR-39: drop=false only reports; doctor reads state orders.bad', function()
  local cfg = F.cfg()
  cfg.economy.order_guard = {drop = false, per_run = 4}
  local units = {{id = 1, citizen = true}}
  local W = F.world{cfg = {baseline = cfg}, units = units}
  add_jobs(JOBS)
  W.unit(1).job = {}
  W.set_census('u', F.census_u({1}))
  F.order(W, {job_type = df.job_type.MakeHelm, amount_left = 3})
  W.load(fresh('economy'))
  settle(W)
  T.eq(#W.find_acts('order_remove'), 0)
  T.eq(W.state().orders.bad, 1)
  T.eq(W.find_events('ORDER_BAD')[1].d.dropped, 0)
end)

T.test('order.add verb: refuses unsafe orders, adds safe ones through act.workorder', function()
  local W = world{}
  settle(W)
  local r = W.inbox('order.add', {job = 'MakeArmor', amount = 5, material_category = {'cloth'}})
  T.eq(r.ok, false)
  T.ok(r.msg:find('item_subtype', 1, true), r.msg)
  r = W.inbox('order.add', {job = 'NoSuchJob', amount = 1})
  T.eq(r.ok, false)
  r = W.inbox('order.add', {job = 'MakeArmor', amount = 5, item_subtype = 'ITEM_ARMOR_SHIRT', material_category = {'cloth'}})
  T.eq(r.ok, true, r.msg)
  local wo = W.find_acts('workorder')
  local spec = wo[#wo].args[1]
  T.eq({spec.job, spec.amount_total, spec.item_subtype, spec.tag, spec.material_category},
       {'MakeArmor', 5, 'ITEM_ARMOR_SHIRT', 'dfllm:cmd', {'cloth'}})
  T.eq(r.data.order, spec and df.global.world.manager_orders.all[#df.global.world.manager_orders.all - 1].id)
  days(W, 1)
  T.eq(#W.find_events('ORDER_BAD'), 0, 'the added order is safe')
end)

T.test('FR-01: an order without its workshop, input or worker is reported after stuck_days (ORDER_STUCK B)', function()
  local W = world{masons = false, setup = function(W)
    F.order(W, {job_type = df.job_type.ConstructTable, mat_type = 0, mat_index = -1, amount_left = 4,
                material_category = {}, _name = 'Construct rock table'})              -- no Masons, no worker
    F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = -1, mat_index = -1, amount_left = 2,
                material_category = {wood = true}, _name = 'Construct wooden door'})   -- workshop + wood
    F.workshop(W, 'Carpenters')
    for _ = 1, 5 do F.item(W, 'WOOD', {}) end
  end}
  days(W, 2)
  T.eq(#W.find_events('ORDER_STUCK'), 0, 'not before stuck_days')
  days(W, 2)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1)
  T.eq(ev[1].d.order, 1)
  T.ok(ev[1].d.why:find('no Masons', 1, true), ev[1].d.why)
  T.ok(ev[1].d.why:find('no rock', 1, true), ev[1].d.why)
  T.ok(ev[1].d.why:find('no worker MASON', 1, true), ev[1].d.why)
  T.eq(W.state().orders.stuck, 1)
  T.eq(W.state().orders.n, 2)
  local r = W.inbox('inspect', {what = 'orders'})
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.n, r.data.stuck, #r.data.list}, {2, 1, 2})
  T.eq(r.data.list[1].name, 'Construct rock table')
  T.ok(r.data.list[1].days >= 3)
  T.eq(r.data.list[2].why, nil, 'the wooden door can run')
  days(W, 3)
  T.eq(#W.find_events('ORDER_STUCK'), 1, 'reported once')
end)

T.test('FR-01: unreachable input counts as missing (snapshot.far)', function()
  local W = world{setup = function(W)
    W.load({name = 'snapshot', every = {ticks = 100}, far = function(K, x, y, z) return x == 99 end,
            tile = function(K, x, y, z) return {c = '.'} end, reach = function() return true end})
    F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = -1, mat_index = -1, amount_left = 2,
                material_category = {wood = true}})
    F.workshop(W, 'Carpenters')
    for _ = 1, 5 do F.item(W, 'WOOD', {_pos = {99, 1, 1}}) end                    -- in a cut-off cave
  end}
  days(W, 4)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1)
  T.eq(ev[1].d.why, 'no wood')
end)

T.test('FR-10: "Needs ..." cancels past needs_drop remove the order; supply orders are kept', function()
  local W = world{setup = function(W)
    F.order(W, {job_type = df.job_type.ConstructTable, amount_left = 6, _name = 'Engrave slab'})
    F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 6,
                _name = 'Brew drink'})
  end}
  settle(W)
  for _ = 1, 9 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'A cancels Engrave Slab: Needs slab.'}) end
  for _ = 1, 12 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'B cancels Brew Drink: Needs empty barrel.'}) end
  W.run(1)
  T.eq(#W.find_acts('order_remove'), 0, '9 < 10')
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'A cancels Engrave Slab: Needs slab.'})
  W.run(1)
  T.eq(#W.find_acts('order_remove'), 1)
  T.eq(ids_of(W), {2}, 'the brew order (supply) stays')
  local ev = W.find_events('ORDER_STUCK')
  T.eq({ev[1].d.order, ev[1].d.dropped, ev[1].d.n}, {1, 1, 10})
  T.ok(ev[1].d.why:find('Needs slab', 1, true))
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  T.eq(r.data.cancels[1], {why = 'Needs empty barrel', n = 12})
end)

T.done()
