-- BUG-600 / BUG-601 (round 39):
--   600: Run 16a i1 Basementflew y413 and Run 16b i2 Brotherarrow y405 / y412 (`perimeter OPEN 7 d (1 way in)` with floor / pebbles tiles that were
--        gone at the next check, `seal at=last` 'nothing to close', the pop ceiling lowered a day beside a wall that stood): in PEACE a way in
--        counts for the perimeter once the SAME tile has stayed in the entrance check's answer for OPEN_CONFIRM ticks; a finished seal's check
--        (SEAL `sealdone`) is read at once
--   601: Run 16b i2 Brotherarrow y405-y414 (Pop 81 -> 88 -> 86 with the soldiers in armor worn 7-39 %, 'Ceiling 88 (armor 56 %)' made once a
--        year by the plan): the kernel holds max-pop itself while the soldiers wear under DEF.worn_pct percent
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true}
local SEALED = {tick = 1, sealed = 1, routes = 0, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}
local function leaky(x, y) return {tick = 1, sealed = 0, routes = 1, doors = {}, open = {{pos = {x, y, 117}, kind = 'floor'}}} end

local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end
local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

local function audit(W, over)
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'audit'})
  W.frame(0, true)
  local a = {}
  for k, v in pairs(AUDIT_OK) do a[k] = v end
  for k, v in pairs(over or {}) do a[k] = v end
  a.snap = id
  return W.inbox('audit', a, {by = 'follow'})
end

-- confirm: OPEN_CONFIRM as shipped (false) or 0; worn: the military KPI's worn % (nil: leave military as it is); armor_pct: DEF.worn_pct
local function world(o)
  o = o or {}
  local units = X.citizens(o.n or 50, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}, manifest = o.manifest}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = o.entrances or SEALED, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, W.seal}, {'sense', 'gate'})
  local R = X.mod('readiness')
  R.CAPS = {[0] = o.cap or 120, [1] = o.cap or 120, [2] = o.cap or 120, [3] = 250}
  if not o.confirm then R.OPEN_CONFIRM = 0 end
  if not o.armor then R.DEF.worn_pct = 0 end
  if o.worn then
    local real = X.mod('military').kpi
    X.mod('military').kpi = function(K)
      local k = real(K) or {}
      k.soldiers, k.worn = o.soldiers or 12, W.worn
      return k
    end
    W.worn = o.worn
  end
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = o.cap or 120, beauty = 'used_rooms'}})
  return W
end

---------------------------------------------------------------- 600
T.test('BUG-600: a way in counts for the perimeter only after the same tile stayed in the answer for two game days (PEACE); one that is gone ' ..
       'at the next look, or a new tile every day, never counts', function()
  local W = world{confirm = true, entrances = leaky(55, 62)}
  day(W)
  audit(W)
  day(W)
  T.eq(ready(W).open, 0, 'the first sight: young, not counted (old code: 1 way in, R0 open_perimeter at once)')
  T.ok(not has(ready(W).fail, 'open_perimeter'), 'no R0 blocker for a tile one day old')
  T.eq(ready(W).pd, nil)
  day(W, 2)
  T.eq(ready(W).open, 1, 'the same tile two days later: a way in')
  T.ok(has(ready(W).fail, 'open_perimeter'))
  -- a plant that comes and goes: another tile each day
  local W2 = world{confirm = true, entrances = leaky(10, 10)}
  day(W2)
  audit(W2)
  for i = 1, 6 do
    W2.seal.x = leaky(10 + i, 10)
    day(W2)
  end
  T.eq(ready(W2).open, 0, 'a different tile every day never counts')
  T.ok(not has(ready(W2).fail, 'open_perimeter'), T.show(ready(W2).fail))
  T.eq(ready(W2).pd, nil)
end)

T.test('BUG-600: a running open spell counts its ways at once; outside PEACE a new way in is news at once', function()
  local W = world{confirm = true, entrances = SEALED}
  day(W)
  audit(W)
  W.K.set_mode('ALERT', 'test')
  W.seal.x = leaky(55, 62)
  day(W)
  T.eq(ready(W).open, 1, 'ALERT: counted at once')
end)

T.test('BUG-600: the check that follows a finished seal (SEAL sealdone) is read at once: no day of "perimeter OPEN" beside a wall that stands', function()
  local W = world{entrances = leaky(55, 62)}
  day(W)
  audit(W)
  day(W)
  T.eq(ready(W).open, 1)
  T.ok(has(ready(W).fail, 'open_perimeter'))
  W.seal.x = SEALED                                       -- the seal pass has run: sealed, no route
  W.K.emit('SEAL', 'B', 'seal verified: no route', {routes = 0, why = 'sealdone'})
  W.run(60, {skip = 9})
  local r = W.state().ready
  T.eq(r.open, 0, 'the answer of the fresh check, within a minute (old code: the next daily evaluation)')
  T.ok(not has(r.fail, 'open_perimeter'), T.show(r.fail))
end)

---------------------------------------------------------------- 601
T.test('BUG-601: soldiers in armor worn under 60 % hold max-pop at the population after the grace days (named defense_short), a soft gap ' ..
       '(40 % and more) leaves room for one wave, the hold lifts when the armor is worn', function()
  local W = world{n = 100, cap = 120, armor = true, worn = 30}
  day(W, 3)
  audit(W)
  day(W, 2)
  local r = ready(W)
  T.ok(r.as and r.as:find('armor worn 30 %', 1, true), T.show(r.as))
  T.ok(not has(r.fail, 'traps_short'), 'the traps are fine')
  T.eq(W.state().pop.cap, 120, 'not held yet (grace_days)')
  day(W, 22)
  T.eq(W.state().pop.cap, 100, 'held at the population: worn 30 % leaves no room')
  T.eq(W.state().pop.hold, 'defense_short 100')
  W.worn = 50
  day(W, 3)
  T.eq(W.state().pop.cap, 110, 'soft: worn 50 %: 100 citizens + growth_room 10')
  T.eq(W.state().pop.hold, 'defense_short 110+')
  W.worn = 70
  day(W, 3)
  T.eq(W.state().pop.cap, 100, 'BUG-742: worn again, held for clear_days')
  day(W, 8)
  T.eq(W.state().pop.cap, 120, 'armor worn: the hold is lifted')
  T.eq(ready(W).as, nil)
end)

T.test('BUG-601: a short dip (under the grace days), a small fort, and no soldiers hold nothing', function()
  local W = world{n = 100, cap = 120, armor = true, worn = 30}
  day(W, 3)
  audit(W)
  day(W, 10)
  W.worn = 80
  day(W, 20)
  T.eq(W.state().pop.cap, 120, 'worn again before the grace days: never held')
  local W2 = world{n = 15, cap = 120, armor = true, worn = 10}
  day(W2, 3)
  audit(W2)
  day(W2, 30)
  T.ok(W2.state().pop.cap >= 120 or W2.state().pop.cap == 120, 'under armor_pop citizens: no ask')
  T.eq(ready(W2).as, nil)
  local W3 = world{n = 100, cap = 120, armor = true, worn = 10, soldiers = 0}
  day(W3, 3)
  audit(W3)
  day(W3, 30)
  T.eq(W3.state().pop.cap, 120, 'no soldiers: nothing to wear armor')
end)

T.done()
