-- Neuausrichtung 15 (BUG-905..909, Run 17 i3 Orangering, kernel b8160ba3): the inner bridge B1 (footprint 85-87,64,142) was DOWN when the alarms
-- came and then did not rise: GATE_FAIL five times in one evening, soldiers of squads 99/100 one to three tiles from the footprint 'on their way to
-- station 86,60,142', citizens on or walking onto it; raised only by the player's lever. Diagnosis leitung/neu10/DIAGNOSE-B1-2026-11-25.md.
-- The siege world's B1 is the same shape: a 3x1 footprint 50..52,40, the squad station 4 tiles on its inner side (51,44). Every case is a SIEGE
-- TRAFFIC test (b1_world.lua: real sense / threat / siege / gate, citizens and soldiers that walk with a path DF shows, a hostile that walks, a raised
-- bridge cannot be walked, a unit ON a moving bridge is crushed). The numbers they pin (ticks from the first frame) are in bugs/BUG-905..909.
--   F1 (BUG-905) PEACE: soldiers at their station and units far away do not keep the quiet raise waiting; units near it / walking onto it still do
--   F2 (BUG-906) the station clearance is RAISE_R + spread: ALERT with soldiers pacing at 3 tiles -> STATION_MOVED, B1 up; no tile clear -> stand by order
--   F3 (BUG-907) ALERT / RECOVERY / lockdown: the wait for walkers is bounded (450 / 1500 ticks); a unit ON the footprint always holds
--   F4 (BUG-908) the return window is only opened when the re-raise is possible; a bridge wanted up for a game day names who holds it
--   F5 (BUG-909) SIEGE against building destroyers only: a unit standing beside the footprint does not hold it while the destroyer closes
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local Z = S.Z

local SHUF = {{0, 0}, {1, 0}, {0, 1}, {1, 1}}                       -- the soldiers' tiles about the station (51,44): 4 and 5 tiles from B1
local function soldiers(ids, pace)
  local r = {}
  for _, id in ipairs(ids) do
    r[#r + 1] = {id = id, kind = 'soldier', pos = {51, 44}, pace = pace or SHUF, nopath = true}
  end
  return r
end
local function cat(...)
  local r = {}
  for _, l in ipairs({...}) do for _, v in ipairs(l) do r[#r + 1] = v end end
  return r
end
local function names(W) return table.concat(W.crushed, '; ') end

---------------------------------------------------------------- F1: PEACE
T.test('F1 PEACE (BUG-905): four soldiers shuffling at the station 4 tiles inside B1 and a citizen 15 tiles out walking elsewhere: B1 is ' ..
       'pulled after the quiet window (lever latency 645), up within ~800 ticks, nobody crushed', function()
  local W = B.build{lat = 645, actors = cat(soldiers({5, 101, 102, 103}),
                    {{id = 60, kind = 'citizen', route = B.patrol(66, 72, 55, 40)}})}
  B.run(W, 2300)
  local pulls, ups, w0 = B.pulls(W, 'B1'), B.flips(W, 'B1', 'up'), B.want_t(W)
  if os.getenv('DBG') then print('want', w0, 'pulls', table.concat(pulls, ','), 'ups', table.concat(ups, ','), 'crushed', #W.crushed) end
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  T.ok(w0 ~= nil and pulls[1] ~= nil and pulls[1] - w0 >= 645 and pulls[1] - w0 <= 760, 'pulled after the 645-tick quiet window, not before: want +' .. tostring(w0) .. ', pull +' .. tostring(pulls[1]))
  T.ok(ups[1] ~= nil and ups[1] - w0 <= 850, 'B1 up within ~800 ticks of the want: +' .. tostring(ups[1] and ups[1] - w0))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.find_events('GATE_CRUSH_RISK'), 0)
end)

T.test('F1 PEACE (BUG-905): a citizen 4 tiles from B1 walking onto it: no pull while he does, the pull after he has crossed; nobody crushed', function()
  local W = B.build{lat = 645, actors = cat(soldiers({5, 101, 102, 103}),
                    {{id = 61, kind = 'citizen', route = B.route(51, 36, 70), start = 1000}})}   -- he sets off at +1000, inside the quiet window
  local cross_t
  local function watch(w, rel)
    if not cross_t then local _, y = B.at(w, 61); if y >= 41 then cross_t = rel end end
  end
  local at = {}
  for t = 0, 3000, 9 do at[#at + 1] = {t, function(w, now) B.step(w, now); watch(w, now - (w.t0 or now)) end} end
  S.run(W, 3000, {at = at})
  local pulls, ups = B.pulls(W, 'B1'), B.flips(W, 'B1', 'up')
  if os.getenv('DBG') then print('cross', cross_t, 'pulls', table.concat(pulls, ','), 'ups', table.concat(ups, ',')) end
  T.ok(cross_t ~= nil, 'he crossed')
  T.ok(cross_t > 1000, 'he crossed after the quiet window had started: +' .. tostring(cross_t))
  T.ok(pulls[1] ~= nil and pulls[1] > cross_t + 600, 'no pull while he walks onto it and a whole quiet window after (crossed at +' .. tostring(cross_t) .. '), first pull +' .. tostring(pulls[1]))
  T.ok(ups[1] ~= nil, 'raised after he has crossed')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
end)

T.test('F1 PEACE (BUG-905): a citizen standing 6 tiles from B1 (inside) still keeps the quiet raise waiting (BUG-831 stays); after a game day GATE ' ..
       'peace_stuck names him by kind and distance, once', function()
  local W = B.build{lat = 645, actors = cat(soldiers({5, 101}), {{id = 62, kind = 'citizen', pos = {56, 46}, still = true}})}
  B.run(W, 2000)
  T.eq(S.bstate(W, 'B1'), 'down', 'not raised: he stands within 8 tiles')
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  local ev = B.events(W, 'GATE', 'peace_stuck')
  T.eq(#ev, 1, 'one peace_stuck event')
  T.ok(ev[1] and ev[1].msg:find('citizen 62 (6 tiles)', 1, true), ev[1] and ev[1].msg)
  T.ok(ev[1] and ev[1].d.ticks >= 1200 and ev[1].d.units[1] == 62, 'after a game day, names the unit')
  T.eq(#W.crushed, 0)
end)

T.test('F1 PEACE (BUG-905): a unit standing 14 tiles out with no path onto the footprint does not hold the raise; one standing 7 tiles out does', function()
  local W = B.build{lat = 645, actors = {{id = 63, kind = 'citizen', pos = {51, 54}, still = true}}}
  B.run(W, 2300)
  T.eq(S.bstate(W, 'B1'), 'up', 'raised with a unit standing 14 tiles away')
  local W2 = B.build{lat = 645, actors = {{id = 64, kind = 'citizen', pos = {51, 47}, still = true}}}
  B.run(W2, 2300)
  T.eq(S.bstate(W2, 'B1'), 'down', 'not raised with a unit 7 tiles away')
end)

---------------------------------------------------------------- F2: station clearance, stand by order
local PACE3 = {{0, -1}, {0, 0}, {1, -1}, {1, 0}}                  -- soldiers pacing at 3 and 4 tiles from B1 (station 51,44)
local function alert_world(o)
  return B.build{mode = 'ALERT', lock = 'lockdown', real_mil = true, hidden = o and o.hidden,
                 actors = cat(soldiers({5, 101, 102, 103}, PACE3), o and o.actors or {}),
                 army = {S.inv(250, 51, 15, Z)}}                    -- ONE hostile 25 tiles from B1, on the attack side, standing
end

T.test('F2 ALERT (BUG-906): a lone hostile 25 tiles out, the station 4 tiles from B1 and its soldiers pacing at 3 tiles: the station is MOVED ' ..
       '(STATION_MOVED, not kept) within 300 ticks and B1 is up within 800; nobody crushed', function()
  local W = alert_world()
  B.run(W, 1200)
  local sm = B.events(W, 'STATION_MOVED', 'hold')
  local ups, w0 = B.flips(W, 'B1', 'up'), nil
  local bl = B.events(W, 'GATE', 'blocked')
  w0 = bl[1] and bl[1].tick - W.t_start or 0
  if os.getenv('DBG') then print('want', w0, 'sm', sm[1] and sm[1].tick - W.t_start, 'ups', table.concat(ups, ','), 'station', W.squad1.orders[1].pos.y) end
  T.eq(W.K.mode(), 'ALERT')
  T.ok(#sm >= 1 and sm[1].tick - W.t_start - w0 <= 300, 'STATION_MOVED within 300 ticks of the first hold: ' .. tostring(sm[1] and sm[1].msg))
  T.ok(sm[1] and sm[1].d.to and sm[1].d.to[2] >= 45, 'to a tile 5 tiles from the footprint: ' .. tostring(sm[1] and sm[1].d.to and sm[1].d.to[2]))
  T.ok(W.squad1.orders[1].pos.y >= 45, 'the squad has the new station order')
  T.ok(ups[1] ~= nil and ups[1] - w0 <= 800, 'B1 up within 800 ticks of the first hold: +' .. tostring(ups[1] and ups[1] - w0))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  T.eq(#W.find_events('GATE_FAIL'), 0)
end)

T.test('F2 ALERT (BUG-906): no tile clear of B1 can be found (nothing revealed): STATION_MOVED none says so ONCE with the tiles tried and that the soldiers ' ..
       'stand by order; they hold nothing (B1 up past the pacers, not crushed); a soldier ON the footprint still holds it', function()
  local W = alert_world{hidden = true}
  B.run(W, 1200)
  local none = B.events(W, 'STATION_MOVED', 'none')
  T.eq(#none, 1, 'said once per alarm')
  T.ok(none[1] and none[1].d.standby == true and none[1].d.tiles > 100 and none[1].d.tried:find('bridge B1', 1, true), 'tiles tried: ' .. tostring(none[1] and none[1].d.tiles))
  T.ok(none[1] and none[1].msg:find('stand by order', 1, true) and none[1].msg:find('tiles tried', 1, true), none[1] and none[1].msg)
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up past the soldiers standing by order')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  -- a soldier ON the footprint holds the raise whatever the order says (never raised onto him)
  local W2 = alert_world{hidden = true, actors = {{id = 110, kind = 'soldier', pos = {51, 40}, still = true, nopath = true}}}
  B.run(W2, 2400)
  T.eq(S.bstate(W2, 'B1'), 'down', 'not raised onto the soldier ON the footprint')
  T.eq(#W2.crushed, 0)
  local f = W2.find_events('GATE_FAIL')
  T.ok(#f >= 1 and f[1].msg:find('soldier 110 on the footprint', 1, true), f[1] and f[1].msg)
end)

T.test('F2 military.clearance: stations.clear (default 4 = RAISE_R + spread, never below margin + spread); 2 = the old BUG-032 clearance', function()
  local W = alert_world()
  local mil = package.loaded['dfllm.military']
  local G = package.loaded['dfllm.gate']
  T.eq(mil.CLEAR, G.RAISE_R + mil.SPREAD, 'default clearance = RAISE_R + spread')
  -- stations.clear = 2: the station at 4 tiles is clear and 'kept' (the pre-BUG-906 behaviour; the soldiers at 3 tiles hold the raise)
  local W2 = B.build{mode = 'ALERT', lock = 'lockdown', real_mil = true, cfg = {reflex = {v = 2, stations = {clear = 2}}},
                     actors = soldiers({5, 101, 102, 103}, PACE3), army = {S.inv(250, 51, 15, Z)}}
  B.run(W2, 1200)
  T.eq(#B.events(W2, 'STATION_MOVED', 'hold'), 0, 'clear = 2: not moved')
  local up2 = B.flips(W2, 'B1', 'up')
  T.ok(up2[1] ~= nil and up2[1] >= 450, 'clear = 2: the pacers hold the raise until the bounded wait (BUG-907) lets it go: +' .. tostring(up2[1]))
end)

---------------------------------------------------------------- F3: bounded wait outside SIEGE / BREACH
local function stream_world(o)
  local acts = {{id = 120, kind = 'soldier', pos = {51, 41}, still = true, nopath = true}}       -- one soldier standing beside B1 (1 tile)
  for k, y in ipairs({37, 35, 32}) do                             -- three citizens crossing as a stream, 3, 5 and 8 steps from the footprint
    acts[#acts + 1] = {id = 120 + k, kind = 'citizen', route = B.route(50 + k - 1, y, 70), start = 0}
  end
  for _, a in ipairs(o and o.actors or {}) do acts[#acts + 1] = a end
  return B.build{mode = o and o.mode or 'ALERT', lock = 'lockdown', actors = acts, army = not (o and o.nofoe) and {S.inv(250, 51, 20, Z)} or nil}   -- ONE hostile, 20 tiles out
end

T.test('F3 ALERT (BUG-907): a hostile 20 tiles out, three citizens crossing as a stream and a soldier standing beside B1: the wait is bounded: ' ..
       'GATE bounded stage 1 at +450, stage 2 at +1500, B1 up by +1500+; nobody on the footprint when it moves, nobody crushed', function()
  local W = stream_world()
  B.run(W, 2400)
  local ups, pulls = B.flips(W, 'B1', 'up'), B.pulls(W, 'B1')
  local bd = B.events(W, 'GATE', 'bounded')
  if os.getenv('DBG') then
    print('pulls', table.concat(pulls, ','), 'ups', table.concat(ups, ','), 'crushed', #W.crushed)
    for _, e in ipairs(bd) do print('bounded', e.tick - W.t_start, e.d.stage, e.msg) end
  end
  T.eq(#bd, 2, 'two stage events')
  T.eq({bd[1].d.stage, bd[2].d.stage}, {1, 2})
  local w0 = bd[1].tick - W.t_start - 450
  T.ok(bd[2].tick - W.t_start - w0 >= 1500, 'stage 2 after BOUND_FOOT ticks')
  T.ok(ups[1] ~= nil and ups[1] <= w0 + 1500 + 250, 'B1 up by want + 1500 (+ the pull): +' .. tostring(ups[1]) .. ' want +' .. w0)
  T.ok(pulls[1] ~= nil and pulls[1] >= w0 + 1500, 'the soldier beside it held the raise until stage 2: pull +' .. tostring(pulls[1]))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  T.eq(#W.find_events('GATE_CRUSH_RISK'), 0)
end)

T.test('F3 ALERT (BUG-907): the same with one citizen standing ON the footprint the whole time: B1 stays down, nobody crushed, GATE_FAIL names him ' ..
       '(the correct refusal)', function()
  local W = stream_world{actors = {{id = 130, kind = 'citizen', pos = {51, 40}, still = true, nopath = true}}}
  B.run(W, 3600)
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(#B.pulls(W, 'B1'), 0, 'never pulled onto him')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local f = W.find_events('GATE_FAIL')
  T.ok(#f >= 1 and f[1].msg:find('citizen 130 on the footprint', 1, true), f[1] and f[1].msg)
  T.ok(f[1] and f[1].d.units[1] == 130)
end)

T.test('F3 RECOVERY (BUG-907): the bound holds in RECOVERY too; PEACE with no lockdown and no hostile keeps the quiet rule (no stage events)', function()
  local W = stream_world{mode = 'RECOVERY', nofoe = true}         -- (a hostile in sight would make it SIEGE: reentry)
  B.run(W, 2400)
  T.eq(#B.events(W, 'GATE', 'bounded'), 2, 'two stage events')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local W2 = B.build{actors = {{id = 120, kind = 'soldier', pos = {51, 41}, still = true, nopath = true}}}
  B.run(W2, 3000)
  T.eq(#B.events(W2, 'GATE', 'bounded'), 0, 'no stage event in quiet PEACE')
  T.eq(S.bstate(W2, 'B1'), 'down', 'a soldier beside B1 keeps the quiet raise waiting (BUG-831)')
end)

T.test('F3 ALERT cost (BUG-907): a gapless recall stream (a citizen every 150 ticks, 27 ticks a tile) with a hostile 20 tiles out: B1 is up by the end of ' ..
       'stage 2 and the walkers past stage 2 are the accepted price: crushed only after +1500, never before', function()
  local acts = {}
  for k = 0, 40 do acts[#acts + 1] = {id = 200 + k, kind = 'citizen', route = B.route(50 + k % 3, 28, 70), start = 150 * k} end
  local W = B.build{mode = 'ALERT', lock = 'lockdown', actors = acts, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 4500)
  local ups = B.flips(W, 'B1', 'up')
  if os.getenv('DBG') then
    print('ups', table.concat(ups, ','), 'crushed', #W.crushed)
    for _, c in ipairs(W.crushed) do print('  ', c) end
  end
  T.ok(ups[1] ~= nil, 'B1 rose although the stream never stops')
  for _, c in ipairs(W.crushed) do
    T.ok(tonumber(c:match('at %+(%d+)')) >= 1500, 'crushed before stage 2: ' .. c)
  end
  T.ok(#W.crushed <= 2, 'crushed: ' .. names(W))
end)

---------------------------------------------------------------- F5: SIEGE against building destroyers only
local TROLL = 77
local function dragon_world(o)
  local W = B.build{mode = 'SIEGE', actors = o.actors, army = {S.inv(300, 51, -44)},
                    foes = {{id = 300, x = 51, y0 = -44, y1 = 38, tpt = 10}}}      -- 84 tiles from B1, 10 ticks a tile
  local lvl, flag = {flags = {}, misc = {buildingdestroyer = 1}}, {flags = {BUILDINGDESTROYER = true}}
  df.creature_raw = {find = function(r) if r == TROLL then return {caste = {[0] = lvl, [1] = flag}} end end}
  local u = W.unit(300)
  u.race, u.caste = TROLL, 0
  return W
end

T.test('F5 SIEGE vs a building destroyer alone (BUG-909): a cave dragon 84 tiles from B1 at 10 ticks a tile and a citizen standing beside B1: ' ..
       'B1 is up before the dragon is within 20 tiles (eta bound, GATE_FORCED names the reason); nobody crushed', function()
  local W = dragon_world{actors = {{id = 140, kind = 'citizen', pos = {51, 41}, still = true, nopath = true}}}
  B.run(W, 1100)
  local h = W.K.census.h
  T.ok(type(h) == 'table' and (h.bd or 0) >= 1, 'the census sees the destroyer')
  local ups = B.flips(W, 'B1', 'up')
  if os.getenv('DBG') then
    print('ups', table.concat(ups, ','), 'pulls', table.concat(B.pulls(W, 'B1'), ','), 'crushed', #W.crushed)
    for _, e in ipairs(W.find_events('GATE_FORCED')) do print('FORCED', e.tick - W.t_start, e.msg) end
  end
  T.ok(ups[1] ~= nil, 'B1 rose')
  -- the dragon is within 20 tiles of B1 at +640; the bridge needs 100 ticks to move
  T.ok(ups[1] + W.move_ticks <= 640, 'B1 up before the dragon is within 20 tiles (+640): flip +' .. tostring(ups[1]))
  local fo = W.find_events('GATE_FORCED')
  T.ok(#fo >= 1 and fo[1].msg:find('building destroyer', 1, true), fo[1] and fo[1].msg)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
end)

T.test('F5 SIEGE vs a building destroyer alone (BUG-909): the citizen stands ON the footprint: B1 stays down until he leaves, then it rises; ' ..
       'nobody crushed', function()
  local leave = 700
  local W = dragon_world{actors = {{id = 141, kind = 'citizen', pos = {51, 40}, nopath = true,
                                    fn = function(W, rel, a) if rel >= leave and not a.left then a.left = true; W.move(a.id, 51, 46, Z) end end}}}
  local moved_early = false
  local at = {}
  for t = 0, 1600, 9 do
    at[#at + 1] = {t, function(w, now)
      B.step(w, now)
      if (now - (w.t0 or now)) < leave - 20 and S.bstate(w, 'B1') ~= 'down' then moved_early = true end
    end}
  end
  S.run(W, 1600, {at = at})
  local ups, pulls = B.flips(W, 'B1', 'up'), B.pulls(W, 'B1')
  if os.getenv('DBG') then print('ups', table.concat(ups, ','), 'pulls', table.concat(pulls, ',')) end
  T.ok(not moved_early, 'B1 never moved while he stood on it')
  T.ok(pulls[1] == nil or pulls[1] >= leave - 20, 'no pull onto him')
  T.ok(ups[1] ~= nil and ups[1] >= leave, 'raised once he left: +' .. tostring(ups[1]))
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
end)

T.test('F5 SIEGE (BUG-909): a destroyer that is NOT closing (parked 84 tiles out) does not release a unit beside the footprint', function()
  local W = dragon_world{actors = {{id = 142, kind = 'citizen', pos = {51, 41}, still = true, nopath = true}}}
  W.foes = {}                                                                    -- parked
  B.run(W, 1500)
  T.eq(S.bstate(W, 'B1'), 'down', 'no eta, no release: the citizen beside it holds the raise')
  T.eq(#W.crushed, 0)
end)

T.test('F3 ALERT cost (BUG-907): a stream so dense that the pull (70 ticks) never finds a free footprint (a citizen every 90 ticks) is never crushed: ' ..
       'the pulls are cancelled by the citizen ON the footprint (stage 2) WITHOUT the pull_cap give-up, so B1 rises as soon as the stream has ended', function()
  local acts = {}
  for k = 0, 40 do acts[#acts + 1] = {id = 300 + k, kind = 'citizen', route = B.route(50 + k % 3, 28, 70), start = 90 * k} end
  local W = B.build{mode = 'ALERT', lock = 'lockdown', actors = acts, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 4500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local ups = B.flips(W, 'B1', 'up')
  if os.getenv('DBG') then print('dense: ups', table.concat(ups, ','), 'pulls', #B.pulls(W, 'B1')) end
  T.ok(ups[1] ~= nil and ups[1] > 3600, 'no gap before the last citizen had passed (+3600), then up: +' .. tostring(ups[1]))
  for _, e in ipairs(W.find_events('GATE_FAIL')) do T.ok(not e.msg:find('no pull for', 1, true), 'the pull_cap give-up parked the levers: ' .. e.msg) end
end)

---------------------------------------------------------------- F4: the return window and the re-raise
-- PEACE on D-14 inner, B1 up, two civilians outside it (north of B1), the squad's soldiers at their station: the window opens after return_every,
-- they walk home over B1; the window ends when they are in; B1 is up again within 1500 ticks of the last return
local function returners(o)
  local acts = {}
  for k, y in ipairs({30, 32}) do
    acts[#acts + 1] = {id = 70 + k, kind = 'citizen', route = B.route(50 + k, y, 75), start = math.huge}
  end
  for _, a in ipairs(o and o.actors or {}) do acts[#acts + 1] = a end
  local W = B.build{closed = {B1 = true}, lat = 645, actors = cat(soldiers({5, 101, 102, 103}), acts)}
  W.hook = function(w, rel)                                      -- they set off when B1 is down (the window)
    if S.bstate(w, 'B1') == 'down' then
      for _, a in ipairs(w.actors) do if a.start == math.huge then a.start = rel + (a.id - 70) * 60 end end
    end
    if o and o.hook then o.hook(w, rel) end
  end
  return W
end

T.test('F4 PEACE (BUG-908): the return window opens for two civilians outside B1, they walk home, the window ends when they are in, B1 is up again ' ..
       'within 1500 ticks of the last return (soldiers at their station do not hold the quiet re-raise); nobody crushed', function()
  local W = returners()
  local last_in
  local at = {}
  for t = 0, 6000, 9 do
    at[#at + 1] = {t, function(w, now)
      B.step(w, now)
      if not last_in then
        local n = 0
        for _, id in ipairs({71, 72}) do local _, y = B.at(w, id); if y >= 41 then n = n + 1 end end
        if n == 2 then last_in = now - (w.t0 or now) end
      end
    end}
  end
  S.run(W, 6000, {at = at})
  local win, ups = B.events(W, 'GATE', 'return'), B.flips(W, 'B1', 'up')
  local end_ev = B.events(W, 'GATE', 'return_end')
  if os.getenv('DBG') then
    print('window', win[1] and win[1].tick - W.t_start, 'last_in', last_in, 'ups', table.concat(ups, ','), 'end', end_ev[1] and end_ev[1].tick - W.t_start, 'crushed', #W.crushed)
  end
  T.eq(#win, 1, 'one return window')
  T.ok(last_in ~= nil, 'both are in')
  T.eq(#end_ev, 1, 'the window ended early: nobody left outside')
  T.ok(ups[1] ~= nil and ups[1] > last_in and ups[1] - last_in <= 1500, 'B1 up within 1500 ticks of the last return (+' .. tostring(last_in) .. '): +' .. tostring(ups[1]))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
end)

T.test('F4 PEACE (BUG-908): a citizen idling 7 tiles inside B1 would keep the re-raise waiting: the return window does NOT open (B1 stays up, GATE ' ..
       'return_wait names him once); when he has gone the window opens and they come home', function()
  local W = returners{actors = {{id = 80, kind = 'citizen', pos = {56, 47}, nopath = true,
                                 fn = function(w, rel, a) if rel >= 3000 and not a.gone then a.gone = true; w.move(a.id, 70, 70, Z) end end}}}
  local down_early = false
  local at = {}
  for t = 0, 6600, 9 do
    at[#at + 1] = {t, function(w, now)
      B.step(w, now)
      if (now - (w.t0 or now)) < 2900 and S.bstate(w, 'B1') ~= 'up' then down_early = true end
    end}
  end
  S.run(W, 6600, {at = at})
  local win, wait = B.events(W, 'GATE', 'return'), B.events(W, 'GATE', 'return_wait')
  if os.getenv('DBG') then print('window', win[1] and win[1].tick - W.t_start, 'wait', #wait, 'ups', table.concat(B.flips(W, 'B1', 'up'), ',')) end
  T.ok(not down_early, 'B1 stayed up while he idled inside')
  T.ok(#wait >= 1 and wait[1].msg:find('citizen 80', 1, true), wait[1] and wait[1].msg)
  T.ok(#win >= 1 and win[1].tick - W.t_start >= 3000, 'the window opened after he left: +' .. tostring(win[1] and win[1].tick - W.t_start))
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up again at the end')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local inside = 0
  for _, id in ipairs({71, 72}) do local _, y = B.at(W, id); if y >= 41 then inside = inside + 1 end end
  T.eq(inside, 2, 'both civilians got home')
end)

T.done()
