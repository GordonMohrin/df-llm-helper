-- BUG-587 siege traffic test (Run 16c i3 Sealcertain y422 summer: two cave dragons and a goblin army; the recall streamed 27
-- citizens over B1 and B2, both raises waited for people 'walking onto it in 1-13 steps' for 2268 / 2800 ticks while the hostile came from 61
-- to 0 tiles; the dragons toppled B2, entered the refuge Tiefe+ at 62,127,136, the alert flipped Tiefe+ <-> Innen+ ten times and ended with
-- 'no confinement, citizens flee on their own': 61 -> 1).
-- The gate half (the world of test_bug577_580_audit_siege.lua: real sense / threat / siege / gate, walkers on and around the bridges, a
-- raised bridge cannot be walked, a unit ON a moving bridge is crushed; here also a hostile that walks):
--   (1) SIEGE, a hostile CLOSING in from 88 tiles and citizens standing beside B1 for good: B1 is raised past them once the hostile is within
--       approach_near and the hold is older than approach_hold, before it is within approach_close; nobody crushed, GATE_FORCED names them;
--   (2) a PARKED hostile 25 tiles out (not closing, BUG-492's shape): the hold stays (B1 down, nobody crushed, no GATE_FORCED);
--   (3) a closing hostile and a citizen ON B1's footprint who leaves at +1500: never raised onto him, raised right after he left;
--   (4) a stream of citizens over O1, B1 and B2 with the hostile closing in: nobody crushed, every bridge up in time;
--   (5) gate.approach_cfg: bad values fall back to the defaults, 0 turns the bounded hold off (B1 stays down for the stander).
-- The seal half (building destroyers vs the refuge access) is test_bug588_589_refuge_destroyers.lua.
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

-- a hostile walking from (x0, y) to (x1, y), one tile per `per` ticks, starting at +t0 (W.hostile: {id, x0, x1, y, per, t0})
local function hostile_x(h, k)
  local x = h.x0 + (h.x1 - h.x0) * math.min(1, k / math.abs(h.x1 - h.x0))
  return math.floor(x + 0.5)
end

local function hostile_step(W, t)
  local h = W.hostile
  if not h then return end
  local rel = t - (W.t0 or t)
  local k = math.max(0, math.floor((rel - h.t0) / h.per))
  W.move(h.id, hostile_x(h, k), h.y, Z)
end

local function run2(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, function(w, now) step(w, now); hostile_step(w, now) end} end
  S.run(W, ticks, {at = at})
end

local function world(o)
  local army = {S.inv(250, o.x0, o.y or 34, Z), table.unpack(S.army(4, 50, 150))}
  local W = build{mode = 'SIEGE', walkers = o.walkers, army = army}
  W.hostile = {id = 250, x0 = o.x0, x1 = o.x1, y = o.y or 34, per = o.per or 20, t0 = o.t0 or 0}
  return W
end

-- standing beside B1 (49,41) for good
local function stander(id, x)
  local r = {}
  for _ = 1, 600 do r[#r + 1] = {x or 49, 41} end
  return {id = id, kind = 'citizen', route = r, start = 0, nopath = true}
end

-- the tick (relative to the start) the hostile first is within `d` tiles of B1's footprint (x 50..52, y 40)
local function reach_tick(W, d)
  local h = W.hostile
  for k = 0, 400 do
    local x = hostile_x(h, k)
    local dx = x > 52 and x - 52 or (x < 50 and 50 - x or 0)
    local dy = math.abs(h.y - 40)
    if math.max(dx, dy) <= d then return h.t0 + k * h.per end
  end
end

T.test('BUG-587 (1): SIEGE, a hostile closing in from 88 tiles, two citizens standing beside B1 for good: B1 is raised past them when the hostile is within ' ..
       'approach_near and the hold is older than approach_hold - before it is within approach_close; nobody crushed, GATE_FORCED names them', function()
  local W = world{x0 = 140, x1 = 59, walkers = {stander(860, 49), stander(861, 53)}}
  run2(W, 2400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose')
  local t30, t12 = reach_tick(W, 30), reach_tick(W, 12)
  T.ok(up[1] >= t30, 'not while the hostile is far (+' .. tostring(up[1]) .. ' vs ' .. tostring(t30) .. ')')
  T.ok(up[1] <= t12, 'before the hostile is within approach_close (+' .. tostring(up[1]) .. ' vs ' .. tostring(t12) .. ')')
  local f = W.find_events('GATE_FORCED')
  T.ok(#f >= 1 and f[1].msg:find('approach_near', 1, true) and (f[1].msg:find('citizen 860', 1, true) or f[1].msg:find('citizen 861', 1, true)),
       T.show(f))
  T.eq(S.bstate(W, 'B1'), 'up')
end)

T.test('BUG-587 (2): a PARKED hostile 25 tiles out is no approach (BUG-492): the citizen beside B1 keeps the raise down, nobody crushed, no GATE_FORCED', function()
  local W = world{x0 = 64, x1 = 64, y = 15, walkers = {stander(862, 49)}}      -- 25 tiles from B1's row
  run2(W, 2400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 stays down for the citizen')
  T.eq(#W.find_events('GATE_FORCED'), 0)
end)

T.test('BUG-587 (3): a hostile closing in and a citizen ON B1: B1 is never raised onto him (BUG-310), raised once he stepped off', function()
  local r = {}
  for _ = 1, 165 do r[#r + 1] = {51, 40} end                  -- ON the footprint until about +1500
  for k = 1, 30 do r[#r + 1] = {51, 40 + k} end                -- then into the fort
  local W = world{x0 = 140, x1 = 59, walkers = {{id = 863, kind = 'citizen', route = r, start = 0, nopath = true}}}
  run2(W, 3000)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose')
  T.ok(up[1] >= 165 * 9, 'not while he stood on it (+' .. tostring(up[1]) .. ')')
  T.ok(up[1] <= 165 * 9 + 600, 'soon after he left (+' .. tostring(up[1]) .. ')')
end)

T.test('BUG-587 (4): a stream of citizens over O1, B1 and B2 and two standing beside B1, the hostile closing in: nobody is crushed, O1 and B1 ' ..
       'are up when the hostile is within approach_close', function()
  local ws = {stander(870, 49), stander(871, 53)}
  for k = 0, 4 do ws[#ws + 1] = {id = 880 + k, kind = k % 2 == 0 and 'citizen' or 'soldier', route = route(51, 0, 70), start = 300 * k} end
  local W = world{x0 = 150, x1 = 59, walkers = ws}
  run2(W, 3400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local t12 = reach_tick(W, 12)
  for _, b in ipairs({'O1', 'B1'}) do      -- (B2 lies 26 tiles from the hostile's path: it is no approach to it, its stream hold stays)
    local up = flips_to(W, b, 'up')
    T.ok(#up >= 1, b .. ' rose')
    T.ok(up[1] <= t12 + 300, b .. ' up in time (+' .. tostring(up[1]) .. ', hostile within 12 at +' .. tostring(t12) .. ')')
    T.eq(S.bstate(W, b), 'up', b .. ' up at the end')
  end
end)

T.test('BUG-587 (5): gate.approach_cfg: bad values fall back to the defaults; approach_near 0 and approach_close 0 end the bounded hold (B1 stays down)', function()
  local g = require('dfllm.gate')
  local K = {cfg = {reflex = {v = 2, gate = {approach_near = 'x', approach_hold = -5, approach_close = 500}}}}
  local n, h, c = g.approach_cfg(K)
  T.eq({n, h, c}, {g.APPROACH_NEAR, g.APPROACH_HOLD, g.APPROACH_CLOSE})
  local W = world{x0 = 140, x1 = 59, walkers = {stander(864, 49)}}
  W.K.cfg.reflex = {v = 2, gate = {approach_near = 0, approach_close = 0}}
  run2(W, 2400)
  T.eq(#W.crushed, 0)
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'the old rule: B1 waits for the citizen however near the hostile comes')
end)

T.done()
