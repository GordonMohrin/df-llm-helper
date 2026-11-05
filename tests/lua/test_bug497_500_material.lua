-- BUG-497 to BUG-499 (Run 16a-d, 05.11.2026: forts with no stone, strange moods without bone, a manager who validates nothing):
--   * BUG-497: a seal door goes before the wood other owners' orders claimed (economy.wood_left def), the explore that digs to hard stone
--     queues with the hospital while the fort has no free boulder (runner Q.quarry_first, economy.stone_zero)
--   * BUG-498: a mood that needs bone marks an ADULT (the most numerous race first), and when only the breeding pairs are left the last
--     adult of a race: pets and war animals never; ANIMAL_MARKED says so
--   * BUG-499: inspect what=manager names the findings (squad, mood, outside, office, chair, table, walk path, orders)
local T = require('testlib')
local H = require('runner_world')
local F = require('wp8_world')
local runner = require('dfllm.runner')
local kmock = require('dfllm.util.k_mock')

local function fresh_mod(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

---------------------------------------------------------------- BUG-497: the quarry dig goes first
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function qworld(zero)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world({tag = 'b497' .. tostring(zero)})
  W.load(runner)
  W.load({name = 'economy', every = {ticks = 1200}, stone_zero = function(K) return zero end})
  for i = 1, 5 do H.place(W, 'p' .. i, H.doc{x = 10 * i}, {tpl = 'bedrooms', site = 'S1', prio = 4}) end
  H.place(W, 'q9', H.doc{x = 90, tpl = 'explore', class = 'infra'}, {tpl = 'explore', site = 'S1', prio = 4})
  H.settle(W); W.frame(1); H.settle(W)
  local s = {}
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do s[c.pos[1]] = true end
  return s
end
T.test('BUG-497: no free boulder: the explore (it digs to hard stone) is one of the three projects at work, the youngest of six', function()
  local s = qworld(true)
  T.ok(s[90], 'the explore runs')
  T.ok(s[10] and s[20] and not s[30], 'then the oldest bedrooms')
end)
T.test('BUG-497: stone in the fort: the queue order is unchanged, the explore (the youngest) waits', function()
  local s = qworld(false)
  T.ok(not s[90] and s[10] and s[20] and s[30], 'oldest first')
end)

---------------------------------------------------------------- BUG-498: bones from an adult
local E = fresh_mod('economy')
T.test('BUG-498: slaughter_pick adult_first: adults before young, the most numerous race first; pets and war animals never', function()
  local herd = {
    {id = 1, race = 5, adult = true, female = true}, {id = 2, race = 5, adult = true, female = false},
    {id = 3, race = 5, adult = false, female = true},                                   -- a young cavy
    {id = 4, race = 6, adult = true, female = true}, {id = 5, race = 6, adult = true, female = true},
    {id = 6, race = 6, adult = true, female = false}, {id = 7, race = 6, adult = true, pet = true},
    {id = 8, race = 7, adult = true, war = true}}
  T.eq(E.slaughter_pick(herd, {keep_f = 1, keep_m = 1, max = 3}), {3, 5}, 'old order: the lowest ids (young first)')
  T.eq(E.slaughter_pick(herd, {keep_f = 1, keep_m = 1, max = 3, adult_first = true}), {5, 3}, 'adult of the larger race, then the young one')
  T.eq(E.slaughter_pick({herd[1], herd[2], herd[7], herd[8]}, {keep_f = 0, keep_m = 0, max = 1, adult_first = true}), {1},
       'with no pair kept: an adult; the pet and the war animal stay')
end)

-- (the mood test with the whole economy world is in test_economy_food.lua)

---------------------------------------------------------------- BUG-499: inspect what=manager
T.test('BUG-499: inspect what=manager exists and answers without a manager post', function()
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}}}
  W.set_census('u', F.census_u({1}))
  W.load(fresh_mod('economy'))
  local r = W.inbox('inspect', {what = 'manager'})
  T.ok(r.ok ~= false, tostring(r.msg))
  T.ok(tostring(r.msg):find('manager', 1, true), tostring(r.msg))
end)

T.done()
