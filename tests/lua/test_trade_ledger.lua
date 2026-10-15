-- trade FR-32 (ledger), FR-18 (inspect what=trade: merchant goods at the depot) and FR-43 (DEPOT_MISSING, the
-- runner's depot keeper), on k_mock with tests/lua/trade_world.lua and tests/lua/runner_world.lua.
local T = require('testlib')
local F = require('trade_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local L = fresh('trade').lib

T.test('ledger: sold and bought by type, unmet wants with none / value / part', function()
  local want = L.tokens({'bar:iron', 'anvil', 'cloth', 'leather'})
  local buys = {{i = 0, k = 1, value = 100, stack = 5, t = 'BAR'}, {i = 1, k = 2, value = 300, stack = 1, t = 'ANVIL'},
                {i = 2, k = 3, value = 60, stack = 1, t = 'CLOTH'}, {i = 3, k = 3, value = 60, stack = 1, t = 'CLOTH'}}
  local sells = {{i = 0, value = 200, stack = 1, t = 'FIGURINE'}, {i = 1, value = 150, stack = 1, t = 'FIGURINE'},
                 {i = 2, value = 40, stack = 3, t = 'AMULET'}}
  local lg = L.ledger(want, buys, sells, {buy = {0, 2}, sell = {0, 2}})
  T.eq(lg.sold, {{'FIGURINE', 1, 200}, {'AMULET', 3, 40}})
  T.eq({lg.sold_n, lg.sold_v, lg.bought_n, lg.bought_v}, {4, 240, 6, 160})
  T.eq(lg.bought, {{'bar:iron', 'BAR', 5, 100}, {'cloth', 'CLOTH', 1, 60}})
  T.eq(lg.unmet, {{'anvil', 'value'}, {'cloth', 'part'}, {'leather', 'none'}}, 'cloth: 1 of the 2 the merchants had')
end)

T.test('ledger: a partly served want is "part"; nothing marked leaves every want unmet', function()
  local want = L.tokens({'cloth'})
  local buys = {{i = 0, k = 1, value = 60, stack = 1, t = 'CLOTH'}, {i = 1, k = 1, value = 60, stack = 1, t = 'CLOTH'}}
  T.eq(L.ledger(want, buys, {}, {buy = {0}, sell = {}}).unmet, {{'cloth', 'part'}})
  T.eq(L.ledger(want, buys, {}, nil).unmet, {{'cloth', 'value'}})
end)

T.test('token_for: the want token naming a merchant good', function()
  T.eq(L.token_for('BAR', 'inorganic:iron', 'iron bars'), 'bar:iron')
  T.eq(L.token_for('BAR', 'inorganic:pig_iron', 'pig iron bars'), 'bar:pig_iron')
  T.eq(L.token_for('WEAPON', 'inorganic:iron', 'iron pick'), 'pick')
  T.eq(L.token_for('WEAPON', 'inorganic:copper', 'copper short sword'), 'weapon')
  T.eq(L.token_for('AMMO', 'inorganic:copper', 'copper bolts'), 'bolts')
  T.eq(L.token_for('ANVIL', 'inorganic:iron', 'iron anvil'), 'anvil')
  T.eq(L.token_for('SKIN_TANNED', 'creature:cow:leather', 'cow leather'), 'leather')
  T.eq(L.token_for('SPLINT', '', 'splint'), 'splint')
end)

---------------------------------------------------------------- flow on k_mock (as tests/lua/test_trade.lua)
local function std_goods(W)
  return {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5}),
          F.item(W, {type = 'ANVIL', mat = 'INORGANIC:IRON', desc = 'iron anvil', value = 300}),
          F.item(W, {type = 'CLOTH', mat = 'CREATURE:SPIDER_CAVE_GIANT:SILK', desc = 'giant cave spider silk cloth', value = 60}),
          F.item(W, {type = 'FIGURINE', mat = 'INORGANIC:GOLD', desc = 'gold figurine', value = 500})}
end
local function std_ours()
  local r = {}
  for _, v in ipairs({200, 150, 120, 90, 80, 60, 50, 40, 30, 20}) do r[#r + 1] = {type = 'FIGURINE', value = v} end
  return r
end
local function setup(o)
  o = o or {}
  local W = F.world{mode = o.mode}
  local d = not o.no_depot and F.depot(W, {}) or nil
  local c = F.caravan(W, {state = 'Approaching', tr = 1500, goods = std_goods(W)})
  if d then F.goods(W, d, std_ours()) end
  W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}
  local U = d and F.ui(W, d, c, o.ui) or nil
  if o.before_load then o.before_load(W, d, c) end
  W.load(fresh('trade'))
  return W, d, c, U
end
local function to_depot(W, d, c)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(900, {skip = 9})
end

T.test('FR-32: a trade logs TRADE_LEDGER (sold, bought, unmet) and keeps it for inspect what=trade', function()
  local W, d, c = setup()
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'traded') > 0 end, 600), 'traded')
  local ev = W.find_events('TRADE_LEDGER')
  T.eq(#ev, 1)
  local e = ev[1].d
  T.eq({e.ok, e.sold > 0, e.bought, e.civ}, {1, true, 6, 'The Merchant Guild'})
  T.eq(e.unmet, {'anvil:value'}, 'the anvil did not fit the value of our goods')
  local lg = W.K.persist.get('m.trade').ledger
  T.eq(#lg, 1)
  T.eq(lg[1].bought, {{'bar:iron', 'BAR', 5, 100}, {'cloth', 'CLOTH', 1, 60}})
  local r = W.inbox('inspect', {what = 'trade'})
  T.eq(r.ok, true, r.msg)
  T.eq(r.data.ledger[1].civ, 'The Merchant Guild')
  T.eq(r.data.want, {'bar:iron', 'anvil', 'cloth'})
end)

T.test('FR-32: a visit that fails logs every want as unmet with the reason', function()
  local W, d, c = setup{ui = {accept = 50}}
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'retry') > 0 end, 1500), 'retry')
  W.run(1300, {skip = 9})                      -- RETRY_WAIT
  T.ok(F.until_(W, function() return #F.events(W, 'failed') > 0 end, 2000), 'failed')
  local ev = W.find_events('TRADE_LEDGER')
  T.eq(#ev, 1, 'the retry logs nothing, the final failure once')
  T.eq(ev[1].d.ok, 0)
  T.eq(ev[1].d.unmet, {'bar:iron:refused', 'anvil:refused', 'cloth:refused'})
end)

T.test('FR-18: inspect what=trade lists the merchant goods at the depot with their want tokens', function()
  local W, d, c = setup()
  local r0 = W.inbox('inspect', {what = 'trade'})
  T.eq({r0.ok, r0.msg, #r0.data.goods}, {true, 'caravan not at the depot yet', 0}, 'nothing before the depot is open')
  F.set_state(c, 'AtDepot')
  for _, it in ipairs(c._items) do d.contained_items:insert('#', {item = it}) end   -- unloaded into the depot
  local r = W.inbox('inspect', {what = 'trade'})
  T.eq(r.ok, true, r.msg)
  T.eq(r.data.goods_items, 4)
  local by = {}
  for _, g in ipairs(r.data.goods) do by[g.token] = g end
  T.eq({by['bar:iron'].n, by['bar:iron'].value, by.anvil.n}, {5, 100, 1})
  T.eq(r.data.goods[1].type, 'FIGURINE', 'most valuable first')
  T.eq(r.data.caravans[1].state, 'AtDepot')
end)

T.test('FR-43: a caravan without a built depot raises DEPOT_MISSING (A) once and asks the runner for one', function()
  local calls = {}
  local W = F.world{}
  F.caravan(W, {state = 'Approaching', tr = 1500, goods = std_goods(W)})
  W.load({name = 'runner', every = {ticks = 600},
          depot_keep = function(K, why) calls[#calls + 1] = why; return true, 'depot1' end})
  W.load(fresh('trade'))
  W.run(300, {skip = 9})
  local ev = W.find_events('DEPOT_MISSING')
  T.eq(#ev, 1)
  T.eq({ev[1].cls, ev[1].d.proj, ev[1].d.planned, ev[1].d.civ}, {'A', 'depot1', 0, 'The Merchant Guild'})
  T.eq(calls, {'caravan'})
  W.run(600, {skip = 9})
  T.eq(#W.find_events('DEPOT_MISSING'), 1, 'once per visit')
end)

---------------------------------------------------------------- the runner's depot keeper
local H = require('runner_world')
local runner = require('dfllm.runner')

T.test('FR-43: the runner queues a 5x5 depot at manifest.depot when none stands; one project at a time', function()
  local W = H.world{tag = 'depot', persist = {manifest = {v = 2, depot = {60, 40, 100}}}}
  df.global.world.buildings.other.TRADE_DEPOT = kmock.vec{}
  W.load(runner)
  W.run(700, {skip = 9})
  local P = H.proj(W, 'depot1')
  T.ok(P, 'project depot1')
  T.eq({P.tpl, P.class, P.prio}, {'depot', 'infra', 2})
  local doc = W.K.persist.get('bp.depot1')
  T.eq(doc.stages[1].chunks[1], {pos = {58, 38, 100}, cells = {{0, 0, 0, 'D(5x5)'}}})
  local ok, ok2, res = W.K.call('runner', 'depot_keep', 'caravan')
  T.eq({ok, ok2, res}, {true, true, 'depot1'}, 'one project at a time')
  W.set_mode('SIEGE')
  T.eq({select(2, W.K.call('runner', 'depot_keep', 'x'))}, {false, 'not in SIEGE'})
end)

T.test('FR-43: a standing depot is remembered and rebuilt there when the manifest has none', function()
  local W = H.world{tag = 'depot2'}
  local dep = {centerx = 30, centery = 31, z = 99}
  df.global.world.buildings.other.TRADE_DEPOT = kmock.vec{dep}
  W.load(runner)
  W.run(700, {skip = 9})
  T.eq(H.proj(W, 'depot1'), nil)
  T.eq({select(2, W.K.call('runner', 'depot_keep', 'x'))}, {true, 'standing'})
  df.global.world.buildings.other.TRADE_DEPOT:erase(0)                -- razed by a siege
  T.eq({select(2, W.K.call('runner', 'depot_keep', 'x'))}, {true, 'depot1'})
  T.eq(W.K.persist.get('bp.depot1').stages[1].chunks[1].pos, {28, 29, 99})
end)

T.done()
