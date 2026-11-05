-- BUG-440 (Run 16a i1 Syrupobeyed y376: `trade.want '{"want":["bone"]}'` replaced the whole wish list): add / remove change the
-- current list, want / sell still replace it, a token that matches no item type is named in the reply.
local T = require('testlib')
local F = require('trade_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function setup(plan)
  local W = F.world{plan = plan}
  F.depot(W, {})
  local M = fresh('trade')
  W.load(M)
  return W, M
end

local PLAN = {v = 2, year = 3, phase_target = 'P4', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}, trade = {want = {'bar:iron', 'anvil', 'cloth'}, sell = {'crafts'}}}

T.test('trade.want add: the new tokens go in front of the plan list, nothing is lost, none is doubled', function()
  local W = setup(PLAN)
  local r = W.inbox('trade.want', {add = {'mechanism', 'stone'}})
  T.ok(r.ok, r.msg)
  T.eq(r.data.want, {'mechanism', 'stone', 'bar:iron', 'anvil', 'cloth'})
  T.eq(r.data.sell, {'crafts'})
  T.eq(W.inbox('trade.want', {add = {'stone', 'gem'}}).data.want, {'stone', 'gem', 'mechanism', 'bar:iron', 'anvil', 'cloth'},
       'the added tokens lead in the order given, a token already there is not doubled')
end)

T.test('trade.want remove, sell_add / sell_remove, want replaces, the list stays under 40', function()
  local W = setup(PLAN)
  T.eq(W.inbox('trade.want', {remove = {'anvil'}}).data.want, {'bar:iron', 'cloth'})
  T.eq(W.inbox('trade.want', {sell_add = {'gem'}}).data.sell, {'gem', 'crafts'})
  T.eq(W.inbox('trade.want', {sell_remove = {'crafts'}}).data.sell, {'gem'})
  T.eq(W.inbox('trade.want', {want = {'leather'}}).data.want, {'leather'}, 'want still replaces')
  T.eq(W.inbox('trade.want', {add = {'stone'}, remove = {'leather'}}).data.want, {'stone'}, 'add and remove in one call')
  local many = {}
  for i = 1, 40 do many[i] = 'x' .. string.char(96 + (i % 26) + 1) .. string.char(96 + (i // 26) + 1) end
  W.inbox('trade.want', {want = many})
  T.eq(#W.inbox('trade.want', {add = {'stone'}}).data.want <= 40, true)
  T.eq(W.inbox('trade.want', {add = {'Bar'}}).ok, false, 'bad token')
  T.eq(W.inbox('trade.want', {add = 'bar'}).ok, false)
end)

T.test('trade.want: a token that matches no item type is named as ignored (bone is none)', function()
  local W = setup(PLAN)
  local r = W.inbox('trade.want', {add = {'bone'}})
  T.ok(r.ok, r.msg)
  T.eq(r.data.ignored, {'bone'})
  T.ok(r.msg:find('ignored', 1, true) and r.msg:find('bone', 1, true), r.msg)
  T.eq(r.data.want, {'bar:iron', 'anvil', 'cloth'}, 'the list stands, bone is not a trade token')
end)

T.done()
