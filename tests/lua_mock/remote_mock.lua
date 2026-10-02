-- Minimal DFHack mock for lua/pilot_remote.lua and lua/pilot_tools.lua (spec v3-05/06). Usage:
--   MOCK_REMOTE=<units.json> lua5.4 tests/lua_mock/remote_mock.lua <script.lua> [args...]
-- units.json: [{id, citizen, adult, squad, x, y, z, hunger, thirst, job, labors:[...], pick}]
-- Fixed world: hospital zone 900 = rectangle (0,0)-(5,5) on z130 (location 7, type HOSPITAL); food stockpile 500 at
-- (92,97,130); work details Fisherdwarves (FISH, selected: 4156, 344), Planters (PLANT, everybody).
-- After the run prints 'STATE {...}' with labors/jobs per unit and the work detail members.
local function enum(names)
  local t = {}
  for i, n in ipairs(names) do t[n] = i - 1; t[i - 1] = n end
  return t
end
local function vec(items)
  local v = { _n = #items }
  for i, x in ipairs(items) do v[i - 1] = x end
  return setmetatable(v, { __len = function(s) return s._n end, __index = {
    erase = function(s, k) for i = k, s._n - 2 do s[i] = s[i + 1] end s[s._n - 1] = nil s._n = s._n - 1 end,
    insert = function(s, pos, x) s[s._n] = x s._n = s._n + 1 end } })
end
local std_ipairs = ipairs
local function lua_ipairs(v)            -- DFHack-style ipairs over 0-based vectors
  if type(v) == 'table' and v._n then
    local i = -1
    return function() i = i + 1 if i < v._n then return i, v[i] end end
  end
  return std_ipairs(v)
end

local function encode(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' or t == 'number' then return tostring(v) end
  if t == 'string' then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
  if #v > 0 or next(v) == nil then
    local p = {}
    for _, x in ipairs(v) do p[#p + 1] = encode(x) end
    return '[' .. table.concat(p, ',') .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local p = {}
  for _, k in ipairs(keys) do p[#p + 1] = encode(k) .. ':' .. encode(v[k] == nil and v[tonumber(k)] or v[k]) end
  return '{' .. table.concat(p, ',') .. '}'
end

-- tiny JSON decoder (objects, arrays, strings, numbers, booleans, null)
local function decode(s)
  local pos = 1
  local val
  local function ws() pos = s:find('[^%s]', pos) or #s + 1 end
  local function str()
    local e = s:find('"', pos + 1, true)
    local r = s:sub(pos + 1, e - 1) pos = e + 1 return r
  end
  function val()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      local t = {} pos = pos + 1 ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        ws() local k = str() ws() pos = pos + 1 t[k] = val() ws()
        local d = s:sub(pos, pos) pos = pos + 1
        if d == '}' then return t end
      end
    elseif c == '[' then
      local t = {} pos = pos + 1 ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = s:sub(pos, pos) pos = pos + 1
        if d == ']' then return t end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    else
      local n = s:match('^-?%d+%.?%d*', pos) pos = pos + #n return tonumber(n)
    end
  end
  return val()
end

local LABORS = { 'MINE', 'HAUL_STONE', 'FISH', 'HERBALISM', 'PLANT', 'HUNT', 'CUTWOOD' }
local JOBS = { 'Dig', 'Fish', 'GatherPlants', 'Haul', 'Eat', 'Rest' }
df = {
  unit_labor = enum(LABORS), job_type = enum(JOBS), work_detail_mode = enum({ 'EverybodyDoesThis', 'NobodyDoesThis', 'OnlySelectedDoesThis' }),
  item_type = enum({ 'WEAPON', 'BIN' }), building_type = enum({ 'Well', 'Bed' }), abstract_building_type = enum({ 'HOSPITAL' }),
  job_skill = enum({ 'MINING' }),
}
local M = df.work_detail_mode
local function allowed(names)
  local t = {}
  for _, n in ipairs(names) do t[df.unit_labor[n]] = true end
  return t
end
local wds = vec({
  { name = 'Fisherdwarves', flags = { mode = M.OnlySelectedDoesThis }, allowed_labors = allowed({ 'FISH' }), assigned_units = vec({ 4156, 344 }) },
  { name = 'Planters', flags = { mode = M.EverybodyDoesThis }, allowed_labors = allowed({ 'PLANT' }), assigned_units = vec({}) },
})
local units = {}
do
  local f = io.open(os.getenv('MOCK_REMOTE'), 'r')
  local raw = f:read('*a') f:close()
  for _, d in ipairs(decode(raw)) do
    local labs = {}
    for _, L in ipairs(d.labors or {}) do labs[df.unit_labor[L]] = true end
    local u = { id = d.id, _c = d.citizen ~= false, _a = d.adult ~= false, pos = { x = d.x or 90, y = d.y or 95, z = d.z or 130 },
                military = { squad_id = d.squad and 1 or -1 }, counters2 = { hunger_timer = d.hunger or 0, thirst_timer = d.thirst or 0 },
                status = { labors = labs }, job = { current_job = d.job and { job_type = df.job_type[d.job] } or nil },
                inventory = vec({}), body = { wounds = vec({}) }, status2 = { limbs_stand_count = 2 } }
    units[#units + 1] = u
  end
end
local zone = { id = 900, x1 = 0, y1 = 0, x2 = 5, y2 = 5, z = 130, location_id = 7 }
df.global = {
  plotinfo = { labor_info = { work_details = wds }, equipment = { work_weapons = vec({ 1, 2 }) } },
  world = {
    world_data = { active_site = { [0] = { buildings = vec({ { id = 7, getType = function() return df.abstract_building_type.HOSPITAL end } }) } } },
    buildings = { other = { ACTIVITY_ZONE = vec({ zone }), STOCKPILE = vec({ { id = 500, centerx = 92, centery = 97, z = 130, settings = { flags = { food = true } } } }) },
                  all = vec({}) },
    items = { other = { WEAPON = vec({}), FISH_RAW = vec({ { flags = {}, getStackSize = function() return 3 end } }), FISH = vec({}) } },
    jobs = { list = {} },
  },
}
df.unit = { find = function(id) for _, u in ipairs(units) do if u.id == id then return u end end return nil end }
dfhack = {
  units = { getCitizens = function() local v = {} for _, u in ipairs(units) do if u._c then v[#v + 1] = u end end return vec(v) end,
            isCitizen = function(u) return u._c end, isAdult = function(u) return u._a end,
            getReadableName = function(u) return 'Dwarf ' .. u.id end, getEffectiveSkill = function() return 0 end },
  job = { removeJob = function(j) for _, u in ipairs(units) do if u.job.current_job == j then u.job.current_job = nil end end return true end,
          removeWorker = function() return true end },
  items = {},
}
ipairs = lua_ipairs
package.loaded['utils'] = { listpairs = function() return function() return nil end end }
local util = { require_fort = function() return true end, emit = function(t) print(encode(t)) end }
function reqscript(name)
  if name == 'claude/util' then return util end
  error('reqscript ' .. name)
end

local script = arg[1]
local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end
assert(loadfile(script))(table.unpack(args))
local st = { units = {}, wds = {} }
for _, u in ipairs(units) do
  local labs = {}
  for _, L in ipairs(LABORS) do if u.status.labors[df.unit_labor[L]] then labs[#labs + 1] = L end end
  st.units[tostring(u.id)] = { labors = labs, job = u.job.current_job and df.job_type[u.job.current_job.job_type] or 'none' }
end
for i = 0, #wds - 1 do
  local m = {}
  for j = 0, #wds[i].assigned_units - 1 do m[#m + 1] = wds[i].assigned_units[j] end
  st.wds[wds[i].name] = m
end
io.write('STATE ') print(encode(st))
