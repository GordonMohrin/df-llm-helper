-- Grid mock for the v3 features reach/perimeter/digcheck (own copy; tests/lua_mock/dfhack_mock.lua stays untouched).
-- Usage: lua5.4 tests/lua_mock/grid_mock.lua <script.lua> [args...]
-- MOCK_GRID = path to JSON [{x,y,z,c,g}] (c = tile character of df_llm_helper/features/_grid.py, g = walk group for
-- canWalkBetween); tiles not listed are natural wall. MOCK_HOME = df-llm-helper home (perimeter result file).
-- MOCK_MAP = "x,y,z" map size (default 200,200,200). dfhack.timeout callbacks run after the script returns.
-- tiny JSON encoder (deterministic, sorted keys)
local function encode(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' or t == 'number' then return tostring(v) end
  if t == 'string' then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"' end
  if t == 'table' then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = encode(k) .. ':' .. encode(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return '"?"'
end

-- minimal JSON decoder (objects, lists, strings, numbers, true/false/null)
local function decode(str)
  local pos = 1
  local function ws() pos = str:find('[^%s]', pos) or #str + 1 end
  local val
  local function strv()
    local out, i = {}, pos + 1
    while true do
      local c = str:sub(i, i)
      if c == '"' then pos = i + 1 return table.concat(out) end
      if c == '\\' then
        local n = str:sub(i + 1, i + 1)
        out[#out + 1] = ({ n = '\n', t = '\t' })[n] or n
        i = i + 2
      elseif c == '' then error('string without end')
      else out[#out + 1] = c i = i + 1 end
    end
  end
  function val()
    ws()
    local c = str:sub(pos, pos)
    if c == '{' then
      local t = {} pos = pos + 1 ws()
      if str:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        ws() local k = strv() ws() assert(str:sub(pos, pos) == ':') pos = pos + 1
        t[k] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == '}' then return t end
        assert(d == ',', 'comma expected')
      end
    elseif c == '[' then
      local t = {} pos = pos + 1 ws()
      if str:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == ']' then return t end
        assert(d == ',', 'comma expected')
      end
    elseif c == '"' then return strv()
    elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    else
      local num = str:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
      if not num or num == '' then error('JSON unreadable at ' .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local r = val()
  return r
end


local function enum(names)
  local t = {}
  for i, nm in ipairs(names) do t[nm] = i - 1; t[i - 1] = nm end
  return t
end

local mx, my, mz = (os.getenv('MOCK_MAP') or '200,200,200'):match('(%d+),(%d+),(%d+)')
df = {
  tiletype_shape = enum({ 'NONE', 'EMPTY', 'FLOOR', 'BOULDER', 'PEBBLES', 'WALL', 'FORTIFICATION', 'STAIR_UP',
                          'STAIR_DOWN', 'STAIR_UPDOWN', 'RAMP', 'RAMP_TOP', 'BROOK_BED', 'BROOK_TOP', 'TRUNK_BRANCH',
                          'SHRUB', 'SAPLING', 'TWIG', 'ENDLESS_PIT' }),
  tiletype_material = enum({ 'NONE', 'STONE', 'SOIL', 'CONSTRUCTION' }),
  tile_liquid = enum({ 'Water', 'Magma' }),
  building_type = enum({ 'Chair', 'Bed', 'Door', 'Hatch', 'Trap', 'Workshop', 'Well' }),
  tile_building_occ = enum({ 'None', 'Planned', 'Passable', 'Obstacle', 'Well', 'Floor', 'Impassable', 'Dynamic' }),
  global = { world = { map = { x_count = tonumber(mx), y_count = tonumber(my), z_count = tonumber(mz) } } },
}
local S, MAT = df.tiletype_shape, df.tiletype_material
-- tiletype "ids" are strings here; attrs[id] -> {shape, material} like the real df.tiletype.attrs
local TT = {
  WALL = { shape = S.WALL, material = MAT.STONE }, CWALL = { shape = S.WALL, material = MAT.CONSTRUCTION },
  FLOOR = { shape = S.FLOOR, material = MAT.STONE }, EMPTY = { shape = S.EMPTY, material = MAT.NONE },
  STAIR_UPDOWN = { shape = S.STAIR_UPDOWN, material = MAT.STONE }, STAIR_UP = { shape = S.STAIR_UP, material = MAT.STONE },
  STAIR_DOWN = { shape = S.STAIR_DOWN, material = MAT.STONE }, RAMP = { shape = S.RAMP, material = MAT.STONE },
}
df.tiletype = { attrs = TT }
-- character -> {tiletype, outside, subterranean, water_table, flow, magma, hidden, building}
local CH = {
  ['?'] = { 'WALL', hidden = true }, ['#'] = { 'WALL' }, A = { 'WALL', water_table = true }, C = { 'CWALL' },
  ['.'] = { 'FLOOR' }, [','] = { 'FLOOR', outside = true }, X = { 'STAIR_UPDOWN' }, x = { 'STAIR_UPDOWN', outside = true },
  ['<'] = { 'STAIR_UP' }, ['>'] = { 'STAIR_DOWN' }, ['^'] = { 'RAMP' }, ['/'] = { 'RAMP', outside = true },
  ['_'] = { 'EMPTY', subterranean = false }, ["'"] = { 'EMPTY', outside = true, subterranean = false },
  V = { 'EMPTY' }, ['~'] = { 'FLOOR', flow = 7 }, M = { 'FLOOR', flow = 7, magma = true },
  D = { 'FLOOR', building = 'Door' }, T = { 'FLOOR', building = 'Trap' },
  -- BUG-424: door whose block occupancy reads as blocking (worst case of a forbidden/locked door): still a way in
  L = { 'FLOOR', building = 'Door', occ = 'Obstacle' },
  W = { 'EMPTY', building = 'Well', occ = 'Well' },      -- well: open space in DF, blocks walking (walk group 0)
}
local tiles = {}
do
  local gp = os.getenv('MOCK_GRID')
  if gp then
    local f = assert(io.open(gp, 'r'))
    local raw = f:read('*a') f:close()
    for _, t in ipairs(decode(raw)) do tiles[t.x .. ',' .. t.y .. ',' .. t.z] = t end
  end
end
local function tile(x, y, z)
  local t = tiles[x .. ',' .. y .. ',' .. z]
  return t, CH[t and t.c or '#'] or CH['#']
end
MOCK_CALLS = { flags = 0 }
function xyz2pos(x, y, z) return { x = x, y = y, z = z } end
local timeouts = {}
dfhack = {
  isMapLoaded = function() return true end, df2utf = function(s) return s end,
  timeout = function(n, unit, fn) timeouts[#timeouts + 1] = fn return #timeouts end,
  filesystem = { mkdir_recursive = function() return true end },
  maps = {
    getTileFlags = function(x, y, z)
      MOCK_CALLS.flags = MOCK_CALLS.flags + 1
      local _, c = tile(x, y, z)
      return { hidden = c.hidden or false, outside = c.outside or false,
               subterranean = c.subterranean ~= false and not c.outside, water_table = c.water_table or false,
               flow_size = c.flow or 0, liquid_type = c.magma and df.tile_liquid.Magma or df.tile_liquid.Water }
    end,
    getTileType = function(x, y, z) local _, c = tile(x, y, z) return c[1] end,
    -- block with occupancy[x%16][y%16].building (tile_building_occ value)
    getTileBlock = function(x, y, z)
      local bx, by = x - x % 16, y - y % 16
      return { occupancy = setmetatable({}, { __index = function(_, xi)
        return setmetatable({}, { __index = function(_, yi)
          local _, c = tile(bx + xi, by + yi, z)
          return { building = df.tile_building_occ[c.occ or 'None'] }
        end })
      end }) }
    end,
    canWalkBetween = function(p1, p2)
      local a = tiles[p1.x .. ',' .. p1.y .. ',' .. p1.z]
      local b = tiles[p2.x .. ',' .. p2.y .. ',' .. p2.z]
      return a ~= nil and b ~= nil and (a.g or 0) > 0 and a.g == b.g
    end,
  },
  buildings = {
    findAtTile = function(x, y, z)
      local _, c = tile(x, y, z)
      if not c.building then return nil end
      local bt = df.building_type[c.building]
      return { getType = function() return bt end, x1 = x, y1 = y, x2 = x, y2 = y }
    end,
  },
}
local util = { require_fort = function() return true end,
               emit = function(t) print(encode(t)) end,
               home = function() return os.getenv('MOCK_HOME') or '.' end }
package.loaded['json'] = { encode = encode, decode = decode }
function reqscript(name)
  if name == 'claude/util' then return util end
  -- the grid fixtures are small synthetic maps: no enclave filter in pilot_perimeter (MOCK_MINCOMP to test it)
  -- MOCK_CORE = "x,y,z,zmin,zmax" -> FORT_REFS[1] / Z_MIN / Z_MAX of the fort config (BUG-424: '-' arguments)
  if name == 'claude/config' then
    local c = { PERIMETER_MINCOMP = tonumber(os.getenv('MOCK_MINCOMP') or '1') }
    local x, y, z, z1, z2 = (os.getenv('MOCK_CORE') or ''):match('(%d+),(%d+),(%d+),(%d+),(%d+)')
    if x then c.FORT_REFS, c.Z_MIN, c.Z_MAX = { { tonumber(x), tonumber(y), tonumber(z) } }, tonumber(z1), tonumber(z2) end
    return c
  end
  error('reqscript ' .. name)
end

local script = arg[1]
local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
local chunk = assert(loadfile(script))
chunk(table.unpack(args))
local ticks = 0
while #timeouts > 0 do
  local fn = table.remove(timeouts, 1)
  ticks = ticks + 1
  fn()
end
io.stderr:write('MOCK ticks=' .. ticks .. ' flags=' .. MOCK_CALLS.flags .. '\n')
