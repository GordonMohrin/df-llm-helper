-- BUG-512 drill traffic test (Run 16d i4 Trumpetrealms y389-y395: 40 DRILL_RESULT 'up:B1, slow:O1, worn<90'; the drill started its clock at
-- T0, the tick the alert sends everybody home and the squads to their stations over B1, so the raise waited for the march and the
-- measurement missed). The world of test_bug510_513_siege with the REAL drill module (military stands in: 8 soldiers, 7 on station):
--   (1) the recall (citizens outside walk in over B1, one every 150 ticks for ~900 ticks) and a squad marching over B1: with the settle
--       phase B1 and O1 rise AFTER the march, inside the drill's own clock (B1 up by T+900 of the settle tick), the drill passes the
--       mechanics (no up:/slow: failure), nobody is crushed, DRILL_RESULT carries `settle`;
--   (2) a citizen who stays outside for good: the settle cap (SETTLE_MAX) ends the settle, the drill measures `outside:1` as before;
--   (3) SETTLE_MAX 0 keeps the old clock (T0): the control that the recall stream makes the old drill miss B1.
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

-- walkers: {id, kind = 'soldier'|'citizen'|'animal', route, start (ticks), ghost}; the stepper moves them one tile per frame
local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    local u
    if w.kind == 'animal' then u = {id = w.id, pos = {x, y, Z}, tame = true, animal = true}
    else u = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil) end
    units[#units + 1] = u
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind, ghost = w.ghost}
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
  local xs, ys, zs = {}, {}, {}
  for k = w.i + 1, math.min(#w.route, w.i + 25) do
    xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z
  end
  for _, g in ipairs(w.ghost or {}) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = g[1], g[2], Z end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

-- an animal in the census (sense refreshes it only every COUNT_EVERY ticks)
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
    if not w.dead and rel >= w.start and w.i < #w.route then
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


local D = require('dfllm.drill')

local function drill_world(o)
  local W = build(o)
  package.loaded['dfllm.drill'] = nil
  local drill = require('dfllm.drill')
  drill.SETTLE_MAX = o.settle_max or 1200
  W.load(drill)
  return W, drill
end

-- the citizens outside walk in over B1 (one every 150 ticks), a squad of 3 marches over it too
local function recall(n)
  local ws = {}
  for k = 0, n - 1 do ws[#ws + 1] = {id = 600 + k, kind = 'citizen', route = route(51, 20, 60), start = 150 * k} end
  for k = 0, 2 do ws[#ws + 1] = {id = 640 + k, kind = 'soldier', route = route(50 + k, 30, 46), start = 60 * k} end
  return ws
end

local function result(W)
  local r = W.find_events('DRILL_RESULT')
  return r[#r]
end

T.test('BUG-512 (1): the drill settles first: the recall and the squad march are over before the raise is asked for; B1 and O1 are ' ..
       'up inside the drill clock, no up:/slow: failure, nobody crushed, DRILL_RESULT settle > 0', function()
  local W, drill = drill_world{walkers = recall(6)}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 3800)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  T.ok(r.d.settle and r.d.settle > 0, 'the drill settled for ' .. tostring(r.d.settle))
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(not fails:find('up:', 1, true) and not fails:find('slow:', 1, true), 'no raise failure: ' .. fails)
  T.eq(r.d.mech, 1, 'only the gear (worn) may be missing: ' .. fails)
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
  -- the raise was not asked for before the settle ended
  local up = flips_to(W, 'B1', 'up')
  T.ok(up[1] and up[1] >= r.d.settle, 'B1 rose after the settle (' .. tostring(r.d.settle) .. '): +' .. tostring(up[1]))
end)

T.test('BUG-512 (2): a citizen who stays outside: the settle ends at SETTLE_MAX, the drill measures outside:1 as before', function()
  local W = drill_world{walkers = {{id = 700, kind = 'citizen', route = {{51, 20}}, start = 0}}, settle_max = 600}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 3300)
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  T.ok(r.d.settle >= 600 and r.d.settle <= 650, 'the cap ended the settle: ' .. tostring(r.d.settle))
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(fails:find('outside:1', 1, true), 'outside:1 is measured: ' .. fails)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
end)

T.test('BUG-512 (3): control, SETTLE_MAX 0 = the old clock from T0 (settle 0)', function()
  local W = drill_world{walkers = recall(6), settle_max = 0}
  W.K.call('drill', 'start', 'test')
  run(W, 3300)
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  T.eq(r.d.settle, 0, 'no settle phase')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
end)

T.done()
