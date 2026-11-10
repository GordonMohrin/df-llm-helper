-- BUG-627 (Run 16a i1 Basementflew y443-y453: `trade.sell crafts/thread/drink`, every caravan 'nothing_to_sell' beside 169 items of other
-- kinds; the first trade since y426 came only after bone, food, meal and plant were added by hand, and drink in the list cut the stock from
-- 944 to 396 days): the kernel adds bone, food (plant, meal) above SURPLUS_FOOD_D days and drink only above SURPLUS_DRINK_D days to a
-- non-empty sell list. Every test fails before.
local T = require('testlib')
local F = require('trade_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local M = fresh('trade')
local L = M.lib
local CFG = M.CFG
local function srcs(l) local r = {} for _, t in ipairs(l) do r[#r + 1] = t.src end return r end

T.test('surplus: a long food stock adds bone and food, short drink stays out', function()
  local sell = L.tokens({'crafts', 'thread', 'drink'})
  local r, added = L.surplus_sell(L.tokens({'crafts', 'thread'}), {food_d = 900, drink_d = 100}, nil, CFG)
  T.eq(srcs(r), {'crafts', 'thread', 'bone', 'food'})
  T.eq(added, {'bone', 'food'})
  T.eq(#sell, 3, 'the input list is not changed')
  T.ok(L.first_match(r, {type = 'PLANT', mat = '', desc = 'plump helmets'}), 'food takes plants')
  T.ok(L.first_match(r, {type = 'FOOD', mat = '', desc = 'dwarven roast'}), 'food takes meals')
  T.ok(L.first_match(r, {type = 'CORPSEPIECE', mat = '', desc = 'goat bone'}), 'bone takes bones')
end)

T.test('surplus: drink joins only above the floor, food only above its days', function()
  local base = L.tokens({'crafts'})
  T.eq(srcs((L.surplus_sell(base, {food_d = 200, drink_d = 944}, nil, CFG))), {'crafts', 'bone', 'drink'})
  T.eq(srcs((L.surplus_sell(base, {food_d = 300, drink_d = CFG.SURPLUS_DRINK_D - 1}, nil, CFG))), {'crafts', 'bone', 'food'})
  T.eq(srcs((L.surplus_sell(base, {food_d = 9999, drink_d = CFG.SURPLUS_DRINK_D}, nil, CFG))), {'crafts', 'bone', 'food', 'drink'})
end)

T.test('surplus: player lists stay as they are, an empty list and unknown stock add nothing', function()
  local named = L.tokens({'drink', 'food', 'bone'})
  local r, added = L.surplus_sell(named, {food_d = 9999, drink_d = 9999}, nil, CFG)
  T.eq(srcs(r), {'drink', 'food', 'bone'}); T.eq(added, {})
  T.eq(#(L.surplus_sell({}, {food_d = 9999, drink_d = 9999}, nil, CFG)), 0, 'an empty list sells whatever lies at the depot')
  T.eq(srcs((L.surplus_sell(L.tokens({'crafts'}), nil, nil, CFG))), {'crafts'}, 'no stock reading')
  T.eq(srcs((L.surplus_sell(L.tokens({'crafts'}), {food_d = 9999, drink_d = 9999}, nil, {SURPLUS = false}))), {'crafts'})
  -- drink named by the player is kept below the floor too
  T.eq(srcs((L.surplus_sell(L.tokens({'crafts', 'drink'}), {food_d = 10, drink_d = 10}, nil, CFG))), {'crafts', 'drink', 'bone'})
end)

T.test('surplus: a kind the player removed stays out', function()
  local r = L.surplus_sell(L.tokens({'crafts'}), {food_d = 9999, drink_d = 9999}, nil, CFG, {'drink', 'bone'})
  T.eq(srcs(r), {'crafts', 'food'})
end)

T.test('surplus: through the module, economy.surplus_days feeds trade.want replies and sell_remove sticks', function()
  local W = F.world{plan = {v = 2, year = 3, phase_target = 'P4', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
                            policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}, trade = {want = {'anvil'}, sell = {'crafts'}}}}
  F.depot(W, {})
  W.load({name = 'economy', every = {ticks = 600}, surplus_days = function() return {food_d = 800, drink_d = 700} end})
  W.load(fresh('trade'))
  T.eq(W.inbox('trade.want', {}).data.sell, {'crafts', 'bone', 'food', 'drink'})
  T.eq(W.inbox('trade.want', {sell_remove = {'drink'}}).data.sell, {'crafts', 'bone', 'food'}, 'the removed kind is not added again')
end)

T.done()
