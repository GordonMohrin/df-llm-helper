-- Round 37 (BUG-577 and BUG-580; the traffic test of the audit / siege round): bridges are defense, so a siege or drill change must leave the
-- fort closing in a SIEGE with nobody sealed out or crushed. The world of test_bug543_raise_traffic.lua (real sense / threat / siege / gate /
-- drill, walkers on and around the bridges, a raised bridge cannot be walked, a unit ON a moving bridge is crushed; the pacer is the adversary:
-- 2 tiles from B1 he steps onto the footprint the moment it moves):
--   (1) SIEGE, a citizen next to B1 for ~1000 ticks and a far army (Run 16c i3 Sealcertain y405-y407: 'breach: B1 not up at T+900' with GATE_FAIL
--       'blocked: citizen 26133 next to it'): B1 waits for him, no BREACH, then B1 rises; nobody crushed;
--   (2) SIEGE, a pacer who never stops: B1 stays down, nobody crushed, the BREACH comes once the hold passed siege.CIT_HOLD (as before);
--   (3) SIEGE, a hostile within force_near of B1 and the pacer beside it: the old BREACH at T+900 (a real breach, not a hold for a citizen);
--   (4) DRILL, the pacer beside B1 at T+900: the clock restarts (not `occupied:B1`), B1 rises when he stops, the result says `retries`, the
--       mechanics pass and no failure streak; (5) DRILL, a pacer who never stops: `occupied:B1` after OCC_RETRIES restarts, that failure
--       counts for no streak (no DRILL_FAIL, retry after RETRY_OCC), nobody crushed; (6) traffic_only.
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


local function modes(W) return table.concat(S.modes(W), ',') end

-- a citizen who stands NEXT to B1's footprint (49,41) for n frames of 9 ticks, then walks off into the fort: the gate never raises onto the
-- footprint's neighbours in a SIEGE without a hostile near (BUG-027), so B1 waits for him
local function stander(id, n)
  local r = {}
  for _ = 1, n do r[#r + 1] = {49, 41} end
  for k = 1, 10 do r[#r + 1] = {49 - k, 41 + k} end
  return {id = id, kind = 'citizen', route = r, start = 0, nopath = true}
end

-- the hostile 8 tiles from B1's footprint (NEAR_RAISE is 10, force_near 3): the old rule counted a bridge down with a hostile that near a breach
local function siege_world(o)
  local W = build{mode = 'SIEGE', walkers = o.walkers, army = o.army or {S.inv(250, 51, 32, Z), table.unpack(S.army(5, 50, 150))}}
  return W
end

T.test('BUG-577 (1): SIEGE, a citizen next to B1 for ~1000 ticks, a hostile 8 tiles from it: B1 waits for him, no BREACH, B1 rises after he stops, ' ..
       'nobody is crushed', function()
  local W = siege_world{walkers = {stander(830, 115)}}
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.ok(not modes(W):find('BREACH', 1, true), 'no BREACH for a bridge held for a citizen: ' .. modes(W))
  T.eq(#W.find_events('BREACH'), 0)
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] >= 100 * 9, 'not while he paced (+' .. tostring(up[1]) .. ')')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.ok(logged(W, 'B1 is held down for our own people'), 'kern.log says why there is no BREACH')
end)

T.test('BUG-577 (2): SIEGE, a citizen who never leaves: nobody crushed, B1 stays down, and the BREACH comes once the hold is older than CIT_HOLD', function()
  local W = siege_world{walkers = {stander(831, 700)}}
  run(W, 4400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 never rose')
  local br = W.find_events('BREACH')
  T.ok(#br >= 1, 'a hold longer than CIT_HOLD is a breach as before: ' .. modes(W))
  local t = S.mode_tick(W, 'SIEGE>BREACH')
  local hold = require('dfllm.siege').CIT_HOLD
  T.ok(t - W.t_start >= hold, 'not before the hold passed ' .. hold .. ': +' .. tostring(t - W.t_start))
end)

T.test('BUG-577 (3): SIEGE, a citizen standing ON the footprint of B1 and a hostile 8 tiles out: that is no hold for a citizen next to it, the ' ..
       'BREACH at T+900 as before (BUG-310) and he is never crushed', function()
  local on = {id = 832, kind = 'citizen', route = (function() local r = {} for _ = 1, 400 do r[#r + 1] = {51, 40} end return r end)(),
              start = 0, nopath = true}
  local W = siege_world{walkers = {on}}
  run(W, 2000)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 is never raised onto him')
  T.ok(#W.find_events('BREACH') >= 1 or modes(W):find('BREACH', 1, true), 'BREACH: ' .. modes(W))
  T.ok(not logged(W, 'B1 is held down for our own people'), 'not named a hold for citizens')
end)

T.test('BUG-580 (4): DRILL, a pacer beside B1 at T+900: the clock restarts instead of occupied:B1, B1 rises when he stops, the result carries ' ..
       'retries, the mechanics pass', function()
  local W = drill_world{walkers = {pacer(840, 200, true)}}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 5400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(not fails:find('occupied', 1, true) and not fails:find('up:', 1, true), 'no raise failure: ' .. fails)
  T.ok((r.d.retries or 0) >= 1, 'the clock restarted: retries ' .. tostring(r.d.retries))
  T.eq(r.d.mech, 1, 'only the gear (worn) may be missing: ' .. fails)
  T.eq(#flips_to(W, 'B1', 'up'), 1, 'B1 rose')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  T.ok(logged(W, 'kept down by our own people: the clock starts again'), 'kern.log says so')
end)

T.test('BUG-580 (5): DRILL, a pacer who never stops: occupied:B1 after OCC_RETRIES restarts, no failure streak, no DRILL_FAIL, nobody crushed', function()
  local W, drill = drill_world{walkers = {pacer(841, 700, true)}}
  local ok, msg = W.K.call('drill', 'start', 'test')
  T.ok(ok, tostring(msg))
  run(W, 6600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 never rose')
  local r = result(W)
  T.ok(r, 'DRILL_RESULT')
  local fails = table.concat(r.d.fails or {}, ',')
  T.ok(fails:find('occupied:B1', 1, true), fails)
  T.eq(r.d.retries, drill.OCC_RETRIES, 'restarted OCC_RETRIES times, then dropped')
  T.eq(r.d.pass, 0)
  local rec = W.K.persist.get('drill')
  T.eq(rec.streak_fail, 0, 'a traffic failure is no failed drill (old: 1, then a doubled wait and `drill never`)')
  T.eq(#W.find_events('DRILL_FAIL'), 0)
  T.ok(logged(W, 'the clock starts again (2 of 2)'), 'kern.log counts the restarts')
end)

T.test('BUG-580 (6): traffic_only: only occupied:* failures are traffic; a mixed or empty list is a real failure', function()
  local drill = require('dfllm.drill')
  T.eq(drill.traffic_only({'occupied:B1'}), true)
  T.eq(drill.traffic_only({'occupied:B1', 'occupied:B2'}), true)
  T.eq(drill.traffic_only({'occupied:B1', 'up:B2'}), false)
  T.eq(drill.traffic_only({'worn'}), false)
  T.eq(drill.traffic_only({}), false)
  T.eq(drill.traffic_only(nil), false)
end)

T.done()
