-- BUG-677 (Run 16c i3 Wallfree y400-y404: four shafts each stopped after the heavy layer's ring wall stood unbuilt for 2 d; the fort had only
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
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  AQ.CFG.ring_stop, AQ.CFG.ring_stop_mat = 5 * AQ.CFG.ring_wait, 10 * AQ.CFG.ring_wait      -- 10 d and 20 d
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

T.test('BUG-677: a wall that waits for MATERIAL outlives ring_stop and stops at ring_stop_mat, naming the missing stone', function()
  local W = fresh{tag = 'b677mat'}
  start_wall(W)
  STOCK.have, STOCK.rock, STOCK.none = 0, 0, true               -- the fort turns out to have no stone a job may take
  H.runs(W, 2 * 14)                                              -- 14 d: past ring_stop (10 d), short of ring_stop_mat (20 d)
  T.eq(#ev(W, 'AQ_RING_STOP'), 0, 'the material is missing: the wall is given longer')
  local st = rec(W, 'aq').levels['99'].stall
  T.ok(st and st.why == 'no_boulders', T.show(st))
  T.ok(AQ.stall_text(rt(W), 'aq'):find('no stone a job may take', 1, true), AQ.stall_text(rt(W), 'aq'))
  H.runs(W, 2 * 10)                                              -- 24 d
  local stops = ev(W, 'AQ_RING_STOP')
  T.eq(#stops, 1, T.show(ev(W, 'PROJECT_BLOCKED')))
  T.eq(stops[1].d.miss, 'no_boulders')
  T.ok(stops[1].msg:find('NO STONE', 1, true) and not stops[1].msg:find('has not moved', 1, true), stops[1].msg)
  T.ok(stops[1].d.cmd:find('trade.want', 1, true), stops[1].d.cmd)
  T.eq(H.proj(W, 'aq').blocked, 'ring_nostone')
  T.eq(#ev(W, 'AQ_HEAVY'), 0)
end)

T.test('BUG-677: a wall the builders just have not taken (material there) stops at ring_stop, as before', function()
  local W = fresh{tag = 'b677time'}
  start_wall(W)
  H.runs(W, 2 * 14)
  local stops = ev(W, 'AQ_RING_STOP')
  T.eq(#stops, 1, T.show(ev(W, 'PROJECT_BLOCKED')))
  T.eq(stops[1].d.miss, nil)
  T.eq(H.proj(W, 'aq').blocked, 'ring_wall')
end)

T.done()
