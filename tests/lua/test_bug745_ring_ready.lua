-- BUG-745 (Run 16c i3 Doorwings y392, 7th aqshaft at z140: the ring tile was channelled open into the heavy layer while buildingplan still took
-- boulders (stone free 0), the wall waited 2 d, wall_alt switched to logs only then, the water came first; six shafts before it the same way):
-- no ring tile is channelled until its wall can be built at once: wall material counted for every missing wall, the material route resolved
-- (wall_alt) BEFORE the channel, a citizen with the construction labor. Else the level stalls with nothing open.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local STOCK, BUILDERS, ORDER
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  STOCK, BUILDERS, ORDER = {have = 20, rock = 20, blocks = 0, logs = 0}, 3, {}
  local W = H.world(opts)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          wall_stock = function() return STOCK end,
          wall_builders = function() return BUILDERS end,
          wall_alt = function() ORDER[#ORDER + 1] = 'alt'; return 'the walls are built of logs' end,
          need = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function rt(W) return W.K.persist.get('m.runner') end
local function rec(W, id) return rt(W).aq[id] end
local function key(x, y, z) return x .. ',' .. y .. ',' .. z end
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
-- the shaft stands on z100 with z99 known heavy: the ring of z99 starts
local function start(W)
  rt(W).dz = {{pos = {AX + 20, AY, 99}, why = 'heavy_aquifer', proj = 'oldcore', tpl = 'fortcore', t = 0}}
  H.place(W, 'aq', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)
  for _ = 1, 6 do
    if rec(W, 'aq').levels['99'] ~= nil then break end
    H.runs(W, 1)
  end
  H.runs(W, 1)
  H.dig(W)
end
local function channels(W)
  local n = 0
  for _, o in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
    local t = W.tile(AX + o[1], AY + o[2], 100)
    if t and t.c ~= '#' then n = n + 1 end
  end
  return n
end

T.test('BUG-745: the wall route is resolved (wall_alt) before the first channel, with builders and material', function()
  local W = fresh{tag = 'b745a'}
  start(W)
  H.runs(W, 2)
  T.ok(#ORDER >= 1, 'wall_alt asked before anything was open')
  local R = rec(W, 'aq').levels['99'].ring
  T.ok(R ~= nil and R.pieces[1][3] ~= 'new', 'the first channel is designated: ' .. T.show(R))
end)

T.test('BUG-745: no citizen with the construction labor: nothing is channelled, the stall names it', function()
  local W = fresh{tag = 'b745b'}
  BUILDERS = 0
  start(W)
  H.runs(W, 3)
  local L = rec(W, 'aq').levels['99']
  T.ok(L.ring ~= nil, 'the ring started')
  for _, pc in ipairs(L.ring.pieces) do T.eq(pc[3], 'new') end
  T.ok(L.stall ~= nil and L.stall.why == 'ring_builder', T.show(L.stall))
  T.eq(#W.find_events('AQ_HEAVY'), 0)
  BUILDERS = 2                                                  -- a builder appears: the ring goes on
  H.runs(W, 3)
  T.ok(rec(W, 'aq').levels['99'].ring.pieces[1][3] ~= 'new', 'channel designated now')
  local st2 = rec(W, 'aq').levels['99'].stall
  T.ok(st2 == nil or st2.why ~= 'ring_builder', 'stall cleared: ' .. T.show(rec(W, 'aq').levels['99'].stall))
end)

T.test('BUG-745: material for the missing walls lacking: nothing is channelled (no_boulders), not even the first tile', function()
  local W = fresh{tag = 'b745c'}
  STOCK.have, STOCK.rock, STOCK.logs, STOCK.alt = 0, 0, 0, 0
  start(W)
  H.runs(W, 3)
  local L = rec(W, 'aq').levels['99']
  if L.ring then for _, pc in ipairs(L.ring.pieces) do T.eq(pc[3], 'new') end end
  T.ok(L.stall ~= nil and L.stall.why == 'no_boulders', T.show(L.stall))
end)

T.test('BUG-745: unknown builder count (nil) does not block (older economy / mock)', function()
  local W = fresh{tag = 'b745d'}
  BUILDERS = nil
  start(W)
  H.runs(W, 2)
  local L = rec(W, 'aq').levels['99']
  T.ok(L.ring ~= nil and L.ring.pieces[1][3] ~= 'new', T.show(L.ring))
end)

T.done()
