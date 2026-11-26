-- Neuausrichtung 15b (BUG-905..909, second round; Run 17 i3 Orangering, kernel 7f3706e5): the live crush of citizen 29043 by B1 in ALERT (BRIDGE_CRUSH #38052:
-- soldier 27323 on the footprint, a stream of walkers, the pull of round 15's bounded wait queued at stage 2 and done 117 ticks later) and the rule that replaces
-- the bounded wait: outside SIEGE / BREACH no pull is made, and none is kept, while any unit can reach the footprint before the bridge has moved
-- (gate.reach_hold). SIEGE TRAFFIC tests (b1_world.lua: real sense / threat / siege / gate, walkers with a path DF shows, a hostile that walks, a raised
-- bridge cannot be walked, a unit ON a moving bridge is crushed and recorded). B1 = 3x1 footprint 50..52,40 of the siege world, squad station 51,44, O1 at y=10.
--   (i)   ALERT, one hostile, a soldier ON the footprint, a citizen stream, lever latency 1000: no pull while they can reach it, zero crush, the refusal is said
--   (ii)  the same with a clear approach: B1 is up
--   (iii) PEACE with a crossing every ~300 ticks and latency 1000: no pull ever, ONE DECISION_NEEDED with the numbers
--   (iv)  the return window with the forecast negative (test_bug905_909_b1.lua F4: the squad's soldiers can reach it): B1 stays up
--   (v)   the player's lever in ALERT / SIEGE: inner bridges, up; refused with a unit ON the footprint, queued without
--   (vi)  GATE_CRUSH_RISK names every unit on the footprint (the soldier crushed at O1 was reported as k=citizen)
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local Z = S.Z

local function cat(...)
  local r = {}
  for _, l in ipairs({...}) do for _, v in ipairs(l) do r[#r + 1] = v end end
  return r
end
local function names(W) return table.concat(W.crushed, '; ') end
local function soldiers(ids, pace)
  local r = {}
  for _, id in ipairs(ids) do r[#r + 1] = {id = id, kind = 'soldier', pos = {51, 44}, pace = pace, nopath = true} end
  return r
end
local SHUF = {{0, 0}, {1, 0}, {0, 1}, {1, 1}}

-- a stream of citizens walking over B1 from far out on the attack side (9 ticks a tile: a walker covers a tile per 9 ticks), one every `gap` ticks
local function stream(first, n, gap, id0, y0)
  local acts = {}
  for k = 0, n - 1 do acts[#acts + 1] = {id = (id0 or 200) + k, kind = 'citizen', route = B.route(50 + k % 3, y0 or 4, 70), start = first + gap * k, tpt = 9} end
  return acts
end

---------------------------------------------------------------- (i) / (ii): ALERT
-- the live ALERT case: a soldier standing ON the footprint (leaves it at +900), one beside it, a citizen stream walking onto it (one every 150 ticks),
-- citizen 29043 standing 3 tiles out, ONE hostile 20 tiles out and the measured lever latency 1000
local function alert_stream(o)
  o = o or {}
  local acts = {{id = 27323, kind = 'soldier', pos = {51, 40}, nopath = true,
                 fn = function(W, rel, a) if rel >= 900 and not a.left then a.left = true; W.move(a.id, 51, 44, Z) end end},
                {id = 27354, kind = 'soldier', pos = {51, 41}, still = true, nopath = true},
                {id = 29043, kind = 'citizen', pos = {51, 37}, still = true, nopath = true}}
  return B.build{mode = o.mode or 'ALERT', lock = 'lockdown', lat = 1000, actors = cat(acts, stream(300, 30, 150)), army = {S.inv(250, 51, 20, Z)}}
end

T.test('(i) ALERT, one hostile 20 tiles out, a soldier ON the footprint, a citizen stream walking onto it, lever latency 1000: no pull while anybody can reach ' ..
       'it, zero crush, B1 stays down, GATE_FAIL names who can reach it', function()
  local W = alert_stream()
  B.run(W, 5200)
  local pulls = B.pulls(W, 'B1')
  if os.getenv('DBG') then
    print('pulls', table.concat(pulls, ','), 'ups', table.concat(B.flips(W, 'B1', 'up'), ','), 'crushed', #W.crushed)
    for _, e in ipairs(W.find_events('GATE_FAIL')) do print('GATE_FAIL', e.tick - W.t_start, e.msg) end
  end
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  T.eq(#W.find_events('GATE_CRUSH_RISK'), 0, 'no crush risk')
  T.eq(#pulls, 0, 'no pull while a unit can reach the footprint: ' .. table.concat(pulls, ','))
  T.eq(S.bstate(W, 'B1'), 'down')
  local text
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'B1' then text = text or e.msg end end
  T.ok(text and (text:find('can reach it in', 1, true) or text:find('on the footprint', 1, true)), text)
end)

T.test('(i) the live ambush: citizen 29043 steps onto B1 as the pull is done; with the reach rule no pull is queued in the first place (round 15: stage 2 of the bounded ' ..
       'wait cancelled only for a unit ON the footprint)', function()
  local acts = {{id = 27354, kind = 'soldier', pos = {51, 41}, still = true, nopath = true},
                {id = 29043, kind = 'citizen', pos = {51, 37}, nopath = true,
                 fn = function(W, rel, a)                     -- when the lever worker has had the pull for 36 of its 40 ticks he steps onto the footprint
                   for _, l in ipairs(W.levers) do
                     for i = 0, #l.jobs - 1 do
                       local j = l.jobs[i]
                       if j._w and l.bridge == 'B1' and S.abs_now() - j._w >= 36 and not a.stepped then a.stepped = true; W.move(a.id, 51, 40, Z) end
                     end
                   end
                 end}}
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, actors = acts, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 4000)
  T.eq(#B.pulls(W, 'B1'), 0, 'never pulled with him 3 tiles out')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  T.eq(S.bstate(W, 'B1'), 'down')
end)

T.test('(ii) ALERT, one hostile 20 tiles out, a clear approach (nobody within 24 tiles of B1), lever latency 1000: B1 is pulled and up, nobody crushed', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 1500)
  local ups = B.flips(W, 'B1', 'up')
  if os.getenv('DBG') then print('pulls', table.concat(B.pulls(W, 'B1'), ','), 'ups', table.concat(ups, ',')) end
  T.ok(ups[1] ~= nil and ups[1] <= 900, 'B1 up within 900 ticks: +' .. tostring(ups[1]))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0)
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no refusal')
end)

T.test('(ii) the stream passes: four walkers stand 20 tiles out and walk over B1 (one every 150 ticks); B1 is pulled only once the last one has left the 24 tiles the ' ..
       'census sees, and is then up', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, actors = stream(0, 4, 150, 200, 20), army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 3600)
  local pulls, ups = B.pulls(W, 'B1'), B.flips(W, 'B1', 'up')
  if os.getenv('DBG') then print('pulls', table.concat(pulls, ','), 'ups', table.concat(ups, ',')) end
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  -- the last walker (start 450, 9 ticks a tile) is 24 tiles past the footprint (y=64) after 450 + 44 x 9 = ~850
  T.ok(pulls[1] ~= nil and pulls[1] >= 800, 'first pull only after the last walker had left: +' .. tostring(pulls[1]))
  T.ok(ups[1] ~= nil, 'then up')
end)

---------------------------------------------------------------- (iii) PEACE traffic
T.test('(iii) PEACE with a walker crossing the footprint every ~300 ticks and lever latency 1000: B1 is never pulled and never moves, nobody is crushed; after a game ' ..
       'day ONE peace_stuck and ONE DECISION_NEEDED gate_peace_traffic with the numbers (units, crossings per 1000 ticks, quiet gap, latency)', function()
  local W = B.build{lat = 1000, actors = stream(0, 14, 300)}
  B.run(W, 4800)
  T.eq(#B.pulls(W, 'B1'), 0, 'never pulled')
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local dn = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'gate_peace_traffic' then dn[#dn + 1] = e end end
  if os.getenv('DBG') then for _, e in ipairs(dn) do print('DECISION', e.tick - W.t_start, e.msg) end end
  T.eq(#dn, 1, 'ONE decision')
  local d = dn[1] and dn[1].d or {}
  T.ok(d.bridge == 'B1' and d.lat == 1000 and d.need == 1000 and d.n >= 4 and d.crossings >= 3 and d.gap < 1000 and d.ticks >= 1200, dn[1] and dn[1].msg)
  T.ok(dn[1] and dn[1].msg:find('per 1000', 1, true) and dn[1].msg:find('lever latency 1000', 1, true) and dn[1].msg:find('quiet gap', 1, true), dn[1] and dn[1].msg)
  T.eq(#B.events(W, 'GATE', 'peace_stuck'), 1, 'one peace_stuck')
end)

---------------------------------------------------------------- (v) the player's lever
local function reply(W) return W.replies[#W.replies] end

T.test('(v) the player\'s lever in ALERT: an inner bridge, up: refused with a unit ON the footprint (naming him, no want set), queued without; the soldiers at their ' ..
       'station that hold the kernel\'s own raise do not hold the player\'s; the outer bridge and lever down stay refused', function()
  local W = B.build{mode = 'ALERT', lat = 1000, actors = cat(soldiers({5, 101, 102}, SHUF),
                    {{id = 90, kind = 'citizen', pos = {51, 40}, nopath = true,
                      fn = function(w, rel, a) if rel >= 1500 and not a.left then a.left = true; w.move(a.id, 51, 47, Z) end end}}),
                    army = {S.inv(250, 51, 15, Z)}}                                    -- NO lockdown: the kernel wants nothing up by itself
  B.run(W, 60)
  W.inbox('lever', {bridge = 'B1', want = 'up'})
  T.eq(reply(W).ok, false, 'refused with a citizen ON the footprint')
  T.ok(reply(W).msg:find('citizen 90 on the footprint', 1, true), reply(W).msg)
  T.eq(#B.pulls(W, 'B1'), 0)
  W.inbox('lever', {bridge = 'O1', want = 'up'})
  T.eq(reply(W).ok, false, 'the outer bridge is refused')
  T.ok(reply(W).msg:find('for O1', 1, true) and reply(W).msg:find('inner', 1, true), reply(W).msg)
  W.inbox('lever', {bridge = 'B1', want = 'down'})
  T.eq(reply(W).ok, false, 'lever down is refused')
  T.ok(reply(W).msg:find('lever down not allowed in ALERT', 1, true), reply(W).msg)
  B.run(W, 1600)                                                                       -- he leaves the footprint at +1500
  W.inbox('lever', {bridge = 'B1', want = 'up'})
  T.eq(reply(W).ok, true, 'queued without a unit on the footprint: ' .. tostring(reply(W).msg))
  B.run(W, 900)
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up although the soldiers at their station could reach it (the player decides)')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
end)

T.test('(v) the player\'s lever in SIEGE: the inner bridge, up: refused with a unit on the footprint, queued without; BREACH keeps the emergency-exit rule', function()
  local W = B.build{mode = 'SIEGE', lat = 1000, base = false, actors = {{id = 91, kind = 'citizen', pos = {51, 40}, still = true, nopath = true}},
                    army = {S.inv(250, 51, -40, Z)}, closed = {}, lever = {worker = 30, pull = 40}}
  W.bridges.B1.gate_flags.closed = false
  B.run(W, 20)
  W.inbox('lever', {bridge = 'B1', want = 'up'})
  T.ok(reply(W).ok == false and reply(W).msg:find('citizen 91 on the footprint', 1, true), reply(W).msg)
  W.move(91, 51, 47, Z)
  W.inbox('lever', {bridge = 'B1', want = 'up'})
  T.eq(reply(W).ok, true, tostring(reply(W).msg))
end)

---------------------------------------------------------------- (vi) the report of a crush names every unit
T.test('(vi) GATE_CRUSH_RISK (forced raise, round 3 bounded crush) names every unit ON the footprint, a later one in a further event; the moving one too', function()
  local W = B.build{mode = 'SIEGE', army = {S.inv(250, 51, -40, Z)}}
  local G = package.loaded['dfllm.gate']
  local K = W.K
  local r = {job = {id = 77, queued = 100}}
  local now = K.now().tick
  local cit = {id = 26276, k = 'citizen', d = 0, x = 86, y = 91, z = 142}
  local sol = {id = 27055, k = 'soldier', d = 0, x = 87, y = 91, z = 142}
  G.crush_forced(K, 'O1', r, {cit}, now)
  G.crush_forced(K, 'O1', r, {cit}, now)                         -- the same unit again: nothing
  G.crush_forced(K, 'O1', r, {cit, sol}, now)                    -- the soldier stepped on later: a second event naming HIM
  local ev = W.find_events('GATE_CRUSH_RISK')
  T.eq(#ev, 2, 'two events')
  T.eq(ev[1].d.k, 'citizen')
  T.eq(ev[2].d.k, 'soldier')
  T.eq(ev[2].d.unit, 27055)
  T.ok(ev[2].msg:find('soldier 27055', 1, true) and not ev[2].msg:find('citizen', 1, true), ev[2].msg)
  local r2 = {job = {id = 78, queued = 100}}
  G.crush_forced(K, 'O1', r2, {cit, sol}, now)                   -- both at once: both named
  ev = W.find_events('GATE_CRUSH_RISK')
  T.eq(#ev, 3)
  T.ok(ev[3].msg:find('citizen 26276, soldier 27055', 1, true), ev[3].msg)
  T.eq(ev[3].d.kinds, {'citizen', 'soldier'})
  T.eq(ev[3].d.units, {26276, 27055})
  -- crush_risk of the moving bridge: both named in one event, a third unit later in another
  local m = {to = 'up', pull = 5}
  G.crush_risk(K, 'O1', m, {list = {cit, sol}}, nil)
  local third = {id = 30001, k = 'child', d = 0, x = 86, y = 91, z = 142}
  G.crush_risk(K, 'O1', m, {list = {cit, sol, third}}, nil)
  ev = W.find_events('GATE_CRUSH_RISK')
  T.eq(#ev, 5)
  T.eq(ev[4].d.kinds, {'citizen', 'soldier'})
  T.ok(ev[5].d.k == 'child' and ev[5].d.unit == 30001, ev[5].msg)
end)

T.done()
