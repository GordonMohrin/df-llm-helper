-- BUG-510 (Run 16a i1 Basementflew y406 summer: a siege of 15 goblins and a cave dragon, pop 99 -> 31, soldiers 21 -> 2; "SIEGE
-- refill: squad A 1 -> 5 of 5 with healthy civilians", 2 of 19 soldiers equipped, metal 0, worn 0 %): in a SIEGE or BREACH a squad of
-- which fewer than military.UNFIT_PCT (30) percent hold a real weapon AND wear body armor is not stationed (its order is cleared, it
-- goes off duty and the civ alert keeps it with the civilians in the refuge) and is not sent out (squad.sortie, kill_lone, siege's
-- gate sortie); an equipped squad is stationed as before; in PEACE nothing changes.
local T = require('testlib')
local X = require('wp6_world')

local function boot(n)
  local W = X.world{n = n or 50}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end
local function orders(s)
  local o = s.orders[0]
  return o and (o.kind .. (o.pos and string.format('@%d,%d,%d', o.pos.x, o.pos.y, o.pos.z) or '')) or ''
end
local function members(W, s)
  local r = {}
  for _, p in ipairs(s.positions) do if p.occupant >= 0 then r[#r + 1] = W.hfs[p.occupant].unit_id end end
  return r
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end
local function kpi(W) return X.call(W, 'military', 'kpi') end

T.test('BUG-510: SIEGE, unequipped squads get no station (order cleared, off duty); kern.log says why; the KPI does not count a ' ..
       'station miss', function()
  local W = boot()
  local A, B, C = X.squad_of(W, 'A'), X.squad_of(W, 'B'), X.squad_of(W, 'C')
  X.call(W, 'military', 'posture', 'READY_STATION')
  T.eq(orders(A), 'station@51,44,10', 'PEACE posture: stationed (old rule: unequipped soldiers too)')
  W.K.set_mode('SIEGE', 'test')
  X.call(W, 'military', 'posture', 'READY_STATION', true)
  W.run(30, {skip = 9})
  T.eq({orders(A), orders(B), orders(C)}, {'', '', ''}, 'stood down')
  T.ok(logged(W, 'military: SIEGE: squad A stands down: 0 of 3 soldiers hold a real weapon and wear body armor (< 30 %)'),
       'kern.log names the squad')
  local k = kpi(W)
  T.ok((k.sd or 0) >= 3, 'the KPI counts the soldiers standing down: ' .. tostring(k.sd))
  T.eq(k.off and k.off.nost, nil, 'no "no station" miss')
  -- the player's sortie is refused with the reason (no hostile needed)
  local r = W.inbox('squad.sortie', {squad = 'A', target = {58, 36, X.Z}, approve = true})
  T.eq(r.ok, false)
  T.ok(tostring(r.msg):find('sortie refused: squad A is not equipped: 0 of 3 soldiers', 1, true), tostring(r.msg))
end)

T.test('BUG-510: equipped again -> the squad takes its station (kern.log); a squad with 1 of 3 equipped (33 %) is stationed, 0 of 3 ' ..
       'is not', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  W.K.set_mode('SIEGE', 'test')
  X.call(W, 'military', 'posture', 'READY_STATION', true)
  W.run(30, {skip = 9})
  T.eq(orders(A), '', 'bare squad: stood down')
  local ids = members(W, A)
  T.eq(#ids, 3)
  X.equip(W, ids[1])                                   -- 1 of 3 = 33 % >= 30 %
  W.run(700, {skip = 9})
  T.eq(orders(A), 'station@51,44,10', 'one in three is equipped: stationed')
  T.ok(logged(W, 'squad A is equipped again (1 of 3)'), 'kern.log says so')
  -- he loses the kit again: 0 of 3
  W.unit(ids[1]).inventory = require('dfllm.util.k_mock').vec{}
  W.run(700, {skip = 9})
  T.eq(orders(A), '', 'bare again: stood down')
end)

T.test('BUG-510: PEACE and DRILL are untouched: unequipped squads keep their posture station', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  X.call(W, 'military', 'posture', 'READY_STATION')
  W.run(30, {skip = 9})
  T.eq(orders(A), 'station@51,44,10', 'PEACE')
  W.K.set_mode('DRILL', 'test')
  X.call(W, 'military', 'posture', 'READY_STATION', true)
  W.run(30, {skip = 9})
  T.eq(orders(A), 'station@51,44,10', 'DRILL')
  T.eq(X.call(W, 'military', 'unfit_text', 'A'), nil, 'no refusal text outside SIEGE / BREACH')
end)

T.test('BUG-510: military.unfit_text names the squad in a SIEGE / BREACH only', function()
  local W = boot()
  W.K.set_mode('SIEGE', 'test')
  local ok, txt = X.call(W, 'military', 'unfit_text', 'A')
  T.ok(ok == nil or ok == true or ok, 'call ran')
  T.ok(tostring(txt or ok):find('squad A is not equipped: 0 of 3 soldiers hold a real weapon and wear body armor (< 30 %)', 1, true),
       tostring(txt or ok))
  X.equip_all(W)
  T.eq(X.call(W, 'military', 'unfit_text', 'A'), nil, 'equipped: no refusal')
end)

T.done()
