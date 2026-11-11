-- BUG-757 (Run 16b i2 Whirledrampart y440): squad A stood outside on walk group 331, the sortie against a predator in the fort was
-- 'target unreachable', and nothing called the squads back into the core in PEACE. military.recall_pass: a squad with soldiers outside
-- Kern+ for RECALL.after ticks in quiet PEACE gets a station order at the nearest Kern+ floor; it ends when they are back.
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local rf_hold
local function stubs()
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.holding(K) return rf_hold end
  return {rf}
end

local real_blocks
local function setup()
  rf_hold = ''
  local W = X.world{units = X.citizens(50)}
  real_blocks = real_blocks or dfhack.burrows.listBlocks
  dfhack.burrows.listBlocks = function(b)                -- the burrows screen's blocks of the burrow's bbox
    if not b or not b._bbox then return {} end
    local r, bb = {}, b._bbox
    for z = bb[3], bb[6] do
      for by = bb[2] // 16, bb[5] // 16 do
        for bx = bb[1] // 16, bb[4] // 16 do r[#r + 1] = {map_pos = {x = bx * 16, y = by * 16, z = z}} end
      end
    end
    return r
  end
  local mods = stubs()
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i in ipairs(pts) do r[i] = 1 end; return r end
  mods[#mods + 1] = snap
  mods[#mods + 1] = X.runner('P5')
  X.load(W, {'military'}, mods, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  X.equip_all(W)
  W.run(3700, {skip = 9})
  return W
end
local function squad_ids(W, alias)
  local s = X.squad_of(W, alias)
  local r = {}
  for _, p in ipairs(s.positions) do
    if p.occupant and p.occupant >= 0 then r[#r + 1] = W.hfs[p.occupant].unit_id end
  end
  return r, s
end
local function station_orders(W, sid)
  return X.acts(W, 'squad_order', function(a) return a.args[1] == sid and type(a.args[2]) == 'table' and a.args[2].kind == 'station' end)
end
local function in_kern(p) return p.x >= 40 and p.x <= 80 and p.y >= 41 and p.y <= 95 and p.z >= Z - 2 and p.z <= Z end

T.test('BUG-757: soldiers outside Kern+ for a while in quiet PEACE: a station order at a Kern+ floor calls the squad back', function()
  local W = setup()
  local ids, s = squad_ids(W, 'A')
  T.ok(#ids >= 2, 'squad A has soldiers')
  for _, id in ipairs(ids) do W.move(id, 10, 10, Z); W.unit(id)._m.pinned = true end
  local n0 = #station_orders(W, s.id)
  W.run(1200, {skip = 9})
  T.eq(#station_orders(W, s.id), n0, 'not yet: the grace period')
  W.run(2 * 3600 + 1200, {skip = 9})
  local o = station_orders(W, s.id)
  T.ok(#o > n0, 'old code: no recall order')
  local pos = o[#o].args[2].pos
  T.ok(in_kern(pos), 'the order lies in Kern+: ' .. tostring(pos and pos.x) .. ',' .. tostring(pos and pos.y))
  local logged
  for _, l in ipairs(W.logs) do if l.msg:find('called back to', 1, true) then logged = true end end
  T.ok(logged, 'kern.log names the recall')
end)

T.test('BUG-757: nobody outside: no recall; a lockdown hold (reflex.holding) or a SIEGE: no recall order', function()
  local W = setup()
  local ids, s = squad_ids(W, 'A')
  for _, id in ipairs(ids) do W.move(id, 45, 50, Z); W.unit(id)._m.pinned = true end
  local n0 = #station_orders(W, s.id)
  W.run(3 * 3600, {skip = 9})
  T.eq(#station_orders(W, s.id), n0, 'inside Kern+: nothing new')
  W = setup()
  ids, s = squad_ids(W, 'A')
  rf_hold = 'lockdown'
  for _, id in ipairs(ids) do W.move(id, 10, 10, Z); W.unit(id)._m.pinned = true end
  n0 = #station_orders(W, s.id)
  W.run(4 * 3600, {skip = 9})
  T.eq(#station_orders(W, s.id), n0, 'a lockdown hold: no recall')
end)

T.test('BUG-757: back inside: the recall ends and the posture station is ordered again', function()
  local W = setup()
  local ids, s = squad_ids(W, 'A')
  for _, id in ipairs(ids) do W.move(id, 10, 10, Z); W.unit(id)._m.pinned = true end
  W.run(4 * 3600, {skip = 9})
  local n1 = #station_orders(W, s.id)
  T.ok(n1 > 0)
  for _, id in ipairs(ids) do W.move(id, 45, 50, Z) end
  W.run(2 * 3600, {skip = 9})
  local back
  for _, l in ipairs(W.logs) do if l.msg:find('is back in Kern+', 1, true) then back = true end end
  T.ok(back, 'recall ended')

  T.eq(X.mod('military').RECALL.after, 2400)
  dfhack.burrows.listBlocks = real_blocks
end)

T.test('BUG-757: a recall in progress ends when a SIEGE begins: no recall order is given in a siege (the posture owns the squads)', function()
  local W = setup()
  local ids, s = squad_ids(W, 'A')
  for _, id in ipairs(ids) do W.move(id, 10, 10, Z); W.unit(id)._m.pinned = true end
  W.run(4 * 3600, {skip = 9})
  W.K.set_mode('SIEGE', 'test')
  local function calls()
    local n = 0
    for _, l in ipairs(W.logs) do if l.msg:find('called back to', 1, true) then n = n + 1 end end
    return n
  end
  local before = calls()
  T.eq(before, 1, 'one recall in PEACE')
  W.run(4 * 3600, {skip = 9})
  local back = calls()
  T.eq(back, before, 'none in the SIEGE')
end)

dfhack.burrows.listBlocks = real_blocks
T.done()
