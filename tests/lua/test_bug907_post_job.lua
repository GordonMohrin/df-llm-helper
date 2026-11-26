-- Neuausrichtung 15b, BUG-907 final rule (option A, the lead's decision): the post-job gap is CLOSED by the hold. A bridge is raised by the kernel outside SIEGE / BREACH only when the
-- footprint is provably clear for the whole window from the pull to the end of the movement (W = max(measured lever latency, REACH_FLOOR) + TIMED_WIN; every non-animal unit of a fresh
-- census, standing or walking, at any distance within W / REACH_TPT tiles holds the pull; an unknown path holds, a missing or stale census holds). So a unit that STANDS 30 or 40 tiles
-- out when the pull would be queued and starts to walk after the lever job has vanished is NOT crushed: there is no pull. The world is B.build{deep = true}: the fort's own people live
-- 190+ tiles from every footprint, so the only unit that can hold is the one the test places.
-- Cases: ALERT latency 1000 (30 and 40 tiles), quiet PEACE (21, 25, 40 tiles), RECOVERY, DRILL; the same fort without the walker raises (availability); a stale census holds; the hold is
-- reported (GATE_FAIL / GATE with the nearest unit and its distance) and after REACH_DAY ticks ONE DECISION_NEEDED gate_reach_traffic says the bridge stays down because of traffic.
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local G = require('dfllm.gate')
local Z = S.Z

-- a unit standing `y0` rows north of the footprint row 40 (x 51) that starts to walk toward it at +150 (the lever job of a pull would be done by then) or the frame the bridge
-- starts to move, and walks straight onto the footprint (9 ticks a tile)
local function late_walker(id, y0)
  return {id = id, kind = 'citizen', pos = {51, y0}, nopath = true,
          fn = function(W, rel, a)
            if not a.go and (S.bstate(W, 'B1') == 'moving' or rel >= 150) then a.go, a.t = true, rel end
            if a.go then
              local y = math.min(y0 + (rel - a.t) // 9, 41)
              W.move(a.id, 51, y, Z)
            end
          end}
end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end
local function drill_world(actors)
  local W = B.build{mode = 'DRILL', lat = 1000, actors = actors, deep = true}
  W.load(S.drill())
  return W
end

T.test('(i) ALERT, latency 1000: a unit standing 30 or 40 tiles out that starts to walk after the lever job would have vanished is NOT crushed: no pull, B1 stays down, the hold is said', function()
  for _, y0 in ipairs({10, 0}) do
    local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, move = 380, deep = true, actors = {late_walker(900 + y0, y0)}, army = {S.inv(250, 51, 20, Z)}}
    B.run(W, 2400)
    T.eq(#B.pulls(W, 'B1'), 0, y0 .. ': no pull with a unit ' .. (40 - y0) .. ' tiles out')
    T.eq(S.bstate(W, 'B1'), 'down', y0 .. ': B1 never moved')
    T.eq(#W.crushed, 0, y0 .. ': nobody crushed: ' .. table.concat(W.crushed, '; '))
    local said                                             -- the first look names him, his distance and the ticks he needs (the GATE line); the GATE_FAIL at the deadline names him too
    for _, e in ipairs(W.find_events('GATE')) do
      if e.d.bridge == 'B1' and e.msg:find('citizen ' .. (900 + y0) .. ' ' .. (40 - y0) .. ' tiles away, can reach it in ' .. (40 - y0) * 9 .. ' ticks', 1, true) then said = e.msg end
    end
    T.ok(said, 'GATE names the unit, the distance and the ticks')
    local text
    for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'B1' then text = text or e.msg end end
    T.ok(text and text:find('citizen ' .. (900 + y0), 1, true), tostring(text))
  end
end)

T.test('(i) ALERT, latency 1000: the same fort without the walker raises B1 (availability: safety must not mean never)', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, deep = true, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 1500)
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0)
end)

T.test('(ii) quiet PEACE: a unit standing 21, 25 or 40 tiles out that starts to walk after the job would be done is NOT crushed: no pull, B1 stays down', function()
  for _, y0 in ipairs({19, 15, 0}) do
    local W = B.build{lat = 645, move = 380, deep = true, actors = {late_walker(910 + y0, y0)}}
    B.run(W, 3000)
    T.eq(#B.pulls(W, 'B1'), 0, y0 .. ': no pull with a unit ' .. (40 - y0) .. ' tiles out')
    T.eq(S.bstate(W, 'B1'), 'down', y0 .. ': B1 never moved')
    T.eq(#W.crushed, 0, y0 .. ': nobody crushed: ' .. table.concat(W.crushed, '; '))
    local said
    for _, e in ipairs(W.find_events('GATE')) do if e.d.bridge == 'B1' and e.msg:find('citizen ' .. (910 + y0), 1, true) then said = e.msg end end
    T.ok(said, y0 .. ': GATE names the unit that keeps it down')
  end
  local W = B.build{lat = 645, move = 380, deep = true}                       -- nobody: it rises
  B.run(W, 3000)
  T.eq(S.bstate(W, 'B1'), 'up')
end)

T.test('(iii) RECOVERY (the lockdown still wants B1 up): a unit standing 30 tiles out that starts to walk later is not crushed, no pull; without him B1 rises', function()
  local W = B.build{mode = 'RECOVERY', lock = 'lockdown', lat = 1000, move = 380, deep = true, actors = {late_walker(920, 10)}}
  B.run(W, 2400)
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(#W.crushed, 0, table.concat(W.crushed, '; '))
  local W2 = B.build{mode = 'RECOVERY', lock = 'lockdown', lat = 1000, move = 380, deep = true}
  B.run(W2, 2400)
  T.eq(S.bstate(W2, 'B1'), 'up', 'availability')
end)

T.test('(iv) DRILL, latency 1000: a unit standing 30 tiles out that starts to walk later is not crushed, no pull; with nobody within the window B1 is pulled and up', function()
  local W = drill_world({late_walker(930, 10)})
  B.run(W, 1100)
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(#W.crushed, 0, table.concat(W.crushed, '; '))
  local W2 = drill_world({})
  B.run(W2, 1100)
  T.ok(B.flips(W2, 'B1', 'up')[1] ~= nil, 'availability: B1 up')
end)

T.test('(v) the hold lasts: a standing unit 30 tiles out in ALERT keeps B1 down for good and after REACH_DAY ticks ONE DECISION_NEEDED gate_reach_traffic says it is the traffic', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, deep = true, actors = {{id = 940, kind = 'citizen', pos = {51, 10}, still = true, nopath = true}},
                    army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 4200)
  T.eq(#B.pulls(W, 'B1'), 0, 'never pulled')
  local dn = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'gate_reach_traffic' then dn[#dn + 1] = e end end
  T.eq(#dn, 1, 'ONE decision, however long it lasts')
  local d = dn[1] and dn[1].d or {}
  T.ok(d.bridge == 'B1' and d.unit == 940 and d.d == 30 and d.need == 1110 and d.ticks >= G.REACH_DAY, dn[1] and dn[1].msg)
  T.ok(dn[1] and dn[1].msg:find('stays down', 1, true) and dn[1].msg:find('citizen 940', 1, true) and dn[1].msg:find('30 tiles', 1, true), dn[1] and dn[1].msg)
  T.ok(logged(W, 'B1 stays down'), 'kern.log says it too')
end)

T.test('(vi) a missing or stale census holds (fail closed); the base of this fort is out of the window', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, deep = true, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 1500)
  T.eq(S.bstate(W, 'B1'), 'up')
  local K = W.K
  local G = package.loaded['dfllm.gate']                   -- the world's own copy of the module
  T.ok(type(G.reach_census(K, 'B1')) == 'table', 'a fresh census answers')
  local cu = K.census.u
  local tick = cu.tick
  cu.tick = K.now().tick - G.REACH_FRESH - 1
  T.eq(G.reach_census(K, 'B1'), nil, 'a stale census: unknown')
  local hold = G.reach_hold(K, 'B1', nil, {}, {})
  T.eq(hold.unknown, true, 'unknown holds the pull')
  cu.tick = tick
  K.census.u = nil
  T.eq(G.reach_census(K, 'B1'), nil, 'no census: unknown')
  K.census.u = cu
  local list = G.reach_units(K, 'B1', nil, nil, nil)
  T.eq(#list, 0, 'the base of the fort is out of reach')
end)

T.done()
