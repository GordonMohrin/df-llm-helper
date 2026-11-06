-- BUG-531 (Run 16a i1 Basementflew: 'light' panel, soil 'some', the real aquifer ran z114-z127 with heavy layers at z116/120/123, so no core could
-- be dug under it and the fort never had one): the embark checklist works out how far the hard stone BELOW the aquifer lies (reach = soil
-- levels + the worst span seen for the class (core_span)); above core_reach_warn the aquifer item warns, above core_reach_max it fails
-- (acceptable with a reason). The panel cannot show the real span: it is a warning.
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

T.test('BUG-531: a near core under a light aquifer stays a plain warning (as before)', function()
  local r = C.evaluate(rec{soil = 'little', aquifer = 'light'}, nil, ctx)         -- 1 + 8 = 9: not above core_reach_warn
  T.eq({item(r, 'aquifer').res, r.reach, r.core_reach}, {'warn', 5, nil})
  T.ok(not item(r, 'aquifer').why:find('must go under the aquifer', 1, true), item(r, 'aquifer').why)
end)

T.test('BUG-531: Basementflew (light panel, soil some): the warning says up to 11 levels to the stone below the aquifer', function()
  local r = C.evaluate(rec{soil = 'some', aquifer = 'light'}, nil, ctx)           -- 3 + 8 = 11 > 9
  T.eq({item(r, 'aquifer').res, r.core_reach}, {'warn', 11})
  T.ok(item(r, 'aquifer').why:find('the core must go under the aquifer: up to 11 levels to the hard stone below it (3 soil + up to 8 of the light aquifer)', 1, true),
       item(r, 'aquifer').why)
  T.ok(item(r, 'aquifer').why:find('Basementflew: 14 levels', 1, true))
  local n = 0
  for _, v in ipairs(r.warns) do if v == 'aquifer' then n = n + 1 end end
  T.eq(n, 1, 'one warning entry, not two')
  T.ok(not has(r.fails, 'aquifer'), 'a warning, not a failure, at the default limits')
end)

T.test('BUG-531: no core below the aquifer within reach fails the aquifer criterion (acceptable, not a hard reject)', function()
  local r = C.evaluate(rec{soil = 'some', aquifer = 'light'}, {core_reach_max = 10}, ctx)       -- 11 > 10
  T.eq({item(r, 'aquifer').res, r.core_reach}, {'fail', 11})
  T.ok(item(r, 'aquifer').why:find('no core below the aquifer within reach: up to 11 levels', 1, true), item(r, 'aquifer').why)
  T.ok(has(r.fails, 'aquifer') and not has(r.warns, 'aquifer'), 'moved from the warnings to the failures, once')
  T.ok(C.ACCEPTABLE_SET.aquifer and not C.HARD_REJECT.aquifer, 'the player may accept it with a reason')
  T.eq(r.verdict, 'reject')
  local n = 0
  for _, v in ipairs(r.fails) do if v == 'aquifer' then n = n + 1 end end
  T.eq(n, 1)
end)

T.test('BUG-531: a site whose stone item fails already (deep soil) is not failed a second time for the core; no aquifer: no check', function()
  local deep = C.evaluate(rec{soil = 'very_deep', aquifer = 'light'}, nil, ctx)
  T.eq(item(deep, 'stone').res, 'fail')
  T.eq({item(deep, 'aquifer').res, deep.core_reach}, {'warn', nil})
  local none = C.evaluate(rec{soil = 'some', aquifer = 'none'}, nil, ctx)
  T.eq({item(none, 'aquifer').res, none.core_reach}, {'pass', nil})
end)

T.test('BUG-531: the rules file carries the limits (rules.json = the defaults)', function()
  local f = assert(io.open(repo .. '/tools/embark/rules.json', 'rb'))
  local text = f:read('*a')
  f:close()
  T.ok(text:find('"core_reach_warn": ' .. C.DEFAULT.core_reach_warn, 1, true))
  T.ok(text:find('"core_reach_max": ' .. C.DEFAULT.core_reach_max, 1, true))
  T.ok(text:find('"core_span": {"light": ' .. C.DEFAULT.core_span.light .. ', "varied": ' .. C.DEFAULT.core_span.varied ..
                 ', "heavy": ' .. C.DEFAULT.core_span.heavy .. '}', 1, true))
end)

T.done()
