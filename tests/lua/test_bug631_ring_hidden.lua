-- BUG-631 (Run 16 round 19, i1 z125 at two sites 900-1400 days, i2 z132/z135 540 days: the aqshaft ring stayed 'new/new/new/new' and
-- 'the ring has not moved'): the ring tile on the heavy level lies diagonally below the open stair of the dry level above and is HIDDEN until
-- the channel above it is dug, which only the ring step designates. The step waited for both tiles, so it never designated anything.
-- Now the channel needs only the tile above; a hidden tile / a missing quickfort call / too little wall material is NAMED (with the
-- coordinates or the counts) in the stall text, the row and the PROJECT_BLOCKED message.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local STOCK = {have = 20, rock = 20, blocks = 0, logs = 0}
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  STOCK = {have = 20, rock = 20, blocks = 0, logs = 0}
  local W = H.world(opts)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          wall_stock = function() return STOCK end,
          need = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function rt(W) return W.K.persist.get('m.runner') end
local function rec(W, id) return rt(W).aq[id] end
local function until_(W, fn, max)
  for _ = 1, max or 20 do
    if fn() then return true end
    H.runs(W, 1)
  end
  return fn()
end

local AX, AY, AT = 50, 50, 100
local function shaft_doc(depth)
  local stages = {}
  for i = 0, depth - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0,
          params = {x = AX, y = AY, top = AT, dry_levels = 2, depth = depth, mode = 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end
local function know_heavy(W, z)
  rt(W).dz = {{pos = {AX + 20, AY, z}, why = 'heavy_aquifer', proj = 'oldcore', tpl = 'fortcore', t = 0}}
end
local function start(W)
  H.place(W, 'aq', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)
  until_(W, function() return rec(W, 'aq').levels['99'] ~= nil end, 6)
  H.runs(W, 1)
end
local function blocked(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.why == why then r[#r + 1] = e end end
  return r
end
local CFGQ = {baseline = {v = 2, runner = {queue = {idle_days = 5, stall_days = 10, stall_every = 5}}}}

T.test('BUG-631: the hidden ring tile on the heavy level does not stop the channel above it (the first piece leaves "new")', function()
  local W = fresh{tag = 'b631hid', cfg = CFGQ}
  know_heavy(W, 99)
  for _, o in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do W.tile(AX + o[1], AY + o[2], 99).hidden = true end
  start(W)
  T.eq(W.tile(AX + 1, AY, 100).dig, 'h', 'the channel is designated on the revealed tile above')
  T.eq(rec(W, 'aq').levels['99'].ring.pieces[1][3], 'chan', 'piece 1 left new')
  -- the miner digs the channel; the tile below is hidden still: the step waits and says which tile
  H.dig(W)
  for _ = 1, 2 * 6 do H.runs(W, 1) end
  local ev = blocked(W, 'aq_stall:ring_stuck')
  T.eq(#ev, 1, T.show(W.find_events('PROJECT_BLOCKED')))
  T.ok(ev[1].msg:find('the ramp 51,50,99 below the dug channel is hidden', 1, true), ev[1].msg)
  T.ok(AQ.stall_text(rt(W), 'aq'):find('51,50,99', 1, true), AQ.stall_text(rt(W), 'aq'))
  -- the ramp shows: the ring goes on with the wall
  W.tile(AX + 1, AY, 99).hidden, W.tile(AX + 1, AY, 99).c = nil, '_'
  T.ok(until_(W, function() return rec(W, 'aq').levels['99'].ring.pieces[1][3] ~= 'chan' end, 6), 'the ring moves on')
end)

T.test('BUG-631: a hidden channel tile is named with its coordinates', function()
  local W = fresh{tag = 'b631top', cfg = CFGQ}
  know_heavy(W, 99)
  start(W)
  W.tile(AX + 1, AY, AT).hidden = true
  for _ = 1, 2 * 6 do H.runs(W, 1) end
  local ev = blocked(W, 'aq_stall:ring_stuck')
  T.eq(#ev, 1, T.show(W.find_events('PROJECT_BLOCKED')))
  T.ok(ev[1].msg:find('channel tile 51,50,100 is hidden', 1, true), ev[1].msg)
  T.ok(rec(W, 'aq').levels['99'].ring.wait:find('51,50,100', 1, true), T.show(rec(W, 'aq').levels['99'].ring))
end)

T.test('BUG-631: no wall material names the counts (blocks, boulders, logs), logs alone are enough walls', function()
  local W = fresh{tag = 'b631mat', cfg = CFGQ}
  know_heavy(W, 99)
  STOCK.have, STOCK.rock, STOCK.blocks, STOCK.logs = 2, 0, 0, 2
  start(W)
  local ev = blocked(W, 'aq_stall:no_boulders')
  T.eq(#ev, 1, T.show(W.find_events('PROJECT_BLOCKED')))
  T.ok(ev[1].msg:find('2 of 6 walls: 0 blocks, 0 free boulders, 2 logs reachable', 1, true), ev[1].msg)
  T.ok(AQ.stall_text(rt(W), 'aq'):find('2 logs reachable', 1, true), AQ.stall_text(rt(W), 'aq'))
  STOCK.have, STOCK.logs = 8, 8                         -- eight logs and nothing else: a ring of wooden walls
  T.ok(until_(W, function() return W.tile(AX + 1, AY, 100).dig == 'h' end, 8), 'the ring starts on logs alone')
  T.eq(AQ.stall_text(rt(W), 'aq'), '', 'the stall is cleared')
end)

T.done()
