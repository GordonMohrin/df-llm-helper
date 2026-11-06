-- BUG-527 (Run 16b i2 Brotherarrow y392-y393: Still and Kitchen missing for years, 89 orders stuck, only 7 working adults and every
-- project 'set aside, no runner slot'): a live workshops project that builds a Still or a Kitchen no standing workshop has is an ESSENTIAL
-- shop. It sorts ahead of the plan's other projects (with the hospital), takes one of the few slots and is never set aside for want of
-- progress; once the shop stands it is an ordinary project again.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(type(tag) == 'table' and tag or {tag = tag})
  df.workshop_type = require('dfllm.util.k_mock').enum{'Carpenters', 'Still', 'Kitchen'}
  W.load(runner)
  return W
end
local function shop_doc(x, types)
  local ws = {}
  for _, t in ipairs(types) do ws[#ws + 1] = {type = t, id = 'w' .. t, bbox = {x, 10, 100, x + 2, 12, 100}} end
  return H.doc{x = x, tpl = 'workshops', class = 'infra', params = {only = table.concat(types, ',')},
               manifest = {v = 2, workshops = ws}}
end
local function started(W)
  local s = {}
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do s[c.pos[1]] = true end
  return s
end
local function workshop(W, name)
  local b = W.add_building{type = df.workshop_type[name], getBuildStage = function() return 1 end,
                           getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other.WORKSHOP_ANY:insert('#', b)
end

T.test('BUG-527: a missing Still takes a slot ahead of three older projects', function()
  local W = fresh('b527a')
  for i = 1, 3 do H.place(W, 'p' .. i, H.doc{x = 10 * i}, {tpl = 'bedrooms', site = 'S1', prio = 4}) end
  H.place(W, 'ws', shop_doc(70, {'Still'}), {tpl = 'workshops', site = 'S1', prio = 4})
  H.settle(W); W.frame(1); H.settle(W)
  local s = started(W)
  T.ok(s[70], 'the Still project got a slot (old code: the three older bedrooms projects took all of them)')
  local n = 0
  for _ in pairs(s) do n = n + 1 end
  T.eq(n, 3, 'the slots stay three')
end)

T.test('BUG-527: with a Still standing the shop project is an ordinary one (the oldest first)', function()
  local W = fresh('b527b')
  workshop(W, 'Still')
  for i = 1, 3 do H.place(W, 'p' .. i, H.doc{x = 10 * i}, {tpl = 'bedrooms', site = 'S1', prio = 4}) end
  H.place(W, 'ws', shop_doc(70, {'Still'}), {tpl = 'workshops', site = 'S1', prio = 4})
  H.settle(W); W.frame(1); H.settle(W)
  local s = started(W)
  T.ok(not s[70], 'no priority for a shop that stands')
  T.ok(s[10] and s[20] and s[30])
end)

T.test('BUG-527: a Kitchen project is essential too, a Carpenters project is not', function()
  local W = fresh('b527c')
  for i = 1, 3 do H.place(W, 'p' .. i, H.doc{x = 10 * i}, {tpl = 'bedrooms', site = 'S1', prio = 4}) end
  H.place(W, 'wc', shop_doc(70, {'Carpenters'}), {tpl = 'workshops', site = 'S1', prio = 4})
  H.place(W, 'wk', shop_doc(80, {'Kitchen'}), {tpl = 'workshops', site = 'S1', prio = 4})
  H.settle(W); W.frame(1); H.settle(W)
  local s = started(W)
  T.ok(s[80] and not s[70], 'the Kitchen goes first, the Carpenters wait their turn')
end)

local function row(W, id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end
local function aside(W, id) return ((row(W, id) or {})[4] or ''):find('^set aside') ~= nil end

T.test('BUG-527: an essential shop is never set aside for want of progress, an ordinary project is', function()
  local W = fresh{tag = 'b527d', cfg = {baseline = {v = 2, runner = {queue = {idle_days = 5}}}}}
  H.floor(W, 10, 10, 100, 14, 11)
  H.floor(W, 30, 10, 100, 34, 11)
  H.place(W, 'st', H.doc{x = 10})
  H.place(W, 'ss', shop_doc(30, {'Still'}), {tpl = 'workshops', site = 'S1', prio = 4})
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 2 * 14 do H.runs(W, 1) end
  T.ok(aside(W, 'st'), 'the bedrooms project nobody builds is set aside: ' .. T.show(row(W, 'st')))
  T.ok(not aside(W, 'ss'), 'the Still project keeps its slot: ' .. T.show(row(W, 'ss')))
end)

T.done()
