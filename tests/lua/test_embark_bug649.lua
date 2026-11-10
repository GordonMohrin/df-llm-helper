-- BUG-649 (Run 16b i2 Valleyhame y372: 'no stream shown; light aquifer as well source' was a warning, the brook lay 13 embark tiles away,
-- the fort's only water was its aquifer: drink 0 d on day 78, STRANDED): no brook in the rectangle with a light aquifer is a FAIL (acceptable
-- with a reason, 'water' is in C.ACCEPTABLE) and the text says the panel's light aquifer is a class, not a span.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local C = require('embark.checklist')

local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end
local REC = {read = 5, aquifer = 'light', soil = 'some', trees = 'woodland', metals = {'iron'}, flux = true, evil = 'neutral',
             savagery = 'low', temperature = 'temperate', warnings = {}}

T.test('BUG-649: light aquifer and no brook in the rectangle fails the water item, and says the span is unknown', function()
  local r = C.evaluate(REC, nil, {})
  local it = item(r, 'water')
  T.eq(it.res, 'fail')
  T.ok(it.why:find('no brook or river in the rectangle', 1, true) and it.why:find('class, not a span', 1, true)
       and it.why:find('8 heavy layers', 1, true), it.why)
  local has = false
  for _, id in ipairs(r.fails) do if id == 'water' then has = true end end
  T.ok(has, 'water is in fails')
  local acc = false
  for _, id in ipairs(C.ACCEPTABLE) do if id == 'water' then acc = true end end
  T.ok(acc, 'water can be accepted with a reason')
end)

T.test('BUG-649: a sweep (a few hovered tiles) stays a warning, and a brook in the rectangle passes', function()
  local r = C.evaluate(REC, nil, {sweep = true})
  T.eq(item(r, 'water').res, 'warn')
  T.ok(item(r, 'water').why:find('not a span', 1, true), item(r, 'water').why)
  local rec2 = {}
  for k, v in pairs(REC) do rec2[k] = v end
  rec2.water = 'brook'
  T.eq(item(C.evaluate(rec2, nil, {}), 'water').res, 'pass')
end)

T.done()
