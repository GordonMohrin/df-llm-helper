-- BUG-937 (Run 17 i3 y500 #53473: 'sortie A ended: the mode is PEACE' while the megacerops it was sent against still lived): a kill sortie begun in ALERT /
-- RECOVERY against ONE wild animal outlives the mode (as BUG-675's PEACE sortie does); it ends when the target is dead / gone, or by the other rules.
-- A group, and a sortie begun in ALERT against an invader, keep the old rule. SIEGE / BREACH are untouched (only the PEACE test was changed).
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local Z = S.Z

local function mil_world()
  local W = X.world{n = 50}
  local th = {name = 'threat', every = {ticks = 100000}}
  function th.assess(K) return {fresh = true, inv = 0, great = 0, undead = 0, bd = 0} end
  local sg = {name = 'siege', every = {ticks = 100000}}
  function sg.so_conf(K) return {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800, track_near = 25, foe_cv = 0} end
  local rf = {name = 'reflex', every = {ticks = 100000}}
  function rf.lone_ids(K) return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  function rf.far_ids(K) return {} end
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i = 1, #pts do r[i] = 1 end; return r end
  X.load(W, {'military'}, {th, sg, rf, snap, X.runner('P5')}, {'sense'})
  X.mod('military').UNFIT_PCT = 0
  W.state()
  W.run(9, {skip = 9})
  return W
end
local function sorties(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('SORTIE')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end
local function world(units)
  local W = mil_world()
  for _, x in ipairs(units) do X.add(W, x) end
  W.run(300, {skip = 9})
  return W
end
local CMD = {squad = 'A', target = {100, 100, Z}, unit = 201, approve = true}

T.test('BUG-937: a sortie begun in ALERT against ONE wild animal is not ended when the mode falls to PEACE', function()
  local W = world({X.S.danger(201, 100, 100, Z)})
  W.set_mode('ALERT')
  local r = W.inbox('squad.sortie', CMD)
  T.ok(r.ok, tostring(r.msg))
  W.set_mode('PEACE')                                  -- the animal was cleared as passive, ALERT ended (the live #53469)
  W.run(900, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'old code: sortie A ended: the mode is PEACE')
  T.eq(X.squad_of(W, 'A').orders[0].units, {201}, 'still on it')
end)

T.test('BUG-937: ... and it still ends when the animal is gone (out of sight for idle_ticks)', function()
  local W = world({X.S.danger(201, 100, 100, Z)})
  W.set_mode('ALERT')
  T.ok(W.inbox('squad.sortie', CMD).ok)
  W.set_mode('PEACE')
  W.unit(201)._m.hidden = true                         -- out of sight, alive
  W.run(3000, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1] and ab[1].d.why}, {1, 'gone'}, 'it ended by its own rule: gone')
end)

T.test('BUG-937: a sortie against a group begun in ALERT still ends with the mode (old rule)', function()
  local W = world({X.S.danger(201, 100, 100, Z), X.S.danger(202, 99, 100, Z)})
  W.set_mode('ALERT')
  local r = W.inbox('squad.sortie', {squad = 'A', target = {100, 100, Z}, approve = true})
  T.ok(r.ok, tostring(r.msg))
  W.set_mode('PEACE')
  W.run(900, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab >= 1, ab[1] and ab[1].d.why}, {true, 'mode'}, 'ended with the mode')
end)

T.done()
