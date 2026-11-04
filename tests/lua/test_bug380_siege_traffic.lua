-- BUG-380 (Run 16d i4 Woodmill, the fort that fell: events #2699/#2700, tick 153579422-598): soldier 26395 crushed by B2.
-- Mode BREACH with 0 visible hostiles, squads 99-101 on their way to stations 76,114..115,134 beyond B2 (the core stair
-- at 78,115 two tiles behind the footprint), citizens streaming over the bridges. B2/O1 were pulled ~10 times in 1500 ticks;
-- the soldier was nine steps out when the pull was done and walked on while B2 moved (~100 ticks): the hotfix of
-- 571f58f let every walker farther than PATH_SIEGE (6) steps go in a SIEGE/BREACH, hostile or none.
-- The traffic test: a simulated squad and civilians walk (a tile per 9-tick frame, their next 25 tiles in unit.path.path)
-- over the bridges of the siege world while the real sense, threat, siege and gate run (fake military); a raised bridge
-- cannot be walked, a unit ON a bridge that moves is crushed. Both halves of the policy at once:
--   (1) nobody is on a footprint when a bridge moves, in BREACH with no hostile in sight and in a SIEGE;
--   (2) a hostile approaching: the bridge is up before it arrives and before T+900 (the earlier rounds broke one or the
--       other: BUG-335 held it for good (BREACH at T+900), the hotfix crushed).
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- the footprints are x 50..52 at these rows

local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

-- units: {id, kind = 'soldier'|'citizen', route, start (ticks)}; the stepper moves them one tile per frame
local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    local u = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil)
    units[#units + 1] = u
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind, ghost = w.ghost}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = {worker = 30, pull = 40}}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  W.foes = o.foes or {}
  return W
end

local function on_fp(name, x, y)
  return y == FPY[name] and x >= 50 and x <= 52
end

local function path_of(w)
  local xs, ys, zs = {}, {}, {}
  for k = w.i + 1, math.min(#w.route, w.i + 25) do
    xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z
  end
  for _, g in ipairs(w.ghost or {}) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = g[1], g[2], Z end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

-- one frame of the walkers and the invaders, then the crush rule
local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name, row in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end   -- a raised bridge: no way
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
      end
    end
    if not w.dead then W.unit(w.id).path = (rel >= w.start) and path_of(w) or nil end
  end
  for _, f in ipairs(W.foes) do
    if rel >= f.start and f.y0 ~= f.y1 then
      local k = math.min(math.floor((rel - f.start) / 9), math.abs(f.y1 - f.y0))
      local y = f.y0 + (f.y1 > f.y0 and k or -k)
      W.move(f.id, f.x, y, Z)
    end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = {id = w.id, bridge = name, tick = rel}
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

local function names(list)
  local r = {}
  for _, c in ipairs(list) do r[#r + 1] = string.format('%d on %s at +%d', c.id, c.bridge, c.tick) end
  return table.concat(r, '; ')
end

local function flips_to(W, b, to)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == to then r[#r + 1] = f.tick - W.t_start end end
  return r
end

-- a squad of six walks in over B2 to the stations behind it (y 66), one tile apart, then a citizen reaches B2 every 170 ticks
-- (19 tiles apart), alternately from each side, 8 of them (Review fix merge20: 230 ticks apart, so a gap of the 70 ticks the
-- pull needs opens after each walker is across; the walkers within 13 steps hold, the old rule of the last 6 steps let the
-- next citizen, 14 steps out, walk onto B2 in the ~100 ticks it moved)
local function traffic_b2(n)
  local ws = {}
  for i = 1, 6 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 46, 66), start = (i - 1) * 18} end
  for k = 0, n - 1 do
    local north = k % 2 == 0                   -- from y 90 (30 steps to the footprint) or from y 46 (14 steps)
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 90, 46) or route(52, 46, 90),
                   start = 300 + 230 * k - (north and 270 or 126)}
  end
  return ws
end

T.test('BUG-380 traffic (1): BREACH, no hostile in sight, a squad and a stream of citizens over B2 -> nobody is crushed, ' ..
       'B2 stays down while a walker can reach it before it has moved (13 steps) and rises in the first gap', function()
  local W = build{mode = 'BREACH', walkers = traffic_b2(8)}
  run(W, 2600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B2', 'up')
  T.eq(#up, 1, 'B2 rose once')
  T.ok(up[1] + W.move_ticks < 900, 'up before T+900: ' .. up[1])
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(#W.find_events('GATE_FORCED'), 0, 'no hostile in sight: nothing is forced')
end)

-- SIEGE, an army walking down x 50..52 from y -90 (130 tiles from B1: within 30 tiles of it after 900 ticks, at the gate after
-- 1150) while a squad walks in over B1 and a citizen reaches it every 170 ticks (100, 270, 440, 610), alternately from each
-- side, each in view of the gate 21 steps out. The siege wants B1 up at T+450 (the timer): the army is far, so the
-- walkers 20 steps out hold the pull (old: a gap for it opens, the next citizen walks onto the moving B1); the last one is
-- across at ~620 and B1 rises then, long before the army arrives
local function traffic_b1()
  local ws = {}
  for i = 1, 6 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 3 do
    local north = k % 2 == 0                   -- from y 61 or y 19: 21 steps to the footprint at y 40
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 61, 28) or route(52, 19, 62),
                   start = 100 + 170 * k - 21 * 9}
  end
  return ws
end
local function army_down(y0)
  local army, foes = S.army(6, 50, y0), {}
  for _, u in ipairs(army) do foes[#foes + 1] = {id = u.id, x = u.pos[1], y0 = u.pos[2], y1 = 38, start = 0} end
  return army, foes
end

T.test('BUG-380 traffic (2): SIEGE, an army approaching B1 -> B1 is up before the army arrives and before T+900, ' ..
       'nobody is crushed, no GATE_FAIL, no BREACH', function()
  local army, foes = army_down(-90)
  local W = build{walkers = traffic_b1(), army = army, foes = foes}
  run(W, 1400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') - W.t_start
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1)
  T.ok(up[1] + W.move_ticks <= 1150, 'up before the army is at the gate (1150): ' .. (up[1] + W.move_ticks))
  T.ok(up[1] + W.move_ticks - t0 < 900, 'up before T+900')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
end)

-- the other half: with the army within HURRY_NEAR (30) tiles of B1 (25: it stands in the killing field) the stream must
-- not keep B1 down for good (BUG-335: BREACH at T+900): the walkers farther than PATH_SIEGE steps are let go again
-- (the hotfix; the accepted risk, a hostile being there), so B1 rises at the siege timer, long before T+900
T.test('BUG-380 traffic (3): SIEGE, an army 25 tiles from B1 and a stream over it -> B1 up before T+900, nobody crushed, ' ..
       'no GATE_FAIL, no BREACH', function()
  local army = S.army(6, 50, 14)
  local W = build{walkers = traffic_b1(), army = army}
  run(W, 1400)
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') - W.t_start
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1)
  T.ok(up[1] + W.move_ticks - t0 < 900, 'B1 up before T+900: ' .. (up[1] + W.move_ticks - t0))
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
end)

-- Review fix (merge20): the raise is timed (CROSS_REACH), not measured by the hostile's distance. Every test asserts both
-- halves: nobody is crushed (nobody on a footprint while it moves) and the bridge is up before T+900 of its epoch.
local function t900(W, b)
  local up = flips_to(W, b, 'up')                  -- the world starts in the mode: the epoch begins at the first tick
  T.eq(#up >= 1, true, b .. ' rose')
  return up[1] + W.move_ticks, up[1]
end
-- a stream 8..20 steps south of B2: citizens in a queue 14..20 steps out whose paths lead over it (they stand there for good:
-- the 20-step rule held the raise for them until GATE_FAIL) and real citizens crossing 220 ticks apart, each within 8..20 steps
-- of it for ~110 ticks
local function south_stream(n, gap, first)
  local ws = {}
  for j = 0, 5 do
    local y = 74 + j
    ws[#ws + 1] = {id = 600 + j, kind = 'citizen', route = {{50 + j % 3, y}}, ghost = route(50 + j % 3, y - 1, 58), start = 0}
  end
  for k = 0, n - 1 do
    ws[#ws + 1] = {id = 400 + k, kind = 'citizen', route = route(50, 80, 46), start = first + gap * k}
  end
  return ws
end

T.test('BUG-380 traffic (4): BREACH, no hostile in sight, a stream of citizens 8..20 steps from B2 -> B2 up before T+900, ' ..
       'nobody on the footprint while it moves', function()
  local W = build{mode = 'BREACH', walkers = south_stream(8, 220, 0)}
  run(W, 2200)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local rel = t900(W, 'B2')
  T.ok(rel < 900, 'B2 up before T+900: ' .. rel)
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

T.test('BUG-380 traffic (5): BREACH, a hostile parked 20 tiles from B2 and the same stream -> B2 up before T+900, ' ..
       'nobody crushed (the walkers 14..20 steps out are let go, the nearer ones hold)', function()
  local W = build{mode = 'BREACH', walkers = south_stream(8, 220, 0), army = S.army(3, 50, 80)}
  run(W, 2200)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local rel = t900(W, 'B2')
  T.ok(rel < 900, 'B2 up before T+900: ' .. rel)
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

T.test('BUG-380 traffic (6): BREACH, a hostile 20 tiles from B2, a soldier 9 steps out walks onto it -> he holds the raise ' ..
       '(not crushed), B2 rises behind him before T+900', function()
  local ws = {{id = 301, kind = 'soldier', route = route(51, 51, 70), start = 40}}
  local W = build{mode = 'BREACH', walkers = ws, army = S.army(3, 50, 80)}
  run(W, 1400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local rel, at = t900(W, 'B2')
  T.ok(rel < 900, 'B2 up before T+900: ' .. rel)
  T.ok(at >= 18 * 9, 'not before the soldier is across (19 steps): ' .. at)
  T.eq(S.bstate(W, 'B2'), 'up')
end)

-- units standing 3..5 steps from B2 with a path that goes on over it (a queue at the gate) never leave: the walkers hold
-- until CROSS_HELD of the DEADLINE, then the deadline escape raises the bridge (nobody on the footprint), logged
T.test('BUG-380 traffic (7): BREACH, a queue within 5 steps of B2 for good -> the deadline escape raises B2 before T+900 ' ..
       'with nobody on the footprint', function()
  local ws = {}
  for i = 0, 5 do
    local y = 63 + i % 3
    ws[#ws + 1] = {id = 500 + i, kind = 'citizen', route = {{50 + i % 3, y}}, ghost = route(50 + i % 3, y - 1, 58), start = 0}
  end
  local W = build{mode = 'BREACH', walkers = ws}
  run(W, 1600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local rel = t900(W, 'B2')
  T.ok(rel < 900, 'B2 up before T+900: ' .. rel)
  T.ok(rel >= 450, 'held until the escape (450 held): ' .. rel)
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

T.done()
