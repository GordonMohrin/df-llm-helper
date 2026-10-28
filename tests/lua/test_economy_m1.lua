-- economy, package M1 (BUG-103, Run 14 note 74): the supply alarm and the hungry count are about citizens; the census also holds
-- residents (sense.lua), whom no stock of ours feeds. Fails on the commit before the package (32994bb).
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- 10 citizens, two residents (ids 11, 12) in the census; the residents are starving and thirsty, the citizens are fine
local function world()
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  for i = 11, 12 do units[i] = {id = i, resident = true, pos = {190, 23, 133}} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 12 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 400})
  F.item(W, 'FOOD', {stack_size = 400, subtype = 1})
  for i = 1, 10 do W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = 1000} end
  for i = 11, 12 do W.unit(i).counters2 = {thirst_timer = 74000, hunger_timer = 74000} end
  W.load(fresh('economy'))
  return W
end

T.test('BUG-103: two starving residents in the census raise no supply alarm and no hungry count; a citizen does', function()
  local W = world()
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'alarm')), nil, 'residents are not the fort\'s hunger')
  T.eq(W.state().stock.hungry, nil)
  W.unit(1).counters2 = {thirst_timer = 0, hunger_timer = 70000}
  W.unit(2).counters2 = {thirst_timer = 0, hunger_timer = 70000}
  days(W, 1)
  T.eq(select(2, W.K.call('economy', 'alarm')), 'hunger 2', 'two citizens do')
end)
T.done()
