-- BUG-543 raise traffic test (Run 16c i3 Sealcertain y406 autumn d65, DRILL: soldier 26591 'crushed: bridge B1 up (pulled at 163978076),
-- last seen on it at 63,116,140'; two of seven soldiers were still marching to their stations, nothing held B1 from the pull to the
-- lever, the bridge moved and he was on it 90 ticks later). The world of test_bug512_drill_settle (real sense/siege/gate/drill, walkers
-- on and around the bridges, a raised bridge cannot be walked, a unit ON a moving bridge is crushed). The units that crushed him cannot
-- be told from the path: they have NO readable path (soldiers shuffling about a station, marching between squad orders), so
-- M.crossers does not see them. These walkers are adversaries: while their pacing lasts they step onto the footprint the moment the
-- bridge starts to move (`react`). A raise that is not an emergency must never be pulled while one of them is moving within
-- gate.RAISE_R tiles:
--   (1) DRILL, a soldier paces 2 tiles from B1 for ~500 ticks and then stands: nobody is crushed, B1 rises behind him inside the drill's
--       clock and the drill passes the mechanics;
--   (2) DRILL, he never stops: B1 is never raised (nobody crushed), the T+900 drop gives `occupied:B1` (not `up:B1`) and kern.log names him;
--   (3) PEACE, a lever-up of B1 (a gate raise) with the pacer: nobody crushed, raised once he stands; one that never stops ends as
--       GATE_FAIL `blocked` naming him after the deadline;
--   (4) BREACH, citizens and soldiers walking over O1, B1 and B2 (a stream with gaps, the army far away): nobody on a footprint when it moves,
--       all three rise (the emergency rules are unchanged);
--   (5) a soldier standing at his station / a tame animal walking 3 tiles out do not hold a DRILL raise (the drill does not stall on them).
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

-- walkers: {id, kind = 'soldier'|'citizen'|'animal', route, start, nopath = true (no readable path ever), react = {bridge, to = {x, y}}
-- (while the route lasts: steps onto `to` the tick that bridge moves)}
local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    local u
    if w.kind == 'animal' then u = {id = w.id, pos = {x, y, Z}, tame = true, animal = true}
    else u = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil) end
    units[#units + 1] = u
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind, ghost = w.ghost,
                             nopath = w.nopath, react = w.react}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = {worker = 30, pull = 40},
                    manifest = o.manifest, lever_cfg = o.lever_cfg}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  return W
end

local function on_fp(name, x, y)
  return y == FPY[name] and x >= 50 and x <= 52
end

local function path_of(w)
  if w.nopath then return nil end
  local xs, ys, zs = {}, {}, {}
  for k = w.i + 1, math.min(#w.route, w.i + 25) do
    xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z
  end
  for _, g in ipairs(w.ghost or {}) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = g[1], g[2], Z end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

local function census_animals(W)
  local list = {}
  for _, w in ipairs(W.walkers) do if w.kind == 'animal' then list[#list + 1] = {id = w.id} end end
  W.K.census.a = {tick = W.K.now().tick, n = #list, list = list}
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  census_animals(W)
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start then
      local r = w.react
      if r and w.i < #w.route and S.bstate(W, r.bridge) == 'moving' then
        W.move(w.id, r.to[1], r.to[2], Z)                 -- the adversary: onto the footprint while the bridge moves
        w.i = #w.route
      elseif w.i < #w.route then
        local nx = w.route[w.i + 1]
        local blocked = false
        for name in pairs(FPY) do
          if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end   -- a raised bridge: no way
        end
        if not blocked then
          w.i = w.i + 1
          W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
        end
      end
    end
    if not w.dead then W.unit(w.id).path = (rel >= w.start) and path_of(w) or nil end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = {id = w.id, bridge = name, tick = rel, kind = w.kind}
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
  for _, c in ipairs(list) do r[#r + 1] = string.format('%s %d on %s at +%d', c.kind, c.id, c.bridge, c.tick) end
  return table.concat(r, '; ')
end

local function flips_to(W, b, to)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == to then r[#r + 1] = f.tick - W.t_start end end
  return r
end

local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end

-- a soldier pacing along y = 42 (2 tiles from B1's footprint row 40), n steps, then standing; he steps onto (51, 40) when B1 moves
local function pacer(id, n, react)
  local r = {}
  local xs = {48, 50, 49, 50, 48}                       -- a period of 5 frames: never in step with the 25-tick look of gate
  for i = 1, n do r[#r + 1] = {xs[i % 5 + 1], 42} end
  return {id = id, kind = 'soldier', route = r, start = 0, nopath = true, react = react and {bridge = 'B1', to = {51, 40}} or nil}
end

local function drill_world(o)
  local W = build(o)
  package.loaded['dfllm.drill'] = nil
  local drill = require('dfllm.drill')
  drill.SETTLE_MAX = o.settle_max or 1200
  W.load(drill)
  return W, drill
end

local function result(W)
  local r = W.find_events('DRILL_RESULT')
  return r[#r]
end

T.test('BUG-543 (1): DRILL, a soldier with no path paces 2 tiles from B1 (and would step on it the moment it moves), then stands: ' ..
       'B1 is not pulled while he paces, nobody is crushed, B1 rises after he stands still, the drill passes the mechanics', function()
  local W = drill_world{walkers = {pacer(800, 60, true)}}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 3800)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.ok(#up >= 1, 'B1 rose')
  T.ok(up[1] >= 60 * 9, 'not while he paced (' .. tostring(up[1]) .. ')')
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(not fails:find('up:', 1, true) and not fails:find('slow:', 1, true) and not fails:find('occupied', 1, true),
       'no raise failure: ' .. fails)
  T.eq(r.d.mech, 1, 'only the gear (worn) may be missing: ' .. fails)
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

T.test('BUG-543 (2): DRILL, a soldier who paces next to B1 for good: B1 is never raised onto him; the T+900 drop reports ' ..
       'occupied:B1 (not up:B1) and kern.log names him', function()
  local W = drill_world{walkers = {pacer(801, 400, true)}}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 3800)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 never rose')
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(fails:find('occupied:B1', 1, true), 'occupied:B1 is measured: ' .. fails)
  T.ok(not fails:find('up:B1', 1, true), 'not up:B1: ' .. fails)
  T.eq(r.d.mech, 0, 'a drill that could not raise is no mechanics pass')
  T.ok(logged(W, 'drill: B1 not raised: occupied by soldier 801'), 'kern.log names him')
end)

local function peace_world(n, react)
  local W = build{mode = 'PEACE', walkers = {pacer(810, n, react)}}
  return W
end

T.test('BUG-543 (3): PEACE, a lever-up of B1 with the pacer: not pulled while he paces, raised once he stands, nobody crushed', function()
  local W = peace_world(60, true)
  run(W, 100)
  T.eq(select(2, W.K.call('gate', 'want', 'B1', 'up', 'lever:test')), true)
  run(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] >= 60 * 9, 'not while he paced: +' .. tostring(up[1]))
  T.eq(S.bstate(W, 'B1'), 'up')
end)

T.test('BUG-543 (3b): PEACE, a pacer who never stops: B1 stays down, nobody crushed, GATE_FAIL blocked after the deadline names him', function()
  local W = peace_world(400, true)
  run(W, 100)
  W.K.call('gate', 'want', 'B1', 'up', 'lever:test')
  run(W, 2600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 never rose')
  local fails = W.find_events('GATE_FAIL')
  T.ok(#fails >= 1, 'GATE_FAIL')
  T.eq(fails[1].d.why, 'blocked', 'the reason is blocked')
  T.ok(tostring(fails[1].msg):find('citizen 810', 1, true) or tostring(fails[1].msg):find('soldier 810', 1, true),
       'he is named: ' .. tostring(fails[1].msg))
end)

-- a stream over O1, B1 and B2 (the whole column x 51), sparse enough for a gap of a raise
local function column()
  local ws = {}
  for k = 0, 3 do
    local down = k % 2 == 0
    ws[#ws + 1] = {id = 900 + k, kind = k % 2 == 0 and 'citizen' or 'soldier', route = down and route(51, 0, 70) or route(51, 70, 0),
                   start = 400 * k}
  end
  return ws
end

T.test('BUG-543 (4): BREACH, citizens and soldiers walking over O1, B1 and B2: nobody is on a footprint when it moves, all three rise', function()
  local W = build{mode = 'BREACH', walkers = column(), army = S.army(6, 50, 150)}
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, b in ipairs({'O1', 'B1', 'B2'}) do T.eq(S.bstate(W, b), 'up', b .. ' up') end
end)

T.test('BUG-543 (5): a tame animal 3 tiles out and a soldier standing 2 tiles from B1 for good do not stall the drill raise', function()
  local stand = {id = 820, kind = 'soldier', route = {{48, 42}}, start = 0, nopath = true}
  local pet = {id = 821, kind = 'animal', route = {{51, 43}}, start = 0, nopath = true}
  local W = drill_world{walkers = {stand, pet}}
  W.K.call('drill', 'start', 'test')
  run(W, 3800)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(not fails:find('occupied', 1, true) and not fails:find('up:', 1, true), 'raised: ' .. fails)
  T.eq(S.bstate(W, 'B1'), 'down', 'lowered again by the end')
end)

T.done()
