-- Neuausrichtung 2 (BUG-831/832/833, Run 17d i4 Girderroots y374: the kernel's own quiet PEACE raise of B1 crushed three citizens).
-- PEACE traffic test: a citizen starts for the footprint right after the lever was pulled and the bridge moves ~300 ticks (i4: 536
-- ticks queue-to-up). On main B1 rose at once and he was crushed; now the raise waits for a quiet footprint, a risk locks the bridge
-- down in PEACE, the player's `lever` down takes `days`, and the SIEGE TRAFFIC test still holds. (helpers as in test_neu1_tore.lua)
KMOCK_LEGACY_15B = true   -- Neuausrichtung 15b: written for the gate of main; the safety switches gate.reach / player_lever / station_clear are ON when absent, this test sets them off (k_mock)
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- footprints x 50..52 at these rows; Kern+ is y >= 41
local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end
local function in_kern(x, y) return x >= 40 and x <= 80 and y >= 41 and y <= 95 end

-- a fake seal answering refuge_drink('kern') (the audit of Kern+), nil = no answer (unknown)
local function seal_fake(drink)
  local M = {name = 'seal', every = {ticks = 100000}}
  function M.refuge_drink(K, which) return drink end
  return M
end

local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

-- the fixture soldier (unit 5, squad 1) stands at fortcore's melee station 4 tiles inside B1; since the BUG-831 retry a soldier at his
-- station counts like anybody else near the footprint, so by default he stands far inside Kern+ (o.at_station keeps him at the station)
local function fort_units(at_station)
  local units = S.fort_units()
  if not at_station then for _, u in ipairs(units) do if u.id == 5 then u.pos = {60, 85, Z} end end end
  return units
end

-- o.units, o.walkers ({id, route, start, kind}), o.cfg, o.seal (refuge_drink answer, false = no seal module), o.manifest, o.reflex
local function world(o)
  o = o or {}
  local units = o.units or fort_units(o.at_station)
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local u = S.cit(w.id, w.route[1][1], w.route[1][2], Z, w.kind == 'soldier' and {squad = 1} or nil)
    units[#units + 1] = u
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = S.world{station = true, units = units, mode = o.mode, move = 100, lever_default = {worker = 30, pull = 40}, manifest = o.manifest,
                    cfg = o.cfg}
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  local extra = {S.military()}
  if o.seal ~= false then extra[#extra + 1] = seal_fake(o.seal or {exists = true, drink = 40, wells = 0, wet = false}) end
  if o.reflex then
    df.global.world.status.popups = kmock.vec{}
    package.loaded['dfllm.reflex'] = nil
    extra[#extra + 1] = require('dfllm.reflex')
  end
  S.load(W, extra)
  return W
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route and rel >= (w.next or 0) then
      local nx = w.route[w.i + 1]
      local blocked = false
      -- a raised bridge: no way. DF gives a unit with no path no walk toward it: he idles where he is, so the walker stops 4
      -- tiles before a raised (or moving) footprint instead of queueing beside it
      for k = w.i + 1, math.min(#w.route, w.i + 4) do
        local q = w.route[k]
        for name in pairs(FPY) do
          local bs = S.bstate(W, name)
          -- BUG-831: DF's pathing still treats a bridge that is being raised as passable until it is up (w.through): he walks on
          if on_fp(name, q[1], q[2]) and bs ~= 'down' and not (w.through and bs == 'moving') then blocked = true end
        end
      end
      w.blocked = blocked
      if not blocked then
        w.i, w.next = w.i + 1, rel + 18                  -- a tile every 18 ticks
        W.move(w.id, nx[1], nx[2], Z)
      end
    end
    if not w.dead then                                   -- the walk path DF shows: the next 25 route tiles (none while no way)
      local xs, ys, zs = {}, {}, {}
      if rel >= w.start and not w.blocked then
        for k = w.i + 1, math.min(#w.route, w.i + 25) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z end
      end
      W.unit(w.id).path = #xs > 0 and {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}} or nil
    end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = string.format('%d on %s at +%d', w.id, name, rel)
        end
      end
    end
  end
end

local function run(W, ticks, at)
  local list = {}
  for t = 0, ticks, 9 do list[#list + 1] = {t, step} end
  for _, a in ipairs(at or {}) do list[#list + 1] = a end
  S.run(W, ticks, {at = list})
end

local function gate_ev(W, state)
  local r = {}
  for _, e in ipairs(W.find_events('GATE')) do if e.d.state == state then r[#r + 1] = e end end
  return r
end
local function ups_after(W, b, t0)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == 'up' and f.tick >= t0 then r[#r + 1] = f.tick - t0 end end
  return r
end
local function want_of(W, b)
  local ok, st = W.K.call('gate', 'state', b)
  return st
end
local function remove_army(W, ids)
  for _, id in ipairs(ids) do W.kill(id) end
end


-- like world() but with the i4 lever timing: a worker takes the pull after 60 ticks and pulls 175 ticks later, the bridge moves 300 ticks
local function slow_world(o)
  o = o or {}
  local units = fort_units(o.at_station)
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    units[#units + 1] = S.cit(w.id, w.route[1][1], w.route[1][2], Z)
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or math.huge, i = 1, when_moving = w.when_moving, jump = w.jump, through = w.through}
  end
  local W = S.world{station = true, units = units, move = 300, lever_default = {worker = 60, pull = 175}, cfg = o.cfg}
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  S.load(W, {S.military(), seal_fake({exists = true, drink = 40, wells = 0, wet = false})})
  return W
end

-- units that stay as they are (the soldier at his station) and step onto the footprint when o.jump_at ticks after the lever
local function soldier_jump(W, t)
  W.sj = W.sj or {}
  if S.bstate(W, 'B1') == 'moving' and not W.sj.jumped then
    W.sj.jumped = true
    W.sj.crush = W.sj.crush or {}
    W.move(5, 51, 40, Z)                                  -- the stationed soldier steps onto the moving footprint
  end
  if W.sj.jumped and not W.sj.back and S.bstate(W, 'B1') ~= 'moving' then
    W.sj.back = true
  end
  if S.bstate(W, 'B1') == 'moving' and W.sj.jumped then
    local u = W.unit(5)
    if on_fp('B1', u._m.x, u._m.y) then W.crushed[#W.crushed + 1] = 'soldier 5 on B1' end
  end
end

-- walkers with when_moving start walking the moment B1 moves (the lever is pulled: nothing can cancel it any more)
local function go_when_moving(W, t)
  for _, w in ipairs(W.walkers) do
    if w.jumped and not w.back and S.bstate(W, 'B1') ~= 'moving' then w.back = true; W.move(w.id, 51, 70, Z) end   -- (he is flung off)
    if S.bstate(W, 'B1') == 'moving' then
      if w.when_moving and w.start == math.huge then w.start = (t - (W.t0 or t)) end
      if w.jump and not w.jumped then w.jumped = true; W.move(w.id, w.jump[1], w.jump[2], Z) end    -- steps onto the moving bridge
    end
  end
end
local function run2(W, ticks)
  local list = {}
  for t = 0, ticks, 9 do list[#list + 1] = {t, function(W2, now) go_when_moving(W2, now); step(W2, now) end} end
  S.run(W, ticks, {at = list})
end

T.test('PEACE TRAFFIC (BUG-831): a citizen 15 tiles from B1 who starts walking onto it once the lever is pulled: B1 is NOT raised ' ..
       '(a unit within gate.peace_clear_r tiles), nobody crushed, GATE peace_wait names him', function()
  local W = slow_world{walkers = {{id = 60, route = route(51, 55, 39), when_moving = true, through = true}}}
  run2(W, 3000)
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(S.bstate(W, 'B1'), 'down', 'not raised while he stands 15 tiles away')
  T.eq(#S.pulls(W, 'B1'), 0, 'no pull queued')
  local ev = gate_ev(W, 'peace_wait')
  T.ok(#ev >= 1 and ev[1].d.unit == 60, ev[1] and ev[1].msg)
  T.eq(#W.find_events('GATE_FAIL'), 0)
  T.eq(#W.find_events('GATE_CRUSH_RISK'), 0)
end)

T.test('PEACE TRAFFIC: a quiet fort gets B1 up only after the whole quiet window; a walker coming near cancels the pending pull', function()
  local W = slow_world{walkers = {{id = 61, route = route(51, 90, 90), start = math.huge}}}
  run2(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'up', 'raised in a quiet fort')
  local f = S.flips(W, 'B1')
  T.ok(f[1] and f[1].tick - W.t_start >= 600, 'not before the quiet window: +' .. tostring(f[1] and f[1].tick - W.t_start))
  T.eq(#W.crushed, 0)
  -- the quiet window has passed, the pull waits for its worker (235 ticks): a citizen walks up the core
  local W2 = slow_world{walkers = {{id = 62, route = route(51, 80, 45), start = math.huge}}}
  run2(W2, 700)
  W2.walkers[1].start = 0
  run2(W2, 2400)
  T.eq(#W2.crushed, 0, 'crushed: ' .. table.concat(W2.crushed, '; '))
  T.eq(#W2.find_events('GATE_CRUSH_RISK'), 0)
end)

T.test('PEACE TRAFFIC (BUG-831): a risk of the kernel raise (a unit on the footprint while it moves) keeps B1 down in PEACE ' ..
       '(peace_traffic); peace_lock_days 0 does not', function()
  -- a tiny radius lets the raise through; the citizen then steps onto the footprint while it moves
  local cfg = {reflex = {v = 2, gate = {peace_clear_r = 2, peace_clear = 0}}}
  local W = slow_world{cfg = cfg, walkers = {{id = 60, route = route(51, 55, 55), jump = {51, 40}}}}
  run2(W, 1800)
  T.ok(#W.find_events('GATE_CRUSH_RISK') >= 1, 'the risk event')
  local ev = gate_ev(W, 'peace_traffic')
  T.ok(#ev >= 1 and ev[1].d.days == 3, ev[1] and ev[1].msg)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run2(W, 1500)
  T.eq(S.bstate(W, 'B1'), 'down', 'the caravan window lowers it')
  run2(W, 1200)
  T.eq(S.bstate(W, 'B1'), 'down', 'locked down in PEACE (3 days = 3600 ticks)')
  run2(W, 12000)
  T.eq(S.bstate(W, 'B1'), 'up', 'the lock ends after peace_lock_days')
  local W0 = slow_world{cfg = {reflex = {v = 2, gate = {peace_clear_r = 2, peace_clear = 0, peace_lock_days = 0}}},
                        walkers = {{id = 60, route = route(51, 55, 55), jump = {51, 40}}}}
  run2(W0, 1800)
  T.eq(#gate_ev(W0, 'peace_traffic'), 0, 'no lock with peace_lock_days 0')
end)

T.test('gate.peace_raise false: B1 is never raised in PEACE (the pre-NEU1 D-14 down)', function()
  local W = slow_world{cfg = {reflex = {v = 2, gate = {peace_raise = false}}}}
  run2(W, 4000)
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(#S.pulls(W, 'B1'), 0)
end)

T.test('lever days (BUG-833): lever down with days=N holds B1 down N game days; bad values are refused', function()
  local W = slow_world{}
  run2(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'up')
  local verbs = require('dfllm.gate').verbs
  local K = W.K
  local r1, m1 = verbs.lever(K, {bridge = 'B1', want = 'down', days = 0}, {by = 't'})
  T.eq(r1, false, m1)
  T.eq((verbs.lever(K, {bridge = 'B1', want = 'down', days = 121}, {by = 't'})), false)
  T.eq((verbs.lever(K, {bridge = 'B1', want = 'up', days = 3}, {by = 't'})), false)
  local r4, m4 = verbs.lever(K, {bridge = 'B1', want = 'down', days = 10}, {by = 't'})
  T.eq(r4, true, m4)
  T.ok(m4:find('held down 10 days', 1, true), m4)
  run2(W, 6000)
  T.eq(S.bstate(W, 'B1'), 'down')
  run2(W, 6000)
  T.eq(S.bstate(W, 'B1'), 'down', 'held beyond the default 3 days (12,000 ticks = 10 days)')
  run2(W, 9000)
  T.eq(S.bstate(W, 'B1'), 'up', 'raised again after the hold, in the quiet')
end)

T.test('PEACE TRAFFIC (BUG-831 retry, i4 #1441): a soldier at his station 4 tiles from B1 (squad station order) is NOT exempt: ' ..
       'B1 is never pulled in PEACE, so he is not crushed when he steps onto the footprint; GATE names him', function()
  local W = slow_world{at_station = true}
  W.crushed, W.walkers = {}, {}
  local list = {}
  for t = 0, 4000, 9 do list[#list + 1] = {t, soldier_jump} end
  S.run(W, 4000, {at = list})
  T.eq(S.bstate(W, 'B1'), 'down', 'stays down with a soldier at the station')
  T.eq(#S.pulls(W, 'B1'), 0, 'no pull queued')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  local ev = gate_ev(W, 'peace_wait')
  T.ok(#ev >= 1 and ev[1].d.unit == 5, ev[1] and ev[1].msg)
end)

T.test('PEACE TRAFFIC fail closed: while the census is unknown the quiet raise waits', function()
  local W = slow_world{}
  local g = require('dfllm.gate')
  local hit = g.peace_busy(W.K, 'B1', {}, nil, 0, nil)
  T.ok(hit ~= nil and hit.k == 'unknown', 'peace_busy without a census reports a blocker')
end)

---------------------------------------------------------------- SIEGE TRAFFIC (fix_common.md)
T.test('SIEGE TRAFFIC with the PEACE quiet raise: attackers arrive with civilians outside; O1 and B1 up and held, nobody crushed; ' ..
       'the shut-out get in again afterwards (not walled out of drink)', function()
  local walkers = {}
  for k = 0, 2 do walkers[#walkers + 1] = {id = 70 + k, route = route(50 + k, 2, 70), start = math.huge} end
  for k = 0, 2 do walkers[#walkers + 1] = {id = 80 + k, route = route(50 + k, 15, 70), start = math.huge} end
  local W = world{walkers = walkers}
  run(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up in the quiet PEACE')
  for _, w in ipairs(W.walkers) do w.start = 0 end
  local ids = {}
  for _, u in ipairs(S.army(6, 20, 0, 500)) do W.add_unit(u); ids[#ids + 1] = u.id end
  W.event('INVASION', {id = 501})
  run(W, 1500)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq(S.bstate(W, 'O1'), 'up')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
  remove_army(W, ids)
  run(W, 14400)
  T.eq(W.K.mode(), 'PEACE')
  for _, w in ipairs(W.walkers) do
    local u = W.unit(w.id)
    T.ok(in_kern(u._m.x, u._m.y), 'citizen ' .. w.id .. ' is inside Kern+ with the drink')
  end
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
end)

T.test('SIEGE raise ignores the PEACE quiet rule: a citizen standing 20 tiles from B1 does not keep it down once a hostile is in sight', function()
  local W = slow_world{walkers = {{id = 64, route = route(51, 60, 60), start = math.huge}}}
  run2(W, 900)
  T.eq(S.bstate(W, 'B1'), 'down', 'a citizen 20 tiles away: the PEACE raise waits')
  for _, u in ipairs(S.army(4, 20, 0, 800)) do W.add_unit(u) end
  W.event('INVASION', {id = 801})
  run2(W, 1800)
  T.eq(S.bstate(W, 'B1'), 'up', 'the siege raised it')
  T.eq(#W.crushed, 0)
end)

T.done()
