-- BUG-690 (Run 16b i2 Rocksblush: 'trees' accepted on a site with no trees and its hard stone 5 levels down; 0 logs, 0 stone, 0 blocks, every
-- workshop, the depot and the shaft waited for 'no rock, no blocks, no logs'): no trees and no stone near the surface is a hard reject ('timber')
-- that '--accept trees' alone cannot clear; trees accepted with stone at the surface (or a sparse forest) stay as they were.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local C = require('embark.checklist')

local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end
local function rec(o)
  local r = {read = 6, trees = 'woodland', water = 'brook', metals = {'iron'}, flux = true, evil = 'neutral', savagery = 'low',
             temperature = 'temperate', warnings = {}, aquifer = 'none', soil = 'little'}
  for k, v in pairs(o or {}) do r[k] = v end
  return r
end
local ctx = {world = {8, 30}, size = {4, 4}}
local function has(list, id) for _, v in ipairs(list) do if v == id then return true end end return false end

T.test('BUG-690: no trees and the stone 3+ levels down is a hard reject nobody can accept', function()
  T.ok(C.HARD_REJECT.timber and not C.ACCEPTABLE_SET.timber and not C.WAIVABLE_SET.timber, 'hard reject, not acceptable, not waivable')
  local r = C.evaluate(rec{trees = 'none', soil = 'some'}, nil, ctx)         -- Rocksblush: hard stone ~5 levels
  T.eq(item(r, 'stone').res, 'warn')
  T.eq(item(r, 'trees').res, 'fail')
  T.eq(item(r, 'timber').res, 'fail')
  T.ok(item(r, 'timber').why:find('accepting trees cannot clear it', 1, true), item(r, 'timber').why)
  T.ok(has(r.fails, 'timber') and not C.ACCEPTABLE_SET.timber, 'a gate that accepts only trees still refuses')
  T.eq(r.verdict, 'reject')
  local sc = C.evaluate(rec{trees = 'scarce', soil = 'deep'}, nil, ctx)
  T.eq({item(sc, 'timber').res, item(sc, 'stone').res}, {'fail', 'fail'})
end)

T.test('BUG-690: Rocksblush (light aquifer, little soil, no trees): stone passes on soil, the reach 5 still rejects', function()
  local r = C.evaluate(rec{trees = 'none', soil = 'little', aquifer = 'light'}, nil, ctx)
  T.eq(item(r, 'stone').res, 'pass')
  T.eq(r.reach, 5)
  T.eq(item(r, 'timber').res, 'fail')
  T.ok(has(r.fails, 'timber') and not C.ACCEPTABLE_SET.timber, 'accepting trees and the aquifer alone still refuses')
  T.eq(r.verdict, 'reject')
  local ok = C.evaluate(rec{trees = 'woodland', soil = 'little', aquifer = 'light'}, nil, ctx)
  T.eq(item(ok, 'timber'), nil)
end)

T.test('BUG-690: stone near the surface, or any forest, leaves trees as it was (acceptable with a reason)', function()
  local near = C.evaluate(rec{trees = 'none', soil = 'little'}, nil, ctx)
  T.eq(item(near, 'stone').res, 'pass')
  T.eq(item(near, 'timber'), nil)
  T.ok(has(near.fails, 'trees') and C.ACCEPTABLE_SET.trees, 'trees alone: still the player\'s trade-off')
  local sparse = C.evaluate(rec{trees = 'sparse', soil = 'some'}, nil, ctx)
  T.eq(item(sparse, 'timber'), nil)
  local wood = C.evaluate(rec{trees = 'woodland', soil = 'some'}, nil, ctx)
  T.eq(item(wood, 'timber'), nil)
  local nost = rec{trees = 'none'}
  nost.soil = nil
  T.eq(item(C.evaluate(nost, nil, ctx), 'timber'), nil, 'an unknown soil depth stays a review, not a reject')
end)

T.done()
