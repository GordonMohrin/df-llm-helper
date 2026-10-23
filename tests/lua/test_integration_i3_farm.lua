-- Integration audit I3: autofarm off for good (BUG-058) x the thread and cloth chain (FR-73).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local SEASONS = {SPRING = true, SUMMER = true, AUTUMN = true, WINTER = true}
local TILES = {}
local function raw(id, flags, depth)
  local f = {SEED = true}
  for k, v in pairs(flags) do f[k] = v end
  return {id = id, flags = f, underground_depth_min = depth or 0, growths = kmock.vec{}}
end

local function world(opts)
  opts = opts or {}
  local cit = opts.cit or 6
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  if opts.starve_days then cfg.economy.starve.days = opts.starve_days end
  if opts.cfg then opts.cfg(cfg) end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = opts.mode}
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = (opts.hungry or {})[i] or 0}
  end
  W.set_census('u', F.census_u(ids))
  df.global.world.raws.plants.all = kmock.vec{
    raw('MUSHROOM_HELMET_PLUMP', SEASONS, 1),                         -- 0: underground, all year
    raw('STRAWBERRY', {SUMMER = true, AUTUMN = true}),                -- 1: surface, summer and autumn
    raw('CARROT', {SPRING = true, SUMMER = true}),                    -- 2: surface, spring and summer
    raw('PINE', {TREE = true, SPRING = true})}                        -- 3: a tree, never a crop
  F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
  F.mat(W, 419, 61, {token = 'PLANT:STRAWBERRY:SEED'})
  F.mat(W, 419, 62, {token = 'PLANT:CARROT:SEED'})
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true}})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  if opts.food ~= false then F.item(W, 'FOOD', {stack_size = opts.food or 500, subtype = 1, _pos = {1, 1, 100}}) end
  W.act_result('farm_crop', function(id, s, crop)
    local b = W.buildings[id]
    b.plant_id[s] = crop
    return true, crop
  end)
  W.act_result('item_flag', function(id, flag, on)
    local it = W.items_by_id[id]
    it.flags[flag] = on
    return true
  end)
  if opts.snapshot ~= false then
    W.load({name = 'snapshot', every = {ticks = 100},
            tile = function(K, x, y, z) if x == 66 then return nil end return {c = '.'} end,   -- x 66: hidden
            far = function(K, x, y, z) return x == 99 end,                                 -- x 99: cut off
            reach = function(K, a, b) return a.x ~= 13 end,                              -- unit 3 is shut in
            -- BUG-058: the plot's tile (snapshot.plot_under): under the open sky, subterranean, or unknown (no entry)
            plot_under = function(K, x, y, z)
              local t = TILES[z]
              if not t or t.hidden then return nil end
              if t.outside then return false end
              return t.subterranean == true
            end})
  end
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W
end

local function logs_like(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then r[#r + 1] = l.msg end end
  return r
end
local function settle(W) for _ = 1, 80 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function plot(W, crops)
  local p = {[0] = crops[1], [1] = crops[2], [2] = crops[3], [3] = crops[4]}
  return F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 100, plant_id = p,
                                     getType = function() return df.building_type.FarmPlot end})
end

local SURFACE = {hidden = false, outside = true, subterranean = false}
local UNDER = {hidden = false, outside = false, subterranean = true}
local function tiles(by_z) TILES = by_z end            -- plot level -> tile flags (snapshot.plot_under above reads them)
local function crop_world(opts)
  opts = opts or {}
  opts.setup = function(W)
    W.load({name = 'runner', every = {ticks = 600}, state = function() return {phase = 'P3'} end})   -- mood_from_phase P1
    df.global.world.raws.plants.all = kmock.vec{
      raw('MUSHROOM_HELMET_PLUMP', SEASONS, 1),                         -- 0: underground, all year
      raw('STRAWBERRY', {SPRING = true, SUMMER = true, AUTUMN = true}), -- 1: surface
      raw('CARROT', SEASONS),                                           -- 2: surface, all year, edible
      raw('MADDER', SEASONS),                                           -- 3: surface, all year, a dye (no food)
      raw('TURNIP', SEASONS),                                           -- 4: surface
      raw('GRASS_WHEAT_CAVE', SEASONS, 1),                              -- 5: underground
      raw('FLAX', SEASONS)}                                              -- 6: a fiber crop (thread), surface
    df.global.world.raws.plants.all[2].growths = kmock.vec{{mat_type = 419, mat_index = 63}}
    F.mat(W, 419, 63, {token = 'PLANT:CARROT:ROOT', flags = {EDIBLE_RAW = true}})
    F.mat(W, 419, 64, {token = 'PLANT:MADDER:SEED'})
    F.mat(W, 419, 65, {token = 'PLANT:GRASS_WHEAT_CAVE:SEED'})
    F.mat(W, 419, 66, {token = 'PLANT:FLAX:SEED'})
    if opts.plots then opts.plots(W) end
  end
  return world(opts)
end

local function plots3(W)
  tiles({[100] = SURFACE})
  F.item(W, 'SEEDS', {mat_type = 419, mat_index = 64, stack_size = 50})         -- madder: the most seeds
  F.item(W, 'SEEDS', {mat_type = 419, mat_index = 66, stack_size = 5})          -- flax
  return {plot(W, {-1, -1, -1, -1}), plot(W, {-1, -1, -1, -1}), plot(W, {-1, -1, -1, -1})}
end
local function count(pl, s, id) local n = 0; for _, p in ipairs(pl) do if p.plant_id[s] == id then n = n + 1 end end return n end

T.test('I3: autofarm off for good and cloth short: farms.fiber_slots empty slots a season take a fiber crop', function()
  local pl
  local W = crop_world{food = 500, cfg = function(c) c.economy.farms.autofarm = 'off' end}
  days(W, 1)                                               -- the plan has seen the cloth deficit (st.cloth)
  pl = plots3(W)
  days(W, 2)
  T.eq(count(pl, 0, 6), 2, 'two of three plots hold flax in spring')
  T.eq(count(pl, 0, 3), 1, 'the third the crop with the most seeds')
  T.eq(count(pl, 2, 6), 2, 'and in autumn')
  T.ok(#logs_like(W, 'autofarm is off') >= 1, 'kern.log names the cloth autofarm does not plant')
  -- the cap holds when the plots already carry fibers; planted slots are never replaced
  pl[3].plant_id[0] = 3
  days(W, 1)
  T.eq(count(pl, 0, 6), 2)
  T.eq(pl[3].plant_id[0], 3)
end)

T.test('I3: no fiber slot in food shortage, with fiber_slots 0, or while autofarm works', function()
  local pl
  local W = crop_world{food = 1, cfg = function(c) c.economy.farms.autofarm = 'off' end}
  days(W, 1)
  pl = plots3(W)
  days(W, 2)
  T.eq(count(pl, 0, 3), 3, 'the plots are planted')
  T.eq(count(pl, 0, 6), 0, 'food low: the edible crops first, no fiber')
  local pl0
  local W0 = crop_world{food = 500, cfg = function(c) c.economy.farms.autofarm = 'off'; c.economy.farms.fiber_slots = 0 end}
  days(W0, 1)
  pl0 = plots3(W0)
  days(W0, 2)
  T.eq(count(pl0, 0, 3), 3, 'the plots are planted')
  T.eq(count(pl0, 0, 6), 0, 'fiber_slots 0')
  local pk
  local Wk = crop_world{food = 500, cfg = function(c) c.economy.farms.autofarm = 'keep' end}
  days(Wk, 1)
  pk = plots3(Wk)
  days(Wk, 2)
  T.eq(count(pk, 0, 3), 3, 'the plots are planted')
  T.eq(count(pk, 0, 6), 0, 'autofarm is on (keep): its business')
end)

T.test('J2: the fiber note repeats after max(7 game days, 10 minutes), not after a game week alone (timestream)', function()
  local W = crop_world{food = 500, cfg = function(c) c.economy.farms.autofarm = 'off' end}
  days(W, 2)
  T.eq(#logs_like(W, 'autofarm is off'), 1, 'the first line goes out at once')
  days(W, 8)                                         -- more than a game week, a few seconds of the wall clock
  T.eq(#logs_like(W, 'autofarm is off'), 1, 'a game week is 19 s at 450 ticks a second: the line waits for the wall clock too')
  W.ms = W.ms + 700 * 1000                           -- ten minutes later
  days(W, 1)
  T.eq(#logs_like(W, 'autofarm is off'), 2, 'then it speaks again')
end)

T.done()
