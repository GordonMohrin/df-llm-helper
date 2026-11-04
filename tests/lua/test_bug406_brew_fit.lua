-- BUG-406/BUG-408 (Run 16c i3 Yawninggilt y388: one underground farm plot, 'no seeds for MUSHROOM_HELMET_PLUMP and no other crop with seeds
-- grows there now' in every season while 476 seeds of brewable crops lay unused, drink 23 days; Run 16a i1 Bachwald: 'no brewable plants'
-- beside 50 seeds and no farm plot): the stills' plants are short and the brewable seeds in stock fit no farm plot (a surface crop, only
-- an underground plot; or no plot at all): PROJECT_REQUEST farms why=drink|drink_surface, once per request_days; the block says so; the
-- gather zone follows the missing plants from gather.drink_early drink days on. Fails on the commit before (no request, bare text, 60 days).
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

-- opts.drink (stack size), opts.cup (seeds of the underground brewable cup), opts.grass (seeds of the surface brewable grass),
-- opts.under (what snapshot.plot_under answers: true = underground plots)
local function world(opts)
  opts = opts or {}
  local cit = 6
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.farms.autofarm = 'off'
  cfg.economy.farms.cook_slots = 0
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
    raw('BUSH_QUARRY', 1),                -- 0: underground, cooks
    raw('MUSHROOM_CUP_DIMPLE', 1),        -- 1: underground, DRINK_MAT
    raw('GRASS_PIG', 0)}                  -- 2: surface, DRINK_MAT
  F.mat(W, 419, 51, {token = 'PLANT:BUSH_QUARRY:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 52, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:STRUCTURAL', flags = {}, products = {'DRINK_MAT'}})
  F.mat(W, 419, 53, {token = 'PLANT:GRASS_PIG:STRUCTURAL', flags = {}, products = {'DRINK_MAT'}})
  F.mat(W, 419, 61, {token = 'PLANT:BUSH_QUARRY:SEED'})
  F.mat(W, 419, 62, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:SEED'})
  F.mat(W, 419, 63, {token = 'PLANT:GRASS_PIG:SEED'})
  F.item(W, 'BARREL', {})
  F.item(W, 'DRINK', {stack_size = opts.drink or 10})
  F.item(W, 'FOOD', {stack_size = 400, subtype = 1})
  F.item(W, 'SEEDS', {mat_type = 419, mat_index = 61, stack_size = 100})
  if (opts.cup or 0) > 0 then F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = opts.cup}) end
  if (opts.grass or 0) > 0 then F.item(W, 'SEEDS', {mat_type = 419, mat_index = 63, stack_size = opts.grass}) end
  W.act_result('farm_crop', function(id, s, crop)
    W.buildings[id].plant_id[s] = crop
    return true, crop
  end)
  local under = opts.under
  if under == nil then under = true end
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function() return {c = '.'} end,
          plot_under = function() return under end})
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
local function settle(W) for _ = 1, 80 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function reqs(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'farms' then r[#r + 1] = e.d end end
  return r
end

T.test('BUG-406: surface seeds only, the one plot is underground: a surface plot is requested (why=drink_surface), once', function()
  local W = world{grass = 476}
  days(W, 1)
  plots(W, 1)
  days(W, 6)
  T.eq(W.state().stock.bshort, 1)
  local r = reqs(W)
  T.eq(#r, 1, 'one request')
  T.eq({r[1].tpl, r[1].why, r[1].n}, {'farms', 'drink_surface', 1})
  days(W, 6)
  T.eq(#reqs(W), 1, 'every request_days only')
end)

T.test('BUG-406: underground seeds only, the plots lie on the surface: a plot in a room is requested (why=drink)', function()
  local W = world{cup = 30, under = false}
  days(W, 1)
  plots(W, 2)
  days(W, 6)
  local r = reqs(W)
  T.eq(#r, 1)
  T.eq(r[1].why, 'drink')
end)

T.test('BUG-408: seeds of a brewable crop and no farm plot at all: the plot is requested', function()
  local W = world{grass = 50}
  days(W, 7)
  local r = reqs(W)
  T.eq(#r, 1)
  T.eq(r[1].why, 'drink_surface')
end)

T.test('BUG-406: the seeds fit a plot (underground cup, underground plot): no request, the slots take the cup', function()
  local W = world{cup = 30}
  local pl = plots(W, 1)
  days(W, 7)
  T.eq(#reqs(W), 0)
  T.eq(pl[1].plant_id[0], 1, 'the cup (brewable) in the spring slot')
end)

T.test('BUG-406: no seed of a brewable crop: no plot request (the caravans are asked, BUG-397)', function()
  local W = world{}
  days(W, 1)
  plots(W, 1)
  days(W, 6)
  T.eq(#reqs(W), 0)
end)

T.test('BUG-406: the block names seeds that fit no plot', function()
  local W = world{grass = 476}
  days(W, 1)
  plots(W, 1)
  days(W, 6)
  local econ = require('dfllm.economy')
  local r = {inv = W.K.census.i or {}, days = {drink_d = 3, food_d = 400}, p = W.K.persist.get('m.economy')}
  local bl = econ.drink_block(W.K, W.K.cfg.baseline.economy, r, r.inv)
  local words
  for _, x in ipairs(bl) do if x[1] == 'plants' then words = x[2] end end
  T.ok(words and words:find('476 seeds fit no farm plot: surface seeds', 1, true), 'words: ' .. tostring(words))
end)

T.test('BUG-408: with no brewable plant at all the gather zone follows from gather.drink_early drink days (not only below 60)', function()
  local W = world{drink = 30}
  days(W, 4)
  local dd = W.state().stock.drink_d
  T.ok(dd >= 60 and dd < 120, 'between the old line (60) and the early one (120): ' .. tostring(dd))
  T.eq(W.state().stock.bshort, 1, 'drink ' .. tostring(dd) .. ' days, no brewable plant')
  local W2 = world{drink = 4000}
  days(W2, 4)
  T.eq(W2.state().stock.bshort, nil, 'drink plentiful: none')
end)

T.done()
