-- BUG-511 / BUG-510 (Run 16a i1 Basementflew y405 invasion 3 and y406: "B1 not up after 1302 ticks", then three pairs of lever pullers in
-- a row "let go ... away" after 600 ticks each while the nearest citizens lay 40+ tiles from the lever room, a pull nobody took): the
-- arrival allowance of a puller grows with the distance he has to walk (PULLER_BASE + PULLER_STEP per tile, at most PULLER_MAX), so the
-- walk of a far pair is not cut off at 600 ticks and replaced by another far pair. Fixture of test_gate_pullers (lever rooms, the
-- burrow screen's unit assignment, walkers that arrive after `walk` ticks).
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
  local mods = {W.mil, W.drill}
  if o.reflex then                                  -- BUG-511: the arrival lockdown (reflex) holds the gates up in PEACE
    local snap = {name = 'snapshot', every = {ticks = 100}}
    function snap.tile() return {c = '.', dig = '', bld = ''} end
    function snap.far() return false end
    snap.outside_near = require('dfllm.snapshot').outside_near
    df.global.world.status.popups = kmock.vec{}
    package.loaded['dfllm.reflex'] = nil
    mods[#mods + 1] = snap
    mods[#mods + 1] = require('dfllm.reflex')
  end
  S.load(W, mods)
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


local function far_units()
  local r = S.fort_units()
  r[1] = S.cit(1, 60, 94)            -- 49 tiles from the Z3 lever room
  r[2] = S.cit(2, 61, 94)
  r[3] = S.cit(3, 62, 94)
  return r
end

T.test('BUG-511: pullers 49 tiles from the lever room who arrive after 800 ticks are NOT let go at 600 (old: replaced by the next far ' ..
       'pair, again and again); a puller who never arrives is let go after his distance allowance', function()
  local W = setup{units = far_units, walk = 800, stuck = {[2] = true}}
  run(W, 1500, {{50, drill}})
  local z3 = assigns(W, 'dfllm-levers')
  T.eq(z3[1].ids, {1, 2}, 'the two nearest')
  local t0 = S.mode_tick(W, 'PEACE>DRILL')
  local second = z3[2]
  T.ok(second and second.tick - t0 > 600, 'nobody is replaced at 600: ' .. T.show(z3))
  T.ok(second and second.tick - t0 >= 880 and second.tick - t0 <= 940,
       'the stuck puller (never arrives) is let go after 300 + 12 x 49 = 888 ticks: +' .. tostring(second and second.tick - t0))
  T.eq(second.ids[1], 1, 'the one who walks stays')
end)

T.test('BUG-511: a puller 3 tiles from the room who never arrives is still let go at 600 (the allowance never shortens it)', function()
  local W = setup{stuck = {[7] = true}}
  run(W, 900, {{50, drill}})
  local t0 = S.mode_tick(W, 'PEACE>DRILL')
  local z3 = assigns(W, 'dfllm-levers')
  T.ok(z3[2].tick - t0 >= 600 and z3[2].tick - t0 <= 640, 'replaced at T+600: ' .. (z3[2].tick - t0))
end)

T.test('BUG-511: an arrival lockdown (the raiders not in sight yet, PEACE) already sends the pullers to the lever room: they are there ' ..
       'when the SIEGE starts', function()
  local function units_raiders()
    local r = far_units()
    for _, u in ipairs(S.army(4, 51, 0)) do r[#r + 1] = u end
    return r
  end
  local W = setup{units = units_raiders, reflex = true, walk = 400}
  for i = 201, 204 do W.unit(i)._m.hidden = true end
  W.event('INVASION', {id = 7})
  run(W, 120)
  T.eq(W.K.mode(), 'PEACE', 'a lockdown, no siege yet')
  local z3 = assigns(W, 'dfllm-levers')
  T.ok(#z3 >= 1 and z3[1].ids and #z3[1].ids == 2, 'pullers assigned in the PEACE lockdown: ' .. T.show(z3))
  local t0 = W.find_events('ARRIVAL')[1].tick
  T.ok(z3[1].tick - t0 <= 150, 'within the first frames of the lockdown (old: only at the SIEGE): +' .. (z3[1].tick - t0))
  run(W, 600)
  local b = dfhack.burrows.findByName('dfllm-levers')
  local there = 0
  for _, id in ipairs(b.units or {}) do
    local u = W.unit(id)
    if u and in_box(u.pos, b._bbox) then there = there + 1 end
  end
  T.eq(there, 2, 'both stand in the room')
end)

T.done()
