-- NEU19 BUG-928 (Run 17 i3: 8 of 8 DRILL_RESULT 'failed (occupied:B1/O1 ...)' although the kernel itself keeps a bridge down while any unit within ~99 steps can reach the footprint; GATE_FAIL
-- 'blocked ... can reach it in N ticks' and 'not up after 40825 ticks' in an ALERT for the same hold): EVENT WORDING ONLY. A drill whose only failures are occupied:* is `held`
-- (what was measured: citizens inside after N ticks, footprint clear yes / no); a bridge the reach rule holds down outside SIEGE / BREACH is said in ONE GATE `reach_hold` line, never GATE_FAIL.
-- Bridge raise / lower decisions are NOT changed (the traffic tests of the 15b rounds pin them).
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



T.test('BUG-928 (b): DRILL, a pacer beside B1 for good: DRILL_RESULT is `held` (not `failed`): the message says what was measured, no failure streak, no DRILL_FAIL, nobody crushed', function()
  local W, drill = drill_world{walkers = {pacer(841, 700, true)}}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 6600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  T.eq(r.d.pass, 0)
  T.eq(r.d.word, 'held')
  T.eq(r.d.clear, 0, 'a footprint was held')
  T.ok(r.d.inside ~= nil and r.d.inside >= 0, 'citizens inside counted: ' .. tostring(r.d.inside))
  T.ok(r.d.ticks >= 900, 'after N ticks: ' .. tostring(r.d.ticks))
  T.ok(r.msg:find('drill held', 1, true) and not r.msg:find('drill failed', 1, true), r.msg)
  T.ok(r.msg:find('citizens inside', 1, true) and r.msg:find('footprint clear no', 1, true) and r.msg:find('occupied:B1', 1, true), r.msg)
  T.eq(W.K.persist.get('drill').streak_fail, 0)
  T.eq(#W.find_events('DRILL_FAIL'), 0)
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 was not raised (behaviour unchanged)')
end)

T.done()
