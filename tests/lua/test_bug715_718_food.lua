-- BUG-715 to BUG-718 (food production, Run 16a i1 Basementflew, Run 16c i3 Wallfree / Doorwings; offline, live-untested)
-- BUG-715: a dead (unreachable or flooded) workshop beside a reachable one of its type is named and retired.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- walk groups by x: 0..60 the fort (group 7), 100..199 another level (group 9), 200+ hidden/unread (-1), the rest no walkable tile (0)
local function group_at(x) return x <= 60 and 7 or (x >= 200 and -1 or (x >= 100 and 9 or 0)) end
local SNAP = {name = 'snapshot', every = {ticks = 1200},
              groups = function(_K, pts)
                local out = {}
                for i, p in ipairs(pts) do out[i] = group_at(p.x or p[1]) end
                return out
              end,
              home_set = function(_K, ids)
                local set = {}
                for _, g in ipairs(ids) do if g > 0 then set[g] = true end end
                return set
              end}

local function shop(W, name, x, y, z)
  local sub = df.workshop_type[name]
  return F.building(W, 'WORKSHOP_ANY', {type = sub, getType = function() return df.building_type.Workshop end,
                                        getSubtype = function() return sub end,
                                        x1 = x - 1, x2 = x + 1, y1 = y - 1, y2 = y + 1, z = z or 5})
end

local function world(o)
  o = o or {}
  local cit = o.cit or 12
  local units, ids = {}, {}
  for i = 1, cit do units[i] = {id = i, citizen = true, pos = {10 + i, 20, 5}}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, cit do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.unit_labor = {COOK = 5, [5] = 'COOK', PLANT = 1, [1] = 'PLANT'}
  df.job_skill = df.job_skill or {}
  F.mat(W, 419, 53, {token = 'PLANT:PEACH:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  if o.snapshot ~= false then W.load(SNAP) end
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  if (o.growth or 0) > 0 then F.item(W, 'PLANT_GROWTH', {stack_size = o.growth, mat_type = 419, mat_index = 53}) end
  for i = 1, cit do
    W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = i <= (o.hungry or 0) and 60000 or 1000}
  end
  return W
end
local function econ(W)
  local E = fresh('economy')
  W.load(E)
  return E
end
local function requests(W, why)
  local n, last = 0, nil
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == why then n, last = n + 1, e end end
  return n, last
end
local function cut_events(W)
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if e.d.kind == 'workshop' and tostring(e.msg):find('no way for the citizens', 1, true) then out[#out + 1] = e end
  end
  return out
end
local function setup(o)
  local W = world(o)
  for i = 1, (o.cit or 12) do
    local u = W.unit(i)
    u.status.labors, u.mood, u.military = {}, -1, {squad_id = -1}
  end
  return W
end


local function acts(W, fn)
  local out = {}
  for _, a in ipairs(W.acts) do if a.fn == fn then out[#out + 1] = a end end
  return out
end
local function dead_events(W)
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if e.d.kind == 'workshop' and tostring(e.msg):find('dead workshop', 1, true) then out[#out + 1] = e end
  end
  return out
end

T.test('BUG-715 Basementflew: a second Kitchen in the flooded level beside a reachable one is named after 3 days and retired once', function()
  local W = setup{growth = 200, hungry = 2}
  local good = shop(W, 'Kitchen', 20, 20)
  local dead = shop(W, 'Kitchen', 80, 20)            -- ring all group 0: flooded z117
  econ(W)
  days(W, 2)
  T.eq(#acts(W, 'workshop_retire'), 0, 'two days: a flooded corner may dry')
  days(W, 3)
  local a = acts(W, 'workshop_retire')
  T.eq(#a, 1, 'retired once')
  T.eq(a[1].args[1], dead.id, 'the dead one, never the reachable one')
  T.ok(dead.id ~= good.id)
  local ev = dead_events(W)
  T.eq(#ev, 1, 'told once')
  T.ok(ev[1].msg:find('Kitchen ' .. dead.id .. ' at 80,20,5 (walk group 0: no walkable tile round it', 1, true), ev[1].msg)
  T.ok(ev[1].msg:find('a reachable Kitchen stands', 1, true), ev[1].msg)
  T.eq({ev[1].d.job, ev[1].d.kind, ev[1].d.id}, {'Kitchen', 'workshop', dead.id})
  local p = W.K.persist.get('m.economy')
  T.ok(p.deadws and p.deadws[tostring(dead.id)] and p.deadws[tostring(dead.id)].done, 'persisted with the retire time')
  T.eq(p.cutws, nil, 'the type is not cut: a reachable Kitchen stands')
  days(W, 20)
  T.eq(#acts(W, 'workshop_retire'), 1, 'not asked again inside RETIRE_AGAIN days')
  days(W, 15)
  T.eq(#acts(W, 'workshop_retire'), 2, 'a shop that still stands after 30 days is retired again (the job may have gone)')
end)

T.test('BUG-715: a dead shop on another walk group is retired too; a type with ONLY dead shops is the BUG-654 case (asked for, nothing removed)', function()
  local W = setup{growth = 200}
  shop(W, 'Kitchen', 20, 20)
  local far = shop(W, 'Kitchen', 120, 20)           -- walk group 9
  econ(W)
  days(W, 6)
  local a = acts(W, 'workshop_retire')
  T.eq(#a, 1)
  T.eq(a[1].args[1], far.id)
  T.ok(dead_events(W)[1].msg:find('walk group 9, the citizens on 7', 1, true), dead_events(W)[1].msg)
  local W2 = setup{growth = 200}
  shop(W2, 'Kitchen', 120, 20)
  econ(W2)
  days(W2, 8)
  T.eq(#acts(W2, 'workshop_retire'), 0, 'no reachable kitchen: nothing is removed, a new one is asked for')
  T.eq(#cut_events(W2), 1)
end)

T.test('BUG-715: an unread ring (-1) is no dead shop; a shop that comes back to the citizens walk group is forgotten', function()
  local W = setup{growth = 200}
  shop(W, 'Kitchen', 20, 20)
  shop(W, 'Kitchen', 220, 20)                       -- hidden ring: unknown
  econ(W)
  days(W, 8)
  T.eq(#acts(W, 'workshop_retire'), 0)
  local W2 = setup{growth = 200}
  shop(W2, 'Kitchen', 20, 20)
  shop(W2, 'Kitchen', 120, 20)
  econ(W2)
  days(W2, 2)
  local p = W2.K.persist.get('m.economy')
  T.ok(p.deadws, 'seen as dead')
  W2.unit(1).pos = {120, 20, 5}                     -- (group_at is by x only: move the shop instead)
  for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do if b.x1 == 119 then b.x1, b.x2 = 29, 31 end end
  days(W2, 2)
  T.eq(W2.K.persist.get('m.economy').deadws, nil, 'forgotten once it stands on the citizens group')
  T.eq(#acts(W2, 'workshop_retire'), 0)
end)

T.test('BUG-715: the kitchen stall text names the dead second kitchen', function()
  local W = setup{growth = 200, hungry = 2}
  shop(W, 'Kitchen', 20, 20)
  shop(W, 'Kitchen', 80, 20)
  local E = econ(W)
  days(W, 5)
  local p = W.K.persist.get('m.economy')
  local note = E.dead_note(p, 'Kitchen')
  T.ok(note and note:find('dead Kitchen', 1, true) and note:find('walk group 0', 1, true) and note:find('retired', 1, true), tostring(note))
  T.eq(E.dead_note(p, 'Still'), nil)
end)

-- act.workshop_retire against DF fakes: profile, jobs, Remove Building
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local actlib = require('dfllm.act')
T.test('BUG-715 act.workshop_retire: profile max_general_orders 0 and deconstruct queued; no job is removed (lint remove-job)', function()
  H.world{tag = 'wsretire'}
  local b1 = {id = 71, profile = {max_general_orders = 5}, jobs = kmock.vec{{id = 1, job_type = 10}}}
  local b2 = {id = 72, jobs = kmock.vec{}}
  df.global.world.buildings.other.WORKSHOP_ANY = kmock.vec{b1, b2}
  dfhack.buildings = dfhack.buildings or {}
  local dec = {}
  dfhack.buildings.deconstruct = function(b) dec[#dec + 1] = b.id; return false end
  dfhack.buildings.markedForRemoval = function(b) return true end
  local api = actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
                         log_cmd = function() end, fail = function() end}
  T.eq({api.workshop_retire('x')}, {false, 'bad workshop id'})
  T.eq({api.workshop_retire(999)}, {false, 'no such workshop'})
  local ok, res = api.workshop_retire(71)
  T.ok(ok)
  T.eq(res, {how = 'queued', profile = true})
  T.eq(b1.profile.max_general_orders, 0)
  T.eq(#b1.jobs, 1, 'the job stays: the order stall watch handles it')
  T.eq(dec, {71})
  local ok2, res2 = api.workshop_retire(72)         -- no profile field on the fake: pcall holds; still queued
  T.ok(ok2 and res2.how == 'queued' and res2.profile == false)
  dfhack.buildings.markedForRemoval = function(b) return false end
  T.eq({api.workshop_retire(72)}, {false, 'deconstruct refused'})
  dfhack.buildings.deconstruct = function(b) return true end
  T.eq({api.workshop_retire(72)}, {true, {how = 'gone', profile = false}})
  dfhack.buildings.markedForRemoval = nil
end)

-- ---------------------------------------------------------------- BUG-716: raw fish, the hunger gap
local function fish_world(o)
  o = o or {}
  local W = setup{cit = o.cit or 12, growth = 0}
  df.unit_labor.CLEAN_FISH = 7
  df.unit_labor[7] = 'CLEAN_FISH'
  if o.fishery ~= false then shop(W, 'Fishery', 20, 20) end
  F.item(W, 'FISH_RAW', {stack_size = o.raw or 120})
  for _, id in ipairs(o.holders or {}) do W.unit(id).status.labors[7] = true end
  return W
end
local function fish_events(W)
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if tostring(e.msg):find('raw fish not cleaned', 1, true) then out[#out + 1] = e end
  end
  return out
end

T.test('BUG-716 Wallfree: 120 raw fish, a fishery, nobody holds Fish cleaning: after 6 days the labor goes on for an idle adult and the cause is told once', function()
  local W = fish_world{}
  W.unit(4).job = nil                                -- idle: the first pick
  W.act_result('labor_set', function(id, which, on) W.unit(id).status.labors[7] = true; return true, 'enabled' end)
  econ(W)
  days(W, 4)
  T.eq(#fish_events(W), 0, 'four days: the cleaners may be slow')
  days(W, 5)
  local ev = fish_events(W)
  T.eq(#ev, 1, 'told once')
  T.ok(ev[1].msg:find('120 raw fish, fishery built, Fish cleaning on nobody', 1, true), ev[1].msg)
  T.ok(ev[1].msg:find('Fish cleaning labor on for unit 4', 1, true), ev[1].msg)
  T.eq({ev[1].d.job, ev[1].d.kind}, {'PrepareRawFish', 'worker'})
  local ls = acts(W, 'labor_set')
  T.eq(#ls, 1)
  T.eq({ls[1].args[1], ls[1].args[2], ls[1].args[3]}, {4, 'clean_fish', true})
  days(W, 10)
  T.eq(#fish_events(W), 1, 'not told again inside 30 days')
end)

T.test('BUG-716: a holder exists and the pile does not fall: told as a slow fishery or an idle labor, no second labor for a pile under 3x the floor; a falling pile is no stall', function()
  local W = fish_world{holders = {2}}
  econ(W)
  days(W, 8)
  local ev = fish_events(W)
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('Fish cleaning held', 1, true), ev[1].msg)
  T.eq(#acts(W, 'labor_set'), 0, 'the labor is on: nothing switched')
  T.eq(ev[1].d.kind, 'input')
  local W2 = fish_world{holders = {2}}
  econ(W2)
  days(W2, 3)
  for _, it in ipairs(W2.items or {}) do end
  W2.K.persist.get('m.economy').fishw = {base = 400, d = 5, day = 0}      -- a pile that was 400: 120 is a fall of more than a fifth
  days(W2, 2)
  T.eq(#fish_events(W2), 0, 'a pile that fell by a fifth is no stall')
end)

T.test('BUG-716: no fishery (BUG-038 asks for it) or a pile under fish.stall_raw: no watch; the food decision names the uncleaned fish', function()
  local W = fish_world{fishery = false}
  econ(W)
  days(W, 9)
  T.eq(#fish_events(W), 0)
  local W2 = fish_world{raw = 20}
  econ(W2)
  days(W2, 9)
  T.eq(#fish_events(W2), 0)
  local W3 = fish_world{}
  local E = econ(W3)
  days(W3, 8)
  local out = E.food_block(W3.K, W3.K.cfg.baseline.economy or {}, {p = W3.K.persist.get('m.economy'), inv = W3.K.census.i, now = 0, days = {food_d = 20}}, W3.K.census.i)
  local found
  for _, b in ipairs(out) do if b[1] == 'fish_clean' then found = b[2] end end
  T.ok(found and found:find('120 raw fish uncleaned for', 1, true), tostring(found))
end)

T.test('BUG-716 hunger gap: in autumn and winter a stock under food.gap_days counts as low; spring and summer, a bigger stock, gap_days 0 do not', function()
  local E = fresh('economy')
  local c = {food = {pre_days = 30, gap_days = 110}}
  local Y = 403200
  local function r(season, fd) return {now = 5 * Y + season * 100800 + 5000, days = {food_d = fd}, p = {}} end
  T.eq(E.food_low(c, r(2, 100)), true, 'autumn, 100 days')
  T.eq(E.food_low(c, r(3, 60)), true, 'winter, 60 days')
  T.eq(E.food_low(c, r(0, 60)), false, 'spring: the crops come')
  T.eq(E.food_low(c, r(1, 60)), false, 'summer')
  T.eq(E.food_low(c, r(2, 111)), false, 'autumn with 111 days')
  T.eq(E.food_low({food = {pre_days = 30, gap_days = 0}}, r(2, 60)), false, 'off')
  T.eq(E.food_low({food = {pre_days = 30}}, r(3, 100)), true, 'default 110')
  T.eq(E.food_low(c, r(0, 20)), true, 'the 30-day line as before')
end)

T.done()
