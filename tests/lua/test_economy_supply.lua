-- economy: farm season slots (FR-17), forbidden seeds (FR-23), the starvation handler (FR-25) and forbidden
-- drink/food containers of any item type (FR-50).
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

T.test('FR-17: every empty season slot gets a crop that grows then and there (underground all year)', function()
  local under, surf, empty
  local W = world{setup = function(W)
    for _ = 1, 3 do F.item(W, 'SEEDS', {mat_type = 419, mat_index = 60, stack_size = 5}) end
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 4})      -- carrots
    under = plot(W, {0, -1, -1, -1})
    surf = plot(W, {-1, 1, -1, -1})                                             -- strawberries in summer
    empty = plot(W, {-1, -1, -1, -1})                                           -- unknown biome: left to autofarm
  end}
  days(W, 1)
  T.eq({under.plant_id[1], under.plant_id[2], under.plant_id[3]}, {0, 0, 0}, 'plump helmets all year')
  T.eq(surf.plant_id[0], 2, 'spring: carrots (seeds in stock, grows in spring)')
  T.eq(surf.plant_id[2], 1, 'autumn: the plot\'s own strawberries')
  T.eq(surf.plant_id[3], -1, 'winter: no surface crop grows')
  T.eq({empty.plant_id[0], empty.plant_id[3]}, {-1, -1})
  local ci = W.K.census.i
  -- BUG-058: the slot of the running season (spring) was filled at once by T.slotnow; the daily fill counts the other 9
  T.eq({ci.farm_plots, ci.farm_empty}, {3, 9}, 'counted before the daily fill')
  days(W, 1)
  T.eq(W.K.census.i.farm_empty, 5, 'the empty plot (4) and winter on the surface plot (1)')
end)

T.test('FR-23: seeds in a forbidden bag are unusable; bag and seeds are unforbidden on known reachable tiles', function()
  local bag, hidden, loose
  local W = world{setup = function(W)
    bag = F.item(W, 'TOOL', {flags = {forbid = true}, _pos = {5, 5, 100}})
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 60, stack_size = 7, _cont = bag, _pos = {5, 5, 100}})
    hidden = F.item(W, 'TOOL', {flags = {forbid = true}, _pos = {66, 5, 100}})
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 61, stack_size = 2, _cont = hidden, _pos = {66, 5, 100}})
    loose = F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 3, flags = {forbid = true}, _pos = {6, 6, 100}})
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 1})
  end}
  settle(W)
  local ci = W.K.census.i
  T.eq({ci.seeds_ok, ci.seeds_forb}, {1, 12})
  T.eq(bag.flags.forbid, false)
  T.eq(loose.flags.forbid, false)
  T.eq(hidden.flags.forbid, true, 'a hidden tile is never touched')
  days(W, 1)
  T.eq(W.K.census.i.seeds_ok, 11)
end)

T.test('FR-50: drink in a forbidden TOOL pot counts as forbidden; the pot is unforbidden (PEACE only)', function()
  local function run(mode)
    local pot
    local W = world{mode = mode, setup = function(W)
      pot = F.item(W, 'TOOL', {flags = {forbid = true}, _pos = {7, 7, 100}})
      F.item(W, 'DRINK', {stack_size = 30, _cont = pot, _pos = {7, 7, 100}})
      local cave = F.item(W, 'TOOL', {flags = {forbid = true}, _pos = {99, 7, 100}})
      F.item(W, 'DRINK', {stack_size = 10, _cont = cave, _pos = {99, 7, 100}})
    end}
    settle(W)
    return W, pot
  end
  local W, pot = run()
  T.eq(W.K.census.i.drink_forb, 40)
  T.eq(pot.flags.forbid, false)
  local n = 0
  for _, a in ipairs(W.find_acts('item_flag')) do if a.args[1] == pot.id then n = n + 1 end end
  T.eq(n, 1)
  T.eq(#W.find_acts('item_flag'), 1, 'the pot in the cut-off cave stays')
  local W2, pot2 = run('SIEGE')
  T.eq(#W2.find_acts('item_flag'), 0)
  T.eq(pot2.flags.forbid, true)
end)

T.test('FR-25: starvation marks shrubs, staffs gatherers and planters, unforbids food, names who is cut off', function()
  local ctl = {}
  local W = world{cit = 6, food = 1, starve_days = 10, hungry = {[1] = 60000, [3] = 70000},
                  setup = function(W)
    ctl.planters = {name = 'Planters', assigned_units = kmock.vec{}, allowed_labors = {}, flags = {mode = 3}}
    ctl.gather = {name = 'Plant gatherers', assigned_units = kmock.vec{5}, allowed_labors = {}, flags = {mode = 3}}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.planters, ctl.gather}}
    W.act_result('work_detail', function(name, id, on)
      local wd = name == 'Planters' and ctl.planters or ctl.gather
      wd.assigned_units:insert('#', id)
      return true, 'added'
    end)
    plot(W, {0, 0, 0, 0})
    local function shrub(x, mat) return {pos = {x = x, y = 3, z = 100}, material = mat} end
    df.global.world.plants = {shrub_dry = kmock.vec{shrub(20, 0), shrub(21, 1), shrub(66, 0), shrub(99, 0)},
                              shrub_wet = kmock.vec{shrub(22, 0)}}
    ctl.marked = {}
    dfhack.designations = {isPlantMarked = function(p) return p.pos.x == 22 end,
                           markPlant = function(p) ctl.marked[#ctl.marked + 1] = p.pos.x; return true end}
    W.act_result('plant_gather', function(list) ctl.cand = list; return true, #list end)
    ctl.meat = F.item(W, 'MEAT', {flags = {forbid = true}, _pos = {8, 8, 100}, mat_type = 37, mat_index = 0})
    F.mat(W, 37, 0, {token = 'CREATURE:CAMEL_2_HUMP:MUSCLE', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  end}
  days(W, 1)
  T.eq(ctl.cand, {{20, 3, 100}}, 'edible, revealed, reachable, not yet marked (plump helmet only)')
  local pl, ga = {}, {}
  for _, id in ipairs(ctl.planters.assigned_units) do pl[#pl + 1] = id end
  for _, id in ipairs(ctl.gather.assigned_units) do ga[#ga + 1] = id end
  T.eq(#pl, 4, 'planters up to 4 (farm plots exist)')
  T.eq(#ga, 4, 'gatherers up to 4 (one was there)')
  local wd = W.find_events('WORK_DETAIL')
  T.eq(wd[1].d.why, 'starvation')
  T.eq(ctl.meat.flags.forbid, false, 'forbidden food unforbidden in a starvation')
  local dn
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'starvation' then dn = e end end
  T.ok(dn, 'starvation report')
  T.ok(dn.msg:find('2 hungry', 1, true), dn.msg)
  T.ok(dn.d.q:find('cannot reach food: Urist 3', 1, true), dn.d.q)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq({r.data.starve.hungry, r.data.starve.cut, r.data.starve.cut_units}, {2, 1, {3}})
  days(W, 1)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'starvation' then n = n + 1 end end
  T.eq(n, 1, 'every report_days')
end)

T.test('FR-25: nothing without hungry citizens, and no work details in modern labormanager mode', function()
  local W = world{food = 1, starve_days = 10, setup = function(W)
    df.global.world.plants = {shrub_dry = kmock.vec{{pos = {x = 20, y = 3, z = 100}, material = 0}}, shrub_wet = kmock.vec{}}
    W.act_result('plant_gather', function(list) return true, #list end)
  end}
  days(W, 1)
  T.eq(#W.find_acts('plant_gather'), 0)
  T.eq(W.K.persist.get('m.economy').starve, nil)
  local W2 = world{food = 1, starve_days = 10, hungry = {[2] = 60000}, setup = function(W2)
    df.global.world.plants = {shrub_dry = kmock.vec{{pos = {x = 20, y = 3, z = 100}, material = 0}}, shrub_wet = kmock.vec{}}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{
      {name = 'Plant gatherers', assigned_units = kmock.vec{}, allowed_labors = {}, flags = {mode = 3}}}}
    W2.act_result('plant_gather', function(list) return true, #list end)
    W2.act_result('run', function(cmd, a1)
      if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: modern (labormanager)' end
      return true, ''
    end)
  end}
  days(W2, 1)
  T.eq(#W2.find_acts('plant_gather'), 1)
  T.eq(#W2.find_acts('work_detail'), 0, 'labormanager (modern) owns the details')
end)

-- BUG-058 (Run 13 y512/y513, Wheelsblows: 8 plots stood at -1 for the running season for weeks, autofarm emptied the slots
-- the kernel set within 30 s, the new plots on z149 held surface crops and made no PlantSeeds job): the slots of the
-- running season are filled at once (T.slotnow), the edible crops first when food is low, a crop of the wrong kind for the
-- plot's tile is replaced, and autofarm steps aside (disable) when it works against the kernel.
local SURFACE = {hidden = false, outside = true, subterranean = false}
local UNDER = {hidden = false, outside = false, subterranean = true}
local function tiles(by_z) TILES = by_z end            -- plot level -> tile flags (snapshot.plot_under above reads them)
local function crop_world(opts)
  opts = opts or {}
  opts.setup = function(W)
    df.global.world.raws.plants.all = kmock.vec{
      raw('MUSHROOM_HELMET_PLUMP', SEASONS, 1),                         -- 0: underground, all year
      raw('STRAWBERRY', {SPRING = true, SUMMER = true, AUTUMN = true}), -- 1: surface
      raw('CARROT', SEASONS),                                           -- 2: surface, all year, edible
      raw('MADDER', SEASONS),                                           -- 3: surface, all year, a dye (no food)
      raw('TURNIP', SEASONS),                                           -- 4: surface
      raw('GRASS_WHEAT_CAVE', SEASONS, 1)}                              -- 5: underground
    df.global.world.raws.plants.all[2].growths = kmock.vec{{mat_type = 419, mat_index = 63}}
    F.mat(W, 419, 63, {token = 'PLANT:CARROT:ROOT', flags = {EDIBLE_RAW = true}})
    F.mat(W, 419, 64, {token = 'PLANT:MADDER:SEED'})
    F.mat(W, 419, 65, {token = 'PLANT:GRASS_WHEAT_CAVE:SEED'})
    if opts.plots then opts.plots(W) end
  end
  return world(opts)
end

T.test('BUG-058: the running season\'s slot of an all-empty plot is filled at once from the plot\'s tile; edible crops first ' ..
       'when food is low', function()
  local function run(food)
    local plot_, W
    W = crop_world{food = food, plots = function(W)
      tiles({[100] = SURFACE})
      F.item(W, 'SEEDS', {mat_type = 419, mat_index = 64, stack_size = 50})         -- madder: the most seeds
      F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 4})          -- carrot (mat 62 = CARROT seed)
      plot_ = plot(W, {-1, -1, -1, -1})
    end}
    days(W, 1)
    return W, plot_
  end
  local W, p1 = run(500)
  T.eq(p1.plant_id[0], 3, 'food fine: the crop with the most seeds that grows now (madder)')
  T.ok(#logs_like(W, 'slots of the running season filled at once') == 1, 'one kern.log line')
  local W2, p2 = run(1)
  T.eq(p2.plant_id[0], 2, 'food low: the edible carrot first')
end)

T.test('BUG-058: surface crops on an underground plot are replaced by crops that grow underground; the surface plot stays',
       function()
  local under, surf
  local W = crop_world{plots = function(W)
    tiles({[90] = UNDER, [100] = SURFACE})
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 65, stack_size = 9})            -- cave wheat
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 60, stack_size = 5})            -- plump helmet
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 4})
    under = F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 90, plant_id = {[0] = 4, 2, -1, 1},
                                        getType = function() return df.building_type.FarmPlot end})
    surf = plot(W, {2, 2, 2, 2})
  end}
  days(W, 1)
  for s = 0, 3 do
    local pid = under.plant_id[s]
    T.ok(pid == 0 or pid == 5, string.format('slot %d of the underground plot holds %s', s, tostring(pid)))
  end
  T.eq({surf.plant_id[0], surf.plant_id[1], surf.plant_id[2], surf.plant_id[3]}, {2, 2, 2, 2}, 'the surface plot is right')
end)

T.test('BUG-058: autofarm is disabled below af_off_days food days, enabled again from af_on_days after af_hold_days; ' ..
       'keep never touches it', function()
  local W = crop_world{food = 1, plots = function(W) tiles({[100] = SURFACE}); plot(W, {2, -1, -1, -1}) end}
  days(W, 2)
  local n = 0
  for _, l in ipairs(F.runs(W)) do if l == 'disable autofarm' then n = n + 1 end end
  T.eq(n, 1, 'one disable autofarm')
  T.ok(#logs_like(W, 'autofarm disabled (food') == 1, 'logged once')
  for _, l in ipairs(F.runs(W)) do T.ok(l:sub(1, 17) ~= 'autofarm threshold', l) end
  W.add_food = F.item(W, 'FOOD', {stack_size = 3000, subtype = 1})
  days(W, 10)
  for _, l in ipairs(F.runs(W)) do T.ok(l ~= 'enable autofarm' or false, 'held 14 days: not yet') end
  days(W, 6)
  local e = 0
  for _, l in ipairs(F.runs(W)) do if l == 'enable autofarm' then e = e + 1 end end
  T.eq(e, 1, 'food back and held: enabled again')
  local Wk = crop_world{food = 1, cfg = function(c) c.economy.farms.autofarm = 'keep' end,
                        plots = function(W) tiles({[100] = SURFACE}); plot(W, {2, -1, -1, -1}) end}
  days(Wk, 2)
  for _, l in ipairs(F.runs(Wk)) do T.ok(l ~= 'disable autofarm', 'keep') end
end)

T.test('BUG-058: a slot the kernel filled and autofarm emptied again switches autofarm off (evidence); twice: for good',
       function()
  local pl
  local W = crop_world{food = 500, plots = function(W)
    tiles({[100] = SURFACE})
    F.item(W, 'SEEDS', {mat_type = 419, mat_index = 62, stack_size = 4})
    pl = plot(W, {-1, -1, -1, -1})
  end}
  days(W, 1)
  T.eq(pl.plant_id[0], 2)
  for _, l in ipairs(F.runs(W)) do T.ok(l ~= 'disable autofarm', 'food fine, nothing wiped yet') end
  pl.plant_id[0] = -1                                           -- autofarm: nothing short, no crop
  days(W, 1)
  local n = 0
  for _, l in ipairs(F.runs(W)) do if l == 'disable autofarm' then n = n + 1 end end
  T.eq(n, 1)
  T.ok(#logs_like(W, 'slots it emptied or changed again') >= 1, 'the log names the cause')
  T.eq(pl.plant_id[0], 2, 'and the slot is filled again')
  T.eq(W.K.persist.get('m.economy').af.wiped, 1)
  local function count(what)
    local k = 0
    for _, l in ipairs(F.runs(W)) do if l == what then k = k + 1 end end
    return k
  end
  F.item(W, 'FOOD', {stack_size = 3000, subtype = 1})            -- food back: autofarm is allowed again after 14 days
  days(W, 20)
  T.eq(count('enable autofarm'), 1)
  pl.plant_id[0] = -1                                           -- emptied a second time
  days(W, 1)
  T.eq(count('disable autofarm'), 2)
  T.eq(W.K.persist.get('m.economy').af.wiped, 2)
  days(W, 30)
  T.eq(count('enable autofarm'), 1, 'wiped twice: autofarm stays off')
end)

T.test("BUG-058: farms.autofarm 'off' disables autofarm at the first run, whatever the food", function()
  local W = crop_world{food = 500, cfg = function(c) c.economy.farms.autofarm = 'off' end,
                       plots = function(W) tiles({[100] = SURFACE}); plot(W, {2, -1, -1, -1}) end}
  days(W, 1)
  local n = 0
  for _, l in ipairs(F.runs(W)) do if l == 'disable autofarm' then n = n + 1 end end
  T.eq(n, 1)
  days(W, 3)
  n = 0
  for _, l in ipairs(F.runs(W)) do if l == 'disable autofarm' then n = n + 1 end end
  T.eq(n, 1, 'once')
end)

T.test('BUG-058: a wrong-kind crop is replaced only when the right kind has usable seeds', function()
  local under
  local W = crop_world{plots = function(W)
    tiles({[90] = UNDER})
    under = F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 90, plant_id = {[0] = 4, 2, -1, 1},
                                        getType = function() return df.building_type.FarmPlot end})
  end}
  days(W, 1)
  T.eq({under.plant_id[0], under.plant_id[1], under.plant_id[3]}, {4, 2, 1}, 'no cave seeds: the crops stay as they are')
end)

T.done()
