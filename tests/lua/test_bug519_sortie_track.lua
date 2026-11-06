-- BUG-519 (Run 16a i1 Basementflew y404: the INTRUDER's squad.sortie reached the reported tile 1,212 ticks later, "no visible hostile
-- within 5 tiles" / "nobody within 5 tiles to attack" ended it, the goblin snatcher had walked on): `unit` follows the unit, an empty
-- reported tile takes the nearest hostile within track_near, nobody in sight is refused with the reason, move=true moves anyway.
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local function setup(units)
  local u = X.citizens(50)
  for _, x in ipairs(units or {}) do u[#u + 1] = x end
  local W = X.world{units = u}
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800, track_near = 25} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i = 1, #pts do r[i] = 1 end; return r end
  X.load(W, {'military'}, {sg, rf, snap, X.runner('P5')}, {'sense'})
  -- the fixture's soldiers carry no kit: BUG-510's stand-down of unequipped squads is not what this file tests
  X.mod('military').UNFIT_PCT = 0
  W.state()
  W.run(9, {skip = 9})
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('BREACH', 'test')
  W.run(30, {skip = 9})
  X.call(W, 'military', 'posture', 'B2_HOLD')
  return W
end
local function order(W, key) return X.squad_of(W, key).orders[0] end
local function sorties(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('SORTIE')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end

T.test('BUG-519: unit names the hostile: the kill order follows it, the tile only says where it was', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {60, 100, Z}, unit = 201, approve = true})
  T.ok(r.ok, r.msg)
  T.eq({order(W, 'A').kind, order(W, 'A').units}, {'kill', {201}})
  T.ok(r.msg:find('follows the unit', 1, true) and r.msg:find('100,100', 1, true), r.msg)
  local go = sorties(W, 'go')
  T.eq({#go, go[1].d.units}, {1, {201}})
  -- it walks on: the sortie keeps the new place (census), it does not end at the old tile
  W.move(201, 130, 100, Z)
  W.run(200, {skip = 9})
  T.eq(#sorties(W, 'abort') + #sorties(W, 'done'), 0, 'still running')
  T.eq(order(W, 'A').units, {201})
end)

T.test('BUG-519: a unit that is not in sight is refused with the reason (nothing is sent to an empty place); move=true moves anyway', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {60, 100, Z}, unit = 999, approve = true})
  T.ok(not r.ok and r.msg:find('unit 999 is not in sight', 1, true) and r.msg:find('60,100', 1, true), r.msg)
  T.eq(#sorties(W, 'go'), 0, 'no sortie started')
  r = W.inbox('squad.sortie', {squad = 'A', target = {60, 100, Z}, unit = 999, approve = true, move = true})
  T.ok(r.ok, r.msg)
  T.eq({order(W, 'A').kind, order(W, 'A').pos}, {'station', {x = 60, y = 100, z = Z}})
end)

T.test('BUG-519: an empty reported tile takes the nearest visible hostile; none within track_near is refused', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {90, 100, Z}, approve = true})
  T.ok(r.ok and r.msg:find('kill order on 201', 1, true) and r.msg:find('10 tiles on', 1, true), r.msg)
  T.eq(order(W, 'A').units, {201})
  r = W.inbox('squad.sortie', {squad = 'B', target = {20, 100, Z}, approve = true})
  T.ok(not r.ok and r.msg:find('no hostile in sight within 25 tiles of 20,100', 1, true), r.msg)
  local W0 = setup{}
  r = W0.inbox('squad.sortie', {squad = 'A', target = {20, 100, Z}, approve = true})
  T.ok(not r.ok and r.msg:find('the target is gone', 1, true), r.msg)
end)

T.test('BUG-519: a station sortie that finds the tile empty on arrival follows the hostile that is in sight, else ends naming the gone target', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {120, 100, Z}, approve = true, move = true})
  T.ok(r.ok, r.msg)
  T.eq(order(W, 'A').kind, 'station')
  for _, p in ipairs(X.squad_of(W, 'A').positions) do
    if p.occupant >= 0 then W.move(W.hfs[p.occupant].unit_id, 120, 100, Z) end
  end
  W.run(300, {skip = 9})
  T.eq({order(W, 'A').kind, order(W, 'A').units}, {'kill', {201}}, '20 tiles on, within track_near: the kill order')
  local go = sorties(W, 'go')
  T.ok(#go >= 1 and go[#go].d.units[1] == 201, 'a SORTIE go event names it')
  local W2 = setup{}
  W2.inbox('squad.sortie', {squad = 'B', target = {60, 100, Z}, approve = true, move = true})
  for _, p in ipairs(X.squad_of(W2, 'B').positions) do
    if p.occupant >= 0 then W2.move(W2.hfs[p.occupant].unit_id, 60, 100, Z) end
  end
  W2.run(300, {skip = 9})
  local e = sorties(W2, 'done')
  T.eq({#e, e[1].d.why}, {1, 'no_target'})
  T.ok(e[1].msg:find('the target is gone', 1, true), e[1].msg)
end)

T.done()
