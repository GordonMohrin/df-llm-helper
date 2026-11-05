-- BUG-465 (Run 16a-d: all four forts of the world's region1 sat on 8-15 levels of soil under an aquifer and had no hard stone for years,
-- Basementflew: 'light' panel, real light z126/127 over heavy z120-123): a failed stone is a hard reject (not acceptable), the item names the
-- estimated levels down to the hard stone (soil + the aquifer class's span), a reachable stone scores higher, the merge counts the aquifer
-- classes of the hovered tiles.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local C = require('embark.checklist')
local S = require('embark.steps')

local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end
local function rec(o)
  local r = {read = 6, trees = 'woodland', water = 'brook', metals = {'iron'}, flux = true, evil = 'neutral', savagery = 'low',
             temperature = 'temperate', warnings = {}, aquifer = 'none', soil = 'little'}
  for k, v in pairs(o or {}) do r[k] = v end
  return r
end
local ctx = {world = {8, 30}, size = {4, 4}}

T.test('BUG-465: stone is a hard reject, never acceptable; only an unknown depth can be waived', function()
  T.ok(not C.ACCEPTABLE_SET.stone and C.WAIVABLE_SET.stone, 'waivable (unknown depth), not acceptable')
  T.ok(C.HARD_REJECT.stone:find('cannot be accepted', 1, true))
  local r = C.evaluate(rec{soil = 'very_deep', aquifer = 'light'}, nil, ctx)
  T.eq(item(r, 'stone').res, 'fail')
  T.ok(item(r, 'stone').why:find('hard reject: no hard stone within reach, this site cannot be accepted', 1, true), item(r, 'stone').why)
  T.ok(item(r, 'stone').why:find('about 19 levels to the hard stone (15 soil + about 4 of the light aquifer)', 1, true), item(r, 'stone').why)
  T.eq({r.verdict, r.stone_levels, r.aquifer_span, r.reach}, {'reject', 15, 4, 19})
  local r2 = C.evaluate(rec{soil = 'extremely_deep'}, nil, ctx)
  T.eq({item(r2, 'stone').res, r2.reach, r2.aquifer_span}, {'fail', 25, nil})
end)

T.test('BUG-465: the reach adds the aquifer class\'s span; a warning loses score per soil level; a pass costs nothing', function()
  local near = C.evaluate(rec{soil = 'little'}, nil, ctx)                       -- 1 level: pass
  T.eq({item(near, 'stone').res, near.reach, near.stone_pen}, {'pass', 1, 0})
  local some = C.evaluate(rec{soil = 'some'}, nil, ctx)                         -- 3 levels: warn, 3 per level beyond the 2 of a pass
  T.eq({item(some, 'stone').res, some.reach, some.stone_pen}, {'warn', 3, 3})
  T.eq(some.score, near.score - 12 - 3, 'one warn (12) and the stone penalty (3)')
  local aq = C.evaluate(rec{soil = 'some', aquifer = 'varied'}, nil, ctx)
  T.eq({item(aq, 'stone').res, aq.reach, aq.aquifer_span}, {'warn', 9, 6})
  T.ok(item(aq, 'stone').why:find('about 9 levels to the hard stone (3 soil + about 6 of the varied aquifer)', 1, true), item(aq, 'stone').why)
  local unk = C.evaluate(rec{soil = 'unknown_value_not_in_table'}, nil, ctx)
  T.eq(unk.reach, nil)
  local nosoil = rec{}
  nosoil.soil = nil
  local none = C.evaluate(nosoil, nil, ctx)
  T.eq({item(none, 'stone').res, none.reach}, {'unknown', nil})
end)

T.test('BUG-465: merge_tiles counts the hovered tiles per aquifer class', function()
  local base = rec{soil = 'little'}
  local m = S.merge_tiles(base, {{rivers = {}, aquifer = 'light'}, {rivers = {}, aquifer = 'none'}, {rivers = {}, aquifer = 'light'},
                                 {rivers = {}, aquifer = 'heavy'}})
  T.eq(m.tiles.aq_n, {light = 2, none = 1, heavy = 1})
  T.eq(m.aquifer, 'heavy')
  T.eq(S.sweep_rec(m).tiles.aq_n, {light = 2, none = 1, heavy = 1}, 'the compact sweep row keeps it')
end)

T.done()
