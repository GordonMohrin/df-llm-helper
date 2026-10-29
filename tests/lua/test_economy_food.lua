-- economy (live L5): food follows the population. Castlerisen y295: pop 41 -> 53 on the same 80 farm tiles,
-- autofarm's threshold 50 stopped the plump helmets at 40, nobody fished; food fell from 105 to 15 days.
-- Farm tiles per citizen, the farms request (follow places it), the 30-day pre-alarm, autofarm thresholds of the
-- food crops, fishers, the cooking and fishery orders sized by the fort.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- W, ctl: ctl.pending (runner.pending('farms')), ctl.status (autofarm status text), ctl.mode (labormanager mode)
local function world(opts)
  opts = opts or {}
  local ctl = {pending = opts.pending or 0, status = opts.status or '', mode = 'Mode: monitor (labormanager)',
               lost = opts.lost or 0}
  local units = {}
  for i = 1, opts.cit or 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  local ids = {}
  for i = 1, opts.cit or 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 52, {token = 'PLANT:FEATHER:EGG', flags = {EDIBLE_COOKED = true}})
  F.mat(W, 419, 53, {token = 'PLANT:PEACH:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function(_, tpl) return tpl == 'farms' and ctl.pending or 0 end,
          lost = function(_, tpl)
            local n = tpl == 'farms' and ctl.lost or 0
            return n, n > 0 and 'c1a1farms' or nil
          end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, ctl.mode end
    if cmd == 'autofarm' and a1 == 'status' then return true, ctl.status end
    return true, ''
  end)
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  for i = 1, opts.cit or 10 do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
  end
  return W, ctl
end

local function plot(W, w, h) return F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = w - 1, y2 = h - 1}) end
local function requests(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'farms' then r[#r + 1] = e.d end end
  return r
end
local function decisions(W, id)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then n = n + 1 end end
  return n
end
local function order(W, tag)
  local o
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then o = a.args[1] end end
  return o
end
local function runs_like(W, prefix)
  local r = {}
  for _, line in ipairs(F.runs(W)) do if line:sub(1, #prefix) == prefix then r[#r + 1] = line end end
  return r
end

T.test('farm tiles per citizen: cit x per_dwarf / yield (DF: about one crop a tile and season)', function()
  local E = fresh('economy')
  T.eq(E.farm_need(53), 159, '53 citizens x 3 plants a season')
  T.eq(E.farm_need(53, {yield = 2, per_dwarf = 3}), 80)
  T.eq(E.farm_need(0), 0)
  T.eq(E.DEFAULTS.food.plot_tiles, 35, 'the farms template plot is 5x7')
end)

T.test('farms request: food short, too few tiles, nothing pending -> PROJECT_REQUEST farms (plots), every 14 days', function()
  local W = world{cit = 53, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 26, subtype = 1})     -- 26 / (53 x 0.024) = 20 food days
    plot(W, 5, 7); plot(W, 5, 7); plot(W, 5, 2)           -- Castlerisen: 80 tiles
  end}
  settle(W)
  days(W, 1)
  local r = requests(W)
  T.eq(#r, 1)
  T.eq({r[1].tpl, r[1].n, r[1].why}, {'farms', 3, 'food'}, '159 wanted - 80 built = 79 tiles: 3 plots of 35')
  days(W, 10)
  T.eq(#requests(W), 1, 'not again within request_days')
  days(W, 4)
  T.eq(#requests(W), 2, 'still short after 14 days: asks again')
  T.eq(F.bad_runs(W), {})
end)

-- BUG-058 (DECISIONS 9; Run 11: five farms projects 'build_lost, parked' one after the other, no soil there): a farms
-- project lost for good stops the requests until it is cancelled or the farms are placed elsewhere. BUG-257 (Run 15:
-- the same stone site re-dug for 8 seasons): each lost project is first placed elsewhere once (follow ranks by soil)
T.test('BUG-058/BUG-257: a farms project lost to build_lost is placed elsewhere once, then stops the farms requests; ' ..
       'cancelled, they go on', function()
  local W, ctl = world{cit = 53, lost = 1, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 26, subtype = 1})
    plot(W, 5, 7); plot(W, 5, 7); plot(W, 5, 2)
  end}
  settle(W)
  days(W, 20)
  T.eq(#requests(W), 1, 'one request for another site, then none while the project stays lost')
  local function logs(s)
    local n = 0
    for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then n = n + 1 end end
    return n
  end
  T.eq(logs('c1a1farms lost to build_lost (no soil there): farms requested once at another site'), 1)
  T.eq(logs('c1a1farms lost to build_lost (no soil there?): no further farms request'), 1, 'told once')
  ctl.lost = 0                                                  -- bp.cancel: the cause is gone
  days(W, 1)
  T.eq(#requests(W), 2)
  T.eq(requests(W)[2].tpl, 'farms')
end)

-- BUG-256 (Run 15 Inkintense y373/y374: famine on one plot; the second farm was placed by hand): in a famine one more
-- plot is asked for although the tiles cover the citizens' need, up to twice that need
T.test('BUG-256: a famine asks for one more farm plot on top of enough tiles, up to twice the need', function()
  local W = world{cit = 10, setup = function(W) plot(W, 5, 7) end}       -- 35 tiles >= 30 wanted, no food: famine
  settle(W)
  days(W, 2)
  local r = requests(W)
  T.eq(#r, 1, 'old: enough tiles, no request through the famine')
  T.eq({r[1].n, r[1].why}, {1, 'food'})
  local W2 = world{cit = 10, setup = function(W) plot(W, 5, 7); plot(W, 5, 7) end}   -- 70 tiles >= 2 x 35
  settle(W2)
  days(W2, 2)
  T.eq(#requests(W2), 0, 'twice the need stands: no more')
end)

T.test('farms request: never while a farms project is pending, never with enough tiles, at most plots_max', function()
  local W = world{cit = 53, pending = 1, setup = function(W) F.item(W, 'FOOD', {stack_size = 26, subtype = 1}) end}
  settle(W)
  days(W, 3)
  T.eq(#requests(W), 0, 'the runner still builds farms')
  local W2 = world{cit = 53, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 26, subtype = 1})
    for _ = 1, 5 do plot(W, 5, 7) end                      -- 175 tiles >= 159
  end}
  settle(W2)
  days(W2, 3)
  T.eq(#requests(W2), 0, 'enough farm tiles')
  local W3 = world{cit = 53, setup = function(W) F.item(W, 'FOOD', {stack_size = 26, subtype = 1}) end}
  settle(W3)
  days(W3, 1)
  T.eq(requests(W3)[1].n, 4, 'no farm at all: 159 tiles would be 5 plots, capped at plots_max 4')
  local W4 = world{cit = 53, setup = function(W) F.item(W, 'FOOD', {stack_size = 600, subtype = 1}) end}
  settle(W4)
  days(W4, 15)
  T.eq(#requests(W4), 0, '470 food days, stock not falling: no farms')
end)

T.test('farms request: a food stock falling over 14 days asks even with many food days', function()
  local food
  local W = world{cit = 10, setup = function(W) food = F.item(W, 'FOOD', {stack_size = 400, subtype = 1}) end}
  settle(W)
  for _ = 1, 13 do food.stack_size = food.stack_size - 2; days(W, 1) end
  T.ok(W.state().stock.food_d > 90, 'food days ' .. tostring(W.state().stock.food_d))
  T.eq(#requests(W), 0, 'the 14-day window is not full yet')
  for _ = 1, 2 do food.stack_size = food.stack_size - 2; days(W, 1) end
  local r = requests(W)
  T.eq(#r, 1, 'falling for 14 days')
  T.eq(r[1].n, 1, '30 tiles wanted for 10 citizens: one plot')
end)

T.test('famine pre-alarm: below 30 food days one class-A DECISION_NEEDED food_low (util/cadence); below 10 only famine', function()
  local W = world{cit = 53, setup = function(W) F.item(W, 'FOOD', {stack_size = 26, subtype = 1}) end}
  settle(W)
  days(W, 1)
  T.eq(decisions(W, 'food_low'), 1)
  T.eq(decisions(W, 'famine'), 0)
  local e
  for _, x in ipairs(W.find_events('DECISION_NEEDED')) do if x.d.id == 'food_low' then e = x end end
  T.eq(e.cls, 'A')
  T.ok(e.d.q:find('farms 0/159 tiles', 1, true), e.d.q)
  T.ok(#e.d.q <= 200)
  days(W, 4)
  T.eq(decisions(W, 'food_low'), 1)
  days(W, 4)
  T.eq(decisions(W, 'food_low'), 1, 'Run 11 (BUG-008): the same blockers are not asked again')
  W.ms = W.ms + 600 * 1000
  for _ = 1, 6 do F.item(W, 'FISH_RAW', {}) end              -- raw fish and no fishery: asked by itself (BUG-038)
  days(W, 1)
  T.eq(decisions(W, 'food_low'), 1, 'the fishery request is no news for the player')
  W.set_census('a', {n = 2})                                 -- tame animals and no butcher's shop: a new blocker
  days(W, 1)
  T.eq(decisions(W, 'food_low'), 2)
  local W2 = world{cit = 53}
  settle(W2)
  days(W2, 2)
  T.eq({decisions(W2, 'food_low'), decisions(W2, 'famine')}, {0, 1}, 'no food: the famine wake, no pre-alarm')
  local W3 = world{cit = 53, setup = function(W) F.item(W, 'FOOD', {stack_size = 100, subtype = 1}) end}
  settle(W3)
  days(W3, 2)
  T.eq(decisions(W3, 'food_low'), 0, '78 food days')
end)

T.test('live L6: food low or famine -> surplus animals marked for slaughter (one breeding pair per race kept)', function()
  local function A(id, race, female, adult, extra)
    local a = {id = id, race = race, female = female, adult = adult ~= false, pet = false, slaughter = false, war = false}
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
  end
  local herd = {A(30, 1, true), A(31, 1, true), A(32, 1, false), A(33, 1, false), A(34, 1, true, false),
                A(40, 2, true, true, {pet = true}), A(41, 2, false), A(42, 2, false),
                A(50, 3, false, true, {war = true}), A(51, 3, true, true, {slaughter = true})}
  local E = fresh('economy')
  T.eq(E.slaughter_pick(herd, {keep_f = 1, keep_m = 1, max = 10}), {31, 33, 34, 42},
       'per race 1 adult female + 1 adult male stay; pets, war animals, already marked untouched')
  T.eq(E.slaughter_pick(herd, {keep_f = 1, keep_m = 1, max = 3}), {31, 33}, 'max counts the marked ones too')
  local marks = {}
  local W = world{cit = 53, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 26, subtype = 1})               -- about 17 food days: the pre-alarm
    F.workshop(W, 'Butchers')
    W.set_census('a', {tick = 0, n = #herd, list = herd})
    W.act_result('animal_slaughter', function(id, on) marks[#marks + 1] = id; return true, 'marked' end)
  end}
  settle(W)
  days(W, 1)
  T.eq(decisions(W, 'food_low'), 1)
  T.eq(marks, {31, 33, 34, 42})
  local logged = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('4 surplus animals marked for slaughter', 1, true) then logged = true end end
  T.ok(logged, 'logged')
  days(W, 3)
  T.eq(#marks, 4, 'once a week')
  -- no butcher's shop: nothing is marked; plenty of food: nothing either
  local m2 = {}
  local W2 = world{cit = 53, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 26, subtype = 1})
    W.set_census('a', {tick = 0, n = #herd, list = herd})
    W.act_result('animal_slaughter', function(id) m2[#m2 + 1] = id; return true end)
  end}
  settle(W2); days(W2, 2)
  T.eq(m2, {}, 'no butcher: no marks')
  local W3 = world{cit = 53, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
    F.workshop(W, 'Butchers')
    W.set_census('a', {tick = 0, n = #herd, list = herd})
    W.act_result('animal_slaughter', function(id) m2[#m2 + 1] = id; return true end)
  end}
  settle(W3); days(W3, 2)
  T.eq(m2, {}, 'food plenty: no marks')
end)

local STATUS = 'Autofarm is Active.\nSPELT limit 50 current 32\nMUSHROOM_HELMET_PLUMP limit 50 current 40\n' ..
               'GRASS_TAIL_PIG limit 50 current 0\nDefault: 50\n'

T.test('autofarm thresholds of the food crops follow the citizens (fiber crops stay with the cloth chain)', function()
  local W = world{cit = 53, status = STATUS, setup = function(W) F.item(W, 'FOOD', {stack_size = 500, subtype = 1}) end}
  settle(W)
  days(W, 3)
  T.eq(runs_like(W, 'autofarm threshold'), {'autofarm threshold 210 MUSHROOM_HELMET_PLUMP SPELT'},
       '53 x 4 = 212 -> 210 (steps of 10), once')
  T.eq(#runs_like(W, 'autofarm status'), 1, 'status read once')
  days(W, 6)
  T.eq(#runs_like(W, 'autofarm status'), 2, 'read again after status_days')
  T.eq(#runs_like(W, 'autofarm threshold'), 1, 'same value: not sent again')
  T.eq(F.bad_runs(W), {})
  local W2 = world{cit = 5, status = STATUS:gsub('Default: 50', 'Default: 120'), setup = function(W)
    F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  end}
  settle(W2)
  days(W2, 1)
  T.eq(runs_like(W2, 'autofarm threshold'), {'autofarm threshold 120 MUSHROOM_HELMET_PLUMP SPELT'},
       '5 x 4 = 20: never below autofarm\'s own default')
  local W3 = world{cit = 200, status = STATUS, setup = function(W) F.item(W, 'FOOD', {stack_size = 5000, subtype = 1}) end}
  settle(W3)
  days(W3, 1)
  T.eq(runs_like(W3, 'autofarm threshold'), {'autofarm threshold 400 MUSHROOM_HELMET_PLUMP SPELT'}, 'crops_max')
end)

-- fishers: a Fisherdwarves detail and (optionally) a fishing zone
local function fish_world(opts)
  local ctl0
  local W, ctl = world{cit = opts.cit or 53, mode = opts.mode, setup = function(W, ctl)
    ctl0 = ctl
    ctl.wd = {name = 'Fisherdwarves', assigned_units = kmock.vec(opts.fishers or {}),
              allowed_labors = {[0] = false, [4] = true}, flags = {mode = 3}}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wd}}
    W.act_result('work_detail', function(name, id, on)
      local v = ctl.wd.assigned_units
      for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
      if on then v:insert('#', id) end
      return true
    end)
    df.civzone_type.FishingArea, df.civzone_type[85] = 85, 'FishingArea'
    if opts.zone ~= false then F.building(W, 'ANY_ZONE', {type = 85, x1 = 0, y1 = 0, x2 = 9, y2 = 9, z = 1}) end
    F.item(W, 'FOOD', {stack_size = opts.food or 26, subtype = 1})
  end}
  return W, ctl or ctl0
end

T.test('fishers: food short and a fishing zone -> one per 15 citizens (max 3); none without a zone or with food', function()
  local W, ctl = fish_world{cit = 53}
  settle(W)
  days(W, 1)
  T.eq(#ctl.wd.assigned_units, 3, '53 citizens: 4 wanted, max 3')
  local ev = W.find_events('WORK_DETAIL')
  T.eq(ev[1].d.detail, 'Fisherdwarves')
  local W2, ctl2 = fish_world{cit = 20}
  settle(W2)
  days(W2, 1)
  T.eq(#ctl2.wd.assigned_units, 2, '20 citizens: 2')
  local W3, ctl3 = fish_world{cit = 53, zone = false}
  settle(W3)
  days(W3, 2)
  T.eq(#ctl3.wd.assigned_units, 0, 'no fishing zone: nobody fishes')
  local W4, ctl4 = fish_world{cit = 53}
  settle(W4)
  days(W4, 1)
  T.eq(#ctl4.wd.assigned_units, 3)
  F.item(W4, 'FOOD', {stack_size = 600, subtype = 1})
  days(W4, 2)
  T.eq(#ctl4.wd.assigned_units, 3, 'food enough: shrinking waits shrink_days')
  days(W4, 3)
  T.eq(#ctl4.wd.assigned_units, 0, 'then the fishers economy sent go home')
  local W5, ctl5 = fish_world{cit = 53, food = 600, fishers = {1, 2}}
  settle(W5)
  days(W5, 5)
  T.eq(#ctl5.wd.assigned_units, 2, 'Run 10: fishers the player put in stay in PEACE')
end)

T.test('fishers leave at once outside PEACE/RECOVERY (they stand at the water outside the walls)', function()
  local W, ctl = fish_world{cit = 53, fishers = {1, 2, 3}}
  settle(W)
  days(W, 1)
  T.eq(#ctl.wd.assigned_units, 3)
  W.set_mode('ALERT')
  days(W, 1)
  T.eq(#ctl.wd.assigned_units, 0, 'off the detail in the next run, not after shrink_days')
end)

T.test('cooking: meals_per_dwarf meals per citizen from cookable stock, never from plump helmets; cap grows', function()
  local W = world{cit = 20, setup = function(W)
    F.item(W, 'PLANT_GROWTH', {stack_size = 40, mat_type = 419, mat_index = 52})   -- cook-only
    F.item(W, 'PLANT', {stack_size = 300, mat_type = 419, mat_index = 50})         -- helmets: 625 food days
  end}
  settle(W)
  local o = order(W, 'dfllm:food')
  T.ok(o, 'a meal order although food days are far above the target')
  T.eq(o.amount_total, 10, '40 meals wanted (20 x 2), 40 cookable: 10 jobs of 4')
  T.eq(W.K.census.i.food_nocook, 300, 'the helmets are food, but no cook may use them')
  local W2 = world{cit = 20, setup = function(W) F.item(W, 'PLANT', {stack_size = 300, mat_type = 419, mat_index = 50}) end}
  settle(W2)
  T.eq(order(W2, 'dfllm:food'), nil, 'only plump helmets: nothing to cook (Gordon\'s rule)')
  local W3 = world{cit = 60, setup = function(W)
    F.item(W, 'PLANT_GROWTH', {stack_size = 400, mat_type = 419, mat_index = 53})  -- fruit
  end}
  settle(W3)
  T.eq(order(W3, 'dfllm:food').amount_total, 30, '120 meals wanted: 30 jobs, the cap grows from 20 to 30')
  local W4 = world{cit = 20, setup = function(W)
    F.item(W, 'FOOD', {stack_size = 40, subtype = 1})
    F.item(W, 'PLANT_GROWTH', {stack_size = 40, mat_type = 419, mat_index = 53})
  end}
  settle(W4)
  T.eq(order(W4, 'dfllm:food'), nil, '40 meals for 20 citizens: enough')
end)

T.test('prepared fish is food: item_fishst has no mat_type field, the census reads getActualMaterial (live L5)', function()
  local W = world{cit = 10, setup = function(W)
    F.mat(W, 61, 3, {token = 'CREATURE:FISH_CARP:MUSCLE', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
    for _ = 1, 3 do
      local it = F.item(W, 'FISH', {stack_size = 2})
      it.mat_type, it.mat_index = nil, nil            -- DF raises on the missing field; the fake reads nil
      it.getActualMaterial = function() return 61 end
      it.getActualMaterialIndex = function() return 3 end
    end
  end}
  settle(W)
  T.eq(W.K.census.i.food, 6)
  local warns = {}
  for _, l in ipairs(W.logs) do if l.module == 'economy' and tostring(l.msg):find('^census') then warns[#warns + 1] = l.msg end end
  T.eq(warns, {}, 'no unreadable items')
end)

T.test('fishery: one PrepareRawFish order holds up to one fish per citizen', function()
  local W = world{cit = 53, setup = function(W)
    for _ = 1, 80 do F.item(W, 'FISH_RAW', {}) end
    F.workshop(W, 'Fishery')
  end}
  settle(W)
  days(W, 1)
  T.eq(order(W, 'dfllm:fish').amount_total, 53)
  local W2 = world{cit = 10, setup = function(W)
    for _ = 1, 80 do F.item(W, 'FISH_RAW', {}) end
    F.workshop(W, 'Fishery')
  end}
  settle(W2)
  days(W2, 1)
  T.eq(order(W2, 'dfllm:fish').amount_total, 30, 'at least fish.max')
end)

-- BUG-059 (Run 12 y503 autumn: 12 dwarves starved in a season, 17 corpses, "food 41 d", meals 0): raw plants and seeds
-- count as food days and nobody cooks them. Hungry citizens and no prepared meal are warned about above the pre-alarm
-- line (kern.log, state stock.hungry for the status line), and the food_low decision names them first.
T.test('BUG-059: hungry citizens and meals 0 at 41 food days: stock.hungry, a kern.log warning; food_low names them first',
       function()
  local function hungry_world(food_raw)
    local W = world{cit = 12, setup = function(W)
      F.item(W, 'PLANT', {stack_size = food_raw, mat_type = 419, mat_index = 53})     -- raw peaches: edible raw, no meal
    end}
    for i = 1, 5 do W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = 60000} end
    for i = 6, 12 do W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = 1000} end
    return W
  end
  local W = hungry_world(500)
  settle(W)
  days(W, 1)
  local fd = W.state().stock.food_d
  T.ok(fd >= 30, 'above the pre-alarm line: ' .. tostring(fd))
  T.eq(W.state().stock.hungry, 5)
  local l = {}
  for _, g in ipairs(W.logs) do if tostring(g.msg):find('citizens hungry and no prepared meal', 1, true) then l[#l + 1] = g.msg end end
  T.eq(#l, 1, 'one warning')
  T.ok(l[1]:find('5 citizens hungry', 1, true) and l[1]:find('raw plants and seeds are not cooked', 1, true), l[1])
  days(W, 3)
  local n = 0
  for _, g in ipairs(W.logs) do if tostring(g.msg):find('citizens hungry and no prepared meal', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'again only after 7 days or when the count doubled')
  -- below the pre-alarm line the decision says it first
  local W2 = hungry_world(8)
  settle(W2)
  days(W2, 1)
  local d
  for _, e in ipairs(W2.find_events('DECISION_NEEDED')) do if e.d.id == 'food_low' then d = e end end
  T.ok(d, 'food_low')
  T.eq(d.d.block[1], 'hungry')
  T.ok(d.msg:find('5 hungry, 0 meals: raw food is not cooked', 1, true), d.msg)
  T.ok(d.d.q:find('5 hungry', 1, true), d.d.q)
  -- nobody hungry, or a meal at hand: no warning
  local W3 = world{cit = 12, setup = function(W)
    F.item(W, 'PLANT', {stack_size = 500, mat_type = 419, mat_index = 53})
  end}
  days(W3, 2)
  T.eq(W3.state().stock.hungry, nil)
end)

T.done()
