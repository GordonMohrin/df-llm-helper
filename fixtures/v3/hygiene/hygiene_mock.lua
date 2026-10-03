-- SYNTHETIC test harness (not live data): minimal DFHack mock for lua/pilot_hygiene.lua (spec v3-07, FEATURE-002) and
-- lua/pilot_forbid.lua (FEATURE-003). Variant of tests/lua_mock/dfhack_mock.lua (copied, not shared). Usage:
--   MOCK_ITEMS=items.json [MOCK_BUILDINGS=b.json] [MOCK_DUMPJOBS=n] [MOCK_ORDERS=o.json] [MOCK_STANDING=s.json]
--   [MOCK_NEXT_ID=n] [MOCK_LOG=file] lua5.4 hygiene_mock.lua lua/pilot_hygiene.lua <args>
-- items.json: [{id, type, x, y, z, dump, forbid, race, unit_id, hf, bone, rotten, hidden, outside, reach,
--               stockpile, foreign, trader, artifact, in_job, in_building, maker (maker race), n (stack size),
--               container (id of the item it sits in; BUG-125)}]
-- b.json: [{id, kind (Civzone|Stockpile|Bridge), x1, y1, x2, y2, z, zone, cats, max_bins, max_barrels, raised, levers}]
-- o.json: [{id, job, left, total, freq, conds: [{cmp, value, type, flags}]}]
-- Prints the emitted JSON, then 'FORBIDDEN [ids]', 'ORDERS [...]', 'MAXBINS [[id, n]...]' and
-- 'STATE [ids with flags.dump=true]'.
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
  'HELM', 'GLOVES', 'PANTS', 'AMMO', 'FOOD', 'EGG', 'CHEESE', 'GLOB', 'SKIN_TANNED', 'TOOL', 'CRAFTS', 'BARREL', 'BIN',
  'DRINK', 'BOX', 'BUCKET', 'FLASK', 'AMULET', 'BRACELET', 'EARRING', 'CROWN', 'RING', 'SCEPTER', 'INSTRUMENT', 'TOY',
  'TOTEM' }
df = {
  item_type = enum(TYPES),
  general_ref_type = enum({ 'CONTAINED_IN_ITEM', 'BUILDING_TRIGGER' }),
  building_type = enum({ 'Stockpile', 'Civzone', 'Workshop', 'Bridge', 'Trap' }),
  civzone_type = enum({ 'Home', 'Dump', 'Tomb' }),
  job_type = enum({ 'Dig', 'DumpItem', 'StoreItemInStockpile', 'ConstructBin', 'MakeCrafts', 'MakeGoblet',
                    'ConstructBlocks' }),
  logic_condition_type = enum({ 'AtLeast', 'AtMost', 'GreaterThan', 'LessThan', 'Exactly', 'Not' }),
  workquota_frequency_type = enum({ 'OneTime', 'Daily', 'Monthly', 'Seasonally', 'Yearly' }),
  global = { plotinfo = { race_id = 572 }, world = {}, item_next_id = tonumber(os.getenv('MOCK_NEXT_ID') or '') },
  unit = { find = function() return nil end },
}
-- FEATURE-002/003: standing orders (MOCK_STANDING = {"forbid_other_dead_items": 1, ...}) as DF globals
for k, v in pairs(readjson('MOCK_STANDING', {})) do df.global['standing_orders_' .. k] = v end

local tiles, piles = {}, {}
local items = {}
local occupied = {}
for _, d in raw_ipairs(readjson('MOCK_ITEMS', {})) do
  local key = d.x .. ',' .. d.y .. ',' .. d.z
  tiles[key] = { hidden = d.hidden or false, outside = d.outside or false, reach = d.reach ~= false }
  if d.stockpile then piles[key] = true end
  if not d.container then occupied[key] = true end
  local it = { id = d.id, _t = df.item_type[d.type], _x = d.x, _y = d.y, _z = d.z, race = d.race or 100,
               unit_id = d.unit_id or -1, hist_figure_id = d.hf or -1, _n = d.n or 1, _in = d.container,
               maker_race = d.maker or -1, corpse_flags = { bone = d.bone or false },
               flags = { on_ground = not d.container, dump = d.dump or false, forbid = d.forbid or false,
                         rotten = d.rotten or false, foreign = d.foreign or false, artifact = d.artifact or false,
                         trader = d.trader or false, in_job = d.in_job or false, in_building = d.in_building or false } }
  assert(it._t, 'unknown type ' .. tostring(d.type))
  function it:getType() return self._t end
  function it:getStackSize() return self._n end
  items[#items + 1] = it
end
local by_id = {}
for _, it in raw_ipairs(items) do by_id[it.id] = it end
local function of_type(t)
  local r = {}
  for _, it in raw_ipairs(items) do if it._t == df.item_type[t] then r[#r + 1] = it end end
  return vec(r)
end
df.global.world.items = { all = vec(items), other = { IN_PLAY = vec(items), BIN = of_type('BIN'), WOOD = of_type('WOOD') } }

-- buildings: dump zones (kind Civzone), stockpiles (kind Stockpile: cats, max_bins, max_barrels, extents ignored),
-- bridges (kind Bridge: raised, levers = [lever building ids])
local blds, by_bid, stockpiles = {}, {}, {}
for _, b in raw_ipairs(readjson('MOCK_BUILDINGS', {})) do
  local o = { id = b.id, x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z, type = df.civzone_type[b.zone or 'Dump'],
              _bt = df.building_type[b.kind or 'Civzone'], name = b.name or '', room = { width = 0 } }
  function o:getType() return self._bt end
  if b.kind == 'Stockpile' then
    local fl = {}
    for _, c in raw_ipairs(b.cats or {}) do fl[c] = true end
    o.settings = { flags = fl }
    o.storage = { max_bins = b.max_bins or 0, max_barrels = b.max_barrels or 0 }
    stockpiles[#stockpiles + 1] = o
  elseif b.kind == 'Bridge' then
    o.gate_flags = { raised = b.raised or false }
    local mechs = {}
    for _, lv in raw_ipairs(b.levers or {}) do mechs[#mechs + 1] = { _lever = lv } end
    o.linked_mechanisms = vec(mechs)
  end
  blds[#blds + 1] = o
  by_bid[o.id] = o
end
df.global.world.buildings = { all = vec(blds), other = { STOCKPILE = vec(stockpiles) } }
df.building = { find = function(id) return by_bid[id] end }
local head = { next = nil }
for _ = 1, tonumber(os.getenv('MOCK_DUMPJOBS') or '0') do head.next = { item = { job_type = df.job_type.DumpItem }, next = head.next } end
df.global.world.jobs = { list = head }

-- manager orders (MOCK_ORDERS = [{id, job, left, total, freq, conds: [{cmp, value, type, flags}]}])
local orders = {}
local orders_vec = vec(orders)
local function push_order(o) orders[#orders + 1] = o; orders_vec[#orders - 1] = o end
for _, d in raw_ipairs(readjson('MOCK_ORDERS', {})) do
  local conds = {}
  for _, c in raw_ipairs(d.conds or {}) do
    local f1 = {}
    for fl in tostring(c.flags or ''):gmatch('[%w_]+') do f1[fl] = true end
    conds[#conds + 1] = { compare_type = df.logic_condition_type[c.cmp or 'LessThan'], compare_val = c.value,
                          item_type = c.type and df.item_type[c.type] or -1, item_subtype = -1, flags1 = f1,
                          flags2 = {}, flags3 = {} }
  end
  push_order({ id = d.id, job_type = df.job_type[d.job], amount_left = d.left or 0, amount_total = d.total or 0,
               frequency = df.workquota_frequency_type[d.freq or 'Daily'], item_conditions = vec(conds) })
end
df.global.world.manager_orders = { all = orders_vec }
local workorder = {
  preprocess_orders = function(o) return { o } end,
  fillin_defaults = function() end,
  create_orders = function(list)
    for _, o in raw_ipairs(list) do
      push_order({ id = 900 + #orders, job_type = df.job_type[o.job], amount_left = o.amount_total,
                   amount_total = o.amount_total, frequency = df.workquota_frequency_type[o.frequency],
                   item_conditions = vec({}), _mc = o.material_category and o.material_category[1] })
    end
  end,
}

local STOCKPILE = { getType = function() return df.building_type.Stockpile end, id = -1 }
function xyz2pos(x, y, z) return { x = x, y = y, z = z } end
local function pile_at(p)
  for _, o in raw_ipairs(stockpiles) do
    if p.z == o.z and p.x >= o.x1 and p.x <= o.x2 and p.y >= o.y1 and p.y <= o.y2 then return o end
  end
  return piles[p.x .. ',' .. p.y .. ',' .. p.z] and STOCKPILE or nil
end
dfhack = {
  items = { getGeneralRef = function(it, t)
              if t == df.general_ref_type.CONTAINED_IN_ITEM and it._in then return { item_id = it._in } end
              if t == df.general_ref_type.BUILDING_TRIGGER and it._lever then return { building_id = it._lever } end
              return nil
            end,
            getPosition = function(it)
              local c = it
              while c._in and by_id[c._in] do c = by_id[c._in] end
              return c._x, c._y, c._z
            end,
            getContainer = function(it) return it._in and by_id[it._in] or nil end,
            getContainedItems = function(c)
              local r = {}
              for _, it in raw_ipairs(items) do if it._in == c.id then r[#r + 1] = it end end
              return r
            end },
  buildings = { findAtTile = pile_at },
  maps = { getTileFlags = function(x, y, z) return tiles[x .. ',' .. y .. ',' .. z] or { hidden = false, outside = false } end,
           canWalkBetween = function(_, p) local t = tiles[p.x .. ',' .. p.y .. ',' .. p.z] return not t or t.reach end,
           getTileBlock = function(x, y, z)
             local bx, by = x - x % 16, y - y % 16
             local occ = setmetatable({}, { __index = function(_, lx)
               return setmetatable({}, { __index = function(_, ly)
                 return { item = occupied[(bx + lx) .. ',' .. (by + ly) .. ',' .. z] == true }
               end })
             end })
             return { occupancy = occ }
           end },
  matinfo = { decode = function() return nil end },
  units = { getCitizens = function() return vec({}) end },
}
local logpath = os.getenv('MOCK_LOG')
local util = { require_fort = function() return true end, emit = function(t) print(encode(t)) end,
               home = function() return os.getenv('MOCK_HOME') or '.' end,
               game_date = function() return { text = '1. Granite, Jahr 122' } end,
               append_log = function(_, line)
                 if logpath then local f = io.open(logpath, 'a') f:write(line, '\n') f:close() end
               end }
local cfg = { FORT_REFS = { { 100, 100, 130 } } }
function reqscript(name)
  if name == 'claude/util' then return util end
  if name == 'claude/config' then return cfg end
  if name == 'workorder' then return workorder end
  error('reqscript ' .. name)
end

local script = arg[1]
local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
assert(loadfile(script))(table.unpack(args))
local forb, ords, maxb = {}, {}, {}
for _, it in raw_ipairs(items) do if it.flags.forbid then forb[#forb + 1] = it.id end end
for _, o in raw_ipairs(orders) do
  ords[#ords + 1] = { id = o.id, job = df.job_type[o.job_type], total = o.amount_total,
                      freq = df.workquota_frequency_type[o.frequency], mc = o._mc }
end
for _, o in raw_ipairs(stockpiles) do maxb[#maxb + 1] = { o.id, o.storage.max_bins } end
io.write('FORBIDDEN ') print(encode(forb))
io.write('ORDERS ') print(encode(ords))
io.write('MAXBINS ') print(encode(maxb))
local dumped = {}
for _, it in raw_ipairs(items) do if it.flags.dump then dumped[#dumped + 1] = it.id end end
io.write('STATE ')
print(encode(dumped))
