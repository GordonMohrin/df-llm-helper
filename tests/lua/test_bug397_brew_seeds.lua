-- BUG-397 (Run 16c i3 Yawninggilt: an embark without plump helmet seeds and no depot, 'no brewable plants', drink 150 -> 0):
-- with the stills' plants short (stock.bshort) an empty farm slot takes the brewable crop that has seeds (not the crop with
-- the most seeds), the caravans are asked for seeds of a brewable crop (and plants) when none is in stock, and the drink block
-- says what the fort does about it. Fails on the commit before (the crop with the most seeds, no seed want, bare text).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local SEASONS = {SPRING = true, SUMMER = true, AUTUMN = true, WINTER = true}
local function raw(id, depth)
  local f = {SEED = true}
  for k in pairs(SEASONS) do f[k] = true end
  return {id = id, flags = f, underground_depth_min = depth or 0, growths = kmock.vec{}}
end

-- opts.drink (stack size), opts.brewseed (seeds of the brewable cup), opts.quarry (seeds of the cook crop with the most seeds)
local function world(opts)
  opts = opts or {}
  local cit = 6
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.farms.autofarm = 'off'
  cfg.economy.farms.cook_slots = 0                       -- BUG-381's pass is not under test
  local W = F.world{cfg = {baseline = cfg}, units = units}
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  df.global.world.raws.plants.all = kmock.vec{
    raw('BUSH_QUARRY', 1),                -- 0: underground, all year, cooks, not brewed
    raw('MUSHROOM_CUP_DIMPLE', 1)}        -- 1: underground, all year, DRINK_MAT
  F.mat(W, 419, 51, {token = 'PLANT:BUSH_QUARRY:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 52, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:STRUCTURAL', flags = {}, products = {'DRINK_MAT'}})
  F.mat(W, 419, 61, {token = 'PLANT:BUSH_QUARRY:SEED'})
  F.mat(W, 419, 62, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:SEED'})
  F.item(W, 'BARREL', {})
  F.item(W, 'DRINK', {stack_size = opts.drink or 10})                                   -- a few drink days
  F.item(W, 'FOOD', {stack_size = 400, subtype = 1})
  F.item(W, 'SEEDS', {mat_type = 419, mat_index = 61, stack_size = opts.quarry or 100})   -- the most seeds
  if (opts.brewseed or 5) > 0 then F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = opts.brewseed or 5}) end
  W.act_result('farm_crop', function(id, s, crop)
    W.buildings[id].plant_id[s] = crop
    return true, crop
  end)
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function() return {c = '.'} end,
          plot_under = function() return true end})
  W.load(fresh('economy'))
  return W
end

local function plots(W, n)
  local r = {}
  for i = 1, n do
    r[i] = F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 100,
                                       plant_id = {[0] = -1, [1] = -1, [2] = -1, [3] = -1},
                                       getType = function() return df.building_type.FarmPlot end})
  end
  return r
end
local function count(pl, s, id) local n = 0; for _, p in ipairs(pl) do if p.plant_id[s] == id then n = n + 1 end end return n end
local function settle(W) for _ = 1, 80 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

T.test('BUG-397: drink plants short: the empty slots take the brewable crop that has seeds, not the crop with the most seeds', function()
  local W = world()
  days(W, 1)
  local pl = plots(W, 3)
  days(W, 3)
  T.eq(W.state().stock.bshort, 1, 'the stills\' plants are short')
  T.eq(count(pl, 0, 1), 3, 'all three spring slots: the cup (brewable, 5 seeds)')
  T.eq(count(pl, 0, 0), 0, 'not the quarry bush with 100 seeds')
end)

T.test('BUG-397: drink fine: the crop with the most seeds as before', function()
  local W = world{drink = 4000}
  days(W, 1)
  local pl = plots(W, 3)
  days(W, 3)
  T.eq(W.state().stock.bshort, nil)
  T.eq(count(pl, 0, 0), 3, 'quarry bushes: the most seeds')
end)

T.test('BUG-397: no seed of a brewable crop and the plants short: the caravans are asked for seeds and plants; the block says it', function()
  local W = world{brewseed = 0}
  days(W, 1)
  plots(W, 2)
  days(W, 3)
  local st = W.state()
  T.eq(st.stock.bshort, 1)
  local econ = require('dfllm.economy')
  local seeds, plant
  for _, w in ipairs(econ.fd_wants(W.K, W.K.cfg.baseline.economy, {inv = W.K.census.i or {}, days = {drink_d = 3, food_d = 400}}) or {}) do
    if w.buy == 'seeds' then seeds = w end
    if w.buy == 'plant' then plant = w end
  end
  T.ok(seeds and seeds.why == 'no seeds of a brewable crop', 'seeds wanted: ' .. tostring(seeds and seeds.why))
  T.ok(plant, 'and plants')
  local r = {inv = W.K.census.i or {}, days = {drink_d = 3, food_d = 400}, p = W.K.persist.get('m.economy')}
  local bl = econ.drink_block(W.K, W.K.cfg.baseline.economy, r, r.inv)
  local words
  for _, x in ipairs(bl) do if x[1] == 'plants' then words = x[2] end end
  T.eq(words, 'no brewable plants (0 seeds; gathering, trade)')
end)

T.done()
