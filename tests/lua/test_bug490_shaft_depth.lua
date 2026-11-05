-- BUG-490 (Run 16a i1 Basementflew: aqshaft p.depth 16 ended at z125 after the first light level and two dry levels, AQ_PASS_DONE,
-- PROJECT_DONE, with the heavy levels z123/z120/z116 below): a shaft is not passed while a known aquifer level lies below it within
-- its depth; below the depth the pass says which levels are left. The level list is one: a recorded heavy level is in the
-- manifest's aquifer_levels too.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function ev(W, t) return W.find_events(t) end
local function until_(W, fn, max)
  for _ = 1, max or 20 do
    if fn() then return true end
    H.runs(W, 1)
  end
  return fn()
end

local AX, AY, AT = 50, 50, 100
local function shaft_doc(depth)
  local stages = {}
  for i = 0, depth - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0,
          params = {x = AX, y = AY, top = AT, dry_levels = 2, depth = depth, mode = 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end
local ORTH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function aquifer_level(W, z)
  for _, o in ipairs(ORTH) do W.tile(AX + o[1], AY + o[2], z).aq = true end
end
-- run the shaft down to the level z whose tile is designated, digging every level on the way
local function down_to(W, z)
  for _ = 1, 40 do
    if W.tile(AX, AY, z).dig == 'i' then return true end
    H.dig(W)
    H.runs(W, 1)
  end
  return W.tile(AX, AY, z).dig == 'i'
end

T.test('BUG-490: two dry levels do not pass a shaft while a known aquifer level lies below within its depth', function()
  local W = fresh{tag = 'b490cont'}
  aquifer_level(W, 99)
  local rt = W.K.persist.get('m.runner')
  rt.aql = {92, 99}                                  -- z92 was seen damp elsewhere: inside the depth (z91..z100)
  H.place(W, 'aq', shaft_doc(10))
  H.runs(W, 1)
  T.ok(down_to(W, 96), 'the shaft goes past z97, where it was passed before')
  T.eq(#ev(W, 'AQ_PASS_DONE'), 0, 'not passed: z92 lies below')
  T.eq(H.proj(W, 'aq').done, 0)
end)

T.test('BUG-490: the known levels under the depth are said in AQ_PASS_DONE (rest), the shaft still ends there', function()
  local W = fresh{tag = 'b490rest'}
  aquifer_level(W, 99)
  local rt = W.K.persist.get('m.runner')
  rt.aql = {80, 99}                                  -- below z95 (the shaft's depth 6)
  H.place(W, 'aq', shaft_doc(6))
  H.runs(W, 1)
  T.ok(until_(W, function() H.dig(W); return #ev(W, 'AQ_PASS_DONE') == 1 end, 40), 'passed at the depth / two dry levels')
  local p = ev(W, 'AQ_PASS_DONE')[1]
  T.eq(p.d.rest, {80})
  T.ok(p.msg:find('NOT passed', 1, true), p.msg)
end)

T.test('BUG-490: a recorded heavy level joins the manifest aquifer_levels (one list)', function()
  local W = fresh{tag = 'b490list'}
  runner.aq_seen(W.K, 119)
  runner.hv_level(W.K, 123)
  local l = W.K.manifest().aquifer_levels
  T.eq({l[1], l[2]}, {119, 123})
  T.eq(runner.aq_below(125), {123, 119})
  T.eq(runner.aq_below(120), {119})
end)

T.done()
