-- BUG-584 (Run 16d i4 Trumpetrealms y412-y415: four explore probes in a mudstone fort found 'no ore, no hard stone' and nobody could tell which
-- rock the shafts had passed): the PROJECT_DONE of a finished explore names the rock layers of its stair column, top down, one entry per run of
-- one stone, in the message and in d.rocks; other templates and unreadable layers add nothing.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local LM0 = runner.layer_mat

local function explore_doc(ax, ay, az, depth)
  local chunks = {}
  for w = 0, -depth, -1 do
    chunks[#chunks + 1] = {pos = {ax, ay + 1, az + w}, cells = {{0, 0, 0, w == 0 and 'j' or (w == -depth and 'u' or 'i')}}}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {depth = depth, arm = 0, every = 3, avoid = ''},
          anchor = {ax, ay, az}, rot = 0, stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}},
          manifest = {v = 2}, materials = {}}
end

local function finish(layers)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  runner.layer_mat = layers
  local W = H.world{tag = 'rocks', map_size = {16, 16, 160}}
  W.load(runner)
  H.place(W, 'ex1', explore_doc(10, 10, 100, 6))
  H.runs(W, 1)
  H.dig(W)
  for z = 100, 94, -1 do local t = W.tile(10, 11, z); t.c, t.dig = z == 100 and '>' or 'X', '' end
  H.runs(W, 6)
  return W
end

T.test('BUG-584: a finished explore names the rock layers of its shaft, one entry per run', function()
  local W = finish(function(x, y, z)
    if x ~= 10 or y ~= 11 then return nil end
    return z >= 98 and 'MUDSTONE' or 'LIMESTONE'
  end)
  runner.layer_mat = LM0
  local ev
  for _, e in ipairs(W.find_events('PROJECT_DONE')) do if e.d.proj == 'ex1' then ev = e end end
  T.ok(ev, 'explore done: ' .. T.show(H.proj(W, 'ex1')))
  T.eq(ev.d.rocks, {'MUDSTONE z100-z98', 'LIMESTONE z97-z94'})
  T.ok(ev.msg:find('rock: MUDSTONE z100-z98, LIMESTONE z97-z94', 1, true), ev.msg)
end)

T.test('BUG-584: an unreadable layer adds nothing (no rocks key), the project is done all the same', function()
  local W = finish(function() return nil end)
  runner.layer_mat = LM0
  local ev
  for _, e in ipairs(W.find_events('PROJECT_DONE')) do if e.d.proj == 'ex1' then ev = e end end
  T.ok(ev and ev.d.rocks == nil and not ev.msg:find('rock:', 1, true), ev and ev.msg)
end)

T.done()
