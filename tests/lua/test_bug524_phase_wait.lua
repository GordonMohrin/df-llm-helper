-- BUG-524: the status line of a phase that waits for an `orders` deliverable names what the library's stage lacks (economy.held_why):
-- 'orders_rockstock stone 3/60' instead of 'orders_rockstock' for 8 years. An economy that names nothing leaves the plain key.
local T = require('testlib')
local H = require('runner_world')
local C = require('dfllm.util.contract')
local runner = require('dfllm.runner')

local PHASES = {
  {id = 'P0', title = 'p0', approve = false, deliver = {{k = 'orders', lib = 'library/rockstock'}}},
  {id = 'P1', title = 'p1', approve = false, deliver = {}},
}

local function fresh(tag, held)
  local W = H.world{tag = tag, phases = {v = 2, kind = 'phases', phases = PHASES}}
  df.workshop_type = require('dfllm.util.k_mock').enum{'Carpenters', 'Still', 'Butchers'}
  W.load(runner)
  if held ~= nil then
    W.load({name = 'economy', every = {ticks = 1200}, imported = function() return false end,
            held_why = function() return held end})
  end
  return W
end

T.test('BUG-524: phw.wait carries what the library stage lacks', function()
  local W = fresh('held', 'stone 3/60')
  H.runs(W, 2)
  local s = W.state()
  T.eq(s.phase, 'P0')
  T.eq(s.phw and s.phw.wait, {'orders_rockstock stone 3/60'})
  T.eq(C.check_state(s), {}, 'the state keeps its contract (40 bytes a line)')
end)

T.test('BUG-524: a long answer is cut at the 40 bytes the state allows', function()
  local W = fresh('long', 'no MetalsmithsForge,no Smelter,stone 123/60,no fuel')
  H.runs(W, 2)
  local s = W.state()
  T.eq(#s.phw.wait[1] <= 40, true)
  T.eq(C.check_state(s), {})
end)

T.test('BUG-524: an economy that names nothing leaves the plain key', function()
  local W = fresh('plain', false)
  H.runs(W, 2)
  T.eq(W.state().phw.wait, {'orders_rockstock'})
end)

T.done()
