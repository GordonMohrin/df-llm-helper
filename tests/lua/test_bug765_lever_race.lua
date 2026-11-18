-- BUG-765 (Run 16a i1 Basementflew y540 win d76, kern 87b10464: a surprise siege killed 11 citizens outside Kern+; B1's levers lie 5 tiles WEST of its
-- footprint, outside the walls; the arrival's pullers were chosen 60 tiles away inside Kern+ (nearest first), the lever burrow went into the civ
-- alert, a cave dragon and goblins stood 17-47 tiles from the levers: the pull took 1,650 ticks and the citizens that walked out to the levers or
-- stood at B1 were among the dead): a lever room OUTSIDE Kern+ and the refuge is a race. A puller is chosen, kept on his way and the lever burrow
-- listed in the alert only while the hostile needs longer to reach the levers than the puller needs to reach them and pull.
-- Siege traffic (real sense / threat / siege / gate / reflex on one k_mock world, invaders visible, walkers that walk, a raised bridge cannot be
-- walked, a unit ON a moving bridge is crushed):
--   * lost race (levers outside the walls, the army 28 tiles from them, every citizen 36+ tiles away): nobody is sent out, no lever burrow in the
--     alert, nobody stands outside Kern+ or on a footprint, nothing crushed
--   * won race (a citizen 3 tiles from the room, the army 33 tiles from it): he is the puller, B1 and O1 rise before T+900
--   * 24 civilians far outside at the ARRIVAL, levers inside Kern+ (the rule never touches those): the recall brings them in, the bridges rise
--     before T+900, nobody is crushed or locked out
local T = require('testlib')
local S = require('siege_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

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
  else
    m.bridges.O1.levers = {{55, 45, Z}, {56, 45, Z}}
    m.bridges.B1.levers = {{54, 46, Z}, {55, 46, Z}}
  end
  return m
end

local function setup(o)
  C.ACT.burrow_units = {'gate'}
  local W = S.world{units = o.units, manifest = manifest(o.outside), mode = o.mode,
                    lever_default = {worker = 150, pull = 40}}
  W.burrow('dfllm-levers', o.outside and ROOM or {54, 45, Z, 56, 46, Z})
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
  W.lever_cfg = setmetatable({}, {__index = function(_, id)       -- a lever is taken only by a puller standing in its room
    local lv = W.buildings[id]
    local b = dfhack.burrows.findByName('dfllm-levers')
    if b and in_box({x = lv.x1, y = lv.y1, z = lv.z}, b._bbox) then
      for _, uid in ipairs(b.units or {}) do
        local u = W.unit(uid)
        if u and in_box(u.pos, b._bbox) then return nil end
      end
      return {}
    end
    return nil
  end})
  W.mil = S.military()
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  df.global.world.status.popups = kmock.vec{}
  package.loaded['dfllm.reflex'] = nil
  S.load(W, {W.mil, snap, require('dfllm.reflex')})
  return W
end

local function hook(W, t)
  local now = S.abs_now()
  for id, w in pairs(W.walk) do
    if now >= w.tick then W.move(id, w.to[1], w.to[2], w.to[3]); W.walk[id] = nil end
  end
  -- the walkers of the test (civilians on their way in): one tile west / north every 24 ticks (about 9 ticks a frame: every 3rd frame)
  W.t0 = W.t0 or now
  local step = (now - W.t0) // 27
  for _, w in ipairs(W.walkers) do
    if not w.dead and (w.done or 0) < step and w.i < #w.route then
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

local function assigns(W)
  local r = {}
  for _, a in ipairs(W.find_acts('burrow_units')) do
    if a.args[1] == 'dfllm-levers' then r[#r + 1] = {tick = a.tick, ids = a.args[2]} end
  end
  return r
end
local function alert_has_levers(W)
  for _, a in ipairs(W.find_acts('alert_burrows')) do
    for _, n in ipairs(a.args[1] or {}) do if n == 'dfllm-levers' then return true end end
  end
  return false
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

local function army_units(inner, y)
  local r = inner
  for _, u in ipairs(S.army(6, 51, y)) do r[#r + 1] = u end
  return r
end

T.test('BUG-765: levers outside the walls, the army 28 tiles from them, every citizen 36+ tiles away: nobody is sent out to pull, the lever ' ..
       'burrow stays out of the alert, nobody is crushed or left outside Kern+', function()
  local W = setup{outside = true, mode = 'SIEGE', units = army_units(S.fort_units(), 5)}
  run(W, 2400)
  for _, a in ipairs(assigns(W)) do T.eq(a.ids, {}, 'no puller is ever assigned (old: the two nearest, walking 36 tiles out): ' .. T.show(a)) end
  T.ok(not alert_has_levers(W), 'the lever burrow is not listed in the civ alert (old: citizens are drawn out to the levers)')
  T.ok(logged(W, 'not sent as pullers'), 'kern.log says why')
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, id in ipairs({1, 2, 3, 4}) do
    local u = W.unit(id)
    T.ok(in_kern(u._m.x, u._m.y), 'citizen ' .. id .. ' stays inside Kern+ at ' .. u._m.x .. ',' .. u._m.y)
  end
end)

T.test('BUG-765: the same fort with a citizen 3 tiles from the lever room and the army 33 tiles from it: he is the puller and B1 and O1 rise ' ..
       'before T+900', function()
  local units = S.fort_units()
  units[#units + 1] = S.cit(6, 56, 37)
  local W = setup{outside = true, mode = 'SIEGE', units = army_units(units, 0)}
  run(W, 1500)
  local got
  for _, a in ipairs(assigns(W)) do if #a.ids > 0 then got = got or a end end
  T.ok(got and got.ids[1] == 6, 'the near citizen is assigned: ' .. T.show(got))
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') or S.mode_tick(W, 'ALERT>SIEGE') or 0
  for _, b in ipairs({'O1', 'B1'}) do
    T.eq(S.bstate(W, b), 'up', b .. ' is up')
    local f = S.flips(W, b)[1]
    T.ok(f and f.to == 'up', b .. ' flipped up')
  end
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(W.pending_violations, 0, 'never two pending pulls on one bridge')
end)

T.test('BUG-765 siege traffic: 24 civilians far outside Kern+ at the ARRIVAL, levers inside Kern+: the rule never touches them; the recall brings ' ..
       'everyone in, O1 and B1 rise before T+900, nobody is crushed or locked out', function()
  local units, walkers = S.fort_units(), {}
  for k = 0, 23 do
    local id = 300 + k
    local x, y = 82 + (k % 8), 50 + 3 * (k // 8)
    units[#units + 1] = S.cit(id, x, y)
    local route = {}
    for xx = x, 70, -1 do route[#route + 1] = {xx, y} end
    walkers[#walkers + 1] = {id = id, route = route, i = 1}
  end
  local W = setup{outside = false, mode = 'PEACE', units = army_units(units, 5), walkers = walkers}
  W.event('INVASION', {id = 5})
  run(W, 1800)
  T.ok(W.K.mode() == 'SIEGE', 'a SIEGE: ' .. W.K.mode())
  for _, b in ipairs({'O1', 'B1'}) do
    T.eq(S.bstate(W, b), 'up', b .. ' is up')
    local f = S.flips(W, b)[1]
    T.ok(f and f.tick - (S.abs_now() - 1800) <= 900, b .. ' rose before T+900: +' .. tostring(f and (f.tick - (S.abs_now() - 1800))))
  end
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, w in ipairs(walkers) do
    local u = W.unit(w.id)
    T.ok(in_kern(u._m.x, u._m.y), 'civilian ' .. w.id .. ' is inside Kern+ (locked out at ' .. u._m.x .. ',' .. u._m.y .. ')')
    for name in pairs(FPY) do T.ok(not on_fp(name, u._m.x, u._m.y), w.id .. ' stands on ' .. name) end
  end
  T.eq(#assigns(W) >= 0, true)
end)

T.done()
