-- FR-102/103 (G15): the beauty stage of a large room (class beauty: smooth, then engrave) runs only in PEACE with
-- readiness >= 1 and goes stage by stage; finished large rooms and the deep core keep their box for the audit (KEEP_BOX).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end

local function beauty_doc(x, y, z)
  local function st(label, key)
    return {label = label, mode = 'dig', orders = 0, defense = 0,
            chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, key .. '(5x1)'}}}}}
  end
  return {v = 2, tpl = 'suites', site = 'same', class = 'beauty', params = {stage = 2, size = 'large', n = 2},
          anchor = {x, y, z}, rot = 0, stages = {st('beauty.smooth', 's'), st('beauty.engrave', 'e')},
          manifest = {v = 2, rooms = {{id = 'suites' .. x, tpl = 'suites', use = 'used', bbox = {x, y, z, x + 4, y, z},
                                       tier = 1000}}}, materials = {}}
end

local function named(W)
  local r = {}
  for _, e in ipairs(select(2, W.K.call('runner', 'boxes'))) do r[e.id] = e.tpl end
  return r
end

T.test('FR-102: the beauty stage waits for R1, smooths, then engraves, and keeps its box when done', function()
  local W = fresh{tag = 'fr102'}
  H.RESULT.e = 'S'                                   -- the fake engravers leave a smoothed (engraved) wall
  T.ok(H.place(W, 'b1', beauty_doc(10, 10, 100)).ok)
  H.runs(W, 2)
  T.eq(#H.qf_calls(W, 'dig'), 0, 'no readiness module: beauty waits')
  local lvl = 1
  W.load{name = 'readiness', every = {ticks = 33600}, level = function() return lvl end}
  H.runs(W, 1)
  local calls = H.qf_calls(W, 'dig')
  T.ok(#calls >= 1)
  T.eq(W.tile(10, 10, 100).dig, 's')                 -- smoothing designated on the rough wall
  T.eq(W.tile(12, 10, 100).dig, 's')
  H.dig(W); H.runs(W, 2)
  T.eq(W.tile(10, 10, 100).c, 'S')
  T.eq(W.tile(10, 10, 100).dig, 'e', 'the engrave stage follows the smoothing')
  H.dig(W); H.runs(W, 3)
  T.eq(H.proj(W, 'b1').done, 1)
  T.eq(named(W).b1, 'suites', 'a finished large room keeps its box (audit snapshot)')
  H.RESULT.e = nil
end)

T.test('FR-102: beauty never runs outside PEACE or with the plan policy beauty none', function()
  local W = fresh{tag = 'fr102b', plan = {v = 2, year = 3, phase_target = 'P7',
                                          policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
                                          seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}}}}
  W.load{name = 'readiness', every = {ticks = 33600}, level = function() return 2 end}
  T.ok(H.place(W, 'b2', beauty_doc(30, 10, 100)).ok)
  H.runs(W, 2)
  T.eq(#H.qf_calls(W, 'dig'), 0, 'policy beauty none')
end)

T.test('FR-103: a finished deep core stage keeps its box like a room', function()
  local W = fresh{tag = 'fr103'}
  local d = H.dig_doc(1, {tpl = 'deepcore', params = {stage = 1, depth = 3}, class = 'living', label = 's1.dig', x = 50})
  T.ok(H.place(W, 'dc', d).ok)
  for _ = 1, 4 do H.runs(W, 1); H.dig(W) end
  H.runs(W, 3)
  T.eq(H.proj(W, 'dc').done, 1)
  T.eq(named(W).dc, 'deepcore')
end)

T.done()
