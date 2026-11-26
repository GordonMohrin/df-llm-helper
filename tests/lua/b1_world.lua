-- Neuausrichtung 15 (BUG-905..909): the shared SIEGE TRAFFIC harness of the B1 tests (Run 17 i3: the inner bridge B1, a 3x1 footprint 50..52,40
-- of the siege world, a squad station 4 tiles on its inner side at 51,44). Real sense / threat / siege / gate (and, with o.real_mil, the real
-- military's restation / standing on a mutable squad fake) on one k_mock world; units that walk (a path DF shows: the next 25 route tiles), pace
-- about their station or stand; a raised bridge cannot be walked; a unit ON a moving bridge is crushed (and recorded, with the tick).
--   local B = require('b1_world'); local W = B.build{actors = {...}, mode = 'ALERT', lock = 'lockdown', ...}; B.run(W, 2400)
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local B = {}
B.FPY = {O1 = 10, B1 = 40, B2 = 60}
local function on_fp(name, x, y) return y == B.FPY[name] and x >= 50 and x <= 52 end
B.on_fp = on_fp

function B.route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

-- a patrol: the tiles of a line walked back and forth `n` times
function B.patrol(x0, x1, y, n)
  local r = {}
  for k = 1, n do
    for x = x0, x1 do r[#r + 1] = {x, y} end
    for x = x1 - 1, x0 + 1, -1 do r[#r + 1] = {x, y} end
  end
  return r
end

local function seal_fake()
  local M = {name = 'seal', every = {ticks = 100000}}
  function M.refuge_drink(K, which) return {exists = true, drink = 40, wells = 0, wet = false} end
  return M
end

-- o.actors = {{id, kind = 'soldier'|'citizen', pos = {x, y} | route = {{x, y}...}, start, tpt, pace = {{dx, dy}...} (soldiers pacing about the squad
--   station), period, still = true, nopath = true, fn = function(W, rel, a)}}
-- o.army = hostile units (S.inv...); o.foes = {{id, x, y0, y1, tpt}} walkers among them; o.mode; o.lock (the reflex lockdown reason, nil = none);
-- o.lever ({worker, pull}); o.move; o.lat (the measured lever latency to start with); o.closed = {B1 = true} (up at the start);
-- o.real_mil (real military restation / standing); o.hidden (the snapshot knows no tile: a station can not be moved); o.station = {x, y};
-- o.cfg; o.base = false (no citizens inside Kern+); o.deep = true (final rule of BUG-907: the base citizens live 190+ tiles from every footprint (past the window of a measured latency of 1000: 126 tiles), in a Kern+ that reaches there, so that
-- nobody of the base is within the reach window of a bridge and a kernel raise is possible at all)
function B.build(o)
  o = o or {}
  local units = o.base == false and {} or (o.deep and {S.cit(1, 60, 250), S.cit(2, 61, 250), S.cit(3, 62, 251), S.cit(4, 63, 252, Z, {adult = false})}
                                          or {S.cit(1, 60, 70), S.cit(2, 61, 70), S.cit(3, 62, 71), S.cit(4, 63, 72, Z, {adult = false})})
  local actors = {}
  for _, a in ipairs(o.actors or {}) do
    local x, y = a.pos and a.pos[1] or a.route[1][1], a.pos and a.pos[2] or a.route[1][2]
    units[#units + 1] = S.cit(a.id, x, y, Z, a.kind == 'soldier' and {squad = 1} or nil)
    actors[#actors + 1] = {id = a.id, kind = a.kind, route = a.route, start = a.start or 0, i = 1, tpt = a.tpt or 27, pace = a.pace, period = a.period or 36,
                           still = a.still, nopath = a.nopath, fn = a.fn, k = 1, next = 0}
  end
  local foes = {}
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  for _, f in ipairs(o.foes or {}) do foes[#foes + 1] = f end
  local persist = {}
  if o.lat then persist['m.gate'] = {lat = {s = (o.lat + 50) // 100, t = o.lat}} end
  -- the shipped switches of config/reflex.json (the code's own defaults are the legacy gate of main): the reach rule, the player's lever, the station clearance
  local cfg = o.cfg or {}
  cfg.reflex = cfg.reflex or {v = 2}
  cfg.reflex.gate = cfg.reflex.gate or {}
  if cfg.reflex.gate.reach == nil then cfg.reflex.gate.reach = o.reach ~= false end
  if cfg.reflex.gate.player_lever == nil then cfg.reflex.gate.player_lever = true end
  if cfg.reflex.gate.station_clear == nil then cfg.reflex.gate.station_clear = 4 end
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = o.lever or {worker = 30, pull = 40}, cfg = cfg,
                    persist = persist, kern = o.deep and {40, 41, Z - 2, 200, 300, Z} or nil}
  W.actors, W.foes, W.crushed, W.t0 = actors, foes, {}, nil
  -- the squad: one fake squad 1 whose station order the military module (the real one: o.real_mil) may move
  local st = o.station or {51, 44}
  df.global.plotinfo.group_id = df.global.plotinfo.group_id or 1
  W.squad1 = {id = 1, entity_id = df.global.plotinfo.group_id, orders = {{kind = 'station', pos = {x = st[1], y = st[2], z = Z}}}}
  df.squad = {find = function(id) if id == 1 then return W.squad1 end end}
  W.act_result('squad_order', function(sid, order)
    if sid ~= 1 or type(order) ~= 'table' or not order.pos then return false, 'no squad' end
    W.squad1.orders = {{kind = 'station', pos = {x = order.pos.x, y = order.pos.y, z = order.pos.z}}}
    return true
  end)
  local extra = {S.military(), seal_fake()}
  if o.hidden then
    local snap = {name = 'snapshot', every = {ticks = 100}}
    function snap.tile(K, x, y, z) return nil end
    extra[#extra + 1] = snap
  else
    extra[#extra + 1] = S.snapshot({})
  end
  W.lockwhy, W.hook = o.lock, o.hook
  extra[#extra + 1] = {name = 'reflex', every = {ticks = 100000}, holding = function(K, what) if what == 'gates' then return W.lockwhy end end}
  if o.real_mil then
    package.loaded['dfllm.military'] = nil
    local mil = require('dfllm.military')
    extra[1] = {name = 'military', every = {ticks = 1000000000}, init = mil.init, restation = mil.restation, standing = mil.standing,
                posture = function() return true end, kpi = function() return {squads = 1, soldiers = 4, worn = 95, cv = 13, metal_pct = 0, on_station = 4} end,
                kill = function() return true, 0 end, step = function() end}
  end
  S.load(W, extra)
  for name in pairs(o.closed or {}) do W.bridges[name].gate_flags.closed = true end
  return W
end

local function path_of(a)
  local xs, ys, zs = {}, {}, {}
  for k = a.i + 1, math.min(#a.route, a.i + 25) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = a.route[k][1], a.route[k][2], Z end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

local function sgn(v) return v > 0 and 1 or (v < 0 and -1 or 0) end

function B.step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  if W.hook then W.hook(W, rel) end                       -- a test's own script (starts a walker when a bridge is down, ...)
  for _, a in ipairs(W.actors) do
    local u = W.unit(a.id)
    if not a.dead and rel >= a.start then
      if a.fn then
        a.fn(W, rel, a)
      elseif a.pace then                                   -- soldiers pacing about the CURRENT station order (they walk to a new one)
        local o = W.squad1.orders[1].pos
        local off = a.pace[a.k]
        local tx, ty = o.x + off[1], o.y + off[2]
        local x, y = u._m.x, u._m.y
        if (x ~= tx or y ~= ty) then
          if rel >= a.next then
            W.move(a.id, x + sgn(tx - x), y + sgn(ty - y), Z)
            a.next = rel + a.tpt
          end
        elseif rel >= a.next then
          a.k = a.k % #a.pace + 1
          a.next = rel + a.period
        end
      elseif a.route and a.i < #a.route and rel >= a.next then
        local nx = a.route[a.i + 1]
        local blocked = false
        for name in pairs(B.FPY) do
          if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) ~= 'down' then blocked = true end   -- raised or moving: no way
        end
        a.blocked = blocked
        if not blocked then
          a.i = a.i + 1
          a.next = rel + a.tpt
          W.move(a.id, nx[1], nx[2], Z)
        end
      end
    end
    if not a.dead then
      u.path = (a.route and not a.nopath and rel >= a.start and not a.blocked) and path_of(a) or nil
    end
  end
  for _, f in ipairs(W.foes) do
    local k = math.min(math.floor(rel / (f.tpt or 9)), math.abs(f.y1 - f.y0))
    W.move(f.id, f.x, f.y0 + (f.y1 >= f.y0 and k or -k), Z)
  end
  -- a unit ON a moving bridge is crushed (and recorded)
  for _, a in ipairs(W.actors) do
    if not a.dead then
      local u = W.unit(a.id)
      for name in pairs(B.FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          a.dead = true
          W.crushed[#W.crushed + 1] = string.format('%d (%s) on %s at +%d', a.id, tostring(a.kind), name, rel)
        end
      end
    end
  end
end

function B.run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, B.step} end
  S.run(W, ticks, {at = at})
end

-- ticks (from the first frame) of the flips of bridge b to `to`
function B.flips(W, b, to)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == to then r[#r + 1] = f.tick - W.t_start end end
  return r
end
function B.pulls(W, b)
  local r = {}
  for _, p in ipairs(S.pulls(W, b)) do r[#r + 1] = p.tick - W.t_start end
  return r
end
function B.events(W, typ, state)
  local r = {}
  for _, e in ipairs(W.find_events(typ)) do if state == nil or e.d.state == state or e.d.why == state then r[#r + 1] = e end end
  return r
end
-- the tick (from the first frame) the want of bridge b started to be waited for: the first GATE peace_wait line (the gate's first pass comes ~600
-- ticks after load; its want, the quiet clock and the first wait all start there)
function B.want_t(W)
  local ev = B.events(W, 'GATE', 'peace_wait')
  return ev[1] and ev[1].tick - W.t_start or nil
end
-- the position of unit id now
function B.at(W, id) local u = W.unit(id); return u._m.x, u._m.y end

return B
