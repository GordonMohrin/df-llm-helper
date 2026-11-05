-- BUG-478 siege traffic test (Gordon's rule: bridge/gate changes only with a siege traffic test). Round 30 changed gate.resolve
-- so that every bridge gets a linked lever INSIDE the refuge burrow Tiefe+ (the one place the civilians confined by the civ alert
-- in BREACH / SIEGE_DEEP can pull from). The world: each bridge has its two Kern+ levers (manifest) PLUS a refuge lever in
-- Tiefe+; the Kern+ levers are dead (lever_cfg worker = nil: nobody confined to Tiefe+ can reach them), so a bridge moves only
-- if the gate sends the pull to the refuge lever. Citizens and a squad walk over the bridges (a raised bridge cannot be
-- walked, a unit on a moving bridge is crushed) while the real sense/threat/siege/gate run. Asserts the BUG-380/462 invariants
-- (nobody crushed, nobody shut out, B1 up before the invaders reach it, no GATE_FAIL / BREACH) plus: the pulls go to the
-- refuge levers, and no inner_wait hold (GATE state 'held', round 15 / BUG-338) and no lever hold (held down) stays on a bridge.
-- Controls: the old outside-lever fort (no refuge lever, Kern+ levers work) behaves as before; with neither a working lever
-- outside nor one in the refuge the pull fails (the test world bites).
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



local TROLL = 77
local function troll_raws()
  local lvl, flag = {flags = {}, misc = {buildingdestroyer = 1}}, {flags = {BUILDINGDESTROYER = true}}
  df.creature_raw = {find = function(r) if r == TROLL then return {caste = {[0] = lvl, [1] = flag}} end end}
end

local REF = {O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}, B2 = {72, 70, Z - 6}}
local function manifest_ref()
  local m = S.manifest()
  for name, p in pairs(REF) do table.insert(m.bridges[name].levers, p) end
  return m
end
-- the Kern+ levers (manifest ids 11,12,21,22,31,32) are out of reach for the confined civilians
local function dead_kern()
  local c = {}
  for _, ids in pairs(S.LEVERS) do for _, id in ipairs(ids) do c[id] = {pull = 40} end end
  return c
end
local function ref_world(o)
  o.manifest, o.lever_cfg = manifest_ref(), dead_kern()
  return build(o)
end
local function is_ref(W, lid)
  local lv = W.buildings[lid]
  return lv ~= nil and lv.x1 >= 70
end
local function pulled(W, b)
  local n_ref, n_other = 0, 0
  for _, p in ipairs(S.pulls(W, b)) do if is_ref(W, p.lever) then n_ref = n_ref + 1 else n_other = n_other + 1 end end
  return n_ref, n_other
end
local function held_events(W)
  local n = 0
  for _, ev in ipairs(W.find_events('GATE')) do if ev.d and ev.d.state == 'held' then n = n + 1 end end
  return n
end
local function logs_with(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat) then n = n + 1 end end
  return n
end
local function walkers_across(W)
  for _, w in ipairs(W.walkers) do T.eq(w.i, #w.route, 'walker ' .. w.id .. ' got through (not shut out)') end
end

local function route_walkers()
  local ws = {}
  for i = 1, 6 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 3 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 61, 28) or route(52, 19, 62),
                   start = 100 + 170 * k - 21 * 9}
  end
  return ws
end

local function troll_army(W)
  local foes = {}
  for i = 1, 6 do
    local troll = i <= 2
    local u = W.add_unit(S.inv(500 + i, 50 + i % 3, -90 - (i // 3), Z, troll and {race = 'TROLL'} or nil))
    if troll then u.race, u.caste = TROLL, i % 2 end
    foes[#foes + 1] = {id = u.id or (500 + i), x = 50 + i % 3, y0 = -90 - (i // 3), y1 = 38, start = 0}
  end
  return foes
end

T.test('BUG-478 traffic (1): SIEGE, two trolls and goblins walk down the gate lane, citizens return over B1, the Kern+ levers ' ..
       'are out of reach -> the pulls go to the refuge levers, B1 up before the army reaches it, nobody crushed or shut out',
       function()
  local W = ref_world{walkers = route_walkers()}
  troll_raws()
  W.foes = troll_army(W)
  run(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  walkers_across(W)
  T.ok(#W.find_events('SIEGE_DEEP') >= 1, 'the destroyers send the civilians to the refuge')
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] + W.move_ticks <= 1150, 'B1 up before the army reaches it: ' .. (up[1] + W.move_ticks))
  T.eq(S.bstate(W, 'B1'), 'up')
  local r, o = pulled(W, 'B1')
  T.ok(r >= 1, 'B1 was pulled from the refuge lever')
  T.eq(o, 0, 'no pull went to a lever outside the refuge')
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0, 'no GATE_FAIL / BREACH')
  T.eq(held_events(W), 0, 'no inner_wait hold left over (round 15)')
  T.eq(logs_with(W, 'held down'), 0, 'no lever hold')
end)

T.test('BUG-478 traffic (2): BREACH, no hostile in sight, squad and citizens stream over B2, Kern+ levers out of reach -> B2 ' ..
       'is pulled from the refuge lever, up before T+900, nobody crushed, no GATE_FAIL', function()
  local ws = {}
  for i = 1, 6 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 46, 66), start = (i - 1) * 18} end
  for k = 0, 5 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 90, 46) or route(52, 46, 90),
                   start = 300 + 230 * k - (north and 270 or 126)}
  end
  local W = ref_world{mode = 'BREACH', walkers = ws}
  run(W, 2600)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  -- BREACH raises B2 in the first gap: the citizens still out then are shut out by design (not asserted here)
  for _, w in ipairs(W.walkers) do if w.kind == 'soldier' then T.eq(w.i, #w.route, 'soldier ' .. w.id .. ' got through') end end
  local up = flips_to(W, 'B2', 'up')
  T.eq(#up, 1, 'B2 rose once')
  T.ok(up[1] + W.move_ticks < 900, 'B2 up before T+900: ' .. up[1])
  T.eq(S.bstate(W, 'B2'), 'up')
  local r, o = pulled(W, 'B2')
  T.ok(r >= 1 and o == 0, 'B2 pulled from the refuge lever only: ' .. r .. '/' .. o)
  T.eq(#W.find_events('GATE_FAIL'), 0, 'no GATE_FAIL')
  T.eq(held_events(W), 0)
  T.eq(logs_with(W, 'held down'), 0)
end)

-- (a plain SIEGE with the Kern+ alert may use the Kern+ levers, so the dead ones belong to the deep defense / BREACH only)
T.test('BUG-478 traffic (3): two trolls and goblins 25 tiles from B1 in the killing field (deep defense), a stream over B1 -> ' ..
       'B1 up before T+900 from the refuge lever, nobody crushed or shut out', function()
  local W = ref_world{walkers = route_walkers()}
  troll_raws()
  for i = 1, 2 do local u = W.add_unit(S.inv(500 + i, 50 + i, 14, Z, {race = 'TROLL'})); u.race, u.caste = TROLL, i % 2 end
  for i = 3, 6 do W.add_unit(S.inv(500 + i, 50 + i % 3, 15, Z)) end
  run(W, 1400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  walkers_across(W)
  T.ok(#W.find_events('SIEGE_DEEP') >= 1, 'deep defense')
  local up = flips_to(W, 'B1', 'up')
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') - W.t_start
  T.eq(#up, 1)
  T.ok(up[1] + W.move_ticks - t0 < 900, 'B1 up before T+900: ' .. (up[1] + W.move_ticks - t0))
  T.eq(S.bstate(W, 'B1'), 'up')
  local r, o = pulled(W, 'B1')
  T.ok(r >= 1 and o == 0, 'pulled from the refuge lever only: ' .. r .. '/' .. o)
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
  T.eq(held_events(W), 0)
end)

-- the old case: a fort without a refuge lever whose Kern+ levers work behaves as before (BUG-462 traffic, same asserts)
T.test('BUG-478 traffic (4): the old outside-lever fort (no refuge lever, Kern+ levers work), SIEGE with trolls -> as before: ' ..
       'B1 up before the army, nobody crushed or shut out, pulls on the Kern+ levers, no GATE_FAIL', function()
  local W = build{walkers = route_walkers()}
  troll_raws()
  W.foes = troll_army(W)
  run(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  walkers_across(W)
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] + W.move_ticks <= 1150, 'B1 up before the army reaches it: ' .. (up[1] + W.move_ticks))
  local r, o = pulled(W, 'B1')
  T.eq(r, 0)
  T.ok(o >= 1, 'pulled from a Kern+ lever')
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
  T.eq(held_events(W), 0)
end)

-- the Castletongs case: the refuge lever stands BESIDE its manifest tile (not in the manifest's list at all), linked to the bridge;
-- the manifest levers are the Kern+ ones that nobody confined can take. Only gate.resolve's scan finds it (main: the scan ran only
-- while NO linked lever was known -> GATE_FAIL 'its levers lie outside the alert burrow Tiefe+')
local function extra_lever(W, name, x, y, z, id)
  local lv = W.add_building{id = id, _kind = 'trap', trap_type = df.trap_type.Lever, x1 = x, y1 = y, x2 = x, y2 = y, z = z,
                            centerx = x, centery = y, state = 0, bridge = name}
  lv.jobs = kmock.vec{}
  local target = W.bridges[name]
  lv.linked_mechanisms = kmock.vec{{_ref = {getBuilding = function() return target end}}}
  W.levers[#W.levers + 1] = lv
  df.global.world.buildings.other.TRAP:insert('#', lv)
  return lv
end

T.test('BUG-478 traffic (6): the refuge lever stands beside its manifest tile (linked, not listed), Kern+ levers out of reach, ' ..
       'SIEGE with trolls and returning citizens -> found by the resolve scan, B1 up before the army, nobody crushed', function()
  local W = build{walkers = route_walkers(), lever_cfg = dead_kern()}
  extra_lever(W, 'O1', 71, 71, Z - 6, 9001)
  extra_lever(W, 'B1', 72, 71, Z - 6, 9002)
  extra_lever(W, 'B2', 73, 71, Z - 6, 9003)
  troll_raws()
  W.foes = troll_army(W)
  run(W, 1500)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  walkers_across(W)
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] + W.move_ticks <= 1150, 'B1 up before the army reaches it: ' .. (up[1] + W.move_ticks))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.ok(S.pulls(W, 'B1')[1] and S.pulls(W, 'B1')[1].lever == 9002, 'the first pull of B1 went to the refuge lever')
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
  T.eq(held_events(W), 0)
end)

-- the bug's own situation (control; proves the world bites): no refuge lever, the Kern+ levers out of reach -> B1 cannot move
T.test('BUG-478 traffic (5): control, no refuge lever and the Kern+ levers out of reach in BREACH -> the pull fails (GATE_FAIL), ' ..
       'nobody is crushed either', function()
  local W = build{mode = 'BREACH', walkers = route_walkers(), lever_cfg = dead_kern()}
  run(W, 1400)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  T.eq(#flips_to(W, 'B1', 'up'), 0, 'B1 never moved')
  T.ok(#W.find_events('GATE_FAIL') >= 1, 'GATE_FAIL')
end)

T.done()
