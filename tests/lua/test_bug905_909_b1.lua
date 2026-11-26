-- Neuausrichtung 15 (BUG-905..909, Run 17 i3 Orangering, kernel b8160ba3): the inner bridge B1 (footprint 85-87,64,142) was DOWN when the alarms
-- came and then did not rise: GATE_FAIL five times in one evening, soldiers of squads 99/100 one to three tiles from the footprint 'on their way to
-- station 86,60,142', citizens on or walking onto it; raised only by the player's lever. Diagnosis leitung/neu10/DIAGNOSE-B1-2026-11-25.md.
-- The siege world's B1 is the same shape: a 3x1 footprint 50..52,40, the squad station 4 tiles on its inner side (51,44). Every case is a SIEGE
-- TRAFFIC test (b1_world.lua: real sense / threat / siege / gate, citizens and soldiers that walk with a path DF shows, a hostile that walks, a raised
-- bridge cannot be walked, a unit ON a moving bridge is crushed). The numbers they pin (ticks from the first frame) are in bugs/BUG-905..909.
--   F1 (BUG-905) PEACE: the quiet raise waits for every unit within 20 tiles, soldiers at their station included (15b: the round-15 exemptions are withdrawn);
--      a bridge wanted up for a game day names who keeps it down and asks DECISION_NEEDED gate_peace_traffic with the numbers
--   F2 (BUG-906) the station clearance is RAISE_R + spread: ALERT with soldiers pacing at 3 tiles -> STATION_MOVED; the stand-by order holds in SIEGE only
--   F4 (BUG-908) the return window is only opened when the re-raise is possible; a bridge wanted up for a game day names who holds it
--   F5 (BUG-909) SIEGE against building destroyers only: a unit standing beside the footprint does not hold it while the destroyer closes
-- (F3, the bounded wait of BUG-907, is withdrawn in 15b: test_bug905_909_b1b.lua pins the reach rule that replaces it.)
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
T.test('F1 PEACE (BUG-905/15b): four soldiers shuffling at the station 4 tiles inside B1 keep the quiet raise waiting (they can reach it in 36 ticks): ' ..
       'no pull in 3000 ticks, GATE peace_wait names a soldier, after a game day ONE peace_stuck and ONE DECISION_NEEDED gate_peace_traffic with the numbers', function()
  local W = B.build{lat = 645, actors = soldiers({5, 101, 102, 103})}
  B.run(W, 3000)
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  T.eq(#W.crushed, 0)
  local pw = B.events(W, 'GATE', 'peace_wait')
  T.ok(#pw >= 1 and pw[1].msg:find('soldier', 1, true), pw[1] and pw[1].msg)
  local ps = B.events(W, 'GATE', 'peace_stuck')
  T.eq(#ps, 1, 'one peace_stuck event')
  T.ok(ps[1] and ps[1].d.ticks >= 1200 and ps[1].msg:find('soldier', 1, true), ps[1] and ps[1].msg)
  local dn = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'gate_peace_traffic' then dn[#dn + 1] = e end end
  T.eq(#dn, 1, 'one DECISION_NEEDED gate_peace_traffic')
  T.ok(dn[1] and dn[1].d.bridge == 'B1' and dn[1].d.n >= 4 and dn[1].d.lat == 645 and dn[1].d.need == 645 and dn[1].d.ticks >= 1200, dn[1] and dn[1].msg)
  T.ok(dn[1] and dn[1].msg:find('per 1000', 1, true) and dn[1].msg:find('lever latency 645', 1, true), dn[1] and dn[1].msg)
end)

T.test('F1 PEACE (BUG-905/15b): a citizen 4 tiles from B1 walking onto it: no pull while he does and a whole quiet window after; nobody crushed', function()
  local W = B.build{lat = 645, actors = {{id = 61, kind = 'citizen', route = B.route(51, 36, 70), start = 1000}}}   -- he sets off at +1000, inside the quiet window
  local cross_t
  local at = {}
  for t = 0, 3600, 9 do
    at[#at + 1] = {t, function(w, now)
      B.step(w, now)
      if not cross_t then local _, y = B.at(w, 61); if y >= 41 then cross_t = now - (w.t0 or now) end end
    end}
  end
  S.run(W, 3600, {at = at})
  local pulls, ups = B.pulls(W, 'B1'), B.flips(W, 'B1', 'up')
  T.ok(cross_t ~= nil, 'he crossed')
  T.ok(pulls[1] ~= nil and pulls[1] > cross_t + 600, 'no pull while he walks onto it and a whole quiet window after (crossed at +' .. tostring(cross_t) .. '), first pull +' .. tostring(pulls[1]))
  T.ok(ups[1] ~= nil, 'raised after he has gone (he walks on to 30 tiles out)')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
end)

T.test('F1 PEACE (BUG-905/15b): a unit standing 14 tiles out holds the raise (a walker covers it in ~130 ticks), one standing 22 tiles out (past PEACE_R 20) does not', function()
  local W = B.build{lat = 645, actors = {{id = 63, kind = 'citizen', pos = {51, 54}, still = true, nopath = true}}}
  B.run(W, 2300)
  T.eq(S.bstate(W, 'B1'), 'down', 'not raised with a unit 14 tiles away')
  local W2 = B.build{lat = 645, actors = {{id = 64, kind = 'citizen', pos = {51, 62}, still = true, nopath = true}}}
  B.run(W2, 2300)
  T.eq(S.bstate(W2, 'B1'), 'up', 'raised with a unit 22 tiles away')
  T.eq(#W2.crushed, 0)
end)

---------------------------------------------------------------- F2: station clearance, stand by order
local PACE3 = {{0, -1}, {0, 0}, {1, -1}, {1, 0}}                  -- soldiers pacing at 3 and 4 tiles from B1 (station 51,44)
local function alert_world(o)
  return B.build{mode = o and o.mode or 'ALERT', lock = 'lockdown', real_mil = true, hidden = o and o.hidden,
                 actors = cat(soldiers({5, 101, 102, 103}, PACE3), o and o.actors or {}),
                 army = {S.inv(250, 51, 15, Z)}}                    -- ONE hostile 25 tiles from B1, on the attack side, standing
end

T.test('F2 ALERT (BUG-906): a lone hostile 25 tiles out, the station 4 tiles from B1 and its soldiers pacing at 3 tiles: the station is MOVED ' ..
       '(STATION_MOVED, not kept) within 300 ticks; the soldiers still hold the ALERT raise (15b: a soldier at his station can reach the footprint): B1 stays down, ' ..
       'GATE_FAIL says who; nobody crushed', function()
  local W = alert_world()
  B.run(W, 2400)
  local sm = B.events(W, 'STATION_MOVED', 'hold')
  local bl = B.events(W, 'GATE', 'blocked')
  local w0 = bl[1] and bl[1].tick - W.t_start or 0
  T.eq(W.K.mode(), 'ALERT')
  T.ok(#sm >= 1 and sm[1].tick - W.t_start - w0 <= 300, 'STATION_MOVED within 300 ticks of the first hold: ' .. tostring(sm[1] and sm[1].msg))
  T.ok(sm[1] and sm[1].d.to and sm[1].d.to[2] >= 45, 'to a tile 5 tiles from the footprint: ' .. tostring(sm[1] and sm[1].d.to and sm[1].d.to[2]))
  T.ok(W.squad1.orders[1].pos.y >= 45, 'the squad has the new station order')
  T.eq(S.bstate(W, 'B1'), 'down', 'the soldiers at their station can reach it: not raised')
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local f = W.find_events('GATE_FAIL')
  local text
  for _, e in ipairs(f) do if e.d.bridge == 'B1' then text = e.msg end end
  T.ok(text and text:find('soldier', 1, true) and text:find('can reach it in', 1, true), text)
end)

T.test('F2 SIEGE (BUG-906): no tile clear of B1 can be found (nothing revealed): STATION_MOVED none says so ONCE with the tiles tried; in SIEGE the soldiers stand ' ..
       'by order and hold nothing (B1 up past the pacers, not crushed), a soldier ON the footprint still holds it; in ALERT the same soldiers keep B1 down', function()
  local W = alert_world{hidden = true, mode = 'SIEGE'}
  B.run(W, 1200)
  local none = B.events(W, 'STATION_MOVED', 'none')
  T.eq(#none, 1, 'said once per alarm')
  T.ok(none[1] and none[1].d.standby == true and none[1].d.tiles > 100 and none[1].d.tried:find('bridge B1', 1, true), 'tiles tried: ' .. tostring(none[1] and none[1].d.tiles))
  T.ok(none[1] and none[1].msg:find('stand by order', 1, true) and none[1].msg:find('tiles tried', 1, true), none[1] and none[1].msg)
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up past the soldiers standing by order (SIEGE)')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W))
  local W2 = alert_world{hidden = true, mode = 'SIEGE', actors = {{id = 110, kind = 'soldier', pos = {51, 40}, still = true, nopath = true}}}
  B.run(W2, 2400)
  T.eq(S.bstate(W2, 'B1'), 'down', 'not raised onto the soldier ON the footprint')
  T.eq(#W2.crushed, 0)
  local f = W2.find_events('GATE_FAIL')
  T.ok(#f >= 1 and f[1].msg:find('soldier 110 on the footprint', 1, true), f[1] and f[1].msg)
  local W3 = alert_world{hidden = true}
  B.run(W3, 2400)
  T.eq(S.bstate(W3, 'B1'), 'down', 'ALERT: the soldiers at their station keep it down (the stand-by exemption is withdrawn outside SIEGE / BREACH)')
  T.eq(#W3.crushed, 0)
end)

T.test('F2 military.clearance: stations.clear (default 4 = RAISE_R + spread, never below margin + spread); 2 = the old BUG-032 clearance', function()
  local W = alert_world()
  local mil = package.loaded['dfllm.military']
  local G = package.loaded['dfllm.gate']
  T.eq(mil.CLEAR, G.RAISE_R + mil.SPREAD, 'default clearance = RAISE_R + spread')
  local W2 = B.build{mode = 'ALERT', lock = 'lockdown', real_mil = true, cfg = {reflex = {v = 2, stations = {clear = 2}}},
                     actors = soldiers({5, 101, 102, 103}, PACE3), army = {S.inv(250, 51, 15, Z)}}
  B.run(W2, 1200)
  T.eq(#B.events(W2, 'STATION_MOVED', 'hold'), 0, 'clear = 2: not moved')
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

---------------------------------------------------------------- F4: the return window and the re-raise
-- PEACE on D-14 inner, B1 up, two civilians outside it (north of B1), the squad's soldiers at their station: the window opens after return_every,
-- they walk home over B1; the window ends when they are in; B1 is up again within 1500 ticks of the last return
local function returners(o)
  local acts = {}
  for k, y in ipairs({30, 32}) do
    acts[#acts + 1] = {id = 70 + k, kind = 'citizen', route = B.route(50 + k, y, 75), start = math.huge}
  end
  for _, a in ipairs(o and o.actors or {}) do acts[#acts + 1] = a end
  local W = B.build{closed = {B1 = true}, lat = 645, actors = cat(o and o.soldiers and soldiers({5, 101, 102, 103}) or {}, acts)}
  W.hook = function(w, rel)                                      -- they set off when B1 is down (the window)
    if S.bstate(w, 'B1') == 'down' then
      for _, a in ipairs(w.actors) do if a.start == math.huge then a.start = rel + (a.id - 70) * 60 end end
    end
    if o and o.hook then o.hook(w, rel) end
  end
  return W
end

T.test('F4 PEACE (BUG-908): the return window opens for two civilians outside B1, they walk home, the window ends when they are in, B1 is up again ' ..
       'within 1500 ticks of the last return; nobody crushed', function()
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

T.test('F4 PEACE (BUG-908/15b): the squad stands at its station 4 tiles inside B1 (its soldiers can reach the footprint, the quiet re-raise would wait for them): the return ' ..
       'window does NOT open for the two civilians outside (B1 stays up, GATE return_wait names a soldier, once per FAIL_REPEAT), nobody is crushed', function()
  local W = returners{soldiers = true}
  local down_early = false
  local at = {}
  for t = 0, 4800, 9 do
    at[#at + 1] = {t, function(w, now)
      B.step(w, now)
      if S.bstate(w, 'B1') ~= 'up' then down_early = true end
    end}
  end
  S.run(W, 4800, {at = at})
  local win, wait = B.events(W, 'GATE', 'return'), B.events(W, 'GATE', 'return_wait')
  T.ok(not down_early, 'B1 never left its raised state')
  T.eq(#win, 0, 'no return window')
  T.ok(#wait >= 1 and wait[1].msg:find('soldier', 1, true) and wait[1].msg:find('could not be raised again', 1, true), wait[1] and wait[1].msg)
  T.eq(#B.flips(W, 'B1', 'down'), 0, 'B1 never moved')
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
