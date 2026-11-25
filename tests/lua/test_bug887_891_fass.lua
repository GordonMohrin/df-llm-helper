-- NEU13 BUG-887..891 (Neuausrichtung 13, 'fass'): drink fell to 0 again and again after seven fix rounds (Run 17 i1-i4, 25.11.). Rebuilt offline:
--   i2 Whirledrampart y509-y522: 418 barrels, 42 'empty' by the census (the game took none), plants in the barrels, DF 'Needs empty food storage item' 100-250x a week,
--       the plant piles' barrel limits left room for 450 more barrels, the 14-day freeze given back after 130 days;
--   i1: trader barrels and the mood pile's barrel among the 'empty' ones; i3/i4: total_cap 200 switched the reserve off for good; 'Brew drink from fruit: Needs
--   unrotten fermentable leaf or fruit' 100-180x a week beside 12000 plant items.
-- BUG-887 the census counts as usable only what a brew can take (trader ref, mood pile, job, out of reach, forbidden named); BUG-888 the food piles' barrel cap
-- STANDS (no timer, follows the barrels down, ends only when the fort stops brewing); BUG-889 total_cap is a rate per game year, the weekly statement names
-- where the boulders are; BUG-890 the fruit brew order goes when DF cancels it for want of fruit; BUG-891 ladder, stall and status say the same truth.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local DAYT = 1200
local BREWER = 6

local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return l.msg end end
  return nil
end

---------------------------------------------------------------- BUG-887: the census
local function census_world(setup)
  local units, ids = {}, {}
  for i = 1, 10 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  for i = 1, 10 do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  setup(W)
  W.load(fresh('economy'))
  return W
end

T.test("BUG-887 i2 y509: 418 barrels, 42 empty by the census: 20 a trader's, 5 held by a job: 17 usable (10 of them in the mood pile, still usable), 3 forbidden named", function()
  local TB
  local W = census_world(function(W)
    df.general_ref_type = df.general_ref_type or kmock.enum({'UNIT_TRADEBRINGER', 'CONTAINS_ITEM'})
    TB = df.general_ref_type.UNIT_TRADEBRINGER
    df.global.world.buildings.other.STOCKPILE = kmock.vec{{id = 7, name = 'dfllm-mood', x1 = 50, y1 = 50, x2 = 50, y2 = 50, z = 9}}
    for _ = 1, 376 do F.item(W, 'BARREL', {_contents = {{id = 1}}, pos = {x = 5, y = 5, z = 9}}) end          -- full of plants
    for _ = 1, 20 do F.item(W, 'BARREL', {general_refs = {{getType = function() return TB end}}, pos = {x = 6, y = 6, z = 9}}) end
    for _ = 1, 10 do F.item(W, 'BARREL', {pos = {x = 50, y = 50, z = 9}}) end                               -- the mood pile
    for _ = 1, 5 do F.item(W, 'BARREL', {flags = {in_job = true}, pos = {x = 7, y = 7, z = 9}}) end
    for _ = 1, 7 do F.item(W, 'BARREL', {pos = {x = 8, y = 8, z = 9}}) end                                  -- free
    for _ = 1, 3 do F.item(W, 'BARREL', {flags = {forbid = true}, pos = {x = 9, y = 9, z = 9}}) end
    F.item(W, 'DRINK', {stack_size = 20000})
  end)
  settle(W)
  local i = W.K.census.i
  T.eq({i.barrels, i.barrels_empty, i.cont_free}, {418, 42, 17}, 'barrels, empty, usable (mood pile barrels count)')
  T.eq({i.barrels_trader, i.barrels_mood, i.barrels_busy, i.barrels_forb}, {20, 10, 5, 3}, 'barrels_mood is information only')
  local econ = require('dfllm.economy')
  T.eq(econ.cont_words(i), "20 a trader's, 5 held by a job, 3 forbidden (not counted)")
  T.ok(econ.cont_text(i):find("17 usable of 42 empty barrels or pots (20 a trader's", 1, true), econ.cont_text(i))
end)

---------------------------------------------------------------- BUG-888: the standing cap
local function brew_world()
  local units, ids = {}, {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  base.economy.diag = {cx_cure = true, mgr_chores = true, still_pin = true, stall_line = true}
  local W = F.world{cfg = {baseline = base}, units = units}
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER'}
  df.job_skill = df.job_skill or {}
  dfhack.job.getWorker = function(j) return j._worker end
  for i = 1, 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.unit(1).status.labors[BREWER] = true
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 20, amount_total = 20,
                          mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{}})
  return W, b, ord
end
local function feed(econ, K, n, tick, job, why)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels ' .. (job or 'Brew drink from plant') .. ': ' .. (why or 'Needs empty food storage item') .. '.'})
  end
end

T.test('BUG-888 i2: the food piles take no more barrels than they hold, with no timer; the cap follows the barrels down; given back only when brewing stops', function()
  local W, still, ord = brew_world()
  local sp = function(id, name, x1, drink, max)
    return {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, max_barrels = max,
            settings = {flags = {food = true}, food = {drink_plant = kmock.vec{drink}, drink_animal = kmock.vec{false}}}}
  end
  local plants, plants2, drinkp, store, bare = sp(41, 'plants', 0, false, 40), sp(42, 'stock', 10, false, 30), sp(43, 'mixed', 20, true, 40), sp(44, 'dfllm-drink', 30, true, 40), sp(45, 'bare', 40, false, 40)
  local pure = sp(46, 'pure drinks', 50, true, 40)         -- a pure drink pile that is not dfllm-drink
  local all = {plants, plants2, drinkp, store, bare, pure}
  df.global.world.buildings.other.STOCKPILE = kmock.vec(all)
  df.building.find = function(id) for _, s in ipairs(all) do if s.id == id then return s end end end
  local items = {}
  for _ = 1, 10 do items[#items + 1] = {pos = {x = 1, y = 1, z = 5}} end
  for _ = 1, 6 do items[#items + 1] = {pos = {x = 11, y = 1, z = 5}} end
  for _ = 1, 4 do items[#items + 1] = {pos = {x = 21, y = 1, z = 5}} end
  rawset(df.global.world.items.other, 'BARREL', kmock.vec(items))
  local actlib = require('dfllm.act')
  local api = actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
  W.act_result('pile_barrels', function(mode, arg) return api.pile_barrels(mode, arg) end)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0}
  local function watch(day, i2)
    local r = {day = true, now = day * DAYT, p = p, inv = i2 or inv, days = {drink_d = 40}, cit = 6}
    econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  end
  watch(100)
  T.eq(p.pilestand, nil, 'no DF reason: nothing acts')
  T.eq({plants.max_barrels, plants2.max_barrels}, {40, 30})
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  T.eq(p.pilestand, true, 'DF cancels for want of a container: the cap starts')
  T.eq({plants.max_barrels, plants2.max_barrels, drinkp.max_barrels, store.max_barrels, bare.max_barrels, pure.max_barrels}, {10, 6, 40, 40, 2, 40},
       'food piles at what they hold; every pile that takes drink (mixed, pure, dfllm-drink) left completely open; a pile without barrels at the floor of 2')
  -- round 3 (verifier): a second day on which the mixed pile's barrel count GROWS: it is not shut (no ratchet), the pure food piles stay capped
  for _ = 1, 5 do items[#items + 1] = {pos = {x = 21, y = 1, z = 5}} end
  rawset(df.global.world.items.other, 'BARREL', kmock.vec(items))
  watch(102)
  T.eq({drinkp.max_barrels, pure.max_barrels, plants.max_barrels}, {40, 40, 10}, 'day 2: the mixed pile holds 9 barrels, its limit is still 40')
  items[#items + 1] = {pos = {x = 21, y = 1, z = 5}}
  rawset(df.global.world.items.other, 'BARREL', kmock.vec(items))
  api.pile_barrels('freeze', {mixed = true, floor = 2})          -- the drink emergency in standing mode does not cap drink piles either
  T.eq(drinkp.max_barrels, 40, 'day 3: still open, also in the drink emergency')
  T.ok(log_has(W, 'container stand: the food piles take no more barrels'), 'one kern.log line')
  -- 200 game days later: DF's cancels are long gone, the cap stands (the old freeze was given back after 14 days / 130 days)
  watch(300)
  watch(301)
  T.eq({p.pilestand, plants.max_barrels, plants2.max_barrels}, {true, 10, 6}, 'a short calm (1 day) gives nothing back')
  T.ok(p.pilecap and p.pilecap['41'] == 40 and p.pilecap['45'] == 40 and p.pilecap['43'] == nil, 'the old limits are kept for the end (the mixed pile was never touched)')
  -- a barrel leaves a pile (hauled to the drink pile): the cap follows it down at the next look, never up
  items[1].pos = {x = 21, y = 1, z = 5}
  rawset(df.global.world.items.other, 'BARREL', kmock.vec(items))
  watch(302)
  T.eq({plants.max_barrels, plants2.max_barrels}, {9, 6})
  -- the fort stops brewing (no brewable plant): after 30 days the limits go back
  local none = {brew_p = 0, brew_g = 0, barrels = 20, barrels_empty = 4, cont_free = 0}
  watch(310, none)
  T.eq(p.pilestand, true, '8 days without plants: the cap stands')
  watch(341, none)
  T.eq({p.pilestand, p.pilecap, plants.max_barrels, plants2.max_barrels}, {nil, nil, 40, 30}, 'brewing stopped for 31 days: the old limits are back')
  T.ok(log_has(W, 'container stand over'), 'said')
end)

T.test('BUG-888: the switch cancel.stand = false leaves the timed freeze of BUG-844 as it was', function()
  local W, still, ord = brew_world()
  W.K.cfg.baseline.economy.cancel.stand = false
  W.act_result('pile_barrels', function() return true, {} end)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  feed(econ, W.K, 12, 101 * DAYT)
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = 101 * DAYT, p = p, inv = {brew_p = 100, barrels = 20, barrels_empty = 4, cont_free = 0}, days = {drink_d = 40}, cit = 6})
  T.eq(p.pilestand, nil)
  local froze = 0
  for _, a in ipairs(W.find_acts('pile_barrels')) do if a.args[1] == 'freeze' then froze = froze + 1 end end    -- round 6: the mood piles' one-off 'zero_mood' call is not a freeze
  T.eq(froze, 0, 'the stand never froze a pile (the verdict path needs its stall days)')
end)

T.test('BUG-888 round 2: a pile whose barrels all leave keeps a floor of 2 (never 0), a pile with a limit under the floor is not raised', function()
  local actlib = require('dfllm.act')
  local sp = function(id, name, x1, drink, max)
    return {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, max_barrels = max,
            settings = {flags = {food = true}, food = {drink_plant = kmock.vec{drink}, drink_animal = kmock.vec{false}}}}
  end
  local a, b, c = sp(1, 'a', 0, false, 40), sp(2, 'b', 10, false, 1), sp(3, 'c', 20, false, 40)
  df.global.world.buildings.other.STOCKPILE = kmock.vec{a, b, c}
  local items = {{pos = {x = 1, y = 1, z = 5}}, {pos = {x = 2, y = 1, z = 5}}, {pos = {x = 2, y = 2, z = 5}}, {pos = {x = 21, y = 1, z = 5}}}
  rawset(df.global.world.items.other, 'BARREL', kmock.vec(items))
  local api = actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
  api.pile_barrels('freeze', {floor = 2})
  T.eq({a.max_barrels, b.max_barrels, c.max_barrels}, {3, 1, 2}, 'a holds 3, b keeps its own 1, c holds 1 and gets the floor 2')
  rawset(df.global.world.items.other, 'BARREL', kmock.vec{})          -- every barrel leaves
  api.pile_barrels('freeze', {floor = 2})
  T.eq({a.max_barrels, b.max_barrels, c.max_barrels}, {2, 1, 2}, 'all gone: the limit stops at the floor, a pile can always take 2 barrels for its food')
end)

T.test('BUG-888 round 2: the cap is lifted when DF has not cancelled for stand_calm_d days, and starts again when the cancels return', function()
  local W, still, ord = brew_world()
  local plants = {id = 41, name = 'plants', x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 5, max_barrels = 40,
                  settings = {flags = {food = true}, food = {drink_plant = kmock.vec{false}, drink_animal = kmock.vec{false}}}}
  df.global.world.buildings.other.STOCKPILE = kmock.vec{plants}
  df.building.find = function(id) if id == 41 then return plants end end
  local items = {}
  for _ = 1, 10 do items[#items + 1] = {pos = {x = 1, y = 1, z = 5}} end
  rawset(df.global.world.items.other, 'BARREL', kmock.vec(items))
  local actlib = require('dfllm.act')
  local api = actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
  W.act_result('pile_barrels', function(mode, arg) return api.pile_barrels(mode, arg) end)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0}
  local function watch(day) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}) end
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  T.eq({p.pilestand, plants.max_barrels}, {true, 10}, 'capped')
  for d = 110, 135, 5 do watch(d) end                            -- the 7-day window is empty from day 109 on; the gate closes after 14 more days
  T.eq({p.pilestand, plants.max_barrels}, {true, 10}, 'calm for less than 30 days: the cap stands')
  watch(160)                                                     -- the gate itself closes 14 days after the window is empty (cx_off_days), then 30 calm days
  T.eq({p.pilestand, p.pilecap, plants.max_barrels}, {nil, nil, 40}, 'calm for 30+ days: the limits are back')
  T.ok(log_has(W, 'has not cancelled a brew for want of a container'), 'said')
  feed(econ, W.K, 12, 161 * DAYT)
  watch(161)
  T.eq({p.pilestand, plants.max_barrels}, {true, 10}, 'the cancels came back: the cap starts again')
end)

---------------------------------------------------------------- BUG-889: the reserve cap is a rate; the statement names where the boulders are
local function rworld()
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  df.unit_labor = {BREWER = 6, [6] = 'BREWER', CARPENTER = 7, [7] = 'CARPENTER', STONE_CRAFT = 8, [8] = 'STONE_CRAFT'}
  df.job_skill = df.job_skill or {}
  for i, n in ipairs({'MakeBarrel', 'BrewDrink'}) do df.job_type[n], df.job_type[900 + i] = 900 + i, n end
  dfhack.units.isChild = function() return false end
  dfhack.units.isBaby = function() return false end
  for i = 1, 8 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  W.act_result('order_remove', function() return true, 'removed' end)
  return W
end
local function rrun(W, o)
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  local r = {now = o.now, day = true, p = p, inv = o.inv, f = {['workshop:Carpenters'] = true, ['workshop:Craftsdwarfs'] = true, ['workshop:Still'] = true},
             s = {brew = {left = o.brews or 30}, live = {}, used = {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 8}
  local acted = econ.plan_reserve(W.K, c, r)
  return acted, r, p
end

T.test('BUG-889 i3/i4: 200 containers ordered in a year do not switch the reserve off for good: the count starts over after a game year', function()
  local W = rworld()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  local inv = {wood = 60, wood_far = 0, boulders = 0, barrels = 400, barrels_empty = 20, cont_free = 2}
  feed(econ, W.K, 40, t0 + 10 * DAYT)
  local p = W.K.persist.get('m.economy')
  p.rsv = {t0 = t0, at = t0, done = t0 + 1, mat = 'wood', n = 30, made = 201, wn = 201, wt = t0, rep = 1}
  local acted, r = rrun(W, {now = t0 + 10 * DAYT, inv = inv})
  T.ok(acted and #r.cands == 0, 'inside the year: capped')
  T.ok(log_has(W, 'ordered in this game year (cap 200 a year'), 'the cap line says per year')
  feed(econ, W.K, 40, t0 + 340 * DAYT)
  local acted2, r2, p2 = rrun(W, {now = t0 + 340 * DAYT, inv = inv})
  T.ok(acted2 and #r2.cands == 1, 'a game year after the count began it orders again')
  T.eq(p2.rsv.wn, r2.cands[1].n, 'the new year counts from this batch')
end)

T.test('BUG-889 i1: no usable material: ONE weekly statement names where the 33 boulders are and what the fort asks for', function()
  local W = rworld()
  local econ = require('dfllm.economy')
  local t0 = 300 * DAYT
  feed(econ, W.K, 40, t0)
  local inv = {wood = 0, wood_far = 0, boulders = 33, rock = 0, rock_far = 2, rock_busy = 0, barrels = 119, barrels_empty = 27, cont_free = 0, picks = 0}
  rrun(W, {now = t0 + DAYT, inv = inv})
  rrun(W, {now = t0 + 2 * DAYT, inv = inv})
  local n, line = 0, nil
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('nothing to make them of', 1, true) then n = n + 1; line = l.msg end end
  T.eq(n, 1, 'once a week')
  T.ok(line:find('33 boulders exist but none is free: 31 built into buildings', 1, true), line)
  T.ok(line:find('trade.want wood', 1, true), line)
end)

---------------------------------------------------------------- BUG-890: the fruit order
local function drink_world()
  local units = {}
  for i = 1, 12 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local cfg = F.cfg()
  cfg.economy.standing = false
  local W = F.world{cfg = {baseline = cfg}, units = units}
  df.unit_labor = {BREWER = 3, [3] = 'BREWER'}
  local ids = {}
  for i = 1, 12 do ids[i] = i; local u = W.unit(i); u.job = {current_job = {id = 900 + i}}; u.status.labors = {[3] = true}; u.mood = -1 end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true}, products = {'DRINK_MAT', 'SEED_MAT'}})
  F.mat(W, 419, 70, {token = 'PLANT:STRAWBERRY:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}, products = {'DRINK_MAT'}})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.', bld = '', dig = ''} end})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end, state = function() return {phase = 'P5'} end,
          repair = function() return true, 'rp' end})
  F.workshop(W, 'Still')
  F.workshop(W, 'Carpenters')
  for i = 1, 16 do F.item(W, 'BARREL', i <= 12 and {} or {_contents = {{id = 1}}}) end
  F.item(W, 'DRINK', {stack_size = 20})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  F.item(W, 'PLANT', {mat_type = 419, mat_index = 50, stack_size = 30})
  F.item(W, 'PLANT_GROWTH', {mat_type = 419, mat_index = 70, stack_size = 12000})
  local removed = {}
  W.act_result('workorder', function(spec)
    local mo = df.global.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    mo.all:insert('#', {id = id, job_type = df.job_type[spec.job], reaction_name = spec.reaction or '', amount_left = spec.amount_total, amount_total = spec.amount_total,
                        _spec = spec, item_subtype = -1, mat_type = -1, mat_index = -1, status = {validated = true}})
    return true, id
  end)
  W.act_result('order_remove', function(id)
    removed[#removed + 1] = id
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i) end end
    return true, 'removed'
  end)
  W.load(fresh('economy'))
  return W, removed
end
local function orders_of(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end

T.test('BUG-890 i3/i4: DF cancels "Brew drink from fruit: Needs unrotten fermentable leaf or fruit": the fruit order is taken down, not made for the hold, then tried again', function()
  local W, removed = drink_world()
  local econ = require('dfllm.economy')
  days(W, 1)
  local n0 = #orders_of(W, 'dfllm:drink_fruit')
  T.eq(n0, 1, 'the census sees 12000 fruit: the fruit order is made')
  feed(econ, W.K, 14, W.K.now().tick, 'Brew drink from fruit', 'Needs unrotten fermentable leaf or fruit')
  days(W, 1)
  T.ok(#removed >= 1, 'the fruit order was removed: ' .. T.show(removed))
  T.ok(log_has(W, 'fruit brew off: DF cancelled'), 'one kern.log line')
  local p = W.K.persist.get('m.economy')
  T.ok(p.fruitoff ~= nil and p.orders['dfllm:drink_fruit'] == nil, 'state: off, no order id')
  days(W, 5)
  T.eq(#orders_of(W, 'dfllm:drink_fruit'), n0, 'no new fruit order during the hold')
  days(W, 31)
  T.ok(#orders_of(W, 'dfllm:drink_fruit') > n0, 'the hold is over: one is made again')
end)

T.test('BUG-890: brew_share gives the whole share to the plant order and none to the fruit order while the fruit order is off', function()
  local W = drink_world()
  local econ = require('dfllm.economy')
  local r = {inv = {brew_p = 30, brew_g = 90}, p = {}, now = 1}
  local plain = econ.brew_share(r, {src = 'brew_p'}, 8)
  r.p.fruitoff = 0
  T.ok(plain < 8, 'normally the plants take their stock share: ' .. plain)
  T.eq(econ.brew_share(r, {src = 'brew_p'}, 8), 8, 'fruit off: all of it')
end)

---------------------------------------------------------------- BUG-891: the same truth in the stall text, the ladder and the status
T.test('BUG-891: the stall line, the ladder and the status name usable of empty with the reasons', function()
  local W = rworld()
  local econ = require('dfllm.economy')
  local inv = {barrels = 418, barrels_empty = 42, pots_empty = 0, cont_free = 0, barrels_trader = 30, barrels_far = 12}
  T.eq(econ.cont_text(inv), "0 usable of 42 empty barrels or pots (30 a trader's, 12 out of reach)")
  local d = econ.brew_diag(W.K, inv, {res = 3, ph = 0, dfx = 'DF cancelled Brew 40x in 7 d'})
  T.eq(d.conts.words, "30 a trader's, 12 out of reach")
  local id, text = econ.brew_cause({stills = {{id = 1, at = {1, 1, 1}, jobs = 0, taken = 0, susp = 0}}, brewers = {n = 2, idle = 1, who = {}}, orders = {n = 1, valid = 1}, conts = d.conts})
  T.eq(id, 'nobarrel')
  T.ok(text:find("not usable: 30 a trader's, 12 out of reach", 1, true), text)
end)

T.done()
