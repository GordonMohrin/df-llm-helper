-- BUG-051 (Run 13 cause 2, note 2): the drill is refused only for danger (a mode other than PEACE, a lockdown, a hostile in
-- sight), not for traders and not for the runner's phase; it may start once barracks and squads exist. Early squads:
-- a fort of 40+ citizens with a barracks that never left P0/P1 (Run 13: pop 47-59 at P0 for twenty years) staffs them.
local T = require('testlib')
local X = require('wp6_world')
local kmock = require('dfllm.util.k_mock')
local S = X.S
local Z = X.Z

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

-- opts: n, phase (runner phase, default P5), auto, manifest, equip (default true), steps
local function world(opts)
  opts = opts or {}
  local units = X.citizens(opts.n or 30, 1, {skills = SKILLS})
  local W = X.world{units = units, manifest = opts.manifest}
  W.runner = X.runner(opts.phase or 'P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  if not opts.auto then X.mod('drill').SETTLE = 1e9 end
  X.run(W, 1200)
  if opts.equip ~= false then X.equip_all(W) end
  X.run(W, 50)
  return W
end
local function start(W, why) return X.call(W, 'drill', 'start', why or 'test') end
local function hold(W) return X.call(W, 'drill', 'hold') end
local function results(W) return X.call(W, 'drill', 'results') end
local function caravan(state)
  df.global.plotinfo.caravans:insert('#', {trade_state = df.caravan_state.T_trade_state[state]})
end
local function no_caravans() df.global.plotinfo.caravans = kmock.vec{} end
-- the drill is due when asked (hold() evaluates now, no step runs): the settle time is over
local function due(W) X.mod('drill').SETTLE = 100 end
local function stub_call(W, fn)                      -- wrap K.call: fn(mod, name, ...) -> true, value | nil to pass on
  local call = W.K.call
  W.K.call = function(mod, name, ...)
    local ok, v = fn(mod, name, ...)
    if ok then return true, v end
    return call(mod, name, ...)
  end
end

---------------------------------------------------------------- traders
T.test('BUG-051: merchants on the map no longer hold a drill (a manual start, hold(), the automatic start)', function()
  local W = world{auto = true}
  caravan('AtDepot')
  local ok, msg = start(W)
  T.ok(ok, 'a manual drill with merchants at the depot: ' .. tostring(msg))
  T.eq(W.K.mode(), 'DRILL')
  X.run(W, 1300)
  T.eq(W.K.mode(), 'PEACE')
  no_caravans()
  local W2 = world{auto = true}
  caravan('Approaching')
  X.run(W2, 1200)
  T.eq(W2.K.mode(), 'DRILL', 'the automatic first drill runs with a caravan approaching')
  T.ok(W2.find_events('MODE')[#W2.find_events('MODE')].d.why:find('auto: first', 1, true))
  X.run(W2, 1300)
  T.eq(results(W2).last[1].pass, 1, table.concat(results(W2).last[1].fails, ','))
  no_caravans()
end)

T.test('BUG-051: a trade session under way (trade.clock) defers the drill; no merchant standing around does', function()
  local W = world{}
  due(W)
  caravan('AtDepot')
  T.eq(hold(W), nil, 'merchants at the depot, no session: due')
  local trading = true
  stub_call(W, function(mod, name) if mod == 'trade' and name == 'clock' and trading then return true, 'trade' end end)
  local ok, msg = start(W)
  T.eq(ok, false)
  T.ok(msg:find('trade', 1, true), msg)
  T.eq(hold(W), 'trading')
  trading = false
  T.eq(hold(W), nil, 'the session is over: due')
  no_caravans()
end)

---------------------------------------------------------------- danger
T.test('BUG-051: a lockdown or a hostile in sight holds the drill (start refuses, hold() names it); ALERT keeps its text', function()
  local W = world{}
  due(W)
  local lock = true
  stub_call(W, function(mod, name) if mod == 'reflex' and name == 'holding' and lock then return true, 'arrival' end end)
  local ok, msg = start(W)
  T.eq(ok, false)
  T.ok(msg:find('lockdown', 1, true), msg)
  T.eq(hold(W), 'lockdown')
  lock = false
  T.eq(hold(W), nil)
  local h = W.K.census.h
  W.K.census.h = {vis = 3, tick = W.K.now().tick}
  ok, msg = start(W)
  T.eq(ok, false)
  T.ok(msg:find('hostile', 1, true), msg)
  T.eq(hold(W), 'hostile')
  W.K.census.h = h
  W.K.set_mode('ALERT', 'test')
  ok, msg = start(W)
  T.eq(ok, false)
  T.ok(msg:find('PEACE', 1, true), msg)
  T.eq(hold(W), 'mode ALERT')
end)

---------------------------------------------------------------- phase and barracks
T.test('BUG-051: the runner phase no longer gates the automatic drill: barracks and squads do', function()
  local W = world{phase = 'P3'}
  T.ok(X.call(W, 'military', 'kpi').soldiers > 0, 'squad A exists at P3')
  T.eq(hold(W), 'settling')
  due(W)
  T.eq(hold(W), nil, 'due at P3 (it used to be held: phase P3<P5)')
  X.mod('drill').SETTLE = 2400
  X.run(W, 1500)
  T.eq(W.K.mode(), 'DRILL', 'the automatic first drill started at P3')
end)

T.test('BUG-051: no barracks (a Barracks zone read, no station, no barracks room) holds the drill: no barracks', function()
  local man = S.manifest()
  man.stations = nil
  local W = world{manifest = man}
  local saved = {df.civzone_type, df.global.world.buildings}
  df.civzone_type = kmock.enum{'Tomb', 'Office', 'Barracks'}
  df.global.world.buildings = {other = {ANY_ZONE = kmock.vec{{type = df.civzone_type.Tomb}}}}
  due(W)
  T.ok(X.call(W, 'military', 'kpi').soldiers > 0)
  T.eq(hold(W), 'no barracks')
  local v, why = X.call(W, 'military', 'barracks')
  T.eq({v, why}, {false, 'none'})
  df.global.world.buildings.other.ANY_ZONE:insert('#', {type = df.civzone_type.Barracks})
  X.run(W, 1300)                                    -- the answer is cached for a day
  v, why = X.call(W, 'military', 'barracks')
  T.eq({v, why}, {true, 'zone'}, 'a Barracks zone is a barracks')
  T.ok(hold(W) ~= 'no barracks')
  df.civzone_type, df.global.world.buildings = saved[1], saved[2]
end)

T.test('BUG-051: unreadable zones with no manifest evidence do not block (unknown is not a verdict)', function()
  local man = S.manifest()
  man.stations = nil
  local W = world{manifest = man}
  due(W)
  local v, why = X.call(W, 'military', 'barracks')
  T.eq({v, why}, {nil, 'unread'}, 'unknown')
  T.ok(hold(W) ~= 'no barracks', tostring(hold(W)))
end)

---------------------------------------------------------------- early squads
T.test('BUG-051: a fort of 40+ citizens with a barracks staffs squad A at P0, one of 30 does not', function()
  local W = world{n = 45, phase = 'P0'}
  T.ok(X.call(W, 'military', 'kpi').soldiers > 0, 'squads at P0: the barracks stands and 45 >= 40')
  T.eq(X.call(W, 'military', 'barracks'), true)
  local W2 = world{n = 30, phase = 'P0'}
  T.eq(X.call(W2, 'military', 'kpi').soldiers, 0, 'below early_pop: the phase still gates')
  local man = S.manifest()
  man.stations = nil
  local W3 = world{n = 45, phase = 'P0', manifest = man}
  T.eq(X.call(W3, 'military', 'kpi').soldiers, 0, 'no barracks evidence: the phase still gates')
  due(W3)
  T.eq(hold(W3), 'no soldiers')
end)

T.test('BUG-051: early squads are latched: 39 citizens do not release them, early_pop 0 switches the rule off', function()
  local W = world{n = 45, phase = 'P0'}
  T.ok(X.call(W, 'military', 'kpi').soldiers > 0)
  W.K.census.u.cit = 39
  X.run(W, 3700)
  T.ok(X.call(W, 'military', 'kpi').soldiers > 0, '39 of 40: kept')
  W.K.cfg.baseline.military = {early_pop = 0}
  X.run(W, 3700)
  T.eq(X.call(W, 'military', 'kpi').soldiers, 0, 'early_pop 0: the phase gates again and the squads go')
end)

T.test('BUG-051: the automatic drill runs at P0 once barracks and squads exist (Run 13 never drilled)', function()
  local W = world{n = 45, phase = 'P0', auto = true}
  X.run(W, 1200)
  X.equip_all(W)
  X.run(W, 1500)
  local started = false
  for _, e in ipairs(W.find_events('MODE')) do if e.d.to == 'DRILL' then started = true end end
  T.ok(started, 'a drill started at phase P0')
end)

T.done()
