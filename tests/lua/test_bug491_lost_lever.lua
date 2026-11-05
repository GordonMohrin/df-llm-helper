-- BUG-491 (Run 16d i4 Trumpetrealms y383-y387: O1 destroyed by a cave dragon once, rebuilt by the keeper, its levers never linked
-- again (act.link_lever 'needs 2 free reachable mechanisms, 0 found', ~100 times in 1500 days: a fort without stone), so gate
-- said no_lever, status 'PERIMETER OPEN 191 days: levers lost: O1', the pop ceiling stuck and three cave dragons came through
-- 84,73,139; the keeper replaced O1 by wall + door only after 2 more losses to building destroyers). Seal's bridge queue now asks
-- economy whether the lost bridge's levers can be linked again (mech_free, mech_state): no stone / no Mechanics' workshop = the
-- first loss is replaced by wall + door at once; mechanisms on the way = rebuilt, but replaced link_wait ticks after the loss when
-- they are still short. The wall + door has the BUG-458/487 reach check: walls that would cut citizens off, or whose reach is not
-- proven, become doors. The siege traffic of the gate itself is tests/lua/test_bug492_493_traffic.lua.
local T = require('testlib')
local SW = require('seal_world')

local G = 9
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}, {25, 23, G}, {25, 24, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}
local MAN3 = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 24, G, 20, 26, G}, levers = {{25, 22, G}, {25, 23, G}}}},
              burrows = {['Kern+'] = {role = 'kern'}}}

local function run(W, n) W.run(n, {skip = 9}) end
local function evs(W, t) return W.find_events(t) end

-- the gatehouse of test_bridge_rebuild: fort walls x20-40 y20-30, O1 in the west wall (1 or 3 tiles), no bridge standing (lost)
local function fort(man, mech, nocit)
  local fp = man.bridges.O1.fp
  local W = SW.new{persist = {manifest = man}}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  local col = {}
  for y = fp[2], fp[5] do col[#col + 1] = '.' end
  SW.draw(W, G, col, 20, fp[2])
  W.o1 = SW.bridge(W, fp, false, 'O1')
  W.lv = SW.lever(W, 25, 22, G, W.o1)
  SW.regroup(W)
  if not nocit then SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}}) end
  W.lock = nil
  W.load(SW.fake('reflex', {holding = function() return W.lock end}))
  W.cells = {}
  W.load(SW.fake('runner', {repair = function(K, cells, why, opts)
    W.cells[#W.cells + 1] = {cells = cells, why = why, peace = type(opts) == 'table' and opts.peace == true,
                             closure = type(opts) == 'table' and opts.closure == true}
    return true, 'rp' .. #W.cells
  end}))
  W.mech = mech
  W.load(SW.fake('economy', {mech_free = function() return W.mech.free end,
                             mech_state = function() return {need = 4, free = W.mech.free, short = math.max(0, 4 - W.mech.free),
                                                              route = W.mech.route} end}))
  package.loaded['dfllm.gate'] = nil
  W.load(require('dfllm.gate'))
  package.loaded['dfllm.seal'] = nil
  W.load(require('dfllm.seal'))
  return W
end

-- DF removes the destroyed building; the footprint is plain floor again
local function destroy(W, fp)
  local b = W.o1
  W.buildings[b.id] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
  local col = {}
  for y = fp[2], fp[5] do col[#col + 1] = '.' end
  SW.draw(W, G, col, 20, fp[2])
  W.o1 = nil
  SW.regroup(W)
end

-- one dragon siege that destroys O1, then quiet PEACE
local function lose(W, man)
  run(W, 300)                                   -- gate sees the bridge complete
  W.K.set_mode('SIEGE', 'test')
  run(W, 200)
  W.add_unit{id = 501, pos = {10, 25, G}, invader = true, race = 'DRAGON'}
  W.set_census('h', {tick = W.K.now().tick, vis = 1, bd = 1, list = {{id = 501, x = 10, y = 25, z = G, bd = 1, dz = 1}}})
  run(W, 100)
  destroy(W, man.bridges.O1.fp)
  run(W, 600)
  W.set_census('h', {tick = W.K.now().tick, vis = 0, bd = 0, list = {}})
  W.K.set_mode('RECOVERY', 'test')
  run(W, 600)
  W.K.set_mode('PEACE', 'test')
  run(W, 400)
end

T.test('BUG-491: the first loss, no stone to make the mechanisms for its levers: replaced by wall + door at once, not rebuilt ' ..
       '(old code: a bridge no lever could ever move)', function()
  local W = fort(MAN, {free = 0, route = 'no stone'})
  lose(W, MAN)
  local ev = evs(W, 'BRIDGE_DESTROYED')
  T.eq(#ev, 1)
  T.eq(ev[1].d.n, 1, 'one loss')
  T.eq(#W.cells, 1, 'one repair queued')
  T.ok(W.cells[1].closure and W.cells[1].peace, 'a peace-only closure, not the bridge')
  T.eq(W.cells[1].cells, {{20, 25, G, 'd'}}, 'a door in place of the gate')
  T.ok(W.cells[1].why:find('replaced by wall + door', 1, true) and W.cells[1].why:find('no stone', 1, true), W.cells[1].why)
  local ok, lost = W.K.call('seal', 'lost_gates')
  T.ok(ok and lost.O1 and lost.O1.n == 1 and lost.O1.cl == 'rp1', 'readiness sees lost:O1 closing: ' .. tostring(lost.O1 and lost.O1.cl))
  local pb = evs(W, 'PERIMETER_BROKEN')
  T.eq(pb[#pb].d.why, 'replaced')
  T.ok(pb[#pb].msg:find('replaced by wall + door at 20,25,9', 1, true), pb[#pb].msg)
end)

T.test('BUG-491: no Mechanics workshop is the same; mechanisms on the way (stone route) are waited for', function()
  local W = fort(MAN, {free = 0, route = 'no Mechanics'})
  lose(W, MAN)
  T.eq(W.cells[1] and W.cells[1].cells, {{20, 25, G, 'd'}}, 'no Mechanics: the door')
  local W2 = fort(MAN, {free = 1, route = 'ordered'})
  lose(W2, MAN)
  T.eq(#W2.cells, 1)
  T.eq(W2.cells[1].cells, {{20, 25, G, 'gw(1x1)'}}, 'mechanisms ordered: the bridge is rebuilt')
  T.ok(not W2.cells[1].closure, 'not a closure')
end)

T.test('BUG-491: enough free mechanisms (4 for 2 levers): rebuilt as before, the first loss', function()
  local W = fort(MAN, {free = 5, route = nil})
  lose(W, MAN)
  T.eq(#W.cells, 1)
  T.eq(W.cells[1].cells, {{20, 25, G, 'gw(1x1)'}})
end)

T.test('BUG-491: mechanisms still short link_wait (10 days) after the loss: the queued rebuild nobody built becomes the closure', function()
  local W = fort(MAN, {free = 1, route = 'stone'})
  W.K.cfg.reflex = nil
  run(W, 300)
  W.K.set_mode('SIEGE', 'test')
  run(W, 200)
  destroy(W, MAN.bridges.O1.fp)
  run(W, 600)
  W.K.set_mode('RECOVERY', 'test')
  run(W, 600)
  W.K.set_mode('PEACE', 'test')
  run(W, 400)
  T.eq(#W.cells, 1, 'the bridge was queued first')
  T.eq(W.cells[1].cells, {{20, 25, G, 'gw(1x1)'}})
  run(W, 12000 + 2400)
  local last = W.cells[#W.cells]
  T.ok(last.closure, 'ten days later the mechanisms are still short: the closure ' .. #W.cells)
  T.eq(last.cells, {{20, 25, G, 'd'}})
end)

T.test('BUG-491: a 3-tile footprint: walls on the flanks and the door between them when their reach is proven; the all-door ' ..
       'closure when the reach check cannot prove it', function()
  local W = fort(MAN3, {free = 0, route = 'no stone'})
  lose(W, MAN3)
  T.eq(#W.cells, 1)
  local c = W.cells[1].cells
  T.eq({#c, c[1][4], c[2][4], c[3][4]}, {3, 'Cw', 'd', 'Cw'}, 'walls and a door: the flood proves nobody is cut off')
  -- no citizen on a walk group: the reach is unknown, so every cell is a door (and it stands when the doors stand)
  local W2 = fort(MAN3, {free = 0, route = 'no stone'}, true)
  lose(W2, MAN3)
  T.eq(#W2.cells, 1)
  local d = W2.cells[1].cells
  T.eq({#d, d[1][4], d[2][4], d[3][4]}, {3, 'd', 'd', 'd'}, 'unproven reach: doors only')
end)

T.done()
