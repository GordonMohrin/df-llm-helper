-- BUG-692 / BUG-694 (Run 16d i4 Trumpetrealms y461 winter, INVASION 38: one goblin inside Kern+ and the refuge shaft killed 49 of 69 citizens in a
-- BREACH while the squads (3-13 soldiers) held no weapon + armor: squad.sortie 'not equipped: 0 of 3', squad.uniform 'not allowed in BREACH', the
-- kernel's own kill order 'worn 0 % < 80 %', the DEATHS_3PLUS default re-applied the lockdown; the unequipped squads stood down OFF DUTY and never
-- fetched the 17-30 pieces DF had assigned them):
--   (1) a few hostiles inside Kern+ that killed (kill mark, or citizens died) and squads 3 to 1: the unequipped squads may go (squad.sortie),
--       only against them; the squads screen (squad.uniform) is open; the kernel starts the sortie itself (kill_inside);
--   (2) nothing of it without a killer / a death, with more than 3 inside, with a great danger or too few soldiers, outside a BREACH;
--   (3) an unequipped squad of a SIEGE / BREACH waits at the refuge anchor on an equip hold (a station order), not off duty.
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local deaths
local function stubs()
  deaths = 0
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return {worn = 80, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  local ca = {name = 'care', every = {ticks = 10}}
  function ca.deaths_recent(K) return deaths end
  return {sg, rf, ca}
end
local function msetup(units, mode)
  local u = X.citizens(50)
  for _, x in ipairs(units or {}) do u[#u + 1] = x end
  local W = X.world{units = u}
  local mods = stubs()
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i in ipairs(pts) do r[i] = 1 end; return r end
  mods[#mods + 1] = snap
  mods[#mods + 1] = X.runner('P5')
  X.load(W, {'military'}, mods, {'sense'})
  W.state()
  W.run(9, {skip = 9})                  -- NOT equipped: the squads hold no weapon and no armor
  W.K.set_mode('SIEGE', 'test')
  if mode ~= 'SIEGE' then W.K.set_mode('BREACH', 'test') end
  W.run(30, {skip = 9})
  X.call(W, 'military', 'posture', 'B2_HOLD')
  W.run(30, {skip = 9})
  return W
end
local function order(W, key) return X.squad_of(W, key).orders[0] end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end
local function kill(W, id) X.call(W, 'sense', 'mark_killer', id) end

T.test('BUG-692: BREACH, one killer goblin inside Kern+, unequipped squads of 3: squad.sortie goes (old: refused "not equipped: 0 of 3"), only ' ..
       'against it', function()
  local W = msetup{X.S.inv(201, 78, 93, Z), X.S.inv(150, 150, 150, Z)}
  kill(W, 201)
  W.run(120, {skip = 9})
  local r = W.inbox('squad.sortie', {squad = 'A', target = {78, 93, Z}, unit = 150, approve = true})
  T.eq(r.ok, false, 'a hostile outside Kern+ is not covered by the exception')
  T.ok(tostring(r.msg):find('is not equipped', 1, true) or tostring(r.msg):find('only against the hostiles inside', 1, true), tostring(r.msg))
  r = W.inbox('squad.sortie', {squad = 'A', target = {78, 93, Z}, unit = 201, approve = true})
  T.ok(r.ok, tostring(r.msg))
  T.eq(order(W, 'A').kind, 'kill')
  T.eq(order(W, 'A').units, {201})
end)

T.test('BUG-692: the squads screen (squad.uniform) is open in that BREACH; without a killer or a death it is refused as before', function()
  local W = msetup{X.S.inv(201, 78, 93, Z)}
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee', approve = true})
  T.eq(r.ok, false, 'a hostile that killed nobody: not allowed in BREACH')
  T.ok(tostring(r.msg):find('not allowed in BREACH', 1, true), tostring(r.msg))
  kill(W, 201)
  W.run(120, {skip = 9})
  r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee', approve = true})
  T.ok(not tostring(r.msg):find('not allowed in BREACH', 1, true), tostring(r.msg))
  -- a death within a day opens it too
  local W2 = msetup{X.S.inv(201, 78, 93, Z)}
  deaths = 4
  r = W2.inbox('squad.uniform', {squad = 'A', kind = 'melee', approve = true})
  T.ok(not tostring(r.msg):find('not allowed in BREACH', 1, true), tostring(r.msg))
end)

T.test('BUG-692: kill_inside sends every squad with members against the killer inside; a second call finds the sorties running', function()
  local W = msetup{X.S.inv(201, 78, 93, Z)}
  local started, msg = X.call(W, 'military', 'kill_inside', 'reflex')
  T.eq(started, false, 'no kill mark, no death: nothing: ' .. tostring(msg))
  kill(W, 201)
  W.run(120, {skip = 9})
  started, msg = X.call(W, 'military', 'kill_inside', 'reflex')
  T.ok(started == true, tostring(msg))
  for _, k in ipairs({'A', 'B', 'C'}) do
    local o = order(W, k)
    T.ok(o and o.kind == 'kill' and o.units[1] == 201, 'squad ' .. k .. ' kill order')
  end
  local go = W.find_events('SORTIE')
  T.ok(#go >= 1 and go[1].d.inside == 1, 'SORTIE event with inside=1')
  started, msg = X.call(W, 'military', 'kill_inside', 'reflex')
  T.ok(started == true and tostring(msg):find('running', 1, true), tostring(msg))
end)

T.test('BUG-692: no exception with 4 hostiles inside, too few soldiers or a SIEGE (no BREACH)', function()
  local W = msetup{X.S.inv(201, 78, 93, Z), X.S.inv(202, 77, 93, Z), X.S.inv(203, 76, 93, Z), X.S.inv(204, 75, 93, Z)}
  for id = 201, 204 do kill(W, id) end
  W.run(120, {skip = 9})
  local started, msg = X.call(W, 'military', 'kill_inside', 'reflex')
  T.eq(started, false)
  T.ok(tostring(msg):find('4 hostiles inside', 1, true), tostring(msg))
  local r = W.inbox('squad.sortie', {squad = 'A', target = {78, 93, Z}, unit = 201, approve = true})
  T.eq(r.ok, false)
  T.ok(tostring(r.msg):find('is not equipped', 1, true), tostring(r.msg))
  -- three hostiles and 8 soldiers in the force: 3 per hostile (9) is not there; with a ratio of 2 it goes
  local W3 = msetup{X.S.inv(201, 78, 93, Z), X.S.inv(202, 77, 93, Z), X.S.inv(203, 76, 93, Z)}
  for id = 201, 203 do kill(W3, id) end
  W3.run(120, {skip = 9})
  local M = X.mod('military')
  started, msg = X.call(W3, 'military', 'kill_inside', 'reflex')
  T.eq(started, false)
  T.ok(tostring(msg):find('fewer than 3 per hostile', 1, true), tostring(msg))
  M.INSIDE_RATIO = 2
  started, msg = X.call(W3, 'military', 'kill_inside', 'reflex')
  M.INSIDE_RATIO = 3
  T.ok(started == true, tostring(msg))
  -- a SIEGE: no BREACH, no exception
  local W4 = msetup({X.S.inv(201, 78, 93, Z)}, 'SIEGE')
  kill(W4, 201)
  W4.run(120, {skip = 9})
  started, msg = X.call(W4, 'military', 'kill_inside', 'reflex')
  T.eq(started, false)
  T.eq(msg, 'not BREACH')
end)

T.test('BUG-694: an unequipped squad in a SIEGE / BREACH waits on an equip hold at the refuge anchor (a station order, not off duty); it keeps ' ..
       'standing down (no sortie, no station against the enemy)', function()
  local W = msetup{}
  local man = W.K.manifest()
  local an = man.refuge and man.refuge.anchor
  T.ok(an, 'the world has a refuge anchor')
  local o = order(W, 'A')
  T.ok(o ~= nil and o.kind == 'station', 'old code: cleared (off duty): ' .. T.show(o))
  T.eq({o.pos.x, o.pos.y, o.pos.z}, {an[1], an[2], an[3]})
  T.ok(logged(W, 'equip hold at'), 'kern.log names the hold')
  local ok, txt = X.call(W, 'military', 'unfit_text', 'A')
  T.ok(tostring(txt or ok):find('is not equipped', 1, true), 'still no sortie of an unequipped squad without a killer')
  -- equipped: the posture station again
  X.equip_all(W)
  W.run(900, {skip = 9})
  local o2 = order(W, 'A')
  T.ok(o2 and o2.kind == 'station' and not (o2.pos.x == an[1] and o2.pos.y == an[2] and o2.pos.z == an[3]), 'the posture station: ' .. T.show(o2))
end)

T.done()
