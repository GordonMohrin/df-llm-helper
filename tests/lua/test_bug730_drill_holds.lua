-- BUG-730 (Run 16d i4 Trumpetrealms y374: DRILL_FAIL 'worn<90, outside:1/8' several times in a row, the clock held at 30 t/s each time, the plan's
-- projects stalled behind it): an automatic drill is not repeated while the gear alone failed the last one and has not improved
-- (drill.gear_hold), and does not start while a citizen stands outside Kern+ (drill.outside_hold, at most OUT_FORCE ticks).
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world()
  local W = X.world{units = X.citizens(30, 1, {skills = SKILLS})}
  W.runner = X.runner('P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  X.run(W, 1200)
  X.run(W, 50)
  return W
end

T.test('BUG-730 gear_hold: the newest drill failed on the gear alone and the gear did not improve: held; improved, or a year on: free', function()
  local D = require('dfllm.drill')
  local newest = {tick = 1000, pass = 0, mech = 1, worn = 40}
  T.eq(D.gear_hold({worn = 42}, newest, 50000), 'gear: worn 42<90')
  T.eq(D.gear_hold({worn = 50}, newest, 50000), nil, 'ten points better')
  T.eq(D.gear_hold({worn = 95}, newest, 50000), nil, 'worn is there')
  T.eq(D.gear_hold({worn = 42}, newest, 1000 + D.GEAR_RECHECK), nil, 'a year on: look again')
  T.eq(D.gear_hold({worn = 42}, {tick = 1000, pass = 0, mech = 0, worn = 40}, 50000), nil, 'a mechanics failure is retried as before')
  T.eq(D.gear_hold({worn = 42}, {tick = 1000, pass = 1, mech = 1, worn = 40}, 50000), nil, 'a pass')
end)

T.test('BUG-730: one gear-only drill fails, and no automatic retry follows within two retry waits while the gear stays short', function()
  local W = world()
  local ok, msg = X.call(W, 'drill', 'start', 'test')
  T.ok(ok, msg)
  X.run(W, 1900)
  local r = W.find_events('DRILL_RESULT')
  T.eq({#r, r[1].d.fails, r[1].d.mech}, {1, {'worn<90'}, 1})
  X.run(W, 80000)
  T.eq(#W.find_events('DRILL_RESULT'), 1, 'no second drill')
  local hold = X.call(W, 'drill', 'hold')
  T.ok(hold and hold:find('gear: worn', 1, true), tostring(hold))
end)

T.test('BUG-730 outside_hold: a citizen outside Kern+ holds an automatic drill for OUT_FORCE ticks at most', function()
  local W = world()
  local D = require('dfllm.drill')
  local K = W.K
  local cu = K.census.u
  local old = cu.outside
  cu.outside = 2
  T.eq(D.outside_hold(K, 1000), 'outside: 2')
  T.eq(D.outside_hold(K, 1000 + D.OUT_FORCE - 1), 'outside: 2')
  T.eq(D.outside_hold(K, 1000 + D.OUT_FORCE), nil, 'after OUT_FORCE the drill starts and recalls as before')
  cu.outside = 0
  T.eq(D.outside_hold(K, 99999), nil)
  cu.outside = 1
  T.eq(D.outside_hold(K, 100000), 'outside: 1', 'the clock of the hold starts again')
  cu.outside = old
end)

T.done()
