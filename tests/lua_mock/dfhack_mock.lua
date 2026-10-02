-- Minimaler Mock fuer DFHack (nur was pilot_*.lua brauchen). Nutzung:
--   lua5.4 tests/lua_mock/dfhack_mock.lua <skript.lua> [args...]
local function enum(names)
  local t = {}
  for i, n in ipairs(names) do t[n] = i - 1; t[i - 1] = n end
  return t
end
local function vec(items) local v = {} for i, x in ipairs(items) do v[i - 1] = x end
  return setmetatable(v, { __len = function() return #items end }) end

-- sehr kleiner JSON-Encoder (deterministisch, Schluessel sortiert)
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

-- minimaler JSON-Decoder (Objekte, Listen, Strings, Zahlen, true/false/null)
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
        assert(d == ',', 'Komma erwartet')
      end
    elseif c == '[' then
      local t = {} pos = pos + 1 ws()
      if str:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == ']' then return t end
        assert(d == ',', 'Komma erwartet')
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

df = {
  work_detail_mode = enum({ 'EverybodyDoesThis', 'NobodyDoesThis', 'OnlySelectedDoesThis' }),
  global = { plotinfo = { labor_info = { work_details = nil } },
             world = { status = { reports = {} }, map = { x_count = 200, y_count = 200, z_count = 200 } } },
}
local M = df.work_detail_mode
df.global.plotinfo.labor_info.work_details = vec({
  { name = 'Stonecutters', flags = { mode = M.EverybodyDoesThis } },
  { name = 'Miners', flags = { mode = M.OnlySelectedDoesThis } },
})
dfhack = { isMapLoaded = function() return true end, df2utf = function(s) return s end,
           run_command_silent = function(cmd, ...)
             local args = { ... }
             if cmd == 'boom' then error('intentional error') end
             if cmd == 'bad' then return 'kaputt', 1 end
             if cmd == 'big' then return string.rep('x', 100), 0 end
             if cmd == 'utf8' then return string.rep('\195\164', 60), 0 end   -- 60 x 'ä' (2 bytes each)
             return 'out:' .. cmd .. (#args > 0 and (' ' .. table.concat(args, ' ')) or ''), 0
           end }
CR_OK = 0
MOCK_OUT = {}
local util = { require_fort = function() return true end,
               emit = function(t) MOCK_OUT[#MOCK_OUT + 1] = t; print(encode(t)) end }
package.loaded['json'] = { encode = encode, decode = decode }
local mock_cfg = { FORT_X = tonumber(os.getenv('MOCK_FORT_X') or ''), FORT_Y = tonumber(os.getenv('MOCK_FORT_Y') or '') }
function reqscript(name)
  if name == 'claude/util' then return util end
  if name == 'claude/config' then return mock_cfg end
  error('reqscript ' .. name)
end
_G.json_encode = encode

-- Einheiten fuer Tests: Umgebungsvariable MOCK_UNITS = Pfad zu JSON-Liste
-- [{id, merchant, citizen, pet, fort, left}] -> df.global.world.units.active + dfhack.units.is*
do
  local up = os.getenv('MOCK_UNITS')
  local units = {}
  if up then
    local f = io.open(up, 'r')
    local raw = f:read('*a') f:close()
    for _, u in ipairs(decode(raw)) do
      units[#units + 1] = { id = u.id, flags1 = { left = u.left or false }, _m = u.merchant, _c = u.citizen, _p = u.pet,
                            _f = u.fort }
    end
  end
  df.global.world.units = { active = units }
  dfhack.units = { isMerchant = function(u) return u._m == true end, isCitizen = function(u) return u._c == true end,
                   isPet = function(u) return u._p == true end, isFortControlled = function(u) return u._f == true end }
  MOCK_UNITS_LIST = units
end

-- Kacheln fuer Tests: MOCK_TILES = Pfad zu JSON-Liste [{x,y,z,flow,magma,hidden,shape}]; sonst Wand, trocken, entdeckt
do
  local tp = os.getenv('MOCK_TILES')
  local tiles = {}
  if tp then
    local f = io.open(tp, 'r')
    local raw = f:read('*a') f:close()
    for _, t in ipairs(decode(raw)) do tiles[t.x .. ',' .. t.y .. ',' .. t.z] = t end
  end
  df.tile_liquid = enum({ 'Water', 'Magma' })
  df.tiletype_shape = enum({ 'WALL', 'FLOOR', 'RAMP', 'STAIR_UPDOWN', 'EMPTY' })
  df.tiletype = { attrs = setmetatable({}, { __index = function(_, k) return { shape = df.tiletype_shape[k] } end }) }
  dfhack.maps = {
    getTileFlags = function(x, y, z)
      local t = tiles[x .. ',' .. y .. ',' .. z] or {}
      return { hidden = t.hidden or false, flow_size = t.flow or 0,
               liquid_type = t.magma and df.tile_liquid.Magma or df.tile_liquid.Water }
    end,
    getTileType = function(x, y, z) local t = tiles[x .. ',' .. y .. ',' .. z] or {} return t.shape or 'WALL' end,
  }
end

local script = arg[1]
local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
local chunk = assert(loadfile(script))
chunk(table.unpack(args))
if os.getenv('MOCK_UNITS') then
  local left = {}
  for _, u in ipairs(MOCK_UNITS_LIST) do if u.flags1.left then left[#left + 1] = u.id end end
  io.write('LEFT ') print(encode(left))
end
-- Zustand nach dem Lauf fuer Tests
io.write('STATE ')
local st = {}
for i = 0, #df.global.plotinfo.labor_info.work_details - 1 do
  local d = df.global.plotinfo.labor_info.work_details[i]
  st[d.name] = M[d.flags.mode]
end
print(encode(st))
