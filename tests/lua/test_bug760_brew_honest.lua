-- BUG-760 (Run 16b i2 Whirledrampart y443-445: drink 176 -> 0 days, DECISION drink_low 'auto: brew' with 8 brews ordered that never ran;
-- order.add knew no brew job): order.add Brew / BrewFruit make the CustomReaction BREW_* order and say what keeps it from running
-- (no Still, no plants, no empty barrel, nobody brews); 'auto: brew' is said only when nothing blocks and the brews moved in 7 days,
-- a brew order that stands still names itself. Fails on the commit before (unknown job, auto: brew with a missing Still).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function world()
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 10})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  return W
end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); for _ = 1, 80 do W.run(1) end end end

local function ids(bl) local o = {} for _, x in ipairs(bl) do o[x[1]] = x[2] end return o end

T.test('BUG-760: order.add Brew makes the brew reaction order and names the missing Still', function()
  local W = world()
  days(W, 1)
  local econ = require('dfllm.economy')
  local ok, msg = econ.verbs['order.add'](W.K, {job = 'Brew', amount = 3}, {by = 't'})
  T.ok(ok, tostring(msg))
  T.ok(msg:find('BREW_DRINK_FROM_PLANT', 1, true), msg)
  T.ok(msg:find('cannot run yet', 1, true) and msg:find('no still', 1, true), msg)
  local o = df.global.world.manager_orders.all[#df.global.world.manager_orders.all - 1]
  T.eq(o.reaction_name, 'BREW_DRINK_FROM_PLANT')
  local ok2, msg2 = econ.verbs['order.add'](W.K, {job = 'BrewFruit', amount = 1}, {by = 't'})
  T.ok(ok2 and msg2:find('BREW_DRINK_FROM_PLANT_GROWTH', 1, true), tostring(msg2))
  local ok3 = econ.verbs['order.add'](W.K, {job = 'Brew', amount = 1, reaction = 'X'}, {by = 't'})
  T.eq(ok3, false)
end)

T.test('BUG-760: no auto: brew without a Still; a standing brew order names its stall after 7 days', function()
  local W = world()
  days(W, 1)
  F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 8, amount_total = 8,
              mat_type = -1, mat_index = -1})
  local econ = require('dfllm.economy')
  local function block()
    local r = {inv = W.K.census.i or {}, days = {drink_d = 3, food_d = 400}, p = W.K.persist.get('m.economy')}
    return econ.drink_block(W.K, W.K.cfg.baseline.economy, r, r.inv)
  end
  local bl, auto = block()
  T.ok(ids(bl).still, 'no still named')
  for _, a in ipairs(auto) do T.ok(a[1] ~= 'brew', 'no auto: brew beside a missing Still') end
  F.workshop(W, 'Still')
  bl, auto = block()
  T.eq(ids(bl).brewstall, nil, 'not yet stalled')
  days(W, 8)
  bl = block()
  local w = ids(bl).brewstall
  T.ok(w and w:find('brews ordered, none ran for 7 days', 1, true), 'stall: ' .. tostring(w))
end)

T.done()
