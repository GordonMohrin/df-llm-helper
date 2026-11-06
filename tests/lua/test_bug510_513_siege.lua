-- BUG-510 .. BUG-513 siege traffic tests (the rule: any change to gate.lua, the bridge raise / lower, the drill or the levers comes
-- with a traffic test that simulates SIEGE / BREACH with citizens and soldiers on and around the bridges). The world of
-- test_bug492_493_traffic (real sense / threat / siege / gate, walkers on and around the bridges, a raised bridge cannot be walked,
-- a unit ON a moving bridge is crushed):
--   (1) SIEGE, a tame animal paces 2..4 tiles from B1 and then walks at it (Run 16a i1 Basementflew y406: ONE animal held the raise
--       1,242 ticks, BREACH 'B1 not up at T+900'): B1 is up well before T+900, nobody crushed, no GATE_FAIL;
--   (2) SIEGE, the same animal STANDS on the footprint: it holds the raise only until the deadline escape, B1 rises then;
--   (3) SIEGE with a stream of citizens, soldiers on their way to the station and the animal: B1 up once the stream is across, the
--       gate closes, nobody crushed.
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

-- an animal that paces 2..4 tiles south of B1; DF's path says it walks on over the footprint (it stops 2 tiles short, as a pet
-- that changes its mind does: the raise must not wait for such a path)
local function pacing_animal(id)
  local r = {}
  for i = 1, 14 do r[#r + 1] = {51, 43 + (i % 3)} end
  r[#r + 1] = {51, 42}
  return {id = id, kind = 'animal', route = r, start = 0, ghost = route(51, 41, 36)}
end

T.test('BUG-510 (1): SIEGE, a tame animal paces 2..4 tiles from B1, its path leads over the footprint -> B1 is up well before T+900, no GATE_FAIL, ' ..
       'nobody crushed (one animal held the raise 1,242 ticks in Run 16a i1)', function()
  local W = build{mode = 'SIEGE', walkers = {pacing_animal(800)}, army = S.army(3, 50, 15)}
  run(W, 1300)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up >= 1, true, 'B1 rose')
  T.ok(up[1] + W.move_ticks <= 900, 'B1 up by T+900: ' .. tostring(up[1] and up[1] + W.move_ticks))
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
  T.eq(#W.find_events('BREACH'), 0, 'no BREACH')
end)

T.test('BUG-510 (2): SIEGE, a tame animal STANDS on the footprint -> it holds the raise until the deadline escape only, then B1 ' ..
       'rises', function()
  local W = build{mode = 'SIEGE', walkers = {{id = 801, kind = 'animal', route = {{51, 40}}, start = 0}}}
  run(W, 1600)
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up >= 1, true, 'B1 rose')
  T.ok(up[1] >= 400, 'not before the escape (a unit on the footprint holds): +' .. tostring(up[1]))
  T.ok(up[1] <= 900, 'by the deadline: +' .. tostring(up[1]))
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

T.test('BUG-510 (3): SIEGE, citizens and soldiers over B1 and an animal at it -> the gate closes behind the stream, nobody ' ..
       'crushed, no GATE_FAIL', function()
  local ws = {pacing_animal(802)}
  for i = 1, 4 do ws[#ws + 1] = {id = 310 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 2 do ws[#ws + 1] = {id = 330 + k, kind = 'citizen', route = route(50 + k % 2, 28, 62), start = 90 * k} end
  local W = build{mode = 'SIEGE', walkers = ws, army = S.army(4, 50, 15)}
  run(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 is up')
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
end)

T.done()
