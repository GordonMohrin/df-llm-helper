-- BUG-492 / BUG-493 siege traffic tests (the rule: any change to gate.lua or the bridge raise/lower logic comes with a traffic
-- test). The world of test_bug478_refuge_lever_traffic (real sense/threat/siege/gate, walkers on and around the bridges, a raised
-- bridge cannot be walked, a unit ON a moving bridge is crushed):
--   (1) BREACH, the army parked 25 tiles from B1, the BUG-462 stream of citizens and soldiers over B1: citizen 323 was crushed at
--       +603 (the deadline escape let the raise go while he walked 8 steps out). Now nobody is crushed and B1 rises behind him;
--   (2) BREACH, a stream that never leaves a gap: B1 is not raised onto anybody; at the deadline GATE_FAIL `blocked` names the units;
--   (3) BREACH, a queue that stands 3..5 steps out for good: the escape still raises (BUG-380 7), a walker among them still holds;
--   (4) DRILL, the recall streams over B1 (14..20 steps out): B1 is up by T+900 (the old rule held it for every unit within 20
--       path steps for the whole drill: 'up:B1/O1' in 42 of 45 drills of Run 16d i4), nobody crushed;
--   (5) the drill's end lowers the bridges within the quiet window cap (gate.QUIET_DRILL), not after 2400 ticks.
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- the footprints are x 50..52 at these rows (O1 leaves it when destroyed)

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
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = {worker = 30, pull = 40},
                    manifest = o.manifest, lever_cfg = o.lever_cfg}
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




local function stream_walkers()
  local ws = {}
  for i = 1, 6 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 3 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 61, 28) or route(52, 19, 62),
                   start = 100 + 170 * k - 21 * 9}
  end
  return ws
end

T.test('BUG-492 (1): BREACH, the army parked 25 tiles from B1, the citizen stream over B1 -> nobody crushed (323 walked 8 steps ' ..
       'out when the escape released him), B1 up once the walker is across', function()
  local W = build{mode = 'BREACH', walkers = stream_walkers(), army = S.army(6, 50, 15)}
  run(W, 1800)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

-- a citizen every 80 ticks walks over B1 from the north and from the south for ~2000 ticks: never the gap of ~120 ticks a raise
-- needs (13 steps to the footprint at 9 ticks)
local function endless(n)
  local ws = {}
  for k = 0, n - 1 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 400 + k, kind = 'citizen', route = north and route(50, 22, 58) or route(52, 58, 22), start = 80 * k}
  end
  return ws
end

T.test('BUG-492 (2): BREACH, a stream without a gap: B1 is never raised onto anybody; at the deadline GATE_FAIL blocked names ' ..
       'the units (the time-out with a reason)', function()
  local W = build{mode = 'BREACH', walkers = endless(30), army = S.army(6, 50, 15)}
  run(W, 2400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local fails = W.find_events('GATE_FAIL')
  T.ok(#fails >= 1, 'GATE_FAIL when the stream never ends')
  T.eq(fails[1].d.why, 'blocked', 'the reason is blocked')
  T.ok(tostring(fails[1].msg):find('citizen', 1, true), 'the units are named: ' .. tostring(fails[1].msg))
end)

T.test('BUG-492 (3): BREACH, a queue standing 3..5 steps from B1 for good and one walker 9 steps out at the escape: the walker ' ..
       'holds the raise past the escape, the queue does not; B1 rises behind him, nobody crushed', function()
  local ws = {}
  for i = 0, 5 do
    local y = 43 + i % 3
    ws[#ws + 1] = {id = 500 + i, kind = 'citizen', route = {{50 + i % 3, y}}, ghost = route(50 + i % 3, y - 1, 36), start = 0}
  end
  ws[#ws + 1] = {id = 520, kind = 'citizen', route = route(51, 20, 60), start = 450 - 9 * 9}
  local W = build{mode = 'BREACH', walkers = ws}
  run(W, 1700)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose')
  T.ok(up[1] >= 450, 'not before the escape: ' .. up[1])
  T.eq(S.bstate(W, 'B1'), 'up')
end)

-- the drill's recall: citizens stream over B1 from the outside (14..20 steps out) during the first ~1000 ticks
local function recall(n, gap)
  local ws = {}
  for k = 0, n - 1 do ws[#ws + 1] = {id = 600 + k, kind = 'citizen', route = route(51, 20, 60), start = gap * k} end
  return ws
end

T.test('BUG-493 (4): DRILL, the recall streams over B1 -> B1 is up by T+900 (walkers 14+ steps out cannot reach it while it ' ..
       'moves), nobody crushed', function()
  local W = build{walkers = recall(6, 250)}
  W.load(S.drill())                                    -- siege ends a DRILL at once without a drill module
  W.K.set_mode('DRILL', 'test drill')
  run(W, 1300)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up >= 1, true, 'B1 rose')
  T.ok(up[1] + W.move_ticks <= 900, 'B1 up by T+900: ' .. tostring(up[1] and up[1] + W.move_ticks))
end)

T.test('BUG-493 (5): the drill lowers a bridge after QUIET_DRILL ticks of a busy ring, not QUIET_MAX', function()
  -- a unit pacing 2 tiles from B1 keeps the quiet window from opening; the lowering of the drill's end goes ahead after
  -- QUIET_DRILL ticks on the 1-tile margin
  local r = {}
  for i = 1, 200 do r[#r + 1] = {i % 2 == 0 and 48 or 49, 42} end
  -- (BUG-543: the pacer starts after B1 is up: a unit moving within 3 tiles of the footprint holds a raise, not a lowering's 1-tile margin)
  local W = build{walkers = {{id = 700, kind = 'citizen', route = r, start = 380}}}
  W.load(S.drill())                                    -- siege ends a DRILL at once without a drill module
  W.K.set_mode('DRILL', 'test drill')
  run(W, 400)
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up >= 1, true, 'B1 up in the drill')
  W.K.call('gate', 'want', 'B1', 'down', 'drill_end')
  local t0 = W.K.now().tick
  run(W, 1500)
  local down = flips_to(W, 'B1', 'down')
  T.eq(#down >= 1, true, 'B1 came down')
  T.ok(down[#down] + W.t_start - t0 < 1200, 'B1 lowered well before QUIET_MAX (2400): +' .. tostring(down[#down] + W.t_start - t0))
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
end)

T.done()
