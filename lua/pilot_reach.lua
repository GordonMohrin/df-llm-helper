-- claude/pilot_reach check sx sy sz x,y,z [x,y,z ...] | dump x1 y1 z1 x2 y2 z2     (df-llm-helper spec v3-11, LIVE-UNTESTED)
-- check: dfhack.maps.canWalkBetween(start, point) for every point in ONE call (walk groups, cheap)
--        -> {"ok":true,"start":[x,y,z],"results":[true,false,...]} (same order as the arguments).
-- dump:  one character per tile for a box (encoding in df_llm_helper/features/_grid.py); df-llm-helper does the path logic
--        (cause search with/without constructions, what-if walls). Unrevealed tiles are emitted as '?' and nothing
--        else is read about them (fair play). Max 200000 tiles per call.
-- Read only: no designations, no buildings, no map changes.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'check'
local function n(i) return tonumber(a[i]) end
local MAP = df.global.world.map
local XM, YM, ZM = MAP.x_count, MAP.y_count, MAP.z_count
local SHAPE = df.tiletype_shape
local FLOORISH = {}
for _, nm in ipairs({ 'FLOOR', 'BOULDER', 'PEBBLES', 'SHRUB', 'SAPLING', 'TWIG', 'BROOK_BED', 'BROOK_TOP',
                      'TRUNK_BRANCH' }) do
  if SHAPE[nm] then FLOORISH[SHAPE[nm]] = true end
end

-- walkable buildings that matter for paths: doors/hatches ('D'), traps ('T'); furniture stays floor
local function bchar(x, y, z)
  if not (dfhack.buildings and dfhack.buildings.findAtTile) then return nil end
  local b = dfhack.buildings.findAtTile(x, y, z)
  if not b then return nil end
  local t = b:getType()
  local BT = df.building_type
  if t == BT.Door or t == BT.Hatch then return 'D' end
  if t == BT.Trap then return 'T' end
  return nil
end

local function tch(x, y, z)
  if x < 0 or y < 0 or z < 0 or x >= XM or y >= YM or z >= ZM then return '#' end
  local d = dfhack.maps.getTileFlags(x, y, z)
  if not d then return '#' end
  if d.hidden then return '?' end                       -- unrevealed: not judged, nothing more is read
  local tt = dfhack.maps.getTileType(x, y, z)
  local at = tt and df.tiletype.attrs[tt]
  if not at then return '#' end
  local sh = at.shape
  if d.flow_size > 0 then return d.liquid_type == df.tile_liquid.Magma and 'M' or '~' end
  local out = d.outside
  if sh == SHAPE.WALL or sh == SHAPE.FORTIFICATION then
    if at.material == df.tiletype_material.CONSTRUCTION then return 'C' end
    if d.water_table then return 'A' end
    return '#'
  end
  if sh == SHAPE.EMPTY or sh == SHAPE.RAMP_TOP or sh == SHAPE.ENDLESS_PIT then
    if out then return "'" end
    return d.subterranean and 'V' or '_'
  end
  if sh == SHAPE.RAMP then return out and '/' or '^' end
  if sh == SHAPE.STAIR_UPDOWN then return out and 'x' or 'X' end
  if sh == SHAPE.STAIR_UP then return '<' end
  if sh == SHAPE.STAIR_DOWN then return '>' end
  if FLOORISH[sh] then
    return bchar(x, y, z) or (out and ',' or '.')
  end
  return '#'
end

if cmd == 'check' then
  local sx, sy, sz = n(2), n(3), n(4)
  if not (sx and sy and sz) then util.emit({ ok = false, error = 'check sx sy sz x,y,z ...' }) return end
  local res = {}
  for i = 5, #a do
    local x, y, z = a[i]:match('^(-?%d+),(-?%d+),(-?%d+)$')
    if x then
      res[#res + 1] = dfhack.maps.canWalkBetween(xyz2pos(sx, sy, sz), xyz2pos(tonumber(x), tonumber(y), tonumber(z)))
        and true or false
    end
  end
  util.emit({ ok = true, start = { sx, sy, sz }, results = res })
elseif cmd == 'dump' then
  local x1, y1, z1, x2, y2, z2 = n(2), n(3), n(4), n(5), n(6), n(7)
  if not (x1 and y1 and z1 and x2 and y2 and z2) then util.emit({ ok = false, error = 'dump x1 y1 z1 x2 y2 z2' }) return end
  x1, x2 = math.max(0, math.min(x1, x2)), math.min(XM - 1, math.max(x1, x2))
  y1, y2 = math.max(0, math.min(y1, y2)), math.min(YM - 1, math.max(y1, y2))
  z1, z2 = math.max(0, math.min(z1, z2)), math.min(ZM - 1, math.max(z1, z2))
  local cells = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
  if cells > 200000 then util.emit({ ok = false, error = 'box too large: ' .. cells .. ' tiles (max 200000)' }) return end
  local levels = {}
  for z = z1, z2 do
    local rows = {}
    for y = y1, y2 do
      local r = {}
      for x = x1, x2 do r[#r + 1] = tch(x, y, z) end
      rows[#rows + 1] = table.concat(r)
    end
    levels[tostring(z)] = rows
  end
  util.emit({ ok = true, origin = { x1, y1 }, box = { x1, y1, z1, x2, y2, z2 }, levels = levels })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_reach check sx sy sz x,y,z ... | dump x1 y1 z1 x2 y2 z2' })
end
