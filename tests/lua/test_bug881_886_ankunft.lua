-- Neuausrichtung 12 (BUG-881..886, Run 17d i4 Girderroots y418 spring d39: 'ARRIVAL snatcher (popup)' -> two cave dragons 92 tiles out, then
-- goblins; 22 citizens outside Kern+, both bridges down, 19 pulls and 18 cancels in the first 905 ticks, BREACH at T+900 took the pullers
-- of O1/B1 away, 18 citizens dead, pop 50 -> 32).
-- SIEGE TRAFFIC TEST of the arrival: mode PEACE, both bridges down, 22 citizens stream over O1 and B1 (the recall, a footprint is free for
-- a moment now and then), a hostile army 92 tiles from O1 closing at a tile per 9 ticks; real sense / threat / siege / gate. The raises
-- must be pulled and kept (not cancelled for walkers 1..13 steps out), O1 and B1 up before the army is at them, nobody crushed on a
-- moving bridge, no BREACH. Fails on main (the pull is cancelled again and again, B1/O1 rise too late, BREACH at T+900).
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}
local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end
local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end
local function path_of(w)
  local xs, ys, zs = {}, {}, {}
  for k = w.i + 1, math.min(#w.route, w.i + 25) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    units[#units + 1] = S.cit(w.id, w.route[1][1], w.route[1][2], Z, w.kind == 'soldier' and {squad = 1} or nil)
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind}
  end
  local foes = {}
  for _, u in ipairs(o.army or {}) do
    units[#units + 1] = u
    foes[#foes + 1] = {id = u.id, x = u.pos[1], y0 = u.pos[2], y1 = o.y1 or 60, start = 0}
  end
  local W = S.world{units = units, mode = o.mode, move = 100, lever_default = o.lever or {worker = 60, pull = 40}, cfg = o.cfg}
  S.load(W, {S.military()})
  W.walkers, W.crushed, W.t0, W.foes = walkers, {}, nil, foes
  return W
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route and (W.fast or (rel // 9) % 3 == 0) then   -- a dwarf: 27 ticks a tile (W.fast: on the run, 9)
      local nx = w.route[w.i + 1]
      local blocked = false
      for name in pairs(FPY) do if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end end
      if not blocked then w.i = w.i + 1; W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z) end
    end
    if not w.dead then W.unit(w.id).path = (rel >= w.start) and path_of(w) or nil end
  end
  for _, f in ipairs(W.foes) do
    local k = math.min(math.floor(rel / (W.foe_tpt or 9)), math.abs(f.y1 - f.y0))
    W.move(f.id, f.x, f.y0 + k, Z)
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = string.format('%d on %s at +%d', w.id, name, rel)
        end
      end
    end
  end
end

local function run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  S.run(W, ticks, {at = at})
end

local function up_at(W, b)
  for _, f in ipairs(S.flips(W, b)) do if f.to == 'up' then return f.tick - W.t_start end end
end

-- 22 citizens out in the bailey north of O1 (y -2 .. -20), each walks in over O1 and B1 to Kern+ one after the other (a free footprint
-- now and then: 60 ticks apart)
local function recall(n, gap, y0)
  local ws = {}
  for k = 0, n - 1 do
    ws[#ws + 1] = {id = 400 + k, kind = 'citizen', route = route(50 + k % 3, (y0 or -4) - k, 80), start = (y0 and 0 or 20) + gap * k}
  end
  return ws
end

T.test('BUG-881 arrival traffic (runners): the same on the run (9 ticks a tile) -> nobody is crushed by the TIMED force (the walkers are held by ' ..
       'their measured speed) while there is time to wait for a gap; a crush is the accepted risk only once the army is CLOSE_NEED ticks from the bridge (+428)', function()
  local W = build{walkers = recall(22, 60), army = S.army(6, 50, -82), y1 = 38}
  W.fast = true
  run(W, 2600)
  for _, c in ipairs(W.crushed) do
    local at = tonumber(c:match('at %+(%d+)'))
    T.ok(at >= 420, 'crushed while there was time to wait for a gap: ' .. c)
  end
  T.eq(#W.find_events('BREACH'), 0, 'no BREACH')
  local o1 = up_at(W, 'O1')
  T.ok(o1 ~= nil and o1 + W.move_ticks <= 828, 'O1 closed before the army is at it: ' .. tostring(o1))
end)

T.test('BUG-881 pull_late: only a worker within LATE_R tiles of the lever (or of unknown position) can still cancel a kept pull', function()
  local G = package.loaded['dfllm.gate']
  local W = build{walkers = {}}
  local r = {job = {lever = 1}, pos = {[1] = {53, 11, Z}}}
  T.eq(G.pull_late(r, nil), false, 'nobody took it')
  W.move(1, 60, 70, Z)
  T.eq(G.pull_late(r, W.unit(1)), false, 'on his way, 60 tiles out')
  W.move(1, 55, 12, Z)
  T.eq(G.pull_late(r, W.unit(1)), true, 'two tiles from the lever')
end)

T.test('BUG-881 arrival traffic: PEACE, 22 citizens streaming over O1/B1, an army 92 tiles from O1 closing -> O1 and B1 are up before ' ..
       'the army is at them, nobody crushed, no BREACH', function()
  -- the army: 3 invaders at y -82 (92 tiles from O1 at y 10), a tile per 9 ticks: at O1 after 828 ticks, at B1 after 1098
  local W = build{walkers = recall(22, 60), army = S.army(6, 50, -82), y1 = 38}
  run(W, 2600)
  if os.getenv('DBG') then
    for _, b in ipairs({'O1','B1','B2'}) do for _, f in ipairs(S.flips(W, b)) do print(b, f.to, f.tick - W.t_start) end end
    for _, e in ipairs(W.find_events('GATE_FORCED')) do print('FORCED', e.tick - W.t_start, e.text) end
    for _, e in ipairs(W.find_events('MODE')) do print('MODE', e.tick - W.t_start, e.d.from, e.d.to, e.d.why) end
    for _, a in ipairs(W.find_acts('pull')) do print('pull', a.tick - W.t_start, a.args[1]) end
  end
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  local o1, b1 = up_at(W, 'O1'), up_at(W, 'B1')
  T.ok(o1 ~= nil and o1 + W.move_ticks <= 828, 'O1 closed before the army is at it (828): ' .. tostring(o1))
  T.ok(b1 ~= nil and b1 + W.move_ticks <= 1098, 'B1 closed before the army is at it (1098): ' .. tostring(b1))
  T.eq(#W.find_events('BREACH'), 0, 'no BREACH')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
  local pulls = #S.pulls(W, 'O1') + #S.pulls(W, 'B1')
  T.ok(pulls <= 6, 'the pulls are kept, not re-queued: ' .. pulls)
end)


-- Round 3: every raise that goes ahead with a unit on the footprint is in the crush history: GATE_CRUSH_RISK names each crushed unit
local function crush_history(W)
  local ev = W.find_events('GATE_CRUSH_RISK')
  for _, c in ipairs(W.crushed) do
    local id = tonumber(c:match('^(%d+)'))
    local hit
    for _, e in ipairs(ev) do if e.d.unit == id then hit = e end end
    T.ok(hit ~= nil, 'GATE_CRUSH_RISK names the crushed unit ' .. id .. ' (' .. #ev .. ' events)')
    if hit and os.getenv('DBG') then print('RISK', hit.tick - W.t_start, hit.d.unit, hit.d.to, 'eta', tostring(hit.d.eta), 'forced', tostring(hit.d.forced)) end
  end
  return ev
end

local function dbg(W)
  if not os.getenv('DBG') then return end
  for _, b in ipairs({'O1','B1','B2'}) do for _, f in ipairs(S.flips(W, b)) do print(b, f.to, f.tick - W.t_start) end end
  for _, e in ipairs(W.find_events('GATE_FORCED')) do print('FORCED', e.tick - W.t_start, e.text) end
  for _, e in ipairs(W.find_events('MODE')) do print('MODE', e.tick - W.t_start, e.d.from, e.d.to, e.d.why) end
  for _, a in ipairs(W.find_acts('pull')) do print('pull', a.tick - W.t_start, a.args[1]) end
  for _, c in ipairs(W.crushed) do print('crushed', c) end
end

-- Review round 2 (the stream is AT the footprints when the arrival comes: citizens 1-13 steps from O1/B1 at +0, one more every 87 ticks, a
-- walker is near a footprint all the time, 27 ticks a tile; the army 92 tiles out, 9 ticks a tile -> at O1 after 828 ticks)
T.test('BUG-881 arrival traffic (gapless stream at the footprints from +0): O1 and B1 up before the army, no BREACH, the timed hold ends ' ..
       'while there is still time (a stream with no gap cannot keep the raise pending for ever)', function()
  local G = package.loaded['dfllm.gate']
  local W = build{walkers = recall(22, 87, 8), army = S.army(6, 50, -82), y1 = 38}
  run(W, 2600)
  dbg(W)
  local o1, b1 = up_at(W, 'O1'), up_at(W, 'B1')
  T.ok(o1 ~= nil and o1 + W.move_ticks <= 828, 'O1 closed before the army is at it (828): ' .. tostring(o1))
  T.ok(b1 ~= nil and b1 + W.move_ticks <= 1098, 'B1 closed before the army is at it (1098): ' .. tostring(b1))
  T.eq(#W.find_events('BREACH'), 0, 'no BREACH')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
  T.ok(#S.pulls(W, 'O1') + #S.pulls(W, 'B1') <= 6, 'the pulls are kept: ' .. (#S.pulls(W, 'O1') + #S.pulls(W, 'B1')))
  -- a stream without a gap longer than the bridge move: the walkers are held while there is time to spare, then let go: at most
  -- one crushed walker per bridge, none before the hold has run (the army is nowhere near)
  local risk = crush_history(W)
  for _, e in ipairs(risk) do
    if e.d.forced == 1 then
      T.ok(e.d.eta ~= nil and e.d.eta <= G.CLOSE_NEED, 'the deliberate crush only inside the last CLOSE_NEED ticks (eta ' .. tostring(e.d.eta) .. ')')
    end
  end
  T.ok(#W.crushed <= 2, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, c in ipairs(W.crushed) do
    T.ok(tonumber(c:match('at %+(%d+)')) >= 420, 'crushed while there was time to wait for a gap: ' .. c)
  end
  -- the citizens who had not crossed when O1 went up are LOCKED OUT (the accepted BUG-775 price, documented in BUG-881): they stay outside
  -- alive (not crushed, not moved) and the raise does not wait for them
  local out = 0
  for _, w in ipairs(W.walkers) do if not w.dead and w.route[w.i][2] < 10 then out = out + 1 end end
  T.ok(out >= 10 and out <= 21, 'citizens left outside the raised O1: ' .. out)
end)

-- the i4 dragons were measured at 12.7 ticks a tile (92 tiles took 1167 ticks), not 8-9: the force is timed by the measured speed, so the
-- walkers get the longer wait for a gap and the raise is still done before the army
T.test('BUG-881 arrival traffic (slow army, 13 ticks a tile, gapless stream): O1 up before the army (1196), no BREACH, the citizens were ' ..
       'given time to cross first', function()
  local W = build{walkers = recall(22, 87, 8), army = S.army(6, 50, -82), y1 = 38}
  W.foe_tpt = 13
  run(W, 3000)
  dbg(W)
  local o1 = up_at(W, 'O1')
  T.ok(o1 ~= nil and o1 + W.move_ticks <= 1196, 'O1 closed before the army is at it (1196): ' .. tostring(o1))
  T.eq(#W.find_events('BREACH'), 0, 'no BREACH')
  T.ok(o1 >= 700, 'the raise waited for a gap in the stream first (+700 at least): ' .. tostring(o1))
  local across = 0
  for _, w in ipairs(W.walkers) do if not w.dead and w.route[w.i][2] >= 10 then across = across + 1 end end
  T.ok(across >= 5, 'citizens crossed O1 while it waited: ' .. across)
  T.ok(#W.crushed <= 2, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, c in ipairs(W.crushed) do T.ok(tonumber(c:match('at %+(%d+)')) >= 790, 'crushed while there was time to wait: ' .. c) end
end)

-- Round 3 (C): the deliberate crush is bounded: a unit ON the footprint keeps its hold until the last moment a raise can still succeed
T.test('BUG-881 crush_late: the on-footprint hold ends only when the hostile needs no more than the lever latency + the bridge move + a margin', function()
  local G = package.loaded['dfllm.gate']
  local W = build{walkers = recall(22, 87, 8), army = S.army(6, 50, -82), y1 = 38}
  run(W, 1500)
  local lat = W.state().lever.lat_t
  T.ok(lat > 0, 'lever latency measured: ' .. lat)
  local function late(eta, at, now)
    local ok, v = W.K.call('gate', 'crush_late', {fz_eta = eta, fz_at = at}, now)
    T.ok(ok, 'crush_late callable')
    return v
  end
  -- find the limit of this world's instance by bisection, then compare it with latency + TIMED_WIN + CRUSH_MARGIN
  local lo, hi = 0, 6000
  while hi - lo > 1 do
    local mid = (lo + hi) // 2
    if late(mid, 100, 100) then lo = mid else hi = mid end
  end
  T.eq(lo, lat + G.TIMED_WIN + G.CRUSH_MARGIN, 'the limit is the measured latency + TIMED_WIN + CRUSH_MARGIN')
  T.eq(late(lo + 1, 100, 100), false, 'one tick too early')
  T.eq(late(lo, 100, 100), true, 'at the limit')
  T.eq(late(lo + 50, 100, 150), true, 'the eta runs down with the time since the look')
  T.eq(late(nil, 100, 100), false, 'no timed force: never')
  T.eq(G.eta_now({fz_eta = 30, fz_at = 0}, 100), 0, 'never negative')
end)

-- Round 3 (C): false arrivals never get a timed force: an ARRIVAL with no closing hostile in sight, a wild animal (not a hostile), a hostile
-- moving away, a hostile far beyond CLOSE_BUDGET
T.test('BUG-881 false arrivals: no hostile, a hostile moving away, one beyond the budget -> no GATE_FORCED, no raise, nobody held out', function()
  local function scene(foes_y1, y0)
    local army = S.army(2, 50, y0)
    local W = build{walkers = recall(10, 87, 8), army = army, y1 = foes_y1}
    return W
  end
  -- nobody in sight at all (a migrant/caravan/visitor ARRIVAL has no hostile in the census)
  local W = build{walkers = recall(10, 87, 8)}
  run(W, 1500)
  T.eq(#W.find_events('GATE_FORCED'), 0, 'no hostile: no force')
  T.eq(#S.pulls(W, 'O1') + #S.pulls(W, 'B1'), 0, 'no raise pulled')
  -- a hostile walking AWAY (y decreasing from -40 to -300): never closing
  local W2 = build{walkers = recall(10, 87, 8), army = S.army(2, 50, -40), y1 = -300}
  run(W2, 1500)
  T.eq(#W2.find_events('GATE_FORCED'), 0, 'a hostile moving away: no force')
  -- closing, but 1500 ticks away at 13 a tile (130 tiles): beyond CLOSE_BUDGET
  local W3 = build{walkers = recall(10, 87, 8), army = S.army(2, 50, -150), y1 = 38}
  W3.foe_tpt = 13
  run(W3, 500)
  T.eq(#W3.find_events('GATE_FORCED'), 0, 'beyond the budget: no timed force yet')
end)

-- Building destroyers alone (the i4 cave dragons): no timed force (the bridges are no barrier, raising only locks the citizens out)
T.test('BUG-881 barrier_foe: building destroyers alone get no timed force, any other hostile in sight does', function()
  local G = package.loaded['dfllm.gate']
  local function K(list) return {census = {h = {list = list}}} end
  T.eq(G.barrier_foe(K({{id = 1, bd = 1}, {id = 2, bd = 1}})), false, 'two cave dragons')
  T.eq(G.barrier_foe(K({{id = 1, bd = 1}, {id = 3}})), true, 'dragon and a goblin')
  T.eq(G.barrier_foe(K({})), true, 'no list: unknown = a timed force')
  T.eq(G.barrier_foe({census = {}}), true, 'no census')
end)

-- Round 3 (the real i4 arrival, event #13421): ONLY two cave dragons (building destroyers, bd = 1) in sight, 92 tiles from O1, 13 ticks a tile, 22
-- citizens streaming over the bridges (gapless), both bridges down, PEACE then the arrival. DECISION (A): a raised bridge is NO barrier
-- to building destroyers in this codebase's own history (BUG-462 Run 16a i1 Syrupobeyed: trolls broke O1 and B2 although both stood UP; BUG-030 Run 10
-- y421: six trolls destroyed O1, B1, B2, BRIDGE_DESTROYED 'last up'; Run 11 site98: cave dragons destroyed O1 in all five sieges), so
-- `barrier_foe` keeps them out of the timed force: raising would only lock the citizens out. This test pins what really happens: NO
-- GATE_FORCED, NO timed raise (the plain approach rules), nothing crushed by traffic, no BREACH from traffic.
local TROLL = 77
local function troll_raws()
  local lvl, flag = {flags = {}, misc = {buildingdestroyer = 1}}, {flags = {BUILDINGDESTROYER = true}}
  df.creature_raw = {find = function(r) if r == TROLL then return {caste = {[0] = lvl, [1] = flag}} end end}
end
local function lockedout(W)
  local n = 0
  for _, w in ipairs(W.walkers) do if not w.dead and w.route[w.i][2] < 10 then n = n + 1 end end
  return n
end
-- mode = nil: PEACE then the arrival (the census decides: ALERT, destroyers); 'SIEGE': the siege popup already made it SIEGE (the real i4: PEACE, then SIEGE)
local function destroyer_arrival(mode)
  local army = S.army(2, 50, -82)
  local W = build{walkers = recall(22, 87, 8), army = army, y1 = 38, mode = mode}
  troll_raws()
  for _, u in ipairs(army) do local x = W.unit(u.id); x.race, x.caste = TROLL, 0 end
  W.foe_tpt = 13
  run(W, 3000)
  dbg(W)
  local h = W.K.census.h
  T.ok(type(h) == 'table' and (h.bd or 0) >= 1, 'the census sees the building destroyers: ' .. tostring(h and h.bd))
  if os.getenv('DBG') then print('O1 up', up_at(W, 'O1'), 'B1 up', up_at(W, 'B1'), 'locked out', lockedout(W), 'crushed', #W.crushed) end
  return W
end
T.test('BUG-881 round 3 arrival of two building destroyers only (i4 #13421, PEACE then the arrival): no timed force, nobody crushed by traffic, nobody locked out', function()
  local W = destroyer_arrival(nil)
  T.eq(#W.find_events('GATE_FORCED'), 0, 'no timed force for building destroyers alone')
  T.eq(#W.crushed, 0, 'nobody crushed by the traffic: ' .. table.concat(W.crushed, '; '))
  T.eq(#W.find_events('GATE_CRUSH_RISK'), 0, 'no GATE_CRUSH_RISK')
  T.eq(lockedout(W), 0, 'nobody locked out: the bridges stay down while the dragons come (they would only break a raised one)')
end)
T.test('BUG-881 round 3 the same in SIEGE (the siege popup of the i4 arrival): the plain approach rule raises (no TIMED force: the raise comes with the ' ..
       'dragons 30 tiles out, not 400 ticks out), O1/B1 up before they arrive, no BREACH, one crushed at the end, the rest locked out (NOT promised)', function()
  local W = destroyer_arrival('SIEGE')
  local forced = W.find_events('GATE_FORCED')
  T.ok(#forced >= 1, 'the plain approach rule (BUG-587) forced the raise')
  -- dragons 13 ticks a tile, 92 tiles = at O1 after 1196: a TIMED force would have started at the first closing look (~+60..+120); the approach rule
  -- (approach_near 30 tiles = 390 ticks) comes at +800 at the earliest
  T.ok(forced[1].tick - W.t_start >= 800, 'first GATE_FORCED at +' .. (forced[1].tick - W.t_start) .. ' (approach rule, not timed)')
  local o1, b1 = up_at(W, 'O1'), up_at(W, 'B1')
  T.ok(o1 ~= nil and o1 + W.move_ticks <= 1196, 'O1 up before the dragons are at it (1196): ' .. tostring(o1))
  T.ok(b1 ~= nil and b1 + W.move_ticks <= 1196 + 270, 'B1 up before the dragons are at it: ' .. tostring(b1))
  T.eq(#W.find_events('BREACH'), 0, 'no BREACH caused by traffic')
  T.ok(#W.crushed <= 1, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, c in ipairs(W.crushed) do T.ok(tonumber(c:match('at %+(%d+)')) >= 800, 'crushed only at the approach force: ' .. c) end
  local n = lockedout(W)
  T.ok(n >= 5 and n <= 21, 'citizens locked out by that raise: ' .. n)
end)

-- BUG-882: BREACH only because a bridge failed (hostiles outside, nothing inside Kern+): the pullers of O1's lever room stay on duty
T.test('BUG-882: BREACH with the hostiles outside keeps the pullers of the O1 lever room and O1 rises', function()
  local C = require('dfllm.util.contract')
  C.ACT.burrow_units = {'gate'}
  local m = S.manifest()
  m.bridges.O1.levers = {{53, 11, Z}}
  m.burrows['dfllm-levers'] = {role = 'other'}
  local units = S.fort_units()
  units[#units + 1] = S.cit(6, 53, 11)
  for _, u in ipairs(S.army(4, 50, -12)) do units[#units + 1] = u end         -- 23 tiles from the lever room
  local W = S.world{units = units, manifest = m, mode = 'BREACH', lever_default = {worker = 30, pull = 40}}
  W.burrow('dfllm-levers', {53, 11, Z, 54, 12, Z})
  W.act_result('burrow_units', function(name, ids)
    local b = dfhack.burrows.findByName(name)
    if not b then return false, 'no burrow ' .. tostring(name) end
    b.units = kmock.vec(ids)
    return true, #ids
  end)
  S.load(W, {S.military()})
  S.run(W, 60)
  if os.getenv('DBG') then for _, m in ipairs(S.modes(W)) do print('mode', m) end print('O1', S.bstate(W,'O1'), #S.pulls(W,'O1')); local h = W.K.census.h; print('h', h and h.tick, h and h.inside, W.K.now().tick) end
  local ok, pul = W.K.call('gate', 'puller_of')
  T.eq(ok and pul[6], 'dfllm-levers', 'citizen 6 is a puller of the room in BREACH')
  S.run(W, 900)
  T.eq(S.bstate(W, 'O1'), 'up', 'O1 rose')
end)

T.done()
