-- BUG-312 (Run 15d Drillchamber y376-y378: every automatic drill 'auto: retry' failed; REFUGE_FAIL 'Kern+: drink 0<38 (3 wells,
-- none wet)' at each start, STRANDED held B1/O1 down, GATE_CRUSH_RISK #2664 at the end): no automatic drill while readiness
-- says refuge_dry or seal's audit finds the kern burrow (the drill's alert burrow) dry; drill.hold names it; the player's
-- drill still runs. wp6_world as tests/lua/test_fix10_famine.lua. Fails on 9ef2ccb (the drill starts: mode DRILL).
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function dworld(fake)
  local units = X.citizens(30, 1, {skills = SKILLS})
  local W = X.world{units = units}
  W.econ = X.economy({drink_d = 200, food_d = 90, meals = 5})
  X.load(W, nil, {W.econ, X.snapshot(), X.runner('P5')})
  local call = W.K.call
  W.K.call = function(mod, name, ...)
    local f = fake[mod .. '.' .. name]
    if f then return true, f(...) end
    return call(mod, name, ...)
  end
  X.run(W, 1200)
  X.equip_all(W)
  X.run(W, 50)
  return W
end

T.test('BUG-312: readiness refuge_dry holds the automatic drill (old: auto: first); with drink back it runs', function()
  local dry = 'Tiefe+ has no drink (drink 0<38, no well)'
  local W = dworld{['readiness.refuge_dry'] = function() return dry end}
  X.run(W, 3600)
  T.eq(W.K.mode(), 'PEACE', 'old code: auto: first with a dry refuge')
  T.eq(X.call(W, 'drill', 'hold'), 'refuge dry')
  dry = nil
  X.run(W, 1300)
  T.eq(W.K.mode(), 'DRILL', 'refuge wet: the automatic drill runs')
end)

T.test('BUG-312: a dry kern burrow (seal audit: drink < need, no wet well) holds it too; the player\'s drill runs', function()
  local kd = {name = 'Kern+', exists = true, drink = 0, need = 38, wells = 3, wet = false}
  local W = dworld{['seal.refuge_drink'] = function(which) if which == 'kern' then return kd end end}
  X.run(W, 3600)
  T.eq(W.K.mode(), 'PEACE', 'old code: auto: first, REFUGE_FAIL Kern+ drink 0<38')
  T.eq(X.call(W, 'drill', 'hold'), 'Kern+ dry')
  T.eq(X.call(W, 'drill', 'start', 'inbox:llm'), true, 'the player\'s drill is his choice')
end)

T.done()
