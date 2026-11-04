-- BUG-375 (Run 16d Plankscale y374-y380: the perimeter stood open 79 days, max-pop hung at 38 beside a queued seal): the
-- open-perimeter freeze (FR-70) is a push to seal. While a seal project is live (runner.pending 'seal') the cap is not
-- frozen at the population; when no seal is queued the freeze applies as before; a seal that finishes (or is cancelled)
-- with the perimeter still open brings the freeze back.
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world(entrances)
  local W = X.world{units = X.citizens(50, 1, {skills = SKILLS}), persist = {}}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.sealq = 0
  function runner.pending(K, tpl) return tpl == 'seal' and W.sealq or 0 end
  W.seal = {name = 'seal', every = {ticks = 600}, x = entrances, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), runner, W.seal}, {'sense', 'gate'})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  return W
end

local LEAKY = {tick = 1, sealed = 0, routes = 3, doors = {}, open = {{pos = {55, 62, 117}, kind = 'floor'},
                                                                  {pos = {61, 55, 117}, kind = 'floor'}}}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

T.test('an open perimeter freezes max-pop at the population only while no seal project is queued', function()
  local W = world(LEAKY)
  day(W, 5)
  T.eq(W.state().pop.cap, 50, 'no seal queued: frozen at the 50 citizens (FR-70, as before)')
  W.sealq = 1
  day(W)
  T.eq(W.state().pop.cap, 55, 'a seal project is queued: the cap is back at its ceiling (old: held at 50 for good)')
  T.eq(W.state().ready.open, 2, 'the perimeter is still open')
  W.sealq = 0
  day(W)
  T.eq(W.state().pop.cap, 50, 'the seal is gone and the perimeter open: frozen again')
end)

T.test('a seal queued from the start: the cap is never frozen', function()
  local W = world(LEAKY)
  W.sealq = 2
  day(W, 6)
  T.eq(W.state().pop.cap, 55)
  T.eq(W.state().ready.fail[1], 'open_perimeter', 'R0 open_perimeter stays until the ways in are closed')
end)

T.done()
