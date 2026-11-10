-- BUG-629 (Run 16a i1 Basementflew y459: food 2,000+ days, 2,398 cook ingredients, the kitchen built, COOK held, meals 0 for 14 million ticks and ONE
-- dfllm:food order in the whole log; Run 16b i2 Valleyhame y377: 'kitchen has 4 cook ingredients and 0 meals', 13 hungry, food 0 days, the meal order
-- waited for 10 ingredients): the cook floor drops to the 2 ingredients of one meal when a citizen is hungry or food is below the pre-alarm line, a
-- stalled food order is taken down and made again without an item condition, a COOK labor on nobody is switched on.
-- BUG-630 (Valleyhame y376-y383: a depot, a caravan, 'nothing_to_sell', no Craftsdwarf's workshop): the shop is asked for (workshops why=trade).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- opts: cit, kitchen (default true), growth (cook-only plant growths, stack), helmets (plump helmet plants: food that no cook may use),
-- hungry (the first n citizens past the hunger line), cook_holders (units holding the COOK labor), plants (more plump helmets: food days)
local function world(o)
  o = o or {}
  local cit = o.cit or 12
  local units, ids = {}, {}
  for i = 1, cit do units[i] = {id = i, citizen = true}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, cit do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.unit_labor = {COOK = 5, [5] = 'COOK', PLANT = 1, [1] = 'PLANT'}
  df.job_skill = df.job_skill or {}
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 53, {token = 'PLANT:PEACH:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  if o.plants then F.item(W, 'PLANT', {stack_size = o.plants, mat_type = 419, mat_index = 50}) end   -- plump helmets: food days, no cook may use them
  if o.kitchen ~= false then F.workshop(W, 'Kitchen') end
  if (o.growth or 0) > 0 then F.item(W, 'PLANT_GROWTH', {stack_size = o.growth, mat_type = 419, mat_index = 53}) end
  if (o.helmets or 0) > 0 then F.item(W, 'PLANT', {stack_size = o.helmets, mat_type = 419, mat_index = 50}) end
  for i = 1, cit do
    W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = i <= (o.hungry or 0) and 60000 or 1000}
  end
  W.load(fresh('economy'))
  for i = 1, cit do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
    u.military = {squad_id = -1}
  end
  for _, id in ipairs(o.cook_holders or {}) do W.unit(id).status.labors[5] = true end
  return W
end
local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function stalls(W)
  local n = 0
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('cooking stalled', 1, true) then n = n + 1 end end
  return n
end
local function floor_of(o)
  for _, x in ipairs(o.item_conditions or {}) do
    for _, f in ipairs(x.flags or {}) do if f == 'cookable' then return x.value end end
  end
end

T.test('BUG-629 Valleyhame: 4 cook ingredients, 5 hungry, food short: the meal order is made at the floor of one meal (2), not 10', function()
  local W = world{cit = 12, growth = 4, hungry = 5}
  days(W, 2)
  local o = orders(W, 'dfllm:food')
  T.ok(#o >= 1, 'a meal order although only 4 ingredients lie there')
  T.eq(floor_of(o[1]), 2, 'the DF item condition waits for 2, not 10')
  T.eq(W.K.census.i.cook_in, 4)
end)

T.test('BUG-629: nobody hungry and plenty of food: the floor of 10 stays (no order for a handful, the order carries 10)', function()
  local W = world{cit = 12, growth = 4, plants = 3000}
  days(W, 2)
  T.eq(#orders(W, 'dfllm:food'), 0, 'a handful of ingredients and a well fed fort: no job per handful')
  local W2 = world{cit = 12, growth = 40, plants = 3000}
  days(W2, 2)
  local o = orders(W2, 'dfllm:food')
  T.ok(#o >= 1, '40 ingredients: ordered')
  T.eq(floor_of(o[1]), 10, 'the config floor')
end)

T.test('BUG-629 Valleyhame: 4 ingredients and a food stock below the pre-alarm line (nobody counted hungry yet): floor 2 too', function()
  local W = world{cit = 12, growth = 4, plants = 1}
  days(W, 2)
  local o = orders(W, 'dfllm:food')
  T.ok(#o >= 1, 'ordered')
  T.eq(floor_of(o[1]), 2)
end)

T.test('BUG-629 Basementflew: 400 ingredients, 2,000 food days, the order never moves, meals 0: after 6 days it is taken down and made again with no condition', function()
  local W = world{cit = 20, growth = 400, helmets = 300, hungry = 1, cook_holders = {1}}
  days(W, 2)
  local first = orders(W, 'dfllm:food')
  T.eq(#first, 1, 'the one order of the live log')
  T.ok(floor_of(first[1]) ~= nil, 'with its item condition')
  local oid = W.K.state and nil
  days(W, 5)
  T.eq(#orders(W, 'dfllm:food'), 1, 'five days: the order is waited for')
  days(W, 3)
  local all = orders(W, 'dfllm:food')
  T.eq(#all, 2, 'stalled 6 days: a second order')
  T.eq(all[2].item_conditions, nil, 'without any item condition')
  T.eq(all[2].top, true, 'at the top of the manager list')
  local removed = W.find_acts('order_remove')
  T.eq(#removed, 1, 'the stalled one was taken down')
  local ev = W.find_events('ORDER_STUCK')
  T.ok(#ev >= 1 and ev[#ev].d.job == 'PrepareMeal', 'ORDER_STUCK PrepareMeal')
  T.ok(ev[#ev].msg:find('cooking stalled 6 days', 1, true), ev[#ev].msg)
  T.eq(ev[#ev].d.dropped, 1)
end)

T.test('BUG-629: an order that moves (amount left falls) is no stall', function()
  local W = world{cit = 20, growth = 400, helmets = 300, cook_holders = {1}}
  days(W, 2)
  local mo = df.global.world.manager_orders
  local tagged
  for _, o in ipairs(mo.all) do if o._spec and o._spec.tag == 'dfllm:food' then tagged = o end end
  T.ok(tagged, 'the order stands')
  for _ = 1, 10 do
    tagged.amount_left = math.max(1, tagged.amount_left - 1)
    tagged.amount_total = tagged.amount_left + 5
    days(W, 1)
    if tagged.amount_left == 1 then tagged.amount_left = 9 end
  end
  T.eq(#orders(W, 'dfllm:food'), 1, 'never made again while the cooks work')
  T.eq(#W.find_acts('order_remove'), 0)
end)

T.test('BUG-629: no kitchen, or meals at hand: no watch', function()
  local W = world{cit = 20, growth = 400, helmets = 300, kitchen = false}
  days(W, 10)
  T.eq(#W.find_acts('order_remove'), 0)
  T.eq(stalls(W), 0)
  local W2 = world{cit = 20, growth = 400, helmets = 300}
  F.item(W2, 'FOOD', {stack_size = 5, subtype = 1})
  days(W2, 10)
  T.eq(#W2.find_acts('order_remove'), 0, 'a meal stands: cooking works')
  T.eq(stalls(W2), 0)
end)

T.test('BUG-629: the COOK labor on nobody is switched on for an idle citizen at the stall (act.labor_set cook)', function()
  local W = world{cit = 10, growth = 400, helmets = 300, hungry = 1}
  W.unit(3).job = nil
  local sets = {}
  W.act_result('labor_set', function(id, which, on) sets[#sets + 1] = {id, which, on}; return true, 'enabled' end)
  days(W, 10)
  T.eq(sets[1], {3, 'cook', true}, 'the idle citizen')
  local ev = W.find_events('ORDER_STUCK')
  T.ok(#ev >= 1 and ev[#ev].d.kind == 'worker', 'ORDER_STUCK kind worker')
  local l
  for _, g in ipairs(W.logs) do if tostring(g.msg):find('Cooking labor on for unit 3', 1, true) then l = g end end
  T.ok(l, 'kern.log says it')
end)

T.test('BUG-629: the food decision says the kitchen is idle, not "raw food is not cooked", after the watch made the order again', function()
  local W = world{cit = 12, growth = 400, hungry = 4, cook_holders = {1}}
  days(W, 10)
  local d
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'food_low' or e.d.id == 'famine' then d = e end end
  if d then T.ok(not d.msg:find('raw food is not cooked', 1, true), d.msg) end
  local ev = W.find_events('ORDER_STUCK')
  T.ok(#ev >= 1, 'the stall is told')
end)

T.test('BUG-630 Valleyhame: a depot, crafts to sell, fewer than 30 and no Craftsdwarf workshop: workshops why=trade types Craftsdwarfs, once per request_days', function()
  local W = world{cit = 12, plants = 3000}
  W.load({name = 'trade', every = {ticks = 1200}, sells = function() return {'crafts'} end})
  F.building(W, 'TRADE_DEPOT', {getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end})
  days(W, 3)
  local req
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'trade' then req = e end end
  T.ok(req, 'PROJECT_REQUEST why=trade')
  T.eq(req.d.types, {'Craftsdwarfs'})
  T.eq(req.d.tpl, 'workshops')
  local n = 0
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'trade' then n = n + 1 end end
  T.eq(n, 1, 'asked once within the pacing')
end)

T.test('BUG-630: an empty sell list sells whatever lies at the depot, crafts too: the shop is asked for; no depot or the shop standing: no request', function()
  local W = world{cit = 12, plants = 3000}
  W.load({name = 'trade', every = {ticks = 1200}, sells = function() return {} end})
  F.building(W, 'TRADE_DEPOT', {getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end})
  days(W, 3)
  local n = 0
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'trade' then n = n + 1 end end
  T.eq(n, 1)
  local nodepot = world{cit = 12, plants = 3000}
  nodepot.load({name = 'trade', every = {ticks = 1200}, sells = function() return {'crafts'} end})
  days(nodepot, 3)
  for _, e in ipairs(nodepot.find_events('PROJECT_REQUEST')) do T.ok(e.d.why ~= 'trade', 'no depot: no craft shop request') end
  local shop = world{cit = 12, plants = 3000}
  F.workshop(shop, 'Craftsdwarfs')
  shop.load({name = 'trade', every = {ticks = 1200}, sells = function() return {'crafts'} end})
  F.building(shop, 'TRADE_DEPOT', {getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end})
  days(shop, 3)
  for _, e in ipairs(shop.find_events('PROJECT_REQUEST')) do T.ok(e.d.why ~= 'trade', 'the shop stands') end
end)

T.done()
