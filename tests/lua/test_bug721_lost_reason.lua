-- BUG-721 (Run 16a i1 Basementflew / 16b i2 Whirledrampart: 'build_lost at build, missing bed x3' and 'no builder has taken it (no cause readable)' with no
-- word why): a build_lost stage names the tiles its ONE-TILE pieces (beds, chests, tables) stand on when they are no open floor (before only the depot's
-- 5x5 was read, BUG-536); the economy's 'no builder' answer names what it read (tests/lua/test_economy_build_state.lua).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag}
  W.real_bench = true
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function doc()
  local d = H.doc{tpl = 'bedrooms', class = 'living', params = {}, manifest = {v = 2}}
  d.stages[2].chunks[1].cells = {{0, 0, 0, 'b'}, {1, 0, 0, 'b'}, {2, 0, 0, 'b'}, {0, 1, 0, 'R'}}
  return d
end

T.test('BUG-721: a build_lost bedroom names the one-tile pieces that stand on a tree or a stair', function()
  local W = world('lr1')
  H.floor(W, 10, 10, 100, 14, 11)
  W.tile(11, 10, 100).c = 'T'
  W.tile(12, 10, 100).c = '>'
  for _, k in ipairs({'10,10,100', '11,10,100', '12,10,100', '10,11,100'}) do W.unsuitable[k] = true end
  local d = doc()
  H.place(W, 'dr', d)
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 8 do H.runs(W, 1) end
  local P = H.proj(W, 'dr')
  T.eq(P.blocked, 'build_lost', T.show(P))
  local why = runner.lost_why(W.K, P, d)
  T.ok(why and why:find('2 of 4 missing pieces stand on tiles that are no open floor', 1, true), tostring(why))
  T.ok(why:find('11,10,100 tree (bed)', 1, true) and why:find('12,10,100 stair (bed)', 1, true), why)
  H.runs(W, 4)
  local pb = W.find_events('PROJECT_BLOCKED')
  T.ok(#pb >= 1)
  T.ok(pb[1].msg:find('no open floor', 1, true), pb[1].msg)
end)

T.test('BUG-721: one-tile pieces on open floor say nothing (the retry text and the material reason stay)', function()
  local W = world('lr2')
  H.floor(W, 10, 10, 100, 14, 11)
  for _, k in ipairs({'10,10,100', '11,10,100', '12,10,100', '10,11,100'}) do W.unsuitable[k] = true end
  local d = doc()
  H.place(W, 'dr', d)
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 8 do H.runs(W, 1) end
  T.eq(runner.lost_why(W.K, H.proj(W, 'dr'), d), nil)
end)

T.done()
