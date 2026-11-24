-- NEU1 P5 Tore (decision E2, docs/v2/NEU1-tore.md): D-14 inner (the inner gate up in PEACE, the outer one down for trade), its
-- windows (caravan, return), the drink rule, fail closed, close at once - and the SIEGE TRAFFIC test fix_common.md asks for: the real
-- sense / threat / siege / gate (+ reflex) on one k_mock world (tests/lua/siege_world.lua), walkers that walk, a raised bridge cannot
-- be walked, a unit on a moving bridge is crushed; attackers arrive while civilians are outside, the bridges go up and stay up,
-- nobody is crushed, those shut out are let in once it is quiet (not walled out of drink for good), the caravan and the recall cases.
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

-- o.units, o.walkers ({id, route, start, kind}), o.cfg, o.seal (refuge_drink answer, false = no seal module), o.manifest, o.reflex
local function world(o)
  o = o or {}
  local units = o.units or S.fort_units()
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
          if on_fp(name, q[1], q[2]) and S.bstate(W, name) ~= 'down' then blocked = true end
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

---------------------------------------------------------------- PEACE
T.test('D-14 inner (the default): in PEACE B1 rises, O1 and B2 stay down; nobody crushed', function()
  T.eq(require('dfllm.util.contract').DECISIONS['D-14'], 'inner', 'the shipped default')
  local W = world{}
  run(W, 2400)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'down', 'up', 'down'})
  T.eq(#W.crushed, 0)
end)

T.test('D-14 down (legacy switch): in PEACE every gate stays down', function()
  local W = world{cfg = S.legacy()}
  run(W, 2400)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'down', 'down', 'down'})
end)

T.test('drink_inside: Kern+ KNOWN dry keeps B1 down in PEACE (kern.log says why); an unknown audit keeps it up (fail closed)', function()
  local W = world{seal = {exists = true, drink = 0, wells = 1, wet = false}}
  run(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'down', 'dry Kern+: B1 not raised')
  local hit = false
  for _, l in ipairs(W.logs) do if l.msg:find('B1 stays down in PEACE: Kern+ holds no drink', 1, true) then hit = true end end
  T.ok(hit, 'kern.log names the dry Kern+')
  local W2 = world{seal = false}
  run(W2, 2400)
  T.eq(S.bstate(W2, 'B1'), 'up', 'no audit: up')
  local W3 = world{seal = {exists = true, drink = 0, wells = 1, wet = false},
                   cfg = {reflex = {v = 2, gate = {drink_inside = false}}}}
  run(W3, 2400)
  T.eq(S.bstate(W3, 'B1'), 'up', 'drink_inside off: up')
end)

T.test('return window: a citizen outside the raised B1 in quiet PEACE is let in after return_every; B1 closes again', function()
  local W = world{walkers = {{id = 60, route = route(51, 10, 75), start = math.huge}}}   -- 30 tiles out: beyond gate.peace_clear_r
  run(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'up')
  W.walkers[1].start = 0                                -- he walks home now (relative to the step clock: from the start)
  run(W, 7200)
  local ev = gate_ev(W, 'return')
  T.ok(#ev >= 1, 'GATE return')
  local t_up = S.flips(W, 'B1')[1].tick
  T.ok(ev[1].tick - t_up >= 1200 - 100, 'not before return_every after B1 rose: +' .. tostring(ev[1].tick - t_up))
  T.eq(ev[1].d.n, 1)
  local u = W.unit(60)
  T.ok(in_kern(u._m.x, u._m.y), 'he is inside Kern+ (' .. u._m.x .. ',' .. u._m.y .. ')')
  T.eq(S.bstate(W, 'B1'), 'up', 'closed again')
  T.eq(#W.crushed, 0)
end)

T.test('caravan: the arrival report opens B1 (no hostile in sight); a goblin in sight closes it at once', function()
  local W = world{}
  run(W, 2400)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run(W, 600)
  T.eq(S.bstate(W, 'B1'), 'down', 'open for the caravan')
  T.eq(S.bstate(W, 'O1'), 'down')
  W.add_unit(S.inv(400, 51, 0))                          -- a goblin at the map edge, 40 tiles from B1
  local t0 = S.abs_now()
  run(W, 600)
  local up = ups_after(W, 'B1', t0)
  T.ok(#up >= 1 and up[1] < 400, 'B1 up again within the pull latency: +' .. tostring(up[1]))
  T.eq(#W.crushed, 0)
end)

---------------------------------------------------------------- fail closed
-- BUG-802 (verifier, n1-tore retry): fail closed both ways. A quiet PEACE raise of B1 whose levers all lie outside Kern+ would
-- send a puller out into the bailey and then be refused every lowering (caravan, migrants, return): a permanent seal. So it is
-- never raised; once an inside lever is linked it rises, and the windows lower and raise it normally.
T.test('fail closed (BUG-802): B1 levers all outside Kern+: NOT raised in PEACE (GATE names the lever), nobody walks out; an ' ..
       'inside lever linked: B1 rises, the caravan window lowers it and it rises again', function()
  local m = S.manifest()
  m.bridges.B1.levers = {{54, 34, Z}, {55, 34, Z}}       -- the attack side, outside Kern+ (y >= 41)
  local W = world{manifest = m}
  run(W, 1200)
  T.eq(S.bstate(W, 'B1'), 'down', 'not raised in PEACE')
  T.eq(#S.pulls(W, 'B1'), 0, 'no pull: nobody sent out to the lever')
  local ev = gate_ev(W, 'fail_closed')
  T.ok(#ev >= 1, 'GATE fail_closed')
  T.ok(ev[1] and ev[1].d.missing:find('no linked lever inside Kern+', 1, true), ev[1] and ev[1].msg)
  T.eq(ev[1] and ev[1].d.why, 'cannot_close_again')
  T.ok(ev[1] and ev[1].msg:find('B1 stays down in PEACE', 1, true), ev[1] and ev[1].msg)
  T.eq(#gate_ev(W, 'fail_closed'), 1, 'once (rate-limited), not every pass')
  for _, u in ipairs(S.fort_units()) do
    local x = W.unit(u.id)
    T.ok(in_kern(x._m.x, x._m.y), 'unit ' .. u.id .. ' still inside Kern+')
  end
  T.eq(#W.find_events('GATE_FAIL'), 0)
  local ok, miss = W.K.call('gate', 'missing', 'O1')
  T.eq(miss, nil, 'O1 has its levers inside: nothing missing')
  -- BUG-774's lever work lands: a lever inside Kern+ is built and linked, the manifest lists it
  local lv = S.add_lever(W, 'B1', {56, 46, Z}, 23)
  m.bridges.B1.levers[#m.bridges.B1.levers + 1] = {56, 46, Z}
  W.K.persist.set('manifest', m)
  local t1 = S.abs_now()
  run(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'up', 'raised once it can be closed again')
  local p = S.pulls(W, 'B1')
  T.ok(#p >= 1 and p[#p].lever == lv.id, 'pulled at the inside lever: ' .. tostring(p[#p] and p[#p].lever))
  T.eq(#ups_after(W, 'B1', t1), 1)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run(W, 900)
  T.eq(S.bstate(W, 'B1'), 'down', 'the caravan window lowers it')
  run(W, 5400)
  T.eq(S.bstate(W, 'B1'), 'up', 'up again after the caravan window')
  T.eq(#W.crushed, 0)
  T.eq(#W.find_events('GATE_FAIL'), 0)
end)

T.test('fail closed (BUG-802): a B1 the kernel raised in PEACE stays lowerable by the windows when a gap opens later (inside ' ..
       'lever gone); it is then not raised again', function()
  local W = world{}
  run(W, 2400)
  T.eq(S.bstate(W, 'B1'), 'up')
  local m = W.K.manifest()
  m.bridges.B1.levers = {{54, 34, Z}}                    -- the inside levers vanish from the list (deconstructed)
  for _, id in ipairs(S.LEVERS.B1) do W.buildings[id].linked_mechanisms = kmock.vec{} end
  S.add_lever(W, 'B1', {54, 34, Z}, 24)
  W.K.persist.set('manifest', m)
  run(W, 600)
  local ok, miss = W.K.call('gate', 'missing', 'B1')
  T.ok(miss ~= nil, 'something is missing now: ' .. tostring(miss))
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run(W, 900)
  T.eq(S.bstate(W, 'B1'), 'down', "the caravan window still lowers the kernel's own PEACE raise")
  run(W, 5400)
  T.eq(S.bstate(W, 'B1'), 'down', 'not raised again while it could not be closed again')
  local fc = gate_ev(W, 'fail_closed')
  T.ok(#fc >= 1 and fc[#fc].d.why == 'cannot_close_again', fc[#fc] and fc[#fc].msg)
end)

T.test('fail closed: no civilian inside Kern+ to pull: the window lowering is refused; fail_closed false lowers it', function()
  local units = {S.cit(1, 51, 20), S.cit(2, 52, 20), S.cit(5, 51, 44, Z, {squad = 1})}   -- the civilians outside, a soldier inside
  local W = world{units = units, cfg = {reflex = {v = 2, gate = {return_every = 0}}}}
  -- B1 is raised by hand (state), PEACE wants it up
  W.bridges.B1.gate_flags.closed = true
  run(W, 600)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run(W, 900)
  T.eq(S.bstate(W, 'B1'), 'up')
  local ev = gate_ev(W, 'fail_closed')
  T.ok(#ev >= 1 and ev[1].d.missing:find('no civilian inside', 1, true), ev[1] and ev[1].msg)
  local W2 = world{units = {S.cit(1, 51, 20), S.cit(2, 52, 20), S.cit(5, 51, 44, Z, {squad = 1})},
                   cfg = {reflex = {v = 2, gate = {return_every = 0, fail_closed = false}}}}
  W2.bridges.B1.gate_flags.closed = true
  run(W2, 600)
  W2.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run(W2, 900)
  T.eq(S.bstate(W2, 'B1'), 'down', 'switch off: lowered as before')
end)

---------------------------------------------------------------- SIEGE TRAFFIC
-- PEACE on D-14 inner (B1 up), six civilians outside: three at work north of O1, three in the bailey walking home; the return window
-- has just let two of them through. Then the army comes into sight 30 tiles north of O1 (INVASION).
local function siege_world(o)
  local walkers = {}
  for k = 0, 2 do walkers[#walkers + 1] = {id = 70 + k, route = route(50 + k, 2, 70), start = math.huge} end   -- outside O1
  for k = 0, 2 do walkers[#walkers + 1] = {id = 80 + k, route = route(50 + k, 15, 70), start = math.huge} end  -- in the bailey
  local W = world{walkers = walkers, reflex = o and o.reflex, cfg = o and o.cfg}
  return W
end

T.test('SIEGE TRAFFIC: attackers arrive with civilians outside: O1 rises at once (no T+450 wait, no hold for them), B1 stays up, nobody ' ..
       'crushed, no GATE_FAIL / BREACH; once the army is gone the return window lets the shut-out in (not walled out of drink)', function()
  local W = siege_world()
  run(W, 2400)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'down', 'up'})
  for _, w in ipairs(W.walkers) do w.start = 0 end       -- everybody heads home now
  local army = S.army(6, 20, 0, 500)
  local ids = {}
  for _, u in ipairs(army) do W.add_unit(u); ids[#ids + 1] = u.id end
  local t0 = S.abs_now()
  W.event('INVASION', {id = 501})
  run(W, 1500)
  T.eq(W.K.mode(), 'SIEGE')
  local up = ups_after(W, 'O1', t0)
  T.ok(#up >= 1 and up[1] < 450, 'O1 up before the old T+450 timer: +' .. tostring(up[1]))
  T.eq(S.bstate(W, 'O1'), 'up')
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 never came down')
  T.eq(#ups_after(W, 'B1', t0), 0, 'B1 was never moved')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0, 'no GATE_FAIL / BREACH')
  local held = 0
  for _, l in ipairs(W.logs) do if l.msg:find('up held for', 1, true) then held = held + 1 end end
  T.eq(held, 0, 'no straggler hold')
  local out = 0
  for _, w in ipairs(W.walkers) do
    local u = W.unit(w.id)
    if not in_kern(u._m.x, u._m.y) then out = out + 1 end
  end
  T.ok(out >= 1, 'somebody was shut out (close at once): ' .. out)
  -- the army leaves: RECOVERY, PEACE; B1 stays up through it (B2 down), O1 comes down; the shut-out come in by the return window
  remove_army(W, ids)
  run(W, 14400)
  T.eq(W.K.mode(), 'PEACE')
  T.eq(S.bstate(W, 'O1'), 'down', 'O1 down for trade again')
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up in PEACE')
  for _, w in ipairs(W.walkers) do
    local u = W.unit(w.id)
    T.ok(in_kern(u._m.x, u._m.y), 'citizen ' .. w.id .. ' is inside Kern+ with the drink (' .. u._m.x .. ',' .. u._m.y .. ')')
  end
  T.ok(#gate_ev(W, 'return') >= 1, 'a return window opened for them')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
end)

T.test('SIEGE TRAFFIC, recall case (reflex lockdown on an arrival announcement): O1 up at once, B1 held up, no GATE "up held", nobody ' ..
       'crushed; the walkers on O1\'s way hold its pull only while they can reach the footprint', function()
  local W = siege_world{reflex = true}
  run(W, 2400)
  for _, w in ipairs(W.walkers) do w.start = 0 end
  local t0 = S.abs_now()
  local army = S.army(4, 20, 0, 600)
  for _, u in ipairs(army) do W.add_unit(u) end
  run(W, 1800)
  T.eq(S.bstate(W, 'O1'), 'up', 'O1 up')
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up')
  T.eq(#ups_after(W, 'B1', t0), 0, 'B1 never moved')
  T.eq(#gate_ev(W, 'held'), 0, 'no BUG-338 hold for the civilians outside')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
end)

T.test('SIEGE TRAFFIC, caravan case: B1 open for a caravan when the army comes: B1 and O1 rise at once, nobody crushed, no BREACH', function()
  local W = siege_world()
  run(W, 2400)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from the hills has arrived.'})
  run(W, 900)
  T.eq(S.bstate(W, 'B1'), 'down', 'open for the caravan')
  for _, w in ipairs(W.walkers) do w.start = 0 end
  local t0 = S.abs_now()
  for _, u in ipairs(S.army(6, 20, 0, 700)) do W.add_unit(u) end
  W.event('INVASION', {id = 701})
  run(W, 1500)
  for _, b in ipairs({'O1', 'B1'}) do
    local up = ups_after(W, b, t0)
    T.ok(#up >= 1 and up[1] < 900, b .. ' up before T+900: +' .. tostring(up[1]))
    T.eq(S.bstate(W, b), 'up', b)
  end
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(#W.find_events('BREACH'), 0)
end)

T.test('close_at_once false (legacy switch): the SIEGE raise of O1 waits for the civilians outside until T+450', function()
  local W = siege_world{cfg = {reflex = {v = 2, gate = {close_at_once = false}}}}
  run(W, 2400)
  for _, w in ipairs(W.walkers) do w.start = 0 end
  for _, u in ipairs(S.army(6, 20, 0, 500)) do W.add_unit(u) end
  local t0 = S.abs_now()
  W.event('INVASION', {id = 501})
  run(W, 2400)
  local p = S.pulls(W, 'O1')
  T.ok(#p >= 1 and p[1].tick - t0 >= 400, 'O1 pulled at the timer: +' .. tostring(p[1] and p[1].tick - t0))
end)

T.done()
