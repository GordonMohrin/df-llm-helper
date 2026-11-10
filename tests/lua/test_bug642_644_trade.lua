-- BUG-642..644 (Round 41, trade): the stale Leaving caravan (Run 16c i3 Wallfree y376-y389), the sell tokens the nothing_to_sell text names
-- (Run 16a i1 Basementflew y457), the value gap of a wanted metal armor (Run 16d i4 Trumpetrealms y432). Every test fails before.
local T = require('testlib')
local F = require('trade_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local M0 = fresh('trade')
local L, CFG = M0.lib, M0.CFG

local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {30, 5, 10, 32, 5, 10}, levers = {{35, 8, 10}}},
                               B1 = {role = 'inner', fp = {30, 15, 10, 32, 15, 10}, levers = {{35, 18, 10}}}}}
local function plan_want(want, sell)
  return {v = 2, year = 3, phase_target = 'P4', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
          policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}, trade = {want = want, sell = sell or {}}}
end
local function std_goods(W)
  return {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5}),
          F.item(W, {type = 'CLOTH', mat = 'CREATURE:SPIDER_CAVE_GIANT:SILK', desc = 'giant cave spider silk cloth', value = 60})}
end
local function count_runs(W)
  local n = 0
  for _, a in ipairs(F.calls(W, 'run')) do if a.args[1] == 'fix/stuck-merchants' then n = n + 1 end end
  return n
end

---------------------------------------------------------------- BUG-642: a caravan listed Leaving for years
local function stale_world(o)
  o = o or {}
  local W = F.world{persist = o.persist, plan = o.plan}
  local d = F.depot(W, {})
  if o.gate then F.gate(W) end
  local c = F.caravan(W, {state = 'Leaving', tr = 0, goods = {}})
  W.add_unit{id = 700, pos = {5, 5, 10}, merchant = true, civ_id = 7}           -- on the map, ownerless
  W.add_unit{id = 701, pos = {6, 6, 10}, merchant = true, civ_id = 7, offmap = true}
  W.add_unit{id = 702, pos = {7, 7, 10}, merchant = true, civ_id = 9}           -- another civ's
  local S = fresh('sense')
  W.load({name = 'sense', every = {ticks = 100000}, merchants = function(K, civ) return S.merchants(K, civ) end})
  W.load(fresh('trade'))
  return W, d, c
end

T.test('BUG-642: a caravan Leaving for LEAVE_STALE ticks is said once, fix/stuck-merchants runs, the visit is over', function()
  local W, d, c = stale_world()
  W.frame(1)
  T.eq(W.state().trade.caravan, 1, 'a fresh Leaving caravan is on the map')
  W.run(CFG.LEAVE_STALE - 1000, {skip = 10})
  T.eq(#F.events(W, 'stale'), 0)
  T.eq(count_runs(W), 0)
  W.run(2000, {skip = 10})
  local ev = F.events(W, 'stale')
  T.eq(#ev, 1)
  T.eq(count_runs(W), 1)
  T.ok(ev[1].msg:find('1 merchants on the map', 1, true) and ev[1].msg:find('700', 1, true), ev[1].msg)
  T.ok(ev[1].msg:find('1 off it', 1, true), 'the flagged one off the map is counted: ' .. ev[1].msg)
  local dec
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'caravan_stale' then dec = e end end
  T.ok(dec and dec.d.n == 1 and dec.d.q:find('squad.sortie', 1, true), dec and dec.d.q or 'no decision')
  T.eq(W.state().trade.caravan, 0, 'no caravan on the map for the gate and the supervisor')
  T.eq(W.state().trade.stale, 1)
  W.run(9000, {skip = 10})
  T.eq(#F.events(W, 'stale'), 1, 'once per visit')
  T.eq(count_runs(W), 1)
  F.remove_caravans()
  W.run(300, {skip = 10})
  T.eq(#F.events(W, 'left'), 1)
  T.eq(W.state().trade.stale, nil)
end)

T.test('BUG-642: a stale Leaving caravan opens no O1 window', function()
  local W = stale_world({persist = {manifest = MAN}, gate = true})
  W.bridge_state.O1 = 'up'
  W.set_census('h', {tick = W.K.now().tick, vis = 0})
  W.frame(1)
  W.run(100, {skip = 9})
  T.eq(W.gate_wants, {{'O1', 'down', 'trade'}}, 'a fresh Leaving caravan still gets its window')
  for _ = 1, CFG.LEAVE_STALE // 250 + 8 do W.set_census('h', {tick = W.K.now().tick, vis = 0}); W.run(250, {skip = 10}) end   -- BUG-670: relative
  T.eq(#F.events(W, 'stale'), 1)
  local n = #W.gate_wants
  W.bridge_state.O1 = 'up'
  for _ = 1, 20 do W.set_census('h', {tick = W.K.now().tick, vis = 0}); W.run(250, {skip = 10}) end
  T.eq(#W.gate_wants, n, 'no further window for the stale caravan')
end)

T.test('BUG-642: the phase of a traded visit ends when its caravan goes stale, the next caravan trades', function()
  local W = F.world{plan = plan_want({'cloth'}, {'crafts'})}
  local d = F.depot(W, {})
  local c = F.caravan(W, {state = 'Approaching', tr = 1500, goods = std_goods(W)})
  F.goods(W, d, {{type = 'FIGURINE', value = 200}, {type = 'FIGURINE', value = 150}})
  W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}
  F.ui(W, d, c, {})
  W.load(fresh('trade'))
  local e = W.mods.trade
  W.frame(1)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(900, {skip = 9})
  T.ok(F.until_(W, function() return #F.events(W, 'traded') > 0 end, 1500), 'traded')
  F.set_state(c, 'Leaving')
  c.time_remaining = 0
  W.run(CFG.LEAVE_STALE + 600, {skip = 10})
  T.eq(#F.events(W, 'stale'), 1)
  -- a caravan of another civ arrives while the first one is still listed
  local c2 = F.caravan(W, {entity = 8, civ = 'Other Civ', state = 'Approaching', tr = 1500, goods = std_goods(W)})
  W.run(400, {skip = 9})
  T.ok(e.boost and e.boost.why:find('approaching', 1, true), 'the module began the second visit: ' .. tostring(e.boost and e.boost.why))
end)

T.test('BUG-642: no caravan for OVERDUE_TICKS is said once a period with the access of the depot', function()
  local W = F.world{}
  F.depot(W, {})
  W.load({name = 'seal', every = {ticks = 100000},
          depot_access = function() return {known = true, depots = 1, ok = false, cut = 1, main = true, age = 10} end})
  W.load(fresh('trade'))
  W.frame(1)
  W.run(CFG.OVERDUE_TICKS - 5000, {skip = 400})
  T.eq(#F.events(W, 'overdue'), 0)
  W.run(8000, {skip = 400})
  local ev = F.events(W, 'overdue')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('NO depot shares a walk group', 1, true), ev[1].msg)
  W.run(100000, {skip = 400})
  T.eq(#F.events(W, 'overdue'), 1, 'once per period')
end)

---------------------------------------------------------------- BUG-643: sell tokens
T.test('BUG-643: backpack / flask / quiver / clothing / junk are sell tokens, sell_name names the token of an item type', function()
  T.eq({L.sell_name('BACKPACK'), L.sell_name('FLASK'), L.sell_name('PANTS'), L.sell_name('QUIVER')}, {'backpack', 'flask', 'pants', 'quiver'})
  T.eq({L.sell_name('FIGURINE'), L.sell_name('GOBLET'), L.sell_name('TOOL'), L.sell_name('FOOD'), L.sell_name('SKIN_TANNED')},
       {'crafts', 'crafts', 'tool', 'meal', 'leather'})
  for _, name in ipairs({'backpack', 'backpacks', 'flask', 'quiver', 'clothing', 'junk'}) do
    T.ok(L.token(name) and L.valid(name), name)
  end
  local junk = L.token('junk')
  for _, ty in ipairs({'BACKPACK', 'FLASK', 'QUIVER', 'PANTS', 'SHOES', 'GLOVES'}) do T.ok(L.match(junk, {type = ty, mat = '', desc = ''}), ty) end
  T.ok(not L.match(junk, {type = 'ARMOR', mat = '', desc = ''}) and not L.match(junk, {type = 'SPLINT', mat = '', desc = ''}))
  T.ok(L.match(L.token('clothing'), {type = 'SHOES', mat = '', desc = ''}) and not L.match(L.token('clothing'), {type = 'FLASK', mat = '', desc = ''}))
end)

local function setup(o)
  local W = F.world{plan = o.plan}
  local d = F.depot(W, {})
  local c = F.caravan(W, {state = 'Approaching', tr = 1500, goods = o.goods and o.goods(W) or std_goods(W)})
  F.goods(W, d, o.ours)
  W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}
  local U = F.ui(W, d, c, o.ui)
  local M = fresh('trade')
  for k, v in pairs(o.cfg or {}) do M.CFG[k] = v end
  W.load(M)
  return W, d, c, U
end
local function to_depot(W, d, c)
  W.frame(1)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(900, {skip = 9})
end

T.test('BUG-643: nothing_to_sell names the sell tokens of the types it leaves out (log line and ledger)', function()
  local W, d, c = setup{plan = plan_want({'cloth'}, {'ring'}), ours = {
    {type = 'TOOL', value = 200}, {type = 'TOOL', value = 210}, {type = 'SPLINT', value = 150}, {type = 'TOOL', value = 3}}}
  to_depot(W, d, c)
  F.until_(W, function() return #F.events(W, 'failed') > 0 end, 600)
  T.eq(F.events(W, 'failed')[1].d.why, 'nothing_to_sell')
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('trade: nothing to sell: 4 of ours', 1, true) then said = l.msg end end
  T.ok(said and said:find('off the sell list: 2 tool, 1 splint', 1, true), said or 'no log line')
  local led
  for _, e in ipairs(W.find_events('TRADE_LEDGER')) do led = e end
  T.ok(led and table.concat(led.d.unmet, ' '):find('nothing_to_sell[value=1,kind=3(tool2+splint1)]', 1, true), led and T.show(led.d.unmet) or 'no ledger')
end)

T.test('BUG-643: items of the craft / gear types the list leaves out are named by their token, crafts counted together', function()
  local W, d, c = setup{cfg = {EXTRA = false}, plan = plan_want({'cloth'}, {'ring'}), ours = {
    {type = 'BACKPACK', value = 20}, {type = 'BACKPACK', value = 20}, {type = 'FLASK', value = 20}, {type = 'FIGURINE', value = 30},
    {type = 'GOBLET', value = 30}, {type = 'PANTS', value = 20}}}
  to_depot(W, d, c)
  F.until_(W, function() return #F.events(W, 'failed') > 0 end, 600)
  local led
  for _, e in ipairs(W.find_events('TRADE_LEDGER')) do led = e end
  T.ok(led and table.concat(led.d.unmet, ' '):find('kind=6(backpack2+crafts2+flask1)', 1, true), led and T.show(led.d.unmet) or 'no ledger')
end)

---------------------------------------------------------------- BUG-644: sell more when a wanted good costs more than the sale value
T.test('BUG-644: gaps names the sale value a want needs against the pool', function()
  local want = L.tokens({'armor:metal', 'cloth'})
  local fac = {ratio = 1.5, margin = 0.10, buy = 1.35, sell = 1.0}
  local buys = {{i = 0, k = 1, value = 400, stack = 1}, {i = 1, k = 1, value = 600, stack = 1}, {i = 2, k = 2, value = 20, stack = 1}}
  local g = L.gaps(buys, {{value = 150}, {value = 131}}, want, fac)
  T.eq(g['armor:metal'], {need = 891, pool = 281})
  T.eq(g.cloth, nil, 'the cloth fits')
  T.eq(next(L.gaps(buys, {{value = 2000}}, want, fac)), nil, 'a rich pool has no gap')
end)

local ARMOR_PLAN = plan_want({'armor:metal'}, {'crafts'})
local function armor_goods(W)
  return {F.item(W, {type = 'ARMOR', mat = 'INORGANIC:IRON', desc = 'iron breastplate', value = 400})}
end

T.test('BUG-644: a metal armor beyond the crafts is paid with the spare backpacks / flasks at the depot, the kinds are learned', function()
  local ours = {{type = 'FIGURINE', value = 60}, {type = 'FIGURINE', value = 60}}
  for _ = 1, 6 do ours[#ours + 1] = {type = 'BACKPACK', value = 150} end
  for _ = 1, 4 do ours[#ours + 1] = {type = 'FLASK', value = 40} end
  local W, d, c, U = setup{plan = ARMOR_PLAN, goods = armor_goods, ours = ours}
  to_depot(W, d, c)
  local okt = F.until_(W, function() return #F.events(W, 'traded') > 0 end, 1500)
  if not okt then
    local tl = {}
    for _, l in ipairs(W.logs) do if l.msg:find('trade', 1, true) then tl[#tl + 1] = l.msg end end
    for _, e in ipairs(F.events(W)) do tl[#tl + 1] = e.msg end
    error(table.concat(tl, ' | '))
  end
  local armor = false
  for _, it in ipairs(c._items) do if not it.flags.trader and it._type == 'ARMOR' then armor = true end end
  T.ok(armor, 'the armor was bought')
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('value gap: armor:metal needs', 1, true) then said = l.msg end end
  T.ok(said and said:find('more items of the depot are offered', 1, true) and said:find('backpack 6', 1, true), said or 'no log line')
  -- learned: the next list (and the haul) holds them
  T.eq(W.inbox('trade.want', {}).data.sell, {'crafts', 'backpack', 'flask'})
  -- the player takes one out: it stays out
  T.eq(W.inbox('trade.want', {sell_remove = {'flask'}}).data.sell, {'crafts', 'backpack'})
  -- the learned kinds survive a reload
  local json = require('dfllm.util.json')
  local p = json.decode(W.persist_raw['dfllm.m.trade'])
  T.ok(type(p.x) == 'table' and p.x.backpack and p.x.flask, T.show(p.x))
  local W2 = F.world{plan = ARMOR_PLAN, persist = {['m.trade'] = p}}
  W2.load(fresh('trade'))
  T.eq(W2.inbox('trade.want', {}).data.sell, {'crafts', 'backpack'}, 'flask stays out: the player removed it')
end)

T.test('BUG-644: without a gap nothing extra is offered; EXTRA = false and a removed kind keep the list as given', function()
  local ours = {{type = 'FIGURINE', value = 1000}, {type = 'BACKPACK', value = 100}}
  local W, d, c = setup{plan = ARMOR_PLAN, goods = armor_goods, ours = ours}
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'traded') > 0 end, 1500), 'traded')
  for _, l in ipairs(W.logs) do T.ok(not l.msg:find('more items of the depot', 1, true), l.msg) end
  T.eq(W.inbox('trade.want', {}).data.sell, {'crafts'})
  -- switched off: the gap stays, the ledger says by how much
  local ours2 = {{type = 'FIGURINE', value = 60}, {type = 'BACKPACK', value = 900}}
  local W2, d2, c2 = setup{cfg = {EXTRA = false}, plan = ARMOR_PLAN, goods = armor_goods, ours = ours2}
  to_depot(W2, d2, c2)
  F.until_(W2, function() return #F.events(W2, 'failed') > 0 or #F.events(W2, 'traded') > 0 end, 3000)
  T.eq(#F.events(W2, 'traded'), 0)
  local led
  for _, e in ipairs(W2.find_events('TRADE_LEDGER')) do led = e end
  T.ok(led and table.concat(led.d.unmet, ' '):find('armor:metal:', 1, true) and table.concat(led.d.unmet, ' '):find('[need=891,pool=60]', 1, true),
       led and T.show(led.d.unmet) or 'no ledger')
end)

T.test('BUG-644: an empty sell result with spare gear at the depot sells the gear instead of nothing_to_sell', function()
  local W, d, c = setup{plan = plan_want({'cloth'}, {'ring'}), ours = {
    {type = 'BACKPACK', value = 120}, {type = 'BACKPACK', value = 110}, {type = 'FLASK', value = 100}}}
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'traded') > 0 end, 1500), 'traded')
  T.eq(#F.events(W, 'failed'), 0)
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('the sell list takes nothing here', 1, true) then said = l.msg end end
  T.ok(said, 'logged')
end)

T.done()
