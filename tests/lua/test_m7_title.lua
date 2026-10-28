-- BUG-120 (Run 14 note 99): `dfhack-run dfllm status` at the title screen says so, with no number of the last fort.
local T = require('testlib')
local H = require('kern_world')

local REPO = (debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')):match('^(.*)/tests/lua/[^/]+$')

local function status_out()
  local out = {}
  local saved_print = print
  print = function(...) out[#out + 1] = table.concat({...}, '\t') end
  local ok, err = pcall(function() assert(loadfile(REPO .. '/lua/dfllm.lua'))('status') end)
  print = saved_print
  assert(ok, err)
  return out
end

T.test('dfllm status without a map: the title screen line, not "kernel not running"', function()
  H.world{tag = 'title'}
  dfhack.findScript = function(name) return REPO .. '/lua/' .. name .. '.lua' end
  local real = dfhack.isMapLoaded
  dfhack.isMapLoaded = function() return false end
  local out = status_out()
  dfhack.isMapLoaded = real
  T.eq(out, {'dfllm: DF at title screen: no fort loaded (kernel not running)'})
  out = status_out()
  T.eq(out, {'dfllm: kernel not running'}, 'a map is loaded but the kernel is not: as before')
end)

T.done()
