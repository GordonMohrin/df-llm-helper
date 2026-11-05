-- BUG-493 (Run 16d i4 Trumpetrealms y382-y387, i2 Roadvises: `cmd drill` "started", status `drill never`, P5 waits for the drill):
-- a pass needs worn >= 90 and the fort had no metal (worn 20-70 %), so no drill could ever pass. The drill's result now says WHAT
-- failed (DRILL_RESULT `fails`) and whether the bridges worked (`mech` = 1 when only the gear is short); readiness publishes
-- ready.drill_mech_age and the phase deliverable 'drill' (P5) is met by a drill whose bridges worked. The R2 pass (drill_age) is
-- unchanged: worn >= 90 still. The bridge side (the recall streaming over B1, the restore timeout) is
-- tests/lua/test_bug492_493_traffic.lua.
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world(equip, lever_cfg)
  local W = X.world{units = X.citizens(30, 1, {skills = SKILLS}), lever_cfg = lever_cfg}
  W.runner = X.runner('P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  X.mod('drill').SETTLE = 1e9
  X.run(W, 1200)
  if equip then X.equip_all(W) end
  X.run(W, 50)
  return W
end

T.test('BUG-493: no gear -> the drill fails on worn<90 alone: DRILL_RESULT carries fails and mech 1, ready.drill_mech_age is set ' ..
       'while drill_age (the R2 pass) stays -1', function()
  local W = world(false)
  local ok, msg = X.call(W, 'drill', 'start', 'test')
  T.ok(ok, msg)
  X.run(W, 1900)
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.pass, 0)
  T.eq(r[1].d.fails, {'worn<90'})
  T.eq(r[1].d.mech, 1, 'the bridges worked')
  local rd = W.state().ready
  T.eq(rd.drill_age, -1, 'no R2 pass')
  T.ok(rd.drill_mech_age >= 0, 'the bridges worked: ' .. tostring(rd.drill_mech_age))
  T.eq(X.call(W, 'drill', 'results').last[1].mech, 1)
end)

T.test('BUG-493: a bridge that never rises is a mechanics failure: mech 0, no drill_mech_age', function()
  local W = world(true, {[11] = {}, [12] = {}})        -- O1's levers never get a worker
  X.call(W, 'drill', 'start', 'test')
  X.run(W, 1900)
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.mech, 0)
  T.ok(table.concat(r[1].d.fails, ','):find('up:O1', 1, true), table.concat(r[1].d.fails, ','))
  T.eq(W.state().ready.drill_mech_age, -1)
end)

T.test('BUG-493: a full pass is a mech pass too (drill_age and drill_mech_age)', function()
  local W = world(true)
  X.call(W, 'drill', 'start', 'test')
  X.run(W, 1900)
  local rd = W.state().ready
  T.ok(rd.drill_age >= 0 and rd.drill_mech_age >= 0)
  T.eq(W.find_events('DRILL_RESULT')[1].d.mech, 1)
end)

T.test('BUG-493: the phase deliverable `drill` is met by a drill whose bridges worked', function()
  local W = world(false)
  X.call(W, 'drill', 'start', 'test')
  X.run(W, 1900)
  local ok, met = W.K.call('runner', 'deliverable_met', 'drill')
  if ok and met ~= nil then T.eq(met, true) end
  local v = W.K.view().ready
  T.ok(v ~= nil and ((v.drill_age or -1) >= 0 or (v.drill_mech_age or -1) >= 0), 'the view the deliverable reads')
end)

T.done()
