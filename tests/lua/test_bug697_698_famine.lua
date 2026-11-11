-- BUG-697 (Run 16c i3 Wallfree y431-y433: meals 105 -> 0, pop 49 -> 21, 23 of 30 adults idle, three fishers, four gatherers, 'no cook ingredient (6 raw
-- fish to clean, 5 forbidden)', 'kitchen idle with 5 cook ingredients', the famine decision only repeating): a famine puts the idle adults on the food
-- jobs (fishers, gatherers), frees the loose forbidden food, asks for the farms every 7 days and adds a cook when every holder of the COOK labor is busy.
-- BUG-698: fishers at a zone with no Fish job and no raw fish for dry_days days = fished out: a second zone on other water.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function key(x, y, z) return x .. ',' .. y .. ',' .. z end

T.test('BUG-697: famine_scale: one helper per `per` citizens, never more than the idle adults, never over the cap, never under the base', function()
  local E = fresh('economy')
  T.eq(E.famine_scale(3, 8, 49, 6, 47), 8, '49 citizens, 47 % idle: 9 wanted, 23 idle, the cap 8')
  T.eq(E.famine_scale(3, 8, 49, 6, 0), 3, 'nobody idle: the base')
  T.eq(E.famine_scale(3, 8, 12, 6, 50), 3, '12 citizens: 2 wanted, under the base')
  T.eq(E.famine_scale(4, 10, 49, 5, 47), 10, 'gatherers: 10 wanted, 23 idle')
  T.eq(E.famine_scale(4, 10, 30, 5, 20), 6, '6 idle of 30: 6')
  T.eq(E.famine_scale(0, 0, 49, 5, 90), 0, 'a zero base stays zero')
end)

-- the fishers' world of test_economy_food.lua
local function fish_world(opts)
  local units = {}
  for i = 1, opts.cit do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, opts.cit do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          lost = function() return 0 end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor (labormanager)' end
    return true, ''
  end)
  local wd = {name = 'Fisherdwarves', assigned_units = kmock.vec({}), allowed_labors = {[0] = false, [4] = true}, flags = {mode = 3}}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{wd}}
  W.act_result('work_detail', function(name, id, on)
    local v = wd.assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  df.civzone_type.FishingArea, df.civzone_type[85] = 85, 'FishingArea'
  F.building(W, 'ANY_ZONE', {type = 85, x1 = 0, y1 = 0, x2 = 9, y2 = 9, z = 1})
  F.item(W, 'FOOD', {stack_size = opts.food or 5, subtype = 1})
  W.load(fresh('economy'))
  for i = 1, opts.cit do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
  end
  for i = 1, opts.idle or 0 do W.unit(i).job = nil end
  return W, wd
end

T.test('BUG-697 Wallfree: a famine with 40 of 53 citizens idle puts 8 on the fishing detail, not 3; busy citizens: the old 3', function()
  local W, wd = fish_world{cit = 53, food = 5, idle = 40}
  settle(W)
  days(W, 3)
  T.eq(#wd.assigned_units, 8, 'famine: one per 6 citizens, at most 8, the idle adults are there')
  local W2, wd2 = fish_world{cit = 53, food = 5, idle = 0}
  settle(W2)
  days(W2, 3)
  T.eq(#wd2.assigned_units, 3, 'nobody idle: the old target')
  local W3, wd3 = fish_world{cit = 53, food = 26, idle = 40}
  settle(W3)
  days(W3, 3)
  T.eq(#wd3.assigned_units, 3, 'food short but no famine (20 days): the old target')
end)

-- the cook world of test_bug629_630_cook.lua
local function cook_world(o)
  local cit = o.cit or 10
  local units, ids = {}, {}
  for i = 1, cit do units[i] = {id = i, citizen = true}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, cit do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.unit_labor = {COOK = 5, [5] = 'COOK', PLANT = 1, [1] = 'PLANT'}
  df.job_skill = df.job_skill or {}
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 53, {token = 'PLANT:PEACH:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, state = function() return {phase = 'P3'} end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.workshop(W, 'Kitchen')
  F.item(W, 'PLANT_GROWTH', {stack_size = 400, mat_type = 419, mat_index = 53})
  F.item(W, 'PLANT', {stack_size = 300, mat_type = 419, mat_index = 50})
  for i = 1, cit do W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = i <= 1 and 60000 or 1000} end
  W.load(fresh('economy'))
  for i = 1, cit do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
    u.military = {squad_id = -1}
  end
  W.unit(1).status.labors[5] = true          -- the one holder of the COOK labor
  return W
end

T.test('BUG-697 Wallfree: a COOK holder with a job elsewhere and a hungry fort: at the stall one more cook (the idle adult), not "held"', function()
  local W = cook_world{cit = 10}
  W.unit(3).job = nil
  local sets = {}
  W.act_result('labor_set', function(id, which, on) sets[#sets + 1] = {id, which, on}; return true, 'enabled' end)
  days(W, 10)
  T.eq(sets[1], {3, 'cook', true}, 'the holder (unit 1) is busy: the idle adult is the second cook')
  local l
  for _, g in ipairs(W.logs) do if tostring(g.msg):find('Cooking labor on for unit 3', 1, true) then l = g end end
  T.ok(l, 'kern.log says it')
  -- the holder stands idle at the kitchen: he is the cook, no one is added
  local W2 = cook_world{cit = 10}
  W2.unit(1).job = nil
  W2.unit(3).job = nil
  local sets2 = {}
  W2.act_result('labor_set', function(id, which, on) sets2[#sets2 + 1] = {id, which, on}; return true, 'enabled' end)
  days(W2, 10)
  T.eq(sets2, {}, 'an idle holder: the order or the kitchen is the cause, not the labor')
end)

-- the supply world of test_economy_supply.lua (forbidden food)
local function forbid_world(food_items)
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  local foods = {}
  for i = 1, food_items do
    foods[#foods + 1] = F.item(W, 'FOOD', {stack_size = 2, subtype = 1, flags = {forbid = true}, _pos = {5 + i, 6, 100}})
  end
  W.act_result('item_flag', function(id, flag, on)
    W.items_by_id[id].flags[flag] = on
    return true
  end)
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, far = function() return false end})
  W.load(fresh('economy'))
  return W, foods
end

T.test('BUG-697 Wallfree: 5 loose forbidden food items and no usable food (famine): freed although nobody is starving yet', function()
  local W, foods = forbid_world(5)
  days(W, 3)
  local left = 0
  for _, it in ipairs(foods) do if it.flags.forbid then left = left + 1 end end
  T.eq(left, 0, 'the famine frees them (old code: stayed forbidden "by hand" in PEACE)')
end)

T.test('BUG-697: with food enough (no famine) the loose forbidden food stays (it may be the player own)', function()
  local W, foods = forbid_world(5)
  F.item(W, 'FOOD', {stack_size = 600, subtype = 1, _pos = {1, 1, 100}})
  days(W, 3)
  local left = 0
  for _, it in ipairs(foods) do if it.flags.forbid then left = left + 1 end end
  T.eq(left, 5)
end)

-- the farms world of test_economy_food.lua
T.test('BUG-697: in a famine the farms are asked for again after 7 days, not 14', function()
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          lost = function() return 0 end})
  W.act_result('run', function() return true, '' end)
  F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 4, y2 = 6})          -- 35 tiles: enough, a famine wants one more
  W.load(fresh('economy'))
  for i = 1, 10 do W.unit(i).status.labors, W.unit(i).mood = {}, -1 end
  settle(W)
  days(W, 2)
  local function n()
    local c = 0
    for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'farms' then c = c + 1 end end
    return c
  end
  T.eq(n(), 1)
  days(W, 4)
  T.eq(n(), 1, '6 days since: not yet')
  days(W, 3)
  T.eq(n(), 2, '9 days since: the famine asks again (old: 14)')
end)

T.test('BUG-698 Wallfree: fish_dry counts the days fishers stand at a zone with no Fish job and no raw fish; a Fish job or raw fish resets it', function()
  local E = fresh('economy')
  local c = {fishing = {dry_days = 3}, food = {want_days = 90}, fish = {min = 5}}
  local r = {p = {famine = {}}, inv = {fish_raw = 0}, days = {food_d = 5}, now = 0}
  local function day(d, zone, fishers, jobs, raw)
    r.now, r.inv.fish_raw = d * 1200, raw or 0
    return E.fish_dry(c, r, zone, fishers, jobs)
  end
  T.eq({day(1, true, 2, 0), day(2, true, 2, 0), day(3, true, 2, 0)}, {false, false, false}, 'three days: not yet (dry_days 3 counts days past the first)')
  T.eq(day(4, true, 2, 0), true, 'dry for 3 days after the first')
  T.eq(day(5, true, 2, 1), false, 'a Fish job: reset')
  T.eq(r.p.fishdry, nil)
  T.eq(day(6, true, 2, 0), false)
  T.eq(day(7, true, 2, 0, 50), false, 'raw fish in the fort: the fishers fish')
  T.eq(day(8, true, 0, 0), false, 'nobody on the detail')
  T.eq(day(9, false, 2, 0), false, 'no zone')
  r.days.food_d, r.p.famine = 500, nil
  T.eq(day(10, true, 2, 0), false, 'food enough: the fishers are not wanted')
end)

-- the fishing-zone world of test_economy_fishing.lua, with a Fisherdwarves detail
local function zone_world(o)
  local ctl = {water = o.water, tiles = o.tiles, zones = {}, liq = 0}
  local units = {}
  for i = 1, 20 do units[i] = {id = i, citizen = true, pos = {50, 50, 100}} end
  local bc = F.cfg()
  bc.economy.fishing = {r = 48, levels = 6, tiles = 1500, min_flow = 2, side = 3, scan_days = 7, reads = 200, checks = 160,
                        max_water = 3000, dry_days = o.dry_days or 3}
  local W = F.world{cfg = {baseline = bc}, units = units}
  local ids = {}
  for i = 1, 20 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.civzone_type.FishingArea, df.civzone_type[85] = 85, 'FishingArea'
  df.unit_labor = {COOK = 7, [7] = 'COOK'}
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 4000})
  F.item(W, 'FOOD', {stack_size = 26, subtype = 1})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          lost = function() return 0 end})
  W.load({name = 'snapshot', every = {ticks = 100},
          liquids = function(K, x0, y0, x1, y1, z, min, ice)
            local out = {}
            for _, t in ipairs(ctl.water) do
              if t[3] == z and t[1] >= x0 and t[1] <= x1 and t[2] >= y0 and t[2] <= y1 and t[4] >= min then
                out[#out + 1] = {t[1], t[2], t[4], 0, ice and 0 or nil}
              end
            end
            return out
          end,
          tile = function(K, x, y, z)
            local t = ctl.tiles[key(x, y, z)]
            if t then return t end
            for _, w in ipairs(ctl.water) do
              if w[1] == x and w[2] == y and w[3] == z then return {c = '~', flow = w[4], cav = false, ice = false} end
            end
            return {c = '#', dig = '', bld = ''}
          end,
          far = function() return false end,
          outside_near = function(K, pts) local out = {}; for i = 1, #pts do out[i] = 1 end; return out end})
  W.act_result('run', function() return true, '' end)
  W.act_result('fish_zone', function(pos, side, up)
    ctl.zones[#ctl.zones + 1] = {pos = {pos[1], pos[2], pos[3]}}
    F.building(W, 'ANY_ZONE', {type = 85, x1 = pos[1] - 1, y1 = pos[2] - 1, x2 = pos[1] + 1, y2 = pos[2] + 1, z = pos[3]})
    return true, 1
  end)
  -- the old zone stands on the first pond (56,50,100); the fishers are on the detail
  F.building(W, 'ANY_ZONE', {type = 85, x1 = 55, y1 = 49, x2 = 57, y2 = 51, z = 100})
  local wd = {name = 'Fisherdwarves', assigned_units = kmock.vec({1, 2}), allowed_labors = {[0] = false, [4] = true}, flags = {mode = 3}}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{wd}}
  W.act_result('work_detail', function() return true end)
  W.load(fresh('economy'))
  for i = 1, 20 do W.unit(i).status.labors, W.unit(i).mood = {}, -1 end
  return W, ctl
end

T.test('BUG-698 Wallfree: fishers on a zone that gives no fish for dry_days days: a SECOND zone on another water body, the first one is not painted again', function()
  local water = {{56, 50, 100, 7}, {57, 50, 100, 7}, {58, 50, 100, 7}, {90, 50, 100, 7}, {91, 50, 100, 7}}
  local tiles = {[key(59, 50, 100)] = {c = '.'}, [key(89, 50, 100)] = {c = '.'}, [key(55, 51, 100)] = {c = '.'}}
  local W, ctl = zone_world{water = water, tiles = tiles}
  settle(W)
  days(W, 2)
  T.eq(ctl.zones, {}, 'two days: the zone stands, fishers wait')
  days(W, 12)
  T.eq(#ctl.zones, 1, 'dry for good: one new zone')
  local z = ctl.zones[1].pos
  T.ok(z[1] >= 89, 'on the other water body (x 90), not beside the old zone (x 56): ' .. z[1] .. ',' .. z[2])
  local l
  for _, g in ipairs(W.logs) do if tostring(g.msg):find('SECOND zone', 1, true) then l = g end end
  T.ok(l, 'kern.log says so')
  days(W, 12)
  T.eq(#ctl.zones, 1, 'the fishers have the new water: no third zone')
end)

T.test('BUG-698: no other water: no second zone, and the reason says so; raw fish in the fort keep the zone', function()
  local water = {{56, 50, 100, 7}, {57, 50, 100, 7}}
  local W, ctl = zone_world{water = water, tiles = {[key(59, 50, 100)] = {c = '.'}}}
  settle(W)
  days(W, 15)
  T.eq(ctl.zones, {}, 'only the water of the old zone: nothing to paint')
  local why = W.K.persist.get('m.economy').fishz
  T.ok(why and tostring(why.why):find('fished out', 1, true), tostring(why and why.why))
  local W2, ctl2 = zone_world{water = {{56, 50, 100, 7}, {90, 50, 100, 7}}, tiles = {[key(89, 50, 100)] = {c = '.'}}}
  for _ = 1, 10 do F.item(W2, 'FISH_RAW', {}) end
  settle(W2)
  days(W2, 15)
  T.eq(ctl2.zones, {}, 'raw fish lie in the fort: the fishers are at work, the zone is fine')
end)

-- the starvation handler of test_economy_supply.lua (FR-25) with many idle citizens
local function starve_world(mode)
  local units = {}
  for i = 1, 45 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.starve.days = 10
  cfg.economy.famine_crew.on = false
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = mode}
  local ids = {}
  for i = 1, 45 do
    ids[i] = i
    local u = W.unit(i)
    u.job = i <= 8 and {current_job = {id = 900 + i}} or nil
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = i == 1 and 60000 or 0}
  end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 1, subtype = 1, _pos = {1, 1, 100}})
  local gather = {name = 'Plant gatherers', assigned_units = kmock.vec{}, allowed_labors = {}, flags = {mode = 3}}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{gather}}
  W.act_result('work_detail', function(name, id, on)
    gather.assigned_units:insert('#', id)
    return true, 'added'
  end)
  df.global.world.plants = {shrub_dry = kmock.vec{}, shrub_wet = kmock.vec{}}
  W.act_result('plant_gather', function(list) return true, #list end)
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, far = function() return false end})
  W.load(fresh('economy'))
  return W, gather
end

T.test('BUG-697 Wallfree: a starvation with 37 of 45 citizens idle aims at 9 plant gatherers in PEACE (old: 4), at 4 in a SIEGE (they walk out)', function()
  local function target(W)                       -- the largest `target N` the starvation handler named
    local n = 0
    for _, e in ipairs(W.find_events('WORK_DETAIL')) do
      if e.d.why == 'starvation' then n = math.max(n, e.d.n) end
    end
    return n
  end
  local W = starve_world('PEACE')
  days(W, 12)
  T.eq(target(W), 9, 'one per 5 citizens, the idle adults are there (the first day knows no idle share: 4)')
  local W2 = starve_world('SIEGE')
  days(W2, 12)
  T.eq(target(W2), 4, 'a siege keeps the base number')
end)

T.done()
