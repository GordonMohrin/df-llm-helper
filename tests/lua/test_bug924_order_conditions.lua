-- BUG-924 (Run 17 i3, `why brew --raw` order 34): DF gives compare_type as a number (0 AtLeast, 1 AtMost ...); jobwhy keyed its comparators by
-- name, so "at least 15 plant (DRINK_MAT)" printed as "0 15 plant (DRINK_MAT)", nothing was counted and "3 item conditions by my count met"
-- counted all of them. Now: the comparator in words, the kernel's count beside it, met / unmet / not counted per condition, the empty
-- containers read against the census (0 free beside "at least 5" is unmet), and the summary counts only what the count proved.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function world()
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true, name = 'Urist 1', pos = {11, 10, 100}}}}
  return W
end

T.test('BUG-924: a numeric compare_type reads as words, with the count and a verdict per condition', function()
  local W = world()
  for _ = 1, 3 do
    F.item(W, 'PLANT', {_pos = {12, 12, 100}, getSubtype = function() return -1 end, getMaterial = function() return 419 end,
                        getMaterialIndex = function() return 1 end})
  end
  local JW = fresh('jobwhy')
  local o = {item_conditions = kmock.vec{
    {compare_type = 0, compare_val = 15, item_type = df.item_type.PLANT, flags1 = {}, has_material_reaction_product = 'DRINK_MAT'},
    {compare_type = 0, compare_val = 5, item_type = -1, flags1 = {empty = true}, flags3 = {food_storage = true}},
    {compare_type = 1, compare_val = 3000, item_type = df.item_type.DRINK, flags1 = {}}}}
  local cl = JW.conditions(o, {inv = {cont_free = 0, barrels_empty = 0}})
  T.eq(#cl, 3)
  T.ok(cl[1].text:find('at least 15 plant (DRINK_MAT): 3 found, unmet', 1, true), cl[1].text)
  T.ok(not cl[1].text:find('^0 '), 'the compare type is no number in front: ' .. cl[1].text)
  T.eq(cl[1].met, false)
  T.ok(cl[2].text:find('at least 5 empty food storage containers: 0 free by the census', 1, true) and cl[2].text:find(', unmet', 1, true), cl[2].text)
  T.eq(cl[2].met, false)
  T.eq(cl[2].n, 0)
  T.ok(cl[3].text:find('at most 3000 drink: 0 found, met', 1, true), cl[3].text)
  T.eq(cl[3].met, true)
end)

T.test('BUG-924: the names of every compare type, a name still works, an unknown one is shown as such', function()
  local JW = fresh('jobwhy')
  local want = {[0] = 'AtLeast', 'AtMost', 'GreaterThan', 'LessThan', 'Exactly', 'NotExactly'}
  for n = 0, 5 do T.eq(JW.cmp_name(n), want[n]) end
  T.eq(JW.cmp_name('AtMost'), 'AtMost')
  T.eq(JW.cmp_name(nil), 'AtLeast')
  T.eq(JW.cmp_name(9), 'compare#9')
end)

T.test('BUG-924: with enough empty containers the same condition is met; without a census it is "not counted", never a verdict', function()
  local W = world()
  local JW = fresh('jobwhy')
  local o = {item_conditions = kmock.vec{{compare_type = 0, compare_val = 5, item_type = -1, flags1 = {empty = true}, flags3 = {food_storage = true}}}}
  local cl = JW.conditions(o, {inv = {cont_free = 9}})
  T.eq(cl[1].met, true)
  T.ok(cl[1].text:find('9 free by the census', 1, true) and cl[1].text:find(', met', 1, true), cl[1].text)
  cl = JW.conditions(o, {})
  T.eq(cl[1].met, nil)
  T.ok(cl[1].text:find(', not counted', 1, true), cl[1].text)
end)
