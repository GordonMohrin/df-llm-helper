-- BUG-754: runner.repair takes opts.prio (1..7): seal queues a lost bridge's repair first. The default stays 2, a closure 1.
local T = require('testlib')
local H = require('runner_world')

local Z = 143
local CELLS = {{40, 41, Z, 'gw(3x1)'}}

local function world(tag)
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function() return nil end, state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load({name = 'seal', every = {ticks = 50}, opening_ways = function() return {known = true, routes = 2, here = true, here_closable = false, others = 1, age = 0} end,
          closing = function() return 0 end})
  W.load(require('dfllm.runner'))
  W.state()
  return W
end

T.test('BUG-754: repair opts.prio sets the project priority; bad values and no value keep 2; a closure stays 1', function()
  local W = world('prio')
  for x = 39, 43 do for y = 40, 42 do W.tile(x, y, Z).c = '.' end end
  local _, ok1, id1 = W.K.call('runner', 'repair', CELLS, 'bridge O1 lost', {peace = true, prio = 1})
  T.ok(ok1, tostring(id1))
  T.eq(H.proj(W, id1).prio, 1)
  T.eq(W.K.persist.get('bp.' .. id1).params, {peace = 1})
  local _, ok2, id2 = W.K.call('runner', 'repair', CELLS, 'x', {peace = true})
  T.eq(H.proj(W, id2).prio, 2)
  local _, ok3, id3 = W.K.call('runner', 'repair', CELLS, 'x', {peace = true, prio = 9})
  T.eq(H.proj(W, id3).prio, 2, 'out of range: the default')
  local _, ok4, id4 = W.K.call('runner', 'repair', CELLS, 'x', {peace = true, prio = 4})
  T.eq(H.proj(W, id4).prio, 4)
end)

T.done()
