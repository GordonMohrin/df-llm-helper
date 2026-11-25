-- NEU7 BUG-858 (Run 17 i3 Orangering: the growth halt '(squad)' counted a badly injured member as unarmed and said nothing about it): the halt names
-- the injured ones, the gate rule is unchanged. BUG-859: trade.want says what a change took out of a list.
local T = require('testlib')
local F = require('trade_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

T.test('BUG-858: first squad 2 of 3 armed, 1 of the unarmed injured: the halt stays "squad", the need text and inj name the injured one', function()
  local R = fresh('readiness')
  local c = {}
  for k, v in pairs(R.GROWTH) do c[k] = v end
  c.on = true
  local g = R.growth_ladder({n = 3, fullr = 2, metal = 0, sq_n = 3, sq_w = 2, sq_u = 1, lvl = 1, lever = true, drink_d = 100}, c)
  T.eq(g.halt, 'squad', 'the rule is unchanged: 2 of 3 armed halts')
  T.eq(g.inj, 1)
  T.ok(g.need:find('; 1 injured)', 1, true), g.need)
  local g2 = R.growth_ladder({n = 3, fullr = 2, metal = 0, sq_n = 3, sq_w = 2, sq_u = 0, lvl = 1, lever = true, drink_d = 100}, c)
  T.eq(g2.halt, 'squad')
  T.eq(g2.inj, nil)
  T.ok(not g2.need:find('injured', 1, true), g2.need)
  local g3 = R.growth_ladder({n = 3, fullr = 1, metal = 0, sq_n = 3, sq_w = 3, sq_u = 5, lvl = 1, lever = true, drink_d = 100}, c)
  T.ok(g3.halt ~= 'squad' and g3.inj == nil, 'a halt other than squad never carries the injured count')
  local g4 = R.growth_ladder({n = 3, fullr = 1, metal = 0, sq_n = 3, sq_w = 2, sq_u = 9, lvl = 1, lever = true, drink_d = 100}, c)
  T.eq(g4.inj, 1, 'never more injured than unarmed')
end)

local PLAN = {v = 2, year = 3, phase_target = 'P4', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}, trade = {want = {'bar:iron', 'anvil', 'cloth'}, sell = {'crafts'}}}

T.test('BUG-859: trade.want says what a replacement or a full list dropped; an add drops nothing', function()
  local W = F.world{plan = PLAN}
  F.depot(W, {})
  local M = fresh('trade')
  W.load(M)
  local r = W.inbox('trade.want', {add = {'stone'}})
  T.ok(r.ok and not r.msg:find('dropped', 1, true), r.msg)
  T.eq(r.data.want, {'stone', 'bar:iron', 'anvil', 'cloth'})
  local r2 = W.inbox('trade.want', {want = {'leather'}})
  T.ok(r2.msg:find('dropped from the want list: stone,bar:iron,anvil,cloth', 1, true), r2.msg)
  local r3 = W.inbox('trade.want', {sell = {'gem'}})
  T.ok(r3.msg:find('dropped from the sell list: crafts', 1, true), r3.msg)
  local r4 = W.inbox('trade.want', {add = {'wood'}, remove = {'leather'}})
  T.ok(not r4.msg:find('dropped', 1, true), 'a token named in remove is no surprise: ' .. r4.msg)
  local many = {}
  for i = 1, 40 do many[i] = 'x' .. string.char(96 + (i % 26) + 1) .. string.char(96 + (i // 26) + 1) end
  W.inbox('trade.want', {want = many})
  local r5 = W.inbox('trade.want', {add = {'stone'}})
  T.ok(r5.msg:find('dropped from the want list: ' .. many[40], 1, true), 'a full list drops its tail and says so: ' .. r5.msg)
end)

T.done()
