-- BUG-758 crush-guard test (Run 16b i2 Whirledrampart y441 tick 178213236: soldier 29764 'crushed: bridge O1 up (pulled at 178212998), last
-- seen on it at 85,131,140'. ALERT_START for ONE Megalania (7,609 cm3, inside the fort); siege.apply raised the OUTER bridge O1 because a
-- hostile was within ALERT_O1 (30) tiles of it; gate's BUG-587 rule then let every ALERT raise go ahead past moving units (raise_movers
-- skipped with a hostile within approach_near), so the soldiers marching to their stations over O1 no longer held the pull (BUG-543); one
-- of them stepped onto the footprint while it moved).
-- The world of test_bug587_siege_hold.lua (real sense / threat / siege / gate, walkers, a raised bridge cannot be walked, a unit ON a
-- moving bridge is crushed; `react` walkers are adversaries who step onto the footprint the tick the bridge starts to move):
--   (1) ALERT, one wild animal within 30 tiles of O1: O1 is NOT raised (no outer bridge for a lone wild animal), a soldier pacing beside it
--       is never crushed;
--   (2) ALERT, an INVADER within 30 tiles of O1 (the raise stays wanted) and a soldier pacing 2 tiles from O1 who steps on the moment it
--       moves: not pulled while he paces, raised once he stands, nobody crushed;
--   (3) ALERT, the same with a CITIZEN pacing (the recall stream, BUG-587): the raise is not held for him;
--   (4) SIEGE traffic: real invaders closing in, a stream of citizens and soldiers over O1, B1 and B2 and a soldier pacing beside O1: nobody
--       crushed, O1 and B1 up in time (before T+900), the stream is not locked out (a unit that crossed before the raise stands inside).
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

local function hostile_x(h, k)
  local x = h.x0 + (h.x1 - h.x0) * math.min(1, k / math.max(1, math.abs(h.x1 - h.x0)))
  return math.floor(x + 0.5)
end

local function hostile_step(W, t)
  local h = W.hostile
  if not h then return end
  W.move(h.id, hostile_x(h, math.max(0, math.floor((t - (W.t0 or t) - h.t0) / h.per))), h.y, Z)
end

local function world(o)
  local army = o.army
  local W = build{mode = o.mode or 'ALERT', walkers = o.walkers, army = army}
  W.hostile = o.hostile
  return W
end

local function run2(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, function(w, now) step(w, now); hostile_step(w, now) end} end
  S.run(W, ticks, {at = at})
end

local function pacer(id, kind, n, x, react)
  local r = {}
  for k = 1, n do r[#r + 1] = {k % 2 == 0 and x or x + 1, 13} end      -- shuffling 3 tiles below O1's row (y 10)
  return {id = id, kind = kind, route = r, start = 0, nopath = true, react = react and {bridge = 'O1', to = {51, 10}} or nil}
end

T.test('BUG-758 (1): ALERT, one wild animal within 30 tiles of O1 and a soldier pacing beside it: O1 is not raised, nobody crushed', function()
  local W = world{army = {S.danger(250, 51, 30, Z)}, walkers = {pacer(810, 'soldier', 200, 49, true)}}
  run2(W, 2400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'O1', 'up'), 0, 'no outer raise for a lone wild animal')
  T.eq(S.bstate(W, 'O1'), 'down')
end)

T.test('BUG-758 (2): ALERT, an invader within 30 tiles of O1, a soldier pacing 3 tiles from it who steps on when it moves: held while he paces, raised once he stands, nobody crushed', function()
  local W = world{army = {S.inv(250, 51, 30, Z)}, walkers = {pacer(811, 'soldier', 60, 49, true)}}
  run2(W, 2400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'O1', 'up')
  T.eq(#up, 1, 'O1 rose once')
  T.ok(up[1] >= 60 * 9, 'not while he paced: +' .. tostring(up[1]))
  T.eq(S.bstate(W, 'O1'), 'up')
end)

T.test('BUG-758 (3): ALERT, an invader within 30 tiles of O1 and a CITIZEN pacing 3 tiles from it: the recall stream does not hold the raise (BUG-587)', function()
  local W = world{army = {S.inv(250, 51, 30, Z)}, walkers = {pacer(812, 'citizen', 400, 49, false)}}
  run2(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'O1', 'up'), 1, 'O1 rose past the citizen')
  T.eq(S.bstate(W, 'O1'), 'up')
end)

T.test('BUG-758 (4): SIEGE traffic, invaders closing in, a stream over O1, B1 and B2 and a soldier pacing beside O1: nobody crushed, O1 and B1 up before T+900', function()
  local ws = {pacer(813, 'soldier', 40, 49, true)}
  for k = 0, 4 do ws[#ws + 1] = {id = 880 + k, kind = k % 2 == 0 and 'citizen' or 'soldier', route = route(51, 0, 70), start = 300 * k} end
  local W = world{mode = 'SIEGE', army = {S.inv(250, 51, 34, Z), table.unpack(S.army(4, 50, 100))}, walkers = ws,
                  hostile = {id = 250, x0 = 51, x1 = 51, y = 34, per = 20, t0 = 0}}
  run2(W, 3400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, b in ipairs({'O1', 'B1'}) do
    local up = flips_to(W, b, 'up')
    T.ok(#up >= 1, b .. ' rose')
    T.ok(up[1] <= 900, b .. ' up before T+900 (+' .. tostring(up[1]) .. ')')
    T.eq(S.bstate(W, b), 'up', b .. ' up at the end')
  end
  local inside = 0
  for _, w in ipairs(W.walkers) do if not w.dead and w.id >= 880 and W.unit(w.id)._m.y > 14 then inside = inside + 1 end end
  T.ok(inside >= 1, 'a walker of the stream stands inside')
end)

T.test('BUG-758 (5): ALERT with a predator, a soldier standing ON O1 for good: never crushed (no raise for the animal; with an invader no raise onto him)', function()
  local stand = {id = 814, kind = 'soldier', route = {{51, 10}}, start = 0, nopath = true}
  local W = world{army = {S.danger(250, 51, 30, Z)}, walkers = {stand}}
  run2(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(S.bstate(W, 'O1'), 'down')
  local W2 = world{army = {S.inv(250, 51, 30, Z)}, walkers = {{id = 815, kind = 'soldier', route = {{51, 10}}, start = 0, nopath = true}}}
  run2(W2, 1500)
  T.eq(#W2.crushed, 0, 'crushed: ' .. names(W2.crushed))
  T.eq(#flips_to(W2, 'O1', 'up'), 0, 'not raised onto him')
end)

T.done()
