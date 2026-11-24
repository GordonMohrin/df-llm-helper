-- dfllm.util.hold (NEU1 P7, decision E5): the keys of the game objects an act call touches, so a player verb's change is
-- not undone by a kernel loop. Pure (no DF): kern / k_mock pass the act call (fn, its arguments, its result) in.
--   H.keys(fn, args, res) -> list of keys ('bld:<id>', 'zone:<id>', 'labor:<unit>:<labor>', 'wd:<unit>:<detail>',
--                            'office:<code>', 'area:z:x1:y1:x2:y2' (a removed footprint, recorded only), 'tile:x,y,z' (queried only))
--   H.query(fn, args) -> the keys a kernel call is checked against: H.keys, except that an unlock (door_forbid on=false) is never
--                        refused (fail safe: a hold may keep a door open, never shut)
-- The keys are per object AND per labor / detail (BUG-813): a player labor.set of one labor does not stop care's doctor or water's
-- Orderlies on the same unit. burrow_units has no key (BUG-814): gate's level-triggered lever-room pullers must win in BREACH, and
-- the player module restores its own burrow changes when the exit closes.
--   H.match(holds, keys, now) -> the hold entry that covers one of `keys`, or nil
-- `holds` is a list of {k = key, u = until tick, v = verb}; an `area` hold covers every `tile` key inside it.
local H = {}
H.NO_AREA = {Door = true, Hatch = true}

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function xyz(p)
  if type(p) ~= 'table' then return nil end
  if p.x ~= nil then return int(p.x), int(p.y), int(p.z) end
  return int(p[1]), int(p[2]), int(p[3])
end
local function tile(x, y, z)
  if x and y and z then return string.format('tile:%d,%d,%d', x, y, z) end
end
local function one(prefix, v)
  if v == nil then return {} end
  return {prefix .. tostring(v)}
end

-- act function -> keys from its positional arguments a (table.pack) and its result res
H.KEYS = {
  building_remove = function(a, res)
    local k = one('bld:', int(a[1]))
    local r = type(res) == 'table' and res.rect
    -- BUG-815: a removed door or hatch leaves no area hold (seal / runner must be able to close the perimeter there again)
    if type(res) == 'table' and H.NO_AREA[tostring(res.type)] then r = nil end
    if type(r) == 'table' and int(r[1]) and int(r[2]) and int(r[3]) and int(r[4]) and int(r[5]) then
      k[#k + 1] = string.format('area:%d:%d:%d:%d:%d', r[5], r[1], r[2], r[3], r[4])
    end
    return k
  end,
  zone_assign = function(a) return one('zone:', int(a[1])) end,
  labor_set = function(a)
    local u = int(a[1])
    return (u and type(a[2]) == 'string') and {string.format('labor:%d:%s', u, a[2])} or {}
  end,
  medic = function(a) local u = int(a[1]); return u and {string.format('labor:%d:medic', u)} or {} end,
  work_detail = function(a)
    local u = int(a[2])
    return (u and type(a[1]) == 'string') and {string.format('wd:%d:%s', u, a[1])} or {}
  end,
  appoint = function(a) return type(a[1]) == 'string' and {'office:' .. a[1]} or {} end,
  link_lever = function(a) return one('bld:', int(a[1])) end,
  cancel_link_job = function(a) return one('bld:', int(a[1])) end,
  door_forbid = function(a) return one('bld:', int(a[1])) end,
  -- creators: refused on a footprint the player removed (query only)
  quickfort = function(a) local p = type(a[1]) == 'table' and a[1] or {}; return {tile(xyz(p.pos))} end,
  zone_place = function(a) local p = type(a[1]) == 'table' and a[1] or {}; return {tile(xyz(p.pos))} end,
  hospital_restore = function(a)
    local p = type(a[1]) == 'table' and a[1] or {}
    return {tile(int(p.x1), int(p.y1), int(p.z)), tile(int(p.x2), int(p.y2), int(p.z))}
  end,
  sand_zone = function(a) return {tile(xyz(a[1]))} end,
  fish_zone = function(a) return {tile(xyz(a[1]))} end,
  water_zone = function(a) return {tile(xyz(a[1]))} end,
  drink_pile = function(a) return {tile(xyz(a[1]))} end,
  tool_pile = function(a) return {tile(xyz(a[1]))} end,
}

function H.keys(fn, a, res)
  local f = H.KEYS[fn]
  if not f or type(a) ~= 'table' then return {} end
  local ok, k = pcall(f, a, res)
  if not ok or type(k) ~= 'table' then return {} end
  local out = {}
  for i = 1, 4 do if type(k[i]) == 'string' then out[#out + 1] = k[i] end end      -- a nil key leaves a gap
  return out
end

function H.query(fn, a)
  if fn == 'door_forbid' and type(a) == 'table' and a[2] ~= true then return {} end
  return H.keys(fn, a)
end

-- keys a player verb leaves held (tile keys are queries, never holds)
function H.recorded(keys)
  local out = {}
  for _, k in ipairs(keys or {}) do if k:sub(1, 5) ~= 'tile:' then out[#out + 1] = k end end
  return out
end

local function in_area(area, t)
  local z, x1, y1, x2, y2 = area:match('^area:(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+):(%-?%d+)$')
  local x, y, tz = t:match('^tile:(%-?%d+),(%-?%d+),(%-?%d+)$')
  if not (z and x) then return false end
  x, y, tz = tonumber(x), tonumber(y), tonumber(tz)
  return tz == tonumber(z) and x >= math.min(tonumber(x1), tonumber(x2)) and x <= math.max(tonumber(x1), tonumber(x2))
         and y >= math.min(tonumber(y1), tonumber(y2)) and y <= math.max(tonumber(y1), tonumber(y2))
end

function H.match(holds, keys, now)
  if type(holds) ~= 'table' or type(keys) ~= 'table' or #keys == 0 then return nil end
  for _, h in ipairs(holds) do
    if type(h) == 'table' and type(h.k) == 'string' and (int(h.u) or 0) > (now or 0) then
      for _, k in ipairs(keys) do
        if h.k == k or (h.k:sub(1, 5) == 'area:' and k:sub(1, 5) == 'tile:' and in_area(h.k, k)) then return h end
      end
    end
  end
  return nil
end

return H
