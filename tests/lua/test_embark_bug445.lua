-- BUG-445 (Run 16b i2 Roadvises 25,21: the embark panel said 'light aquifer', the site holds four aquifer levels, z112 and z115 heavy):
-- the checklist's aquifer item says the panel shows a class, not the span; the verdict is unchanged (warn).
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local C = require('embark.checklist')

local function item(r, id) for _, it in ipairs(r.items) do if it.id == id then return it end end end

T.test('BUG-445: a light aquifer is a warn that names the unknown span (several levels, heavy ones too); none stays a plain pass', function()
  local r = C.evaluate({read = 5, aquifer = 'light', soil = 'deep', trees = 'woodland', water = 'brook', metals = {'iron'},
                        flux = true, evil = 'neutral', savagery = 'low', temperature = 'temperate', warnings = {}}, nil, {})
  local it = item(r, 'aquifer')
  T.eq(it.res, 'warn')
  T.ok(it.why:find('light', 1, true) and it.why:find('not the span', 1, true) and it.why:find('heavy ones too', 1, true)
       and it.why:find('aqshaft', 1, true), it.why)
  local r2 = C.evaluate({read = 5, aquifer = 'none', soil = 'deep', trees = 'woodland', water = 'brook', metals = {'iron'},
                         flux = true, evil = 'neutral', savagery = 'low', temperature = 'temperate', warnings = {}}, nil, {})
  T.eq({item(r2, 'aquifer').res, item(r2, 'aquifer').why}, {'pass', 'none'})
end)

T.done()
