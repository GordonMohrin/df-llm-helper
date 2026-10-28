-- M2 / BUG-110 (Run 14 note 87): a drill without a standing outer AND inner bridge is refused with a fixed sentence by
-- drill.start, the inbox verb and the automatic start: no mode change (no civ alert, no recall, no FPS change); the
-- refusals are counted (state ready.dref, once a game day) and logged once a day.
local T = require('testlib')
local X = require('wp6_world')
local S = X.S
local Z = X.Z

local SENT = 'no lever-linked bridge: build fortcore stage 2/3 first'
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world(man, auto)
  local W = X.world{units = X.citizens(30, 1, {skills = SKILLS}), manifest = man}
  W.runner = X.runner('P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  if not auto then X.mod('drill').SETTLE = 1e9 end
  X.run(W, 1200)
  X.equip_all(W)
  X.run(W, 50)
  return W
end

local function only(role)                                  -- the fort's manifest with the bridges of one role only
  local m = S.manifest()
  for name, b in pairs(m.bridges) do if b.role ~= role then m.bridges[name] = nil end end
  return m
end

local function nlog(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then n = n + 1 end end
  return n
end

T.test('BUG-110: no inner bridge (no_inner): start, the inbox verb and the automatic start refuse; the mode never changes', function()
  local W = world(only('outer'), true)
  T.eq(X.call(W, 'drill', 'gap'), 'no_inner')
  local ok, res, why = W.K.call('drill', 'start', 'test')       -- K.call: ok, then start's (false, sentence, data)
  T.eq({ok, res, why}, {true, false, SENT})
  T.eq(W.K.mode(), 'PEACE')
  local r = W.inbox('drill', {})
  T.eq({r.ok, r.msg}, {false, SENT})
  X.run(W, 6000)                                                 -- the automatic start: nothing, however long
  T.eq(W.K.mode(), 'PEACE')
  T.eq(#W.find_events('DRILL_RESULT'), 0)
  T.eq(X.call(W, 'drill', 'hold'), 'no_inner')
  T.eq(#X.acts(W, 'set_mode'), 0)
end)

T.test('BUG-110: both roles missing: hold says no bridges, a manual drill is refused', function()
  local W = world({v = 2, burrows = S.manifest().burrows}, true)
  T.eq(X.call(W, 'drill', 'gap'), 'no_outer,no_inner')
  local ok, res, why = W.K.call('drill', 'start', 'test')
  T.eq({ok, res, why}, {true, false, SENT})
  X.run(W, 3000)
  T.eq(W.K.mode(), 'PEACE')
  T.eq(X.call(W, 'drill', 'hold'), 'no bridges')
end)

T.test('BUG-110: a bridge replaced by wall + door is no gate: the drill is refused', function()
  local W = world(S.manifest(), false)
  T.eq(X.call(W, 'drill', 'gap'), nil)
  local call = W.K.call
  W.K.call = function(mod, name, ...)
    if mod == 'seal' and name == 'replaced' then return true, {O1 = {t = 1, n = 2, how = 'wall + door', fp = {}}} end
    return call(mod, name, ...)
  end
  T.eq(X.call(W, 'drill', 'gap'), 'no_outer')
  local ok, res, why = W.K.call('drill', 'start', 'test')
  T.eq({ok, res, why}, {true, false, SENT})
end)

T.test('BUG-110: the refusals are counted; state ready.dref and the log move once a game day', function()
  local W = world(only('inner'), false)
  for _ = 1, 5 do W.K.call('drill', 'start', 'test') end
  T.eq(X.call(W, 'drill', 'refused'), 1, 'five refusals in one game day publish the first')
  T.eq(nlog(W, 'drill: refused'), 1, 'one log line a day')
  X.run(W, 1300)                                                 -- a game day later, but not a minute of wall clock (timestream)
  W.K.call('drill', 'start', 'test')
  T.eq(X.call(W, 'drill', 'refused'), 1, 'the wall clock bounds it too')
  W.ms = W.ms + 70000                                            -- a minute of wall clock more ...
  X.run(W, 1300)                                                 -- ... and another game day
  W.K.call('drill', 'start', 'test')
  T.eq(X.call(W, 'drill', 'refused'), 7)
  T.eq(nlog(W, 'drill: refused'), 2)
  X.run(W, 1300)
  T.eq(W.state().ready.dref, 7)
end)

T.test('BUG-110: with outer and inner bridges a drill runs as before', function()
  local W = world(S.manifest(), false)
  local ok, res = W.K.call('drill', 'start', 'test')
  T.eq({ok, res}, {true, true})
  T.eq(W.K.mode(), 'DRILL')
  T.eq(X.call(W, 'drill', 'refused'), 0)
end)

T.done()
