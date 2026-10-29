-- BUG-322 (Run 15b Earthboat y385 spr, a siege of 35 goblins): status showed 'PERIMETER OPEN 46 days: 2 ways in' and
-- 'ways in: all with a door or bridge' at once, and `seal at=last` said 'nothing to close'. state ready: open 0,
-- pd 47, pw '2 ways in', mode SIEGE. Outside PEACE readiness kept the text of the last PEACE check for good, while the
-- entrance check (ready.open, the source of the ways-in line and of seal at=last) had moved on. Now the ways in of the
-- signal are the entrance check's of now in every mode; lost bridges keep their last answer outside PEACE.
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world(entrances)
  local W = X.world{units = X.citizens(50, 1, {skills = SKILLS}), persist = {}}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = entrances, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), runner, W.seal}, {'sense', 'gate'})
  return W
end

local SEALED = {tick = 1, sealed = 1, routes = 1, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}
local LEAKY = {tick = 1, sealed = 0, routes = 3, doors = {}, open = {{pos = {55, 62, 117}, kind = 'floor'},
                                                                  {pos = {61, 55, 117}, kind = 'floor'}}}
local ONE = {tick = 1, sealed = 0, routes = 3, doors = {}, open = {{pos = {55, 62, 117}, kind = 'floor'}}}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end

T.test('in a SIEGE the ways in of the open perimeter follow the entrance check: 2 -> 1 way in, then closed (old: ' ..
       '"2 ways in" for good beside open 0)', function()
  local W = world(LEAKY)
  day(W, 3)
  T.eq({ready(W).open, ready(W).pw}, {2, '2 ways in'})
  local pd = ready(W).pd
  W.K.set_mode('SIEGE', 'test')
  W.seal.x = ONE
  day(W)
  T.eq({ready(W).open, ready(W).pw}, {1, '1 way in'}, 'one source: the count of the ways-in line')
  T.ok(ready(W).pd >= pd, 'the days go on: ' .. tostring(ready(W).pd))
  W.seal.x = SEALED
  day(W)
  T.eq({ready(W).open, ready(W).pd, ready(W).pw}, {0, nil, nil}, 'closed during the siege: no PERIMETER OPEN beside "all with a door"')
  for _, f in ipairs(ready(W).fail or {}) do T.ok(f ~= 'open_perimeter', T.show(ready(W).fail)) end
  -- the signal never starts outside PEACE (a lockdown is no news)
  W.seal.x = LEAKY
  day(W)
  T.eq(ready(W).pd, nil, 'not started in a siege')
end)

T.test('perim_now keeps lost bridges and levers, replaces only the ways in', function()
  local R = require('dfllm.readiness')
  T.eq(R.perim_now('2 ways in; bridges lost: O1', 0), 'bridges lost: O1')
  T.eq(R.perim_now('bridges lost: O1; levers lost: B1', 3), '3 ways in; bridges lost: O1; levers lost: B1')
  T.eq(R.perim_now('2 ways in', 0), nil)
  T.eq(R.perim_now(nil, 1), '1 way in')
  T.eq(R.perim_now('?', 0), nil)
end)

T.done()
