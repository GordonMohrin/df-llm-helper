-- FR-62 test world: a fort the size of Run 9 (402 units, 18.7k items, 5 citizens) for the REAL kernel
-- (tests/lua/kern_world.lua) with the WP8 fakes (economy, care and baseline run for real), plus model
-- modules whose cost per call follows the live profile of STATUS §0h (cost clock = W.ms, deterministic).
--   local L = require('load_world')
--   local W = L.world{tag = 'x'}                      -- units and items; F.install done
--   local mods = L.model(W)                           -- stand-ins for sense, reflex, seal, economy, care, baseline
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local L = {}

-- the unit mix (402): 5 citizens, 160 tame animals, 60 wild animals, 15 visitors, 162 dead units
L.MIX = {citizens = 5, tame = 160, wild = 60, visitors = 15, dead = 162}
-- items per items.other category (census categories of economy/seal and others), 18,700 in items.all
L.ITEMS = {BOULDER = 5000, CORPSEPIECE = 2500, DRINK = 1400, WOOD = 800, PLANT = 900, SEEDS = 700, MEAT = 600,
           PLANT_GROWTH = 500, FOOD = 400, BARREL = 400, BAR = 300, ROUGH = 300, AMMO = 300, WEAPON = 300,
           CLOTH = 300, THREAD = 200, BIN = 200, SMALLGEM = 200, SKIN_TANNED = 150, ARMOR = 150, SHOES = 150,
           HELM = 100, PANTS = 100, GLOVES = 100, FISH = 100, SHIELD = 80, CHEESE = 50, EGG = 50,
           COFFIN = 243, TABLE = 300, CHAIR = 300, DOOR = 150, BED = 120, FIGURINE = 400, BLOCKS = 900}

function L.units(mix)
  mix = mix or L.MIX
  local r, id = {}, 0
  local function add(spec) id = id + 1; spec.id = id; spec.pos = spec.pos or {10 + id % 50, 10 + id // 50, 100}; r[#r + 1] = spec end
  for _ = 1, mix.citizens do add{citizen = true, adult = true, race = 1, caste = 0} end
  for _ = 1, mix.tame do add{tame = true, animal = true, race = 10, caste = 0} end
  for i = 1, mix.wild do add{animal = true, race = 20 + i % 4, caste = i % 2} end
  for _ = 1, mix.visitors do add{visitor = true, race = 2, caste = 0} end
  for i = 1, mix.dead do add{dead = true, race = i % 2 == 0 and 1 or 10, caste = 0} end
  return r
end

function L.world(opts)
  opts = opts or {}
  local W = H.world{tag = opts.tag or 'load', units = L.units(opts.mix), ms_per_frame = opts.ms_per_frame or 10}
  F.install(W)
  for _, u in ipairs(df.global.world.units.active) do u.race, u.caste = u._m.race, u._m.caste end   -- DF unit fields
  for id = 1, (opts.mix or L.MIX).citizens do
    local u = W.unit(id)
    u.job, u.mood = {current_job = nil}, -1
    u.inventory = kmock.vec{}
    u.status = {current_soul = {personality = {emotions = kmock.vec{}}}}
  end
  -- raws for sense's LARGE_PREDATOR check (none of the wild races is one)
  local raws = {}
  for race = 0, 30 do raws[race] = {caste = {[0] = {flags = {}}, [1] = {flags = {}}}} end
  df.creature_raw = {find = function(race) return raws[race] end}
  W.raw_finds = 0
  local find = df.creature_raw.find
  df.creature_raw.find = function(race) W.raw_finds = W.raw_finds + 1; return find(race) end
  local all = df.global.world.items.all
  local n = 0
  local cats = {}
  for cat in pairs(opts.items or L.ITEMS) do cats[#cats + 1] = cat end
  table.sort(cats)
  for _, cat in ipairs(cats) do
    for i = 1, (opts.items or L.ITEMS)[cat] do
      local it = F.item(W, cat, {stack_size = 1 + i % 5, mat_type = 0, mat_index = i % 7, _pos = {20, 20, 100}})
      all:insert('#', it)
      n = n + 1
    end
  end
  W.n_items = n
  return W
end

-- count calls of the dfhack.units predicates (the cost driver of sense's per-unit scan)
function L.count_unit_calls(W)
  local U = dfhack.units
  W.unit_calls = 0
  for name, f in pairs(U) do
    if type(f) == 'function' and name:match('^is') then
      U[name] = function(...) W.unit_calls = W.unit_calls + 1; return f(...) end
    end
  end
end

---------------------------------------------------------------- model modules (cost clock = W.ms)
-- The live Run 9 profile before FR-62 (doctor, STATUS §0h): seal 37, sense 16, economy 12-14, care 3,
-- baseline 3, reflex 1.7 ms/s at ~100 frames/s and ~450 ticks/s; the kernel's own housekeeping (kern 11) is
-- modelled as k_house below (booked as a critical test module, so pacing cannot hide it).
-- per-call costs (ms) of the stand-ins. `post` (L.model{post = true}) = sense and the kernel's housekeeping after
-- FR-62, scaled by what load_bench.lua measured on this interpreter for the real code (sense -42 %: inactive
-- units skipped, predator raws cached, entrances on demand; kern + k.* -52 %: a module's big persist record
-- booked to it and written at most every 60 s). An estimate for DF, not a measurement there.
L.COST = {
  sense_unit = 0.004, sense_unit_post = 0.0023, reflex = 0.055, kern_frame = 0.11, kern_frame_post = 0.055,
  seal_slice = 0.4,                     -- seal: a job slice per frame (CFG.work 800), always a job pending
  eco_slice = 0.5, eco_per_slice = 200, eco_run = 4,     -- census slices of 200 items, then the run (< 5 ms each)
  care_run = 4.5, care_slices = 2, base_task = 4,
}

function L.model(W, opts)
  opts = opts or {}
  local c = L.COST
  local units = #df.global.world.units.active
  local function spend(ms) W.ms = W.ms + ms end
  local sense = {name = 'sense', every = {ticks = 9}, critical = true, scans = 0}
  local unit_ms = opts.post and c.sense_unit_post or c.sense_unit
  function sense.step(K)
    K.census.u = K.census.u or {units = units, cit = L.MIX.citizens}   -- the visible-unit count of the load
    local t = K.now().tick
    if not sense.h or t - sense.h >= 45 then sense.h, sense.scans = t, sense.scans + 1; spend(units * unit_ms) end
  end
  local reflex = {name = 'reflex', every = {ticks = 10}, critical = true}
  function reflex.step() spend(c.reflex) end
  local seal = {name = 'seal', every = {ticks = 50}, slices = 0}
  function seal.step() seal.slices = seal.slices + 1; spend(c.seal_slice); return 'more' end
  local in_cats = 0
  for _, cat in ipairs({'DRINK', 'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH', 'CLOTH', 'SKIN_TANNED',
                        'CORPSEPIECE', 'SMALLGEM', 'ROUGH', 'BAR', 'AMMO', 'WOOD', 'BARREL', 'BIN', 'BOULDER', 'THREAD',
                        'SEEDS', 'WEAPON', 'ARMOR', 'HELM', 'PANTS', 'GLOVES', 'SHOES', 'SHIELD'}) do
    in_cats = in_cats + #df.global.world.items.other[cat]
  end
  local economy = {name = 'economy', every = {ticks = 1200}, runs = 0}
  function economy.step(K, b, ctx)
    economy.left = (ctx and ctx.cont) and economy.left or (in_cats // c.eco_per_slice + 1)
    if not (ctx and ctx.cont) then economy.runs = economy.runs + 1 end
    economy.left = economy.left - 1
    spend(economy.left > 0 and c.eco_slice or c.eco_run)
    if economy.left > 0 then return 'more' end
  end
  local care = {name = 'care', every = {ticks = 1200}, runs = 0}
  function care.step(K, b, ctx)
    if not (ctx and ctx.cont) then care.runs = care.runs + 1 end
    spend(c.care_run)
    if (ctx and ctx.slice or 1) < c.care_slices then return 'more' end
  end
  local baseline = {name = 'baseline', every = {ticks = 600}}
  function baseline.step() spend(c.base_task) end
  local house = {name = 'test_house', every = {ticks = 1}, critical = true}
  local house_ms = opts.post and c.kern_frame_post or c.kern_frame
  function house.step() spend(house_ms) end
  return {sense = sense, reflex = reflex, seal = seal, economy = economy, care = care, baseline = baseline, house = house}
end

-- per-owner ms per real second of the last perf.csv rows (mods field), plus the row totals
function L.profile(W, rows)
  local lines = H.lines(W.sd .. '/perf.csv')
  local n, sum, mods = 0, 0, {}
  for i = math.max(2, #lines - (rows or 4) + 1), #lines do
    local f = {}
    for x in (lines[i] .. ','):gmatch('([^,]*),') do f[#f + 1] = x end
    n, sum = n + 1, sum + tonumber(f[8])
    for k, v in f[11]:gmatch('([^=;]+)=(%-?%d+)') do mods[k] = (mods[k] or 0) + tonumber(v) end
  end
  local per_s = {}
  for k, v in pairs(mods) do per_s[k] = v / (n * 30) end
  return {ms_s = n > 0 and sum / n or 0, mods = per_s, rows = n}
end

return L
