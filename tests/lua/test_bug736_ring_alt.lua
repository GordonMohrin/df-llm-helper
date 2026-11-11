-- BUG-736 (Run 16c i3 Doorwings: ring wall z140 'unbuilt for 31-32 d', 385 logs, stone 0): once a ring wall waited ring_wait with material counted, the
-- kernel asks economy.wall_alt (logs / ore / flux) and the stall text names it; ore / flux boulders count as the last-resort wall material in
-- plug_missing (no 'no_boulders' stall for them); blocks held by jobs / on another walk group are named in the no_boulders text. A constructed
-- ring wall of ANY material ends the ring stage (the state machine reads the tile's construction state `C`, never its material).
-- (harness of test_bug677) BUG-677 (Run 16c i3 Wallfree y400-y404: four shafts each stopped after the heavy layer's ring wall stood unbuilt for 2 d; the fort had only
-- claystone, 121 of 200 orders 'Needs non-economic hard stone'): a ring wall that waits for MATERIAL is given ring_stop_mat (longer than
-- ring_stop), the stall names the missing stone, the stop (AQ_RING_STOP, block ring_nostone, final) says NO STONE instead of 'the ring has
-- not moved'. (economy.wall_stock / stone_none: test_bug665_668_stone_wood.lua.)
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local STOCK
local ALT_CALLS = 0
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  AQ.CFG.ring_stop, AQ.CFG.ring_stop_mat = 5 * AQ.CFG.ring_wait, 10 * AQ.CFG.ring_wait      -- 10 d and 20 d
  STOCK = {have = 20, rock = 20, blocks = 0, logs = 0}
  local W = H.world(opts)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          wall_stock = function() return STOCK end,
          wall_alt = function() ALT_CALLS = ALT_CALLS + 1; return 'no free stone and no free block: the walls are built of logs (385 reachable)' end,
          need = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function rt(W) return W.K.persist.get('m.runner') end
local function rec(W, id) return rt(W).aq[id] end
local function ev(W, t) return W.find_events(t) end
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
local function key(x, y, z) return x .. ',' .. y .. ',' .. z end
local function start_wall(W)
  rt(W).dz = {{pos = {AX + 20, AY, 99}, why = 'heavy_aquifer', proj = 'oldcore', tpl = 'fortcore', t = 0}}
  H.place(W, 'aq', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)
  until_(W, function() return rec(W, 'aq').levels['99'] ~= nil end, 6)
  H.runs(W, 1)
  H.dig(W)
  W.tile(AX + 1, AY, 99).c = '_'
  H.runs(W, 1)
  T.ok(W.bld_at[key(AX + 1, AY, 99)], 'the wall is designated')
end


T.test('BUG-736: a ring wall waiting past ring_wait asks wall_alt and the stall names the log wall', function()
  local W = fresh{tag = 'b736a'}
  ALT_CALLS = 0
  start_wall(W)
  H.runs(W, 2 * 3)                                              -- 3 d: past ring_wait (2 d)
  T.ok(ALT_CALLS >= 1, 'wall_alt asked')
  local st = rec(W, 'aq').levels['99'].stall
  T.ok(st ~= nil and T.show(st):find('built of logs', 1, true), T.show(st))
end)

T.test('BUG-736: ore / flux boulders only (have 0, alt 12): the walls are possible, no no_boulders stall', function()
  local W = fresh{tag = 'b736b'}
  start_wall(W)
  STOCK.have, STOCK.rock, STOCK.logs, STOCK.alt, STOCK.none = 0, 0, 0, 12, true
  H.runs(W, 2 * 3)
  local st = rec(W, 'aq').levels['99'].stall
  T.ok(not (st and st.why == 'no_boulders'), T.show(st))
end)

T.test('BUG-736: blocks held by jobs / far are named in the no_boulders text', function()
  local W = fresh{tag = 'b736c'}
  start_wall(W)
  STOCK.have, STOCK.rock, STOCK.logs, STOCK.alt, STOCK.busy, STOCK.far = 0, 0, 0, 0, 132, 4
  H.runs(W, 2 * 3)
  local txt = AQ.stall_text(rt(W), 'aq')
  local st = rec(W, 'aq').levels['99'].stall
  T.ok(st and st.why == 'no_boulders', T.show(st))
  T.ok(T.show(st):find('132 blocks held by jobs', 1, true) or txt:find('132 blocks held by jobs', 1, true), T.show(st) .. ' / ' .. txt)
end)

T.test('BUG-736: a wall of any material that stands ends the ring stage (the logic reads the tile, not the material)', function()
  local W = fresh{tag = 'b736d'}
  start_wall(W)
  W.tile(AX + 1, AY, 99).c = 'C'                                  -- built (here: of logs)
  H.runs(W, 2)
  T.eq(rec(W, 'aq').levels['99'].ring.pieces[1][3], 'done')
  T.eq(#ev(W, 'AQ_RING_STOP'), 0)
end)

T.done()
