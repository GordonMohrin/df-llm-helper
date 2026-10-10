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
    F.item(W, 'MEAT', {stack_size = 3})
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
        i.bars, i.fuel, i.bolts, i.wood, i.boulders, i.blocks, i.crafts},
       {5, 8, 17, 10, 2, 2, 1, 2, 1, 3, 2, 1, 25, 3, 5, 2, 1})
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
