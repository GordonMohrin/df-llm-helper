-- fix24-embark (Run 16a i1 Manorsubtle died of thirst): BUG-426 bare-mountain brook fails water, BUG-427 a sweep stops
-- hovering a world tile whose first tile already rules it out. Fake DF screens as in test_embark_fix22.lua.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local json = require('dfllm.util.json')
local C = require('embark.checklist')
local S = require('embark.steps')

local function slurp(p)
  local f = assert(io.open(p, 'rb'))
  local s = f:read('a')
  f:close()
  return s
end
local RULES = json.decode(slurp(repo .. '/tools/embark/rules.json'))
RULES.dark_fortresses_seen = {{name = 'far', w = {0, 0}}}
local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end

local function rec(extra)
  local r = {read = 8, warnings = {}, rivers = {'brook'}, water = 'brook', trees = 'woodland', aquifer = 'none',
    soil = 'none', temperature = 'temperate', evil = 'neutral', savagery = 'low', surroundings = 'calm',
    metals = {'iron'}, neighbors = {}, terrain = 'mountain', biome = 'mountain'}
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
local CTX = {world = {8, 30}, size = {4, 4}}

T.test('BUG-426: a brook on a bare mountain (no soil, no aquifer) fails water; soil or an aquifer or a mixed biome does not', function()
  local r = C.evaluate(rec(), RULES, CTX)
  local w = item(r, 'water')
  T.eq(w.res, 'fail'); T.ok(w.why:find('mountain: no soil, brook in a gully', 1, true), w.why)
  T.eq(r.verdict, 'reject')
  T.ok(C.ACCEPTABLE_SET.water, 'a player can still accept it with a reason')
  T.eq(item(C.evaluate(rec({soil = 'little'}), RULES, CTX), 'water').res, 'pass', 'soil: a brook bank to dig from')
  T.eq(item(C.evaluate(rec({aquifer = 'light'}), RULES, CTX), 'water').res, 'pass', 'light aquifer: a well')
  T.eq(item(C.evaluate(rec({terrain = 'land', biome = 'forest'}), RULES, CTX), 'water').res, 'pass')
  -- merged tiles: all mountain without soil -> dry; one soiled tile -> not
  local dry = S.merge_tiles(rec(), {{rivers = {'brook'}, terrain = 'mountain', soil = 'none'},
    {rivers = {}, terrain = 'mountain', soil = 'none'}})
  T.eq({dry.tiles.terrain, dry.tiles.mountain, dry.tiles.soiled}, {2, 2, 0})
  T.eq(item(C.evaluate(dry, RULES, CTX), 'water').res, 'fail')
  local wet = S.merge_tiles(rec(), {{rivers = {'brook'}, terrain = 'mountain', soil = 'none'},
    {rivers = {}, terrain = 'mountain', soil = 'some'}})
  T.eq(wet.tiles.soiled, 1)
  T.eq(item(C.evaluate(wet, RULES, CTX), 'water').res, 'pass')
  -- ranking: the bare mountain sits below a soil + brook-bank rectangle
  local good = C.evaluate(rec({soil = 'little', terrain = 'land', biome = 'forest'}), RULES, CTX)
  T.ok(good.score > r.score and good.verdict ~= 'reject', 'soil + brook ranks above the bare mountain')
end)

T.test('BUG-427: sweep_dead names the properties that rule a world tile out from its first tile', function()
  T.eq(S.sweep_dead(rec()), nil)
  T.eq(S.sweep_dead(rec({aquifer = 'heavy'})), 'heavy aquifer')
  T.eq(S.sweep_dead(rec({terrain = 'water'})), 'water')
  T.eq(S.sweep_dead(rec({evil = 'evil'})), 'evil')
  T.eq(S.sweep_dead(rec({savagery = 'high'})), 'savagery')
  T.eq(S.sweep_dead(rec({ice = true})), 'ice')
end)

T.done()
