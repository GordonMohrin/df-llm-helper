-- economy, Run 15 food and drink start (Inkintense y372-y374, Drillchamber y372): year 1 without a Still and only a
-- drink_low question (BUG-255); a plot slot held a crop without one seed through a famine beside 130 other seeds, and
-- the seedless fallback set such crops (BUG-256); low drink days with nobody thirsty (the dwarves drank at the brook) woke
-- DECISION_NEEDED thirst every 7 days and held the supply alarm (BUG-259); breeding pairs had to be marked for
-- slaughter by hand (BUG-260). Every test fails on 2b9c009.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local SEASONS = {SPRING = true, SUMMER = true, AUTUMN = true, WINTER = true}
local function raw(id, flags, depth)
  local f = {SEED = true}
  for k, v in pairs(flags) do f[k] = v end
  return {id = id, flags = f, underground_depth_min = depth or 0, growths = kmock.vec{}}
end

-- opts: cit (12), drinks (DRINK stack, 0 = none), food (FOOD stack), still (true: one stands), kitchen, thirst ({id =
-- timer}), seeds ({[mat_index] = n}: 60 plump helmet, 61 dimple cup), plot (season crops of one underground plot), setup
local function world(opts)
  opts = opts or {}
  local cit = opts.cit or 12
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.standing = false
  local W = F.world{cfg = {baseline = cfg}, units = units}
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = (opts.thirst or {})[i] or 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  df.global.world.raws.plants.all = kmock.vec{
    raw('MUSHROOM_HELMET_PLUMP', SEASONS, 1),                         -- 0: underground, all year
    raw('MUSHROOM_CUP_DIMPLE', SEASONS, 1)}                           -- 1: underground, all year
  F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
  F.mat(W, 419, 61, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:SEED'})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  if (opts.drinks or 20) > 0 then F.item(W, 'DRINK', {stack_size = opts.drinks or 20}) end
  F.item(W, 'FOOD', {stack_size = opts.food or 2000, subtype = 1})
  for mi, n in pairs(opts.seeds or {}) do F.item(W, 'SEEDS', {mat_type = 419, mat_index = mi, stack_size = n}) end
  if opts.still then F.workshop(W, 'Still') end
  if opts.kitchen then F.workshop(W, 'Kitchen') end
  W.act_result('farm_crop', function(id, s, crop)
    W.buildings[id].plant_id[s] = crop
    return true, crop
  end)
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function() return {c = '.', bld = '', dig = ''} end,
          plot_under = function() return true end})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P5'} end})
  if opts.plot then
    local p = opts.plot
    opts.plot_b = F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 90,
                                              plant_id = {[0] = p[1], [1] = p[2], [2] = p[3], [3] = p[4]},
                                              getType = function() return df.building_type.FarmPlot end})
  end
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W
end

local function events(W, typ, pred)
  local r = {}
  for _, e in ipairs(W.find_events(typ)) do if not pred or pred(e) then r[#r + 1] = e end end
  return r
end
local function still_req(W)
  return events(W, 'PROJECT_REQUEST', function(e) return e.d.tpl == 'workshops' and e.d.why == 'mandatory' end)
end
local function decisions(W, id) return events(W, 'DECISION_NEEDED', function(e) return e.d.id == id end) end
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return true end end
  return false
end

T.test('BUG-255: no Still and no project building one -> PROJECT_REQUEST workshops why=mandatory types=[Still], ' ..
       'every request_days, twice an episode; + Kitchen while food is below 60 days and none stands', function()
  local W = world{}
  days(W, 1)
  local r = still_req(W)
  T.eq(#r, 1, 'live: only DECISION_NEEDED drink_low "no still"')
  T.eq({r[1].cls, r[1].d.types}, {'B', {'Still'}}, 'food 2000: the Still alone')
  T.ok(log_has(W, 'no still and no project builds one: request workshops Still (1/2)'), 'kern.log')
  local dl = decisions(W, 'drink_low')
  T.ok(#dl >= 1 and F.has(dl[1].d.auto, 'still') and not F.has(dl[1].d.block, 'still'),
       'the request is the kernel\'s (auto), not the player\'s blocker')
  days(W, 10)
  T.eq(#still_req(W), 1, 'not again within request_days')
  days(W, 5)
  T.eq(#still_req(W), 2)
  days(W, 30)
  T.eq(#still_req(W), 2, 'twice an episode: then the question is the player\'s')
  local W2 = world{food = 10}
  days(W2, 1)
  T.eq(still_req(W2)[1].d.types, {'Still', 'Kitchen'}, 'food low and no kitchen')
  local W3 = world{food = 10, kitchen = true}
  days(W3, 1)
  T.eq(still_req(W3)[1].d.types, {'Still'}, 'a kitchen stands')
  local W4 = world{still = true}
  days(W4, 2)
  T.eq(still_req(W4), {}, 'a Still stands')
end)

T.test('BUG-259: drink below the alarm line with nobody thirsty: no supply alarm, no DECISION_NEEDED thirst; drink_low ' ..
       'asks instead and the status says they drink water; plants and drink in the caravan wants', function()
  local W = world{cit = 6, drinks = 0, still = true}
  days(W, 10)
  T.eq(select(2, W.K.call('economy', 'alarm')), nil, 'live: "drink 0 d" all year, brake and thirst wake')
  T.eq(#decisions(W, 'thirst'), 0, 'live: DECISION_NEEDED thirst every 7 days, 0 thirsty')
  T.eq(#decisions(W, 'drink_low'), 1, 'the drink question with its causes')
  T.ok(log_has(W, 'drink 0 days but nobody thirsty: the citizens drink water'), 'kern.log')
  local dwhy = W.state().stock.dwhy or ''
  T.ok(dwhy:find('nobody thirsty: they drink water', 1, true), dwhy)
  local ok, wants = W.K.call('economy', 'trade_wants')
  local buys = {}
  for _, w in ipairs(ok and wants or {}) do buys[#buys + 1] = w.buy end
  T.ok(F.has(buys, 'plant') and F.has(buys, 'drink'), table.concat(buys, ','))
  W.unit(1).counters2.thirst_timer = 45000                     -- one citizen thirsty: the old rule
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'alarm')), 'drink 0 d')
  T.eq(#decisions(W, 'thirst'), 1)
end)

T.test('BUG-256: the running season\'s slot of a crop without a usable seed is chosen again (a crop with seeds only); ' ..
       'no seedless crop is set; no seed at all: seeds in the caravan wants', function()
  local W = world{seeds = {[60] = 10}, plot = {1, 1, 1, 1}}
  days(W, 1)
  local b = W.buildings
  local plot
  for _, x in pairs(b) do if x.plant_id then plot = x end end
  T.eq(plot.plant_id[0], 0, 'live: MUSHROOM_CUP_DIMPLE with 0 seeds held the slot through a famine')
  T.eq({plot.plant_id[1], plot.plant_id[2], plot.plant_id[3]}, {1, 1, 1}, 'later seasons wait for their turn')
  T.ok(log_has(W, 'no usable seeds for MUSHROOM_CUP_DIMPLE: MUSHROOM_HELMET_PLUMP instead'), 'kern.log')
  -- an empty plot with only dimple-cup seeds: never the helmets without a seed (old: the plot's own crop as a fallback)
  local W2 = world{seeds = {[61] = 4}, plot = {-1, 0, -1, -1}}
  days(W2, 1)
  local p2
  for _, x in pairs(W2.buildings) do if x.plant_id then p2 = x end end
  T.eq(p2.plant_id[0], 1, 'the crop with seeds')
  local W3 = world{plot = {0, -1, -1, -1}}
  days(W3, 1)
  local p3
  for _, x in pairs(W3.buildings) do if x.plant_id then p3 = x end end
  T.eq(p3.plant_id[0], 0, 'no seed anywhere: the slot is left alone')
  T.eq(p3.plant_id[1], -1, 'and no seedless crop is set')
  T.ok(log_has(W3, 'no seeds for MUSHROOM_HELMET_PLUMP and no other crop with seeds grows there now'), 'said once')
  days(W3, 1)                                                  -- the daily watch after the first slot count
  local ok, wants = W3.K.call('economy', 'trade_wants')
  local seeds
  for _, w in ipairs(ok and wants or {}) do if w.buy == 'seeds' then seeds = w end end
  T.ok(seeds and seeds.n > 0, 'seeds wanted')
end)

T.test('BUG-260: butcher.mark marks surplus tame animals (one pair per race kept unless keep_pairs false; pets, war ' ..
       'animals never; race filter; n)', function()
  local function A(id, race, female, extra)
    local a = {id = id, race = race, female = female, adult = true, pet = false, slaughter = false, war = false}
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
  end
  -- Inkintense: a turkey pair and a duck pair, plus a pet cat and a war dog
  local herd = {A(26285, 5, false), A(26286, 5, true), A(26450, 6, true), A(26451, 6, false),
                A(30, 7, true, {pet = true}), A(31, 8, false, {war = true})}
  local marks = {}
  local W = world{setup = function(W)
    W.set_census('a', {tick = 0, n = #herd, list = herd})
    W.act_result('animal_slaughter', function(id, on) marks[#marks + 1] = id; return true, 'marked' end)
    df.global.world.raws.creatures = {all = {[5] = {creature_id = 'TURKEY'}, [6] = {creature_id = 'DUCK'},
                                              [7] = {creature_id = 'CAT'}, [8] = {creature_id = 'DOG'}}}
  end}
  settle(W)
  local r = W.inbox('butcher.mark', {})
  T.eq(r.ok, false, 'every animal is a breeding pair, a pet or a war animal')
  T.ok(r.msg:find('one breeding pair per race', 1, true), r.msg)
  r = W.inbox('butcher.mark', {n = 1, race = 'TURKEY', keep_pairs = false})
  T.eq(r.ok, true, r.msg)
  T.eq(marks, {26285}, 'the turkey only, one')
  T.ok(r.msg:find("no Butcher's shop", 1, true), r.msg)
  r = W.inbox('butcher.mark', {n = 20, keep_pairs = false})
  T.eq(marks, {26285, 26285, 26286, 26450, 26451}, 'never the pet or the war dog (the census says marked later)')
  T.eq(W.inbox('butcher.mark', {n = 0}).ok, false)
end)

T.test('BUG-309: butcher.mark names id, species and sex of each animal; sex filter', function()
  local function A(id, race, female, extra)
    local a = {id = id, race = race, female = female, adult = true, pet = false, slaughter = false, war = false}
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
  end
  -- Drillchamber y376: 8 tame, the player's keep_pairs:false marked 26280, a stray dog, the reply said '26280'
  local herd = {A(26280, 8, true), A(26281, 8, false), A(26282, 5, false, {adult = false})}
  local W = world{setup = function(W)
    W.set_census('a', {tick = 0, n = #herd, list = herd})
    W.act_result('animal_slaughter', function(id, on) return true, 'marked' end)
    df.global.world.raws.creatures = {all = {[5] = {creature_id = 'TURKEY'}, [8] = {creature_id = 'DOG'}}}
  end}
  settle(W)
  local r = W.inbox('butcher.mark', {n = 1, keep_pairs = false, sex = 'male'})
  T.eq(r.ok, true, r.msg)
  T.ok(r.msg:find('1 marked for slaughter: 26281 DOG male', 1, true), 'old code: ' .. r.msg)
  r = W.inbox('butcher.mark', {n = 3, keep_pairs = false})
  T.ok(r.msg:find('26280 DOG female, 26281 DOG male, 26282 TURKEY male (young)', 1, true), r.msg)
  T.eq(W.inbox('butcher.mark', {sex = 'm'}).ok, false, 'sex is male or female')
end)

T.test('BUG-308: economy counts DF\'s cancels of a job kind with its last words (cancels_of)', function()
  local W = world{}
  settle(W)
  T.eq({select(2, W.K.call('economy', 'cancels_of', 'collect webs'))}, {0})
  for _ = 1, 2 do
    W.event('REPORT', {type = 'CANCEL_JOB', text = 'Ral, militia commander cancels Collect webs: Needs undisturbed thread.'})
  end
  W.run(1)
  local _, n, why = W.K.call('economy', 'cancels_of', 'collect webs')
  T.eq({n, why}, {2, 'Needs undisturbed thread'}, 'old code: no such function')
  -- review: 60 other kinds cancelled first (a long session) must not hide the webs cancels from care
  local W2 = world{}
  settle(W2)
  for i = 1, 61 do
    W2.event('REPORT', {type = 'CANCEL_JOB', text = string.format('Ral cancels Job%02d: Interrupted by a cat.', i)})
  end
  W2.event('REPORT', {type = 'CANCEL_JOB', text = 'Ral cancels Collect webs: Needs undisturbed thread.'})
  W2.run(1)
  T.eq({select(2, W2.K.call('economy', 'cancels_of', 'collect webs'))}, {1, 'Needs undisturbed thread'}, 'a full table dropped the new kind')
end)

T.done()
