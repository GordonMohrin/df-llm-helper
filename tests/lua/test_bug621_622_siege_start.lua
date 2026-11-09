-- BUG-621 / BUG-622 siege traffic test (Run 16d i4 Trumpetrealms y431 winter: SIEGE_START with a cave dragon from 105 tiles, a goblin army
-- and a snatcher within one day; 7 citizens outside Kern+ at the alert, '+41 more out since' 9 ticks after it, 3 dead outside; BREACH 'B1 not up at
-- T+900' with citizens pacing beside B1: the force of BUG-587 held for the one look in which the hostile was 26-29 tiles out and closing, the lever
-- worker took the pull 200-400 ticks later, the hostile was out of view by then, a citizen 2-3 tiles from B1 'walking toward it' cancelled the pull,
-- again and again, 1500 ticks).
-- The gate half (the world of test_bug587_siege_hold.lua: real sense / threat / siege / gate, walkers on and around the bridges, a hostile that walks
-- and steps out of view, slow lever workers):
--   (1) a hostile closing in to 24 tiles and out of view, a citizen pacing 2-3 tiles from B1, a worker that takes 200 ticks: B1 is raised (old: never),
--       nobody crushed;
--   (2) the same with a PARKED hostile that never qualified as an approach: no force, no raise (BUG-492 stays), nobody crushed;
--   (3) the hostile is out of view and a citizen stands ON B1 until +1500: never raised onto him, raised right after he left (BUG-310);
--   (4) the recall's stream over O1 / B1 (citizens coming in from the field) with the pacer and the vanishing hostile: nobody crushed, nobody shut
--       out (all inside Kern+ when B1 is up), B1 up before the hostile is within approach_close.
-- The recall half (the count of the citizens out) is in test_recall.lua (BUG-621), the SIEGE_END wording in test_siege.lua (BUG-622).
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z
local FPY = {O1 = 10, B1 = 40, B2 = 60}

local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end

-- a pacing citizen beside B1: steps toward the footprint and back (every step closer is a 'walking toward it')
local function pacer(id)
  local r = {}
  for _ = 1, 400 do r[#r + 1] = {46, 41}; r[#r + 1] = {47, 41}; r[#r + 1] = {48, 41}; r[#r + 1] = {47, 41} end
  return {id = id, route = r}
end

local function stream(id, start)          -- coming in over O1 and B1 from the field, then on into Kern+
  local r = {}
  for y = 0, 70 do r[#r + 1] = {51, y} end
  return {id = id, route = r, start = start}
end

local function build(walkers, hostile, lever)
  local units = S.fort_units()
  for _, w in ipairs(walkers) do
    units[#units + 1] = S.cit(w.id, w.route[1][1], w.route[1][2], Z)
    w.i = 1
  end
  units[#units + 1] = S.inv(hostile.id, hostile.x0, hostile.y, Z)
  for _, u in ipairs(S.army(4, 50, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, mode = 'SIEGE', move = 100, lever_default = lever or {worker = 30, pull = 40}}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.walkers, W.hostile, W.crushed, W.t0 = walkers, hostile, {}, nil
  return W
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= (w.start or 0) and w.i < #w.route then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end      -- a raised bridge: no way
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
      end
    end
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
  local h = W.hostile
  local k = math.max(0, math.floor((rel - h.t0) / h.per))
  local x = h.x0 + (h.x1 - h.x0) * math.min(1, k / math.abs(h.x1 - h.x0))
  local y = h.y
  if h.gone and rel >= h.gone then x, y = 400, 400 end       -- out of sight (a hostile that left the census)
  W.move(h.id, math.floor(x + 0.5), y, Z)
end

local function run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  S.run(W, ticks, {at = at})
end

local function flips_to(W, b, to)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == to then r[#r + 1] = f.tick - W.t_start end end
  return r
end

local function names(list)
  local r = {}
  for _, c in ipairs(list) do r[#r + 1] = string.format('citizen %d on %s at +%d', c.id, c.bridge, c.tick) end
  return table.concat(r, '; ')
end

local SLOW = {worker = 200, pull = 40}          -- the lever worker comes 200 ticks after the pull was queued (live: 85-455)

T.test('BUG-621 (1): a hostile closes in to 24 tiles and steps out of view, a citizen paces 2-3 tiles from B1, the worker takes 200 ticks: ' ..
       'the approach force stays (APPROACH_STICKY), B1 is raised, nobody crushed', function()
  local W = build({pacer(860)}, {id = 250, x0 = 140, x1 = 76, y = 34, per = 20, t0 = 0, gone = 1400}, SLOW)
  run(W, 3000)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose (old: the pacer cancelled every pull once the hostile was out of view)')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.ok(up[1] <= 1400 + 900 + 400, 'within the sticky window (+' .. tostring(up[1]) .. ')')
end)

T.test('BUG-621 (2): a PARKED hostile 25 tiles out never qualified: no force, the pacer keeps B1 down (BUG-492), nobody crushed', function()
  local W = build({pacer(861)}, {id = 250, x0 = 64, x1 = 64, y = 15, per = 20, t0 = 0, gone = 1400}, SLOW)
  run(W, 3000)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 stays down')
end)

T.test('BUG-621 (3): the force is sticky, a citizen ON B1 still holds it: never raised onto him, raised right after he left', function()
  local r = {}
  for _ = 1, 165 do r[#r + 1] = {51, 40} end                  -- ON the footprint until about +1500
  for k = 1, 30 do r[#r + 1] = {51, 40 + k} end                -- then into the fort
  local W = build({{id = 862, route = r}}, {id = 250, x0 = 140, x1 = 76, y = 34, per = 20, t0 = 0, gone = 1400}, SLOW)
  run(W, 4000)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose')
  T.ok(up[1] >= 165 * 9, 'not while he stood on it (+' .. tostring(up[1]) .. ')')
  T.ok(up[1] <= 165 * 9 + 900, 'soon after he left (+' .. tostring(up[1]) .. ')')
end)

T.test('BUG-621 (4): the recall streams over O1 and B1 (citizens coming in from the field) with a pacer beside B1 and a hostile that closes in and ' ..
       'steps out of view: nobody crushed, nobody shut out, B1 up before the hostile is within approach_close', function()
  local ws = {pacer(870)}
  for k = 0, 3 do ws[#ws + 1] = stream(880 + k, 100 * k) end
  local W = build(ws, {id = 250, x0 = 150, x1 = 76, y = 34, per = 20, t0 = 0, gone = 1700}, SLOW)
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, w in ipairs(ws) do
    if w.id >= 880 then
      local u = W.unit(w.id)
      T.ok(u._m.y > 41, string.format('citizen %d came in (y %d)', w.id, u._m.y))
    end
  end
  local up = flips_to(W, 'B1', 'up')
  T.ok(#up >= 1, 'B1 rose')
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up at the end')
  T.ok(up[1] <= 1700 + 1300, 'in time (+' .. tostring(up[1]) .. ')')
end)

T.done()
