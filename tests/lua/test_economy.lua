-- economy (WP8): item census, stock days, supply orders, staged imports, kitchen, cancel loops, labor, D-03.
local T = require('testlib')
local F = require('wp8_world')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg(), decisions = opts.decisions}, units = units, plan = opts.plan,
                    persist = opts.persist, mode = opts.mode}
  local ids = {}
  for i = 1, opts.cit or 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true}})
  F.mat(W, 419, 51, {token = 'PLANT:GRASS_TAIL_PIG:STRUCTURAL', flags = {}})
  F.mat(W, 419, 52, {token = 'PLANT:FEATHER:EGG', flags = {EDIBLE_COOKED = true}})   -- cook-only (live L1 yolks)
  F.mat(W, 37, 0, {token = 'CREATURE:CAMEL_2_HUMP:MUSCLE', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  for _ = 1, opts.barrels or 4 do F.item(W, 'BARREL', {}) end     -- empty: no dfllm:barrel order by default
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end

local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}) end end
local function count_acts(W, fn, arg1)
  local n = 0
  for _, a in ipairs(W.find_acts(fn)) do if arg1 == nil or a.args[1] == arg1 then n = n + 1 end end
  return n
end

T.test('config/baseline.json mirrors economy.DEFAULTS', function()
  T.eq(F.read_json('config/baseline.json').economy, fresh('economy').DEFAULTS)
end)

T.test('item census: categories, exclusions, forbidden drinks, materials', function()
  local W = world{setup = function(W)
    local barrel = {flags = {forbid = true}}
    F.item(W, 'DRINK', {stack_size = 5})
    F.item(W, 'DRINK', {stack_size = 5, flags = {forbid = true}})
    F.item(W, 'DRINK', {stack_size = 3, _cont = barrel})
    F.item(W, 'DRINK', {stack_size = 9, flags = {trader = true}})
    F.item(W, 'FOOD', {stack_size = 4, subtype = 1})
    F.item(W, 'FOOD', {stack_size = 4, subtype = 2})
    F.item(W, 'FOOD', {stack_size = 2, subtype = 1})
    F.item(W, 'FOOD', {stack_size = 7, subtype = 3, flags = {rotten = true}})
    F.item(W, 'MEAT', {stack_size = 3, mat_type = 37, mat_index = 0})
    F.item(W, 'PLANT_GROWTH', {stack_size = 5, mat_type = 419, mat_index = 52})   -- cookable, not food
    F.item(W, 'PLANT', {stack_size = 4, mat_type = 419, mat_index = 50})
    F.item(W, 'PLANT', {stack_size = 6, mat_type = 419, mat_index = 51})
    F.item(W, 'CLOTH', {}); F.item(W, 'CLOTH', {})
    F.item(W, 'SKIN_TANNED', {})
    F.item(W, 'CORPSEPIECE', {stack_size = 2, corpse_flags = {bone = true}})
    F.item(W, 'CORPSEPIECE', {corpse_flags = {shell = true}})
    F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true, unbutchered = true}})
    F.item(W, 'SMALLGEM', {}); F.item(W, 'ROUGH', {stack_size = 2})
    F.item(W, 'BAR', {mat_type = 0, mat_index = 8}); F.item(W, 'BAR', {mat_type = 0, mat_index = 9})
    F.item(W, 'BAR', {mat_type = 7}); F.item(W, 'BAR', {mat_type = 200})
    W.subdefs[3], W.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}, {id = 'ITEM_AMMO_ARROWS'}
    F.item(W, 'AMMO', {stack_size = 25, subtype = 3}); F.item(W, 'AMMO', {stack_size = 25, subtype = 4})
    for _ = 1, 3 do F.item(W, 'WOOD', {}) end
    for _ = 1, 5 do F.item(W, 'BOULDER', {}) end
    for _ = 1, 2 do F.item(W, 'BLOCKS', {}) end
    F.item(W, 'FIGURINE', {})
  end}
  W.run(1)
  local i = W.K.census.i
  T.ok(i, 'census published')
  T.eq({i.drink, i.drink_forb, i.food, i.meals, i.meal_kinds, i.cloth, i.leather, i.bone, i.shell, i.gems,
        i.bars, i.fuel, i.bolts, i.wood, i.boulders, i.blocks, i.crafts, i.cookable},
       {5, 8, 17, 10, 2, 2, 1, 2, 1, 3, 2, 1, 25, 3, 5, 2, 1, 5})
end)

T.test('famine: below famine_days -> hunting and fishing allowed once, DECISION_NEEDED famine weekly', function()
  local W = world{}
  days(W, 2)
  local function famines()
    local n = 0
    for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'famine' then n = n + 1 end end
    return n
  end
  T.eq(famines(), 1)
  local hunt = 0
  for _, a in ipairs(W.find_acts('run')) do
    if a.args[1] == 'labormanager' and (a.args[2] == 'allow-hunting' or a.args[2] == 'allow-fishing') then hunt = hunt + 1 end
  end
  T.eq(hunt, 2)
  days(W, 3)
  T.eq(famines(), 1, 'at most once a week')
  days(W, 5)
  T.eq(famines(), 2)
end)

T.test('census is sliced over frames (per_slice items)', function()
  local cfg = F.cfg()
  cfg.economy.per_slice = 3
  local units = {{id = 1, citizen = true}}
  local W = F.world{cfg = {baseline = cfg}, units = units}
  W.unit(1).job = {}
  W.set_census('u', F.census_u({1}))
  for _ = 1, 10 do F.item(W, 'DRINK', {}) end
  W.load(fresh('economy'))
  W.run(1)
  T.eq(W.K.census.i, nil, 'not done after one slice')
  W.run(2)
  T.eq(W.K.census.i, nil, '9 of 10 items after three slices')
  W.run(1)
  T.eq(W.K.census.i.drink, 10)
end)

T.test('stock-day math: seeded floor, observed decrease, spike cap', function()
  local E = fresh('economy')
  T.eq(E.sample(nil, 100, 530, 3), 530)
  T.eq(E.sample(100, 90, 530, 3), 1590)
  T.eq(E.sample(100, 99, 530, 3), 1000)
  T.eq(E.sample(90, 100, 530, 3), 530)
  T.eq(E.days(530, {530}), 1000)
  T.eq(E.days(0, {530, 530}), 0)
  T.eq(E.days(10, {}), 9999)
end)

T.test('STOCK_LOW on change only; supply order sized from the deficit, never duplicated', function()
  local W = world{setup = function(W) for _ = 1, 10 do F.item(W, 'DRINK', {stack_size = 5}) end end}
  W.run(1)
  local s = W.state()
  T.eq(s.stock.drink_d, 94)                       -- 50 drinks / (10 dwarves * 0.053)
  local low = W.find_events('STOCK_LOW')
  T.eq(#low, 2, 'drink and food')
  T.eq(low[1].d.key, 'drink_d')
  T.eq(low[1].d.min, 170)
  local wo = W.find_acts('workorder')
  T.eq(#wo, 2)
  local drink = wo[1].args[1]
  T.eq({drink.tag, drink.job, drink.reaction, drink.amount_total, drink.frequency},
       {'dfllm:drink', 'CustomReaction', 'BREW_DRINK_FROM_PLANT', 8, 'OneTime'})
  T.eq(wo[2].args[1].tag, 'dfllm:food')
  T.eq(wo[2].args[1].amount_total, 4)
  days(W, 2)
  T.eq(#W.find_events('STOCK_LOW'), 2, 'no repeat while still low')
  T.eq(#W.find_acts('workorder'), 2, 'orders still live')
  df.global.world.manager_orders.all[0].amount_left = 0          -- the drink order finished
  days(W, 1)
  T.eq(#W.find_acts('workorder'), 3)
  T.eq(W.find_acts('workorder')[3].args[1].tag, 'dfllm:drink')
  T.eq(F.bad_runs(W), {})
end)

T.test('empty barrels: below 4 a MakeBarrel order (live L1b: brewing stalled without one)', function()
  local W = world{barrels = 0, setup = function(W)
    F.item(W, 'BARREL', {_contents = {{id = 1}}})                  -- a full barrel does not count
    F.item(W, 'BARREL', {})
  end}
  W.run(1)
  T.eq(W.K.census.i.barrels_empty, 1)
  local b
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == 'dfllm:barrel' then b = a.args[1] end end
  T.ok(b, 'barrel order')
  T.eq({b.job, b.material_category, b.amount_total}, {'MakeBarrel', {'wood'}, 3})
  T.eq(F.bad_runs(W), {})
end)

T.test('a refused supply order is retried after 3 days, not daily', function()
  local W = world{setup = function(W) W.act_result('workorder', function() return false, 'bad json' end) end}
  W.run(1)
  local n1 = count_acts(W, 'workorder')
  T.eq(n1, 2, 'drink and food')
  days(W, 2)
  T.eq(count_acts(W, 'workorder'), n1)
  days(W, 2)
  T.eq(count_acts(W, 'workorder'), 2 * n1)
end)

T.test('stock recovers then drops again: a second STOCK_LOW', function()
  local W = world{setup = function(W) for _ = 1, 10 do F.item(W, 'DRINK', {stack_size = 5}) end end}
  W.run(1)
  local v = df.global.world.items.other.DRINK
  for i = 0, #v - 1 do v[i].stack_size = 200 end                -- 2,000 drinks: recovered
  days(W, 1)
  T.eq(#W.find_events('STOCK_LOW'), 2)
  for i = 0, #v - 1 do v[i].stack_size = 1 end
  days(W, 1)
  local lows = W.find_events('STOCK_LOW')
  T.eq(lows[#lows].d.key, 'drink_d')
  T.eq(#lows, 3)
end)

T.test('staged imports: migrants, mason, smelter, fuel, forge; each once, then sort+recheck', function()
  local W = world{cit = 7}
  days(W, 1)
  T.eq(count_acts(W, 'orders_import'), 0)
  W.event('REPORT', {type = 'MIGRANT_ARRIVAL', text = 'Some migrants have arrived.'})
  W.run(1)
  W.set_census('u', F.census_u({1, 2, 3, 4, 5, 6, 7, 11, 12, 13}))
  days(W, 1)
  T.eq(W.find_events('MIGRANTS')[1].d.n, 3)
  T.eq(count_acts(W, 'orders_import', 'library/basic'), 1)
  T.eq(count_acts(W, 'orders', 'sort'), 1)
  T.eq(count_acts(W, 'orders', 'recheck'), 1)
  F.building(W, 'WORKSHOP_ANY', {type = df.workshop_type.Masons})
  F.building(W, 'FURNACE_ANY', {type = df.furnace_type.Smelter})
  days(W, 1)
  T.eq(count_acts(W, 'orders_import', 'library/rockstock'), 1)
  T.eq(count_acts(W, 'orders_import', 'library/furnace'), 1)
  T.eq(count_acts(W, 'orders_import', 'library/smelting'), 0, 'no fuel yet')
  F.item(W, 'BAR', {mat_type = 7})
  F.building(W, 'WORKSHOP_ANY', {type = df.workshop_type.MetalsmithsForge})
  days(W, 3)
  T.eq(count_acts(W, 'orders_import', 'library/smelting'), 1)
  T.eq(count_acts(W, 'orders_import', 'library/military'), 1)
  T.eq(count_acts(W, 'orders_import'), 5, 'never twice')
  local ok, yes = W.K.call('economy', 'imported', 'library/military')
  T.ok(ok and yes)
  ok, yes = W.K.call('economy', 'imported', 'library/glassstock')
  T.ok(ok and not yes)
end)

T.test('a library whose signature order exists is not imported again (crash before persist flush)', function()
  local W = world{setup = function(W)
    F.order(W, {job_type = 0, reaction_name = 'BREW_DRINK_FROM_PLANT', mat_type = -1, mat_index = -1})
  end}
  days(W, 1)                                      -- 10 citizens: cit>=10 makes basic due
  T.eq(count_acts(W, 'orders_import'), 0)
  local ok, yes = W.K.call('economy', 'imported', 'library/basic')
  T.ok(ok and yes)
end)

T.test('plan.orders.import and season imports are honoured once', function()
  local plan = {v = 2, year = 3, phase_target = 'P3', policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
                seasons = {{build = {}, orders = {import = {'library/glassstock'}}}, {build = {}}, {build = {}}, {build = {}}},
                orders = {import = {'library/furnace'}}}
  local W = world{cit = 7, plan = plan}
  days(W, 2)
  T.eq(count_acts(W, 'orders_import', 'library/glassstock'), 1)
  T.eq(count_acts(W, 'orders_import', 'library/furnace'), 1)
  T.eq(count_acts(W, 'orders_import'), 2)
end)

T.test('kitchen: PLUMP_HELMET plant and seed cook exclusions added once; D-09 yes lifts them in a famine', function()
  local W = world{setup = function(W)
    F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
  end}
  T.eq(count_acts(W, 'kitchen_exclude'), 2, 'at init')
  local a, b = W.find_acts('kitchen_exclude')[1].args, W.find_acts('kitchen_exclude')[2].args
  T.eq({a[1], a[2], a[3], a[4], a[5]}, {'PLANT', -1, 419, 50, 'Cook'})
  T.eq({b[1], b[2], b[3], b[4], b[5]}, {'SEEDS', -1, 419, 60, 'Cook'})
  days(W, 2)
  T.eq(count_acts(W, 'kitchen_exclude'), 2, 'exists: not re-added')
  -- seedwatch (allowPlantSeedCookery) dropped the plant exclusion: baseline's re-check restores it
  table.remove(W.kitchen, 1)
  local ok, res = W.K.call('economy', 'kitchen_check')
  T.ok(ok and res)
  T.eq(count_acts(W, 'kitchen_exclude'), 3)
  T.eq(W.find_acts('kitchen_exclude')[3].args[1], 'PLANT')
  local W2 = world{decisions = {['D-09'] = 'yes'}}   -- no food at all: famine
  W2.kitchen = {}
  days(W2, 1)
  T.eq(#W2.kitchen, 0, 'not re-added during the famine')
end)

T.test('labor KPI: PEACE days with a parsed starving count feed baseline.labor_day', function()
  local got = {}
  local function setup(out)
    return function(W)
      W.load({name = 'baseline', every = {ticks = 33600}, labor_day = function(K, n) got[#got + 1] = n end})
      W.act_result('run', function(cmd, a1)
        if cmd == 'labormanager' and a1 == 'status' then return true, out end
        return true, ''
      end)
    end
  end
  local W = world{setup = setup('job board: 2 starving (> 1200 ticks)')}
  days(W, 2)
  T.eq(got, {2, 2})
  got = {}
  local W2 = world{mode = 'ALERT', setup = setup('job board: 2 starving (> 1200 ticks)')}
  days(W2, 2)
  T.eq(got, {}, 'not outside PEACE')
  local W3 = world{setup = setup('labormanager is not enabled')}
  days(W3, 2)
  T.eq(got, {}, 'no parse, no sample')
end)

T.test('cancel loop: CANCEL_LOOP once per job and day, suspend attempt, one recheck', function()
  local W = world{setup = function(W) F.order(W, {job_type = 0, _name = 'Brew drink', amount_left = 5}) end}
  W.run(1)
  for _ = 1, 7 do
    W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist McBrew, Brewer cancels Brew Drink: Needs empty barrel.'})
  end
  W.run(1)
  local ev = W.find_events('CANCEL_LOOP')
  T.eq(#ev, 1)
  T.eq({ev[1].d.job, ev[1].d.n, ev[1].d.order}, {'Brew Drink', 5, 1})
  T.eq(count_acts(W, 'order_suspend'), 1)
  local rech = count_acts(W, 'orders', 'recheck')
  W.run(1200, {skip = 100})                     -- next day: counting starts over
  for _ = 1, 5 do W.event('REPORT', {type = 'CANCEL_JOB', text = 'X cancels Brew Drink: Needs empty barrel.'}) end
  W.run(1)
  T.eq(#W.find_events('CANCEL_LOOP'), 2)
  T.eq(count_acts(W, 'orders', 'recheck'), rech + 1)
  T.eq(fresh('economy').cancelled_job('A cancels Store Item in Stockpile: Interrupted.'), 'Store Item in Stockpile')
  T.eq(fresh('economy').cancelled_job('nothing here'), nil)
end)

T.test('labormanager status: starving postings parsed', function()
  local E = fresh('economy')
  T.eq(E.parse_starving('job board: 12 postings resolved, avg wait 30 ticks, longest 90 ticks; 2 starving (> 1200 ticks)'), 2)
  T.eq(E.parse_starving('labor monitor: 0 starving postings (> 1200 ticks)'), 0)
  T.eq(E.parse_starving('starving=4 oldest=7 (1300 ticks)'), 4)
  T.eq(E.parse_starving('not enabled'), nil)
  local W = world{setup = function(W)
    W.act_result('run', function(cmd, a1)
      if cmd == 'labormanager' and a1 == 'status' then return true, 'job board: ...; 3 starving (> 1200 ticks)' end
      return true, ''
    end)
  end}
  W.run(1)
  T.eq(W.state().labor.starving, 3)
end)

T.test('supply alarm: >= 2 thirsty citizens or drink < 10 days -> alarm(), DECISION_NEEDED thirst weekly', function()
  local W, E = world{}
  W.unit(1).counters2 = {thirst_timer = 45000, hunger_timer = 0}
  W.unit(2).counters2 = {thirst_timer = 41000, hunger_timer = 0}
  W.unit(3).counters2 = {thirst_timer = 39000, hunger_timer = 0}       -- plain "thirsty" (live L1b): no alarm
  days(W, 1)
  T.eq(W.K.call('economy', 'alarm'), true)
  T.eq(select(2, W.K.call('economy', 'alarm')), 'thirst 2')
  local function thirst()
    local n = 0
    for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'thirst' then n = n + 1 end end
    return n
  end
  T.eq(thirst(), 1)
  W.unit(2).counters2.thirst_timer = 100
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'alarm')), 'drink 0 d', 'no drink at all: still an alarm')
  T.eq(thirst(), 1, 'weekly')
  days(W, 7)
  T.eq(thirst(), 2)
end)

T.test('supply alarm: plain "hungry" (50000-64999) is no alarm, >= 2 near starving (65000) is (live L3)', function()
  local W = world{setup = function(W)
    F.item(W, 'DRINK', {stack_size = 400})
    F.item(W, 'FOOD', {stack_size = 400, subtype = 1})
  end}
  W.unit(1).counters2 = {thirst_timer = 0, hunger_timer = 52000}
  W.unit(2).counters2 = {thirst_timer = 0, hunger_timer = 64000}
  W.unit(3).counters2 = {thirst_timer = 0, hunger_timer = 50000}
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'alarm')), nil, 'DF eats at "hungry": no brake for it')
  W.unit(1).counters2.hunger_timer = 66000
  W.unit(2).counters2.hunger_timer = 70000
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'alarm')), 'hunger 2')
end)

T.test('wood orders: rock furniture orders turn wood while boulders are scarce and logs cover them (live L3)', function()
  local function run(boulders, logs, extra)
    local orders = {}
    local W = world{setup = function(W)
      for _ = 1, boulders do F.item(W, 'BOULDER', {}) end
      for _ = 1, logs do F.item(W, 'WOOD', {}) end
      local jt, one, daily = df.job_type, df.workquota_frequency_type.OneTime, df.workquota_frequency_type.Daily
      local function o(job, freq, mt, left, wood)
        orders[#orders + 1] = F.order(W, {job_type = jt[job], frequency = freq, mat_type = mt, mat_index = -1,
                                          amount_left = left, amount_total = left,
                                          material_category = {wood = wood or nil}, status = {}})
      end
      o('ConstructDoor', one, 0, 7)           -- 1
      o('ConstructCabinet', one, 0, 8)        -- 2
      o('ConstructDoor', daily, 0, 1)         -- 3 rockstock (repeating): stays
      o('ConstructBed', one, -1, 2, true)     -- 4 beds are wood anyway
      o('ConstructCoffin', one, 0, 0)         -- 5 finished
      o('ConstructThrone', one, 0, 40)        -- 6 more than the logs cover
      for _, e in ipairs(extra or {}) do o(e[1], one, e[2], e[3], e[4]) end
    end}
    W.act_result('order_material', function(id, mat)
      for _, x in ipairs(orders) do
        if x.id == id then x.mat_type, x.mat_index, x.material_category.wood = -1, -1, true end
      end
      return true, mat
    end)
    days(W, 1)
    local ids = {}
    for _, a in ipairs(W.find_acts('order_material')) do ids[#ids + 1] = a.args[1] end
    return ids, orders
  end
  local ids, o = run(8, 82)
  T.eq(ids, {o[1].id, o[2].id}, 'door and cabinet; the repeating, bed, finished and 40-chair orders stay')
  ids = run(25, 82)
  T.eq(#ids, 0, 'enough boulders: rock stays')
  ids = run(8, 40)
  T.eq(#ids, 1, '10 spare logs cover the 7 doors, not the cabinets as well')
  ids = run(8, 82, {{'ConstructTable', -1, 50, true}})
  T.eq(#ids, 0, 'logs already promised to wood orders')
end)

T.test('starved supply labors: tool labors -> managed, others -> monitor fallback, LABOR_STARVED, modern only', function()
  local E = fresh('economy')
  local list = table.concat({'MINE: unmanaged (starved 1384 cycles)', 'HAUL_STONE: managed',
                             'BREWER: managed (starved 243 cycles)', 'COOK: managed (starved 12 cycles)',
                             'HANDLE_VEHICLES: managed (starved 20957 cycles)', 'PLANT: unmanaged (starved 728 cycles)'}, '\n')
  T.eq(E.parse_labor_list(list).BREWER, {managed = true, starved = 243})
  T.eq(E.parse_labor_list(list).HAUL_STONE, {managed = true, starved = 0})
  T.eq(E.parse_labor_list(list).MINE, {managed = false, starved = 1384})
  local mode = 'Mode: modern (labormanager)'
  local fell = {}
  local W = world{setup = function(W)
    W.load({name = 'baseline', every = {ticks = 33600}, labor_fallback = function(K, why) fell[#fell + 1] = why end})
    W.act_result('run', function(cmd, a1)
      if cmd == 'labormanager' and a1 == 'mode' then return true, mode end
      if cmd == 'labormanager' and a1 == 'list' then return true, list end
      return true, ''
    end)
  end}
  days(W, 1)
  local sw = {}
  for _, a in ipairs(W.find_acts('run')) do
    if a.args[1] == 'labormanager' and a.args[2] == 'labor' then sw[#sw + 1] = a.args[3] .. ' ' .. a.args[4] end
  end
  table.sort(sw)
  T.eq(sw, {'MINE managed'}, 'never unmanaged: that leaves a labor to the dwarves outside the auto: details')
  T.eq(fell, {'BREWER starved 243 cycles'}, 'modern starved a supply labor: monitor fallback (once per run)')
  local ev = W.find_events('LABOR_STARVED')
  T.eq(#ev, 2)
  T.eq({ev[1].d.labor, ev[1].d.to}, {'BREWER', 'monitor'})
  W.clear()
  mode = 'Mode: monitor (labormanager)'
  days(W, 1)
  T.eq(#W.find_events('LABOR_STARVED'), 0, 'monitor mode assigns nothing: left alone')
end)

-- live L1b: builtin tool details (Miners, Woodcutters, Hunters) in a fake labor_info, act.work_detail with effect
local function tool_world(opts)
  opts = opts or {}
  local backlog, mode = opts.backlog or 0, opts.mode or 'Mode: monitor (labormanager)'
  local ctl = {}
  local W = world{cit = opts.cit or 12, setup = function(W)
    local kmock = require('dfllm.util.k_mock')
    local function wd(name, labor, ids)
      return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = {[0] = false, [labor] = true},
              flags = {mode = 3}}
    end
    ctl.wds = {Miners = wd('Miners', 1, opts.miners), Woodcutters = wd('Woodcutters', 2, opts.cutters),
               Hunters = wd('Hunters', 3, opts.hunters)}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters}}
    W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return ctl.backlog or backlog end,
            state = function() return {phase = ctl.phase or opts.phase} end})
    W.act_result('run', function(cmd, a1)
      if cmd == 'labormanager' and a1 == 'mode' then return true, ctl.mode or mode end
      return true, ''
    end)
    W.act_result('work_detail', function(name, id, on)
      local v = ctl.wds[name].assigned_units
      for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
      if on then v:insert('#', id) end
      return true
    end)
    W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
    W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
    W.subdefs[3] = {id = 'ITEM_WEAPON_CROSSBOW', skill_melee = -1, skill_ranged = df.job_skill.CROSSBOW}
    for _ = 1, opts.picks or 3 do F.item(W, 'WEAPON', {subtype = 1}) end
    F.item(W, 'WEAPON', {subtype = 1, flags = {forbid = true}})
    for _ = 1, opts.axes or 2 do F.item(W, 'WEAPON', {subtype = 2}) end
    F.item(W, 'WEAPON', {subtype = 3})
    for _ = 1, opts.wood or 200 do F.item(W, 'WOOD', {}) end
    F.item(W, 'FOOD', {stack_size = opts.food or 500, subtype = 1})
    F.item(W, 'DRINK', {stack_size = 500})
    if opts.setup then opts.setup(W) end
  end}
  for i = 1, opts.cit or 12 do
    local u = W.unit(i)
    u.status.labors = {}
    u.mood = -1
    u._m.skills = {MINING = (i == 5 and 10) or (i == 7 and 6) or 0, WOODCUTTING = i == 9 and 4 or 0}
  end
  ctl.W = W
  return W, ctl
end

local function members(ctl, name)
  local r = {}
  for _, id in ipairs(ctl.wds[name].assigned_units) do r[#r + 1] = id end
  table.sort(r)
  return r
end

T.test('tool details: miners follow the dig backlog (min 2, max 4 from pop 20), capped by picks; best skill first', function()
  local W, ctl = tool_world{cit = 12, miners = {5}}
  days(W, 1)
  T.eq(members(ctl, 'Miners'), {5, 7}, 'min 2: the skilled miner stays, the next best joins')
  T.eq(F.bad_runs(W), {})
  local ev = W.find_events('WORK_DETAIL')
  T.eq({ev[1].d.detail, ev[1].d.unit, ev[1].d.on, ev[1].d.n}, {'Miners', 7, 1, 2})
  ctl.backlog = 400
  days(W, 1)
  T.eq(#members(ctl, 'Miners'), 2, 'below pop 20 the cap is the minimum')
  local W2, ctl2 = tool_world{cit = 22, miners = {5}, backlog = 400, picks = 3}
  days(W2, 1)
  T.eq(#members(ctl2, 'Miners'), 3, 'pop 22, 10 tiles per... 400/40 = 10 > max 4, but only 3 usable picks')
  local W3, ctl3 = tool_world{cit = 22, miners = {5}, backlog = 400, picks = 6}
  days(W3, 1)
  T.eq(#members(ctl3, 'Miners'), 4, 'max 4')
  ctl3.backlog = 0
  days(W3, 2)
  T.eq(#members(ctl3, 'Miners'), 4, 'shrinking waits shrink_days')
  days(W3, 2)
  T.eq(members(ctl3, 'Miners'), {5, 7}, 'back to the minimum, the best skills stay')
end)

T.test('tool details: woodcutters by log stock, hunters only in a famine, one tool detail per dwarf', function()
  local W, ctl = tool_world{cit = 12, miners = {5}, cutters = {5}, wood = 30}
  days(W, 1)
  T.eq(members(ctl, 'Miners'), {5, 7})
  T.eq(members(ctl, 'Woodcutters'), {1, 9}, 'the miner left Woodcutters; wood 30 < 60: two cutters, best skill first')
  T.eq(members(ctl, 'Hunters'), {}, 'no famine: no hunters')
  local W2, ctl2 = tool_world{cit = 12, cutters = {3}, wood = 200}
  days(W2, 4)
  T.eq(members(ctl2, 'Woodcutters'), {}, 'logs above autochop max: woodcutters released after shrink_days')
  local W3, ctl3 = tool_world{cit = 12, miners = {5, 7}, food = 0}
  days(W3, 1)
  T.eq(#members(ctl3, 'Hunters'), 1, 'famine: hunters, capped by the one usable crossbow')
end)

T.test('tool details: one hunter for the mood stock (bone, shell, leather) from P1, in PEACE only (live L3)', function()
  local W, ctl = tool_world{cit = 12, miners = {5, 7}, phase = 'P3'}
  days(W, 2)
  T.eq(#members(ctl, 'Hunters'), 1, 'no bone, shell or leather: one hunter')
  local W2, ctl2 = tool_world{cit = 12, miners = {5, 7}, phase = 'P0'}
  days(W2, 2)
  T.eq(members(ctl2, 'Hunters'), {}, 'before mood_from_phase: none')
  local W3, ctl3 = tool_world{cit = 12, miners = {5, 7}, phase = 'P3', setup = function(W)
    for _ = 1, 10 do
      F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true}})
      F.item(W, 'CORPSEPIECE', {corpse_flags = {shell = true}})
      F.item(W, 'SKIN_TANNED', {})
    end
  end}
  days(W3, 2)
  T.eq(members(ctl3, 'Hunters'), {}, 'mood stock full: none')
  local W4, ctl4 = tool_world{cit = 12, miners = {5, 7}, phase = 'P3'}
  W4.set_mode('ALERT')
  days(W4, 2)
  T.eq(members(ctl4, 'Hunters'), {}, 'not outside PEACE')
end)

T.test('tool details: shrinking keeps the best skill, also a noble member (live L1b: the bookkeeper miner)', function()
  local W, ctl = tool_world{cit = 22, miners = {2, 5, 7}, backlog = 400, setup = function(W)
    dfhack.units.getNoblePositions = function(u) return u._m.noble and {{position = {code = 'BOOKKEEPER'}}} or nil end
  end}
  W.unit(5)._m.noble = true                     -- skill 10, the best miner
  days(W, 1)
  T.eq(members(ctl, 'Miners'), {2, 5, 7})
  ctl.backlog = 0
  days(W, 5)
  T.eq(members(ctl, 'Miners'), {5, 7}, 'the unskilled one leaves, the skilled noble stays')
end)

T.test('tool details: soldiers removed at once, nobles and moody dwarves never picked, modern mode left alone', function()
  local W, ctl = tool_world{cit = 12, miners = {5, 6}, setup = function(W)
    dfhack.units.getNoblePositions = function(u) return u._m.noble and {{position = {code = 'MANAGER'}}} or nil end
  end}
  W.unit(6).military.squad_id = 3
  W.unit(7)._m.noble = true
  W.unit(1).mood = 0
  days(W, 1)
  T.eq(members(ctl, 'Miners'), {2, 5}, 'soldier out; noble 7 and moody 1 skipped')
  local W2, ctl2 = tool_world{cit = 12, miners = {5}, mode = 'Mode: modern (labormanager)'}
  days(W2, 2)
  T.eq(members(ctl2, 'Miners'), {5}, 'modern labormanager owns the tool details')
  T.eq(#W2.find_acts('work_detail'), 0)
end)

T.test('D-03 rule: idle > 40 % for 3 days -> one useful backlog item, never filler digging', function()
  local W = world{cit = 4, setup = function(W) for _ = 1, 40 do F.item(W, 'BOULDER', {}) end end}
  W.unit(1).job.current_job, W.unit(2).job.current_job = nil, nil
  W.run(1)
  T.eq(W.state().labor.idle, 50)
  local idle_orders = function()
    local n = 0
    for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag:find('idle', 1, true) then n = n + 1 end end
    return n
  end
  days(W, 1)
  T.eq(idle_orders(), 0, 'two idle days are not enough')
  days(W, 1)
  T.eq(idle_orders(), 1)
  local spec = W.find_acts('workorder')[#W.find_acts('workorder')].args[1]
  T.eq({spec.tag, spec.job, spec.material, spec.amount_total}, {'dfllm:idle_blocks', 'ConstructBlocks', 'INORGANIC', 10})
  T.eq(W.find_acts('quickfort'), {}, 'no digging from economy')
end)

T.test('D-03 variants: off, immediate, only in PEACE, combine when nothing else', function()
  local function setup(W) for _ = 1, 40 do F.item(W, 'BOULDER', {}) end end
  local W = world{cit = 2, decisions = {['D-03'] = 'off'}, setup = setup}
  W.unit(1).job.current_job = nil
  days(W, 5)
  for _, a in ipairs(W.find_acts('workorder')) do T.ok(not a.args[1].tag:find('idle', 1, true)) end
  local W2 = world{cit = 2, decisions = {['D-03'] = 'immediate'}, setup = setup}
  W2.unit(1).job.current_job = nil
  W2.run(1)
  local last = W2.find_acts('workorder')
  T.eq(last[#last].args[1].tag, 'dfllm:idle_blocks')
  local W3 = world{cit = 2, decisions = {['D-03'] = 'immediate'}, mode = 'ALERT', setup = setup}
  W3.unit(1).job.current_job = nil
  days(W3, 2)
  for _, a in ipairs(W3.find_acts('workorder')) do T.ok(not a.args[1].tag:find('idle', 1, true)) end
  local W4 = world{cit = 2, decisions = {['D-03'] = 'immediate'}}   -- no boulders: combine
  W4.unit(1).job.current_job = nil
  W4.run(1)
  T.ok(F.has(F.runs(W4), 'combine all -q'))
  T.eq(F.bad_runs(W4), {})
end)

T.test('state and persist: owned keys only, maps survive a save/load round trip', function()
  local W = world{cit = 7}
  W.event('REPORT', {type = 'MIGRANT_ARRIVAL', text = 'migrants'})
  days(W, 2)
  local s = W.state()
  T.ok(s.stock.drink_d and s.stock.food_d and s.stock.meals and s.labor.starving and s.labor.idle)
  local raw = W.persist_raw['dfllm.m.economy']
  T.ok(raw:find('"imported":{"library/basic":', 1, true), raw)
  local W2 = world{cit = 7, persist = {['m.economy'] = json.decode(raw)}}
  local ok, yes = W2.K.call('economy', 'imported', 'library/basic')
  T.ok(ok and yes)
  days(W2, 1)
  T.eq(count_acts(W2, 'orders_import', 'library/basic'), 0)
  T.ok(W2.persist_raw['dfllm.m.economy']:find('"imported":{"library/basic":', 1, true))
end)

T.done()
