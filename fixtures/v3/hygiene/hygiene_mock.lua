-- SYNTHETIC test harness (not live data): minimal DFHack mock for lua/pilot_hygiene.lua (spec v3-07).
-- Variant of tests/lua_mock/dfhack_mock.lua (copied, not shared). Usage:
--   MOCK_ITEMS=items.json [MOCK_BUILDINGS=b.json] [MOCK_DUMPJOBS=n] lua5.4 hygiene_mock.lua lua/pilot_hygiene.lua <args>
-- items.json: [{id, type, x, y, z, dump, forbid, race, unit_id, hf, bone, rotten, hidden, outside, reach,
--               stockpile, foreign, artifact}]
-- Prints the emitted JSON, then 'STATE [ids with flags.dump=true]'.
local function encode(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' or t == 'number' then return tostring(v) end
  if t == 'string' then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
  if t == 'table' then
    if #v > 0 then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return '{}' end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = encode(k) .. ':' .. encode(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return '"?"'
end

local function decode(str)
  local pos = 1
  local function ws() pos = str:find('[^%s]', pos) or #str + 1 end
  local val
  local function strv()
    local out, i = {}, pos + 1
    while true do
      local c = str:sub(i, i)
      if c == '"' then pos = i + 1 return table.concat(out) end
      if c == '\\' then out[#out + 1] = str:sub(i + 1, i + 1) i = i + 2
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
        ws() local k = strv() ws() pos = pos + 1
        t[k] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == '}' then return t end
      end
    elseif c == '[' then
      local t = {} pos = pos + 1 ws()
      if str:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = str:sub(pos, pos) pos = pos + 1
        if d == ']' then return t end
      end
    elseif c == '"' then return strv()
    elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    else
      local num = str:match('^-?%d+%.?%d*', pos)
      pos = pos + #num
      return tonumber(num)
    end
  end
  return val()
end

local function readjson(env, default)
  local p = os.getenv(env)
  if not p then return default end
  local f = assert(io.open(p, 'r'))
  local raw = f:read('*a') f:close()
  return decode(raw)
end

-- 0-based vectors like DFHack (ipairs starts at index 0)
local VEC = {}
local function vec(items)
  local v = {}
  for i, x in ipairs(items) do v[i - 1] = x end
  return setmetatable(v, { __len = function() return #items end, __vec = VEC })
end
local raw_ipairs = ipairs
function ipairs(t)
  local mt = getmetatable(t)
  if mt and mt.__vec == VEC then
    local n = #t
    return function(_, i) i = i + 1 if i < n then return i, t[i] end end, t, -1
  end
  return raw_ipairs(t)
end

local function enum(names)
  local t = {}
  for i, n in raw_ipairs(names) do t[n] = i - 1; t[i - 1] = n end
  return t
end

local TYPES = { 'BAR', 'SMALLGEM', 'BLOCKS', 'ROUGH', 'BOULDER', 'WOOD', 'CORPSE', 'CORPSEPIECE', 'REMAINS', 'MEAT',
  'FISH', 'FISH_RAW', 'PLANT', 'PLANT_GROWTH', 'THREAD', 'CLOTH', 'GOBLET', 'FIGURINE', 'WEAPON', 'ARMOR', 'SHOES',
  'HELM', 'GLOVES', 'PANTS', 'AMMO', 'FOOD', 'EGG', 'CHEESE', 'GLOB', 'SKIN_TANNED', 'TOOL', 'CRAFTS', 'BARREL', 'BIN' }
df = {
  item_type = enum(TYPES),
  general_ref_type = enum({ 'CONTAINED_IN_ITEM' }),
  building_type = enum({ 'Stockpile', 'Civzone', 'Workshop' }),
  civzone_type = enum({ 'Home', 'Dump', 'Tomb' }),
  job_type = enum({ 'Dig', 'DumpItem', 'StoreItemInStockpile' }),
  global = { plotinfo = { race_id = 572 }, world = {} },
  unit = { find = function() return nil end },
}

local tiles, piles = {}, {}
local items = {}
for _, d in raw_ipairs(readjson('MOCK_ITEMS', {})) do
  local key = d.x .. ',' .. d.y .. ',' .. d.z
  tiles[key] = { hidden = d.hidden or false, outside = d.outside or false, reach = d.reach ~= false }
  if d.stockpile then piles[key] = true end
  local it = { id = d.id, _t = df.item_type[d.type], _x = d.x, _y = d.y, _z = d.z, race = d.race or 100,
               unit_id = d.unit_id or -1, hist_figure_id = d.hf or -1,
               corpse_flags = { bone = d.bone or false },
               flags = { on_ground = true, dump = d.dump or false, forbid = d.forbid or false, rotten = d.rotten or false,
                         foreign = d.foreign or false, artifact = d.artifact or false } }
  assert(it._t, 'unknown type ' .. tostring(d.type))
  function it:getType() return self._t end
  items[#items + 1] = it
end
df.global.world.items = { all = vec(items) }

local blds = {}
for _, b in raw_ipairs(readjson('MOCK_BUILDINGS', {})) do
  local o = { id = b.id, x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z, type = df.civzone_type[b.zone or 'Dump'],
              _bt = df.building_type[b.kind or 'Civzone'] }
  function o:getType() return self._bt end
  blds[#blds + 1] = o
end
df.global.world.buildings = { all = vec(blds) }
local head = { next = nil }
for _ = 1, tonumber(os.getenv('MOCK_DUMPJOBS') or '0') do head.next = { item = { job_type = df.job_type.DumpItem }, next = head.next } end
df.global.world.jobs = { list = head }

local STOCKPILE = { getType = function() return df.building_type.Stockpile end }
function xyz2pos(x, y, z) return { x = x, y = y, z = z } end
dfhack = {
  items = { getGeneralRef = function() return nil end,
            getPosition = function(it) return it._x, it._y, it._z end },
  buildings = { findAtTile = function(p) return piles[p.x .. ',' .. p.y .. ',' .. p.z] and STOCKPILE or nil end },
  maps = { getTileFlags = function(x, y, z) return tiles[x .. ',' .. y .. ',' .. z] or { hidden = false, outside = false } end,
           canWalkBetween = function(_, p) local t = tiles[p.x .. ',' .. p.y .. ',' .. p.z] return not t or t.reach end },
  matinfo = { decode = function() return nil end },
  units = { getCitizens = function() return vec({}) end },
}
local util = { require_fort = function() return true end, emit = function(t) print(encode(t)) end }
local cfg = { FORT_REFS = { { 100, 100, 130 } } }
function reqscript(name)
  if name == 'claude/util' then return util end
  if name == 'claude/config' then return cfg end
  error('reqscript ' .. name)
end

local script = arg[1]
local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
assert(loadfile(script))(table.unpack(args))
local dumped = {}
for _, it in raw_ipairs(items) do if it.flags.dump then dumped[#dumped + 1] = it.id end end
io.write('STATE ')
print(encode(dumped))
