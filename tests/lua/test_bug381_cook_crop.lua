-- BUG-381 (Run 16 i1/i2/i4: 'raw food is not cooked', 0 meals for months beside 2,000+ plump helmets, the kitchen built and
-- COOK held; 0 cook ingredients, 2224 cook-banned): the only crop the kernel's farm slots planted was the plump helmet (the
-- crop with the most seeds), which Gordon's rule D-09 keeps off the kitchen's list. While the kitchen has fewer cook
-- ingredients and meals than citizens, farms.cook_slots empty slots a season take a crop with seeds the kitchen may cook.
-- Fails on ec9bd8e (every slot plump helmets).
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

local function world(opts)
  opts = opts or {}
  local cit = 6
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.farms.autofarm = 'off'
  if opts.cfg then opts.cfg(cfg) end
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
    raw('MUSHROOM_HELMET_PLUMP', 1),      -- 0: underground, all year, the config's Cook ban (D-09)
    raw('BUSH_QUARRY', 1),                -- 1: underground, all year, its leaves cook
    raw('MUSHROOM_CUP_DIMPLE', 1)}        -- 2: underground, brewed only
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 51, {token = 'PLANT:BUSH_QUARRY:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 52, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:STRUCTURAL', flags = {}})
  F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
  F.mat(W, 419, 61, {token = 'PLANT:BUSH_QUARRY:SEED'})
  F.mat(W, 419, 62, {token = 'PLANT:MUSHROOM_CUP_DIMPLE:SEED'})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'PLANT', {stack_size = opts.plump or 500, mat_type = 419, mat_index = 50})       -- plump helmets: cook-banned
  if opts.meals then F.item(W, 'FOOD', {stack_size = opts.meals, subtype = 1}) end
  F.item(W, 'SEEDS', {mat_type = 419, mat_index = 60, stack_size = 100})                       -- the most seeds
  if opts.quarry ~= false then F.item(W, 'SEEDS', {mat_type = 419, mat_index = 61, stack_size = 5}) end
  F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 30})
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
local function logs_like(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then r[#r + 1] = l.msg end end
  return r
end

T.test('BUG-381: a kitchen with only cook-banned plump helmets gets cook_slots slots of a crop it may cook; the rest stay brew crops', function()
  local W = world()
  days(W, 1)
  local pl = plots(W, 3)
  days(W, 2)
  T.eq(count(pl, 0, 1), 2, 'two of three plots plant quarry bushes in spring (cook_slots 2)')
  T.eq(count(pl, 0, 0), 1, 'the third the crop with the most seeds: plump helmets stay brewed')
  T.eq(count(pl, 2, 1), 2, 'and in autumn')
  T.ok(#logs_like(W, 'the farms plant a cook crop (BUSH_QUARRY') >= 1, 'kern.log names it')
  pl[3].plant_id[0] = 2                                    -- a planted slot is never replaced
  days(W, 1)
  T.eq(count(pl, 0, 1), 2)
  T.eq(pl[3].plant_id[0], 2)
end)

T.test('BUG-381: no cook slot with meals or cook ingredients for every citizen, with cook_slots 0, or without seeds of a cook crop', function()
  local W = world{meals = 10}
  days(W, 1)
  local pl = plots(W, 3)
  days(W, 2)
  T.eq(count(pl, 0, 0), 3, 'meals for all six: all plump helmets as before')
  local W0 = world{cfg = function(c) c.economy.farms.cook_slots = 0 end}
  days(W0, 1)
  local pl0 = plots(W0, 3)
  days(W0, 2)
  T.eq(count(pl0, 0, 0), 3, 'cook_slots 0')
  local Wn = world{quarry = false}
  days(Wn, 1)
  local pln = plots(Wn, 3)
  days(Wn, 2)
  T.eq(count(pln, 0, 0), 3, 'no seeds of a cook crop: the plots keep the brew crops')
  T.ok(#logs_like(Wn, 'no seeds of a crop it may cook') >= 1, 'kern.log says the caravans are asked')
end)

-- BUG-398 (Run 16b i2 Ostgate: 79 citizens, 0 meals, every plot slot planted with plump helmets: the R20 plan found no empty
-- slot): planted slots of a crop the kitchen will not cook give way to the cook crop, up to the plan's slots a season.
T.test('BUG-398: planted plump helmet slots are swapped for the cook crop up to cook_slots a season; planted cook slots count', function()
  local W = world()
  days(W, 1)
  local pl = plots(W, 3)
  for _, p in ipairs(pl) do p.plant_id[0], p.plant_id[2] = 0, 0 end       -- every spring and autumn slot is planted: plump helmets
  days(W, 2)
  T.eq(count(pl, 0, 1), 2, 'two of three planted spring slots turn to quarry bushes (cook_slots 2)')
  T.eq(count(pl, 0, 0), 1, 'the third stays a brew crop')
  T.eq(count(pl, 2, 1), 2, 'and in autumn')
  days(W, 2)
  T.eq(count(pl, 0, 1), 2, 'idempotent: planted cook slots count against the plan, no more swaps')
  pl[3].plant_id[0] = 2                                                 -- MUSHROOM_CUP_DIMPLE (brewed only) is swapped as well
  days(W, 1)
  T.eq(count(pl, 0, 1), 2, 'the cap holds')
end)

T.test('BUG-398: a planted slot is kept with meals for everyone or with no seed of a cook crop in the season', function()
  local W = world{meals = 10}
  days(W, 1)
  local pl = plots(W, 3)
  for _, p in ipairs(pl) do p.plant_id[0] = 0 end
  days(W, 2)
  T.eq(count(pl, 0, 0), 3, 'meals for all: no swap')
  local Wn = world{quarry = false}
  days(Wn, 1)
  local pln = plots(Wn, 3)
  for _, p in ipairs(pln) do p.plant_id[0] = 0 end
  days(Wn, 2)
  T.eq(count(pln, 0, 0), 3, 'no cook seeds: no swap')
end)

T.done()
