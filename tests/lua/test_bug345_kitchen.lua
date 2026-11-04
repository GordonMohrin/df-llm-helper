-- BUG-345 (Run 15 Guildcleans y386: PrepareMeal 'no cook ingredient (5 inedible, 15 cut off, 517 cook-banned)', 0 meals
-- beside 100 food days; Inkintense: '1 cook-banned'). The baseline enabled seedwatch (which watches every plant at 30
-- seeds and bans the cooking of each one with fewer) and cleared the list only 30,000 ticks later; no unwatch lifts a
-- ban. economy.cook_repair lifts the kitchen exclusions of food while the kitchen has nothing else to cook (never the
-- config ban D-09, never a farmed crop), once a year each; the texts name the banned material; D-09 'yes' in a famine
-- takes the plump helmet exclusion off; the baseline runs its seedwatch task right after the enable. Fails on 14ff5a3.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- opts: food (meals), decisions, crops (baseline's farmed crops), setup(W)
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true, pos = {50, 50, 100}} end
  local W = F.world{cfg = {baseline = F.cfg(), decisions = opts.decisions}, units = units}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.unit_labor = {COOK = 7, [7] = 'COOK'}
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 62, {token = 'PLANT:BERRY_PRICKLE:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 63, {token = 'PLANT:GRASS_WHEAT_CAVE:STRUCTURAL', flags = {EDIBLE_COOKED = true}})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 4000})
  F.item(W, 'FOOD', {stack_size = opts.food or 10, subtype = 1})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end})
  W.load({name = 'baseline', every = {ticks = 33600}, status = function() return {crops = opts.crops or {}} end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor (labormanager)' end
    return true, ''
  end)
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W
end

local function banned(W, t, i)
  for _, e in ipairs(W.kitchen) do if e.what == 'Cook' and e.t == t and e.i == i then return true end end
  return false
end
local function lifts(W)
  local r = {}
  for _, a in ipairs(W.find_acts('kitchen_include')) do r[#r + 1] = table.concat({a.args[1], a.args[3], a.args[4]}, ':') end
  return r
end
local function log_has(W, s)
  for _, l in ipairs(W.logs or {}) do if tostring(l.msg or l[3] or l):find(s, 1, true) then return true end end
  return false
end

T.test('BUG-345: a seedwatch leftover ban on wild plants goes when the kitchen has nothing to cook; D-09 and crops stay',
       function()
  local W = world{crops = {'GRASS_WHEAT_CAVE'}, setup = function(W)
    F.item(W, 'PLANT', {stack_size = 11, mat_type = 419, mat_index = 50})        -- plump helmets: Gordon's rule
    F.item(W, 'PLANT', {stack_size = 40, mat_type = 419, mat_index = 62})        -- prickle berries: seedwatch's leftover
    F.item(W, 'PLANT', {stack_size = 7, mat_type = 419, mat_index = 63})         -- cave wheat: a farmed crop, seeds short
    W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT, t = 419, i = 62}
    W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT, t = 419, i = 63}
  end}
  settle(W)
  local i = W.K.census.i
  T.eq({i.cook_in, i.cook_ban, i.cook_ban_x}, {0, 58, 47}, 'helmets by the config, berries and wheat by exclusions')
  days(W, 1)
  T.eq(lifts(W), {'PLANT:419:62'}, 'only the wild plant: the crop is seedwatch\'s, the helmets the config\'s')
  T.ok(not banned(W, 419, 62) and banned(W, 419, 63) and banned(W, 419, 50))
  days(W, 1)
  T.eq(W.K.census.i.cook_in, 40, 'the berries are cook ingredients now')
  -- the player (or seedwatch) bans them again: not lifted again within the year
  W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT, t = 419, i = 62}
  days(W, 3)
  T.eq(#lifts(W), 1, 'once a year per exclusion')
end)

T.test('BUG-345: nothing is lifted while the kitchen has something else to cook', function()
  local W = world{setup = function(W)
    F.item(W, 'PLANT', {stack_size = 40, mat_type = 419, mat_index = 62})
    F.item(W, 'PLANT', {stack_size = 5, mat_type = 419, mat_index = 63})         -- cookable, no ban
    W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT, t = 419, i = 62}
  end}
  days(W, 2)
  T.eq(W.K.census.i.cook_in, 5)
  T.eq(lifts(W), {})
  T.ok(banned(W, 419, 62))
end)

T.test('BUG-345: ORDER_STUCK PrepareMeal names the banned material and whose ban it is', function()
  local W = world{setup = function(W)
    F.workshop(W, 'Kitchen')
    F.item(W, 'PLANT', {stack_size = 11, mat_type = 419, mat_index = 50})
    F.order(W, {id = 41, job_type = df.job_type.PrepareMeal, amount_left = 5, mat_type = -1, mat_index = -1})
  end}
  W.unit(1).status.labors = {[7] = true}
  days(W, 4)
  local why
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if e.d.job == 'PrepareMeal' then why = e.d.why end end
  T.ok(why and why:find('11 cook-banned (D-09 MUSHROOM_HELMET_PLUMP)', 1, true), tostring(why))
end)

T.test('BUG-345: D-09 yes in a famine takes the plump helmet exclusion off; it comes back after the famine', function()
  local W = world{decisions = {['D-09'] = 'yes'}, food = 0, setup = function(W)
    F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
    W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT, t = 419, i = 50}    -- set before the famine
  end}
  days(W, 2)
  T.ok(not banned(W, 419, 50), 'lifted in the famine')
  T.ok(banned(W, 419, 60), 'the seeds stay banned (the spawn of the farms)')
  T.ok(#W.find_acts('kitchen_include') >= 1)
  for _ = 1, 400 do F.item(W, 'FOOD', {stack_size = 10, subtype = 1}) end
  days(W, 9)
  T.ok(banned(W, 419, 50), 'the famine is over: Gordon\'s rule again')
end)

T.done()
