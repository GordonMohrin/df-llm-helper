-- BUG-774 / 775 / 776 (round 51, lever). Run 16a i1 Basementflew y544 aut d82 / win d2 (kern 87b10464): a surprise siege (cave dragon, goblins) found 35 of
-- 52 citizens outside Kern+; B1's two levers lay 5-6 tiles WEST of its footprint, outside Kern+; the pullers were 60 tiles away, B1 rose 1,650 ticks
-- late once and 'not up after 909 ticks (no worker: its levers lie outside the alert burrow Kern+)' the next time -> BREACH, pop 52 -> 7. Four citizens
-- stood beside B1 for 506-569 ticks while the dragon came from 22 tiles out and were killed at the bridge once it rose.
--   BUG-774 gate.lever_outside + gate's own lever inside Kern+ (act.lever_build, runner.add_levers), readiness R0 `lever_outside` + the question
--   BUG-775 a hostile within approach_now (20) tiles ends the hold of a raise for citizens beside the footprint at once
--   BUG-776 max-pop held while R0 fails on refuge_dry / audit_fail / lever_outside and a quarter of the fort works outside Kern+
-- Siege traffic (the real sense / threat / siege / gate / reflex on one k_mock world, invaders visible, walkers that walk, a raised bridge cannot be
-- walked, a unit on a moving bridge is crushed): the y544 replay with the lever built in PEACE, citizens at the bridge, a hostile 18 tiles out.
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')
local Z = S.Z
local kv = kmock.vec

local ROOM = {54, 33, Z, 56, 34, Z}       -- outside Kern+ (y 41..95): O1 levers (55,33),(56,33), B1 levers (54,34),(55,34)
local FPY = {O1 = 10, B1 = 40, B2 = 60}
local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end
local function in_kern(x, y) return x >= 40 and x <= 80 and y >= 41 and y <= 95 end
local function in_box(p, b) return p.x >= b[1] and p.x <= b[4] and p.y >= b[2] and p.y <= b[5] and p.z >= b[3] and p.z <= b[6] end

local function manifest(outside)
  local m = S.manifest()
  m.burrows['dfllm-levers'] = {role = 'other'}
  if outside then
    m.bridges.O1.levers = {{55, 33, Z}, {56, 33, Z}}
    m.bridges.B1.levers = {{54, 34, Z}, {55, 34, Z}}
  end
  return m
end

local function built(b, on)
  b.getBuildStage = function() return on and 1 or 0 end
  b.getMaxBuildStage = function() return 1 end
end

-- a fake runner: runner.add_levers is the real function (it writes the manifest through K.persist)
local function fake_runner()
  return {name = 'runner', every = {ticks = 100000}, add_levers = runner.add_levers}
end

-- act fakes: lever_build puts a BUILT lever on the tile (unlinked, as a quickfort lever after its mechanism), link_lever links it
local function act_fakes(W, o)
  W.built_at = {}
  W.act_result('lever_build', function(pos)
    if o and o.refuse then return false, 'quickfort designated no lever there' end
    if o and o.nobuild then return true, 1 end          -- designated, waits for its mechanism
    local lv = W.add_building{id = 700 + #W.levers, _kind = 'trap', trap_type = df.trap_type.Lever, x1 = pos[1], y1 = pos[2], x2 = pos[1],
                              y2 = pos[2], z = pos[3], centerx = pos[1], centery = pos[2], state = 0}
    lv.jobs = kv{}
    lv.linked_mechanisms = kv{}
    built(lv, true)
    W.levers[#W.levers + 1] = lv
    df.global.world.buildings.other.TRAP:insert('#', lv)
    W.built_at[#W.built_at + 1] = {pos[1], pos[2], pos[3], id = lv.id}
    return true, 1
  end)
  W.act_result('link_lever', function(lid, bid)
    local lv, b = W.buildings[lid], W.buildings[bid]
    lv.linked_mechanisms = kv{{_ref = {getBuilding = function() return b end}}}
    lv.bridge = b.name
    return true, 9000 + lid
  end)
end

local function snap_floor(chars)
  local M = {name = 'snapshot', every = {ticks = 100}}
  function M.tile(K, x, y, z) return {c = (chars or {})[x .. ',' .. y .. ',' .. z] or '.', dig = '', bld = ''} end
  function M.far() return false end
  M.outside_near = require('dfllm.snapshot').outside_near
  return M
end

local function setup(o)
  C.ACT.burrow_units = {'gate'}
  local W = S.world{units = o.units or S.fort_units(), manifest = manifest(o.outside), mode = o.mode,
                    lever_default = {worker = 150, pull = 40}, move = o.move}
  if not o.noroom then W.burrow('dfllm-levers', o.outside and ROOM or {54, 45, Z, 56, 46, Z}) end
  W.walk, W.crushed, W.t0, W.walkers = {}, {}, nil, o.walkers or {}
  W.act_result('burrow_units', function(name, ids)
    local b = dfhack.burrows.findByName(name)
    if not b then return false, 'no burrow ' .. tostring(name) end
    b.units = kmock.vec(ids)
    for _, id in ipairs(ids) do
      if not in_box(W.unit(id).pos, b._bbox) then
        local u = W.unit(id)
        local d = math.max(math.abs(u._m.x - b._bbox[1]), math.abs(u._m.y - b._bbox[2]))
        W.walk[id] = {tick = S.abs_now() + 24 * d, to = {b._bbox[1], b._bbox[2], b._bbox[3]}}
      end
    end
    return true, #ids
  end)
  W.lever_cfg = setmetatable({}, {__index = function(_, id)       -- a lever of the room is taken only by a puller standing in it
    local lv = W.buildings[id]
    local b = dfhack.burrows.findByName('dfllm-levers')
    if b and lv and in_box({x = lv.x1, y = lv.y1, z = lv.z}, b._bbox) then
      for _, uid in ipairs(b.units or {}) do
        local u = W.unit(uid)
        if u and in_box(u.pos, b._bbox) then return nil end
      end
      return {}
    end
    return nil
  end})
  act_fakes(W, o)
  W.mil = S.military()
  W.snap = snap_floor(o.chars)
  df.global.world.status.popups = kmock.vec{}
  package.loaded['dfllm.reflex'] = nil
  S.load(W, {W.mil, W.snap, fake_runner(), require('dfllm.reflex')})
  df.job_type.LinkBuildingToTrigger = 146
  for _, b in pairs(W.bridges) do built(b, true) end
  for _, lv in ipairs(W.levers) do built(lv, true) end
  return W
end

local function hook(W, t)
  local now = S.abs_now()
  for id, w in pairs(W.walk) do
    if now >= w.tick then W.move(id, w.to[1], w.to[2], w.to[3]); W.walk[id] = nil end
  end
  W.t0 = W.t0 or now
  local step = (now - W.t0) // 27
  for _, w in ipairs(W.walkers) do
    if not w.dead and (w.done or 0) < step and w.i < #w.route and now >= (w.start or 0) then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, nx[1], nx[2], Z)
      end
      w.done = step
    end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = string.format('%d on %s at +%d', w.id, name, now - W.t0)
        end
      end
    end
  end
end

local function run(W, ticks, extra)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, hook} end
  for _, a in ipairs(extra or {}) do at[#at + 1] = a end
  S.run(W, ticks, {at = at})
end

local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
local function outside(W)
  local ok, r = W.K.call('gate', 'lever_outside')
  assert(ok, tostring(r))
  return r
end
local function names(t)
  local r = {}
  for k in pairs(t) do r[#r + 1] = k end
  table.sort(r)
  return r
end

---------------------------------------------------------------- runner.add_levers
T.test('BUG-774: runner.add_levers lists the tiles on an existing bridge (no duplicates, footprint and role untouched), refuses an unknown one', function()
  local W = S.world{units = S.fort_units()}
  local K = W.K
  local before = K.manifest().bridges.B1
  local fp = table.concat(before.fp, ',')
  local ok, n = runner.add_levers(K, 'B1', {{44, 47, Z}, {54, 46, Z}})
  T.eq({ok, n}, {1, nil}, 'the old lever 54,46 is not added twice')
  local b = K.manifest().bridges.B1
  T.eq(b.levers, {{54, 46, Z}, {55, 46, Z}, {44, 47, Z}}, T.show(b.levers))
  T.eq({table.concat(b.fp, ','), b.role}, {fp, 'inner'})
  T.eq({runner.add_levers(K, 'B1', {{44, 47, Z}})}, {0}, 'again: nothing')
  T.eq({runner.add_levers(K, 'B9', {{1, 2, Z}})}, {false, 'no bridge B9'})
end)

---------------------------------------------------------------- gate.lever_outside
T.test('BUG-774: gate.lever_outside names the bridges whose linked levers ALL lie outside Kern+ and the refuge (a lever inside, even one of two, ' ..
       'clears it)', function()
  local W = setup{outside = true, mode = 'PEACE'}
  run(W, 300)
  local lo = outside(W)
  T.eq(names(lo), {'B1', 'O1'}, T.show(lo))
  T.eq({lo.B1.n, lo.B1.at}, {2, {54, 34, Z}})
  local W2 = setup{outside = false, mode = 'PEACE'}
  run(W2, 300)
  T.eq(names(outside(W2)), {}, 'levers in Kern+: none (control)')
  local m = manifest(true)
  m.bridges.B1.levers = {{54, 34, Z}, {55, 46, Z}}              -- one outside, one inside
  local W3 = S.world{units = S.fort_units(), manifest = m}
  S.load(W3, {S.military(), snap_floor()})
  for _, b in pairs(W3.bridges) do built(b, true) end
  for _, lv in ipairs(W3.levers) do built(lv, true) end
  S.run(W3, 300, {})
  T.ok(outside(W3).B1 == nil, 'B1 has a lever in Kern+: not listed ' .. T.show(outside(W3)))
end)

---------------------------------------------------------------- gate.home_step
T.test('BUG-774: PEACE, levers outside: gate designates ONE lever per bridge on a free Kern+ floor tile 4..20 tiles from the footprint, lists it in ' ..
       'the manifest, links it once it stands; the bridge leaves lever_outside; nothing is designated twice', function()
  local W = setup{outside = true, mode = 'PEACE'}
  run(W, 1500)
  local acts = S.acts(W, 'lever_build')
  T.eq(#acts, 2, 'one lever for O1 and one for B1: ' .. T.show(acts))
  for _, a in ipairs(acts) do
    local p = a.args[1]
    T.ok(in_kern(p[1], p[2]) and p[3] == Z, 'inside Kern+: ' .. T.show(p))
  end
  local man = W.K.manifest()
  for _, b in ipairs({'B1', 'O1'}) do
    local n = #man.bridges[b].levers
    T.eq(n, 3, b .. ' lists the new lever in the manifest: ' .. T.show(man.bridges[b].levers))
    local p = man.bridges[b].levers[3]
    for name, spec in pairs(man.bridges) do
      local fp = spec.fp
      local gap = math.max(fp[1] - p[1], 0, p[1] - fp[4], fp[2] - p[2], 0, p[2] - fp[5])
      T.ok(gap >= 4, b .. ' lever ' .. T.show(p) .. ' is ' .. gap .. ' tiles from ' .. name)
    end
    T.ok(in_kern(p[1], p[2]), b .. ' lever in Kern+')
  end
  T.ok(man.bridges.B1.levers[3][1] ~= man.bridges.O1.levers[3][1] or man.bridges.B1.levers[3][2] ~= man.bridges.O1.levers[3][2], 'two tiles')
  T.eq(#W.built_at, 2)
  run(W, 3000)
  T.eq(#S.acts(W, 'lever_build'), 2, 'not designated twice')
  T.ok(#S.acts(W, 'link_lever') >= 2, 'gate links the new levers: ' .. #S.acts(W, 'link_lever'))
  T.eq(names(outside(W)), {}, 'both bridges have a linked lever in Kern+ now: ' .. T.show(outside(W)))
  T.ok(logged(W, 'a lever designated inside Kern+'), 'kern.log says it')
end)

T.test('BUG-774: no free floor tile in Kern+ near the bridge -> nothing is designated, cause no_tile, one warning; a refused quickfort -> refused', function()
  local chars = {}
  for x = 30, 75 do for y = 20, 70 do chars[x .. ',' .. y .. ',' .. Z] = '#' end end
  local W = setup{outside = true, mode = 'PEACE', chars = chars}
  run(W, 1500)
  T.eq(#S.acts(W, 'lever_build'), 0)
  local ok, h = W.K.call('gate', 'lever_home')
  T.ok(ok and h.B1 and h.B1.cause == 'no_tile', T.show(h))
  T.ok(logged(W, 'all its levers lie outside Kern+'), 'warned')
  local W2 = setup{outside = true, mode = 'PEACE', refuse = true}
  run(W2, 1500)
  local _, h2 = W2.K.call('gate', 'lever_home')
  T.eq(h2.B1.cause, 'refused', T.show(h2))
  T.eq(#W2.K.manifest().bridges.B1.levers, 2, 'nothing listed for a refused tile')
end)

T.test('BUG-774: never in a fight: SIEGE with levers outside designates nothing', function()
  local W = setup{outside = true, mode = 'SIEGE'}
  run(W, 1500)
  T.eq(#S.acts(W, 'lever_build'), 0, 'SIEGE: no lever_build')
end)

---------------------------------------------------------------- BUG-775 the hold ends at approach_now
-- a citizen stands beside B1 (51,41), one tile from the footprint; the army stands PARKED d tiles north of it (never closes)
local function hold_world(d)
  local units = S.fort_units()
  units[#units + 1] = S.cit(7, 51, 41)
  for _, u in ipairs(S.army(3, 50, 40 - d, 300)) do units[#units + 1] = u end
  local W = setup{outside = false, mode = 'PEACE', units = units, noroom = true}
  W.event('INVASION', {id = 301})
  return W
end
T.test('BUG-775: a hostile 18 tiles from B1 (parked, not closing) and a citizen beside it: B1 rises with the pull (no hold), GATE_FORCED says ' ..
       'approach_now; at 25 tiles he still holds it', function()
  local W = hold_world(18)
  run(W, 900)
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 is up (old: held for the citizen until the army closed or 300 ticks and 12 tiles)')
  local f = S.flips(W, 'B1')[1]
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') or S.mode_tick(W, 'ALERT>SIEGE') or 0
    T.ok(f and f.tick - t0 < 600, 'B1 rose at +' .. tostring(f and f.tick - t0))
  local ev = W.find_events('GATE_FORCED')
  T.ok(#ev >= 1 and ev[1].d.bridge == 'B1', 'GATE_FORCED B1')
  T.ok(ev[1].msg:find('approach_now', 1, true), ev[1].msg)
  T.eq(W.unit(7)._m.y, 41, 'the citizen stands where he stood: locked out is not crushed')
  T.eq(#W.crushed, 0)
  local W0 = hold_world(18)               -- approach_now 0 = the old rule: not closing, not within 12 tiles: the citizen holds it
  W0.K.cfg.reflex = {gate = {approach_now = 0}}
  run(W0, 900)
  T.eq(S.bstate(W0, 'B1'), 'down', 'approach_now 0: B1 waits for the citizen (the y544 hold)')
  local W2 = hold_world(25)
  run(W2, 900)
  T.eq(S.bstate(W2, 'B1'), 'down', 'a hostile 25 tiles out (parked): the hold stays, B1 waits for the citizen')
  W2.unit(7)._m.x, W2.unit(7)._m.y = 60, 70           -- he walks away
  run(W2, 600)
  T.eq(S.bstate(W2, 'B1'), 'up', 'B1 rises once he is away')
end)

T.test('BUG-775: a citizen ON the footprint still holds it with the hostile 10 tiles out; nothing is crushed', function()
  local units = S.fort_units()
  units[#units + 1] = S.cit(7, 51, 40)
  for _, u in ipairs(S.army(3, 50, 30, 300)) do units[#units + 1] = u end
  local W = setup{outside = false, mode = 'PEACE', units = units, noroom = true}
  W.event('INVASION', {id = 301})
  run(W, 600)
  T.eq(S.bstate(W, 'B1'), 'down', 'never onto a unit on the footprint')
  T.eq(#W.crushed, 0)
end)

---------------------------------------------------------------- siege traffic: the y544 replay
T.test('BUG-774/775 siege traffic (y544 replay): levers outside Kern+, PEACE builds the Kern+ lever, then a surprise siege: 24 civilians far outside, ' ..
       'three citizens at B1, a hostile 18 tiles out: the recall works, B1 and O1 rise before T+900, nobody is crushed, the citizens at the bridge ' ..
       'are locked out (not breached)', function()
  local units, walkers = S.fort_units(), {}
  for k = 0, 23 do
    local id = 300 + k
    local x, y = 82 + (k % 8), 50 + 3 * (k // 8)
    units[#units + 1] = S.cit(id, x, y)
    local route = {}
    for xx = x, 70, -1 do route[#route + 1] = {xx, y} end
    walkers[#walkers + 1] = {id = id, route = route, i = 1, start = math.huge}       -- they start to walk with the siege
  end
  units[#units + 1] = S.cit(8, 50, 41)
  units[#units + 1] = S.cit(9, 52, 41)
  units[#units + 1] = S.cit(10, 51, 39)
  local W = setup{outside = true, mode = 'PEACE', units = units, walkers = walkers, move = 100}
  run(W, 3600)                                     -- PEACE: gate designates, the lever is built, gate links it
  T.eq(names(outside(W)), {}, 'both bridges have a linked lever inside Kern+ before the siege: ' .. T.show(outside(W)))
  for _, a in ipairs(W.find_acts('lever_build')) do T.ok(in_kern(a.args[1][1], a.args[1][2]), 'inside Kern+') end
  -- the surprise siege: an army 18 tiles from B1 (north of it, on the attack side), the civilians come in
  for i, u in ipairs(S.army(6, 50, 22, 400)) do W.add_unit(u) end
  local base = S.abs_now()
  for _, w in ipairs(W.walkers) do w.start = base end
  W.t0 = base
  W.crushed = {}
  W.event('INVASION', {id = 401})
  run(W, 1800)
  T.ok(W.K.mode() == 'SIEGE', 'a SIEGE: ' .. W.K.mode())
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') or S.mode_tick(W, 'ALERT>SIEGE') or base
  for _, b in ipairs({'O1', 'B1'}) do
    T.eq(S.bstate(W, b), 'up', b .. ' is up')
    local ups = {}
    for _, f in ipairs(S.flips(W, b)) do if f.to == 'up' and f.tick >= base then ups[#ups + 1] = f.tick end end
    T.ok(ups[1] and ups[1] - t0 < 900, b .. ' rose before T+900: +' .. tostring(ups[1] and (ups[1] - t0)))
  end
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0, 'no GATE_FAIL / BREACH')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, w in ipairs(walkers) do
    local u = W.unit(w.id)
    T.ok(in_kern(u._m.x, u._m.y), 'civilian ' .. w.id .. ' is inside Kern+ (at ' .. u._m.x .. ',' .. u._m.y .. ')')
  end
  -- the lever that was pulled lies inside Kern+ (the Kern+ one comes first), not at the outside tiles
  local pulled = {}
  for _, a in ipairs(W.find_acts('burrow_units')) do
    if a.args[1] == 'dfllm-levers' then T.eq(#a.args[2], 0, 'nobody is sent to the outside lever room: ' .. T.show(a.args)) end
  end
  for _, a in ipairs(W.find_acts('alert_burrows')) do
    for _, n in ipairs(a.args[1] or {}) do T.ok(n ~= 'dfllm-levers', 'the outside lever room is not in the civ alert') end
  end
  T.eq({W.unit(8)._m.x, W.unit(8)._m.y, W.unit(9)._m.y, W.unit(10)._m.y}, {50, 41, 41, 39}, 'the citizens at B1 stand where they stood')
  for _, a in ipairs(S.pulls(W)) do pulled[#pulled + 1] = W.buildings[a.lever] end
  T.ok(#pulled >= 2, 'pulls: ' .. #pulled)
  for _, lv in ipairs(pulled) do T.ok(in_kern(lv.x1, lv.y1), 'the pulled lever ' .. lv.id .. ' lies in Kern+ at ' .. lv.x1 .. ',' .. lv.y1) end
end)

T.test('BUG-774 control (the old y544): the same siege with the lever outside only (quickfort refused every tile): B1 is not up at T+900, nobody ' ..
       'is sent to pull', function()
  local units = S.fort_units()
  for _, u in ipairs(S.army(6, 50, 22, 400)) do units[#units + 1] = u end
  local W = setup{outside = true, mode = 'PEACE', units = units, refuse = true}
  W.event('INVASION', {id = 401})
  run(W, 1500)
  local ups = {}
  for _, f in ipairs(S.flips(W, 'B1')) do if f.to == 'up' then ups[#ups + 1] = f.tick end end
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') or 0
  T.ok(not ups[1] or ups[1] - t0 >= 900, 'B1 rose at +' .. tostring(ups[1] and ups[1] - t0))
  T.eq(names(outside(W)), {'B1', 'O1'}, 'both still listed')
end)

---------------------------------------------------------------- readiness: R0 flag, question, max-pop hold
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

local function rworld(o)
  local units = X.citizens(50, 1, {skills = SKILLS})
  for i = 1, o.out or 0 do units[i] = X.cit(i, {skills = SKILLS, pos = {90, 70 + i % 10, Z}}) end        -- x 90: outside Kern+ (x <= 80)
  local W = X.world{units = units, persist = {}, manifest = o.manifest}
  W.K.cfg.decisions['D-01'] = 'A'
  local sf = {name = 'seal', every = {ticks = 600}, x = {tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}}
  function sf.entrance_doors(K) return sf.x end
  sf.rd = {name = 'Tiefe+', exists = true, drink = o.drink or 80, need = 50, wells = 0, wet = false}
  function sf.refuge_drink(K) return sf.rd end
  local rn = X.runner('P5')
  function rn.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  rn.pending = function(K, tpl) return 0 end
  rn.add_levers = runner.add_levers
  W.snap, W.sf = snap_floor(), sf
  W.snap.export = X.snapshot().export
  X.load(W, {'military', 'readiness'}, {X.economy(), W.snap, rn, sf}, {'sense', 'gate'})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  X.mod('readiness').OPEN_CONFIRM, X.mod('readiness').DEF.worn_pct = 0, 0
  act_fakes(W, o)
  df.job_type.LinkBuildingToTrigger = 146
  for _, b in pairs(W.bridges) do built(b, true) end
  for _, lv in ipairs(W.levers) do built(lv, true) end
  return W
end
local function ready(W)
  local st = W.state()
  return type(st) == 'table' and type(st.ready) == 'table' and st.ready or {}
end
local function questions(W)
  local q = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'lever_outside' then q[#q + 1] = e end end
  return q
end
local function has(list, x)
  for _, v in ipairs(list or {}) do if v == x then return true end end
  return false
end
local function last_cap(W)
  local a = S.acts(W, 'popcap')
  return a[#a] and a[#a].args[1]
end

T.test('BUG-774: levers outside Kern+ -> R0 `lever_outside`, ready.lo names the bridges, one DECISION_NEEDED lever_outside (cause designated: gate ' ..
       'builds its own); none for levers inside', function()
  local W = rworld{manifest = manifest(true), nobuild = true}
  day(W, 6)
  local rd = ready(W)
  T.ok(has(rd.fail, 'lever_outside'), 'R0 blocker: ' .. T.show(rd.fail))
  T.eq(rd.lo, {'B1', 'O1'}, T.show(rd))
  local q = questions(W)
  T.eq(#q, 1, 'asked once')
  T.eq(q[1].cls, 'A')
  T.eq(q[1].d.cause, 'designated')
  T.ok(q[1].d.q:find('lie outside Kern+', 1, true) and q[1].d.q:find('designated', 1, true), q[1].d.q)
  day(W, 20)
  T.eq(#questions(W), 1, 'not again within ask_days')
  local W2 = rworld{manifest = manifest(false)}
  day(W2, 6)
  T.ok(not has(ready(W2).fail, 'lever_outside') and ready(W2).lo == nil, 'inside: no blocker ' .. T.show(ready(W2)))
  T.eq(#questions(W2), 0)
end)

T.test('BUG-776: R0 on refuge_dry and 15 of 50 citizens outside Kern+: max-pop is held at 50 and does not rise with the fort; fewer than a quarter ' ..
       'outside, or no deadly blocker: no hold; the hold ends with the blocker', function()
  local W = rworld{drink = 0, out = 15}
  day(W, 4)
  T.ok(has(ready(W).fail, 'refuge_dry'), T.show(ready(W).fail))
  T.eq(last_cap(W), 50, 'max-pop held at the population (R0 cap 55): ' .. tostring(last_cap(W)))
  T.eq(ready(W).uh, 50)
  T.ok(logged(W, 'max-pop held at 50'), 'kern.log says why')
  for i = 1, 8 do X.add(W, X.cit(900 + i, {skills = SKILLS})) end
  day(W, 3)
  T.eq(last_cap(W), 50, 'still 50 with 58 citizens')
  W.sf.rd.drink = 80                                -- the refuge is stocked: the blocker is gone
  day(W, 4)
  T.eq(ready(W).uh, nil, 'released')
  T.ok((last_cap(W) or 0) > 50, 'max-pop rises again: ' .. tostring(last_cap(W)))
  local W2 = rworld{drink = 0, out = 4}
  day(W2, 4)
  T.eq(ready(W2).uh, nil, 'only 4 outside: no hold')
  T.eq(last_cap(W2), 55)
  local W3 = rworld{drink = 80, out = 15}
  day(W3, 4)
  T.eq(ready(W3).uh, nil, 'refuge stocked, the levers inside: no deadly blocker, no hold')
  T.eq(last_cap(W3), 55)
end)

T.test('BUG-776: the lever_outside blocker holds max-pop too', function()
  local W = rworld{manifest = manifest(true), out = 15, nobuild = true}
  day(W, 4)
  T.ok(has(ready(W).fail, 'lever_outside'))
  T.eq(last_cap(W), 50, 'held: ' .. tostring(last_cap(W)))
end)

T.done()
