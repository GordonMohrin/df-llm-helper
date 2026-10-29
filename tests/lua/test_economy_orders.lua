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
              'BrewDrink', 'ConstructBuilding', 'MakeBarrel', 'Rest'}

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

T.test('FR-01: the check is sliced (50 orders a frame); BUG-225: 55 orders with the same missing input are one ' ..
       'ORDER_STUCK with n 55 (old: report_per_day events a day, one per order)', function()
  local W = world{setup = function(W)
    for _ = 1, 55 do
      F.order(W, {job_type = df.job_type.PrepareMeal, amount_left = 1, material_category = {}, mat_type = -1})
    end
    F.workshop(W, 'Kitchen')       -- BUG-205: a missing kitchen is one event for all; here nothing to cook (input)
  end}
  days(W, 4)
  T.eq(W.state().orders.n, 55)
  T.eq(W.state().orders.stuck, 55)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1, 'live i3: 3 a day, one per order')
  T.eq({ev[1].d.kind, ev[1].d.n, ev[1].d.order}, {'input', 55, 1})
  T.ok(ev[1].msg:find('55 order(s) cannot run for', 1, true) and ev[1].msg:find('(order 1 PrepareMeal, 2, 3, ...)', 1, true),
       ev[1].msg)
  days(W, 1)
  T.eq(#W.find_events('ORDER_STUCK'), 1, 'no news: quiet')
  for _ = 1, 60 do F.order(W, {job_type = df.job_type.PrepareMeal, amount_left = 1, _name = string.rep('x', 40)}) end
  local r = W.inbox('inspect', {what = 'orders'})
  T.ok(#require('dfllm.util.json').encode(r.data) <= 8192, 'within the 8 KB reply')
  T.eq(#r.data.list + r.data.more, r.data.n)
  T.ok(r.data.more > 0)
  T.ok(r.data.list[1].why ~= nil, 'stuck orders first')
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

-- Run 11 (Kilrudrabed y434): the manager (hf 5443) rested with a wound; ConstructCoffin wood x25 and four ConstructDoor
-- wood orders stayed unvalidated while ORDER_STUCK named their material. Unvalidated + no manager available is the
-- reason now, and after orders.manager_days DECISION_NEEDED manager_absent asks for an acting manager.
local function manager(W, hf_unit)
  local vec = kmock.vec
  df.global.plotinfo.main = {fortress_entity = {positions = {
    own = vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
    assignments = vec{{id = 1, position_id = 3, histfig = 5443, histfig2 = 5443}}}}}
  local u = W.unit(hf_unit)
  u.hist_figure_id = 5443
  u._m.name = 'Ber Ostukdakost, Manager'
  return u
end

T.test('Run 11: an unvalidated order while the manager rests injured says so (ORDER_STUCK), then DECISION_NEEDED '
       .. 'manager_absent; a recovered manager ends it', function()
  local W = world{masons = false, setup = function(W)
    F.workshop(W, 'Carpenters')
    for _ = 1, 40 do F.item(W, 'WOOD', {}) end
    F.order(W, {job_type = df.job_type.ConstructCoffin, mat_type = -1, mat_index = -1, amount_left = 25,
                material_category = {wood = true}, status = {validated = false}, _name = 'Construct wooden coffin'})
    F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = 0, mat_index = -1, amount_left = 4,
                material_category = {}, status = {validated = false}, _name = 'Construct rock door'})  -- no rock either
    F.order(W, {job_type = df.job_type.ConstructTable, mat_type = -1, mat_index = -1, amount_left = 2,
                material_category = {wood = true}, status = {validated = true}})
  end}
  local mg = manager(W, 2)
  mg.job.current_job = {id = 902, job_type = df.job_type.Rest}
  days(W, 2)
  T.eq(#W.find_events('DECISION_NEEDED'), 0, 'not before manager_days')
  days(W, 2)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 2, 'both unvalidated orders, the validated wooden table runs')
  for _, e in ipairs(ev) do
    T.eq(e.d.why, 'unvalidated: no manager available (manager Ber resting/injured)', 'instead of no rock/no Masons')
  end
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1)
  T.eq(dn[1].d.id, 'manager_absent')
  T.ok(dn[1].msg:find('ConstructCoffin x25', 1, true) and dn[1].msg:find('2 orders not validated', 1, true), dn[1].msg)
  T.ok(dn[1].d.q:find('acting manager', 1, true), dn[1].d.q)
  local r = W.inbox('inspect', {what = 'orders'})
  T.eq(r.data.list[1].why, 'unvalidated: no manager available (manager Ber resting/injured)')
  days(W, 8)
  T.eq(#W.find_events('DECISION_NEEDED'), 1, 'once per manager and reason (util/cadence)')
  -- the manager is up again and validates: no reason, the episode ends
  mg.job.current_job = {id = 903}
  for _, o in ipairs(df.global.world.manager_orders.all) do o.status = {validated = true} end
  days(W, 1)
  local again = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('manager orders validated again (Ber)', 1, true) then again = true end end
  T.ok(again, 'the end is logged')
  -- a gone manager (dead) is no manager either
  W.kill(2)
  F.order(W, {job_type = df.job_type.ConstructCoffin, mat_type = -1, mat_index = -1, amount_left = 3,
              material_category = {wood = true}, status = {validated = false}})
  days(W, 4)
  local st = W.find_events('ORDER_STUCK')
  T.eq(st[#st].d.why, 'unvalidated: no manager available (the manager is gone)')
end)

-- BUG-042: an order unvalidated past orders.unval_days with an available manager is held by the validation, not by its
-- material: the reason names why the manager validates nothing (here: he has no office zone)
T.test('Run 11/BUG-042: an unvalidated order with an available manager names why he validates nothing', function()
  local W = world{masons = false, setup = function(W)
    F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = 0, mat_index = -1, amount_left = 4,
                material_category = {}, status = {validated = false}})
  end}
  manager(W, 2)
  days(W, 4)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1)
  T.eq(ev[1].d.why, 'unvalidated: the manager has no office zone')
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1)
  T.eq(dn[1].d.id, 'manager_office', 'none validated with a manager at hand: the office question as before')
  T.ok(dn[1].d.q:find('Office zone with a chair and a table', 1, true), dn[1].d.q)
end)

-- BUG-059 (Run 14 y577): "no Farmers" for ProcessPlants meant that no Farmer's Workshop stood, not that no dwarf may
-- farm; the game session chased work details for hours. The workshop is named as one, the state and the event tell a
-- missing mandatory workshop from a missing worker.
T.test('BUG-205 (live Earthboat: ORDER_STUCK x45 in 2 months, one per order of a missing shop): one event per missing ' ..
       'shop type with the count; again only with a new order after 7 days and 10 min', function()
  local W = world{setup = function(W)
    add_jobs({'ProcessPlants'})
    df.unit_labor.PROCESS_PLANT, df.unit_labor[7] = 7, 'PROCESS_PLANT'
    for _ = 1, 4 do
      F.order(W, {job_type = df.job_type.ProcessPlants, mat_type = -1, mat_index = -1, amount_left = 6,
                  material_category = {}, _name = 'Process plants'})
    end
  end}
  for i = 1, 6 do W.unit(i).status.labors = {[7] = true} end
  days(W, 4)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1, 'live: one per order')
  T.eq({ev[1].d.kind, ev[1].d.n}, {'workshop', 4})
  T.ok(ev[1].msg:find("4 order(s) cannot run for", 1, true) and ev[1].msg:find("no Farmer's Workshop", 1, true), ev[1].msg)
  days(W, 10)
  T.eq(#W.find_events('ORDER_STUCK'), 1, 'no news: quiet')
  F.order(W, {job_type = df.job_type.ProcessPlants, mat_type = -1, mat_index = -1, amount_left = 2,
              material_category = {}, _name = 'Process plants'})
  days(W, 5)
  T.eq(#W.find_events('ORDER_STUCK'), 1, 'a new order: the wall clock (10 min) holds it')
  W.ms = W.ms + 700 * 1000
  days(W, 1)
  local ev2 = W.find_events('ORDER_STUCK')
  T.eq(#ev2, 2)
  T.eq(ev2[2].d.n, 5)
end)

T.test('BUG-225 (live i3: 12x "no bars:INORGANIC:IRON" in a month): kind worker and input are one ORDER_STUCK per ' ..
       'kind and reason with n and sample ids; a lone order keeps its old text; news again after 7 days and 10 min', function()
  local W = world{setup = function(W)
    add_jobs({'ProcessPlants'})
    df.unit_labor.PROCESS_PLANT, df.unit_labor[7] = 7, 'PROCESS_PLANT'
    for _ = 1, 4 do
      F.order(W, {job_type = df.job_type.ProcessPlants, mat_type = -1, mat_index = -1, amount_left = 6,
                  material_category = {}, _name = 'Process plants'})
    end
    F.workshop(W, 'Farmers')
    F.workshop(W, 'Kitchen')
    F.order(W, {job_type = df.job_type.PrepareMeal, amount_left = 1, material_category = {}, mat_type = -1})
  end}
  for i = 1, 6 do W.unit(i).status.labors = {[4] = true, [7] = false} end
  days(W, 4)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 2, 'old: 5 events, one per order')
  local by = {}
  for _, e in ipairs(ev) do by[e.d.kind] = e end
  T.eq({by.worker.d.n, by.worker.d.order}, {4, 1})
  T.ok(by.worker.msg:find('4 order(s) cannot run for', 1, true)
       and by.worker.msg:find('(order 1 ProcessPlants, 2, 3, ...)', 1, true), by.worker.msg)
  T.ok(by.worker.d.why:find('no worker PROCESS_PLANT', 1, true), by.worker.d.why)
  T.eq(by.input.d.n, 1)
  T.ok(by.input.msg:find('^order 5 PrepareMeal cannot run for %d+ days: '), by.input.msg)
  days(W, 10)
  T.eq(#W.find_events('ORDER_STUCK'), 2, 'no news: quiet')
  F.order(W, {job_type = df.job_type.ProcessPlants, mat_type = -1, mat_index = -1, amount_left = 2,
              material_category = {}, _name = 'Process plants'})
  days(W, 4)
  T.eq(#W.find_events('ORDER_STUCK'), 2, 'a new order: the wall clock (10 min) holds it')
  W.ms = W.ms + 700 * 1000
  days(W, 1)
  local ev2 = W.find_events('ORDER_STUCK')
  T.eq(#ev2, 3)
  T.eq({ev2[3].d.kind, ev2[3].d.n}, {'worker', 5})
end)

T.test("BUG-059: a missing Farmer's Workshop is told as a workshop (kind workshop), not as 'no Farmers'; a missing worker apart",
       function()
  local function run(with_shop, with_labor)
    local W = world{setup = function(W)
      add_jobs({'ProcessPlants'})
      df.unit_labor.PROCESS_PLANT, df.unit_labor[7] = 7, 'PROCESS_PLANT'
      F.order(W, {job_type = df.job_type.ProcessPlants, mat_type = -1, mat_index = -1, amount_left = 6,
                  material_category = {}, _name = 'Process plants'})
      if with_shop then F.workshop(W, 'Farmers') end
    end}
    for i = 1, 6 do W.unit(i).status.labors = {[7] = with_labor} end
    days(W, 4)
    return W
  end
  local W = run(false, true)
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1)
  T.ok(ev[1].d.why:find("no Farmer's Workshop", 1, true), ev[1].d.why)
  T.ok(not ev[1].d.why:find('no Farmers', 1, true), ev[1].d.why)
  T.eq(ev[1].d.kind, 'workshop')
  local od = W.state().orders
  T.eq({od.stuck, od.stuck_ws, od.ws, od.stuck_lab}, {1, 1, "Farmer's Workshop x1", nil})
  local r = W.inbox('inspect', {what = 'orders'})
  T.eq(r.data.list[1].kind, 'workshop')
  local W2 = run(true, false)
  local ev2 = W2.find_events('ORDER_STUCK')
  T.eq(#ev2, 1)
  T.ok(ev2[1].d.why:find('no worker PROCESS_PLANT', 1, true), ev2[1].d.why)
  T.eq(ev2[1].d.kind, 'worker')
  local od2 = W2.state().orders
  T.eq({od2.stuck, od2.stuck_ws, od2.ws, od2.stuck_lab}, {1, nil, nil, 1})
end)

T.done()
