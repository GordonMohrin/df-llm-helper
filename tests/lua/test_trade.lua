-- trade (WP9): token matching, ratio/selection math, screen parsers, and the caravan flow on k_mock
-- against a simulated depot/trade UI (tests/lua/trade_world.lua). The UI itself is live-untested.
local T = require('testlib')
local F = require('trade_world')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local L = fresh('trade').lib
local KNOWN = function(n) return n == 'SPLINT' end

local function info(t, mat, desc) return {type = t, mat = (mat or ''):lower(), desc = (desc or ''):lower()} end

---------------------------------------------------------------- tokens and matching
T.test('tokens: kinds, sub, raw item types, rejects', function()
  local t = L.token('bar:iron', KNOWN)
  T.eq({t.kind, t.sub, t.mat, t.cap, t.types.BAR}, {'bar', 'iron', true, 20, true})
  T.eq(L.token('anvil').cap, 1)
  T.ok(L.token('crafts').types.FIGURINE and L.token('crafts').types.GOBLET)
  T.eq(L.token('splint', KNOWN).types, {SPLINT = true})
  T.eq(L.token('splint'), nil)                 -- unknown without a df.item_type lookup
  for _, bad in ipairs({'Bar', 'bar:', 'bar:iron:x', 'bar iron', '', 7}) do T.eq(L.token(bad, KNOWN), nil, tostring(bad)) end
  T.eq(#L.tokens({'bar:iron', 'nonsense', 'cloth'}, KNOWN), 2)
end)

T.test('match: material parts, pig iron is not iron, words and plurals', function()
  local iron, pig = info('BAR', 'INORGANIC:IRON', 'iron bars'), info('BAR', 'INORGANIC:PIG_IRON', 'pig iron bars')
  T.ok(L.match(L.token('bar:iron'), iron))
  T.ok(not L.match(L.token('bar:iron'), pig), 'bar:iron must not match pig iron')
  T.ok(L.match(L.token('bar:pig_iron'), pig))
  T.ok(L.match(L.token('bar'), pig))
  T.ok(L.match(L.token('cloth:silk'), info('CLOTH', 'CREATURE:SPIDER_CAVE_GIANT:SILK', 'giant cave spider silk cloth')))
  T.ok(not L.match(L.token('cloth:silk'), info('CLOTH', 'PLANT:GRASS_TAIL_PIG:THREAD', 'pig tail fiber cloth')))
  T.ok(L.match(L.token('bolts'), info('AMMO', 'INORGANIC:COPPER', 'copper bolts')))
  T.ok(not L.match(L.token('bolts'), info('AMMO', 'INORGANIC:COPPER', 'copper arrows')))
  T.ok(L.match(L.token('weapon:crossbow'), info('WEAPON', 'PLANT:OAK:WOOD', 'oaken crossbow')))
  T.ok(not L.match(L.token('anvil'), info('BAR', 'INORGANIC:IRON', 'iron bars')))
  T.ok(L.has_word('Iron Bars', 'bar') and L.has_word('box of glass', 'box') and not L.has_word('sandbox', 'box'))
  T.ok(L.has_word('pig iron bars', 'pig_iron'))
  local toks = L.tokens({'bar:steel', 'bar', 'cloth'})
  T.eq(L.first_match(toks, iron), 2)           -- priority = list order
  T.eq(L.first_match(toks, info('ANVIL')), nil)
end)

---------------------------------------------------------------- selection math
local function sells(values)
  local r = {}
  for i, v in ipairs(values) do r[i] = {i = i - 1, value = v} end
  return r
end

T.test('choose_sells: many small pieces under the overshoot cap (v1 BUG-226)', function()
  local s = sells({26300, 500, 400, 300, 200, 100})
  local chosen, S = L.choose_sells(s, 900, 0.2)
  T.eq(S, 900)                                 -- 500+400, never the 26300 figurine
  T.eq(#chosen, 2)
end)

T.test('choose_sells: cheapest single piece closes the gap, else most valuable on', function()
  local _, S = L.choose_sells(sells({5000, 2000, 1000}), 1100, 0.2)
  T.eq(S, 3000)                                -- 1000 fits; the cheapest closer is 2000, not 5000
  local _, S1 = L.choose_sells(sells({5000, 1000, 80}), 1100, 0.2)
  T.eq(S1, 6080)                               -- 1000 + 80 fit, 5000 is the only closer (v1 behaviour)
  local _, S2 = L.choose_sells(sells({300, 200}), 1000, 0.2)
  T.eq(S2, 500)                                -- pool too small: everything
  local c3, S3 = L.choose_sells({}, 100, 0.2)
  T.eq({#c3, S3}, {0, 0})
end)

local F0 = {ratio = 1.5, margin = 0.10, buy = 1.35, sell = 1.0, tol = 0.2, max_buy = 60}

T.test('plan: ratio >= 1.5 on the estimate, priority, caps, pool limit', function()
  local buys = {
    {i = 0, k = 1, value = 100, stack = 5, cap = 20},    -- iron bars x5
    {i = 1, k = 2, value = 300, stack = 1, cap = 1},     -- anvil
    {i = 2, k = 2, value = 280, stack = 1, cap = 1},     -- second anvil: cap 1
    {i = 3, k = 3, value = 60, stack = 1, cap = 20},     -- cloth
  }
  local p = L.plan(buys, sells({1000, 800, 500, 300, 200, 100}), F0)
  T.eq(p.pool, 2900)
  T.eq(p.buy, {0, 2, 3})                       -- cheaper anvil first, only one anvil
  T.eq(p.T, 440)
  T.ok(p.S * 1.0 >= p.T * 1.35 * 1.5, 'estimated display ratio holds')
  T.ok(p.ratio_x100 >= 150, p.ratio_x100)
  T.ok(p.S <= p.T * 1.35 * 1.65 * 1.2 + 1000, 'no huge overshoot')
  -- small pool: only what the pool pays for, still >= 1.5
  local q = L.plan(buys, sells({300, 200}), F0)
  T.eq(q.buy, {0, 3})
  T.ok(q.ratio_x100 >= 150, q.ratio_x100)
  -- nothing affordable
  local z = L.plan(buys, sells({20}), F0)
  T.eq({#z.buy, #z.sell, z.ratio_x100}, {0, 0, 0})
end)

T.test('plan: per-token unit caps count stack sizes; max_buy entries', function()
  local buys = {}
  for i = 0, 9 do buys[#buys + 1] = {i = i, k = 1, value = 10, stack = 8, cap = 20} end
  local p = L.plan(buys, sells({100000}), F0)
  T.eq(#p.buy, 3)                              -- 8 + 8 + 8 >= 20 after the third stack
  local q = L.plan(buys, sells({100000}), {ratio = 1.5, margin = 0.1, buy = 1.35, sell = 1, tol = 0.2, max_buy = 2})
  T.eq(#q.buy, 2)
end)

T.test('plan: light mode takes fewer, more valuable goods', function()
  local buys = {{i = 0, k = 1, value = 314, stack = 1, cap = 5}}     -- need ~ 700
  local s = sells({1000, 300, 200, 150, 100, 90, 80, 70, 60})
  local normal = L.plan(buys, s, F0)
  local light = L.plan(buys, s, {ratio = 1.5, margin = 0.1, buy = 1.35, sell = 1, tol = 0.2, light = true})
  T.ok(#light.sell < #normal.sell, #light.sell .. ' vs ' .. #normal.sell)
  T.ok(light.ratio_x100 >= 150 and normal.ratio_x100 >= 150)
end)

T.test('plan: rounding shortfall drops the last buy instead of offering below 1.5', function()
  -- pool exactly at the cap edge: choose_sells may fall short of need; the plan never returns < 1.5
  for pool = 100, 2000, 37 do
    local p = L.plan({{i = 0, k = 1, value = 90, stack = 1, cap = 9}, {i = 1, k = 1, value = 70, stack = 1, cap = 9}},
                     sells({pool // 2, pool // 3, pool - pool // 2 - pool // 3}), F0)
    if #p.buy > 0 then T.ok(p.S * 1.0 >= p.T * 1.35 * 1.5, 'pool ' .. pool) end
  end
end)

---------------------------------------------------------------- screen parsers
local function v1_rows()      -- handelauto selftest fixture (trade at 13:05, Run 6): 4972 / 12510
  local rows = F.blank_rows()
  F.put(rows, 45, 19, 'Value: ~200'); F.put(rows, 115, 19, 'Value: ~60')
  F.put(rows, 45, 52, 'Value: ~60'); F.put(rows, 115, 52, 'Value: ~50')
  F.put(rows, 6, 58, 'Value: 4972'); F.put(rows, 76, 58, 'Value: 12510')
  return rows
end

T.test('parse_display: lowest row with two totals, left = merchant', function()
  local d = L.parse_display(v1_rows())
  T.eq({d.theirs, d.ours, d.y, d.excess}, {4972, 12510, 58, false})
  T.eq(L.parse_display(F.blank_rows()), nil)
  local r = v1_rows(); F.put(r, 6, 59, 'Excess Weight: 300')
  T.ok(L.parse_display(r).excess)
  local g = F.blank_rows(); F.put(g, 6, 58, 'Value: ~1,200'); F.put(g, 76, 58, 'Value: 3000')
  T.eq(L.parse_display(g).theirs, 1200)        -- appraisal estimate counts
  local q = F.blank_rows(); F.put(q, 6, 58, 'Value: 30000?'); F.put(q, 76, 58, 'Value: 3000')
  T.eq(L.parse_display(q), nil)                -- 'N?' = beyond the broker's skill
  local one = F.blank_rows(); F.put(one, 6, 58, 'Value: 10')
  T.eq(L.parse_display(one), nil)
end)

T.test('classify: merchant replies from the 53.16 exe', function()
  local function reply(s) local r = F.blank_rows(); F.put(r, 6, 3, s); return L.classify(r) end
  T.eq(reply('That seems fair.  You have yourself a deal.'), 'accept')
  T.eq(reply('Ah, wonderful.  Thank you for your business.'), 'accept')
  T.eq(reply("I won't trade at a loss."), 'loss')
  T.eq(reply('I simply cannot afford this trade.'), 'afford')
  T.eq(reply('Perhaps if you throw in some more goods I can make an offer.'), 'more')
  T.eq(reply("I can't possibly accept, but how about this?  A true bargain."), 'counter')
  T.eq(reply('I cannot take so much -- and at such cost!'), 'weight')
  T.eq(reply('I wish I could take so much, but my animals...'), 'weight')
  T.eq(reply("You truly despise life, don't you?"), 'offended')
  T.eq(reply('How kind!  Thank you so much.'), 'gift')
  T.eq(L.classify(F.blank_rows()), nil)
end)

T.test('find_trade_button: the label, not "Trade depot"; ambiguity is refused', function()
  local r = F.blank_rows()
  F.put(r, 60, 2, 'Trade depot'); F.put(r, 60, 5, 'Broker requested at depot'); F.put(r, 100, 20, 'Trade')
  T.eq(L.find_trade_button(r), {x = 100, y = 20})
  local r2 = F.blank_rows(); F.put(r2, 60, 2, 'Trade goods'); F.put(r2, 10, 9, 'Traders')
  local b, n = L.find_trade_button(r2)
  T.eq({b, n}, {nil, 0})
  local r3 = F.blank_rows(); F.put(r3, 10, 10, 'Trade'); F.put(r3, 40, 30, 'Trade')
  local b3, n3 = L.find_trade_button(r3)
  T.eq({b3, n3}, {nil, 2})
  local r4 = F.blank_rows(); F.put(r4, 10, 10, 'Trade at depot'); F.put(r4, 40, 30, 'Trade')
  T.eq(L.find_trade_button(r4), {x = 40, y = 30})   -- v1 J262: the candidate without 'at'/'depot'
end)

---------------------------------------------------------------- flow on k_mock
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
  local W = F.world{plan = o.plan, persist = o.persist, mode = o.mode}
  local d = F.depot(W, {})
  local c = F.caravan(W, {state = 'Approaching', tr = o.tr or 1500, goods = o.goods or std_goods(W), wood = o.wood})
  F.goods(W, d, o.ours or std_ours())
  if not o.no_broker then W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}} end
  local U = (not o.no_ui) and F.ui(W, d, c, o.ui) or nil
  if o.before_load then o.before_load(W, d, c) end
  local M = fresh('trade')
  W.load(M)
  return W, M, d, c, U
end

-- arrival -> at the depot with a trader; returns after enough ticks for the goods to settle
local function to_depot(W, d, c, opts)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  if not (opts and opts.no_trader) then F.trader(W, d, true) end
  W.run(opts and opts.ticks or 900, {skip = 9})
end

local function traded(W) return #F.events(W, 'traded') > 0 end
local function count(list, x) local n = 0 for _, v in ipairs(list) do if v == x then n = n + 1 end end return n end

T.test('flow: arrive, broker request, depot, trade screen, ratio >= 1.5, restore, leave', function()
  local W, M, d, c, U = setup()
  W.frame(1)
  T.eq(#F.events(W, 'arrive'), 1)
  T.eq(W.commands[1] and nil, nil)
  local runs = F.calls(W, 'run')
  T.eq({runs[1].args[1], runs[1].args[2]}, {'logistics', 'now'})
  to_depot(W, d, c)
  T.ok(d.trade_flags.trader_requested == true or traded(W), 'broker requested')
  T.eq(d.trade_flags.anyone_can_trade, false)  -- the fort has a broker
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded')
  T.eq(U.trades, 1)
  local ev = F.events(W, 'traded')[1]
  T.ok(ev.d.ratio >= 150, 'ratio ' .. ev.d.ratio)
  T.eq(ev.d.ratio, U.last.ours * 100 // U.last.theirs)   -- the display ratio is what gets reported
  T.eq(U.calls, {'request_broker', 'open', 'open', 'mark', 'offer', 'close', 'request_broker'})
  T.eq(d.trade_flags.trader_requested, false)  -- toggle restored
  T.eq(df.global.game.main_interface.trade.open, false)
  T.eq(select(2, W.K.call('trade', 'done')), 1)
  local s = W.state()
  T.eq(s.trade, {caravan = 1, ratio = ev.d.ratio, done = 1})
  -- what was bought: iron bars and cloth (the anvil does not fit the pool), never the figurine
  local bought = {}
  for _, it in ipairs(c._items) do if not it.flags.trader then bought[#bought + 1] = it._type end end
  table.sort(bought)
  T.eq(bought, {'BAR', 'CLOTH'})
  F.remove_caravans()
  W.run(200, {skip = 9})
  T.eq(#F.events(W, 'left'), 1)
  T.eq(W.state().trade.caravan, 0)
  T.eq(#W.find_events('ACT_FAIL'), 0)
end)

T.test('flow: display factor above the guess -> recalibrate and re-mark', function()
  local W, M, d, c, U = setup{ui = {disp = 1.9}}
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded')
  T.ok(U.marks >= 2, 'marks ' .. tostring(U.marks))
  T.eq(U.offers, 1)                            -- no offer below the display ratio
  T.ok(U.last.ours * 100 >= U.last.theirs * 150, 'display ratio held')
end)

T.test('flow: refusals raise the margin; accepted on the third offer', function()
  local W, M, d, c, U = setup{ui = {accept = 2.5}}
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return traded(W) end, 1500), 'traded')
  T.eq(U.offers, 3)
  T.ok(U.last.ours >= U.last.theirs * 2.5)
end)

T.test('flow: a merchant who never agrees -> one retry, then failed, toggles restored', function()
  local W, M, d, c, U = setup{ui = {accept = 50}}
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'retry') > 0 end, 1500), 'retry')
  T.eq(F.events(W, 'retry')[1].d.why, 'refused')
  T.eq(df.global.game.main_interface.trade.open, false)
  W.run(1300, {skip = 9})                      -- RETRY_WAIT
  T.ok(F.until_(W, function() return #F.events(W, 'failed') > 0 end, 2000), 'failed')
  T.eq(d.trade_flags.trader_requested, false)
  T.eq(U.trades, 0)
  local offers = U.offers
  W.run(3000, {skip = 9})
  T.eq(U.offers, offers)                       -- no third attempt this visit
end)

T.test('flow: merchants still unloading -> close, wait, reopen', function()
  local W, M, d, c, U = setup{ui = {unloading = 1}}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return count(U.calls, 'close') > 0 end, 400)
  T.eq(traded(W), false)
  W.run(700, {skip = 9})
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded after unloading')
  T.ok(count(U.calls, 'open') >= 4)
end)

T.test('flow: DFHack confirm prompt is answered through act.trade offer', function()
  local W, M, d, c, U = setup{ui = {prompt = true}}
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded')
  T.eq(count(U.calls, 'offer'), 2)
end)

T.test('flow: excess weight -> one light re-plan, then retry', function()
  local W, M, d, c, U = setup{ui = {excess = true}}
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'retry') > 0 end, 600), 'retry')
  T.eq(F.events(W, 'retry')[1].d.why, 'weight')
  T.eq(U.marks, 2)
  T.eq(U.offers, 0)
end)

T.test('flow: without act.trade (WP1 stub) the visit fails once and is left to the player', function()
  local W, M, d, c = setup{no_ui = true, before_load = function(W)
    W.act_result('trade', function() return false, 'trade not implemented (WP9 goodflag audit)' end)
  end}
  W.frame(1)
  to_depot(W, d, c)
  W.run(3000, {skip = 9})
  T.eq(#F.calls(W, 'trade'), 1)
  T.eq(#F.events(W, 'failed'), 1)
  T.eq(F.events(W, 'failed')[1].d.why, 'act_missing')
  T.eq(#F.events(W, 'retry'), 0)
end)

T.test('flow: no broker -> "Anyone can Trade"; broker busy for 2 days -> anyone too', function()
  local W, _, d, c = setup{no_broker = true}
  W.frame(1)
  W.run(200, {skip = 9})
  T.eq(d.trade_flags.anyone_can_trade, true)
  local W2, _, d2, c2, U2 = setup{}
  W2.frame(1)
  to_depot(W2, d2, c2, {no_trader = true, ticks = 1200})
  T.eq(d2.trade_flags.anyone_can_trade, false)
  W2.run(1400, {skip = 9})
  T.eq(d2.trade_flags.anyone_can_trade, true)
  T.eq(count(U2.calls, 'open'), 0)             -- nobody at the depot yet
  F.trader(W2, d2, true)
  T.ok(F.until_(W2, function() return traded(W2) end, 2000), 'traded')
  T.eq(d2.trade_flags.anyone_can_trade, false) -- restored
end)

T.test('flow: a trader outside the depot does not open the screen', function()
  local W, _, d, c, U = setup{}
  W.frame(1)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, false)
  W.run(1500, {skip = 9})
  T.eq(count(U.calls, 'open'), 0)
end)

T.test('flow: the player has a screen open -> never touched, no try used', function()
  local W, M, d, c, U = setup{}
  W.frame(1)
  W.focus = {'dwarfmode/Stocks/Default'}
  to_depot(W, d, c)
  local function busy_logged()
    for _, l in ipairs(W.logs) do if l.msg:find('player screen is open', 1, true) then return true end end
  end
  T.ok(F.until_(W, busy_logged, 1500), 'busy logged')
  T.eq(#F.events(W, 'retry'), 0)               -- logged only, no CARAVAN event spam
  T.eq(count(U.calls, 'open'), 0)
  T.eq(json.decode(W.persist_raw['dfllm.m.trade']).visits['7'].tries, 0)
  W.focus = {'dwarfmode/Default'}
  W.run(1300, {skip = 9})
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded once the screen is free')
end)

T.test('flow: the player opened the trade screen himself -> trade.lua waits', function()
  local W, M, d, c, U = setup{}
  W.frame(1)
  to_depot(W, d, c, {ticks = 100})
  U.ops.open({depot = d.id}); U.ops.open({depot = d.id, x = 100, y = 20})   -- the player's clicks
  W.run(900, {skip = 9})
  F.frames(W, 200)
  T.eq(count(U.calls, 'mark'), 0)
  T.eq(count(U.calls, 'open'), 0)
end)

T.test('flow: SIEGE mid-trade closes the screen and sends the trader home; PEACE resumes', function()
  local W, M, d, c, U = setup{}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return df.global.game.main_interface.trade.open end, 300)
  T.ok(df.global.game.main_interface.trade.open, 'screen open')
  W.K.set_mode('SIEGE', 'test')
  T.eq(df.global.game.main_interface.trade.open, false)
  T.eq(d.trade_flags.trader_requested, false)
  local opens = count(U.calls, 'open')
  W.run(1200, {skip = 9})
  T.eq(count(U.calls, 'open'), opens)
  T.eq(d.trade_flags.trader_requested, false)
  W.K.set_mode('RECOVERY', 'test'); W.K.set_mode('PEACE', 'test')
  T.ok(F.until_(W, function() return traded(W) end, 2000), 'traded after the siege')
end)

T.test('flow: caravan short of time and offended caravans', function()
  local W, _, d, c, U = setup{}
  W.frame(1)
  W.run(200, {skip = 9})
  c.time_remaining = 150
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(300, {skip = 9})
  T.eq(F.events(W, 'failed')[1].d.why, 'time')
  T.eq(count(U.calls, 'open'), 0)
  local W2, _, d2, c2, U2 = setup{}
  c2.flags.seized = true
  W2.frame(1)
  W2.run(500, {skip = 9})
  T.eq(#U2.calls, 0)                           -- never started
end)

T.test('flow: nothing wanted / nothing to sell', function()
  local W, _, d, c, U = setup{goods = {}, before_load = function(W, d, c)
    c._items[1] = F.item(W, {type = 'FIGURINE', value = 500}); c._items[1].flags.trader = true
  end}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return #F.events(W, 'failed') > 0 end, 600)
  T.eq(F.events(W, 'failed')[1].d.why, 'nothing_wanted')
  T.eq(count(U.calls, 'mark'), 0)
  -- an export-banned figurine is in the depot but may not be sold (mandate)
  local W2, _, d2, c2, U2 = setup{ours = {{type = 'FIGURINE', value = 200, banned = true}}}
  W2.frame(1)
  to_depot(W2, d2, c2)
  F.until_(W2, function() return #F.events(W2, 'failed') > 0 end, 600)
  T.eq(F.events(W2, 'failed')[1].d.why, 'nothing_to_sell')
end)

-- what the first act.trade('mark') ticked: {buy = {'TYPE:value'...}, sell = {...}}
local function first_mark(W)
  local t = df.global.game.main_interface.trade
  for _, a in ipairs(F.calls(W, 'trade')) do
    if a.args[1] == 'mark' then
      local r = {buy = {}, sell = {}}
      for _, i in ipairs(a.args[2].buy) do r.buy[#r.buy + 1] = t.good[0][i]._type .. ':' .. t.good[0][i]._value end
      for _, i in ipairs(a.args[2].sell) do r.sell[#r.sell + 1] = t.good[1][i]._type .. ':' .. t.good[1][i]._value end
      table.sort(r.buy); table.sort(r.sell)
      return r
    end
  end
end

T.test('selection: wood ethics, mandates, owned, artifacts and full bins are never offered', function()
  local W, _, d, c = setup{wood = true, ours = {
    {type = 'FIGURINE', mat = 'PLANT:OAK:WOOD', desc = 'oaken figurine', value = 400},
    {type = 'FIGURINE', value = 900, banned = true}, {type = 'FIGURINE', value = 800, flags = {owned = true}},
    {type = 'FIGURINE', value = 700, flags = {artifact = true}}, {type = 'BIN', value = 650, contents = {{_value = 1}}},
    {type = 'AMULET', value = 600, animal = true},                -- animal ethics are not set: sellable
    {type = 'FIGURINE', value = 300, desc = 'granite figurine'}, {type = 'RING', value = 250}, {type = 'CROWN', value = 150}}}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return first_mark(W) ~= nil end, 600)
  local m = first_mark(W)
  T.ok(m and #m.sell > 0, 'something offered')
  local allowed = {['AMULET:600'] = true, ['FIGURINE:300'] = true, ['RING:250'] = true, ['CROWN:150'] = true}
  for _, s in ipairs(m.sell) do T.ok(allowed[s], 'offered ' .. s) end
  T.eq(m.buy, {'ANVIL:300', 'BAR:100', 'CLOTH:60'})              -- the figurine is not on the want list
end)

-- DFHack's has_wood() cases the old token check missed (internal/caravan/common.lua:672-720)
local function wood_goods()
  return {{type = 'BAR', mat = 'COAL:CHARCOAL', desc = 'charcoal bars', value = 900},
          {type = 'FIGURINE', mat = 'INORGANIC:GRANITE', desc = 'granite figurine', value = 850, improvements = {'PLANT:OAK:WOOD'}},
          {type = 'WEAPON', mat = 'INORGANIC:OBSIDIAN', desc = 'obsidian short sword', value = 800},
          {type = 'BAR', mat = 'CREATURE:PIG:SOAP', desc = 'soap bars', value = 750},
          {type = 'GOBLET', mat = 'GLASS_CLEAR', desc = 'clear glass goblet', value = 700},
          {type = 'FIGURINE', mat = 'INORGANIC:GRANITE', desc = 'granite figurine', value = 650, improvements = {'GLASS_CRYSTAL'}},
          {type = 'WEAPON', mat = 'INORGANIC:IRON', desc = 'iron short sword', value = 300},
          {type = 'FIGURINE', mat = 'INORGANIC:GRANITE', desc = 'granite figurine', value = 250, improvements = {'INORGANIC:GOLD'}},
          {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 200}, {type = 'CROWN', value = 150}}
end

T.test('selection: wood ethic like DFHack has_wood: charcoal, decorations, obsidian swords, soap, glass', function()
  local W, _, d, c = setup{wood = true, ours = wood_goods()}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return first_mark(W) ~= nil end, 600)
  local m = first_mark(W)
  T.ok(m and #m.sell > 0, 'something offered')
  local allowed = {['WEAPON:300'] = true, ['FIGURINE:250'] = true, ['BAR:200'] = true, ['CROWN:150'] = true}
  for _, s in ipairs(m.sell) do T.ok(allowed[s], 'offered to a wood-ethic caravan: ' .. s) end
  -- without the wood ethic the same goods are fine: the most valuable ones are offered
  local W2, _, d2, c2 = setup{ours = wood_goods()}
  W2.frame(1)
  to_depot(W2, d2, c2)
  F.until_(W2, function() return first_mark(W2) ~= nil end, 600)
  T.eq(first_mark(W2).sell[1], 'BAR:900')
  local W3, _, d3, c3 = setup{ours = {{type = 'WEAPON', mat = 'INORGANIC:OBSIDIAN', desc = 'obsidian short sword', value = 800}}}
  W3.frame(1)
  to_depot(W3, d3, c3)
  F.until_(W3, function() return first_mark(W3) ~= nil end, 600)
  T.eq(first_mark(W3).sell, {'WEAPON:800'})
end)

T.test('selection: animal ethics keep animal products back', function()
  local W, _, d, c = setup{before_load = function(W, d, c)
    W.entities[c.entity].entity_raw.ethic[df.ethic_type.KILL_ANIMAL] = df.ethic_response.PUNISH_EXILE
  end, ours = {{type = 'AMULET', value = 600, animal = true, desc = 'bone amulet'}, {type = 'RING', value = 500}}}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return first_mark(W) ~= nil end, 600)
  T.eq(first_mark(W).sell, {'RING:500'})
end)

T.test('selection: plan.trade.sell and want restrict the trade', function()
  local W, _, d, c = setup{plan = {v = 2, year = 3, phase_target = 'P4', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
    policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}, trade = {want = {'cloth'}, sell = {'ring'}}},
    ours = {{type = 'FIGURINE', value = 900}, {type = 'RING', value = 120}, {type = 'RING', value = 110}}}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return first_mark(W) ~= nil end, 600)
  local m = first_mark(W)
  T.eq(m.buy, {'CLOTH:60'})
  T.ok(#m.sell > 0)
  for _, s in ipairs(m.sell) do T.eq(s:sub(1, 5), 'RING:') end
end)

---------------------------------------------------------------- O1 window and stuck merchants
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {30, 5, 10, 32, 5, 10}, levers = {{35, 8, 10}}},
                               B1 = {role = 'inner', fp = {30, 15, 10, 32, 15, 10}, levers = {{35, 18, 10}}}}}

local function quiet(W, vis) W.set_census('h', {tick = W.K.now().tick, vis = vis or 0}) end

T.test('O1 window: down via gate.want only in PEACE, no visible hostile, caravan present', function()
  local W, M, d, c, U = setup{persist = {manifest = MAN}, before_load = function(W) F.gate(W) end}
  W.bridge_state.O1, W.bridge_state.B1 = 'up', 'up'
  quiet(W, 1)
  W.frame(1)
  T.eq(#W.gate_wants, 0)                       -- a visible hostile
  quiet(W, 0)
  W.run(100, {skip = 9})
  T.eq(W.gate_wants, {{'O1', 'down', 'trade'}})  -- only the outer bridge
  W.bridge_state.O1 = 'up'
  for _ = 1, 4 do quiet(W, 0); W.run(100, {skip = 10}) end
  T.eq(#W.gate_wants, 1)                       -- at most once per 600 ticks
  quiet(W, 0); W.run(300, {skip = 10})
  T.eq(#W.gate_wants, 2)
  W.bridge_state.O1 = 'up'
  W.K.set_mode('ALERT', 'test')
  for _ = 1, 8 do quiet(W, 0); W.run(100, {skip = 10}) end
  T.eq(#W.gate_wants, 2)                       -- not in ALERT
  W.K.set_mode('PEACE', 'test')
  W.set_census('h', {tick = 0, vis = 0})       -- stale census = unknown
  W.run(700, {skip = 10})
  T.eq(#W.gate_wants, 2)
  F.remove_caravans()
  for _ = 1, 8 do quiet(W, 0); W.run(100, {skip = 10}) end
  T.eq(#W.gate_wants, 2)                       -- no caravan, no window
end)

T.test('stuck: fix/stuck-merchants once after 4 days Approaching, never with O1 up', function()
  local W, M, d, c = setup{persist = {manifest = MAN}, before_load = function(W) F.gate(W) end}
  W.bridge_state.O1 = 'up'
  quiet(W, 1)                                  -- hostile visible: no O1 window, O1 stays up
  W.frame(1)
  for _ = 1, 50 do quiet(W, 1); W.run(100, {skip = 10}) end
  local function stuck_runs()
    local n = 0
    for _, a in ipairs(F.calls(W, 'run')) do if a.args[1] == 'fix/stuck-merchants' then n = n + 1 end end
    return n
  end
  T.eq(stuck_runs(), 0)
  W.bridge_state.O1 = 'down'
  W.run(200, {skip = 10})
  T.eq(stuck_runs(), 1)
  T.eq(#F.events(W, 'stuck'), 1)
  W.run(5000, {skip = 10})
  T.eq(stuck_runs(), 1)
  -- a caravan that reached the depot is never "stuck"
  local W2, _, d2, c2 = setup{persist = {manifest = MAN}, before_load = function(W) F.gate(W) end}
  W2.bridge_state.O1 = 'down'
  W2.frame(1)
  W2.run(200, {skip = 10})
  F.set_state(c2, 'AtDepot')
  W2.run(200, {skip = 10})
  F.set_state(c2, 'Approaching')
  W2.run(6000, {skip = 10})
  for _, a in ipairs(F.calls(W2, 'run')) do T.ok(a.args[1] ~= 'fix/stuck-merchants') end
end)

---------------------------------------------------------------- persistence, verb, reports
T.test('persist: done, visits and the override survive a reload', function()
  local W, M, d, c, U = setup{}
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return traded(W) end, 600)
  local p = json.decode(W.persist_raw['dfllm.m.trade'])
  T.eq(p.done, 1)
  T.eq(p.visits['7'].traded, 1)
  local W2 = F.world{persist = {['m.trade'] = p}}
  local c2 = F.caravan(W2, {state = 'AtDepot', goods = std_goods(W2)})
  F.depot(W2, {})
  local M2 = fresh('trade')
  W2.load(M2)
  W2.run(500, {skip = 9})
  T.eq(select(2, W2.K.call('trade', 'done')), 1)
  T.eq(#F.events(W2, 'arrive'), 0)             -- same visit, no second arrival
  T.eq(#F.calls(W2, 'trade'), 0)               -- already traded this visit
end)

T.test('verb trade.want: override, query, validation, dropped by plan.reload', function()
  local W, M = setup{}
  local r = W.inbox('trade.want', {want = {'bar:steel', 'bolts'}, sell = {'crafts'}})
  T.ok(r.ok, r.msg)
  T.eq(r.data, {want = {'bar:steel', 'bolts'}, sell = {'crafts'}})
  local q = W.inbox('trade.want', {})
  T.eq(q.data.want, {'bar:steel', 'bolts'})
  T.eq(W.inbox('trade.want', {want = {'Bar'}}).ok, false)
  T.eq(W.inbox('trade.want', {want = 'bar'}).ok, false)
  W.run(50)
  W.plan_file = {v = 2, year = 3, phase_target = 'P4', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
                 policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}, trade = {want = {'thread'}, sell = {}}}
  T.ok(W.inbox('plan.reload', {}).ok)
  local q2 = W.inbox('trade.want', {})
  T.eq(q2.data, {want = {'thread'}, sell = {}})
  -- empty plan want -> the default list
  W.plan_file.trade.want = {}
  W.run(50)
  W.inbox('plan.reload', {})
  T.eq(W.inbox('trade.want', {}).data.want, {'bar:iron', 'anvil', 'cloth'})
end)

T.test('report CARAVAN_ARRIVAL wakes the module next tick', function()
  local W = F.world{}
  F.depot(W, {})
  local M = fresh('trade')
  W.load(M)
  W.frame(1)
  F.caravan(W, {state = 'Approaching', goods = std_goods(W)})
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'A caravan from The Merchant Guild has arrived.'})
  W.frame(1)
  W.frame(1); W.frame(1)
  T.eq(#F.events(W, 'arrive'), 1)
  T.eq(M.every.ticks, 100)                     -- back to the idle cadence afterwards
end)

T.test('cadence: ticks while waiting, real-time while the screen is open', function()
  local W, M, d, c, U = setup{}
  W.frame(1)
  T.eq(M.every, {ticks = 100})
  to_depot(W, d, c)
  F.until_(W, function() return df.global.game.main_interface.trade.open end, 300)
  T.eq(M.every, {ms = 50})
  F.until_(W, function() return traded(W) end, 600)
  T.eq(M.every, {ticks = 100})
end)

T.test('screen reads: <= READS tiles per frame, only the rows a phase needs', function()
  local W, M, d, c, U = setup{}
  local frame, worst, total = W.frame, 0, 0
  W.frame = function(...)
    W.reads = 0
    frame(...)
    worst, total = math.max(worst, W.reads), total + W.reads
  end
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return traded(W) end, 600)
  W.frame = frame
  T.ok(traded(W))
  T.ok(worst <= M.CFG.READS and M.CFG.READS <= 1000, 'reads per frame ' .. worst)
  -- one depot sheet scan (110 x 40) and two trade screen scans (top 12 + bottom 8 rows of 160)
  T.eq(U.calls, {'request_broker', 'open', 'open', 'mark', 'offer', 'close', 'request_broker'})
  T.ok(total <= 110 * 40 + 2 * 20 * F.SW, 'reads in all ' .. total)
end)

T.test('screen reads at 240x90: a sliced whole-screen fallback finds a sheet button elsewhere', function()
  F.set_size(240, 90)
  local W, M, d, c, U = setup{ui = {button = {x = 12, y = 60}}}
  local frame, worst = W.frame, 0
  W.frame = function(...) W.reads = 0; frame(...); worst = math.max(worst, W.reads) end
  W.frame(1)
  to_depot(W, d, c)
  F.until_(W, function() return traded(W) end, 900)
  W.frame = frame
  F.set_size(160, 60)
  T.ok(traded(W), 'traded')
  T.ok(worst <= 1000, 'reads per frame ' .. worst)
end)

T.done()
