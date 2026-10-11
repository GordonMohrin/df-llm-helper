-- Live L3: lever-puller rooms (gate), the civ-alert list with the rooms (siege) and levers inside Tiefe+ in
-- BREACH, on the WP5 reflex (sense, threat, siege, gate) on k_mock (strict) with the lever/bridge simulator.
-- act.burrow_units (the burrow screen's unit assignment) is not in contract.ACT yet: this suite adds it for
-- its own process, as the live engineer will (see the gate.lua lever-room comment).
-- Reach model: a lever job gets a worker only while the lever lies in the civ-alert area (no alert: anywhere);
-- a worker comes after lever_default.worker ticks (150: live L3 took 156-243), at once from a lever puller
-- standing in the lever's room.
local T = require('testlib')
local S = require('siege_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local ROOM = {54, 45, Z, 56, 46, Z}       -- 'dfllm-levers': O1 levers (55,45),(56,45), B1 levers (54,46),(55,46)
local ROOM_B2 = {54, 66, Z, 55, 66, Z}    -- 'dfllm-levers-b2': B2 levers (54,66),(55,66)
local REF = {O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}, B2 = {72, 70, Z - 6}}   -- one lever each inside Tiefe+

local function in_box(p, b) return p.x >= b[1] and p.x <= b[4] and p.y >= b[2] and p.y <= b[5] and p.z >= b[3] and p.z <= b[6] end
local function P(a) return {x = a[1], y = a[2], z = a[3]} end

local function manifest(o)
  local m = S.manifest()
  m.burrows['dfllm-levers'] = {role = 'other'}
  m.burrows['dfllm-levers-b2'] = {role = 'other'}
  for n, p in pairs(REF) do table.insert(m.bridges[n].levers, p) end
  if o and o.o1_levers then m.bridges.O1.levers = o.o1_levers end
  return m
end

-- fort units plus: 6 moody (nearest to the Z3 room), 7 and 8 the next nearest adults
local function units(...)
  local r = S.fort_units()
  r[#r + 1] = S.cit(6, 56, 47)
  r[#r + 1] = S.cit(7, 57, 48)
  r[#r + 1] = S.cit(8, 58, 49)
  for _, x in ipairs({...}) do
    if x.id then r[#r + 1] = x else for _, u in ipairs(x) do r[#r + 1] = u end end
  end
  return r
end

local function burrow_box(name) return dfhack.burrows.findByName(name)._bbox end

local function lever_at(W, p)
  for _, lv in ipairs(W.levers) do if lv.x1 == p[1] and lv.y1 == p[2] and lv.z == p[3] then return lv.id end end
end

local function alert_area(W, lv)
  if df.global.plotinfo.alerts.civ_alert_idx == 0 then return true end
  for _, n in ipairs(W.alert_burrows or {}) do
    local b = dfhack.burrows.findByName(n)
    if b and in_box({x = lv.x1, y = lv.y1, z = lv.z}, b._bbox) then return true end
  end
  return false
end

-- a puller of the lever's room standing in it, or nil
local function puller_at(W, lv)
  for _, name in ipairs({'dfllm-levers', 'dfllm-levers-b2'}) do
    local b = dfhack.burrows.findByName(name)
    if b and in_box({x = lv.x1, y = lv.y1, z = lv.z}, b._bbox) then
      for _, id in ipairs(b.units or {}) do
        local u = W.unit(id)
        if u and not u._m.dead and in_box(u.pos, b._bbox) then return id end
      end
    end
  end
end

local function setup(o)
  o = o or {}
  C.ACT.burrow_units = o.act ~= false and {'gate'} or nil
  local W = S.world{units = (o.units or units)(), manifest = o.manifest or manifest(o),
                    lever_default = o.lever_default or {worker = 150, pull = 40}}
  W.burrow('dfllm-levers', ROOM)
  W.burrow('dfllm-levers-b2', ROOM_B2)
  W.walk, W.dead = {}, o.dead or {}
  if o.act ~= false then
    W.act_result('burrow_units', function(name, ids)
      local b = dfhack.burrows.findByName(name)
      if not b then return false, 'no burrow ' .. tostring(name) end
      b.units = kmock.vec(ids)
      for _, id in ipairs(ids) do
        if not (o.stuck or {})[id] and not in_box(W.unit(id).pos, b._bbox) then
          W.walk[id] = {tick = S.abs_now() + (o.walk or 100), to = {b._bbox[1], b._bbox[2], b._bbox[3]}}
        end
      end
      return true, #ids
    end)
  end
  W.lever_cfg = setmetatable({}, {__index = function(_, id)
    local lv = W.buildings[id]
    if W.dead[id] or not alert_area(W, lv) then return {} end
    return nil
  end})
  W.mil, W.drill = S.military(), S.drill()
  S.load(W, {W.mil, W.drill})
  return W
end

local function hook(W)
  local now = S.abs_now()
  for id, w in pairs(W.walk) do
    if now >= w.tick then W.move(id, w.to[1], w.to[2], w.to[3]); W.walk[id] = nil end
  end
  for _, lv in ipairs(W.levers) do
    for _, j in ipairs(lv.jobs) do
      if j.job_type == df.job_type.PullLever and not j._worker and not W.dead[lv.id] then
        local p = puller_at(W, lv)
        if p then j._worker, j._w = {id = p}, now end
      end
    end
  end
end

local function run(W, ticks, at)
  S.run(W, ticks, {at = at, frame = function(dt) W.frame(dt); hook(W) end})
end

local function assigns(W, name)
  local r = {}
  for _, a in ipairs(W.find_acts('burrow_units')) do
    if a.args[1] == name then r[#r + 1] = {tick = a.tick, ids = a.args[2]} end
  end
  return r
end
local function alert_lists(W)
  local r = {}
  for _, a in ipairs(W.find_acts('alert_burrows')) do r[#r + 1] = {tick = a.tick, names = a.args[1]} end
  return r
end
local function invariants(W)
  T.eq(W.pending_violations, 0, 'never two pending pulls on one bridge')
  T.eq(S.kpi(W).double_toggles, 0, 'no double toggle')
end
local function drill(W) W.K.call('drill', 'start') end

---------------------------------------------------------------- DRILL / SIEGE
T.test('DRILL: the 2 nearest adult civilians (no soldier, child or moody dwarf) are the O1/B1 pullers; PEACE releases them', function()
  local W = setup()
  W.unit(6).mood = 1                                     -- a Secretive mood (df.mood_type)
  run(W, 1600, {{50, drill}})
  local t0 = S.mode_tick(W, 'PEACE>DRILL')
  local z3 = assigns(W, 'dfllm-levers')
  T.eq(#z3, 2, T.show(z3))
  T.eq(z3[1], {tick = t0, ids = {7, 8}}, 'assigned in the T0 step')
  T.eq(z3[2], {tick = S.mode_tick(W, 'DRILL>PEACE'), ids = {}}, 'released when the drill ends')
  T.eq(#assigns(W, 'dfllm-levers-b2'), 0, 'B2 stays down in a drill: its room gets nobody')
  local al = alert_lists(W)
  T.eq(al[1], {tick = t0, names = {'Kern+', 'dfllm-levers', 'dfllm-levers-b2'}})
  T.eq(S.kpi(W).puller_assigns, 2)
  T.eq(S.kpi(W).pullers, {['dfllm-levers'] = 0, ['dfllm-levers-b2'] = 0})
  T.eq(#dfhack.burrows.findByName('dfllm-levers').units, 0)
  invariants(W)
end)

T.test('pullers make the O1 pull fast: taken at once, O1 up by T+600 (without them: T+700, take 160)', function()
  local out = function() return units(S.cit(9, 100, 100)) end    -- outside: the raise waits for T+450
  local res = {}
  for _, act in ipairs({true, false}) do
    local W = setup{act = act, units = out}
    run(W, 1500, {{50, drill}})
    local k = W.drill.kpi
    res[act] = k
    T.eq(k.double_toggles, 0)
    T.eq(k.fails, {})
    invariants(W)
  end
  local a, b = res[true], res[false]
  T.ok(a.last_raise_ticks.O1 <= 600, 'O1 up at T+' .. tostring(a.last_raise_ticks.O1))
  T.ok(a.take_ticks.O1 <= 40 and a.take_ticks.B1 <= 40, T.show(a.take_ticks))
  T.eq(a.puller_pulls, 2, 'O1 and B1 pulled by pullers')
  T.ok(b.last_raise_ticks.O1 > 600, 'without pullers O1 is up at T+' .. tostring(b.last_raise_ticks.O1))
  T.ok(b.take_ticks.O1 >= 150, T.show(b.take_ticks))
  T.eq(b.puller_pulls, 0)
end)

T.test('lever order: a lever in a room with a puller present first, else manifest order', function()
  local o1 = {{58, 52, Z}, {56, 45, Z}}                   -- the first O1 lever lies outside the Z3 room
  local out = function() return units(S.cit(9, 100, 100)) end
  for _, act in ipairs({true, false}) do
    local W = setup{act = act, units = out, o1_levers = o1}
    run(W, 1500, {{50, drill}})
    local p = S.pulls(W, 'O1')
    T.eq(p[1].lever, lever_at(W, act and o1[2] or o1[1]), act and 'puller lever first' or 'manifest order')
    invariants(W)
  end
end)

T.test('a puller who never arrives is replaced after 600 ticks, a dead one at once; never re-chosen', function()
  local W = setup{stuck = {[7] = true}}
  run(W, 1600, {{50, drill}, {800, function(W) W.kill(8) end}})
  local t0 = S.mode_tick(W, 'PEACE>DRILL')
  local z3 = assigns(W, 'dfllm-levers')
  T.eq(z3[1].ids, {6, 7}, 'nearest first (6 is not moody here)')
  T.eq(z3[2].ids, {6, 8})
  T.ok(z3[2].tick - t0 >= 600 and z3[2].tick - t0 <= 640, 'stuck puller replaced at T+600: ' .. (z3[2].tick - t0))
  T.eq(z3[3].ids, {6, 1}, 'the dead puller replaced, 7 is not chosen again')
  T.ok(z3[3].tick >= W.t_start + 800 and z3[3].tick <= W.t_start + 840)
  T.eq(z3[#z3].ids, {}, 'released after the drill')
  invariants(W)
end)

T.test('without act.burrow_units: no assignment, one warning, the rooms still in the alert list', function()
  local W = setup{act = false}
  run(W, 1600, {{50, drill}})
  T.eq(#W.find_acts('burrow_units'), 0)
  local warns = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('burrow_units missing') then warns = warns + 1 end end
  T.eq(warns, 1)
  T.eq(alert_lists(W)[1].names, {'Kern+', 'dfllm-levers', 'dfllm-levers-b2'})
  T.eq(S.kpi(W).puller_assigns, 0)
  T.eq(W.drill.kpi.fails, {})
  invariants(W)
end)

T.test('reload mid-drill: gate adopts the pullers from the burrow, no re-assignment; PEACE releases them', function()
  local W = setup()
  run(W, 400, {{50, drill}})
  T.eq(#assigns(W, 'dfllm-levers'), 1)
  for i, e in ipairs(W.entries) do if e.name == 'gate' then table.remove(W.entries, i) end end
  W.mods.gate = nil
  package.loaded['dfllm.gate'] = nil
  W.load(require('dfllm.gate'))
  run(W, 1200)
  local z3 = assigns(W, 'dfllm-levers')
  T.eq(#z3, 2, T.show(z3))
  T.eq(z3[2].ids, {})
  T.eq(W.K.mode(), 'PEACE')
  invariants(W)
end)

---------------------------------------------------------------- BREACH
local function breach_inside(o)
  o = o or {}
  o.units = function() return units(S.army(6, 150, 150)) end
  local W = setup(o)
  if o.prep then o.prep(W) end
  run(W, 2000, {{300, function(W) W.move(201, 60, 75, Z) end}})
  local tb = S.mode_tick(W, 'SIEGE>BREACH')
  T.ok(tb, 'BREACH')
  return W, tb
end

T.test('BREACH (hostile inside), B2 lever linked inside Tiefe+: alert Tiefe+ alone, nobody on the B2 landing; B2 raised from Tiefe+', function()
  local W, tb = breach_inside()
  local al = alert_lists(W)
  T.eq(al[#al], {tick = tb, names = {'Tiefe+'}}, 'the landing next to a B2 that may be down draws nobody')
  local z3 = assigns(W, 'dfllm-levers')
  T.eq(z3[#z3], {tick = tb, ids = {}}, 'the Z3 pullers go to the refuge too')
  T.eq(#assigns(W, 'dfllm-levers-b2'), 0, 'the B2 room gets nobody')
  local p = S.pulls(W, 'B2')
  T.eq(#p, 1)
  T.eq(p[1].lever, lever_at(W, REF.B2), 'the refuge lever comes before the landing levers')
  local f = S.flips(W, 'B2')
  T.eq(#f, 1)
  T.ok(f[1].tick - tb <= 300, 'B2 up ' .. (f[1].tick - tb) .. ' ticks into the BREACH')
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  invariants(W)
end)

T.test('BREACH fallback (no B2 lever in Tiefe+, a pre-L3 fort): alert Tiefe+ and the B2 room; B2 pullers raise B2; no GATE_FAIL', function()
  local m = manifest()
  m.bridges.B2.levers = {{54, 66, Z}, {55, 66, Z}}
  local W, tb = breach_inside{manifest = m}
  local al = alert_lists(W)
  T.eq(al[#al], {tick = tb, names = {'Tiefe+', 'dfllm-levers-b2'}}, 'an attacker-side room would draw people out of Tiefe+')
  local z3, b2 = assigns(W, 'dfllm-levers'), assigns(W, 'dfllm-levers-b2')
  T.eq(z3[#z3], {tick = tb, ids = {}}, 'the Z3 pullers go to the refuge too')
  T.eq(b2[1].tick, tb)
  T.eq(#b2[1].ids, 2)
  local f = S.flips(W, 'B2')
  T.eq(#f, 1)
  T.ok(f[1].tick - tb <= 300, 'B2 up ' .. (f[1].tick - tb) .. ' ticks into the BREACH')
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  invariants(W)
end)

T.test('BREACH fallback also while the B2 refuge lever is built but not linked yet', function()
  local W, tb = breach_inside{prep = function(W) W.buildings[lever_at(W, REF.B2)].linked_mechanisms = kmock.vec{} end}
  local al = alert_lists(W)
  T.eq(al[#al], {tick = tb, names = {'Tiefe+', 'dfllm-levers-b2'}})
  T.eq(#assigns(W, 'dfllm-levers-b2')[1].ids, 2)
  T.eq(S.bstate(W, 'B2'), 'up')
  T.ok(S.pulls(W, 'B2')[1].lever ~= lever_at(W, REF.B2), 'an unlinked lever is never pulled')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  invariants(W)
end)

T.test('BREACH by gate fail (O1 Z3 levers dead): O1 is raised from its lever in Tiefe+; the only GATE_FAIL is the SIEGE one', function()
  local W = setup{units = function() return units(S.army(6, 150, 150)) end, dead = {[11] = true, [12] = true}}
  run(W, 3000)
  local t0, tb = S.mode_tick(W, 'PEACE>SIEGE'), S.mode_tick(W, 'SIEGE>BREACH')
  T.ok(tb and tb - t0 >= 900 and tb - t0 <= 930, 'BREACH at T+900')
  local gf = W.find_events('GATE_FAIL')
  T.eq(#gf, 1, T.show(gf))
  T.eq(gf[1].d, {bridge = 'O1', want = 'up', why = 'no_worker'})
  local ref = lever_at(W, REF.O1)
  local after = {}
  for _, p in ipairs(S.pulls(W, 'O1')) do if p.tick >= tb then after[#after + 1] = p end end
  T.ok(#after >= 1)
  T.eq(after[#after].lever, ref, 'the Tiefe+ lever')
  T.eq(S.bstate(W, 'O1'), 'up')
  T.eq(S.bstate(W, 'B2'), 'up')
  T.eq(S.kpi(W).fails, {'O1:no_worker'})
  invariants(W)
end)

T.test('gate.rooms and gate.pullers: BREACH allows only rooms without outer/inner levers whose bridges lack a refuge lever', function()
  local W = setup()
  run(W, 50)
  T.eq(select(2, W.K.call('gate', 'rooms', 'SIEGE')), {'dfllm-levers', 'dfllm-levers-b2'})
  T.eq(select(2, W.K.call('gate', 'rooms', 'BREACH')), {}, 'B2 has a linked lever inside Tiefe+')
  T.eq(select(2, W.K.call('gate', 'pullers', 'O1')), 0)
  run(W, 300, {{0, drill}})
  T.eq(select(2, W.K.call('gate', 'pullers', 'O1')), 2)
  T.eq(select(2, W.K.call('gate', 'pullers', 'B2')), 0)
  local m = manifest()
  m.bridges.B2.levers = {{54, 66, Z}, {55, 66, Z}}
  local W2 = setup{manifest = m}
  run(W2, 50)
  T.eq(select(2, W2.K.call('gate', 'rooms', 'BREACH')), {'dfllm-levers-b2'}, 'no refuge lever: the landing room is the fallback')
end)

---------------------------------------------------------------- needs
T.test('a thirsty or hungry puller is let go (not barred: back after a drink); the next nearest takes over', function()
  local W = setup()
  local function at(t, f) return {t, f} end
  run(W, 1600, {{50, drill},
                at(450, function(W) W.unit(7).counters2 = {thirst_timer = 21000, hunger_timer = 0} end),
                at(700, function(W) W.unit(7).counters2 = {thirst_timer = 0, hunger_timer = 0}; W.kill(8) end),
                at(900, function(W) W.unit(6).counters2 = {thirst_timer = 0, hunger_timer = 45000} end)})
  local z3 = assigns(W, 'dfllm-levers')
  T.eq(z3[1].ids, {6, 7})
  T.eq(z3[2].ids, {6, 8}, 'thirsty 7 let go, 8 is next')
  T.ok(z3[2].tick >= W.t_start + 450 and z3[2].tick <= W.t_start + 490)
  T.eq(z3[3].ids, {6, 7}, 'after a drink 7 may serve again (8 died)')
  T.eq(z3[4].ids, {7, 1}, 'hungry 6 let go')
  T.eq(z3[#z3].ids, {}, 'released after the drill')
  local let = {}
  for _, l in ipairs(W.logs) do
    local s = tostring(l.msg):match('let go ([%d:%a,]+)')
    if s then let[#let + 1] = s end
  end
  T.eq(let, {'7:needs', '8:gone', '6:needs'})
  invariants(W)
end)

C.ACT.burrow_units = nil
T.done()
